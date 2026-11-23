import Foundation

// A song imported from a MIDI file: its notes by track, tempo, bars and karaoke lyrics.
// Shared by Chordy (Mac) and Chordy Pads (iPad, which draws the falling notes). The Mac reads
// the file (`MidiFileReader`), finds the chords and writes them as ChordPro so the song also
// shows (and follows) as chords over the lyrics.

struct MidiScore: Codable, Equatable {
    struct Note: Codable, Equatable {
        var pitch: Int
        /// Beats (quarter notes) from the start.
        var start: Double
        var length: Double
        var velocity: Int

        private enum CodingKeys: String, CodingKey { case pitch = "p", start = "s", length = "l", velocity = "v" }
    }

    struct Track: Codable, Equatable, Identifiable {
        var id: Int
        var name: String
        var channel: Int
        /// General MIDI program 0…127 (kit number for drums).
        var program: Int
        var drums: Bool
        var notes: [Note]
    }

    struct Lyric: Codable, Equatable {
        var beat: Double
        var text: String
    }

    /// A chord found in the music, from `beat` until the next one.
    struct ChordAt: Codable, Equatable {
        var beat: Double
        var name: String
    }

    /// Tempo from `beat` on.
    struct Tempo: Codable, Equatable {
        var beat: Double
        var bpm: Double
    }

    /// Time signature from `beat` on: quarter notes per bar and how it's written.
    struct Meter: Codable, Equatable {
        var beat: Double
        var barBeats: Double
        var label: String
    }

    var tracks: [Track]
    /// First tempo in the file.
    var bpm: Double
    /// Quarter notes per bar (6/8 → 3).
    var barBeats: Double
    var timeSignature: String
    var lengthBeats: Double
    var lyrics: [Lyric]
    var chords: [ChordAt]
    /// Key signature from the file («G», «Em»), if any.
    var key: String?
    /// Every tempo and time signature change (nil in songs imported before they were read).
    var tempos: [Tempo]?
    var meters: [Meter]?

    /// Where each bar starts (beats), following the time signature changes.
    var barStarts: [Double] {
        let meters = (self.meters?.isEmpty == false ? self.meters! : [Meter(beat: 0, barBeats: barBeats, label: timeSignature)])
        var out: [Double] = []
        var b = 0.0, m = 0
        while b < lengthBeats - 1e-6 || out.isEmpty {
            while m + 1 < meters.count, meters[m + 1].beat <= b + 1e-6 { m += 1 }
            out.append(b)
            var next = b + max(0.25, meters[m].barBeats)
            // A new time signature starts a new bar.
            if m + 1 < meters.count, meters[m + 1].beat < next - 1e-6, meters[m + 1].beat > b + 1e-6 { next = meters[m + 1].beat }
            b = next
            if out.count > 100_000 { break }
        }
        return out
    }

    var bars: Int { barStarts.count }

    /// Bar (0-based) that `beat` falls in, given `barStarts`.
    static func bar(at beat: Double, in starts: [Double]) -> Int {
        var lo = 0, hi = starts.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= beat + 1e-6 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Lowest and highest pitched (non-drum) note.
    var range: ClosedRange<Int> {
        let pitches = tracks.filter { !$0.drums }.flatMap { $0.notes.map(\.pitch) }
        guard let lo = pitches.min(), let hi = pitches.max() else { return 48...84 }
        return lo...hi
    }

    /// Index of the chord sounding at `beat` (−1 before the first).
    /// (Chords are found per half bar; see `MidiChords`.)
    func chordIndex(at beat: Double) -> Int {
        var lo = 0, hi = chords.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chords[mid].beat <= beat + 1e-6 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

// MARK: - Chords from notes

enum MidiChords {
    private static let shapes: [(suffix: String, intervals: [Int], penalty: Double)] = [
        ("", [0, 4, 7], 0), ("m", [0, 3, 7], 0), ("7", [0, 4, 7, 10], 0.06), ("m7", [0, 3, 7, 10], 0.06),
        ("maj7", [0, 4, 7, 11], 0.08), ("6", [0, 4, 7, 9], 0.1), ("dim", [0, 3, 6], 0.12), ("sus4", [0, 5, 7], 0.12),
    ]

    /// The chords, half a bar at a time (a whole bar when both halves agree), repeats merged.
    static func detect(_ score: MidiScore) -> [(beat: Double, root: Int, suffix: String)] {
        let notes = score.tracks.filter { !$0.drums }.flatMap(\.notes)
        guard !notes.isEmpty else { return [] }
        // Half bars (whole bars when they're short), following the time signature changes.
        let starts = score.barStarts
        var edges: [Double] = []
        for (i, a) in starts.enumerated() {
            let b = i + 1 < starts.count ? starts[i + 1] : score.lengthBeats
            edges.append(a)
            if b - a >= 3 { edges.append(a + (b - a) / 2) }
        }
        edges.append(score.lengthBeats)
        let windows = edges.count - 1
        guard windows > 0 else { return [] }
        func window(at beat: Double) -> Int {
            var lo = 0, hi = windows - 1, found = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if edges[mid] <= beat + 1e-6 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return found
        }
        // Notes by window they touch, so each window only looks at its own.
        var byWindow = [[MidiScore.Note]](repeating: [], count: windows)
        for n in notes {
            let first = window(at: n.start), last = window(at: n.start + n.length - 1e-3)
            if first <= last { for w in first...last { byWindow[w].append(n) } }
        }
        var out: [(beat: Double, root: Int, suffix: String)] = []
        for w in 0..<windows {
            let a = edges[w], b = edges[w + 1]
            var weights = [Double](repeating: 0, count: 12)
            var bass: (pitch: Int, weight: Double)?
            for n in byWindow[w] {
                let overlap = min(b, n.start + n.length) - max(a, n.start)
                guard overlap > 0 else { continue }
                // Short notes (passing tones, ornaments) count less than held ones.
                let weight = overlap * (0.4 + 0.6 * Double(n.velocity) / 127)
                weights[n.pitch % 12] += weight
                if bass == nil || n.pitch < bass!.pitch { bass = (n.pitch, weight) }
            }
            let total = weights.reduce(0, +)
            guard total > 0.05 else { continue }
            var best: (score: Double, root: Int, suffix: String)?
            for root in 0..<12 {
                for shape in shapes {
                    let tones = Set(shape.intervals.map { (root + $0) % 12 })
                    var s = 0.0
                    for pc in 0..<12 {
                        if tones.contains(pc) { s += weights[pc] * (pc == root ? 1.2 : 1) } else { s -= weights[pc] * 0.6 }
                    }
                    // Every chord tone should be there: a missing third or fifth costs.
                    for pc in tones where weights[pc] < total * 0.02 { s -= total * 0.18 }
                    s -= total * shape.penalty
                    if let bass {
                        if bass.pitch % 12 == root { s += total * 0.25 } else if tones.contains(bass.pitch % 12) { s += total * 0.05 }
                    }
                    if best == nil || s > best!.score { best = (s, root, shape.suffix) }
                }
            }
            guard let best, best.score > total * 0.2 else { continue }
            // Same root again (G → G7 as the melody passes an F): still the same chord.
            if let last = out.last, last.root == best.root { continue }
            out.append((a, best.root, best.suffix))
        }
        return out
    }

    /// Chords named for the score's key (flats in flat keys).
    static func named(_ score: MidiScore) -> [MidiScore.ChordAt] {
        let found = detect(score)
        let plain = found.map { ChordName(root: $0.root, suffix: $0.suffix) }
        let key = score.key ?? ChordSheetImport.guessKey(plain)
        let flat: Bool = {
            guard let k = key.flatMap(ChordName.init) else { return false }
            let minor = k.quality == .minor
            return [5, 10, 3, 8, 1, 6].contains((k.root + (minor ? 3 : 0)) % 12) || k.flat
        }()
        return found.map { MidiScore.ChordAt(beat: $0.beat, name: ChordName(root: $0.root, suffix: $0.suffix, flat: flat).symbol()) }
    }

    // MARK: ChordPro

    /// The song as ChordPro: the lyrics with the chords where they fall, or bars of chords
    /// four to a line when there are no lyrics. Every chord in `score.chords` appears once, in
    /// order, so the n-th chord of the sheet is `score.chords[n]`.
    static func chordPro(_ score: MidiScore, title: String, artist: String?) -> String {
        var out = ["{title: \(title)}"]
        if let artist { out.append("{artist: \(artist)}") }
        if let key = score.key ?? ChordSheetImport.guessKey(score.chords.compactMap { ChordName($0.name) }) {
            out.append("{key: \(key)}")
        }
        out.append("{tempo: \(Int(score.bpm.rounded()))}")
        out.append("{time: \(score.timeSignature)}")
        out.append("")
        let chords = score.chords
        if lyricLines(score).isEmpty {
            // Four bars a line: «[C]      [G]      [Am]     [F]».
            var line = ""
            var bar = 0
            var i = 0
            let starts = score.barStarts
            let bars = starts.count
            while bar < bars {
                let b = bar + 1 < bars ? starts[bar + 1] : score.lengthBeats + 1
                var cell: [String] = []
                while i < chords.count, chords[i].beat < b - 1e-6 {
                    cell.append("[\(chords[i].name)]")
                    i += 1
                }
                line += "| " + (cell.isEmpty ? "%" : cell.joined(separator: " ")) + " "
                bar += 1
                if bar % 4 == 0 || bar == bars {
                    out.append(line + "|")
                    line = ""
                }
            }
            return out.joined(separator: "\n")
        }
        // Lyrics: each chord goes before the first syllable at or after it.
        var i = 0
        for line in lyricLines(score) {
            if line.isEmpty { out.append(""); continue }
            var text = ""
            for syllable in line {
                while i < chords.count, chords[i].beat <= syllable.beat + 0.25 {
                    text += "[\(chords[i].name)]"
                    i += 1
                }
                text += syllable.text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            }
            out.append(text)
        }
        if i < chords.count {
            out.append("")
            out.append(chords[i...].map { "[\($0.name)]" }.joined(separator: " "))
        }
        return out.joined(separator: "\n")
    }

    /// Karaoke syllables split into lines («/» new line, «\\» new verse, or line breaks in the text).
    static func lyricLines(_ score: MidiScore) -> [[MidiScore.Lyric]] {
        var lines: [[MidiScore.Lyric]] = []
        var current: [MidiScore.Lyric] = []
        func breakLine(blank: Bool) {
            if !current.isEmpty { lines.append(current); current = [] }
            if blank, lines.last?.isEmpty == false { lines.append([]) }
        }
        for l in score.lyrics {
            var text = l.text
            if text.hasPrefix("\\") { breakLine(blank: true); text.removeFirst() }
            else if text.hasPrefix("/") { breakLine(blank: false); text.removeFirst() }
            let endsLine = text.hasSuffix("\r") || text.hasSuffix("\n")
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if !text.isEmpty { current.append(MidiScore.Lyric(beat: l.beat, text: text)) }
            if endsLine { breakLine(blank: false) }
        }
        breakLine(blank: false)
        return lines
    }
}

// MARK: - Time

/// Beats ↔ seconds through every tempo change of a song.
struct TempoMap {
    private var beats: [Double] = [0]
    private var seconds: [Double] = [0]
    private var bpms: [Double]

    init(_ score: MidiScore) {
        let tempos = (score.tempos ?? []).filter { $0.bpm > 0 }.sorted { $0.beat < $1.beat }
        bpms = [tempos.first(where: { $0.beat <= 1e-6 })?.bpm ?? score.bpm]
        for t in tempos where t.beat > 1e-6 {
            let last = beats.count - 1
            seconds.append(seconds[last] + (t.beat - beats[last]) * 60 / bpms[last])
            beats.append(t.beat)
            bpms.append(t.bpm)
        }
    }

    private func segment(beat: Double) -> Int {
        var lo = 0, hi = beats.count - 1, found = 0
        while lo <= hi { let mid = (lo + hi) / 2; if beats[mid] <= beat { found = mid; lo = mid + 1 } else { hi = mid - 1 } }
        return found
    }

    private func segment(seconds s: Double) -> Int {
        var lo = 0, hi = seconds.count - 1, found = 0
        while lo <= hi { let mid = (lo + hi) / 2; if seconds[mid] <= s { found = mid; lo = mid + 1 } else { hi = mid - 1 } }
        return found
    }

    func seconds(at beat: Double) -> Double {
        let i = segment(beat: beat)
        return seconds[i] + (beat - beats[i]) * 60 / bpms[i]
    }

    func beat(atSeconds s: Double) -> Double {
        let i = segment(seconds: s)
        return beats[i] + (s - seconds[i]) * bpms[i] / 60
    }

    func bpm(at beat: Double) -> Double { bpms[segment(beat: beat)] }
}
