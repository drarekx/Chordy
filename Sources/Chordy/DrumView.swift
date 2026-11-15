import AppKit
import SwiftUI

/// The drum machine full size: patterns A–H, a big grid with velocity per step, mute/solo
/// and level per lane, the pattern chain, 4 × 4 pads and tools for the chosen lane.
struct DrumView: View {
    @ObservedObject var drums: DrumMachine
    @ObservedObject var engine: ChordEngine
    @State private var renaming: Int?
    @State private var title = ""

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 14) {
                patternBar
                grid
                chainBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            VStack(spacing: 14) {
                padGrid
                lanePanel
                Spacer(minLength: 0)
            }
            .frame(width: 380)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    // MARK: Patterns

    private var patternBar: some View {
        HStack(spacing: 8) {
            SectionLabel(tr("Patrones"))
            ForEach(DrumPattern.names.indices, id: \.self) { i in
                let p = drums.patterns[i]
                let on = i == drums.selected
                let sounding = drums.playingPattern == i && drums.playing
                Button { drums.selected = i } label: {
                    VStack(spacing: 1) {
                        Text(DrumPattern.names[i]).font(.system(size: 18, weight: .bold))
                        Text(p.title ?? (p.isEmpty ? tr("vacío") : " ")).font(.system(size: 9)).lineLimit(1)
                    }
                    .foregroundStyle(on ? Theme.onAccent : (p.isEmpty ? Theme.text3 : Theme.text))
                    .frame(width: 64, height: 50)
                    .background(on ? Theme.accentFill : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(sounding ? Theme.ok : (on ? Color.clear : Theme.line), lineWidth: sounding ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("Patrón %@ · doble clic para ponerle nombre", DrumPattern.names[i]))
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    title = p.title ?? ""
                    renaming = i
                })
                .popover(isPresented: Binding(get: { renaming == i }, set: { if !$0 { renaming = nil } })) {
                    HStack {
                        TextField(tr("Nombre"), text: $title).frame(width: 160)
                            .onSubmit { drums.setTitle(i, title); renaming = nil }
                        Button(tr("Hecho")) { drums.setTitle(i, title); renaming = nil }
                    }
                    .padding(12)
                }
                .contextMenu {
                    Button(tr("Añadir a la cadena")) { drums.appendToChain(i) }
                    Button(tr("Ponerle nombre…")) { title = p.title ?? ""; renaming = i }
                }
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(DrumPattern.names.indices, id: \.self) { i in
                    if i != drums.selected { Button(tr("Patrón %@", DrumPattern.names[i])) { drums.copy(to: i) } }
                }
            } label: { Text(tr("Copiar en…")).font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.radius))
            Button { drums.clear() } label: { Text(tr("Vaciar")).fixedSize() }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 30))
        }
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 236, height: 1)
                HStack(spacing: 5) {
                    ForEach(0..<DrumPattern.stepCount, id: \.self) { s in
                        Text(s % 4 == 0 ? "\(s / 4 + 1)" : "·")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(drums.step == s && drums.playing ? Theme.text : Theme.text3)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(DrumTrack.allCases, id: \.self) { track in
                HStack(spacing: 10) {
                    laneHeader(track)
                    HStack(spacing: 5) {
                        ForEach(0..<DrumPattern.stepCount, id: \.self) { s in
                            StepCell(drums: drums, track: track, step: s)
                        }
                    }
                }
                .frame(minHeight: 44, maxHeight: 110)
            }
            Text(tr("Clic pone o quita · arrastra arriba o abajo sobre un paso para su fuerza · ⌥ clic: acento · M silencia · S deja solo"))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 246)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line) }
    }

    private func laneHeader(_ track: DrumTrack) -> some View {
        let selected = drums.track == track
        let muted = drums.muted.contains(track)
        let soloed = drums.solo == track
        return HStack(spacing: 8) {
            Button { drums.track = track; drums.hit(track, velocity: 100) } label: {
                Text(track.short).font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(selected || drums.flash.contains(track) ? Theme.window : Theme.text)
                    .background(drums.flash.contains(track) ? Theme.text : (selected ? Theme.warn : Theme.control),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(tr("Oírlo y elegir la pista"))
            VStack(alignment: .leading, spacing: 4) {
                Text(track.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Slider(value: Binding(get: { drums.pattern.laneVolume(track) }, set: { drums.setLaneVolume(track, $0) }), in: 0...1)
                    .controlSize(.mini)
            }
            .frame(maxWidth: .infinity)
            toggle("M", on: muted, help: tr("Silenciar")) { drums.toggleMute(track) }
            toggle("S", on: soloed, help: tr("Solo")) { drums.toggleSolo(track) }
        }
        .padding(.horizontal, 8)
        .frame(width: 236, height: 52)
        .background(selected ? Theme.warn.opacity(0.12) : Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.warn.opacity(0.4) : Theme.line) }
    }

    private func toggle(_ label: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .foregroundStyle(on ? Theme.window : Theme.text2)
                .background(on ? Theme.warn : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.lineStrong) }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Chain

    private var chainBar: some View {
        HStack(spacing: 8) {
            SectionLabel(tr("Cadena"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(drums.chain.enumerated()), id: \.offset) { position, index in
                        let current = drums.chainOn && drums.playing && drums.chainPosition == position
                        Text(DrumPattern.names[index]).font(.system(size: 14, weight: .bold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(current ? Theme.onAccent : Theme.text)
                            .background(current ? Theme.accentFill : Theme.control, in: RoundedRectangle(cornerRadius: 8))
                            .contextMenu { Button(tr("Quitar")) { drums.removeFromChain(at: position) } }
                            .onTapGesture { drums.removeFromChain(at: position) }
                            .help(tr("Clic para quitarlo"))
                    }
                    Menu {
                        ForEach(DrumPattern.names.indices, id: \.self) { i in
                            Button(DrumPattern.names[i] + (drums.patterns[i].title.map { " · \($0)" } ?? "")) { drums.appendToChain(i) }
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 34, height: 34)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3])) }
                    .help(tr("Añadir un patrón"))
                }
            }
            Spacer(minLength: 8)
            Text(drums.chain.isEmpty ? tr("Añade patrones para tocarlos en orden, uno por compás") : tr("%d compases", drums.chain.count))
                .font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
            Toggle(tr("Cadena"), isOn: $drums.chainOn).toggleStyle(.switch).controlSize(.small).disabled(drums.chain.isEmpty)
            Button { drums.clearChain() } label: { Text(tr("Vaciar")).fixedSize() }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 28)).disabled(drums.chain.isEmpty)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line) }
    }

    // MARK: Pads

    private var padGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(tr("Pads"))
                Spacer()
                Text(tr("arriba tambores · abajo patrones")).font(.system(size: 10)).foregroundStyle(Theme.text3)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(0..<16, id: \.self) { pad in padButton(pad) }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line) }
    }

    private func padButton(_ pad: Int) -> some View {
        let isDrum = pad < 8
        let track = isDrum ? DrumTrack.allCases[pad] : nil
        let pattern = isDrum ? nil : pad - 8
        let lit = track.map { drums.flash.contains($0) } ?? (pattern == drums.playingPattern && drums.playing)
        let chosen = pattern == drums.selected
        let fill: Color = lit ? Theme.text : (isDrum ? Theme.ok.opacity(0.28) : (chosen ? Theme.accentFill : Theme.accentSoft))
        return Button {
            if let track { drums.hit(track, velocity: 110) } else if let pattern { drums.launch(pattern) }
        } label: {
            VStack(spacing: 2) {
                Text(track?.short ?? DrumPattern.names[pattern!]).font(.system(size: 15, weight: .bold))
                Text(track?.label ?? (drums.patterns[pattern!].title ?? tr("patrón"))).font(.system(size: 9)).lineLimit(1)
            }
            .foregroundStyle(lit ? Theme.window : (chosen ? Theme.onAccent : Theme.text))
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Lane tools

    private var lanePanel: some View {
        let track = drums.track
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(tr("%@ · pista elegida", track.label))
            HStack {
                Text(tr("Sonido")).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
                Menu {
                    ForEach(track.variants, id: \.note) { v in
                        Button("\(v.name) (\(v.note))") { drums.setLaneNote(track, v.note) }
                    }
                } label: {
                    let note = drums.pattern.laneNote(track)
                    Text(track.variants.first { $0.note == note }?.name ?? "\(note)").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
            }
            HStack {
                Text(tr("Volumen")).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { drums.pattern.laneVolume(track) }, set: { drums.setLaneVolume(track, $0) }), in: 0...1)
                    .controlSize(.small)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                tool(tr("Cada paso")) { drums.fill(track, every: 1) }
                tool(tr("Cada 2")) { drums.fill(track, every: 2) }
                tool(tr("Cada 4")) { drums.fill(track, every: 4) }
                tool(tr("Contratiempo")) { drums.fill(track, every: 4, offset: 2) }
                tool(tr("← Desplazar")) { drums.shift(track, by: -1) }
                tool(tr("Desplazar →")) { drums.shift(track, by: 1) }
                tool(tr("Aleatorio")) { drums.randomize(track) }
                tool(tr("Vaciar pista")) { drums.clearLane(track) }
            }
            HStack {
                Text(tr("Swing")).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { drums.pattern.swing }, set: { drums.setSwing($0) }), in: 0...0.5).controlSize(.small)
                Text("\(Int((drums.pattern.swing * 200).rounded())) %").monospacedText(size: 11).frame(width: 40)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line) }
    }

    private func tool(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity) }
            .buttonStyle(AppButtonStyle(kind: .secondary, height: 28, padding: 6))
    }
}

/// One big step: velocity as a bar, click toggles, vertical drag sets the velocity.
private struct StepCell: View {
    @ObservedObject var drums: DrumMachine
    let track: DrumTrack
    let step: Int
    @State private var dragStart: Int?

    var body: some View {
        let velocity = drums.pattern.steps[track.rawValue][step]
        let current = drums.playing && drums.step == step && drums.playingPattern == drums.selected
        let silent = drums.muted.contains(track) || (drums.solo != nil && drums.solo != track)
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(current ? Theme.lineStrong : (step % 4 == 0 ? Theme.control : Theme.field))
                if velocity > 0 {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(current ? Theme.text : (silent ? Theme.text3 : Theme.accentFill))
                        .opacity(0.55 + 0.45 * Double(velocity) / 127)
                        .frame(height: max(6, geo.size.height * CGFloat(velocity) / 127))
                }
                if drums.track == track && drums.padMode == .steps {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.warn.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.height) > 3 else { return }
                        if dragStart == nil { dragStart = velocity > 0 ? velocity : 100 }
                        let v = (dragStart ?? 100) - Int(value.translation.height / max(1, geo.size.height) * 127)
                        drums.setVelocity(track, step, max(1, min(127, v)))
                    }
                    .onEnded { value in
                        if dragStart == nil, abs(value.translation.height) <= 3 {
                            drums.toggleStep(track, step, accent: NSEvent.modifierFlags.contains(.option))
                        }
                        dragStart = nil
                    }
            )
        }
        .frame(minHeight: 36)
        .accessibilityLabel(tr("%@, paso %d", track.label, step + 1))
    }
}
