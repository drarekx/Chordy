import Combine
import Foundation

// MARK: - Model

/// A chord inside a loop, in beats so playback follows the tempo.
struct LoopEvent: Codable, Equatable {
    var degree: Degree
    var color: ChordColor
    /// Octave it was played in (0 = normal register).
    var octave = 0
    /// Semitones above the degree's root (chromatic keys).
    var accidental = 0
    /// A single note (piano in Notes layout) instead of a chord; `degree`/`color` are unused then.
    var midi: Int?
    var velocity = 100
    /// Sound it was played with (two keyboards can record into one take); nil = the loop's.
    var instrument: String?
    var start: Double
    var length: Double

    init(degree: Degree, color: ChordColor, octave: Int = 0, accidental: Int = 0, start: Double, length: Double) {
        self.degree = degree
        self.color = color
        self.octave = octave
        self.accidental = accidental
        self.start = start
        self.length = length
    }

    /// Loops saved before octaves existed have no `octave`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        degree = try c.decode(Degree.self, forKey: .degree)
        color = try c.decode(ChordColor.self, forKey: .color)
        octave = try c.decodeIfPresent(Int.self, forKey: .octave) ?? 0
        accidental = try c.decodeIfPresent(Int.self, forKey: .accidental) ?? 0
        midi = try c.decodeIfPresent(Int.self, forKey: .midi)
        velocity = try c.decodeIfPresent(Int.self, forKey: .velocity) ?? 100
        instrument = try c.decodeIfPresent(String.self, forKey: .instrument)
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
    /// Instrument it was recorded with (`InstrumentLibrary.synthId` or an `Instrument.id`); nil in
    /// loops saved before instruments, which play with whatever is selected.
    var instrument: String?
    /// Reverb, delay and filter for this loop's sampled sounds.
    var effects: Effects?
}

enum LoopMath {
    static let beatsPerBar = 4.0
    /// Recording grid: sixteenth notes.
    static let quantum = 0.25
    private static let epsilon = 1e-6

    private static func snap(_ beats: Double) -> Double { (beats / quantum).rounded() * quantum }
    /// Finest step kept when recording without quantize (1/96 of a beat ≈ 6 ms at 110 bpm).
    static let fine = 1.0 / 96

    /// Wall-clock chords → loop events. The length rounds to whole bars (at least one).
    /// `grid`: snap starts and ends to it (0.25 = sixteenths); 0 keeps the timing as played.
    /// The length is whole bars from where Stop was pressed, but never shorter than the last
    /// note: a take started mid-bar used to lose its last notes.
    static func build(_ chords: [PlayedChord], notes: [PlayedNote] = [], start: Double, end: Double,
                      bpm: Int, grid: Double = 0) -> (Double, [LoopEvent]) {
        let toBeats = { (t: Double) in (t - start) * Double(bpm) / 60 }
        let step = grid > 0 ? grid : fine
        let minimum = grid > 0 ? grid : 1.0 / 16
        let place = { (b: Double) in (b / step).rounded() * step }
        let lastEnd = (chords.map { toBeats($0.end) } + notes.map { toBeats($0.end) }).max() ?? 0
        let stopBars = max(1, (toBeats(end) / beatsPerBar).rounded())
        let neededBars = ((lastEnd - 0.05) / beatsPerBar).rounded(.up)
        let length = max(stopBars, neededBars) * beatsPerBar
        func span(_ s: Double, _ e: Double) -> (Double, Double)? {
            let from = max(0, place(toBeats(s)))
            let to = min(length, max(from + minimum, place(toBeats(e))))
            return from < length && to > from ? (from, to - from) : nil
        }
        let chordEvents = chords.compactMap { c -> LoopEvent? in
            guard let (from, len) = span(c.start, c.end) else { return nil }
            var e = LoopEvent(degree: c.degree, color: c.color, octave: c.octave, accidental: c.accidental, start: from, length: len)
            e.instrument = c.instrument.map { SoundRoute.parse($0).instrument }
            e.velocity = c.velocity
            return e
        }
        let noteEvents = notes.compactMap { n -> LoopEvent? in
            guard let (from, len) = span(n.start, n.end) else { return nil }
            var e = LoopEvent(degree: 1, color: .diatonic, start: from, length: len)
            e.midi = n.midi
            e.velocity = n.velocity
            e.instrument = n.instrument.map { SoundRoute.parse($0).instrument }
            return e
        }
        return (length, link(chordEvents + noteEvents, length: length))
    }

    /// How near beat 0 a note counts as the loop's first one (when linking).
    static let firstTolerance = 0.12

    private static func same(_ a: LoopEvent, _ b: LoopEvent) -> Bool {
        if let m = a.midi { return b.midi == m }
        return b.midi == nil && a.degree == b.degree && a.accidental == b.accidental && a.octave == b.octave
    }

    /// Pairs (end note, first note) to link: a note cut by the loop's end (it started up to a
    /// bar before) and the same note again at beat 0. That's the first chord played early to
    /// flow into the next round, the way chords are joined inside the loop.
    static func linkable(_ events: [LoopEvent], length: Double) -> [(end: Int, first: Int)] {
        var pairs: [(Int, Int)] = []
        var used = Set<Int>()
        for (i, e) in events.enumerated() where e.start > firstTolerance && e.start >= length - beatsPerBar
            && e.start + e.length >= length - 1e-3 && e.start + e.length <= length + 1e-3 {
            if let j = events.indices.first(where: { !used.contains($0) && $0 != i && events[$0].start <= firstTolerance
                                                     && same(events[$0], e) }) {
                pairs.append((i, j))
                used.insert(j)
            }
        }
        return pairs
    }

    /// Joins each linkable pair into one note that starts before the end and goes on into the
    /// first bar: on every repeat it flows over the loop's seam instead of cutting and attacking again.
    static func link(_ events: [LoopEvent], length: Double) -> [LoopEvent] {
        let pairs = linkable(events, length: length)
        guard !pairs.isEmpty else { return events.sorted { $0.start < $1.start } }
        var out = events
        for (i, j) in pairs {
            let firstEnd = events[j].start + events[j].length
            out[i].length = min(length, (length - events[i].start) + firstEnd)
            out[i].velocity = max(events[i].velocity, events[j].velocity)
        }
        let drop = Set(pairs.map(\.first))
        return out.enumerated().filter { !drop.contains($0.offset) }.map(\.element).sorted { $0.start < $1.start }
    }

    /// How early the loop's first chord starts (beats before the end), for the notes that
    /// cross the seam; 0 when none does.
    static func lead(_ events: [LoopEvent], length: Double) -> Double {
        events.filter { $0.start + $0.length > length + 1e-6 }.map { length - $0.start }.max() ?? 0
    }

    /// Start the loop's first chord `lead` beats before the end (0 = on beat 1 again): the notes
    /// that cross the seam, or else the ones that start at beat 0, move their start and keep their end.
    static func setLead(_ events: [LoopEvent], length: Double, lead: Double) -> [LoopEvent] {
        let crossing = events.indices.filter { events[$0].start + events[$0].length > length + 1e-6 }
        let group = crossing.isEmpty ? events.indices.filter { events[$0].start <= firstTolerance } : crossing
        let lead = max(0, min(length / 2, lead))
        var out = events
        for i in group {
            let e = events[i]
            let start = e.start + e.length > length + 1e-6 ? e.start - length : e.start   // ≤ 0 when crossing
            let end = start + e.length
            let newStart = -lead
            guard end - newStart > 1e-3 else { continue }
            out[i].length = min(length, end - newStart)
            out[i].start = newStart < -1e-9 ? length + newStart : 0
        }
        return out.sorted { $0.start < $1.start }
    }

    /// What falls inside [start, end), re-based so `start` becomes beat 0.
    static func trim(_ events: [LoopEvent], start: Double, end: Double) -> [LoopEvent] {
        events.compactMap { e in
            let from = max(e.start, start), to = min(e.start + e.length, end)
            guard to - from > epsilon else { return nil }
            var cut = e
            cut.start = from - start
            cut.length = to - from
            return cut
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

    /// Vertical place of an event in a loop drawing, as fractions of the height (top, height):
    /// chords by degree (7 rows), notes by pitch across the loop's note range.
    static func slot(_ e: LoopEvent, in events: [LoopEvent]) -> (top: Double, height: Double) {
        guard let midi = e.midi else { return (Double(7 - e.degree) / 7, 1.0 / 7) }
        let pitches = events.compactMap(\.midi)
        let low = min(pitches.min() ?? midi, midi), high = max(pitches.max() ?? midi, midi, low + 11)
        let rows = Double(high - low + 1)
        return (Double(high - midi) / rows, 1 / rows)
    }

    /// Notes up or down by semitones (chords move with the loop's key instead).
    static func transpose(_ events: [LoopEvent], semitones: Int) -> [LoopEvent] {
        events.map { e in
            var t = e
            if let midi = e.midi { t.midi = max(0, min(127, midi + semitones)) }
            return t
        }
    }

    /// Snap starts and lengths to a grid (in beats), keeping at least one step.
    static func quantize(_ events: [LoopEvent], grid: Double, length: Double) -> [LoopEvent] {
        events.compactMap { e in
            var q = e
            q.start = (e.start / grid).rounded() * grid
            q.length = max(grid, (e.length / grid).rounded() * grid)
            guard q.start < length else { return nil }
            q.length = min(q.length, length - q.start)
            return q
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
    /// Grid for new takes: 0 = as played (default), 0.25 = sixteenths, 0.5 = eighths.
    @Published var recordQuantize = UserDefaults.standard.double(forKey: "recordQuantize") {
        didSet { UserDefaults.standard.set(recordQuantize, forKey: "recordQuantize") }
    }
    @Published var metronome = UserDefaults.standard.object(forKey: "metronome") as? Bool ?? true {
        didSet { UserDefaults.standard.set(metronome, forKey: "metronome") }
    }
    @Published private(set) var playingId: String?
    /// Mixer level of loop playback (scales the recorded velocities).
    @Published var volume = UserDefaults.standard.object(forKey: "loopsVolume") as? Double ?? 0.85 {
        didSet { UserDefaults.standard.set(volume, forKey: "loopsVolume") }
    }
    /// 0…1 inside the playing loop.
    @Published private(set) var progress = 0.0
    /// Loop the P key / ▶ button plays: last played, else newest.
    @Published private(set) var selectedId: String?

    private let engine: ChordEngine
    private let instruments: InstrumentLibrary
    private var cancellables = Set<AnyCancellable>()

    // Recorder.
    /// Wall-clock start of the take and its beat on the transport (a bar line).
    private var takeStart = 0.0
    private var takeStartBeat = 0.0
    /// Transport beat where the current take started (its bar 1), while recording.
    var recordStartBeat: Double? { recorderState == .recording ? takeStartBeat : nil }
    private var recorderJoined = false
    private var takeBpm = 110
    private var takeTonic = Note.c
    private var takeFlavor = Flavor.major
    private var captured: [PlayedChord] = []
    private var capturedNotes: [PlayedNote] = []
    private var takeInstrument = InstrumentLibrary.synthId
    private var nextBeat = 0
    private var recordTimer: Timer?

    // Player.
    private var playing: Loop?
    /// Transport beat where the loop's beat 0 falls (a bar line), and how far events are handed out.
    private var anchorBeat = 0.0
    private var scheduledBeat = 0.0
    private var lastProgress = 0.0
    private var sounding = Set<Int>()
    private var playTimer: Timer?
    /// Events go to the sound engine this far ahead with their exact time, so a main thread
    /// busy drawing (measured p99 ≈ 45 ms) no longer delays them.
    private static let lookahead = 0.06

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("loops.json")
    }

    init(engine: ChordEngine, instruments: InstrumentLibrary) {
        self.engine = engine
        self.instruments = instruments
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
        engine.onNotePlayed { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.recorderState == .recording else { return }
                self.capturedNotes.append(note)
            }
        }
        // The take begins with the first chord or note after arming.
        engine.$held
            .receive(on: RunLoop.main)
            .sink { [weak self] held in
                if self?.recorderState == .armed, !held.isEmpty { self?.begin() }
            }
            .store(in: &cancellables)
        engine.$heldNotes
            .receive(on: RunLoop.main)
            .sink { [weak self] notes in
                if self?.recorderState == .armed, !notes.isEmpty { self?.begin() }
            }
            .store(in: &cancellables)
    }

    var selected: Loop? { loops.first { $0.id == selectedId } ?? loops.first }
    var isRecording: Bool { recorderState != .idle }
    var isPlaying: Bool { playingId != nil }

    // MARK: Library

    /// Loop open in the editor.
    @Published var studioId: String?

    /// Effects being auditioned in the editor, before saving.
    private var previewEffects: [String: Effects] = [:]

    func effects(for id: String) -> Effects? { previewEffects[id] ?? loops.first { $0.id == id }?.effects }

    func preview(effects: Effects?, for id: String) {
        previewEffects[id] = effects
        instruments.effectsChanged(bus: "loop:\(id)")
    }

    /// Save an edited loop over the original (or as itself when it is new).
    func save(_ edited: Loop) {
        guard let i = loops.firstIndex(where: { $0.id == edited.id }) else { return }
        let wasPlaying = playingId == edited.id
        loops[i] = edited
        previewEffects[edited.id] = nil
        persist()
        instruments.effectsChanged(bus: "loop:\(edited.id)")
        if wasPlaying { play(loops[i]) }
    }

    /// A copy right below the original, named "<name> (copia)".
    @discardableResult
    func duplicate(_ id: String) -> Loop? {
        guard let i = loops.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = loops[i]
        copy.id = UUID().uuidString
        copy.name = tr("%@ (copia)", loops[i].name)
        copy.createdAt = Date()
        loops.insert(copy, at: i + 1)
        selectedId = copy.id
        persist()
        return copy
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = loops.firstIndex(where: { $0.id == id }) else { return }
        loops[i].name = trimmed
        persist()
    }

    /// Opening a project: its loops replace these.
    func replaceAll(_ new: [Loop]) {
        stopPlayback()
        loops = new
        selectedId = new.first?.id
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
            capturedNotes = []
            recorderState = .armed
            if !engine.held.isEmpty || !engine.heldNotes.isEmpty { begin() }
        case .armed:
            resetRecorder()
        case .recording:
            finishTake()
        }
    }

    private func begin() {
        recorderState = .recording
        // The take starts at the first note (it arrived a moment before this runs). With drums or
        // a loop playing, it starts on their bar line instead, so the loop lines up with them; a
        // note up to half a beat early still counts as that downbeat.
        let first = (engine.heldChords().map(\.start) + engine.heldNotesPlayed().map(\.start)).min() ?? now()
        // The recorder stays on the transport until the take ends, so drums stopped and restarted
        // meanwhile keep the same grid.
        if Transport.shared.isRunning {
            let beat = Transport.shared.beat(at: first)
            takeStartBeat = ((beat + 0.5) / LoopMath.beatsPerBar).rounded(.down) * LoopMath.beatsPerBar
            _ = Transport.shared.join("recorder")
        } else {
            takeStartBeat = Transport.shared.join("recorder", downbeat: first)
        }
        recorderJoined = true
        takeStart = Transport.shared.time(ofBeat: takeStartBeat)
        takeBpm = engine.bpm
        takeTonic = engine.tonic
        takeFlavor = engine.flavor
        takeInstrument = instruments.selectedId
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
        let transport = Transport.shared.snapshot
        let t = now()
        elapsedBeats = max(0, transport.beat(at: t) - takeStartBeat)
        // Clicks on the transport's beats, handed to the synth ahead with their exact time.
        let horizon = transport.beat(at: t + Self.lookahead) - takeStartBeat
        while Double(nextBeat) <= horizon {
            let at = transport.time(ofBeat: takeStartBeat + Double(nextBeat))
            if metronome, at > t - 0.03 { Synth.shared.click(accent: nextBeat % Int(LoopMath.beatsPerBar) == 0, at: at) }
            nextBeat += 1
        }
    }

    private func finishTake() {
        let end = now()
        let chords = (captured + engine.heldChords(end: end)).map {
            PlayedChord(degree: $0.degree, color: $0.color, octave: $0.octave, accidental: $0.accidental,
                        start: max($0.start, takeStart), end: $0.end, instrument: $0.instrument,
                        velocity: $0.velocity)
        }
        let notes = (capturedNotes + engine.heldNotesPlayed(end: end)).map {
            PlayedNote(midi: $0.midi, velocity: $0.velocity, start: max($0.start, takeStart), end: $0.end,
                       instrument: $0.instrument)
        }
        let start = takeStart, bpm = takeBpm, tonic = takeTonic, flavor = takeFlavor, instrument = takeInstrument
        resetRecorder()
        guard !chords.isEmpty || !notes.isEmpty else { return }
        let (length, events) = LoopMath.build(chords, notes: notes, start: start, end: end, bpm: bpm,
                                              grid: recordQuantize)
        let loop = Loop(id: UUID().uuidString, name: nextName(), createdAt: Date(), bpm: bpm, tonic: tonic,
                        flavor: flavor, lengthBeats: length, events: events, instrument: instrument)
        loops.insert(loop, at: 0)
        selectedId = loop.id
        persist()
    }

    private func resetRecorder() {
        recordTimer?.invalidate()
        recordTimer = nil
        if recorderJoined { Transport.shared.leave("recorder") }
        recorderJoined = false
        captured = []
        capturedNotes = []
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

    /// Plays in the key, mode and tempo it was recorded in (the tempo only when nothing else is
    /// playing: drums keep theirs); follows live changes after that. Starts on the next bar line
    /// of whatever already plays.
    func play(_ loop: Loop) {
        stopPlayback()
        engine.tonic = loop.tonic
        engine.flavor = loop.flavor
        if !Transport.shared.isRunning { engine.setBpm(loop.bpm) }
        for id in Set(loop.events.compactMap(\.instrument) + [loop.instrument ?? instruments.selectedId]) {
            _ = instruments.player(for: SoundRoute.make(id, bus: "loop:\(loop.id)"))
        }
        playing = loop
        playingId = loop.id
        anchorBeat = Transport.shared.join("loops")
        scheduledBeat = anchorBeat - 1e-9
        lastProgress = 0
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
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
        if let loop = playing {
            for i in sounding { engine.endLoopChord(id: chordId(loop, i)) }
            Transport.shared.leave("loops")
        }
        sounding.removeAll()
        playing = nil
        playingId = nil
        progress = 0
    }

    private func chordId(_ loop: Loop, _ index: Int) -> String { "loop:\(loop.id):\(index)" }

    /// Hands out the loop's note-ons and note-offs that fall in the next `lookahead`, each with
    /// its exact host time on the transport, and moves the progress bar (~30 per second).
    private func playTick() {
        guard let loop = playing, loop.lengthBeats > 0 else { return }
        let transport = Transport.shared.snapshot
        let t = now()
        let nowBeat = transport.beat(at: t)
        let length = loop.lengthBeats
        let position = nowBeat < anchorBeat ? 0 : (nowBeat - anchorBeat).truncatingRemainder(dividingBy: length)
        if abs(position / length - lastProgress) * length * 60 / transport.bpm > 1.0 / 30 || position / length < lastProgress {
            lastProgress = position / length
            progress = lastProgress
        }

        // Main thread stalled for long (sleep, debugger): drop what was missed instead of piling it up.
        if scheduledBeat < nowBeat - 1 { scheduledBeat = nowBeat }
        let from = scheduledBeat, to = transport.beat(at: t + Self.lookahead)
        guard to > from else { return }
        scheduledBeat = to

        // (beat, on?, index) in (from, to], offs before ons on the same beat.
        var due: [(beat: Double, on: Bool, index: Int)] = []
        let firstCycle = Int(((from - anchorBeat) / length).rounded(.down))
        let lastCycle = Int(((to - anchorBeat) / length).rounded(.down))
        // A note may cross the loop's end (a chord played early that flows into the first
        // bar): it keeps sounding into the next cycle, and the very first cycle starts with
        // its tail. Cycle −1 stands for that tail; the previous cycle can still owe note-offs.
        if lastCycle >= 0 {
            for cycle in max(-1, firstCycle - 1)...lastCycle {
                let base = anchorBeat + Double(cycle) * length
                for (i, event) in loop.events.enumerated() {
                    var on = base + event.start
                    let off = base + event.start + min(length, event.length)
                    if cycle < 0 {
                        guard off > anchorBeat else { continue }
                        on = anchorBeat
                    }
                    if on > from && on <= to { due.append((on, true, i)) }
                    if off > from && off <= to { due.append((off, false, i)) }
                }
            }
        }
        due.sort { $0.beat != $1.beat ? $0.beat < $1.beat : (!$0.on && $1.on) }

        for item in due {
            let at = transport.time(ofBeat: item.beat)
            let event = loop.events[item.index]
            if !item.on {
                guard sounding.remove(item.index) != nil else { continue }
                engine.endLoopChord(id: chordId(loop, item.index), at: at)
                continue
            }
            guard !sounding.contains(item.index) else { continue }
            let instrument = SoundRoute.make(event.instrument ?? loop.instrument ?? instruments.selectedId,
                                             bus: "loop:\(loop.id)")
            // Volume is gain on the loop's sampler (velocity picks the sample layer, so scaling
            // it changes the timbre); only the synth still takes volume through velocity.
            let sampled = !InstrumentLibrary.isSynth(SoundRoute.parse(instrument).instrument)
            instruments.player(for: instrument)?.setLevel(volume / 0.85)
            let velocity = min(127, sampled ? event.velocity
                                            : max(1, Int((Double(event.velocity) * volume / 0.85).rounded())))
            if let midi = event.midi {
                engine.startLoopNote(id: chordId(loop, item.index), midi: midi, velocity: velocity,
                                     instrument: instrument, at: at)
            } else {
                engine.startLoopChord(id: chordId(loop, item.index), degree: event.degree, color: event.color,
                                      octave: event.octave, accidental: event.accidental, instrument: instrument,
                                      velocity: velocity, at: at)
            }
            sounding.insert(item.index)
        }
    }
}
