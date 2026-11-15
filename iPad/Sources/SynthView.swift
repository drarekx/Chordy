import SwiftUI

/// The synth designer from the iPad, the same as on the Mac: the library, the whole sound
/// (oscillators, harmonics, filter, envelope, vibrato, volume), save / undo, give it to a
/// keyboard, pin a keyboard to it (it keeps playing whatever is edited here), and keys to try it.
struct SynthView: View {
    @ObservedObject var client: RemoteClient
    let state: RemoteState
    @State private var renaming: RemoteSoundRef?
    @State private var newName = ""
    @State private var deleting: RemoteSoundRef?

    var body: some View {
        if let synth = state.synth {
            HStack(alignment: .top, spacing: 14) {
                library(synth).frame(width: 250)
                VStack(spacing: 12) {
                    topBar(synth)
                    ScrollView {
                        // One column when narrow (portrait), two when there's room.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 12, alignment: .top)], spacing: 12) {
                            OscillatorsCard(client: client, patch: synth.draft)
                            FilterCard(client: client, patch: synth.draft)
                            EnvelopeCard(client: client, patch: synth.draft)
                            VibratoVolumeCard(client: client, patch: synth.draft)
                            if synth.draft.oscillators.contains(where: { $0.enabled && $0.wave == .custom }) {
                                HarmonicsCard(client: client, patch: synth.draft)
                            }
                        }
                    }
                    TryKeys(client: client).frame(height: 110)
                }
            }
            .alert("Renombrar", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Nombre", text: $newName)
                Button("Cancelar", role: .cancel) {}
                Button("Guardar") { if let r = renaming { client.send(.synthRename(id: r.id, name: newName)) } }
            }
            .confirmationDialog("¿Borrar «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Borrar", role: .destructive) { if let d = deleting { client.send(.synthDelete(id: d.id)) } }
            }
        } else {
            Text("Actualiza Chordy en el Mac para diseñar sonidos desde aquí.")
                .font(.title3.weight(.semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Library

    private func library(_ synth: RemoteSynth) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                pill("Nuevo", symbol: "plus", primary: true) { client.send(.synthNew) }
                pill("Duplicar", symbol: "plus.square.on.square") { client.send(.synthDuplicate(id: synth.selectedId)) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let mine = synth.library.filter { !$0.builtin }
                    if !mine.isEmpty {
                        header("TUS SONIDOS")
                        ForEach(mine) { row($0, synth) }
                    }
                    header("DE FÁBRICA")
                    ForEach(synth.library.filter(\.builtin)) { row($0, synth) }
                }
            }
            Text("Mantén pulsado un sonido tuyo para renombrarlo o borrarlo.").font(.system(size: 11)).foregroundStyle(Pal.text3)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Pal.text3).tracking(0.6).padding(.top, 8)
    }

    private func row(_ s: RemoteSoundRef, _ synth: RemoteSynth) -> some View {
        let on = s.id == synth.selectedId
        return Button { if !on { client.send(.synthSelect(id: s.id)) } } label: {
            HStack(spacing: 6) {
                Text(s.name).font(.system(size: 15, weight: on ? .semibold : .regular)).lineLimit(1)
                if on && synth.dirty { Circle().fill(Pal.warn).frame(width: 7, height: 7) }
                Spacer(minLength: 4)
            }
            .foregroundStyle(on ? Pal.onAccent : Pal.text)
            .padding(.horizontal, 12).frame(height: 40)
            .background(on ? Pal.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !s.builtin {
                Button { newName = s.name; renaming = s } label: { Label("Renombrar", systemImage: "pencil") }
            }
            Button { client.send(.synthDuplicate(id: s.id)) } label: { Label("Duplicar", systemImage: "plus.square.on.square") }
            if !s.builtin {
                Button(role: .destructive) { deleting = s } label: { Label("Borrar", systemImage: "trash") }
            }
        }
    }

    // MARK: Top bar

    private func topBar(_ synth: RemoteSynth) -> some View {
        let builtin = synth.library.first { $0.id == synth.selectedId }?.builtin ?? true
        let boards = state.keyboards ?? []
        let pinned = synth.audition.flatMap { id in boards.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(synth.draft.name).font(.system(size: 22, weight: .bold)).lineLimit(1)
            Text(synth.dirty ? "editado, sin guardar" : (builtin ? "de fábrica" : "guardado"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(synth.dirty ? Pal.warn : Pal.text3)
            Spacer()
        }
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
            Menu {
                ForEach(boards) { kb in
                    Button { client.send(.synthAudition(keyboard: kb.id)) } label: {
                        if kb.id == synth.audition { Label(kb.name, systemImage: "checkmark") } else { Text(kb.name) }
                    }
                }
                if pinned != nil {
                    Divider()
                    Button("Dejar de probar (vuelve su sonido)") { client.send(.synthAudition(keyboard: nil)) }
                }
            } label: {
                Label(pinned.map { "Probando en \($0.name)" } ?? "Probar en un teclado", systemImage: pinned == nil ? "pin" : "pin.fill")
                    .font(.system(size: 14, weight: .semibold)).fixedSize()
                    .padding(.horizontal, 12).frame(height: 40)
                    .foregroundStyle(pinned == nil ? Pal.text : Pal.onAccent)
                    .background(pinned == nil ? Pal.control : Pal.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            Menu {
                ForEach(boards) { kb in Button(kb.name) { client.send(.synthAssign(keyboard: kb.id)) } }
            } label: {
                Label("Usar en un teclado", systemImage: "pianokeys").font(.system(size: 14, weight: .semibold)).fixedSize()
                    .padding(.horizontal, 12).frame(height: 40)
                    .foregroundStyle(Pal.text)
                    .background(Pal.control, in: RoundedRectangle(cornerRadius: 10))
            }
            pill("Deshacer", symbol: "arrow.uturn.backward") { client.send(.synthRevert) }
                .disabled(!synth.dirty).opacity(synth.dirty ? 1 : 0.4)
            pill(builtin ? "Guardar copia" : "Guardar", symbol: "square.and.arrow.down", primary: true) {
                client.send(.synthSave(asNew: false))
            }
            .disabled(!synth.dirty).opacity(synth.dirty ? 1 : 0.4)
        }
        }
        }
        .padding(.horizontal, 4)
    }

    private func pill(_ title: String, symbol: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold)).fixedSize()
                .padding(.horizontal, 12).frame(height: 40)
                .foregroundStyle(primary ? Pal.onAccent : Pal.text)
                .background(primary ? Pal.accent : Pal.control, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards

/// Sends the whole sound after one change.
@MainActor private func edit(_ client: RemoteClient, _ patch: Patch, _ change: (inout Patch) -> Void) {
    var p = patch
    change(&p)
    client.send(.synthDraft(p))
}

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text2).tracking(0.6)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// A labelled slider with its value; `log` for frequencies and times.
private struct Param: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var log = false
    let format: (Double) -> String
    let send: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        let shown = dragging ?? value
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13)).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { toSlider(shown) }, set: { v in
                let real = fromSlider(v)
                dragging = real
                send(real)
            }), in: 0...1) { editing in if !editing { dragging = nil } }
            Text(format(shown)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text2).frame(width: 70, alignment: .trailing)
        }
    }

    private func toSlider(_ v: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        if log, lo > 0 { return (Foundation.log(max(lo, v)) - Foundation.log(lo)) / (Foundation.log(hi) - Foundation.log(lo)) }
        return (v - lo) / (hi - lo)
    }

    private func fromSlider(_ t: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        if log, lo > 0 { return exp(Foundation.log(lo) + t * (Foundation.log(hi) - Foundation.log(lo))) }
        return lo + t * (hi - lo)
    }
}

private enum Fmt {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
    static func seconds(_ v: Double) -> String { v < 1 ? "\(Int((v * 1000).rounded())) ms" : String(format: "%.2f s", v) }
    static func hz(_ v: Double) -> String { v >= 1000 ? String(format: "%.1f kHz", v / 1000) : "\(Int(v)) Hz" }
}

private struct OscillatorsCard: View {
    let client: RemoteClient
    let patch: Patch
    private static let waves: [(Patch.Waveform, String)] = [(.sine, "Seno"), (.triangle, "Triáng."), (.sawtooth, "Sierra"),
                                                            (.square, "Cuadr."), (.custom, "Armón.")]

    var body: some View {
        Card(title: "OSCILADORES") {
            ForEach(0..<min(3, patch.oscillators.count), id: \.self) { i in
                let o = patch.oscillators[i]
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(isOn: Binding(get: { o.enabled }, set: { v in edit(client, patch) { $0.oscillators[i].enabled = v } })) {
                            Text("Oscilador \(i + 1)").font(.system(size: 14, weight: .semibold))
                        }
                        .toggleStyle(.switch).fixedSize()
                        Spacer()
                        Stepper(value: Binding(get: { o.octave }, set: { v in edit(client, patch) { $0.oscillators[i].octave = v } }),
                                in: Patch.Range.octave) {
                            Text("Octava \(o.octave > 0 ? "+" : "")\(o.octave)").font(.system(size: 13, design: .monospaced))
                        }
                        .fixedSize()
                    }
                    if o.enabled {
                        Picker("", selection: Binding(get: { o.wave }, set: { v in edit(client, patch) { $0.oscillators[i].wave = v } })) {
                            ForEach(Self.waves, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented)
                        Param(label: "Afinación", value: o.detune, range: Patch.Range.detune, format: { "\(Int($0.rounded())) ct" }) { v in
                            edit(client, patch) { $0.oscillators[i].detune = v }
                        }
                        Param(label: "Nivel", value: o.level, range: 0...1, format: Fmt.percent) { v in
                            edit(client, patch) { $0.oscillators[i].level = v }
                        }
                    }
                }
                if i < 2 { Divider().overlay(Pal.line) }
            }
        }
    }
}

private struct FilterCard: View {
    let client: RemoteClient
    let patch: Patch

    var body: some View {
        Card(title: "FILTRO") {
            Picker("", selection: Binding(get: { patch.filter.type }, set: { v in edit(client, patch) { $0.filter.type = v } })) {
                Text("Pasa bajos").tag(Patch.FilterType.lowpass)
                Text("Pasa altos").tag(Patch.FilterType.highpass)
                Text("Pasa banda").tag(Patch.FilterType.bandpass)
            }
            .pickerStyle(.segmented)
            Param(label: "Corte", value: patch.filter.cutoff, range: Patch.Range.cutoff, log: true, format: Fmt.hz) { v in
                edit(client, patch) { $0.filter.cutoff = v }
            }
            Param(label: "Resonancia", value: patch.filter.resonance, range: Patch.Range.resonance, log: true,
                  format: { String(format: "%.1f", $0) }) { v in edit(client, patch) { $0.filter.resonance = v } }
            Param(label: "Envolvente", value: patch.filter.envAmount, range: Patch.Range.envAmount,
                  format: { String(format: "%+.1f oct", $0) }) { v in edit(client, patch) { $0.filter.envAmount = v } }
            Param(label: "Caída env.", value: patch.filter.envDecay, range: Patch.Range.envDecay, log: true, format: Fmt.seconds) { v in
                edit(client, patch) { $0.filter.envDecay = v }
            }
        }
    }
}

private struct EnvelopeCard: View {
    let client: RemoteClient
    let patch: Patch

    var body: some View {
        Card(title: "ENVOLVENTE") {
            EnvelopeShape(envelope: patch.envelope).frame(height: 70)
            Param(label: "Ataque", value: patch.envelope.attack, range: Patch.Range.attack, log: true, format: Fmt.seconds) { v in
                edit(client, patch) { $0.envelope.attack = v }
            }
            Param(label: "Caída", value: patch.envelope.decay, range: Patch.Range.decay, log: true, format: Fmt.seconds) { v in
                edit(client, patch) { $0.envelope.decay = v }
            }
            Param(label: "Sostenido", value: patch.envelope.sustain, range: 0...1, format: Fmt.percent) { v in
                edit(client, patch) { $0.envelope.sustain = v }
            }
            Param(label: "Liberación", value: patch.envelope.release, range: Patch.Range.release, log: true, format: Fmt.seconds) { v in
                edit(client, patch) { $0.envelope.release = v }
            }
        }
    }
}

/// ADSR as a line: attack, decay to sustain, a held part, release.
private struct EnvelopeShape: View {
    let envelope: Patch.Envelope

    var body: some View {
        Canvas { context, size in
            let total = envelope.attack + envelope.decay + 0.5 + envelope.release
            let x = { (t: Double) in CGFloat(t / total) * size.width }
            let top: CGFloat = 4, bottom = size.height - 2
            let sustainY = bottom - CGFloat(envelope.sustain) * (bottom - top)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: bottom))
            path.addLine(to: CGPoint(x: x(envelope.attack), y: top))
            path.addLine(to: CGPoint(x: x(envelope.attack + envelope.decay), y: sustainY))
            path.addLine(to: CGPoint(x: x(envelope.attack + envelope.decay + 0.5), y: sustainY))
            path.addLine(to: CGPoint(x: size.width, y: bottom))
            var fill = path
            fill.closeSubpath()
            context.fill(fill, with: .color(Pal.accent.opacity(0.18)))
            context.stroke(path, with: .color(Pal.accent), lineWidth: 2)
        }
        .background(Pal.window, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct VibratoVolumeCard: View {
    let client: RemoteClient
    let patch: Patch

    var body: some View {
        Card(title: "VIBRATO Y VOLUMEN") {
            Param(label: "Velocidad", value: patch.vibrato.rate, range: Patch.Range.vibratoRate, log: true,
                  format: { String(format: "%.1f Hz", $0) }) { v in edit(client, patch) { $0.vibrato.rate = v } }
            Param(label: "Profundidad", value: patch.vibrato.depth, range: Patch.Range.vibratoDepth,
                  format: { "\(Int($0.rounded())) ct" }) { v in edit(client, patch) { $0.vibrato.depth = v } }
            Divider().overlay(Pal.line)
            Param(label: "Volumen", value: patch.volume, range: 0...1, format: Fmt.percent) { v in
                edit(client, patch) { $0.volume = v }
            }
        }
    }
}

/// The 16 harmonics of the custom wave: drag across the bars to draw it.
private struct HarmonicsCard: View {
    let client: RemoteClient
    let patch: Patch
    @State private var local: [Double]?

    var body: some View {
        let values = local ?? patch.harmonics
        Card(title: "ARMÓNICOS (ONDA «ARMÓN.»)") {
            GeometryReader { geo in
                let w = geo.size.width / CGFloat(Patch.harmonicCount)
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Pal.window)
                    ForEach(0..<Patch.harmonicCount, id: \.self) { i in
                        let v = i < values.count ? values[i] : 0
                        RoundedRectangle(cornerRadius: 3).fill(Pal.accent.opacity(0.85))
                            .frame(width: w - 6, height: max(2, geo.size.height * CGFloat(v)))
                            .offset(x: CGFloat(i) * w + 3)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let i = Int(g.location.x / w)
                            guard (0..<Patch.harmonicCount).contains(i) else { return }
                            var next = local ?? patch.harmonics
                            while next.count < Patch.harmonicCount { next.append(0) }
                            next[i] = min(1, max(0, 1 - Double(g.location.y / geo.size.height)))
                            local = next
                            edit(client, patch) { $0.harmonics = next }
                        }
                        .onEnded { _ in local = nil }
                )
            }
            .frame(height: 120)
        }
    }
}

/// Two octaves to try the sound: it plays on the Mac (drag across keys to glide).
private struct TryKeys: View {
    let client: RemoteClient
    @State private var held: Int?
    @State private var base = 48
    private static let black: Set<Int> = [1, 3, 6, 8, 10]

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 6) {
                Button { base = min(84, base + 12) } label: { Image(systemName: "chevron.up").frame(width: 44, height: 44) }
                Text("C\(base / 12 - 1)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text2)
                Button { base = max(24, base - 12) } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
            }
            .buttonStyle(.bordered)
            GeometryReader { geo in
                let low = base, high = base + 24
                let whites = (low...high).filter { !Self.black.contains($0 % 12) }
                let w = geo.size.width / CGFloat(whites.count)
                Canvas { context, size in
                    for (i, n) in whites.enumerated() {
                        let r = CGRect(x: CGFloat(i) * w + 1, y: 0, width: w - 2, height: size.height)
                        context.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(held == n ? Pal.accent : Pal.text.opacity(0.9)))
                    }
                    for (i, n) in whites.enumerated() where n + 1 <= high && Self.black.contains((n + 1) % 12) {
                        let r = CGRect(x: CGFloat(i + 1) * w - w * 0.3, y: 0, width: w * 0.6, height: size.height * 0.6)
                        context.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(held == n + 1 ? Pal.accent : Pal.window))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let n = key(at: g.location, size: geo.size, whites: whites, w: w, high: high)
                            guard n != held else { return }
                            if let h = held { client.send(.synthNoteOff(midi: h)) }
                            held = n
                            if let n { client.send(.synthNoteOn(midi: n, velocity: 100)) }
                        }
                        .onEnded { _ in
                            if let h = held { client.send(.synthNoteOff(midi: h)) }
                            held = nil
                        }
                )
            }
        }
        .padding(8)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func key(at p: CGPoint, size: CGSize, whites: [Int], w: CGFloat, high: Int) -> Int? {
        guard p.x >= 0, p.x < size.width, p.y >= 0, p.y <= size.height else { return nil }
        let i = min(whites.count - 1, max(0, Int(p.x / w)))
        if p.y < size.height * 0.6 {
            let local = p.x - CGFloat(i) * w
            if local > w * 0.7, whites[i] + 1 <= high, Self.black.contains((whites[i] + 1) % 12) { return whites[i] + 1 }
            if local < w * 0.3, i > 0, Self.black.contains((whites[i] - 1) % 12) { return whites[i] - 1 }
        }
        return whites[i]
    }
}
