import Combine
import Foundation
import QuartzCore

/// Who triggered a chord: the player (keys, pads, MIDI) or loop playback.
enum ChordSource { case user, loop }

/// A finished chord on the scrolling display. `row` is the degree.
struct ChordEvent {
    let row: Degree
    let color: ChordColor
    let source: ChordSource
    let start: Double
    let end: Double
}

/// A player chord once released; the loop recorder listens for these.
/// `octave` is where it actually sounded (keyboard octave, minus one with octave-down).
struct PlayedChord {
    let degree: Degree
    let color: ChordColor
    var octave = 0
    let start: Double
    let end: Double
}

/// A held player chord: degree plus octave (a MIDI keyboard can hold the same degree in two octaves).
struct HeldChord: Hashable {
    let degree: Degree
    let octave: Int
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
    @Published private(set) var color: ChordColor = .diatonic
    @Published private(set) var direction: Direction?
    @Published private(set) var bpm = 110 { didSet { UserDefaults.standard.set(bpm, forKey: "bpm") } }
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
        let octaveDown: Bool
        let notes: [Int]
        var voices: [Int]
    }

    /// Sound used for new chords.
    var patch: () -> Patch = { Patch.builtins[0] }
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
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    /// Degrees held by the player, in any octave.
    var heldDegrees: Set<Degree> { Set(held.map(\.degree)) }

    /// Seconds of history on the display: 8 beats.
    var windowSeconds: Double { 480 / Double(bpm) }

    /// Symbols of the sounding chords, lowest degree first, no repeats.
    var activeSymbols: [String] {
        var seen = Set<String>()
        return sounding.sorted { $0.degree < $1.degree }
            .map { Music.symbol(tonic, $0.degree, flavor, $0.color) }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Chords

    private func startChord(id: String, degree: Degree, color: ChordColor, source: ChordSource, octave: Int = 0) {
        guard !sounding.contains(where: { $0.id == id }) else { return }
        Synth.shared.start()
        let sound = patch()
        let down = source == .user && octaveDown
        let shift = octave * 12 + (down ? -12 : 0)
        let notes = Music.midiNotes(tonic, degree, flavor, color).map { $0 + shift }.filter { (0...127).contains($0) }
        let voices = notes.map { Synth.shared.noteOn(midi: $0, patch: sound) }
        sounding.append(SoundingChord(id: id, degree: degree, color: color, source: source, start: now(),
                                      octave: octave, octaveDown: down, notes: notes, voices: voices))
        onNotes?(notes, true)
    }

    private func endChord(id: String, release: Double? = nil) {
        guard let index = sounding.firstIndex(where: { $0.id == id }) else { return }
        let chord = sounding.remove(at: index)
        chord.voices.forEach { Synth.shared.noteOff($0, release: release) }
        onNotes?(chord.notes, false)
        let end = now()
        history.append(ChordEvent(row: chord.degree, color: chord.color, source: chord.source, start: chord.start, end: end))
        if chord.source == .user {
            let played = PlayedChord(degree: chord.degree, color: chord.color,
                                     octave: chord.octave - (chord.octaveDown ? 1 : 0), start: chord.start, end: end)
            playedListeners.forEach { $0(played) }
        }
    }

    /// Restart matching chords so they follow a new key, mode, color or octave.
    private func revoice(color next: ChordColor? = nil, _ matches: (SoundingChord) -> Bool) {
        for chord in sounding where matches(chord) {
            endChord(id: chord.id, release: 0.05)
            startChord(id: chord.id, degree: chord.degree, color: next ?? chord.color, source: chord.source,
                       octave: chord.octave)
        }
    }

    private static func userId(_ degree: Degree, _ octave: Int) -> String { "user:\(degree):\(octave)" }

    /// Plays a degree; `octave` moves it up or down from the normal register (C4).
    func pressDegree(_ degree: Degree, octave: Int = 0) {
        guard held.insert(HeldChord(degree: degree, octave: octave)).inserted else { return }
        startChord(id: Self.userId(degree, octave), degree: degree, color: color, source: .user, octave: octave)
    }

    func releaseDegree(_ degree: Degree, octave: Int = 0) {
        held.remove(HeldChord(degree: degree, octave: octave))
        endChord(id: Self.userId(degree, octave))
    }

    /// Loop playback entry points; ids belong to the caller.
    func startLoopChord(id: String, degree: Degree, color: ChordColor, octave: Int = 0) {
        startChord(id: id, degree: degree, color: color, source: .loop, octave: octave)
    }

    func endLoopChord(id: String) { endChord(id: id) }

    func stopAll() {
        for chord in sounding { endChord(id: chord.id, release: 0.1) }
        held.removeAll()
    }

    func onChordPlayed(_ listener: @escaping (PlayedChord) -> Void) { playedListeners.append(listener) }

    /// Player chords still sounding, closed at `end`.
    func heldChords(end: Double = now()) -> [PlayedChord] {
        sounding.filter { $0.source == .user }
            .map { PlayedChord(degree: $0.degree, color: $0.color, octave: $0.octave - ($0.octaveDown ? 1 : 0),
                               start: $0.start, end: end) }
    }

    // MARK: - Color, octave, key, mode, tempo

    private func applyDirectionKeys() {
        let resolved = Direction.resolve(heldDirectionKeys)
        direction = resolved
        let next = resolved?.color ?? .diatonic
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
    }
}
