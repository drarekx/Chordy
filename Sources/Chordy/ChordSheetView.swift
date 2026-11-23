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
                lineView(line).id(line.id)
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
        case .chords, .lyrics:
            let hasChords = line.segments.contains { $0.chord != nil }
            let hasText = line.segments.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            SheetFlow(lineSpacing: style.fontSize * 0.2) {
                ForEach(Array(units(line).enumerated()), id: \.offset) { _, unit in
                    unitView(unit, chordRow: hasChords, textRow: hasText)
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

    private func unitView(_ unit: Unit, chordRow: Bool, textRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if chordRow {
                if let chord = unit.chord {
                    chordLabel(chord, index: unit.index)
                } else {
                    Text(" ").font(chordFont).padding(.vertical, 2)
                }
            }
            if textRow {
                Text(unit.text.isEmpty ? " " : unit.text)
                    .font(.system(size: style.fontSize))
                    .foregroundStyle(style.text)
            }
        }
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
            .padding(.trailing, style.fontSize * 0.35)
        if let index, let onTapChord {
            label.contentShape(Rectangle()).onTapGesture { onTapChord(index) }
        } else {
            label
        }
    }
}

/// Lays its children left to right and wraps to a new row when the width runs out.
struct SheetFlow: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
