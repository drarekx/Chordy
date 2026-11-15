import AVFoundation
import Combine
import Foundation
import QuartzCore
import os

// MARK: - Model

/// The eight drum lanes, with their General MIDI notes.
enum DrumTrack: Int, CaseIterable, Codable {
    case kick, snare, clap, closedHat, openHat, lowTom, highTom, crash

    /// Default GM note.
    var note: UInt8 { variants[0].note }

    /// Sounds of the kit this lane can use (GM drum map).
    var variants: [(note: UInt8, name: String)] {
        switch self {
        case .kick: return [(36, tr("Bombo 1")), (35, tr("Bombo 2"))]
        case .snare: return [(38, tr("Caja 1")), (40, tr("Caja 2")), (37, tr("Aro"))]
        case .clap: return [(39, tr("Palmas")), (54, tr("Pandereta")), (56, tr("Cencerro"))]
        case .closedHat: return [(42, tr("Charles cerrado")), (44, tr("Charles pedal"))]
        case .openHat: return [(46, tr("Charles abierto")), (51, tr("Ride")), (53, tr("Campana ride"))]
        case .lowTom: return [(45, tr("Tom grave")), (41, tr("Tom base")), (43, tr("Tom base agudo"))]
        case .highTom: return [(50, tr("Tom agudo")), (48, tr("Tom medio")), (47, tr("Tom medio grave"))]
        case .crash: return [(49, tr("Crash 1")), (57, tr("Crash 2")), (55, tr("Splash")), (52, tr("China"))]
        }
    }

    var label: String {
        switch self {
        case .kick: return tr("Bombo")
        case .snare: return tr("Caja")
        case .clap: return tr("Palmas")
        case .closedHat: return tr("Charles")
        case .openHat: return tr("Charles abierto")
        case .lowTom: return tr("Tom grave")
        case .highTom: return tr("Tom agudo")
        case .crash: return tr("Crash")
        }
    }

    var short: String {
        switch self {
        case .kick: return "BD"
        case .snare: return "SD"
        case .clap: return "CP"
        case .closedHat: return "CH"
        case .openHat: return "OH"
        case .lowTom: return "LT"
        case .highTom: return "HT"
        case .crash: return "CR"
        }
    }
}

/// One bar of sixteenths: `steps[track][step]` is the velocity, 0 = off.
struct DrumPattern: Codable, Identifiable, Equatable {
    static let stepCount = 16
    static let names = ["A", "B", "C", "D", "E", "F", "G", "H"]
    static let lanes = DrumTrack.allCases.count

    var id: String
    var kit: String
    var steps: [[Int]]
    /// 0…0.5 of a sixteenth: delays the off-beat steps.
    var swing: Double
    var volume: Double
    /// Short description shown under the letter ("Base", "Relleno").
    var title: String?
    /// Per-lane level (0…1) and GM note; nil = defaults.
    var laneVolumes: [Double]?
    var laneNotes: [Int]?

    static func empty(_ id: String) -> DrumPattern {
        DrumPattern(id: id, kit: "gu:kit:808", steps: Array(repeating: Array(repeating: 0, count: stepCount), count: lanes),
                    swing: 0, volume: 0.9)
    }

    /// A starter beat for pattern A, so ▶ plays something on the first try.
    static func starter() -> DrumPattern {
        var p = empty("A")
        p.title = tr("Base")
        for s in [0, 8, 10] { p.steps[DrumTrack.kick.rawValue][s] = 110 }
        for s in [4, 12] { p.steps[DrumTrack.snare.rawValue][s] = 105 }
        for s in stride(from: 0, to: 16, by: 2) { p.steps[DrumTrack.closedHat.rawValue][s] = s % 4 == 0 ? 90 : 65 }
        p.steps[DrumTrack.openHat.rawValue][14] = 80
        return p
    }

    var isEmpty: Bool { steps.allSatisfy { $0.allSatisfy { $0 == 0 } } }

    func laneVolume(_ track: DrumTrack) -> Double { laneVolumes?[safe: track.rawValue] ?? 0.85 }
    func laneNote(_ track: DrumTrack) -> UInt8 { laneNotes?[safe: track.rawValue].map { UInt8($0) } ?? track.note }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Clock (audio-side)

/// Fires the bars from a 1 ms timer on its own queue, so the beat doesn't wobble when the
/// main thread is busy drawing. Talks straight to its own sampler. Each bar is a pattern
/// already mixed (velocities scaled, muted lanes empty); a chain is several bars in a row.
final class DrumClock: @unchecked Sendable {
    struct Bar {
        var steps: [[Int]]
        var notes: [UInt8]
        var swing: Double
    }

    struct State {
        var playing = false
        var bars: [Bar] = []
        var bpm = 110.0
        /// Grid time of the next step (before swing) and its index (counts up forever).
        var gridTime = 0.0
        var next = 0
        /// The sampler is detached while a kit loads: steps advance silently.
        var loading = false
    }

    let sampler = AVAudioUnitSampler()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "chordy.drums", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    /// Called on the main queue with the bar and step that just played.
    var onStep: ((Int, Int) -> Void)?

    init() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }

    func start(bars: [Bar], bpm: Double) {
        state.withLock {
            $0.bars = bars
            $0.bpm = bpm
            $0.gridTime = CACurrentMediaTime() + 0.02
            $0.next = 0
            $0.playing = true
        }
    }

    func stop() { state.withLock { $0.playing = false } }

    /// Step nearest to `time` (for live recording), 0…15.
    func nearestStep(at time: Double) -> Int {
        state.withLock { s in
            let dur = 60 / s.bpm / 4
            let offset = Int(((time - s.gridTime) / dur).rounded())
            return ((s.next + offset) % DrumPattern.stepCount + DrumPattern.stepCount) % DrumPattern.stepCount
        }
    }

    func hit(_ note: UInt8, velocity: UInt8) {
        guard !state.withLock({ $0.loading }) else { return }
        sampler.startNote(note, withVelocity: velocity, onChannel: 9)
        let sampler = self.sampler
        queue.asyncAfter(deadline: .now() + 0.4) { sampler.stopNote(note, onChannel: 9) }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let (fire, played) = state.withLock { s -> ([(UInt8, UInt8)], (Int, Int)?) in
            var fire: [(UInt8, UInt8)] = []
            var played: (Int, Int)?
            guard s.playing, !s.bars.isEmpty else { return (fire, played) }
            let dur = 60 / s.bpm / 4
            while true {
                let index = s.next % DrumPattern.stepCount
                let barIndex = (s.next / DrumPattern.stepCount) % s.bars.count
                let bar = s.bars[barIndex]
                let swing = index % 2 == 1 ? bar.swing * dur : 0
                guard s.gridTime + swing <= now else { break }
                if !s.loading {
                    for (lane, row) in bar.steps.enumerated() where row[index] > 0 {
                        fire.append((bar.notes[lane], UInt8(min(127, row[index]))))
                    }
                }
                played = (barIndex, index)
                s.next += 1
                s.gridTime += dur
                // Fell far behind (sleep, debugger): skip ahead instead of machine-gunning.
                if now - s.gridTime > 0.25 { s.gridTime = now }
            }
            return (fire, played)
        }
        for (note, velocity) in fire { hit(note, velocity: velocity) }
        if let played, let onStep { DispatchQueue.main.async { onStep(played.0, played.1) } }
    }
}

// MARK: - Drum machine

/// Eight patterns (A–H) saved in `~/Library/Application Support/Chordy/drums.json`, the step
/// sequencer that plays them (one, or a chain of them), live pad playing and recording.
@MainActor
final class DrumMachine: ObservableObject {
    /// What the Launchkey pads do.
    enum PadMode: String, CaseIterable { case chords, steps, play }

    @Published private(set) var patterns: [DrumPattern]
    @Published var selected = 0 { didSet { if selected != oldValue { patternChanged(restartKit: true) } } }
    @Published var track = DrumTrack.kick
    @Published private(set) var playing = false
    @Published private(set) var recording = false
    @Published private(set) var step: Int?
    /// Pattern sounding now (differs from `selected` while a chain plays).
    @Published private(set) var playingPattern: Int?
    /// Position in the chain sounding now.
    @Published private(set) var chainPosition: Int?
    @Published var padMode = PadMode(rawValue: UserDefaults.standard.string(forKey: "padMode") ?? "") ?? .chords {
        didSet { UserDefaults.standard.set(padMode.rawValue, forKey: "padMode") }
    }
    /// Last pad hit per track, for a flash on the pads and the grid.
    @Published private(set) var flash: Set<DrumTrack> = []
    /// Performance switches (not saved): silenced lanes and the solo lane.
    @Published private(set) var muted: Set<DrumTrack> = []
    @Published private(set) var solo: DrumTrack?
    /// Patterns played in order, one bar each, when `chainOn`.
    @Published private(set) var chain: [Int] = (UserDefaults.standard.array(forKey: "drumChain") as? [Int]) ?? [] {
        didSet { UserDefaults.standard.set(chain, forKey: "drumChain"); refreshClock() }
    }
    @Published var chainOn = UserDefaults.standard.bool(forKey: "drumChainOn") {
        didSet { UserDefaults.standard.set(chainOn, forKey: "drumChainOn"); refreshClock() }
    }

    private let engine: ChordEngine
    private let instruments: InstrumentLibrary
    private let clock = DrumClock()
    private var attached = false
    private var loadedKit: String?
    private var kitGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drums.json")
    }

    /// Kits to choose from: drum instruments whose bank is on disk (macOS's is always there).
    var kits: [Instrument] {
        Instrument.all.filter { i in
            i.group == .drums && (InstrumentPack.with(i.pack).map { instruments.fileURL($0) != nil } ?? false)
        }
    }

    init(engine: ChordEngine, instruments: InstrumentLibrary) {
        self.engine = engine
        self.instruments = instruments
        let saved = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode([DrumPattern].self, from: $0) }
        var list = saved ?? []
        for (i, name) in DrumPattern.names.enumerated() where i >= list.count {
            list.append(i == 0 && saved == nil ? .starter() : .empty(name))
        }
        patterns = Array(list.prefix(DrumPattern.names.count))
        clock.onStep = { [weak self] bar, step in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step = step
                let order = self.playOrder
                let position = bar % max(1, order.count)
                if self.chainPosition != position { self.chainPosition = position }
                if self.playingPattern != order[position] { self.playingPattern = order[position] }
            }
        }
        engine.$bpm.sink { [weak self] bpm in self?.clock.update { $0.bpm = Double(bpm) } }.store(in: &cancellables)
    }

    var pattern: DrumPattern { patterns[selected] }

    /// What the clock plays: the chain (when on and not empty) or the selected pattern.
    private var playOrder: [Int] { chainOn && !chain.isEmpty ? chain : [selected] }

    /// A pattern as the clock plays it: lane volumes applied, muted/solo lanes silenced.
    private func bar(_ index: Int) -> DrumClock.Bar {
        let p = patterns[index]
        let steps = DrumTrack.allCases.map { track -> [Int] in
            let silent = muted.contains(track) || (solo != nil && solo != track)
            let gain = p.laneVolume(track) / 0.85
            return p.steps[track.rawValue].map { v in
                guard v > 0, !silent else { return 0 }
                return max(1, min(127, Int((Double(v) * gain).rounded())))
            }
        }
        return DrumClock.Bar(steps: steps, notes: DrumTrack.allCases.map { p.laneNote($0) }, swing: p.swing)
    }

    private func refreshClock() {
        let bars = playOrder.map(bar)
        clock.update { $0.bars = bars }
    }

    // MARK: Transport

    func togglePlay() { playing ? stop() : play() }

    func play() {
        prepareKit()
        clock.start(bars: playOrder.map(bar), bpm: Double(engine.bpm))
        playing = true
    }

    func stop() {
        clock.stop()
        playing = false
        recording = false
        step = nil
        playingPattern = nil
        chainPosition = nil
    }

    /// ● in drum modes: record pad hits into the pattern while it plays (starts it if stopped).
    func toggleRecord() {
        recording.toggle()
        if recording && !playing { play() }
    }

    /// Launch another pattern; it takes over on the next step, keeping the groove.
    func launch(_ index: Int) {
        guard patterns.indices.contains(index) else { return }
        selected = index
        if !playing { play() }
    }

    // MARK: Editing

    func toggleStep(_ track: DrumTrack, _ step: Int, accent: Bool = false) {
        edit { p in
            let v = p.steps[track.rawValue][step]
            p.steps[track.rawValue][step] = v > 0 && !accent ? 0 : (accent ? 127 : 100)
        }
    }

    func setVelocity(_ track: DrumTrack, _ step: Int, _ velocity: Int) {
        edit { $0.steps[track.rawValue][step] = max(0, min(127, velocity)) }
    }

    /// Track ◀ ▶ in drum modes.
    func selectTrack(_ step: Int) {
        let all = DrumTrack.allCases
        track = all[((track.rawValue + step) % all.count + all.count) % all.count]
    }

    func clear() { edit { p in p = .empty(p.id).with(kit: p.kit) } }

    func setKit(_ id: String) { edit { $0.kit = id } }
    func setSwing(_ value: Double) { edit { $0.swing = min(0.5, max(0, value)) } }
    func setVolume(_ value: Double) { edit { $0.volume = min(1, max(0, value)) } }

    func setTitle(_ index: Int, _ title: String) {
        guard patterns.indices.contains(index) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        patterns[index].title = t.isEmpty ? nil : String(t.prefix(16))
        persist()
    }

    func setLaneVolume(_ track: DrumTrack, _ value: Double) {
        edit { p in
            var v = p.laneVolumes ?? Array(repeating: 0.85, count: DrumPattern.lanes)
            v[track.rawValue] = min(1, max(0, value))
            p.laneVolumes = v
        }
    }

    func setLaneNote(_ track: DrumTrack, _ note: UInt8) {
        edit { p in
            var n = p.laneNotes ?? DrumTrack.allCases.map { Int($0.note) }
            n[track.rawValue] = Int(note)
            p.laneNotes = n
        }
        hit(track, velocity: 100)
    }

    /// Copy the selected pattern over another slot (keeps that slot's letter).
    func copy(to index: Int) {
        guard patterns.indices.contains(index), index != selected else { return }
        var p = pattern
        p.id = patterns[index].id
        patterns[index] = p
        persist()
        refreshClock()
    }

    // MARK: Lane tools

    /// Hit every `every` steps (1 = all), starting at `offset`.
    func fill(_ track: DrumTrack, every: Int, offset: Int = 0) {
        edit { p in
            for s in 0..<DrumPattern.stepCount {
                p.steps[track.rawValue][s] = s >= offset && (s - offset) % every == 0 ? (s % 4 == 0 ? 110 : 90) : 0
            }
        }
    }

    /// Rotate the lane by one step (wraps around).
    func shift(_ track: DrumTrack, by delta: Int) {
        edit { p in
            let lane = p.steps[track.rawValue]
            let n = lane.count
            p.steps[track.rawValue] = (0..<n).map { lane[((($0 - delta) % n) + n) % n] }
        }
    }

    /// A random lane, denser on the beat.
    func randomize(_ track: DrumTrack) {
        edit { p in
            p.steps[track.rawValue] = (0..<DrumPattern.stepCount).map { s in
                let chance = s % 4 == 0 ? 0.6 : (s % 2 == 0 ? 0.35 : 0.18)
                return Double.random(in: 0..<1) < chance ? Int.random(in: 60...120) : 0
            }
        }
    }

    func clearLane(_ track: DrumTrack) {
        edit { $0.steps[track.rawValue] = Array(repeating: 0, count: DrumPattern.stepCount) }
    }

    // MARK: Mute, solo, chain

    func toggleMute(_ track: DrumTrack) {
        if muted.contains(track) { muted.remove(track) } else { muted.insert(track) }
        refreshClock()
    }

    func toggleSolo(_ track: DrumTrack) {
        solo = solo == track ? nil : track
        refreshClock()
    }

    func appendToChain(_ index: Int) { if chain.count < 64 { chain.append(index) } }
    func removeFromChain(at position: Int) { if chain.indices.contains(position) { chain.remove(at: position) } }
    func clearChain() { chain = [] }

    private func edit(_ body: (inout DrumPattern) -> Void) {
        var p = patterns[selected]
        body(&p)
        guard p != patterns[selected] else { return }
        let kitChanged = p.kit != patterns[selected].kit
        patterns[selected] = p
        persist()
        patternChanged(restartKit: kitChanged)
    }

    private func patternChanged(restartKit: Bool) {
        if restartKit { prepareKit() }
        refreshClock()
        clock.sampler.volume = Float(pattern.volume)
    }

    // MARK: Pads

    /// A drum hit from a pad (Play mode) or the panel: sounds now, and lands on the nearest
    /// step when recording.
    func hit(_ track: DrumTrack, velocity: Int) {
        prepareKit()
        clock.hit(pattern.laneNote(track), velocity: SamplerPlayer.curve(velocity))
        flash.insert(track)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.flash.remove(track) }
        if recording && playing {
            let step = clock.nearestStep(at: CACurrentMediaTime())
            edit { $0.steps[track.rawValue][step] = max(1, min(127, velocity)) }
        }
    }

    // MARK: Sound

    /// Loads the pattern's kit with the sampler detached (loading into a rendering sampler
    /// crashes CoreAudio), then attaches it again.
    private func prepareKit() {
        let kitId = kits.contains { $0.id == pattern.kit } ? pattern.kit : (kits.first?.id ?? "macos:kit")
        guard kitId != loadedKit, let kit = Instrument.with(kitId), let pack = InstrumentPack.with(kit.pack),
              let url = instruments.fileURL(pack) else { return }
        loadedKit = kitId
        kitGeneration += 1
        let generation = kitGeneration
        clock.update { $0.loading = true }
        if attached {
            Synth.shared.detach(clock.sampler)
            attached = false
        }
        let sampler = clock.sampler
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try sampler.loadSoundBankInstrument(at: url, program: kit.program, bankMSB: kit.bankMSB, bankLSB: 0)
            } catch {
                NSLog("Chordy: could not load drum kit \(kitId): \(error)")
            }
            DispatchQueue.main.async {
                guard generation == self.kitGeneration else { return }
                Synth.shared.attach(sampler)
                self.attached = true
                sampler.volume = Float(self.pattern.volume)
                self.clock.update { $0.loading = false }
            }
        }
    }

    private func persist() {
        do {
            try JSONEncoder().encode(patterns).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Chordy: could not save drum patterns: \(error)")
        }
    }
}

private extension DrumPattern {
    func with(kit: String) -> DrumPattern {
        var p = self
        p.kit = kit
        return p
    }
}
