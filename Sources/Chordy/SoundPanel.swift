import SwiftUI

/// Sound side panel: presets and the full synth editor. Edits are heard at once
/// (filter, levels, vibrato and volume even on held notes) and saved on demand.
struct SoundPanel: View {
    @ObservedObject var sounds: SoundLibrary
    @ObservedObject var instruments: InstrumentLibrary

    private var usesCustomWave: Bool { sounds.draft.oscillators.contains { $0.enabled && $0.wave == .custom } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InstrumentPicker(instruments: instruments)
                if instruments.usesSynth { synthEditor }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var synthEditor: some View {
                SectionLabel(tr("Sintetizador"))
                PresetBar(sounds: sounds)
                WaveformPreview(patch: sounds.draft).frame(height: 56)

                section(tr("Osciladores")) {
                    ForEach(0..<Patch.oscillatorCount, id: \.self) { i in
                        OscillatorRow(index: i, oscillator: $sounds.draft.oscillators[i])
                    }
                }

                if usesCustomWave {
                    section(tr("Armónicos"), hint: tr("arrastra para dibujar la onda")) {
                        HarmonicsEditor(harmonics: $sounds.draft.harmonics)
                    }
                }

                section(tr("Filtro"), trailing: {
                    SegmentedControl(options: [("LP", Patch.FilterType.lowpass), ("HP", .highpass), ("BP", .bandpass)],
                                     selection: $sounds.draft.filter.type)
                }) {
                    ParamSlider(label: tr("Corte"), value: $sounds.draft.filter.cutoff, range: Patch.Range.cutoff,
                                log: true, format: Format.hz)
                    ParamSlider(label: tr("Resonancia"), value: $sounds.draft.filter.resonance,
                                range: Patch.Range.resonance, format: { String(format: "%.1f", $0) })
                    ParamSlider(label: tr("Envolvente"), value: $sounds.draft.filter.envAmount,
                                range: Patch.Range.envAmount, format: Format.octaves)
                    ParamSlider(label: tr("Tiempo env."), value: $sounds.draft.filter.envDecay,
                                range: Patch.Range.envDecay, log: true, format: Format.seconds)
                }

                section(tr("Envolvente")) {
                    EnvelopeGraph(envelope: sounds.draft.envelope).frame(height: 54)
                    ParamSlider(label: tr("Ataque"), value: $sounds.draft.envelope.attack, range: Patch.Range.attack,
                                log: true, format: Format.seconds)
                    ParamSlider(label: tr("Caída"), value: $sounds.draft.envelope.decay, range: Patch.Range.decay,
                                log: true, format: Format.seconds)
                    ParamSlider(label: tr("Sostenido"), value: $sounds.draft.envelope.sustain, range: 0...1,
                                format: Format.percent)
                    ParamSlider(label: tr("Liberación"), value: $sounds.draft.envelope.release, range: Patch.Range.release,
                                log: true, format: Format.seconds)
                }

                section(tr("Vibrato")) {
                    ParamSlider(label: tr("Velocidad"), value: $sounds.draft.vibrato.rate, range: Patch.Range.vibratoRate,
                                format: { String(format: "%.1f Hz", $0) })
                    ParamSlider(label: tr("Profundidad"), value: $sounds.draft.vibrato.depth,
                                range: Patch.Range.vibratoDepth, format: { "\(Int($0.rounded())) ct" })
                }

                section(tr("Salida")) {
                    ParamSlider(label: tr("Volumen"), value: $sounds.draft.volume, range: 0...1, format: Format.percent)
                }
    }

    private func section<Content: View>(_ title: String, hint: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        section(title, hint: hint, trailing: { EmptyView() }, content: content)
    }

    private func section<Trailing: View, Content: View>(_ title: String, hint: String? = nil,
                                                         @ViewBuilder trailing: () -> Trailing,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(title)
                if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(Theme.text3) }
                Spacer()
                trailing()
            }
            content()
        }
    }
}

enum Format {
    static func hz(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))" }
    static func seconds(_ v: Double) -> String { v < 1 ? "\(Int((v * 1000).rounded()))ms" : String(format: "%.2fs", v) }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func octaves(_ v: Double) -> String { String(format: "%@%.1f oct", v > 0 ? "+" : "", v) }
}

// MARK: - Presets

private struct PresetBar: View {
    @ObservedObject var sounds: SoundLibrary
    @State private var naming = false
    @State private var name = ""
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if naming {
                    AppTextField(placeholder: tr("Nombre del sonido"), text: $name) { commitSaveAs() }
                    Button(tr("Guardar")) { commitSaveAs() }.buttonStyle(.appPrimary)
                    Button(tr("Cancelar")) { naming = false }.buttonStyle(.appGhost)
                } else {
                    Menu {
                        Section(tr("De fábrica")) {
                            ForEach(Patch.builtins) { patch in Button(patch.name) { sounds.select(patch.id) } }
                        }
                        if !sounds.userPatches.isEmpty {
                            Section(tr("Mis sonidos")) {
                                ForEach(sounds.userPatches) { patch in Button(patch.name) { sounds.select(patch.id) } }
                            }
                        }
                    } label: {
                        Text(sounds.selected.name).font(.system(size: 13, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.lineStrong) }
                    if sounds.dirty {
                        Text(tr("editado")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warn)
                    }
                    IconButton(symbol: "chevron.left", label: tr("Sonido anterior")) { sounds.selectNext(-1) }
                    IconButton(symbol: "chevron.right", label: tr("Sonido siguiente")) { sounds.selectNext(1) }
                }
            }
            if !naming {
                HStack(spacing: 6) {
                    if !sounds.selected.isBuiltin {
                        Button(tr("Guardar")) { sounds.save() }.buttonStyle(.appSecondary).disabled(!sounds.dirty)
                    }
                    Button {
                        name = sounds.selected.isBuiltin ? tr("%@ (copia)", sounds.selected.name) : sounds.selected.name
                        naming = true
                    } label: { Text(tr("Guardar como…")).fixedSize() }
                    .buttonStyle(.appSecondary)
                    Button { sounds.revert() } label: { Text(tr("Deshacer cambios")).fixedSize() }
                        .buttonStyle(.appGhost).disabled(!sounds.dirty)
                    Spacer(minLength: 0)
                    if !sounds.selected.isBuiltin {
                        Button(confirmingDelete ? tr("¿Seguro?") : tr("Borrar")) {
                            if confirmingDelete {
                                sounds.remove(sounds.selectedId)
                                confirmingDelete = false
                            } else {
                                confirmingDelete = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { confirmingDelete = false }
                            }
                        }
                        .buttonStyle(.appDanger)
                    }
                }
            }
        }
    }

    private func commitSaveAs() {
        guard naming else { return }
        naming = false
        sounds.save(as: name.trimmingCharacters(in: .whitespaces).isEmpty ? sounds.draft.name : name)
    }
}

// MARK: - Controls

/// Labelled slider with its value; `log` maps the track logarithmically (frequencies, times).
struct ParamSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var log = false
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { toTrack(value) }, set: { value = fromTrack($0) }), in: 0...1)
                .controlSize(.small)
            Text(format(value)).monospacedText(size: 11).frame(width: 62, alignment: .trailing)
        }
    }

    private func toTrack(_ v: Double) -> Double {
        let v = min(range.upperBound, max(range.lowerBound, v))
        if log { return Foundation.log(v / range.lowerBound) / Foundation.log(range.upperBound / range.lowerBound) }
        return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func fromTrack(_ t: Double) -> Double {
        if log { return range.lowerBound * pow(range.upperBound / range.lowerBound, t) }
        return range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
}

private struct OscillatorRow: View {
    let index: Int
    @Binding var oscillator: Patch.Oscillator

    private static let waves: [(String, Patch.Waveform)] = [
        ("sin", .sine), ("tri", .triangle), ("saw", .sawtooth), ("sqr", .square), (tr("arm"), .custom),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $oscillator.enabled) {
                    Text("OSC \(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            if oscillator.enabled {
                SegmentedControl(options: Self.waves, selection: $oscillator.wave, expand: true)
                HStack(spacing: 10) {
                    Text(tr("Octava")).font(.system(size: 12)).foregroundStyle(Theme.text2).frame(width: 84, alignment: .leading)
                    Stepper(value: $oscillator.octave, in: Patch.Range.octave) {
                        Text(oscillator.octave > 0 ? "+\(oscillator.octave)" : "\(oscillator.octave)").monospacedText(size: 11)
                    }
                    .controlSize(.small)
                    Spacer()
                }
                ParamSlider(label: tr("Afinación"), value: $oscillator.detune, range: Patch.Range.detune,
                            format: { "\(Int($0.rounded())) ct" })
                ParamSlider(label: tr("Nivel"), value: $oscillator.level, range: 0...1, format: Format.percent)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
        .opacity(oscillator.enabled ? 1 : 0.7)
    }
}

/// 16 harmonic amplitudes; drag across the bars to paint them.
private struct HarmonicsEditor: View {
    @Binding var harmonics: [Double]

    private static let shapes: [(String, [Double])] = [
        ("Sine", Harmonics.sine), ("Saw", Harmonics.saw), ("Square", Harmonics.square),
        ("Organ", Harmonics.organ), ("Bell", Harmonics.bell),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let count = harmonics.count
                let w = geo.size.width / CGFloat(count)
                ZStack(alignment: .bottomLeading) {
                    ForEach(0..<count, id: \.self) { i in
                        Rectangle()
                            .fill(Theme.accentFill)
                            .frame(width: max(1, w - 2), height: geo.size.height * harmonics[i])
                            .offset(x: CGFloat(i) * w + 1)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let i = Int(value.location.x / w)
                    guard i >= 0, i < count else { return }
                    let amount = ((1 - value.location.y / geo.size.height) * 100).rounded() / 100
                    harmonics[i] = min(1, max(0, amount))
                })
            }
            .frame(height: 70)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                ForEach(Self.shapes, id: \.0) { shape in
                    Button { harmonics = shape.1 } label: {
                        Text(shape.0).font(.system(size: 11)).foregroundStyle(Theme.text2)
                            .frame(maxWidth: .infinity).frame(height: 22)
                            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One cycle of the mixed oscillators (detune ignored).
private struct WaveformPreview: View {
    let patch: Patch

    var body: some View {
        Canvas { context, size in
            let samples = sampleMix(count: 160)
            var path = Path()
            for (i, v) in samples.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(samples.count - 1),
                                    y: size.height / 2 - CGFloat(v) * size.height * 0.42)
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        }
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func sampleMix(count: Int) -> [Double] {
        let active = patch.oscillators.filter { $0.enabled && $0.level > 0 }
        guard let lowest = active.map(\.octave).min() else { return Array(repeating: 0, count: count) }
        let table = active.contains { $0.wave == .custom } ? Synth.wavetable(patch.harmonics) : []
        let out = (0..<count).map { s -> Double in
            let phase = Double(s) / Double(count)
            return active.reduce(0) { sum, o in
                var p = phase * pow(2, Double(o.octave - lowest))
                p -= floor(p)
                let v: Double
                switch o.wave {
                case .sine: v = sin(2 * .pi * p)
                case .triangle: v = 1 - 4 * abs(p - 0.25 - floor(p + 0.25))
                case .sawtooth: v = 2 * (p - floor(p + 0.5))
                case .square: v = p < 0.5 ? 1 : -1
                case .custom: v = Double(table[Int(p * Double(table.count)) % table.count])
                }
                return sum + v * o.level
            }
        }
        let peak = out.map(abs).max() ?? 1
        return peak > 0 ? out.map { $0 / peak } : out
    }
}

/// ADSR shape: attack, decay and release on a log-ish time axis, sustain as a plateau.
private struct EnvelopeGraph: View {
    let envelope: Patch.Envelope

    var body: some View {
        Canvas { context, size in
            let t = { (s: Double) in log1p(s * 4) }
            let hold = 0.6
            let total = t(envelope.attack) + t(envelope.decay) + hold + t(envelope.release)
            let x = { (v: Double) in size.width * CGFloat(v / total) }
            let y = { (level: Double) in size.height - 4 - CGFloat(level) * (size.height - 8) }
            var a = 0.0
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(0)))
            a += t(envelope.attack); path.addLine(to: CGPoint(x: x(a), y: y(1)))
            a += t(envelope.decay); path.addLine(to: CGPoint(x: x(a), y: y(envelope.sustain)))
            a += hold; path.addLine(to: CGPoint(x: x(a), y: y(envelope.sustain)))
            a += t(envelope.release); path.addLine(to: CGPoint(x: x(a), y: y(0)))
            context.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        }
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
