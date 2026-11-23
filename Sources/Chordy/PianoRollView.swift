import SwiftUI

// Falling notes over a piano keyboard, for MIDI songs. Shared by Chordy (Mac) and Chordy Pads
// (iPad); each passes its colors and where the song is.

struct RollStyle {
    var background: Color
    var line: Color
    var text: Color
    var whiteKey: Color
    var blackKey: Color
    /// Keys the player holds.
    var held: Color
    /// Practice: notes being waited for.
    var expected: Color
    /// One color per track (cycled).
    var tracks: [Color]
}

struct PianoRoll: View {
    let score: MidiScore
    let transpose: Int
    let playing: Bool
    /// Song position in beats, read every frame.
    let beat: () -> Double
    var muted: Set<Int> = []
    var practice: Int?
    var expected: Set<Int> = []
    /// Keys the player holds now, read every frame.
    var held: () -> Set<Int> = { [] }
    let style: RollStyle
    /// Beats from the keyboard to the top.
    var window = 8.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !playing)) { _ in
            Canvas { context, size in draw(context, size) }
        }
        .background(style.background)
    }

    // MARK: Keys

    /// Visible keys: the song's range, widened to whole octaves (at least two).
    private var keyRange: ClosedRange<Int> {
        let r = score.range
        var lo = (r.lowerBound + transpose) / 12 * 12
        var hi = ((r.upperBound + transpose) / 12 + 1) * 12 - 1
        if hi - lo < 23 { lo = max(0, lo - 12); hi = min(127, max(hi, lo + 23)) }
        return max(0, lo)...min(127, hi)
    }

    private static func isBlack(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }

    /// x and width of each key in the range.
    private func keyFrames(_ width: CGFloat) -> [Int: (x: CGFloat, w: CGFloat)] {
        let range = keyRange
        let whites = range.filter { !Self.isBlack($0) }
        let ww = width / CGFloat(max(1, whites.count))
        var out: [Int: (CGFloat, CGFloat)] = [:]
        var i = 0
        for p in range {
            if Self.isBlack(p) {
                out[p] = (CGFloat(i) * ww - ww * 0.32, ww * 0.64)
            } else {
                out[p] = (CGFloat(i) * ww, ww)
                i += 1
            }
        }
        return out
    }

    private func color(_ track: MidiScore.Track) -> Color {
        style.tracks.isEmpty ? style.held : style.tracks[track.id % style.tracks.count]
    }

    // MARK: Drawing

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let now = beat()
        let keysHeight = min(90, max(44, size.height * 0.2))
        let rollHeight = size.height - keysHeight
        let frames = keyFrames(size.width)
        let perBeat = rollHeight / window
        func y(_ b: Double) -> CGFloat { rollHeight - CGFloat(b - now) * perBeat }

        // Bar lines and numbers.
        let firstBar = max(0, Int((now / score.barBeats).rounded(.down)))
        var bar = firstBar
        while Double(bar) * score.barBeats < now + window {
            let yy = y(Double(bar) * score.barBeats)
            if yy <= rollHeight {
                context.fill(Path(CGRect(x: 0, y: yy, width: size.width, height: 1)), with: .color(style.line))
                context.draw(Text("\(bar + 1)").font(.system(size: 10, weight: .semibold)).foregroundColor(style.text),
                             at: CGPoint(x: 4, y: yy - 2), anchor: .bottomLeading)
            }
            bar += 1
        }
        // Octave lines (at each C) to find your way.
        for (p, f) in frames where p % 12 == 0 {
            context.fill(Path(CGRect(x: f.x, y: 0, width: 1, height: rollHeight)), with: .color(style.line.opacity(0.6)))
        }

        // Notes, and which keys sound now.
        var sounding: [Int: Color] = [:]
        for track in score.tracks where !track.drums {
            let isMuted = muted.contains(track.id)
            let isPractice = track.id == practice
            let base = color(track)
            let shading: GraphicsContext.Shading = .color(isMuted ? base.opacity(0.25) : base)
            let notes = track.notes
            // First note that may still be visible (notes are sorted; few last over 16 beats).
            var lo = 0, hi = notes.count
            while lo < hi { let mid = (lo + hi) / 2; if notes[mid].start < now - 16 { lo = mid + 1 } else { hi = mid } }
            for n in notes[lo...] {
                if n.start > now + window { break }
                let end = n.start + n.length
                guard end > now - 0.5 else { continue }
                let pitch = n.pitch + transpose
                guard let f = frames[pitch] else { continue }
                let top = y(end), bottom = min(y(n.start), rollHeight)
                guard bottom > 0, top < rollHeight else { continue }
                let rect = CGRect(x: f.x + 1, y: max(0, top), width: f.w - 2, height: max(3, bottom - max(0, top)))
                let path = Path(roundedRect: rect, cornerRadius: min(4, f.w / 3))
                context.fill(path, with: shading)
                if isPractice { context.stroke(path, with: .color(style.text), lineWidth: 1.5) }
                if n.start <= now, end > now, !isMuted { sounding[pitch] = base }
            }
        }

        // Keyboard.
        let held = self.held()
        let top = rollHeight
        context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: 2)), with: .color(style.line))
        for p in keyRange where !Self.isBlack(p) {
            guard let f = frames[p] else { continue }
            let rect = CGRect(x: f.x + 0.5, y: top + 2, width: f.w - 1, height: keysHeight - 2)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(keyColor(p, held: held, sounding: sounding) ?? style.whiteKey))
            if expected.contains(p) || (!expected.isEmpty && expectedPC(p)) {
                context.stroke(path, with: .color(style.expected), lineWidth: 3)
            }
            if p % 12 == 0 {
                context.draw(Text("C\(p / 12 - 1)").font(.system(size: 9)).foregroundColor(.black.opacity(0.5)),
                             at: CGPoint(x: f.x + f.w / 2, y: top + keysHeight - 4), anchor: .bottom)
            }
        }
        for p in keyRange where Self.isBlack(p) {
            guard let f = frames[p] else { continue }
            let rect = CGRect(x: f.x, y: top + 2, width: f.w, height: (keysHeight - 2) * 0.62)
            let path = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(path, with: .color(keyColor(p, held: held, sounding: sounding) ?? style.blackKey))
            if expected.contains(p) || (!expected.isEmpty && expectedPC(p)) {
                context.stroke(path, with: .color(style.expected), lineWidth: 2.5)
            }
        }
    }

    /// Any octave counts in practice unless the exact note is expected somewhere in range.
    private func expectedPC(_ p: Int) -> Bool {
        expected.contains { $0 % 12 == p % 12 } && !expected.contains { keyRange.contains($0) }
    }

    private func keyColor(_ p: Int, held: Set<Int>, sounding: [Int: Color]) -> Color? {
        if held.contains(p) { return style.held }
        return sounding[p]
    }
}
