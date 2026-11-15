import SwiftUI

/// A live drawing of a keyboard: keys light up as you press them, and every key, pad, knob
/// and button shows what it is mapped to. Launchkey 25 MK2 and Yamaha PSR-E453 are drawn
/// after the real ones; any other keyboard gets a plain keybed.
struct DeviceDrawing: View {
    let config: KeyboardConfig
    @ObservedObject var midi: MidiController
    @ObservedObject var engine: ChordEngine
    @ObservedObject var drums: DrumMachine

    enum Model { case launchkey25, psrE453, generic }

    var model: Model {
        if config.device.localizedCaseInsensitiveContains("launchkey") { return .launchkey25 }
        if config.device == "Digital Keyboard" { return .psrE453 }
        return .generic
    }

    private var aspect: CGFloat {
        switch model {
        case .launchkey25: return 1.75
        case .psrE453: return 2.6
        case .generic: return 3.2
        }
    }

    var body: some View {
        Canvas { context, size in
            switch model {
            case .launchkey25: drawLaunchkey(context, size)
            case .psrE453: drawYamaha(context, size)
            case .generic: drawKeybed(context, CGRect(origin: .zero, size: size), low: max(0, config.low),
                                      high: min(127, max(config.low + 24, min(config.high, config.low + 60))))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityLabel(tr("Dibujo de %@", config.name))
    }

    // MARK: Shared pieces

    private var device: String { config.device }

    private func text(_ context: GraphicsContext, _ s: String, _ p: CGPoint, size: CGFloat, color: Color,
                      weight: Font.Weight = .medium, anchor: UnitPoint = .center) {
        context.draw(Text(s).font(.system(size: size, weight: weight)).foregroundColor(color), at: p, anchor: anchor)
    }

    /// White and black keys from `low` to `high`, lit by what this device holds.
    private func drawKeybed(_ context: GraphicsContext, _ r: CGRect, low: Int, high: Int) {
        let black: Set<Int> = [1, 3, 6, 8, 10]
        let held = midi.liveNotes[device] ?? []
        let from = black.contains(low % 12) ? low - 1 : low
        let to = black.contains(high % 12) ? high + 1 : high
        let whites = (from...to).filter { !black.contains($0 % 12) }
        let w = r.width / CGFloat(max(1, whites.count))
        let labelSize = min(10, max(6, w * 0.42))
        var xs = [Int: CGFloat]()
        for (i, n) in whites.enumerated() { xs[n] = r.minX + CGFloat(i) * w }
        for n in whites {
            let key = CGRect(x: xs[n]! + 0.6, y: r.minY, width: w - 1.2, height: r.height)
            let on = held.contains(n)
            context.fill(Path(roundedRect: key, cornerRadius: min(4, w * 0.18)), with: .color(on ? config.tint : Color(white: 0.93)))
            if on {
                context.fill(Path(roundedRect: key.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: key.height * 0.02),
                                  cornerRadius: min(4, w * 0.18)), with: .color(config.tint.opacity(0.35)))
            }
            if let label = midi.keyLabel(config, note: n), w > 9 {
                text(context, label, CGPoint(x: key.midX, y: key.maxY - labelSize - 2), size: labelSize,
                     color: on ? .white : Color(white: 0.35), weight: .semibold)
            }
        }
        for n in from...to where black.contains(n % 12) {
            guard let left = xs[n - 1] else { continue }
            let bw = w * 0.6
            let key = CGRect(x: left + w - bw / 2, y: r.minY, width: bw, height: r.height * 0.62)
            let on = held.contains(n)
            context.fill(Path(roundedRect: key, cornerRadius: min(3, bw * 0.15)), with: .color(on ? config.tint : Color(white: 0.1)))
            if let label = midi.keyLabel(config, note: n), w > 13, config.layout != .notes {
                text(context, label, CGPoint(x: key.midX, y: key.maxY - labelSize), size: labelSize * 0.85,
                     color: on ? .white : Color(white: 0.75), weight: .semibold)
            }
        }
    }

    private func knob(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, value: Double?, label: String?) {
        let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(ring, with: .color(Color(white: 0.12)))
        context.stroke(ring, with: .color(Color(white: 0.32)), lineWidth: 1.2)
        let v = value ?? 0.5
        let angle = Angle.degrees(135 + 270 * v)
        var arc = Path()
        arc.addArc(center: center, radius: radius + 3, startAngle: .degrees(135), endAngle: angle, clockwise: false)
        if value != nil { context.stroke(arc, with: .color(config.tint), lineWidth: 2) }
        var tick = Path()
        tick.move(to: center)
        tick.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle.radians)) * radius * 0.85,
                                 y: center.y + CGFloat(sin(angle.radians)) * radius * 0.85))
        context.stroke(tick, with: .color(.white), lineWidth: 1.6)
        if let label {
            text(context, label, CGPoint(x: center.x, y: center.y + radius + 9), size: max(7, radius * 0.5),
                 color: Color(white: 0.7))
        }
    }

    private func button(_ context: GraphicsContext, _ r: CGRect, label: String, pressed: Bool, mapped: String? = nil, round: Bool = false) {
        let shape = round ? Path(ellipseIn: r) : Path(roundedRect: r, cornerRadius: r.height * 0.22)
        context.fill(shape, with: .color(pressed ? config.tint : Color(white: 0.2)))
        context.stroke(shape, with: .color(Color(white: 0.38)), lineWidth: 0.8)
        text(context, label, CGPoint(x: r.midX, y: r.midY), size: max(7, r.height * 0.42), color: pressed ? .white : Color(white: 0.85),
             weight: .semibold)
        if let mapped {
            text(context, mapped, CGPoint(x: r.midX, y: r.maxY + max(6, r.height * 0.32)), size: max(6.5, r.height * 0.3),
                 color: Color(white: 0.6))
        }
    }

    private func wheel(_ context: GraphicsContext, _ r: CGRect, value: Double, label: String) {
        context.fill(Path(roundedRect: r, cornerRadius: r.width * 0.4), with: .color(Color(white: 0.06)))
        let h = r.height * 0.22
        let y = r.maxY - h - CGFloat(value) * (r.height - h)
        context.fill(Path(roundedRect: CGRect(x: r.minX + 2, y: y, width: r.width - 4, height: h), cornerRadius: 3),
                     with: .color(abs(value - 0.5) > 0.03 && label == "PITCH" || label == "MOD" && value > 0.02 ? config.tint : Color(white: 0.45)))
        text(context, label, CGPoint(x: r.midX, y: r.maxY + 8), size: 7, color: Color(white: 0.6))
    }

    // MARK: Launchkey 25 MK2

    private func drawLaunchkey(_ context: GraphicsContext, _ size: CGSize) {
        let W = size.width, H = size.height
        let body = CGRect(origin: .zero, size: size)
        context.fill(Path(roundedRect: body, cornerRadius: W * 0.025), with: .color(Color(white: 0.17)))
        context.stroke(Path(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerRadius: W * 0.025), with: .color(Color(white: 0.3)))
        text(context, "novation", CGPoint(x: W * 0.04, y: H * 0.07), size: H * 0.045, color: Color(white: 0.85), weight: .bold, anchor: .leading)
        text(context, "LAUNCHKEY 25", CGPoint(x: W * 0.04, y: H * 0.12), size: H * 0.03, color: Color(white: 0.55), anchor: .leading)

        // Track ◀ ▶ and transport.
        let bw = W * 0.045, bh = H * 0.055
        let track: [(String, Int)] = [("◀", 102), ("▶", 103)]
        for (i, t) in track.enumerated() {
            let r = CGRect(x: W * 0.04 + CGFloat(i) * (bw + W * 0.012), y: H * 0.19, width: bw, height: bh)
            let control = MidiControl(.cc, channel: 1, number: t.1)
            let pressed = midi.isPressed(device, control) || midi.isPressed(device + "", MidiControl(.cc, channel: 16, number: t.1))
                || midi.isPressed("Launchkey MK2 25 Launchkey InControl", MidiControl(.cc, channel: 16, number: t.1))
            button(context, r, label: t.0, pressed: pressed, mapped: drums.padMode == .chords ? tr("sonido") : tr("pista"))
        }
        let transport: [(String, Int)] = [("◀◀", 112), ("▶▶", 113), ("■", 114), ("▶", 115), ("⟲", 116), ("●", 117)]
        for (i, t) in transport.enumerated() {
            let col = i % 3, row = i / 3
            let r = CGRect(x: W * 0.04 + CGFloat(col) * (bw + W * 0.012), y: H * (0.31 + CGFloat(row) * 0.12), width: bw, height: bh)
            let ids = [MidiControl(.cc, channel: 1, number: t.1), MidiControl(.cc, channel: 16, number: t.1)]
            let pressed = ids.contains { c in midi.livePressed.contains { $0.hasSuffix("|\(c.id)") } }
            let mapped = ids.compactMap { midi.bindings[$0.id] }.first.map(MidiController.shortLabel)
            button(context, r, label: t.0, pressed: pressed, mapped: mapped)
        }

        // Knobs.
        let padLeft = W * 0.3, padRight = W * 0.86
        let cell = (padRight - padLeft) / 8
        for i in 0..<8 {
            let control = MidiControl(.cc, channel: 1, number: 21 + i)
            let center = CGPoint(x: padLeft + cell * (CGFloat(i) + 0.5), y: H * 0.13)
            let mapped = midi.bindings[control.id].map { a -> String in
                let l = a.label
                return l.count > 10 ? String(l.prefix(9)) + "…" : l
            }
            knob(context, center: center, radius: min(cell * 0.3, H * 0.045), value: midi.value(device, control), label: mapped)
        }

        // Pads (16) and the two round buttons.
        let padSize = min(cell * 0.82, H * 0.11)
        for pad in 0..<16 {
            let row = pad / 8, col = pad % 8
            let r = CGRect(x: padLeft + cell * CGFloat(col) + (cell - padSize) / 2, y: H * (0.25 + CGFloat(row) * 0.14),
                           width: padSize, height: padSize)
            let inControl = row == 0 ? MidiPresets.inControlTop[col] : MidiPresets.inControlBottom[col]
            let basic = row == 0 ? MidiPresets.basicTop[col] : MidiPresets.basicBottom[col]
            let pressed = midi.livePressed.contains { k in
                k.hasSuffix("|" + MidiControl(.note, channel: 1, number: inControl).id) && k.localizedCaseInsensitiveContains("incontrol")
                    || k.hasSuffix("|" + MidiControl(.note, channel: 10, number: basic).id)
            }
            let info = midi.padInfo(pad)
            let playing = drums.padMode == .steps && drums.playing && drums.step == pad
            let fill: Color = pressed || playing ? .white
                : info.lit ? (drums.padMode == .steps ? Color(red: 0.96, green: 0.77, blue: 0.42) : Color(red: 0.36, green: 0.55, blue: 1))
                : drums.padMode == .play && pad < 8 ? Color(red: 0.2, green: 0.45, blue: 0.3)
                : Color(white: 0.27)
            context.fill(Path(roundedRect: r, cornerRadius: padSize * 0.12), with: .color(fill))
            text(context, info.label, CGPoint(x: r.midX, y: r.midY), size: max(7, padSize * 0.24),
                 color: pressed || playing || info.lit ? .black : Color(white: 0.85), weight: .semibold)
        }
        for row in 0..<2 {
            let note = row == 0 ? MidiPresets.roundTop : MidiPresets.roundBottom
            let control = MidiControl(.note, channel: 1, number: note)
            let r = CGRect(x: padRight + W * 0.025, y: H * (0.25 + CGFloat(row) * 0.14) + padSize * 0.2, width: padSize * 0.6, height: padSize * 0.6)
            let pressed = midi.livePressed.contains { $0.hasSuffix("|" + control.id) && $0.localizedCaseInsensitiveContains("incontrol") }
            button(context, r, label: "", pressed: pressed, mapped: midi.bindings[control.id].map(MidiController.shortLabel), round: true)
        }
        text(context, padModeName, CGPoint(x: padLeft, y: H * 0.535), size: H * 0.03, color: Color(white: 0.6), anchor: .leading)

        // Octave buttons, wheels and keys.
        let ob = CGRect(x: W * 0.04, y: H * 0.56, width: bw, height: bh)
        button(context, ob, label: "−", pressed: false)
        button(context, ob.offsetBy(dx: bw + W * 0.012, dy: 0), label: "+", pressed: false)
        let base = midi.keyWindow[device] ?? 48
        text(context, tr("Octava %@", octaveName(base)), CGPoint(x: W * 0.04, y: H * 0.67), size: H * 0.028,
             color: Color(white: 0.6), anchor: .leading)
        let pb = midi.value(device, MidiControl(.pb, channel: 1, number: 0)) ?? 0.5
        let mod = midi.value(device, MidiControl(.cc, channel: 1, number: 1)) ?? 0
        wheel(context, CGRect(x: W * 0.045, y: H * 0.72, width: W * 0.035, height: H * 0.2), value: pb, label: "PITCH")
        wheel(context, CGRect(x: W * 0.1, y: H * 0.72, width: W * 0.035, height: H * 0.2), value: mod, label: "MOD")
        drawKeybed(context, CGRect(x: W * 0.17, y: H * 0.58, width: W * 0.8, height: H * 0.38), low: base, high: base + 24)
    }

    private var padModeName: String {
        switch drums.padMode {
        case .chords: return tr("Pads: acordes")
        case .steps: return tr("Pads: pasos · %@", drums.track.label)
        case .play: return tr("Pads: tocar · arriba tambores, abajo patrones")
        }
    }

    private func octaveName(_ base: Int) -> String {
        let shift = (base - 48) / 12
        return shift == 0 ? "0" : String(format: "%+d", shift)
    }

    // MARK: Yamaha PSR-E453

    private func drawYamaha(_ context: GraphicsContext, _ size: CGSize) {
        let W = size.width, H = size.height
        let body = CGRect(origin: .zero, size: size)
        context.fill(Path(roundedRect: body, cornerRadius: H * 0.08), with: .color(Color(white: 0.11)))
        context.stroke(Path(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), cornerRadius: H * 0.08), with: .color(Color(white: 0.28)))

        // Speaker grilles.
        for side in [0, 1] {
            let cx = side == 0 ? W * 0.09 : W * 0.91
            let grille = CGRect(x: cx - W * 0.065, y: H * 0.07, width: W * 0.13, height: H * 0.33)
            context.fill(Path(roundedRect: grille, cornerRadius: H * 0.05), with: .color(Color(white: 0.07)))
            var dots = Path()
            var y = grille.minY + 6
            while y < grille.maxY - 3 {
                var x = grille.minX + 6
                while x < grille.maxX - 3 {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 2.2, height: 2.2))
                    x += 6
                }
                y += 6
            }
            context.fill(dots, with: .color(Color(white: 0.22)))
        }
        text(context, "YAMAHA", CGPoint(x: W * 0.2, y: H * 0.1), size: H * 0.055, color: Color(white: 0.85), weight: .bold, anchor: .leading)
        text(context, "PSR-E453", CGPoint(x: W * 0.2, y: H * 0.17), size: H * 0.035, color: Color(white: 0.5), anchor: .leading)

        // Live control knobs.
        for i in 0..<2 {
            knob(context, center: CGPoint(x: W * (0.23 + CGFloat(i) * 0.05), y: H * 0.3), radius: H * 0.045, value: nil,
                 label: i == 0 ? "KNOB A" : "KNOB B")
        }

        // Display with this keyboard's sound and layout.
        let screen = CGRect(x: W * 0.36, y: H * 0.08, width: W * 0.2, height: H * 0.24)
        context.fill(Path(roundedRect: screen, cornerRadius: 4), with: .color(Color(red: 0.55, green: 0.66, blue: 0.62)))
        text(context, Keyboards.soundName(config.instrument).uppercased(), CGPoint(x: screen.minX + 8, y: screen.minY + screen.height * 0.32),
             size: screen.height * 0.17, color: Color(white: 0.1), weight: .bold, anchor: .leading)
        text(context, config.layout.label + (config.octave == 0 ? "" : String(format: " · 8va %+d", config.octave)),
             CGPoint(x: screen.minX + 8, y: screen.minY + screen.height * 0.68), size: screen.height * 0.13,
             color: Color(white: 0.15), anchor: .leading)

        // Panel buttons (they don't send MIDI; drawn for orientation) and the 8 favorites mirror.
        for row in 0..<3 {
            for col in 0..<8 {
                let r = CGRect(x: W * (0.59 + CGFloat(col) * 0.026), y: H * (0.09 + CGFloat(row) * 0.085), width: W * 0.019, height: H * 0.045)
                context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color(white: row == 0 ? 0.3 : 0.22)))
            }
        }
        text(context, tr("Botones de voz → favoritos 1–8"), CGPoint(x: W * 0.59, y: H * 0.38), size: H * 0.032,
             color: Color(white: 0.55), anchor: .leading)

        // Pitch bend wheel and the 61 keys (C2–C7 as MIDI 36–96).
        let pb = midi.value(device, MidiControl(.pb, channel: 1, number: 0)) ?? 0.5
        wheel(context, CGRect(x: W * 0.025, y: H * 0.55, width: W * 0.022, height: H * 0.3), value: pb, label: "PITCH")
        drawKeybed(context, CGRect(x: W * 0.06, y: H * 0.47, width: W * 0.92, height: H * 0.48), low: 36, high: 96)
    }
}
