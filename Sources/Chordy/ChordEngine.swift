import Combine
import Foundation
import QuartzCore

/// Who triggered a chord: the player (keys, pads, MIDI) or loop playback.
enum ChordSource { case user, loop }

/// A finished chord on the scrolling display. `row` is the degree.
struct ChordEvent {
    let row: Degree
    /// Semitones above the row (chromatic chords sit between rows).
    var accidental = 0
    /// Chord name drawn on the bar ("C#m").
    var symbol = ""
    let color: ChordColor
    let source: ChordSource
    let start: Double
    let end: Double
    /// MIDI notes it sounded and the keyboard that played it (nil: Mac keys, pads, loops).
    var notes: [Int] = []
    var owner: String?
}

/// A single note once released, for the note display.
struct NoteEvent {
    let midi: Int
    let start: Double
    let end: Double
    var owner: String?
}

/// A player note once released; the loop recorder listens for these.
struct PlayedNote {
    let midi: Int
    let velocity: Int
    let start: Double
    let end: Double
    var instrument: String?
}

/// A single note held on a MIDI keyboard.
struct HeldNote {
    let midi: Int
    let voice: Int
    let start: Double
    let velocity: Int
    let owner: String?
    let instrument: String?
}

/// Who is sounding a note now, for the keyboard drawings.
struct NoteLight: Equatable {
    let source: ChordSource
    let owner: String?
}

/// A player chord once released; the loop recorder listens for these.
/// `octave` is where it actually sounded (keyboard octave, minus one with octave-down).
struct PlayedChord {
    let degree: Degree
    let color: ChordColor
    var octave = 0
    /// Semitones above the degree's root (chromatic keys).
    var accidental = 0
    let start: Double
    let end: Double
    var instrument: String?
    /// Velocity it was played with (loops replay it as played).
    var velocity = 100
}

/// A held player chord: degree plus octave (a MIDI keyboard can hold the same degree in two octaves),
/// and the keyboard holding it (two keyboards can hold the same chord).
struct HeldChord: Hashable {
    let degree: Degree
    let octave: Int
    var accidental = 0
    var owner: String?
}

/// Current time in seconds, on the same clock as the display.
func now() -> Double { CACurrentMediaTime() }

/// Chord state and playback: key, mode, color, held degrees and sounding chords.
@MainActor
final class ChordEngine: ObservableObject {
    static let bpmRange = 70...150

    @Published var tonic: Note = .c {
        didSet {
            guard tonic != oldValue else { return }
            UserDefaults.standard.set(tonic.rawValue, forKey: "tonic")
            revoice { _ in true }
        }
    }
    @Published var flavor: Flavor = .major {
        didSet {
            guard flavor != oldValue else { return }
            UserDefaults.standard.set(flavor.rawValue, forKey: "flavor")
            revoice { _ in true }
        }
    }
    @Published private(set) var color: ChordColor = ChordColor(rawValue: UserDefaults.standard.string(forKey: "chordType") ?? "") ?? .diatonic
    /// Chord type chosen in the header: what chords play when no W A S D / pad color is held.
    @Published var chordType: ChordColor = ChordColor(rawValue: UserDefaults.standard.string(forKey: "chordType") ?? "") ?? .diatonic {
        didSet {
            guard chordType != oldValue else { return }
            UserDefaults.standard.set(chordType.rawValue, forKey: "chordType")
            applyDirectionKeys()
        }
    }
    @Published private(set) var direction: Direction?
    @Published private(set) var bpm = 110 {
        didSet {
            UserDefaults.standard.set(bpm, forKey: "bpm")
            Transport.shared.setBpm(Double(bpm))
        }
    }
    @Published private(set) var octaveDown = false
    @Published private(set) var held = Set<HeldChord>()
    @Published private(set) var sounding: [SoundingChord] = []
    @Published private(set) var history: [ChordEvent] = []

    struct SoundingChord: Identifiable {
        let id: String
        let degree: Degree
        let color: ChordColor
        let source: ChordSource
        let start: Double
        let octave: Int
        let accidental: Int
        /// Chromatic key: plays major instead of the diatonic quality.
        let chromatic: Bool
        let octaveDown: Bool
        let velocity: Int
        /// Loop chords sound with the loop's instrument; nil = the selected one.
        let instrument: String?
        let owner: String?
        let notes: [Int]
        var voices: [Int]
    }

    /// Where notes sound (synth or sampler); set by `AppModel`.
    var output: SoundOutput!
    /// Single notes held on MIDI keyboards in "Notes" layout, by "<keyboard>:<key>".
    @Published private(set) var heldNotes: [String: HeldNote] = [:]
    /// Single notes from loop playback: loop id → voice and pitch.
    @Published private(set) var loopNotes: [String: (voice: Int, midi: Int)] = [:]
    private var noteListeners: [(PlayedNote) -> Void] = []
    @Published private(set) var noteHistory: [NoteEvent] = []
    /// MIDI notes starting (true) or ending (false), for MIDI out.
    var onNotes: (([Int], Bool) -> Void)?
    private var heldDirectionKeys = Set<Character>()
    private var playedListeners: [(PlayedChord) -> Void] = []
    private var pruneTimer: Timer?

    init() {
        let defaults = UserDefaults.standard
        tonic = defaults.string(forKey: "tonic").flatMap(Note.init(rawValue:)) ?? .c
        flavor = defaults.string(forKey: "flavor").flatMap(Flavor.init(rawValue:)) ?? .major
        if let saved = defaults.object(forKey: "bpm") as? Int {
            bpm = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, saved))
        }
        Transport.shared.setBpm(Double(bpm))
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    /// Degrees held by the player, in any octave (chromatic chords between degrees don't count).
    var heldDegrees: Set<Degree> { Set(held.filter { $0.accidental == 0 }.map(\.degree)) }

    func symbol(of chord: SoundingChord) -> String {
        Music.symbol(tonic, chord.degree, flavor, chord.color, accidental: chord.accidental)
    }

    /// Seconds of history on the display: 8 beats.
    var windowSeconds: Double { 480 / Double(bpm) }

    /// Symbols of the sounding chords, lowest degree first, no repeats.
    /// Every MIDI note sounding now (single notes and chord notes) → from a loop?
    var soundingNotes: [Int: NoteLight] {
        var out = [Int: NoteLight]()
        for chord in sounding {
            for note in chord.notes where out[note]?.source != .user { out[note] = NoteLight(source: chord.source, owner: chord.owner) }
        }
        for note in loopNotes.values where out[note.midi] == nil { out[note.midi] = NoteLight(source: .loop, owner: nil) }
        for note in heldNotes.values { out[note.midi] = NoteLight(source: .user, owner: note.owner) }
        return out
    }

    /// What the header shows: chord names, else the single notes held (C4 · E4).
    var headline: [String] {
        let chords = activeSymbols
        if !chords.isEmpty { return chords }
        return Set(heldNotes.values.map(\.midi)).sorted().map { Note.at($0).rawValue + "\($0 / 12 - 1)" }
    }

    var activeSymbols: [String] {
        var seen = Set<String>()
        return sounding.sorted { $0.degree < $1.degree }
            .map { symbol(of: $0) }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Chords

    private func startChord(id: String, degree: Degree, color requested: ChordColor, source: ChordSource,
                            octave: Int = 0, accidental: Int = 0, chromatic: Bool = false, velocity: Int = 100,
                            instrument: String? = nil, owner: String? = nil, at time: Double? = nil) {
        guard !sounding.contains(where: { $0.id == id }) else { return }
        Synth.shared.start()
        let color = chromatic && requested == .diatonic ? .major : requested
        let down = source == .user && octaveDown
        let shift = octave * 12 + (down ? -12 : 0)
        let notes = Music.midiNotes(tonic, degree, flavor, color, accidental: accidental)
            .map { $0 + shift }.filter { (0...127).contains($0) }
        let voices = notes.map { output.noteOn(midi: $0, velocity: velocity, instrument: instrument, at: time) }
        sounding.append(SoundingChord(id: id, degree: degree, color: color, source: source, start: time ?? now(),
                                      octave: octave, accidental: accidental, chromatic: chromatic,
                                      octaveDown: down, velocity: velocity, instrument: instrument,
                                      owner: owner, notes: notes, voices: voices))
        onNotes?(notes, true)
    }

    private func endChord(id: String, release: Double? = nil, at time: Double? = nil) {
        guard let index = sounding.firstIndex(where: { $0.id == id }) else { return }
        let chord = sounding.remove(at: index)
        chord.voices.forEach { output.noteOff($0, release: release, pedal: chord.source == .user, at: time) }
        onNotes?(chord.notes, false)
        let end = max(chord.start, time ?? now())
        history.append(ChordEvent(row: chord.degree, accidental: chord.accidental, symbol: symbol(of: chord),
                                  color: chord.color, source: chord.source, start: chord.start, end: end,
                                  notes: chord.notes, owner: chord.owner))
        if chord.source == .user {
            let played = PlayedChord(degree: chord.degree, color: chord.color,
                                     octave: chord.octave - (chord.octaveDown ? 1 : 0), accidental: chord.accidental,
                                     start: chord.start, end: end, instrument: chord.instrument,
                                     velocity: chord.velocity)
            playedListeners.forEach { $0(played) }
        }
    }

    /// Restart matching chords so they follow a new key, mode, color or octave.
    private func revoice(color next: ChordColor? = nil, _ matches: (SoundingChord) -> Bool) {
        for chord in sounding where matches(chord) {
            endChord(id: chord.id, release: 0.05)
            startChord(id: chord.id, degree: chord.degree, color: next ?? chord.color, source: chord.source,
                       octave: chord.octave, accidental: chord.accidental, chromatic: chord.chromatic,
                       velocity: chord.velocity, instrument: chord.instrument, owner: chord.owner)
        }
    }

    private static func userId(_ chord: HeldChord) -> String {
        "user:\(chord.owner ?? "-"):\(chord.degree):\(chord.octave):\(chord.accidental)"
    }

    /// Plays a degree; `octave` moves it up or down from the normal register (C4).
    func pressDegree(_ degree: Degree, octave: Int = 0) { press(HeldChord(degree: degree, octave: octave)) }

    func releaseDegree(_ degree: Degree, octave: Int = 0) { release(HeldChord(degree: degree, octave: octave)) }

    /// Plays a held chord; `chromatic` (a MIDI key in chromatic layout) makes the plain color major.
    /// `instrument`: the keyboard's own sound (nil = the selected one).
    /// `time`: when the key went down (MIDI arrival), so recordings keep the real timing.
    func press(_ chord: HeldChord, chromatic: Bool = false, velocity: Int = 100, instrument: String? = nil,
               time: Double? = nil) {
        guard held.insert(chord).inserted else { return }
        startChord(id: Self.userId(chord), degree: chord.degree, color: color, source: .user,
                   octave: chord.octave, accidental: chord.accidental, chromatic: chromatic, velocity: velocity,
                   instrument: instrument, owner: chord.owner, at: time)
    }

    /// A single note, as a piano key (MIDI "Notes" layout). `key` identifies the physical key.
    /// Voice id of a note `LiveFastPath` already sounded on the MIDI thread (it stops it too).
    static let presoundedVoice = Int.min

    /// `presounded`: it already sounds (MIDI fast path); only the state is recorded. `time`:
    /// when the key went down (MIDI arrival), so the recorder doesn't see the main-thread delay.
    func playNote(key: String, midi: Int, velocity: Int, instrument: String? = nil, owner: String? = nil,
                  presounded: Bool = false, time: Double? = nil) {
        guard heldNotes[key] == nil, (0...127).contains(midi) else { return }
        Synth.shared.start()
        let voice = presounded ? Self.presoundedVoice : output.noteOn(midi: midi, velocity: velocity, instrument: instrument)
        heldNotes[key] = HeldNote(midi: midi, voice: voice, start: time ?? now(), velocity: velocity, owner: owner,
                                  instrument: instrument)
        onNotes?([midi], true)
    }

    func stopNote(key: String, time: Double? = nil) {
        guard let note = heldNotes.removeValue(forKey: key) else { return }
        if note.voice != Self.presoundedVoice { output.noteOff(note.voice) }
        onNotes?([note.midi], false)
        let end = max(note.start, time ?? now())
        noteHistory.append(NoteEvent(midi: note.midi, start: note.start, end: end, owner: note.owner))
        let played = PlayedNote(midi: note.midi, velocity: note.velocity, start: note.start, end: end,
                                instrument: note.instrument)
        noteListeners.forEach { $0(played) }
    }

    func onNotePlayed(_ listener: @escaping (PlayedNote) -> Void) { noteListeners.append(listener) }

    /// Player notes still held, closed at `end`.
    func heldNotesPlayed(end: Double = now()) -> [PlayedNote] {
        heldNotes.values.map { PlayedNote(midi: $0.midi, velocity: $0.velocity, start: $0.start, end: end, instrument: $0.instrument) }
    }

    /// A single note from loop playback, with the loop's instrument. `time`: host time it must
    /// sound at (loops schedule ahead); nil = now.
    func startLoopNote(id: String, midi: Int, velocity: Int, instrument: String?, at time: Double? = nil) {
        guard loopNotes[id] == nil, (0...127).contains(midi) else { return }
        Synth.shared.start()
        loopNotes[id] = (output.noteOn(midi: midi, velocity: velocity, instrument: instrument, at: time), midi)
        onNotes?([midi], true)
    }

    func release(_ chord: HeldChord, time: Double? = nil) {
        held.remove(chord)
        endChord(id: Self.userId(chord), at: time)
    }

    /// Loop playback entry points; ids belong to the caller.
    func startLoopChord(id: String, degree: Degree, color: ChordColor, octave: Int = 0, accidental: Int = 0,
                        instrument: String? = nil, velocity: Int = 100, at time: Double? = nil) {
        startChord(id: id, degree: degree, color: color, source: .loop, octave: octave, accidental: accidental,
                   velocity: velocity, instrument: instrument, at: time)
    }

    /// Ends a loop chord or loop note (at host time `time`, never before it started; nil = now).
    func endLoopChord(id: String, at time: Double? = nil) {
        if let note = loopNotes.removeValue(forKey: id) {
            output.noteOff(note.voice, pedal: false, at: time)
            onNotes?([note.midi], false)
            return
        }
        endChord(id: id, at: time)
    }

    func stopAll() {
        for chord in sounding { endChord(id: chord.id, release: 0.1) }
        held.removeAll()
        for key in heldNotes.keys { stopNote(key: key) }
    }

    func onChordPlayed(_ listener: @escaping (PlayedChord) -> Void) { playedListeners.append(listener) }

    /// Player chords still sounding, closed at `end`.
    func heldChords(end: Double = now()) -> [PlayedChord] {
        sounding.filter { $0.source == .user }
            .map { PlayedChord(degree: $0.degree, color: $0.color, octave: $0.octave - ($0.octaveDown ? 1 : 0),
                               accidental: $0.accidental, start: $0.start, end: end, instrument: $0.instrument) }
    }

    // MARK: - Color, octave, key, mode, tempo

    private func applyDirectionKeys() {
        let resolved = Direction.resolve(heldDirectionKeys)
        direction = resolved
        let next = resolved?.color ?? chordType
        guard next != color else { return }
        color = next
        revoice(color: next) { $0.source == .user }
    }

    func setDirectionKey(_ key: Character, pressed: Bool) {
        if pressed { heldDirectionKeys.insert(key) } else { heldDirectionKeys.remove(key) }
        applyDirectionKeys()
    }

    /// Wheel: the sector's keys replace whatever direction keys the wheel set before.
    func setDirection(_ direction: Direction, pressed: Bool) {
        for key in direction.keys {
            if pressed { heldDirectionKeys.insert(key) } else { heldDirectionKeys.remove(key) }
        }
        applyDirectionKeys()
    }

    func releaseAllDirections() {
        heldDirectionKeys.removeAll()
        applyDirectionKeys()
    }

    func setOctaveDown(_ pressed: Bool) {
        guard pressed != octaveDown else { return }
        octaveDown = pressed
        revoice { $0.source == .user }
    }

    func shiftTonic(_ step: Int) { tonic = Note.at(tonic.index + step) }

    func shiftFlavor(_ step: Int) {
        let all = Flavor.allCases
        flavor = all[((all.firstIndex(of: flavor)! + step) % all.count + all.count) % all.count]
    }

    func setBpm(_ value: Int) {
        bpm = min(Self.bpmRange.upperBound, max(Self.bpmRange.lowerBound, value))
    }

    /// Drop events that scrolled off the display.
    private func prune() {
        let cutoff = now() - windowSeconds
        if history.contains(where: { $0.end <= cutoff }) { history.removeAll { $0.end <= cutoff } }
        if noteHistory.contains(where: { $0.end <= cutoff }) { noteHistory.removeAll { $0.end <= cutoff } }
    }
}
