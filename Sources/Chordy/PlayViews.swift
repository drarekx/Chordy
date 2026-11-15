import SwiftUI

// MARK: - Header

/// Sounding chord names and the key stepper.
struct PlayHeader: View {
    @ObservedObject var engine: ChordEngine

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(tr("Acorde"))
                Text(engine.activeSymbols.isEmpty ? tr("Toca un acorde") : engine.activeSymbols.joined(separator: " · "))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(engine.activeSymbols.isEmpty ? Theme.text3 : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer(minLength: 8)
            if engine.octaveDown {
                Text("8vb")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 6))
                    .help(tr("Octava abajo (espacio)"))
            }
            HStack(spacing: 0) {
                IconButton(symbol: "chevron.left", label: tr("Tono anterior (Z)")) { engine.shiftTonic(-1) }
                VStack(spacing: 0) {
                    SectionLabel(tr("Tono"))
                    Text("\(engine.tonic.rawValue) \(engine.flavor.label)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .frame(minWidth: 110)
                IconButton(symbol: "chevron.right", label: tr("Tono siguiente (C)")) { engine.shiftTonic(1) }
            }
            .padding(4)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line) }
        }
    }
}

// MARK: - Scrolling chord display

/// Piano-roll of recent chords: time flows right → left, one row per degree.
struct ChordDisplay: View {
    @ObservedObject var engine: ChordEngine

    private let labelWidth: CGFloat = 38
    private let paddingY: CGFloat = 10

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(context, size, at: now())
            }
            .id(timeline.date)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
        .accessibilityLabel(tr("Historial de acordes"))
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, at time: Double) {
        let rows = 7
        let rowHeight = (size.height - paddingY * 2) / CGFloat(rows)
        let rowTop = { (row: Int) in paddingY + CGFloat(rows - row) * rowHeight }

        for row in 1...rows {
            let y = rowTop(row).rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(Theme.line), lineWidth: 1)
            context.draw(Text(Music.numeral(row, engine.flavor))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.text3),
                         at: CGPoint(x: 8, y: rowTop(row) + rowHeight / 2), anchor: .leading)
        }

        let window = engine.windowSeconds
        let start = time - window
        let plotWidth = size.width - labelWidth
        let toX = { (t: Double) in labelWidth + CGFloat((t - start) / window) * plotWidth }
        let barHeight = rowHeight * 0.62

        func bar(_ row: Int, _ source: ChordSource, _ from: Double, _ to: Double) {
            guard to >= start, from <= time else { return }
            let x = toX(max(from, start))
            let w = max(1, toX(min(to, time)) - x)
            let rect = CGRect(x: x, y: rowTop(row) + (rowHeight - barHeight) / 2, width: w, height: barHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(source == .user ? Theme.accentFill : Theme.accentBorder))
        }
        for event in engine.history { bar(event.row, event.source, event.start, event.end) }
        for chord in engine.sounding { bar(chord.degree, chord.source, chord.start, time) }

        // "Now" line at the right edge.
        var nowLine = Path()
        nowLine.move(to: CGPoint(x: size.width - 1, y: paddingY))
        nowLine.addLine(to: CGPoint(x: size.width - 1, y: size.height - paddingY))
        context.stroke(nowLine, with: .color(Theme.text2), lineWidth: 1.5)
    }
}

// MARK: - Mode and tempo

struct PlayControls: View {
    @ObservedObject var engine: ChordEngine

    var body: some View {
        HStack {
            SegmentedControl(options: Flavor.allCases.map { ($0.label, $0) },
                             selection: Binding(get: { engine.flavor }, set: { engine.flavor = $0 }))
                .help(tr("Modo (Q / E)"))
            Spacer()
            HStack(spacing: 6) {
                IconButton(symbol: "minus", label: tr("Más lento (−)"), kind: .secondary) { engine.setBpm(engine.bpm - 1) }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(engine.bpm)").font(.system(size: 15, weight: .bold, design: .monospaced))
                    Text("bpm").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                }
                .frame(minWidth: 72)
                IconButton(symbol: "plus", label: tr("Más rápido (+)"), kind: .secondary) { engine.setBpm(engine.bpm + 1) }
            }
        }
    }
}

// MARK: - Color wheel

/// Eight color sectors around a hub, like a joystick; drag across sectors to change color.
struct ChordWheel: View {
    @ObservedObject var engine: ChordEngine
    @State private var current: Direction?

    /// Counter-clockwise from east, one 45° sector each.
    private static let sectors: [Direction] = [.right, .upRight, .up, .upLeft, .left, .downLeft, .down, .downRight]
    private let innerRatio = 0.38

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let outer = size / 2 - 1
            let inner = outer * innerRatio
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(Self.sectors.indices, id: \.self) { i in
                    let direction = Self.sectors[i]
                    let active = engine.direction == direction
                    let path = sector(center: center, outer: outer, inner: inner, index: i)
                    path.fill(active ? Theme.accentFill : Theme.card)
                    path.stroke(Theme.lineStrong, lineWidth: 1)
                    let mid = Angle.degrees(Double(i) * 45)
                    let r = (outer + inner) / 2
                    Text(direction.color.short)
                        .font(.system(size: 12, weight: active ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(active ? Theme.onAccent : Theme.text2)
                        .position(x: center.x + r * cos(mid.radians), y: center.y - r * sin(mid.radians))
                }
                Circle()
                    .fill(engine.color == .diatonic ? Theme.accentSoft : Theme.control)
                    .overlay { Circle().strokeBorder(Theme.accentBorder, lineWidth: 2) }
                    .frame(width: inner * 1.7, height: inner * 1.7)
                    .position(center)
                Text(engine.color.short)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accentText)
                    .position(center)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in select(direction(at: value.location, center: center, inner: inner, outer: outer)) }
                    .onEnded { _ in select(nil) }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(tr("Color del acorde (W A S D)"))
    }

    private func sector(center: CGPoint, outer: CGFloat, inner: CGFloat, index: Int) -> Path {
        // SwiftUI angles grow clockwise (y down): negate for counter-clockwise sectors.
        let start = Angle.degrees(-(Double(index) * 45 - 22.5))
        let end = Angle.degrees(-(Double(index) * 45 + 22.5))
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: true)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: false)
        path.closeSubpath()
        return path
    }

    private func direction(at point: CGPoint, center: CGPoint, inner: CGFloat, outer: CGFloat) -> Direction? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= inner, distance <= outer * 1.15 else { return nil }
        var deg = atan2(-dy, dx) * 180 / .pi
        if deg < 0 { deg += 360 }
        return Self.sectors[Int((deg + 22.5) / 45) % 8]
    }

    private func select(_ next: Direction?) {
        guard next != current else { return }
        if let current { engine.setDirection(current, pressed: false) }
        current = next
        if let next { engine.setDirection(next, pressed: true) }
    }
}

// MARK: - Degree pads

struct DegreePads: View {
    @ObservedObject var engine: ChordEngine

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Music.degrees, id: \.self) { degree in
                DegreePad(engine: engine, degree: degree)
            }
        }
    }
}

private struct DegreePad: View {
    @ObservedObject var engine: ChordEngine
    let degree: Degree
    @State private var pressing = false

    var body: some View {
        let active = engine.heldDegrees.contains(degree)
            || engine.sounding.contains { $0.degree == degree && $0.source == .loop }
        VStack(alignment: .leading) {
            Text(String(Music.key(for: degree)).uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? Theme.onAccent : Theme.accentText)
            Spacer(minLength: 12)
            Text(Music.numeral(degree, engine.flavor))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(active ? Theme.onAccent : Theme.text2)
            Text(Music.symbol(engine.tonic, degree, engine.flavor, engine.color))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? Theme.onAccent : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 124, alignment: .leading)
        .background(active ? Theme.accentFill : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Theme.accentFill : Theme.line, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    engine.pressDegree(degree)
                }
                .onEnded { _ in
                    pressing = false
                    engine.releaseDegree(degree)
                }
        )
        .accessibilityLabel("\(Music.numeral(degree, engine.flavor)) \(Music.symbol(engine.tonic, degree, engine.flavor, engine.color))")
        .accessibilityAddTraits(.isButton)
    }
}
