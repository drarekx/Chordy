import Foundation

/// Music theory: keys, modes, scale degrees and chord colors.
enum Note: String, CaseIterable, Codable {
    case c = "C", cs = "C#", d = "D", ds = "D#", e = "E", f = "F"
    case fs = "F#", g = "G", gs = "G#", a = "A", `as` = "A#", b = "B"

    var index: Int { Note.allCases.firstIndex(of: self)! }
    static func at(_ index: Int) -> Note { allCases[((index % 12) + 12) % 12] }
}

enum Flavor: String, CaseIterable, Codable {
    case major, minor, dorian

    var label: String {
        switch self {
        case .major: return tr("mayor")
        case .minor: return tr("menor")
        case .dorian: return tr("dórico")
        }
    }
}

enum ChordColor: String, CaseIterable, Codable {
    case diatonic, major, minor, diminished, augmented, maj7, sus2, sus4, add9

    /// Short name shown on the wheel.
    var short: String {
        switch self {
        case .diatonic: return "diat."
        case .major: return "maj"
        case .minor: return "min"
        case .diminished: return "dim"
        case .augmented: return "aug"
        default: return rawValue
        }
    }

    var symbolSuffix: String {
        switch self {
        case .diatonic, .major: return ""
        case .minor: return "m"
        case .diminished: return "dim"
        case .augmented: return "aug"
        default: return rawValue
        }
    }

    /// Shape over the degree's root, for non-diatonic colors.
    var shape: [Int] {
        switch self {
        case .diatonic, .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .maj7: return [0, 4, 7, 11]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .add9: return [0, 4, 7, 14]
        }
    }
}

enum Direction: String, CaseIterable, Codable {
    case up, down, left, right, upRight, upLeft, downRight, downLeft

    /// Direction keys (W A S D) that make up this direction.
    var keys: Set<Character> {
        switch self {
        case .up: return ["w"]
        case .down: return ["s"]
        case .left: return ["a"]
        case .right: return ["d"]
        case .upRight: return ["w", "d"]
        case .upLeft: return ["w", "a"]
        case .downRight: return ["s", "d"]
        case .downLeft: return ["s", "a"]
        }
    }

    var color: ChordColor {
        switch self {
        case .up: return .major
        case .down: return .minor
        case .left: return .diminished
        case .right: return .augmented
        case .upRight: return .maj7
        case .upLeft: return .sus2
        case .downRight: return .sus4
        case .downLeft: return .add9
        }
    }

    /// Held W/A/S/D keys → direction (diagonals win), or nil.
    static func resolve(_ held: Set<Character>) -> Direction? {
        let w = held.contains("w"), s = held.contains("s"), a = held.contains("a"), d = held.contains("d")
        if w && d { return .upRight }
        if w && a { return .upLeft }
        if s && d { return .downRight }
        if s && a { return .downLeft }
        if w { return .up }
        if s { return .down }
        if a { return .left }
        if d { return .right }
        return nil
    }
}

/// Scale degree 1…7.
typealias Degree = Int

enum Music {
    static let degrees: [Degree] = Array(1...7)

    /// Mac keyboard key for each degree: bottom row J K L ;, top row U I O.
    static let degreeKeys: [Character: Degree] = ["j": 1, "u": 2, "k": 3, "i": 4, "l": 5, "o": 6, ";": 7]
    static func key(for degree: Degree) -> Character {
        degreeKeys.first { $0.value == degree }!.key
    }

    private static let scales: [Flavor: [(numeral: String, intervals: [Int])]] = [
        .major: [("I", [0, 4, 7]), ("ii", [2, 5, 9]), ("iii", [4, 7, 11]), ("IV", [5, 9, 12]),
                 ("V", [7, 11, 14]), ("vi", [9, 12, 16]), ("vii°", [11, 14, 17])],
        .minor: [("i", [0, 3, 7]), ("ii°", [2, 5, 8]), ("III", [3, 7, 10]), ("iv", [5, 8, 12]),
                 ("v", [7, 10, 14]), ("VI", [8, 12, 15]), ("VII", [10, 14, 17])],
        .dorian: [("i", [0, 3, 7]), ("ii", [2, 5, 9]), ("III", [3, 7, 10]), ("IV", [5, 9, 12]),
                  ("v", [7, 10, 14]), ("vi°", [9, 12, 15]), ("VII", [10, 14, 17])],
    ]

    static func numeral(_ degree: Degree, _ flavor: Flavor) -> String {
        scales[flavor]![degree - 1].numeral
    }

    /// Semitone offsets from the tonic for a degree, with color applied.
    static func intervals(_ degree: Degree, _ flavor: Flavor, _ color: ChordColor) -> [Int] {
        let diatonic = scales[flavor]![degree - 1].intervals
        if color == .diatonic { return diatonic }
        return color.shape.map { diatonic[0] + $0 }
    }

    private static func triadQuality(_ intervals: [Int]) -> ChordColor {
        let third = intervals[1] - intervals[0], fifth = intervals[2] - intervals[0]
        if third == 3 && fifth == 6 { return .diminished }
        if third == 4 && fifth == 8 { return .augmented }
        return third == 3 ? .minor : .major
    }

    static func symbol(_ tonic: Note, _ degree: Degree, _ flavor: Flavor, _ color: ChordColor) -> String {
        let diatonic = scales[flavor]![degree - 1].intervals
        let root = Note.at(tonic.index + diatonic[0])
        let quality = color == .diatonic ? triadQuality(diatonic) : color
        return root.rawValue + quality.symbolSuffix
    }

    /// MIDI notes of a chord, voiced from C4 upward.
    static func midiNotes(_ tonic: Note, _ degree: Degree, _ flavor: Flavor, _ color: ChordColor) -> [Int] {
        intervals(degree, flavor, color).map { 60 + tonic.index + $0 }
    }

    static func frequency(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
}
