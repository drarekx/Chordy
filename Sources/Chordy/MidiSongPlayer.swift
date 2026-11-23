import Combine
import Foundation
import QuartzCore

/// Plays the MIDI song open in «Repertorio»: every track with its General MIDI instrument
/// (GeneralUser when downloaded, else the bank in macOS), notes scheduled a little ahead with
/// their exact time. Its own clock, so the speed can change for practice without touching
/// Chordy's tempo.
///
/// Practice: the notes of one track are left to the player. The song stops at each of them
/// and goes on when they are played (any octave, unless `exactOctave`).
@MainActor
final class MidiSongPlayer: ObservableObject {
    @Published private(set) var playing = false
    /// Song position in beats (~30 times a second while playing).
    @Published private(set) var beat = 0.0
    /// Practice: waiting for these notes (pitches, transposed).
    @Published private(set) var expected: Set<Int> = []
    @Published var speed = UserDefaults.standard.object(forKey: "midiSpeed") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "midiSpeed")
            if playing { restartClock() }
        }
    }
    /// Track the player plays (practice), or nil.
    @Published var practiceTrack: Int? { didSet { if practiceTrack != oldValue { practiceChanged() } } }
    @Published var exactOctave = UserDefaults.standard.bool(forKey: "midiExactOctave") {
        didSet { UserDefaults.standard.set(exactOctave, forKey: "midiExactOctave") }
    }
    /// Tracks not played.
    @Published var muted: Set<Int> = [] { didSet { if playing { silenceMuted() } } }

    private(set) var sheetId: String?
    private(set) var score: MidiScore?
    private(set) var transpose = 0

    private let engine: ChordEngine
    private let instruments: InstrumentLibrary
    private var timer: Timer?
    // Clock: beat(t) = fromBeat + (t − startTime) · bpm / 60.
    private var startTime = 0.0
    private var fromBeat = 0.0
    private var scheduledTo = 0.0
    private var next: [Int] = []
    private var pendingOffs: [(voice: Int, end: Double, track: Int)] = []
    private var lastPublish = 0.0
    // Practice.
    private var groups: [(beat: Double, pitches: Set<Int>)] = []
    private var group = 0
    private var lastAttack: [Int: Double] = [:]
    private var lastHeld: Set<Int> = []
    private var passedAt = 0.0
    private static let lookahead = 0.06
    private static let lead = 0.03

    init(engine: ChordEngine, instruments: InstrumentLibrary) {
        self.engine = engine
        self.instruments = instruments
    }

    var bpm: Double { (score?.bpm ?? 120) * speed }
    var waiting: Bool { !expected.isEmpty }

    /// The open song (nil: none or not MIDI). Another song stops what's playing.
    func load(_ id: String?, score: MidiScore?, transpose: Int) {
        if id != sheetId || score != self.score {
            stop()
            sheetId = id
            self.score = score
            muted = []
            practiceTrack = nil
            beat = 0
            if score != nil { preload() }
        }
        if transpose != self.transpose {
            self.transpose = transpose
            if playing { play(from: beatNow()) }
        }
    }

    /// Position now, for drawing (between the published updates).
    func beatNow() -> Double {
        guard playing, !waiting else { return beat }
        return fromBeat + (CACurrentMediaTime() - startTime) * bpm / 60
    }

    func toggle() { playing ? stop() : play(from: beat >= (score?.lengthBeats ?? 0) ? 0 : beat) }

    func rewind() {
        if playing { play(from: 0) } else { beat = 0 }
    }

    func seek(_ b: Double) {
        let b = max(0, min(b, score?.lengthBeats ?? 0))
        if playing { play(from: b) } else { beat = b }
    }

    func play(from b: Double) {
        guard let score else { return }
        stopSounding()
        timer?.invalidate()
        Synth.shared.start()
        preload()
        fromBeat = b
        startTime = CACurrentMediaTime() + Self.lead
        scheduledTo = b
        beat = b
        next = score.tracks.map { t in t.notes.firstIndex { $0.start >= b - 1e-6 } ?? t.notes.count }
        buildGroups(from: b)
        expected = []
        passedAt = CACurrentMediaTime()
        playing = true
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopSounding()
        expected = []
        if playing { beat = beatNow() }
        playing = false
    }

    // MARK: Sound

    /// Sound of a track: its General MIDI program in the best bank available.
    func route(_ track: MidiScore.Track) -> String {
        let pack = instruments.fileURL(.generalUser) != nil ? InstrumentPack.generalUser : InstrumentPack.system
        return SoundRoute.make(Instrument.generalMidi(program: track.program, drums: track.drums, pack: pack), bus: "midi")
    }

    /// Samplers loaded before the first note (loading takes a moment; notes meanwhile are silent).
    private func preload() {
        guard let score else { return }
        for t in score.tracks { _ = instruments.player(for: route(t)) }
    }

    private func stopSounding() {
        for off in pendingOffs { engine.output.noteOff(off.voice, pedal: false) }
        pendingOffs.removeAll()
    }

    private func silenceMuted() {
        let now = CACurrentMediaTime()
        pendingOffs.removeAll { off in
            guard muted.contains(off.track) || off.track == practiceTrack else { return false }
            engine.output.noteOff(off.voice, pedal: false, at: now)
            return true
        }
    }

    private func restartClock() {
        let b = beatNow()
        fromBeat = b
        startTime = CACurrentMediaTime()
        scheduledTo = max(scheduledTo, b)
    }

    private func time(of b: Double) -> Double { startTime + (b - fromBeat) * 60 / bpm }

    private func tick() {
        guard let score else { return stop() }
        let now = CACurrentMediaTime()
        trackAttacks(now)
        if waiting {
            if practicePlayed() { pass(now) } else { return }
        }
        let current = fromBeat + (now - startTime) * bpm / 60
        if now - lastPublish > 1.0 / 30 {
            beat = max(fromBeat, current)
            lastPublish = now
        }
        if current >= score.lengthBeats {
            stop()
            beat = score.lengthBeats
            return
        }
        var horizon = fromBeat + (now + Self.lookahead - startTime) * bpm / 60
        // Practice: nothing past the next notes to play until they're played.
        if practiceTrack != nil, group < groups.count {
            let g = groups[group].beat
            if current >= g - 1e-3 {
                fromBeat = g
                startTime = now
                beat = g
                expected = groups[group].pitches
                horizon = g
            }
            horizon = min(horizon, g)
        }
        pendingOffs.removeAll { off in
            guard off.end <= horizon else { return false }
            engine.output.noteOff(off.voice, pedal: false, at: time(of: off.end))
            return true
        }
        guard horizon > scheduledTo else { return }
        for (i, track) in score.tracks.enumerated() {
            let silent = muted.contains(track.id) || track.id == practiceTrack
            let shift = track.drums ? 0 : transpose
            let inst = route(track)
            while next[i] < track.notes.count, track.notes[next[i]].start < horizon {
                let n = track.notes[next[i]]
                next[i] += 1
                guard !silent, n.start >= scheduledTo - 1e-6 else { continue }
                let pitch = n.pitch + shift
                guard (0...127).contains(pitch) else { continue }
                let voice = engine.output.noteOn(midi: pitch, velocity: n.velocity, instrument: inst, at: time(of: n.start))
                pendingOffs.append((voice, n.start + max(0.05, n.length), track.id))
            }
        }
        scheduledTo = horizon
    }

    // MARK: Practice

    private func practiceChanged() {
        if playing { play(from: beatNow()) } else { expected = [] }
    }

    private func buildGroups(from b: Double) {
        groups = []
        group = 0
        guard let score, let p = practiceTrack, let track = score.tracks.first(where: { $0.id == p }) else { return }
        for n in track.notes where n.start >= b - 1e-6 {
            let pitch = n.pitch + (track.drums ? 0 : transpose)
            if let last = groups.last, n.start - last.beat < 0.08 {
                groups[groups.count - 1].pitches.insert(pitch)
            } else {
                groups.append((n.start, [pitch]))
            }
        }
    }

    /// What the player holds now: single notes and the notes of their chords.
    private var held: Set<Int> {
        var set = Set(engine.heldNotes.values.map(\.midi))
        for chord in engine.sounding where chord.source == .user { set.formUnion(chord.notes) }
        return set
    }

    private func trackAttacks(_ now: Double) {
        let h = held
        for p in h.subtracting(lastHeld) { lastAttack[p] = now }
        lastHeld = h
    }

    /// Every expected note held, and pressed since the last ones were played.
    private func practicePlayed() -> Bool {
        let fresh = lastHeld.filter { (lastAttack[$0] ?? 0) > passedAt - 0.15 }
        if exactOctave { return expected.isSubset(of: fresh) }
        let pcs = Set(fresh.map { $0 % 12 })
        return expected.allSatisfy { pcs.contains($0 % 12) }
    }

    private func pass(_ now: Double) {
        expected = []
        group += 1
        passedAt = now
        // The clock goes on from the notes just played.
        startTime = now + 0.005
    }
}
