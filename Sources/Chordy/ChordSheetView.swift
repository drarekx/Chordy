import SwiftUI

// Draws a song with chords over the lyrics. Shared by Chordy (Mac) and Chordy Pads (iPad);
// each passes its own colors.

struct SheetStyle {
    var text: Color
    var text2: Color
    var text3: Color
    var chord: Color
    /// Chord being played now: fill and text.
    var current: Color
    var onCurrent: Color
    /// Chorus background.
    var chorus: Color
    var line: Color
    var fontSize: CGFloat
}

struct ChordSheetBody: View {
    /// Scroll target of a line («line-12»: plain numbers would also match sections).
    static func scrollId(_ line: Int) -> String { "line-\(line)" }

    let parsed: ParsedSheet
    let transpose: Int
    /// Chord being played now, if following.
    let position: Int?
    let style: SheetStyle
    var latin: Bool?
    var onTapChord: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: style.fontSize * 1.1) {
            ForEach(parsed.sections) { section in
                sectionView(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sectionView(_ section: SheetSection) -> some View {
        let chorus = section.kind == .chorus
        VStack(alignment: .leading, spacing: style.fontSize * 0.25) {
            if let name = section.name {
                Text(name.uppercased())
                    .font(.system(size: max(10, style.fontSize * 0.62), weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(chorus ? style.chord : style.text3)
                    .padding(.bottom, 2)
            }
            ForEach(section.lines) { line in
                lineView(line).id(ChordSheetBody.scrollId(line.id))
            }
        }
        .padding(.leading, chorus ? style.fontSize * 0.8 : 0)
        .padding(.vertical, chorus ? style.fontSize * 0.5 : 0)
        .overlay(alignment: .leading) {
            if chorus { RoundedRectangle(cornerRadius: 2).fill(style.chord.opacity(0.8)).frame(width: 3) }
        }
        .background(chorus ? style.chorus : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func lineView(_ line: SheetLine) -> some View {
        switch line.kind {
        case .empty:
            Color.clear.frame(height: style.fontSize * 0.5)
        case .comment:
            Text(line.text)
                .font(.system(size: style.fontSize * 0.8, weight: .medium).italic())
                .foregroundStyle(style.text2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(style.line, in: RoundedRectangle(cornerRadius: 6))
        case .tab:
            Text(line.text)
                .font(.system(size: style.fontSize * 0.75, design: .monospaced))
                .foregroundStyle(style.text2)
                .lineLimit(1)
        case .chords:
            // Chords and bar lines in one row, wrapping between bars.
            SheetFlow(spacing: style.fontSize * 0.35, lineSpacing: style.fontSize * 0.3) {
                ForEach(Array(line.segments.enumerated()), id: \.offset) { _, segment in
                    if let chord = segment.chord { chordLabel(chord, index: segment.index) }
                    let rest = segment.text.trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty {
                        ForEach(Array(rest.split(separator: " ").enumerated()), id: \.offset) { _, mark in
                            Text(String(mark)).font(chordFont).foregroundStyle(style.text3).fixedSize()
                        }
                    }
                }
            }
        case .lyrics:
            let hasChords = line.segments.contains { $0.chord != nil }
            let hasText = line.segments.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            ChordLineLayout(gap: style.fontSize * 0.3, lineSpacing: style.fontSize * 0.2, chordRow: hasChords, textRow: hasText) {
                ForEach(Array(units(line).enumerated()), id: \.offset) { _, unit in
                    if let chord = unit.chord {
                        chordLabel(chord, index: unit.index).layoutValue(key: SheetPartKey.self, value: .chord)
                    }
                    Text(unit.text.isEmpty ? " " : unit.text)
                        .font(.system(size: style.fontSize))
                        .foregroundStyle(style.text)
                        .fixedSize()
                        .layoutValue(key: SheetPartKey.self, value: .text)
                }
            }
        }
    }

    private struct Unit {
        var chord: String?
        var index: Int?
        var text: String
    }

    /// Words, each with the chord that starts on it, so long lines wrap between words.
    private func units(_ line: SheetLine) -> [Unit] {
        var out: [Unit] = []
        for segment in line.segments {
            var words: [String] = []
            var current = ""
            for ch in segment.text {
                current.append(ch)
                if ch == " " { words.append(current); current = "" }
            }
            if !current.isEmpty { words.append(current) }
            if words.isEmpty { words = [""] }
            for (i, w) in words.enumerated() {
                out.append(Unit(chord: i == 0 ? segment.chord : nil, index: i == 0 ? segment.index : nil, text: w))
            }
        }
        return out
    }

    private var chordFont: Font { .system(size: style.fontSize * 0.88, weight: .bold, design: .rounded) }

    @ViewBuilder
    private func chordLabel(_ written: String, index: Int?) -> some View {
        let shown = parsed.display(written, transpose: transpose, latin: latin)
        let isCurrent = index != nil && index == position
        let isNext = index != nil && position.map { index == $0 + 1 } == true
        let label = Text(shown)
            .font(chordFont)
            .foregroundStyle(isCurrent ? style.onCurrent : (index == nil ? style.text3 : style.chord))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(isCurrent ? style.current : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if isNext { RoundedRectangle(cornerRadius: 5).strokeBorder(style.current.opacity(0.7), lineWidth: 1.5) }
            }
            .padding(.leading, -4)
            .fixedSize()
        if let index, let onTapChord {
            label.contentShape(Rectangle()).onTapGesture { onTapChord(index) }
        } else {
            label
        }
    }
}

enum SheetPart { case chord, text }

struct SheetPartKey: LayoutValueKey {
    static let defaultValue = SheetPart.text
}

/// A line of lyrics with chords: words side by side as plain text, each chord above where its
/// word starts. A chord only pushes the words apart when it would touch the chord before it
/// («A[G]mazing» stays one word). Wraps between words when the width runs out.
struct ChordLineLayout: Layout {
    var gap: CGFloat
    var lineSpacing: CGFloat
    var chordRow: Bool
    var textRow: Bool

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let parts = subviews.map { $0[SheetPartKey.self] }
        let chordH = chordRow ? (zip(sizes, parts).filter { $0.1 == .chord }.map(\.0.height).max() ?? 0) : 0
        let textH = textRow ? (zip(sizes, parts).filter { $0.1 == .text }.map(\.0.height).max() ?? 0) : 0
        let rowH = chordH + textH
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var x: CGFloat = 0, y: CGFloat = 0, chordEnd = -CGFloat.infinity, widest: CGFloat = 0
        var pendingChord: Int?
        for i in subviews.indices {
            if parts[i] == .chord { pendingChord = i; continue }
            let tw = sizes[i].width
            let cw = pendingChord.map { sizes[$0].width } ?? 0
            var at = x
            if pendingChord != nil { at = max(at, chordEnd + gap) }
            if at > 0, at + max(tw, cw) > width {
                y += rowH + lineSpacing
                x = 0
                at = 0
                chordEnd = -.infinity
            }
            if let c = pendingChord {
                frames[c] = CGRect(x: at, y: y, width: cw, height: sizes[c].height)
                chordEnd = at + cw
            }
            frames[i] = CGRect(x: at, y: y + chordH, width: tw, height: textRow ? sizes[i].height : 0)
            x = at + tw
            widest = max(widest, x, chordEnd)
            pendingChord = nil
        }
        return (frames, CGSize(width: widest, height: y + rowH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = frames(proposal.width ?? .infinity, subviews).size
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (frames, _) = self.frames(bounds.width, subviews)
        for (i, view) in subviews.enumerated() {
            let f = frames[i]
            view.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}

/// Children side by side with `spacing`, wrapping to a new row when the width runs out.
struct SheetFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func frames(_ width: CGFloat, _ subviews: Subviews) -> ([CGRect], CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        var out: [CGRect] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowH + lineSpacing
                x = 0
                rowH = 0
            }
            out.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowH = max(rowH, size.height)
        }
        return (out, CGSize(width: widest, height: y + rowH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = frames(proposal.width ?? .infinity, subviews).1
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (frames, _) = self.frames(bounds.width, subviews)
        for (i, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + frames[i].minX, y: bounds.minY + frames[i].minY), proposal: ProposedViewSize(frames[i].size))
        }
    }
}
