import Foundation

/// A physical control: message type, channel (1–16) and note/CC number.
struct MidiControl: Hashable, Codable {
    enum Kind: String, Codable { case note, cc, pb }
    let kind: Kind
    let channel: Int
    /// Note or CC number; 0 for pitch bend.
    let number: Int

    /// Stable key used in the saved mapping.
    var id: String { "\(kind.rawValue):\(channel):\(number)" }

    init(_ kind: Kind, channel: Int, number: Int) {
        self.kind = kind
        self.channel = channel
        self.number = number
    }

    init?(id: String) {
        let parts = id.split(separator: ":")
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])),
              let channel = Int(parts[1]), let number = Int(parts[2]) else { return nil }
        self.init(kind, channel: channel, number: number)
    }

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    var label: String {
        switch kind {
        case .note: return "\(Self.noteNames[number % 12])\(number / 12 - 1) · ch\(channel)"
        case .cc: return "CC\(number) · ch\(channel)"
        case .pb: return "Pitch bend · ch\(channel)"
        }
    }
}

/// A decoded channel message. `value` is 0…1; `pressed` is the "on" side of a button.
struct MidiEvent {
    let control: MidiControl
    let value: Double
    let pressed: Bool

    /// Decode a MIDI 1.0 channel voice message (status, data1, data2). Others → nil.
    init?(status: UInt8, data1: UInt8, data2: UInt8) {
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0x90:
            // Note on with velocity 0 is a note off.
            control = MidiControl(.note, channel: channel, number: Int(data1))
            value = Double(data2) / 127
            pressed = data2 > 0
        case 0x80:
            control = MidiControl(.note, channel: channel, number: Int(data1))
            value = 0
            pressed = false
        case 0xB0:
            control = MidiControl(.cc, channel: channel, number: Int(data1))
            value = Double(data2) / 127
            pressed = data2 >= 64
        case 0xE0:
            control = MidiControl(.pb, channel: channel, number: 0)
            value = Double(Int(data2) << 7 | Int(data1)) / 16383
            pressed = abs(value - 0.5) > 0.25
        default:
            return nil
        }
    }
}

/// What a control can do.
/// - hold: active while held (note on → off, CC ≥ 64 → < 64).
/// - press: fires once when pressed.
/// - range: follows a knob, fader or wheel.
enum MidiActionKind { case hold, press, range }

enum MidiAction: String, CaseIterable, Codable {
    case degree1, degree2, degree3, degree4, degree5, degree6, degree7
    case colorUp, colorDown, colorLeft, colorRight, octaveDown
    case tonicDown, tonicUp, tonicSet, modePrev, modeNext, modeSet
    case bpmDown, bpmUp, bpmSet, record, play, stop
    case soundPrev, soundNext, keysMode, padsMode
    case cutoff, resonance, filterEnv, attack, decay, sustain, release, vibratoDepth, vibratoRate, volume
    case pitchBend

    var kind: MidiActionKind {
        switch self {
        case .degree1, .degree2, .degree3, .degree4, .degree5, .degree6, .degree7,
             .colorUp, .colorDown, .colorLeft, .colorRight, .octaveDown:
            return .hold
        case .tonicDown, .tonicUp, .modePrev, .modeNext, .bpmDown, .bpmUp, .record, .play, .stop,
             .soundPrev, .soundNext, .keysMode, .padsMode:
            return .press
        default:
            return .range
        }
    }

    var degree: Degree? {
        switch self {
        case .degree1: return 1
        case .degree2: return 2
        case .degree3: return 3
        case .degree4: return 4
        case .degree5: return 5
        case .degree6: return 6
        case .degree7: return 7
        default: return nil
        }
    }

    static func degree(_ d: Degree) -> MidiAction { [.degree1, .degree2, .degree3, .degree4, .degree5, .degree6, .degree7][d - 1] }

    enum Group: CaseIterable {
        case chords, color, keyMode, transport, sound

        var title: String {
            switch self {
            case .chords: return tr("Acordes")
            case .color: return tr("Color")
            case .keyMode: return tr("Tono y modo")
            case .transport: return tr("Transporte")
            case .sound: return tr("Sonido")
            }
        }
    }

    var group: Group {
        switch self {
        case .degree1, .degree2, .degree3, .degree4, .degree5, .degree6, .degree7, .keysMode, .padsMode: return .chords
        case .colorUp, .colorDown, .colorLeft, .colorRight, .octaveDown: return .color
        case .tonicDown, .tonicUp, .tonicSet, .modePrev, .modeNext, .modeSet: return .keyMode
        case .bpmDown, .bpmUp, .bpmSet, .record, .play, .stop: return .transport
        default: return .sound
        }
    }

    var label: String {
        if let degree { return tr("Grado %d", degree) }
        switch self {
        case .colorUp: return tr("Color ↑ (mayor)")
        case .colorDown: return tr("Color ↓ (menor)")
        case .colorLeft: return tr("Color ← (dim)")
        case .colorRight: return tr("Color → (aum)")
        case .octaveDown: return tr("Octava abajo")
        case .tonicDown: return tr("Tono −")
        case .tonicUp: return tr("Tono +")
        case .tonicSet: return tr("Tono (knob)")
        case .modePrev: return tr("Modo anterior")
        case .modeNext: return tr("Modo siguiente")
        case .modeSet: return tr("Modo (knob)")
        case .bpmDown: return tr("BPM −")
        case .bpmUp: return tr("BPM +")
        case .bpmSet: return tr("BPM (knob)")
        case .record: return tr("Grabar loop")
        case .play: return tr("Reproducir / parar loop")
        case .stop: return tr("Parar todo")
        case .keysMode: return tr("Teclado: notas ⇄ acordes")
        case .padsMode: return tr("Pads: acordes → pasos → tocar")
        case .soundPrev: return tr("Sonido anterior")
        case .soundNext: return tr("Sonido siguiente")
        case .cutoff: return tr("Filtro: corte")
        case .resonance: return tr("Filtro: resonancia")
        case .filterEnv: return tr("Filtro: envolvente")
        case .attack: return tr("Ataque")
        case .decay: return tr("Caída")
        case .sustain: return tr("Sostenido")
        case .release: return tr("Liberación")
        case .vibratoDepth: return tr("Vibrato: profundidad")
        case .vibratoRate: return tr("Vibrato: velocidad")
        case .volume: return tr("Volumen")
        case .pitchBend: return tr("Pitch bend (±2 semitonos)")
        default: return rawValue
        }
    }

    /// Range actions need a continuous control; buttons need a note or CC.
    func accepts(_ control: MidiControl) -> Bool {
        kind == .range ? control.kind != .note : control.kind != .pb
    }
}

typealias MidiBindings = [String: MidiAction]

// MARK: - Presets

enum MidiPresets {
    /// Keys zone: white keys play degrees (C = I … B = vii°) in the octave of the key
    /// (C4 = normal register), black keys hold colors, so one hand picks the color while
    /// the other plays. Notes 96+ stay free for the Launchkey's InControl pads (channel 1 too).
    static let keyActions: [Int: MidiAction] = [
        0: .degree1, 2: .degree2, 4: .degree3, 5: .degree4, 7: .degree5, 9: .degree6, 11: .degree7,
        1: .colorDown, 3: .colorUp, 6: .colorLeft, 8: .colorRight, 10: .octaveDown,
    ]
    static let keysRange = 0..<96

    /// Octave of a key relative to C4 (C3 → -1, C5 → +1).
    static func octave(ofNote note: Int) -> Int { note / 12 - 5 }

    /// Pad layout shared by basic and InControl modes, left to right.
    static let topPads: [MidiAction] = [.colorDown, .colorUp, .colorLeft, .colorRight, .tonicDown, .tonicUp, .modeNext, .stop]
    static let bottomPads: [MidiAction] = [.degree1, .degree2, .degree3, .degree4, .degree5, .degree6, .degree7, .octaveDown]

    /// Pad notes, left to right. Basic mode: channel 10, drum layout. InControl: channel 1.
    static let basicTop = [40, 41, 42, 43, 48, 49, 50, 51]
    static let basicBottom = [36, 37, 38, 39, 44, 45, 46, 47]
    static let inControlTop = Array(96...103)
    static let inControlBottom = Array(112...119)
    /// Round buttons beside the pads (InControl).
    static let roundTop = 104
    static let roundBottom = 120

    /// Knobs 1–8 (CC 21–28).
    static let knobs: [MidiAction] = [.cutoff, .resonance, .filterEnv, .attack, .release, .vibratoDepth, .volume, .bpmSet]

    /// Novation Launchkey 25 MK2. Transport sends on channel 1 (basic) or 16 (InControl).
    static func launchkeyMK2() -> MidiBindings {
        var out = MidiBindings()
        for (i, action) in topPads.enumerated() {
            out[MidiControl(.note, channel: 10, number: basicTop[i]).id] = action
            out[MidiControl(.note, channel: 1, number: inControlTop[i]).id] = action
        }
        for (i, action) in bottomPads.enumerated() {
            out[MidiControl(.note, channel: 10, number: basicBottom[i]).id] = action
            out[MidiControl(.note, channel: 1, number: inControlBottom[i]).id] = action
        }
        out[MidiControl(.note, channel: 1, number: roundTop).id] = .keysMode
        out[MidiControl(.note, channel: 1, number: roundBottom).id] = .padsMode
        for (i, action) in knobs.enumerated() {
            out[MidiControl(.cc, channel: 1, number: 21 + i).id] = action
        }
        let transport: [Int: MidiAction] = [102: .soundPrev, 103: .soundNext, 112: .tonicDown, 113: .tonicUp,
                                            114: .stop, 115: .play, 116: .play, 117: .record]
        for channel in [1, 16] {
            for (cc, action) in transport { out[MidiControl(.cc, channel: channel, number: cc).id] = action }
        }
        out[MidiControl(.cc, channel: 1, number: 1).id] = .vibratoDepth
        out[MidiControl(.pb, channel: 1, number: 0).id] = .pitchBend
        return out
    }
}
