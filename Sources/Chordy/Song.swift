import Combine
import Foundation
import QuartzCore

/// The arrangement: a drum track and loop tracks with clips placed on bars. A clip repeats its
/// loop (or drum pattern) for as many bars as it lasts. Saved in
/// `~/Library/Application Support/Chordy/song.json` and inside each project.
struct SongData: Codable, Equatable {
    struct Track: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var isDrums: Bool
        var muted = false
        /// Optional so songs saved before still decode.
        var color: Int?
        var volume: Double?
        var solo: Bool?

        var level: Double { volume ?? 1 }
        var soloed: Bool { solo ?? false }
    }

    /// A named stretch of bars (Intro, Verse…) to jump to or repeat.
    struct Section: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var start: Int
        var bars: Int
        var color: Int
    }

    struct Clip: Codable, Equatable, Identifiable {
        enum Source: Codable, Equatable {
            case loop(String)
            case drums(Int)
        }

        var id: String
        var source: Source
        var track: String
        /// First bar (0-based) and length in bars.
        var start: Int
        var bars: Int
        var volume: Double?
        /// Semitones (single notes only; chords follow the loop's key).
        var transpose: Int?
    }

    var tracks: [Track]
    var clips: [Clip]
    var sections: [Section]?

    static let empty = SongData(
        tracks: [Track(id: "drums", name: tr("Batería"), isDrums: true, color: 2)]
            + (1...3).map { Track(id: "loops\($0)", name: tr("Loops %d", $0), isDrums: false, color: $0 == 1 ? 0 : ($0 == 2 ? 1 : 4)) },
        clips: [], sections: [])
}

/// Plays the arrangement on the shared transport: drums through the drum machine's clock, loop
/// notes scheduled ahead with their exact time (like `Loops`).
@MainActor
final class Song: ObservableObject {
    @Published var data: SongData { didSet { if data != oldValue { persist() } } }
    @Published private(set) var playing = false
    /// Song position in beats while playing.
    @Published private(set) var position = 0.0
    /// Where ▶ starts (bar, 0-based).
    @Published var startBar = 0
    /// Bars repeated while playing (a section), or nil.
    @Published var loopRange: Range<Int>? { didSet { if playing, loopRange != oldValue, let r = loopRange { play(fromBar: r.lowerBound) } } }

    private let engine: ChordEngine
    private let loops: Loops
    private let drums: DrumMachine
    private let instruments: InstrumentLibrary
    private var timer: Timer?
    /// Transport beat of song beat `fromBeat`.
    private var anchorBeat = 0.0
    private var fromBeat = 0.0
    private var scheduledTo = 0.0
    private var lengthBeats = 0.0
    /// Notes started and when they end (song beats).
    private var pendingOffs: [(id: String, end: Double)] = []
    private var sounding = Set<String>()
    private var lastPublish = 0.0
    private static let lookahead = 0.06

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("song.json")
    }

    init(engine: ChordEngine, loops: Loops, drums: DrumMachine, instruments: InstrumentLibrary) {
        self.engine = engine
        self.loops = loops
        self.drums = drums
        self.instruments = instruments
        data = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode(SongData.self, from: $0) } ?? .empty
    }

    /// Bars in the song: up to the last clip, at least 8.
    var lengthBars: Int { max(8, data.clips.map { $0.start + $0.bars }.max() ?? 0) }

    // MARK: Editing

    func add(_ source: SongData.Clip.Source, track: String, at bar: Int) {
        let bars: Int
        switch source {
        case .loop(let id): bars = max(1, Int(((loops.loops.first { $0.id == id }?.lengthBeats ?? 4) / 4).rounded(.up)))
        case .drums: bars = 4
        }
        data.clips.append(SongData.Clip(id: UUID().uuidString, source: source, track: track, start: max(0, bar), bars: bars))
    }

    func update(_ id: String, _ body: (inout SongData.Clip) -> Void) {
        guard let i = data.clips.firstIndex(where: { $0.id == id }) else { return }
        var c = data.clips[i]
        body(&c)
        c.start = max(0, c.start)
        c.bars = max(1, c.bars)
        data.clips[i] = c
    }

    func remove(_ id: String) { data.clips.removeAll { $0.id == id } }

    /// A loop was deleted: its clips go too.
    func removeClips(of loopId: String) { data.clips.removeAll { $0.source == .loop(loopId) } }

    func clips(of loopId: String) -> Int { data.clips.filter { $0.source == .loop(loopId) }.count }

    func addTrack() {
        let n = data.tracks.filter { !$0.isDrums }.count + 1
        data.tracks.append(SongData.Track(id: UUID().uuidString, name: tr("Loops %d", n), isDrums: false, color: n % 6))
    }

    func updateTrack(_ id: String, _ body: (inout SongData.Track) -> Void) {
        guard let i = data.tracks.firstIndex(where: { $0.id == id }) else { return }
        body(&data.tracks[i])
    }

    func toggleSolo(_ id: String) {
        updateTrack(id) { $0.solo = !$0.soloed }
        if playing { play(fromBar: Int(position / 4)) }
    }

    /// A copy right after the clip.
    func duplicate(_ id: String) -> String? {
        guard var c = data.clips.first(where: { $0.id == id }) else { return nil }
        c.id = UUID().uuidString
        c.start += c.bars
        data.clips.append(c)
        return c.id
    }

    // MARK: Sections

    var sections: [SongData.Section] { data.sections ?? [] }

    func addSection(at bar: Int) {
        let n = sections.count + 1
        var list = sections
        list.append(SongData.Section(id: UUID().uuidString, name: tr("Sección %d", n), start: max(0, bar), bars: 4, color: n % 6))
        data.sections = list
    }

    func updateSection(_ id: String, _ body: (inout SongData.Section) -> Void) {
        guard var list = data.sections, let i = list.firstIndex(where: { $0.id == id }) else { return }
        body(&list[i])
        list[i].start = max(0, list[i].start)
        list[i].bars = max(1, list[i].bars)
        data.sections = list
    }

    func removeSection(_ id: String) { data.sections = sections.filter { $0.id != id } }

    /// Seconds from the start to song beat `beat`, at the current tempo.
    func seconds(atBeat beat: Double) -> Double { beat * 60 / Double(engine.bpm) }

    func removeTrack(_ id: String) {
        guard let track = data.tracks.first(where: { $0.id == id }), !track.isDrums else { return }
        data.tracks.removeAll { $0.id == id }
        data.clips.removeAll { $0.track == id }
    }

    func toggleMute(_ id: String) {
        guard let i = data.tracks.firstIndex(where: { $0.id == id }) else { return }
        data.tracks[i].muted.toggle()
        if playing { play(fromBar: Int(position / 4)) }
    }

    func replace(_ new: SongData) {
        stop()
        data = new
    }

    // MARK: Playback

    func togglePlay() { playing ? stop() : play(fromBar: startBar) }

    func play(fromBar bar: Int) {
        stop()
        loops.stopPlayback()
        drums.stop()
        lengthBeats = Double(lengthBars) * 4
        fromBeat = Double(min(bar, lengthBars - 1)) * 4
        anchorBeat = Transport.shared.join("song")
        scheduledTo = fromBeat
        position = fromBeat
        // Drums: one entry per bar from the start bar to the end.
        let drumTrack = data.tracks.first { $0.isDrums }
        var order = [Int?](repeating: nil, count: lengthBars)
        let anySolo = data.tracks.contains { $0.soloed }
        if let drumTrack, !drumTrack.muted, !anySolo || drumTrack.soloed {
            for c in data.clips where c.track == drumTrack.id {
                guard case .drums(let pattern) = c.source else { continue }
                for b in c.start..<(c.start + c.bars) where b < order.count { order[b] = pattern }
            }
        }
        let fromBar = Int(fromBeat / 4)
        let slice = Array(order[fromBar...])
        if slice.contains(where: { $0 != nil }) { drums.playSong(slice, at: anchorBeat, gain: drumTrack?.level ?? 1) }
        // Loop instruments ready (and at their mix level) before the first note.
        for case .loop(let id) in data.clips.map(\.source) {
            guard let loop = loops.loops.first(where: { $0.id == id }) else { continue }
            for inst in Set(loop.events.compactMap(\.instrument) + [loop.instrument ?? instruments.selectedId]) {
                instruments.player(for: SoundRoute.make(inst, bus: "loop:\(id)"))?.setLevel(loops.volume / 0.85)
            }
        }
        playing = true
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        guard playing else { return }
        timer?.invalidate()
        timer = nil
        for id in sounding { engine.endLoopChord(id: id) }
        sounding.removeAll()
        pendingOffs.removeAll()
        drums.stopSong()
        Transport.shared.leave("song")
        playing = false
        position = Double(startBar) * 4
    }

    private func transportTime(ofSongBeat b: Double) -> Double {
        Transport.shared.time(ofBeat: anchorBeat + (b - fromBeat))
    }

    private func tick() {
        let t = Transport.shared.snapshot
        let now = CACurrentMediaTime()
        let songNow = fromBeat + (t.beat(at: now) - anchorBeat)
        if now - lastPublish > 1.0 / 30 {
            position = max(fromBeat, songNow)
            lastPublish = now
        }
        if let r = loopRange, songNow >= Double(r.upperBound) * 4 {
            play(fromBar: r.lowerBound)
            return
        }
        if songNow >= lengthBeats {
            stop()
            return
        }
        let horizon = min(lengthBeats, fromBeat + (t.beat(at: now + Self.lookahead) - anchorBeat))
        // Note-offs due before the horizon.
        pendingOffs.removeAll { off in
            guard off.end < horizon else { return false }
            engine.endLoopChord(id: off.id, at: transportTime(ofSongBeat: off.end))
            sounding.remove(off.id)
            return true
        }
        guard horizon > scheduledTo else { return }
        let anySolo = data.tracks.contains { $0.soloed }
        let silent = Set(data.tracks.filter { $0.muted || (anySolo && !$0.soloed) }.map(\.id))
        let levels = Dictionary(uniqueKeysWithValues: data.tracks.map { ($0.id, $0.level) })
        for clip in data.clips where !silent.contains(clip.track) {
            let gain = (levels[clip.track] ?? 1) * (clip.volume ?? 1)
            guard case .loop(let id) = clip.source, let loop = loops.loops.first(where: { $0.id == id }), loop.lengthBeats > 0 else { continue }
            let clipStart = Double(clip.start) * 4, clipEnd = Double(clip.start + clip.bars) * 4
            guard clipEnd > scheduledTo, clipStart < horizon else { continue }
            // Notes crossing the loop's seam: the clip starts with their tail.
            if clipStart >= scheduledTo, clipStart < horizon {
                for (i, e) in loop.events.enumerated() where e.start + e.length > loop.lengthBeats + 1e-6 {
                    let end = min(clipStart + e.start + e.length - loop.lengthBeats, clipEnd)
                    guard end > clipStart else { continue }
                    let noteId = "song:\(clip.id):tail:\(i)"
                    let inst = SoundRoute.make(e.instrument ?? loop.instrument ?? instruments.selectedId, bus: "loop:\(id)")
                    let time = transportTime(ofSongBeat: clipStart)
                    let velocity = max(1, min(127, Int((Double(e.velocity) * gain).rounded())))
                    if let midi = e.midi {
                        engine.startLoopNote(id: noteId, midi: max(0, min(127, midi + (clip.transpose ?? 0))),
                                             velocity: velocity, instrument: inst, at: time)
                    } else {
                        engine.startLoopChord(id: noteId, degree: e.degree, color: e.color, octave: e.octave,
                                              accidental: e.accidental, instrument: inst, velocity: velocity, at: time)
                    }
                    sounding.insert(noteId)
                    pendingOffs.append((noteId, end))
                }
            }
            var rep = max(0, Int(((scheduledTo - clipStart) / loop.lengthBeats).rounded(.down)))
            while true {
                let base = clipStart + Double(rep) * loop.lengthBeats
                if base >= min(clipEnd, horizon) { break }
                for (i, e) in loop.events.enumerated() {
                    let at = base + e.start
                    guard at >= scheduledTo, at < horizon, at < clipEnd else { continue }
                    let end = min(at + e.length, clipEnd)
                    let noteId = "song:\(clip.id):\(rep):\(i)"
                    let inst = SoundRoute.make(e.instrument ?? loop.instrument ?? instruments.selectedId, bus: "loop:\(id)")
                    let time = transportTime(ofSongBeat: at)
                    let velocity = max(1, min(127, Int((Double(e.velocity) * gain).rounded())))
                    if let midi = e.midi {
                        engine.startLoopNote(id: noteId, midi: max(0, min(127, midi + (clip.transpose ?? 0))),
                                             velocity: velocity, instrument: inst, at: time)
                    } else {
                        engine.startLoopChord(id: noteId, degree: e.degree, color: e.color, octave: e.octave,
                                              accidental: e.accidental, instrument: inst, velocity: velocity, at: time)
                    }
                    sounding.insert(noteId)
                    pendingOffs.append((noteId, end))
                }
                rep += 1
            }
        }
        scheduledTo = horizon
    }

    private func persist() {
        do {
            try JSONEncoder().encode(data).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Chordy: could not save the song: \(error)")
        }
    }
}
