import Combine
import Foundation

// MARK: - Model

/// A chord inside a loop, in beats so playback follows the tempo.
struct LoopEvent: Codable, Equatable {
    var degree: Degree
    var color: ChordColor
    /// Octave it was played in (0 = normal register).
    var octave = 0
    var start: Double
    var length: Double

    init(degree: Degree, color: ChordColor, octave: Int = 0, start: Double, length: Double) {
        self.degree = degree
        self.color = color
        self.octave = octave
        self.start = start
        self.length = length
    }

    /// Loops saved before octaves existed have no `octave`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        degree = try c.decode(Degree.self, forKey: .degree)
        color = try c.decode(ChordColor.self, forKey: .color)
        octave = try c.decodeIfPresent(Int.self, forKey: .octave) ?? 0
        start = try c.decode(Double.self, forKey: .start)
        length = try c.decode(Double.self, forKey: .length)
    }
}

struct Loop: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var createdAt: Date
    var bpm: Int
    var tonic: Note
    var flavor: Flavor
    var lengthBeats: Double
    var events: [LoopEvent]
}

enum LoopMath {
    static let beatsPerBar = 4.0
    /// Recording grid: sixteenth notes.
    static let quantum = 0.25
    private static let epsilon = 1e-6

    private static func snap(_ beats: Double) -> Double { (beats / quantum).rounded() * quantum }

    /// Wall-clock chords → loop events. The length rounds to whole bars (at least one).
    static func build(_ chords: [PlayedChord], start: Double, end: Double, bpm: Int) -> (Double, [LoopEvent]) {
        let toBeats = { (t: Double) in (t - start) * Double(bpm) / 60 }
        let bars = max(1, (toBeats(end) / beatsPerBar).rounded())
        let length = bars * beatsPerBar
        let events = chords.compactMap { c -> LoopEvent? in
            let from = max(0, snap(toBeats(c.start)))
            let to = min(length, max(from + quantum, snap(toBeats(c.end))))
            guard from < length, to > from else { return nil }
            return LoopEvent(degree: c.degree, color: c.color, octave: c.octave, start: from, length: to - from)
        }
        return (length, events.sorted { $0.start < $1.start })
    }

    /// What falls inside [start, end), re-based so `start` becomes beat 0.
    static func trim(_ events: [LoopEvent], start: Double, end: Double) -> [LoopEvent] {
        events.compactMap { e in
            let from = max(e.start, start), to = min(e.start + e.length, end)
            guard to - from > epsilon else { return nil }
            return LoopEvent(degree: e.degree, color: e.color, octave: e.octave, start: from - start, length: to - from)
        }
    }

    /// Shift every chord by `offset` beats, wrapping; a chord crossing the end splits in two.
    static func rotate(_ events: [LoopEvent], length: Double, offset: Double) -> [LoopEvent] {
        let shift = (offset.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
        guard shift > epsilon else { return events }
        return events.flatMap { e -> [LoopEvent] in
            let start = (e.start + shift).truncatingRemainder(dividingBy: length)
            let end = start + e.length
            var first = e, second = e
            first.start = start
            if end <= length + epsilon { return [first] }
            first.length = length - start
            second.start = 0
            second.length = end - length
            return [first, second]
        }
        .sorted { $0.start < $1.start }
    }

    /// "2 compases", or "6,5 tiempos" when it isn't whole bars.
    static func formatLength(_ beats: Double) -> String {
        let bars = beats / beatsPerBar
        if bars == bars.rounded() {
            let n = Int(bars)
            return n == 1 ? tr("1 compás") : tr("%d compases", n)
        }
        return tr("%@ tiempos", beats.formatted(.number.precision(.fractionLength(0...2))))
    }
}

// MARK: - Loops (library, recorder, player)

/// Records, saves (`~/Library/Application Support/Chordy/loops.json`) and plays loops.
@MainActor
final class Loops: ObservableObject {
    enum RecorderState { case idle, armed, recording }

    @Published private(set) var loops: [Loop] = []
    @Published private(set) var recorderState = RecorderState.idle
    @Published private(set) var elapsedBeats = 0.0
    @Published var metronome = UserDefaults.standard.object(forKey: "metronome") as? Bool ?? true {
        didSet { UserDefaults.standard.set(metronome, forKey: "metronome") }
    }
    @Published private(set) var playingId: String?
    /// 0…1 inside the playing loop.
    @Published private(set) var progress = 0.0
    /// Loop the P key / ▶ button plays: last played, else newest.
    @Published private(set) var selectedId: String?

    private let engine: ChordEngine
    private var cancellables = Set<AnyCancellable>()

    // Recorder.
    private var takeStart = 0.0
    private var takeBpm = 110
    private var takeTonic = Note.c
    private var takeFlavor = Flavor.major
    private var captured: [PlayedChord] = []
    private var nextBeat = 0
    private var recordTimer: Timer?

    // Player.
    private var playing: Loop?
    private var position = 0.0
    private var lastTick = 0.0
    private var sounding = Set<Int>()
    private var playTimer: Timer?

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("loops.json")
    }

    init(engine: ChordEngine) {
        self.engine = engine
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? decoder.decode([Loop].self, from: data) {
            loops = saved.filter { $0.lengthBeats > 0 }
        }
        engine.onChordPlayed { [weak self] chord in
            MainActor.assumeIsolated {
                guard let self, self.recorderState == .recording else { return }
                self.captured.append(chord)
            }
        }
        // The take begins with the first chord after arming.
        engine.$held
            .receive(on: RunLoop.main)
            .sink { [weak self] held in
                if self?.recorderState == .armed, !held.isEmpty { self?.begin() }
            }
            .store(in: &cancellables)
    }

    var selected: Loop? { loops.first { $0.id == selectedId } ?? loops.first }
    var isRecording: Bool { recorderState != .idle }
    var isPlaying: Bool { playingId != nil }

    // MARK: Library

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].name = trimmed
        persist()
    }

    func remove(_ id: String) {
        if playingId == id { stopPlayback() }
        loops.removeAll { $0.id == id }
        persist()
    }

    func update(_ id: String, length: Double, events: [LoopEvent]) {
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return }
        let wasPlaying = playingId == id
        loops[i].lengthBeats = length
        loops[i].events = events
        persist()
        if wasPlaying { play(loops[i]) }
    }

    private func nextName() -> String {
        let used = Set(loops.map(\.name))
        var n = loops.count + 1
        while used.contains(tr("Loop %d", n)) { n += 1 }
        return tr("Loop %d", n)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(loops).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Chordy: could not save loops: \(error)")
        }
    }

    // MARK: Recorder

    /// R / ●: arm, or stop and save the take.
    func toggleRecord() {
        switch recorderState {
        case .idle:
            captured = []
            recorderState = .armed
            if !engine.heldDegrees.isEmpty { begin() }
        case .armed:
            resetRecorder()
        case .recording:
            finishTake()
        }
    }

    private func begin() {
        recorderState = .recording
        takeStart = now()
        takeBpm = engine.bpm
        takeTonic = engine.tonic
        takeFlavor = engine.flavor
        elapsedBeats = 0
        nextBeat = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordTimer = timer
        recordTick()
    }

    private func recordTick() {
        let beatSeconds = 60 / Double(takeBpm)
        elapsedBeats = (now() - takeStart) / beatSeconds
        while Double(nextBeat) <= elapsedBeats {
            if metronome { Synth.shared.click(accent: nextBeat % Int(LoopMath.beatsPerBar) == 0) }
            nextBeat += 1
        }
    }

    private func finishTake() {
        let end = now()
        let chords = (captured + engine.heldChords(end: end)).map {
            PlayedChord(degree: $0.degree, color: $0.color, octave: $0.octave, start: max($0.start, takeStart), end: $0.end)
        }
        let start = takeStart, bpm = takeBpm, tonic = takeTonic, flavor = takeFlavor
        resetRecorder()
        guard !chords.isEmpty else { return }
        let (length, events) = LoopMath.build(chords, start: start, end: end, bpm: bpm)
        let loop = Loop(id: UUID().uuidString, name: nextName(), createdAt: Date(), bpm: bpm, tonic: tonic,
                        flavor: flavor, lengthBeats: length, events: events)
        loops.insert(loop, at: 0)
        selectedId = loop.id
        persist()
    }

    private func resetRecorder() {
        recordTimer?.invalidate()
        recordTimer = nil
        captured = []
        elapsedBeats = 0
        recorderState = .idle
    }

    // MARK: Player

    /// P / ▶: play or stop a loop (the selected one by default).
    func togglePlay(_ id: String? = nil) {
        guard let loop = id.flatMap({ id in loops.first { $0.id == id } }) ?? selected else { return }
        selectedId = loop.id
        if playingId == loop.id { stopPlayback() } else { play(loop) }
    }

    /// Plays in the key, mode and tempo it was recorded in; follows live changes after that.
    func play(_ loop: Loop) {
        stopPlayback()
        engine.tonic = loop.tonic
        engine.flavor = loop.flavor
        engine.setBpm(loop.bpm)
        playing = loop
        playingId = loop.id
        position = 0
        lastTick = now()
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playTimer = timer
        playTick()
    }

    /// Audition an unsaved edit under the original loop's id.
    func preview(_ draft: Loop) { play(draft) }

    func stopPlayback() {
        playTimer?.invalidate()
        playTimer = nil
        if let loop = playing { for i in sounding { engine.endLoopChord(id: chordId(loop, i)) } }
        sounding.removeAll()
        playing = nil
        playingId = nil
        progress = 0
    }

    private func chordId(_ loop: Loop, _ index: Int) -> String { "loop:\(loop.id):\(index)" }

    private func playTick() {
        guard let loop = playing else { return }
        let t = now()
        position += (t - lastTick) * Double(engine.bpm) / 60
        lastTick = t
        position = position.truncatingRemainder(dividingBy: loop.lengthBeats)
        progress = position / loop.lengthBeats

        for (i, event) in loop.events.enumerated() where sounding.contains(i) {
            if !(position >= event.start && position < event.start + event.length) {
                engine.endLoopChord(id: chordId(loop, i))
                sounding.remove(i)
            }
        }
        for (i, event) in loop.events.enumerated() where !sounding.contains(i) {
            if position >= event.start && position < event.start + event.length {
                engine.startLoopChord(id: chordId(loop, i), degree: event.degree, color: event.color, octave: event.octave)
                sounding.insert(i)
            }
        }
    }
}
