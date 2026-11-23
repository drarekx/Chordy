import Foundation

// Songs with chords over the lyrics. Shared by Chordy (Mac) and Chordy Pads (iPad): the Mac
// keeps the library and sends the ChordPro text; both parse and draw it with this code.
//
// ChordPro is the standard plain-text format: chords in brackets inside the lyrics
// («A[G]mazing [G7]grace») and directives in braces («{title: …}», «{key: G}»).
// Text copied from a website (chords on their own line above the lyrics) is converted to
// ChordPro when it's imported (`ChordSheetImport`).

/// A chord symbol: root, quality and an optional bass («C#m7/G#»).
struct ChordName: Equatable, Hashable {
    /// Pitch class 0…11 (C = 0).
    var root: Int
    /// Everything between the root and the slash («m7», «sus4», «»).
    var suffix: String
    var bass: Int?
    /// Written with flats (Bb) rather than sharps (A#).
    var flat: Bool
    /// Written in solfège (Do, Re, Mi…).
    var latin: Bool

    private static let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11, "H": 11]
    private static let solfege: [(String, Int)] = [("Sol", 7), ("Do", 0), ("Re", 2), ("Mi", 4), ("Fa", 5), ("La", 9), ("Si", 11)]
    static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    static let latinSharp = ["Do", "Do#", "Re", "Re#", "Mi", "Fa", "Fa#", "Sol", "Sol#", "La", "La#", "Si"]
    static let latinFlat = ["Do", "Reb", "Re", "Mib", "Mi", "Fa", "Solb", "Sol", "Lab", "La", "Sib", "Si"]

    /// Reads a note name at the start of `s`: pitch class, characters used, flat?, latin?
    private static func note(_ s: Substring) -> (pc: Int, length: Int, flat: Bool, latin: Bool)? {
        var pc: Int, length: Int, latin = false
        if let first = s.first, let p = letters[first] {
            pc = p; length = 1
        } else if let (name, p) = solfege.first(where: { s.lowercased().hasPrefix($0.0.lowercased()) && s.hasPrefix(String($0.0.prefix(1))) }) {
            pc = p; length = name.count; latin = true
        } else {
            return nil
        }
        var flat = false
        let rest = s.dropFirst(length)
        if let a = rest.first {
            if a == "#" || a == "♯" { pc += 1; length += 1 }
            else if a == "b" || a == "♭" {
                // «Bb» is B flat; «Cb»… too. «b» right after the letter is always the accidental.
                pc -= 1; length += 1; flat = true
            }
        }
        return ((pc % 12 + 12) % 12, length, flat, latin)
    }

    /// Suffixes we understand (after the root); anything else isn't a chord (so lyrics aren't read as chords).
    private static let suffixPattern = try! NSRegularExpression(
        pattern: "^(m|mi|min|-|maj|ma|M|Δ|dim|°|º|o|ø|aug|\\+|sus|add|no|omit|alt|[0-9]|b|#|♭|♯|\\(|\\)|/|,|\\*)*$")

    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        // «(C)» and «C*» are still a C.
        if s.hasPrefix("("), s.hasSuffix(")") { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty, let head = Self.note(Substring(s)) else { return nil }
        var rest = String(s.dropFirst(head.length))
        var bass: Int?
        if let slash = rest.lastIndex(of: "/") {
            let after = rest[rest.index(after: slash)...]
            if let b = Self.note(after), b.length == after.count {
                bass = b.pc
                rest = String(rest[..<slash])
            }
        }
        guard rest.count <= 12,
              Self.suffixPattern.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil else { return nil }
        // Solfège: «Lam» is La minor, but plain words like «Mia» or «Dolor» aren't chords.
        if head.latin, rest.contains(where: { $0.isLetter && !"mMajdinsuth".contains($0) }) { return nil }
        // «o» is a diminished sign only on its own («Co», «Co7»): «Bob» is a name.
        if rest.contains("o"), !(rest == "o" || rest == "o7") { return nil }
        root = head.pc
        suffix = rest
        self.bass = bass
        flat = head.flat
        latin = head.latin
    }

    init(root: Int, suffix: String, bass: Int? = nil, flat: Bool = false, latin: Bool = false) {
        self.root = (root % 12 + 12) % 12
        self.suffix = suffix
        self.bass = bass.map { ($0 % 12 + 12) % 12 }
        self.flat = flat
        self.latin = latin
    }

    static func noteName(_ pc: Int, flat: Bool, latin: Bool) -> String {
        let i = (pc % 12 + 12) % 12
        return latin ? (flat ? latinFlat : latinSharp)[i] : (flat ? flatNames : sharpNames)[i]
    }

    func transposed(_ semitones: Int, flat: Bool? = nil) -> ChordName {
        ChordName(root: root + semitones, suffix: suffix, bass: bass.map { $0 + semitones },
                  flat: flat ?? self.flat, latin: latin)
    }

    /// Written out again, in solfège if `latin` (nil: as it was imported).
    func symbol(latin: Bool? = nil) -> String {
        let l = latin ?? self.latin
        var s = Self.noteName(root, flat: flat, latin: l) + suffix
        if let bass { s += "/" + Self.noteName(bass, flat: flat, latin: l) }
        return s
    }

    // MARK: Quality

    /// The kind of chord, reduced to what the matcher and Chordy's colors need.
    enum Quality: String {
        case major, minor, diminished, augmented, sus2, sus4, power
        case seventh, major7, minor7, halfDiminished, diminished7, minorMajor7
        case add9, sixth, minor6
    }

    var quality: Quality {
        let s = suffix.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "*", with: "")
        let isMaj7 = s.hasPrefix("maj") || s.hasPrefix("ma7") || s.hasPrefix("M") || s.hasPrefix("Δ") || s.contains("7M")
        let minor = !isMaj7 && (s.hasPrefix("m") || s.hasPrefix("-") || s.hasPrefix("min") || s.hasPrefix("mi"))
        if s.hasPrefix("ø") || s.contains("m7b5") || s.contains("m7♭5") || s.contains("-7b5") { return .halfDiminished }
        if s.hasPrefix("dim") || s.hasPrefix("°") || s.hasPrefix("º") || s.hasPrefix("o") {
            return s.contains("7") ? .diminished7 : .diminished
        }
        if s.hasPrefix("aug") || s.hasPrefix("+") || s.contains("#5") { return .augmented }
        if s.contains("sus2") { return .sus2 }
        if s.contains("sus") { return .sus4 }
        if s == "5" { return .power }
        if minor {
            if s.contains("maj7") || s.contains("M7") { return .minorMajor7 }
            if s.contains("7") || s.contains("9") || s.contains("11") || s.contains("13") { return .minor7 }
            if s.contains("6") { return .minor6 }
            return .minor
        }
        if isMaj7 { return .major7 }
        if s.contains("add") || s == "2" { return .add9 }
        if s.contains("7") || s.contains("9") || s.contains("11") || s.contains("13") { return .seventh }
        if s.contains("6") { return .sixth }
        return .major
    }

    /// Semitones above the root.
    var intervals: [Int] {
        switch quality {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .power: return [0, 7]
        case .seventh: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        case .halfDiminished: return [0, 3, 6, 10]
        case .diminished7: return [0, 3, 6, 9]
        case .minorMajor7: return [0, 3, 7, 11]
        case .add9: return [0, 4, 7, 14]
        case .sixth: return [0, 4, 7, 9]
        case .minor6: return [0, 3, 7, 9]
        }
    }

    var pitchClasses: Set<Int> {
        var set = Set(intervals.map { (root + $0) % 12 })
        if let bass { set.insert(bass) }
        return set
    }

    /// The note that tells major from minor (nil for sus and power chords).
    private var third: Int? {
        switch quality {
        case .sus2, .sus4, .power: return nil
        default: return (root + intervals[1]) % 12
        }
    }

    /// Do these notes (pitch classes) sound like this chord? Root and third must be there,
    /// and most of what's held must belong to the chord (a melody note on top is fine;
    /// C–E–G is not an Em).
    func isPlayed(by played: Set<Int>) -> Bool {
        guard played.count >= 2, played.contains(root) else { return false }
        if let third, !played.contains(third) { return false }
        let inside = played.intersection(pitchClasses).count
        return Double(inside) / Double(played.count) >= 0.74
    }
}

// MARK: - Sheet

/// A song in the library. The ChordPro text is the song; the rest is how it's shown.
struct ChordSheet: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var artist: String?
    /// ChordPro text.
    var source: String
    /// Semitones up (−11…11) as shown and played now.
    var transpose = 0
    var addedAt: Date
    var updatedAt: Date?
    /// Imported from a MIDI file: its notes (the text is the chords found in them).
    var midi: MidiScore?

    /// Key written in the song («G», «Am»), else guessed from its chords.
    var key: String? { parsed.key }

    var parsed: ParsedSheet { ParsedSheet(source) }
}

/// A line of the song.
struct SheetLine: Identifiable {
    enum Kind { case lyrics, chords, comment, empty, tab }
    struct Segment {
        /// The chord as written («Am7»), nil for text before the first chord.
        var chord: String?
        var text: String
        /// Index among the song's playable chords (for following), nil if the chord isn't one.
        var index: Int?
    }

    var id: Int
    var kind: Kind
    var segments: [Segment]
    /// Comment lines, and the label of the section that starts here.
    var text = ""
}

struct SheetSection: Identifiable {
    enum Kind { case verse, chorus, bridge, other }
    var id: Int
    var kind: Kind
    var name: String?
    var lines: [SheetLine]
}

/// The ChordPro text read into sections, lines and the list of chords to play in order.
struct ParsedSheet {
    var title: String?
    var subtitle: String?
    var artist: String?
    var key: String?
    var capo: Int?
    var tempo: Int?
    var time: String?
    var sections: [SheetSection] = []
    /// Playable chords in order (index = `Segment.index`).
    var chords: [ChordName] = []
    /// Where each chord is: line id.
    var chordLines: [Int] = []
    /// Key not written: guessed from the chords.
    var keyGuessed = false

    init(_ source: String) {
        var sections: [SheetSection] = []
        var current = SheetSection(id: 0, kind: .other, name: nil, lines: [])
        var lineId = 0
        var inTab = false

        func close() {
            if !current.lines.isEmpty || current.name != nil { sections.append(current) }
            current = SheetSection(id: sections.count + 1, kind: .other, name: nil, lines: [])
        }

        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
                let inner = trimmed.dropFirst().dropLast()
                let parts = inner.split(separator: ":", maxSplits: 1)
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                switch name {
                case "title", "t": title = value
                case "subtitle", "st": subtitle = value
                case "artist", "composer": artist = artist ?? value
                case "key": key = value
                case "capo": capo = Int(value)
                case "tempo": tempo = Int(value)
                case "time": time = value
                case "comment", "c", "comment_italic", "ci", "comment_box", "cb", "highlight":
                    current.lines.append(SheetLine(id: lineId, kind: .comment, segments: [], text: value))
                    lineId += 1
                case "soc", "start_of_chorus", "sov", "start_of_verse", "sob", "start_of_bridge", "sot", "start_of_tab":
                    close()
                    current.kind = name.hasSuffix("c") || name.hasSuffix("chorus") ? .chorus
                        : (name.hasSuffix("b") || name.hasSuffix("bridge") ? .bridge : .verse)
                    if name == "sot" || name == "start_of_tab" { inTab = true; current.kind = .other }
                    current.name = value.isEmpty ? nil : value
                case let n where n.hasPrefix("start_of_"):
                    close()
                    current.name = value.isEmpty ? String(n.dropFirst(9)).capitalized : value
                case "eot", "end_of_tab":
                    inTab = false
                    close()
                case let n where n.hasPrefix("end_of_") || ["eoc", "eov", "eob"].contains(n):
                    close()
                case "chorus":
                    // «{chorus}»: repeat the chorus here; shown as its label.
                    current.lines.append(SheetLine(id: lineId, kind: .comment, segments: [], text: value.isEmpty ? "Chorus" : value))
                    lineId += 1
                default: break
                }
                continue
            }
            if inTab {
                current.lines.append(SheetLine(id: lineId, kind: .tab, segments: [], text: line))
                lineId += 1
                continue
            }
            if trimmed.isEmpty {
                // Blank lines split verses; keep one so the layout breathes.
                if current.lines.last.map({ $0.kind != .empty }) ?? false {
                    current.lines.append(SheetLine(id: lineId, kind: .empty, segments: []))
                    lineId += 1
                }
                continue
            }
            var segments: [SheetLine.Segment] = []
            var text = ""
            var chord: String?
            var i = line.startIndex
            while i < line.endIndex {
                if line[i] == "[", let close = line[i...].firstIndex(of: "]") {
                    if chord != nil || !text.isEmpty { segments.append(.init(chord: chord, text: text)) }
                    chord = String(line[line.index(after: i)..<close])
                    text = ""
                    i = line.index(after: close)
                } else {
                    text.append(line[i])
                    i = line.index(after: i)
                }
            }
            if chord != nil || !text.isEmpty { segments.append(.init(chord: chord, text: text)) }
            let onlyChords = segments.allSatisfy { $0.chord != nil || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            current.lines.append(SheetLine(id: lineId, kind: onlyChords ? .chords : .lyrics, segments: segments))
            lineId += 1
        }
        close()
        // Trailing blank lines say nothing.
        for s in sections.indices { while sections[s].lines.last?.kind == .empty { sections[s].lines.removeLast() } }
        self.sections = sections.filter { !$0.lines.isEmpty || $0.name != nil }

        // Number the playable chords in reading order.
        for s in self.sections.indices {
            for l in self.sections[s].lines.indices {
                for g in self.sections[s].lines[l].segments.indices {
                    guard let written = self.sections[s].lines[l].segments[g].chord, let c = ChordName(written) else { continue }
                    self.sections[s].lines[l].segments[g].index = chords.count
                    chords.append(c)
                    chordLines.append(self.sections[s].lines[l].id)
                }
            }
        }
        if key == nil, let guess = ChordSheetImport.guessKey(chords) {
            key = guess
            keyGuessed = true
        }
    }

    /// Key as root + minor, if it can be read.
    var keyChord: ChordName? { key.flatMap { ChordName($0) } }

    /// Whether to spell the song with flats after transposing by `semitones`.
    func usesFlats(transposedBy semitones: Int) -> Bool {
        guard let k = keyChord else { return chords.contains { $0.flat } }
        let minor = k.quality == .minor || k.quality == .minor7
        // Relative major of the new key decides: F, Bb, Eb, Ab, Db, Gb are flat keys.
        let major = ((k.root + semitones + (minor ? 3 : 0)) % 12 + 12) % 12
        return [5, 10, 3, 8, 1, 6].contains(major)
    }

    /// A chord as shown with the song transposed.
    func display(_ written: String, transpose: Int, latin: Bool? = nil) -> String {
        guard let c = ChordName(written) else { return written }
        if transpose == 0 && latin == nil { return written }
        return c.transposed(transpose, flat: usesFlats(transposedBy: transpose)).symbol(latin: latin)
    }

    func displayKey(transpose: Int) -> String? {
        guard let k = keyChord else { return key }
        return k.transposed(transpose, flat: usesFlats(transposedBy: transpose)).symbol()
    }
}

// MARK: - Following what's played

/// Moves along the song's chords as the player plays them: the next chord (or the one after,
/// if one was skipped) advances the position. Repeating the same chord needs letting go first.
struct ChordFollower {
    /// Chord being played now (−1: before the first).
    var position = -1
    private var lastPlayed: Set<Int> = []

    /// `played`: pitch classes held now. Returns true if the position moved.
    mutating func update(_ played: Set<Int>, chords: [ChordName], transpose: Int) -> Bool {
        defer { lastPlayed = played }
        guard played != lastPlayed, played.count >= 2 else { return false }
        for step in 1...2 {
            let target = position + step
            guard chords.indices.contains(target) else { return false }
            let chord = chords[target].transposed(transpose)
            guard chord.isPlayed(by: played) else { continue }
            // Same chord again (C → C): only on a new attack, not when a melody note joins.
            if chords.indices.contains(position), chords[position].transposed(transpose).pitchClasses == chord.pitchClasses,
               !lastPlayed.isEmpty { return false }
            position = target
            return true
        }
        return false
    }

    mutating func seek(_ index: Int) {
        position = index
        lastPlayed = []
    }
}

// MARK: - Import

enum ChordSheetImport {
    /// Text in, ChordPro out. Text that already is ChordPro stays as it is; chords written on
    /// their own line above the lyrics move into the lyrics.
    static func chordPro(from text: String, fallbackTitle: String? = nil) -> (source: String, title: String, artist: String?) {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if isChordPro(text) {
            let parsed = ParsedSheet(text)
            var source = text
            let title = parsed.title ?? fallbackTitle ?? firstWords(text)
            if parsed.title == nil { source = "{title: \(title)}\n" + source }
            return (source, title, parsed.artist ?? parsed.subtitle)
        }
        return convert(text, fallbackTitle: fallbackTitle)
    }

    static func isChordPro(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).range(of: #"^\{(title|t|key|start_of_\w+|soc|sov|c|comment)\s*[:}]"#, options: .regularExpression) != nil }) {
            return true
        }
        // «[Am]» inside a line of lyrics (not «[Chorus]» on its own line).
        let inline = try! NSRegularExpression(pattern: #"\[([^\]\s]{1,10})\]"#)
        var found = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for m in inline.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let r = Range(m.range(at: 1), in: line), ChordName(String(line[r])) != nil else { continue }
                if trimmed.count > m.range.length { found += 1 }
            }
        }
        return found >= 2
    }

    /// Tokens that can sit in a chord line without being chords.
    private static let fillers: Set<String> = ["|", "||", "/", "-", "–", "x2", "x3", "x4", "(x2)", "(x3)", "(x4)", "%", ".", "..", "...",
                                               "N.C.", "NC", "n.c.", "(", ")", "[", "]", ":", "|:", ":|", "*"]

    /// Is this line only chords (and bar lines)?
    static func isChordLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return false }
        var chords = 0
        for t in tokens {
            if fillers.contains(t) || t.range(of: #"^\(?x\d+\)?$"#, options: .regularExpression) != nil { continue }
            guard ChordName(t) != nil else { return false }
            chords += 1
        }
        return chords > 0
    }

    /// «[Chorus]», «Estribillo:», «Verse 1», «INTRO» → section name.
    static func sectionHeader(_ line: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 32 else { return nil }
        let bracketed = (s.hasPrefix("[") && s.hasSuffix("]")) || (s.hasPrefix("(") && s.hasSuffix(")"))
        if bracketed { s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        let colon = s.hasSuffix(":")
        if colon { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        let lower = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let words = ["intro", "verse", "verso", "estrofa", "chorus", "coro", "estribillo", "tornada", "refrain", "refrany",
                     "bridge", "puente", "pont", "pre-chorus", "prechorus", "pre-coro", "precoro", "pre-estribillo",
                     "outro", "final", "solo", "interlude", "interludio", "instrumental", "coda", "fin", "riff"]
        guard let first = lower.split(separator: " ").first.map(String.init),
              words.contains(where: { first.hasPrefix($0) }) else { return bracketed ? (ChordName(s) == nil ? s : nil) : nil }
        // «Intro: C G Am F» isn't a bare header; the chords are handled as a line.
        if s.split(separator: " ").count > 3 { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func sectionKind(_ name: String) -> String {
        let lower = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        if ["chorus", "coro", "estribillo", "tornada", "refrain", "refrany"].contains(where: { lower.hasPrefix($0) }) { return "chorus" }
        if ["bridge", "puente", "pont"].contains(where: { lower.hasPrefix($0) }) { return "bridge" }
        if ["verse", "verso", "estrofa"].contains(where: { lower.hasPrefix($0) }) { return "verse" }
        return "part"
    }

    private static func firstWords(_ text: String) -> String {
        let line = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    private static func convert(_ text: String, fallbackTitle: String?) -> (source: String, title: String, artist: String?) {
        var lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ") }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }

        var title: String?, artist: String?, key: String?, capo: Int?, tempo: Int?
        // Head: title, maybe the artist, «Tono: G» / «Capo 2» lines, until the first chords.
        var head = 0, texts = 0
        while head < lines.count, head < 8 {
            let t = lines[head].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { head += 1; continue }
            if isChordLine(t) || sectionHeader(t) != nil { break }
            if let k = metadata(t, ["tono", "key", "tonalidad", "tonalitat", "to"]) {
                key = k.split(separator: " ").first.map(String.init); head += 1; continue
            }
            if let c = metadata(t, ["capo", "cejilla", "cejuela", "capodastre", "capotasto"]) {
                capo = Int(c.filter(\.isNumber)); head += 1; continue
            }
            if let b = metadata(t, ["tempo", "bpm"]) { tempo = Int(b.filter(\.isNumber)); head += 1; continue }
            if texts == 0 {
                (title, artist) = splitTitle(t)
            } else if texts == 1, artist == nil, t.count < 60 {
                artist = t
            } else { break }
            texts += 1
            head += 1
        }
        title = title ?? fallbackTitle
        // «Title — Tradicional — Tono: C» on one line.
        if let a = artist, let k = a.range(of: #"(?i)(tono|key|to)\s*:\s*\S+"#, options: .regularExpression) {
            key = key ?? String(a[k].split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces)
            let rest = a.replacingCharacters(in: k, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " —-–,·|"))
            artist = rest.isEmpty ? nil : rest
        }

        var out: [String] = ["{title: \(title ?? firstWords(text))}"]
        if let artist { out.append("{artist: \(artist)}") }
        if let key { out.append("{key: \(key)}") }
        if let capo { out.append("{capo: \(capo)}") }
        if let tempo { out.append("{tempo: \(tempo)}") }
        out.append("")

        var open: String?
        func closeSection() { if let o = open { out.append("{end_of_\(o)}"); open = nil } }

        var i = head
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { out.append(""); i += 1; continue }
            if let name = sectionHeader(trimmed) {
                closeSection()
                let kind = sectionKind(name)
                out.append("{start_of_\(kind): \(name)}")
                open = kind
                i += 1
                continue
            }
            // «Intro: C G Am F»: label and chords on one line.
            if let colon = trimmed.firstIndex(of: ":"), sectionHeader(String(trimmed[...colon])) != nil,
               isChordLine(String(trimmed[trimmed.index(after: colon)...])) {
                closeSection()
                let name = String(trimmed[..<colon])
                let kind = sectionKind(name)
                out.append("{start_of_\(kind): \(name)}")
                open = kind
                out.append(inlineChords(String(trimmed[trimmed.index(after: colon)...]), over: ""))
                i += 1
                continue
            }
            if isChordLine(line) {
                let next = i + 1 < lines.count ? lines[i + 1] : ""
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if !nextTrimmed.isEmpty, !isChordLine(next), sectionHeader(nextTrimmed) == nil {
                    out.append(inlineChords(line, over: next))
                    i += 2
                } else {
                    out.append(inlineChords(line, over: ""))
                    i += 1
                }
                continue
            }
            // Tablature («e|---0---») stays as text.
            if trimmed.range(of: #"^[eBGDAEb]\s*\|[-0-9hpbrx/\\|~ ]+$"#, options: .regularExpression) != nil {
                out.append("{start_of_tab}")
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).range(of: #"^[eBGDAEb]\s*\|"#, options: .regularExpression) != nil {
                    out.append(lines[i]); i += 1
                }
                out.append("{end_of_tab}")
                continue
            }
            out.append(line.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))
            i += 1
        }
        closeSection()
        return (out.joined(separator: "\n"), title ?? firstWords(text), artist)
    }

    /// «Bohemian Rhapsody - Queen» → title and artist.
    private static func splitTitle(_ line: String) -> (String, String?) {
        for sep in [" — ", " – ", " - ", " by ", " | "] {
            if let r = line.range(of: sep) {
                let a = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let b = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty, !b.isEmpty { return (a, b) }
            }
        }
        return (line, nil)
    }

    private static func metadata(_ line: String, _ names: [String]) -> String? {
        let lower = line.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        for name in names {
            guard lower.hasPrefix(name) else { continue }
            let rest = line.dropFirst(name.count).trimmingCharacters(in: CharacterSet(charactersIn: " :=.-"))
            if !rest.isEmpty, rest.count < 20 { return rest }
        }
        return nil
    }

    /// Chords from a chord line placed into the lyric line below at the same columns.
    static func inlineChords(_ chordLine: String, over lyric: String) -> String {
        var placed: [(col: Int, chord: String)] = []
        let chars = Array(chordLine)
        var c = 0
        while c < chars.count {
            if chars[c] == " " { c += 1; continue }
            var e = c
            while e < chars.count, chars[e] != " " { e += 1 }
            let token = String(chars[c..<e])
            if ChordName(token) != nil { placed.append((c, token)) }
            c = e
        }
        if lyric.isEmpty { return placed.map { "[\($0.chord)]" }.joined(separator: " ") }
        var text = Array(lyric.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))
        let last = placed.last?.col ?? 0
        if text.count < last { text += Array(repeating: " ", count: last - text.count) }
        var out = ""
        var pos = 0
        for p in placed {
            if p.col > pos { out += String(text[pos..<min(p.col, text.count)]); pos = p.col }
            out += "[\(p.chord)]"
        }
        if pos < text.count { out += String(text[pos...]) }
        // Padding added after the lyrics only to reach a chord isn't text.
        return out.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }

    /// The key whose scale holds most of the chords (first and last chord break ties).
    static func guessKey(_ chords: [ChordName]) -> String? {
        guard !chords.isEmpty else { return nil }
        let major = [0, 2, 4, 5, 7, 9, 11]
        let qualities: [Int: Bool] = [0: false, 2: true, 4: true, 5: false, 7: false, 9: true, 11: true] // degree → minor?
        var best: (score: Double, root: Int, minor: Bool)?
        for tonic in 0..<12 {
            var score = 0.0
            for c in chords {
                let rel = ((c.root - tonic) % 12 + 12) % 12
                guard major.contains(rel) else { score -= 0.5; continue }
                let minorChord = [.minor, .minor7, .minor6, .halfDiminished, .diminished].contains(c.quality)
                score += (qualities[rel] == minorChord || c.quality == .sus4 || c.quality == .sus2 || c.quality == .power) ? 1 : 0.3
            }
            // Relative major vs. minor: the chord the song starts or ends on.
            let first = chords[0], last = chords[chords.count - 1]
            for (root, minor) in [(tonic, false), ((tonic + 9) % 12, true)] {
                var s = score
                if first.root == root { s += 1.5 }
                if last.root == root { s += 2 }
                let firstMinor = [.minor, .minor7].contains(first.quality)
                if first.root == root && firstMinor == minor { s += 0.5 }
                if best == nil || s > best!.score { best = (s, root, minor) }
            }
        }
        guard let b = best else { return nil }
        let flat = chords.contains { $0.flat } || [5, 10, 3, 8, 1].contains(b.minor ? (b.root + 3) % 12 : b.root)
        let latin = chords.first?.latin ?? false
        return ChordName.noteName(b.root, flat: flat, latin: latin) + (b.minor ? "m" : "")
    }
}
