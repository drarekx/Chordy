import Foundation

// Shared by Chordy (Mac) and Chordy Pads (iPad): the iPad finds the Mac over Bonjour and
// talks newline-delimited JSON over TCP. The Mac plays; the iPad only sends commands and
// shows the state it receives.

enum RemoteProtocol {
    static let service = "_chordypads._tcp"
    static let version = 1
}

struct RemotePattern: Codable, Equatable {
    var title: String?
    var steps: [[Int]]
    var laneVolumes: [Double]
    var laneNotes: [Int]
    var swing: Double
    var volume: Double
    var kit: String
    var isEmpty: Bool
}

struct RemoteKit: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

/// A level on the iPad's mixer: "drums", "loops" or "kb:<keyboard id>".
struct RemoteFader: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var value: Double
    /// Keyboard color index, or nil.
    var color: Int?
}

/// One alternative drum sound for a lane (GM note).
struct RemoteVariant: Codable, Equatable {
    var note: Int
    var name: String
}

/// A keyboard's reverb, echo and filter (same meaning as `Effects` on the Mac).
struct RemoteEffects: Codable, Equatable {
    var reverb: Double
    var delay: Double
    var delayTime: Double
    var feedback: Double
    var filter: Double
}

/// One MIDI keyboard: its sound, effects and the keys to draw.
struct RemoteKeyboard: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var device: String
    var color: Int
    /// Sound id: `synth`, `synth:<patch>` or an instrument id.
    var sound: String
    var soundName: String
    var isSynth: Bool
    var volume: Double
    var effects: RemoteEffects
    var connected: Bool
    /// Keys drawn on the iPad: first MIDI note and how many.
    var firstKey: Int
    var keyCount: Int
}

/// A sound a keyboard can use. `group` is the menu section; `download` is the MB still to fetch.
struct RemoteSound: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var group: String
    var download: Int?
}

/// A section of the song (intro, verse…): where it starts and how long, in bars.
struct RemoteSection: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var start: Int
    var bars: Int
    var color: Int
}

/// A synth sound in the library.
struct RemoteSoundRef: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var builtin: Bool
}

/// The synth designer: the library, the sound being edited (with unsaved edits), and which
/// keyboard is pinned to it.
struct RemoteSynth: Codable, Equatable {
    var library: [RemoteSoundRef]
    var selectedId: String
    var draft: Patch
    var dirty: Bool
    /// Keyboard that plays the edited sound (id), if any.
    var audition: String?
}

struct RemoteState: Codable, Equatable {
    var macName: String
    var bpm: Int
    var playing: Bool
    var recording: Bool
    var selected: Int
    var track: Int
    var patterns: [RemotePattern]
    var kits: [RemoteKit]
    var laneNames: [String]
    var laneShorts: [String]
    var variants: [[RemoteVariant]]
    var muted: [Int]
    var solo: Int?
    var chain: [Int]
    var chainOn: Bool
    var faders: [RemoteFader]
    var loopsPlaying: Bool
    var loopsRecording: Bool
    // Optional so an older iPad or Mac still understands the message.
    var keyboards: [RemoteKeyboard]?
    var sounds: [RemoteSound]?
    /// The eight quick sounds (ids).
    var favorites: [String]?
    /// The song: its sections, length and whether it has anything to play.
    var songSections: [RemoteSection]?
    var songBars: Int?
    var songHasClips: Bool?
    var synth: RemoteSynth?
}

/// Mac → iPad.
enum RemoteMessage: Codable {
    case state(RemoteState)
    /// Playhead, sent on every step (cheap; the state is only sent when it changes).
    case tick(step: Int?, pattern: Int?, chainPosition: Int?)
    /// A drum sounded (pads light up on the iPad too).
    case flash(track: Int)
    /// Answer to `ping`, echoing its id (round-trip time on the iPad).
    case pong(id: Int)
    /// The count on every beat: beat in the bar (0…3) and bar (from 1), nil when stopped;
    /// `recording` (a loop or the drums), `armed` (waiting for the first note).
    case beat(inBar: Int?, bar: Int?, recording: Bool, armed: Bool)
    /// Keys held now on a MIDI device (to light them on the iPad drawing).
    case notes(device: String, midi: [Int])
    /// Song playhead (beats from the start), ~8 times a second while it plays and on changes.
    case song(playing: Bool, beat: Double, bpm: Int)
}

/// iPad → Mac.
enum RemoteCommand: Codable {
    case hello(version: Int, device: String)
    /// Sent ~10 times a second: measures latency and keeps the iPad's wifi radio awake
    /// (it naps between packets, which delays the first hit after a pause).
    case ping(id: Int)
    case hit(track: Int, velocity: Int)
    case hitNote(note: Int, velocity: Int)
    case toggleStep(track: Int, step: Int, accent: Bool)
    case setVelocity(track: Int, step: Int, velocity: Int)
    case select(pattern: Int)
    case launch(pattern: Int)
    case selectTrack(track: Int)
    case togglePlay
    case toggleRecord
    case setBpm(Int)
    case setSwing(Double)
    case setKit(String)
    case setLaneVolume(track: Int, value: Double)
    case setLaneNote(track: Int, note: Int)
    case toggleMute(track: Int)
    case toggleSolo(track: Int)
    case chainAppend(pattern: Int)
    case chainRemove(position: Int)
    case chainClear
    case setChainOn(Bool)
    case setFader(id: String, value: Double)
    case fill(track: Int, every: Int, offset: Int)
    case shift(track: Int, delta: Int)
    case randomize(track: Int)
    case clearLane(track: Int)
    case clearPattern
    case copyPattern(to: Int)
    case loopsTogglePlay
    case loopsToggleRecord
    case stopAll
    case setSound(keyboard: String, sound: String)
    case setEffects(keyboard: String, effects: RemoteEffects)
    case songTogglePlay
    /// Play the song from a bar (a section's start).
    case songPlay(fromBar: Int)
    /// Back to the start (keeps playing if it was).
    case songRewind
    case synthSelect(id: String)
    /// The whole edited sound, sent as a knob moves.
    case synthDraft(Patch)
    /// Save over a user sound, or as a new one (factory sounds always make a copy).
    case synthSave(asNew: Bool)
    case synthRevert
    case synthNew
    case synthDuplicate(id: String)
    case synthRename(id: String, name: String)
    case synthDelete(id: String)
    /// Give the edited sound to a keyboard (saving a copy of an edited factory sound first).
    case synthAssign(keyboard: String)
    /// Pin a keyboard to the edited sound (nil: unpin).
    case synthAudition(keyboard: String?)
    /// The iPad's try-out keyboard: notes of the edited sound on the Mac.
    case synthNoteOn(midi: Int, velocity: Int)
    case synthNoteOff(midi: Int)
}

/// Splits a TCP byte stream into JSON lines.
struct LineBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            lines.append(data[data.startIndex..<newline])
            data.removeSubrange(data.startIndex...newline)
        }
        return lines
    }
}

extension JSONEncoder {
    /// One JSON object followed by a newline (JSONEncoder never writes raw newlines).
    func line<T: Encodable>(_ value: T) -> Data? {
        guard var data = try? encode(value) else { return nil }
        data.append(0x0A)
        return data
    }
}
