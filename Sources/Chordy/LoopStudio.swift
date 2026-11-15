import AppKit
import SwiftUI

/// Full editor for a saved loop: a piano roll to move, stretch, add and delete notes and chords,
/// whole-loop changes (key, tempo, length, transpose, quantize, velocity, instrument) and effects.
/// Works on a draft; «Guardar» writes it over the loop, «Duplicar» keeps the original.
struct LoopStudio: View {
    @ObservedObject var loops: Loops
    @ObservedObject var instruments: InstrumentLibrary
    let close: () -> Void

    @State private var draft: Loop
    @State private var selected: Set<Int> = []
    @State private var drag: DragState?
    @State private var previewing = false
    @State private var grid = 0.25

    private struct DragState {
        enum Mode { case move, resize }
        let mode: Mode
        let index: Int
        let original: [Int: LoopEvent]
    }

    init(loops: Loops, instruments: InstrumentLibrary, loop: Loop, close: @escaping () -> Void) {
        self.loops = loops
        self.instruments = instruments
        self.close = close
        _draft = State(initialValue: loop)
    }

    private var original: Loop? { loops.loops.first { $0.id == draft.id } }
    private var dirty: Bool { original != draft }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    toolBar
                    roll
                }
                .padding(16)
                Rectangle().fill(Theme.line).frame(width: 1)
                inspector.frame(width: 280)
            }
        }
        .frame(minWidth: 1040, minHeight: 660)
        .background(Theme.window)
        .onChange(of: draft) { _, new in
            if previewing { loops.preview(new) }
            loops.preview(effects: new.effects, for: new.id)
        }
        .onDisappear {
            if previewing { loops.stopPlayback() }
            loops.preview(effects: nil, for: draft.id)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            TextField("", text: $draft.name).textFieldStyle(.plain).font(.system(size: 18, weight: .bold)).frame(maxWidth: 260)
            InstrumentMenu(instruments: instruments, selected: draft.instrument ?? instruments.selectedId) { id in
                draft.instrument = id
                for i in draft.events.indices { draft.events[i].instrument = nil }
            }
            .help(tr("Instrumento del loop (todas sus partes)"))
            stepper(tr("Tono"), "\(draft.tonic.rawValue) \(draft.flavor.label)",
                    down: { draft.tonic = Note.at(draft.tonic.index - 1) }, up: { draft.tonic = Note.at(draft.tonic.index + 1) })
            Menu {
                ForEach(Flavor.allCases, id: \.self) { f in Button(f.label) { draft.flavor = f } }
            } label: { Text(tr("Modo")).font(.system(size: 11)) }
                .menuStyle(.borderlessButton).fixedSize()
            stepper(tr("Tempo"), "\(draft.bpm)", down: { draft.bpm = max(ChordEngine.bpmRange.lowerBound, draft.bpm - 1) },
                    up: { draft.bpm = min(ChordEngine.bpmRange.upperBound, draft.bpm + 1) })
            stepper(tr("Largo"), LoopMath.formatLength(draft.lengthBeats),
                    down: { setLength(draft.lengthBeats - LoopMath.beatsPerBar) },
                    up: { setLength(draft.lengthBeats + LoopMath.beatsPerBar) })
            Spacer()
            IconButton(symbol: previewing ? "stop.fill" : "play.fill", label: tr("Escuchar"),
                       kind: previewing ? .primary : .secondary) { togglePreview() }
            Button { if let copy = loops.duplicate(draft.id) { draft = copy } } label: { Text(tr("Duplicar")).fixedSize() }
                .buttonStyle(.appSecondary)
                .help(tr("Guarda una copia y sigue editando la copia"))
            Button(tr("Cancelar"), action: close).buttonStyle(.appGhost).keyboardShortcut(.cancelAction)
            Button(tr("Guardar")) { loops.save(draft); close() }
                .buttonStyle(.appPrimary).disabled(!dirty).keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.sidebar)
    }

    private func stepper(_ title: String, _ value: String, down: @escaping () -> Void, up: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            IconButton(symbol: "minus", label: title, size: 22, action: down)
            Text(value).monospacedText(size: 12).fixedSize()
            IconButton(symbol: "plus", label: title, size: 22, action: up)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: Tool bar

    private var toolBar: some View {
        HStack(spacing: 8) {
            Text(tr("Todo el loop")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            Button { transpose(-1) } label: { Text(tr("−1 st")).fixedSize() }.buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            Button { transpose(1) } label: { Text(tr("+1 st")).fixedSize() }.buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            Button { transpose(-12) } label: { Text(tr("−8va")).fixedSize() }.buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            Button { transpose(12) } label: { Text(tr("+8va")).fixedSize() }.buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            Menu {
                Button(tr("Negras")) { quantize(1) }
                Button(tr("Corcheas")) { quantize(0.5) }
                Button(tr("Semicorcheas")) { quantize(0.25) }
            } label: { Text(tr("Cuantizar")).font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 8).frame(height: 26)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.radius))
            Button { scaleVelocity(0.85) } label: { Text(tr("Más suave")).fixedSize() }.buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            Button { scaleVelocity(1.15) } label: { Text(tr("Más fuerte")).fixedSize() }.buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            Spacer()
            Text(selected.isEmpty ? tr("Arrastra para mover · borde derecho para alargar · doble clic añade una nota")
                                  : tr("%d seleccionados", selected.count))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            Button(tr("Borrar")) { deleteSelected() }
                .buttonStyle(AppButtonStyle(kind: .danger, height: 26))
                .disabled(selected.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
        }
    }

    // MARK: Roll

    /// Pitch range: what the loop uses, padded, at least C3–C6.
    private var range: ClosedRange<Int> {
        let pitches = draft.events.flatMap(pitches(of:))
        return min(48, (pitches.min() ?? 48) - 2)...max(84, (pitches.max() ?? 84) + 2)
    }

    private func pitches(of e: LoopEvent) -> [Int] {
        if let midi = e.midi { return [midi] }
        return Music.midiNotes(draft.tonic, e.degree, draft.flavor, e.color, accidental: e.accidental).map { $0 + e.octave * 12 }
    }

    private func label(of e: LoopEvent) -> String {
        if let midi = e.midi { return Note.at(midi).rawValue + "\(midi / 12 - 1)" }
        return Music.symbol(draft.tonic, e.degree, draft.flavor, e.color, accidental: e.accidental)
    }

    private struct Geometry {
        let size: CGSize
        let range: ClosedRange<Int>
        let length: Double
        let labelWidth: CGFloat = 40

        var rowHeight: CGFloat { size.height / CGFloat(range.count) }
        var beatWidth: CGFloat { (size.width - labelWidth) / CGFloat(length) }
        func x(_ beat: Double) -> CGFloat { labelWidth + CGFloat(beat) * beatWidth }
        func beat(_ x: CGFloat) -> Double { Double((x - labelWidth) / beatWidth) }
        func y(_ midi: Int) -> CGFloat { CGFloat(range.upperBound - midi) * rowHeight }
        func midi(_ y: CGFloat) -> Int { range.upperBound - Int(y / rowHeight) }
    }

    private func rect(_ e: LoopEvent, _ g: Geometry) -> CGRect {
        let p = pitches(of: e)
        let top = g.y(p.max() ?? 60), bottom = g.y(p.min() ?? 60) + g.rowHeight
        return CGRect(x: g.x(e.start), y: top, width: max(4, CGFloat(e.length) * g.beatWidth), height: bottom - top)
    }

    private var roll: some View {
        GeometryReader { geo in
            let g = Geometry(size: geo.size, range: range, length: draft.lengthBeats)
            Canvas { context, _ in draw(context, g) }
                .contentShape(Rectangle())
                .gesture(dragGesture(g))
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { addNote(at: $0.location, g) })
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
        .accessibilityLabel(tr("Notas y acordes del loop"))
    }

    private func draw(_ context: GraphicsContext, _ g: Geometry) {
        let black: Set<Int> = [1, 3, 6, 8, 10]
        for midi in g.range {
            if black.contains(midi % 12) {
                context.fill(Path(CGRect(x: g.labelWidth, y: g.y(midi), width: g.size.width, height: g.rowHeight)),
                             with: .color(Theme.field))
            }
            if midi % 12 == 0 {
                context.draw(Text("C\(midi / 12 - 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.text3),
                             at: CGPoint(x: 6, y: g.y(midi) + g.rowHeight / 2), anchor: .leading)
                let y = g.y(midi) + g.rowHeight
                context.fill(Path(CGRect(x: g.labelWidth, y: y, width: g.size.width, height: 1)), with: .color(Theme.lineStrong))
            }
        }
        var beat = 0.0
        while beat <= draft.lengthBeats {
            let bar = beat.truncatingRemainder(dividingBy: LoopMath.beatsPerBar) == 0
            context.fill(Path(CGRect(x: g.x(beat), y: 0, width: 1, height: g.size.height)),
                         with: .color(bar ? Theme.lineStrong : Theme.line))
            beat += grid * 4 >= 1 ? 1 : grid * 4
        }
        if previewing, loops.playingId == draft.id {
            let x = g.x(loops.progress * draft.lengthBeats)
            context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: g.size.height)), with: .color(Theme.text))
        }
        for (i, e) in draft.events.enumerated() {
            let r = rect(e, g)
            let isSelected = selected.contains(i)
            let shape = Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
            if e.midi != nil {
                context.fill(shape, with: .color(Theme.accentFill.opacity(0.35 + 0.65 * Double(e.velocity) / 127)))
            } else {
                context.fill(shape, with: .color(Theme.accentSoft))
                context.stroke(shape, with: .color(Theme.accent), lineWidth: 1.5)
            }
            if isSelected { context.stroke(shape, with: .color(Theme.text), lineWidth: 2) }
            if r.width > 26 {
                context.draw(Text(label(of: e)).font(.system(size: 10, weight: .semibold))
                    .foregroundColor(e.midi != nil ? Theme.onAccent : Theme.accentText),
                             at: CGPoint(x: r.minX + 4, y: e.midi != nil ? r.midY : r.minY + 8), anchor: .leading)
            }
        }
    }

    private func hit(_ point: CGPoint, _ g: Geometry) -> Int? {
        // Topmost first: single notes over chord blocks.
        let order = draft.events.indices.sorted { (draft.events[$0].midi != nil ? 1 : 0) > (draft.events[$1].midi != nil ? 1 : 0) }
        return order.first { rect(draft.events[$0], g).insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func snap(_ beat: Double) -> Double { (beat / grid).rounded() * grid }

    private func dragGesture(_ g: Geometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    guard let i = hit(value.startLocation, g) else {
                        selected = []
                        return
                    }
                    let shift = NSEvent.modifierFlags.contains(.shift)
                    if shift { selected.formSymmetricDifference([i]) } else if !selected.contains(i) { selected = [i] }
                    let r = rect(draft.events[i], g)
                    let mode: DragState.Mode = value.startLocation.x > r.maxX - 7 ? .resize : .move
                    let originals = Dictionary(uniqueKeysWithValues: selected.map { ($0, draft.events[$0]) })
                    drag = DragState(mode: mode, index: i, original: originals)
                }
                guard let d = drag else { return }
                let beats = snap(Double(value.translation.width / g.beatWidth))
                let semis = -Int((value.translation.height / g.rowHeight).rounded())
                for (i, o) in d.original {
                    var e = o
                    switch d.mode {
                    case .move:
                        e.start = min(max(0, o.start + beats), draft.lengthBeats - grid)
                        e.length = min(o.length, draft.lengthBeats - e.start)
                        if let midi = o.midi { e.midi = max(0, min(127, midi + semis)) }
                    case .resize:
                        e.length = min(max(grid, o.length + beats), draft.lengthBeats - o.start)
                    }
                    draft.events[i] = e
                }
            }
            .onEnded { _ in
                drag = nil
                sortKeepingSelection()
            }
    }

    private func addNote(at point: CGPoint, _ g: Geometry) {
        guard hit(point, g) == nil else { return }
        var e = LoopEvent(degree: 1, color: .diatonic, start: min(max(0, snap(g.beat(point.x) - grid / 2)), draft.lengthBeats - grid),
                          length: max(grid, 1))
        e.length = min(e.length, draft.lengthBeats - e.start)
        e.midi = max(0, min(127, g.midi(point.y)))
        e.velocity = 96
        draft.events.append(e)
        selected = [draft.events.count - 1]
        sortKeepingSelection()
    }

    private func sortKeepingSelection() {
        let tagged = draft.events.enumerated().map { ($0.offset, $0.element) }.sorted { $0.1.start < $1.1.start }
        draft.events = tagged.map(\.1)
        selected = Set(tagged.enumerated().filter { selected.contains($0.element.0) }.map(\.offset))
    }

    // MARK: Whole-loop operations

    /// Notes move by semitones; chords move with the key, so they follow too.
    private func transpose(_ semitones: Int) {
        draft.events = LoopMath.transpose(draft.events, semitones: semitones)
        let octaves = semitones / 12, rest = semitones % 12
        if rest != 0 { draft.tonic = Note.at(draft.tonic.index + rest) }
        if octaves != 0 {
            for i in draft.events.indices where draft.events[i].midi == nil { draft.events[i].octave += octaves }
        }
    }

    private func quantize(_ grid: Double) {
        let target = selected.isEmpty ? Set(draft.events.indices) : selected
        let snapped = LoopMath.quantize(target.sorted().map { draft.events[$0] }, grid: grid, length: draft.lengthBeats)
        let kept = draft.events.indices.filter { !target.contains($0) }.map { draft.events[$0] }
        draft.events = (kept + snapped).sorted { $0.start < $1.start }
        selected = []
    }

    private func scaleVelocity(_ factor: Double) {
        let target = selected.isEmpty ? Set(draft.events.indices) : selected
        for i in target { draft.events[i].velocity = max(1, min(127, Int((Double(draft.events[i].velocity) * factor).rounded()))) }
    }

    private func setLength(_ beats: Double) {
        let length = max(LoopMath.beatsPerBar, min(64, beats))
        draft.lengthBeats = length
        draft.events = LoopMath.trim(draft.events, start: 0, end: length)
        selected = []
    }

    private func deleteSelected() {
        draft.events = draft.events.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
        selected = []
    }

    private func togglePreview() {
        if previewing {
            loops.stopPlayback()
            previewing = false
        } else {
            loops.preview(draft)
            previewing = true
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selected.count == 1, let i = selected.first, draft.events.indices.contains(i) {
                    eventInspector(i)
                } else {
                    Text(selected.isEmpty ? tr("Selecciona una nota o un acorde para retocarlo. Mayúsculas + clic selecciona varios.")
                                          : tr("Los cambios de la barra de arriba (cuantizar, fuerza) se aplican a la selección."))
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                effectsEditor
            }
            .padding(16)
        }
        .background(Theme.sidebar)
    }

    private func eventInspector(_ i: Int) -> some View {
        let e = draft.events[i]
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(e.midi != nil ? tr("Nota") : tr("Acorde"))
            if let midi = e.midi {
                row(tr("Altura"), Note.at(midi).rawValue + "\(midi / 12 - 1)",
                    down: { draft.events[i].midi = max(0, midi - 1) }, up: { draft.events[i].midi = min(127, midi + 1) })
            } else {
                HStack(spacing: 4) {
                    ForEach(Music.degrees, id: \.self) { d in
                        Button { draft.events[i].degree = d; draft.events[i].accidental = 0 } label: {
                            Text(Music.numeral(d, draft.flavor)).font(.system(size: 10, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 24)
                                .foregroundStyle(e.degree == d && e.accidental == 0 ? Theme.onAccent : Theme.text)
                                .background(e.degree == d && e.accidental == 0 ? Theme.accentFill : Theme.field,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Menu {
                    ForEach(ChordColor.allCases, id: \.self) { c in Button(c.short) { draft.events[i].color = c } }
                } label: { Text(tr("Color: %@", e.color.short)).font(.system(size: 12)) }
                    .menuStyle(.borderlessButton)
                row(tr("Octava"), String(format: "%+d", e.octave),
                    down: { draft.events[i].octave -= 1 }, up: { draft.events[i].octave += 1 })
            }
            row(tr("Empieza"), String(format: "%.2f", e.start),
                down: { draft.events[i].start = max(0, e.start - grid) },
                up: { draft.events[i].start = min(draft.lengthBeats - e.length, e.start + grid) })
            row(tr("Dura"), String(format: "%.2f", e.length),
                down: { draft.events[i].length = max(grid, e.length - grid) },
                up: { draft.events[i].length = min(draft.lengthBeats - e.start, e.length + grid) })
            HStack {
                Text(tr("Fuerza")).font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 64, alignment: .leading)
                Slider(value: Binding(get: { Double(draft.events[i].velocity) },
                                      set: { draft.events[i].velocity = Int($0.rounded()) }), in: 1...127)
                    .controlSize(.small)
                Text("\(e.velocity)").monospacedText(size: 11).frame(width: 28)
            }
        }
    }

    private func row(_ title: String, _ value: String, down: @escaping () -> Void, up: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 64, alignment: .leading)
            IconButton(symbol: "minus", label: title, size: 22, action: down)
            Text(value).monospacedText(size: 12).frame(minWidth: 44)
            IconButton(symbol: "plus", label: title, size: 22, action: up)
        }
    }

    private var effectsEditor: some View {
        EffectsEditor(effects: Binding(get: { draft.effects ?? .none }, set: { draft.effects = $0.isOff ? nil : $0 }))
    }
}

/// Reverb, delay and filter sliders (sampled instruments only).
struct EffectsEditor: View {
    @Binding var effects: Effects

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(tr("Efectos"))
                Spacer()
                Button(tr("Quitar")) { effects = .none }.buttonStyle(AppButtonStyle(kind: .ghost, height: 22)).disabled(effects.isOff)
            }
            ParamSlider(label: tr("Reverb"), value: $effects.reverb, range: 0...1, format: Format.percent)
            ParamSlider(label: tr("Eco"), value: $effects.delay, range: 0...1, format: Format.percent)
            ParamSlider(label: tr("Tiempo eco"), value: $effects.delayTime, range: 0.05...1.5, log: true, format: Format.seconds)
            ParamSlider(label: tr("Repeticiones"), value: $effects.feedback, range: 0...0.9, format: Format.percent)
            ParamSlider(label: tr("Filtro"), value: $effects.filter, range: 0...1,
                        format: { $0 >= 0.999 ? tr("abierto") : Format.hz(200 * pow(100, $0)) })
            Text(tr("Se aplican a los instrumentos reales; el sintetizador tiene su propio filtro en «Sonido»."))
                .font(.system(size: 10)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
