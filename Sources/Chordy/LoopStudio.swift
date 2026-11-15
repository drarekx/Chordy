import AppKit
import SwiftUI

/// Full-window loop editor: ruler with bars and beats, piano keys, zoom and scroll, a grid to
/// place notes exactly (free, 1/4 … 1/32, triplets), select / pencil / erase tools, rubber-band
/// selection, ⌥-drag copies, an A–B section to loop while testing (with drums and click if
/// wanted), "fit to tempo" with strength and swing, a velocity lane, copy/paste and undo.
/// Works on a draft; «Guardar» writes it over the loop.
struct LoopStudio: View {
    @ObservedObject var loops: Loops
    @ObservedObject var instruments: InstrumentLibrary
    @ObservedObject var drums: DrumMachine
    let close: () -> Void

    enum Tool: String, CaseIterable { case select, pencil, eraser }

    @State private var draft: Loop
    @State private var selected: Set<Int> = []
    @State private var undoStack: [Loop] = []
    @State private var redoStack: [Loop] = []
    @State private var tool = Tool.select
    /// What the pencil paints: single notes or chords of `paintColor`.
    @AppStorage("editorPaintChords") private var paintChords = false
    @AppStorage("editorPaintColor") private var paintColor = ChordColor.diatonic
    /// Beats per grid step; 0 = free (1/96).
    @State private var grid = 0.25
    @State private var zoomX = 1.0
    @State private var startBeat = 0.0
    @State private var rowHeight: CGFloat = 20
    @State private var topNote = 84
    @State private var region: ClosedRange<Double>?
    @State private var abOn = true
    @State private var previewing = false
    @State private var playOffset = 0.0
    @State private var playLength = 4.0
    @State private var withDrums = false
    @State private var startedDrums = false
    @State private var click = false
    @State private var drag: DragState?
    @State private var marquee: CGRect?
    @State private var rulerDrag: Double?
    @State private var strength = 1.0
    @State private var quantizeEnds = true
    @State private var swing = 0.0
    @State private var rollFrame: CGRect = .zero
    @State private var overviewDrag: OverviewDrag?
    @State private var monitors: [Any] = []
    private static var clipboard: [LoopEvent] = []

    private struct DragState {
        enum Mode { case move, resize, marquee, erase, create }
        var mode: Mode
        let snapshot: Loop
        var originals: [Int: LoopEvent]
        let startBeat: Double
        let startNote: Int
        var copied = false
    }

    init(loops: Loops, instruments: InstrumentLibrary, drums: DrumMachine, loop: Loop, close: @escaping () -> Void) {
        self.loops = loops
        self.instruments = instruments
        self.drums = drums
        self.close = close
        _draft = State(initialValue: loop)
        let pitches = loop.events.compactMap(\.midi)
        // Notes (or C3–C5) in view: top a few rows above the highest note.
        let high = pitches.max() ?? 72, low = pitches.min() ?? 48
        _topNote = State(initialValue: min(120, max(high + 4, low + 24)))
    }

    private var original: Loop? { loops.loops.first { $0.id == draft.id } }
    private var dirty: Bool { original != draft }
    private var gridStep: Double { grid > 0 ? grid : LoopMath.fine }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.line).frame(height: 1)
            toolBar
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                editorArea
                Rectangle().fill(Theme.line).frame(width: 1)
                inspector.frame(width: 300)
            }
        }
        .background(Theme.window)
        .onAppear(perform: installMonitors)
        .onDisappear {
            removeMonitors()
            stopPreview()
            loops.preview(effects: nil, for: draft.id)
        }
        .onChange(of: draft) { _, new in
            if previewing { startPreview() }
            loops.preview(effects: new.effects, for: new.id)
        }
        .onReceive(BeatClock.shared.$beat) { beat in
            guard previewing, click, let beat else { return }
            Synth.shared.click(accent: beat % 4 == 0)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: { Label(tr("Loops"), systemImage: "chevron.left").fixedSize() }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 28))
            TextField("", text: $draft.name).textFieldStyle(.plain).font(.system(size: 18, weight: .bold)).frame(maxWidth: 220)
            InstrumentMenu(instruments: instruments, selected: draft.instrument ?? instruments.selectedId) { id in
                commit { d in
                    d.instrument = id
                    for i in d.events.indices { d.events[i].instrument = nil }
                }
            }
            stepper(tr("Tono"), "\(draft.tonic.rawValue) \(draft.flavor.label)",
                    down: { commit { $0.tonic = Note.at($0.tonic.index - 1) } },
                    up: { commit { $0.tonic = Note.at($0.tonic.index + 1) } })
            Menu {
                ForEach(Flavor.allCases, id: \.self) { f in Button(f.label) { commit { $0.flavor = f } } }
            } label: { Text(tr("Modo")).font(.system(size: 11)) }
                .menuStyle(.borderlessButton).fixedSize()
            stepper(tr("Tempo"), "\(draft.bpm)",
                    down: { commit { $0.bpm = max(ChordEngine.bpmRange.lowerBound, $0.bpm - 1) } },
                    up: { commit { $0.bpm = min(ChordEngine.bpmRange.upperBound, $0.bpm + 1) } })
            stepper(tr("Largo"), LoopMath.formatLength(draft.lengthBeats),
                    down: { setLength(draft.lengthBeats - LoopMath.beatsPerBar) },
                    up: { setLength(draft.lengthBeats + LoopMath.beatsPerBar) })
            Spacer(minLength: 8)
            transport
            Button { if let copy = loops.duplicate(draft.id) { draft = copy; undoStack = []; redoStack = [] } } label: {
                Text(tr("Duplicar")).fixedSize()
            }
            .buttonStyle(.appSecondary)
            IconButton(symbol: "arrow.uturn.backward", label: tr("Deshacer (⌘Z)"), size: 28) { undo() }
                .disabled(undoStack.isEmpty)
            IconButton(symbol: "arrow.uturn.forward", label: tr("Rehacer (⇧⌘Z)"), size: 28) { redo() }
                .disabled(redoStack.isEmpty)
            Button(tr("Guardar")) { loops.save(draft) }
                .buttonStyle(.appPrimary).disabled(!dirty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Theme.sidebar)
    }

    private var transport: some View {
        HStack(spacing: 4) {
            IconButton(symbol: previewing ? "stop.fill" : "play.fill", label: tr("Escuchar (espacio)"),
                       kind: previewing ? .primary : .secondary, size: 30) { togglePreview() }
            toggleChip("A–B", on: abOn && region != nil, enabled: region != nil,
                       help: tr("Repetir solo la parte A–B (arrastra en la regla para marcarla)")) { abOn.toggle(); restartIfPlaying() }
            toggleChip(tr("Batería"), on: withDrums, enabled: true, help: tr("Escuchar con la batería")) {
                withDrums.toggle()
                if previewing { syncDrums() }
            }
            toggleChip(tr("Clic"), on: click, enabled: true, help: tr("Metrónomo al escuchar")) { click.toggle() }
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
    }

    private func toggleChip(_ title: String, on: Bool, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 30)
                .foregroundStyle(on ? Theme.window : (enabled ? Theme.text2 : Theme.text3))
                .background(on ? Theme.warn : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
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
        HStack(spacing: 10) {
            SegmentedControl(options: [(tr("↖ Seleccionar"), Tool.select), (tr("✎ Lápiz"), .pencil), (tr("⌫ Borrar"), .eraser)],
                             selection: $tool)
                .fixedSize()
            Group {
                SegmentedControl(options: [(tr("♪ Nota"), false), (tr("♫ Acorde"), true)],
                                 selection: Binding(get: { paintChords }, set: { paintChords = $0; tool = .pencil }))
                    .fixedSize()
                    .help(tr("Qué pinta el lápiz"))
                if paintChords {
                    Menu {
                        ChordTypeMenuItems(selected: paintColor) { paintColor = $0 }
                    } label: { Text(paintColor.name).font(.system(size: 12, weight: .semibold)) }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .help(tr("Tipo del acorde que pinta el lápiz (la fila que tocas es su nota base)"))
                }
            }
            Text(tr("Rejilla")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            SegmentedControl(options: [(tr("Libre"), 0.0), ("1/4", 1.0), ("1/8", 0.5), ("1/16", 0.25), ("1/32", 0.125),
                                       (tr("Tresillo"), 1.0 / 3)], selection: $grid)
                .fixedSize()
            Rectangle().fill(Theme.line).frame(width: 1, height: 24)
            Button { fitToTempo() } label: {
                Label(tr("Ajustar al tempo · %d %%", Int((strength * 100).rounded())), systemImage: "metronome").fixedSize()
            }
            .buttonStyle(AppButtonStyle(kind: .primary, height: 28))
            .help(tr("Encaja la selección (o todo) en la rejilla; ajusta la intensidad a la derecha"))
            tool(tr("Copiar")) { copySelection() }
            tool(tr("Pegar")) { paste() }
            tool("−1 st") { transposeSelection(-1) }
            tool("+1 st") { transposeSelection(1) }
            tool(tr("Más suave")) { scaleVelocity(0.85) }
            tool(tr("Más fuerte")) { scaleVelocity(1.15) }
            Spacer(minLength: 6)
            Text(tr("Zoom")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            IconButton(symbol: "minus.magnifyingglass", label: tr("Alejar (⌘ + rueda)"), size: 26) { zoom(0.7) }
            IconButton(symbol: "plus.magnifyingglass", label: tr("Acercar (⌘ + rueda)"), size: 26) { zoom(1.4) }
            IconButton(symbol: "arrow.up.and.down", label: tr("Filas más altas (⌥ + rueda)"), size: 26) {
                rowHeight = min(32, rowHeight + 3)
            }
            IconButton(symbol: "arrow.down.right.and.arrow.up.left", label: tr("Filas más bajas"), size: 26) {
                rowHeight = max(8, rowHeight - 3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func tool(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12)).fixedSize() }
            .buttonStyle(AppButtonStyle(kind: .secondary, height: 28, padding: 9))
    }

    // MARK: Geometry

    private struct Geo {
        let width: CGFloat
        let height: CGFloat
        let startBeat: Double
        let visibleBeats: Double
        let rowHeight: CGFloat
        let topNote: Int

        var beatWidth: CGFloat { width / CGFloat(visibleBeats) }
        func x(_ beat: Double) -> CGFloat { CGFloat(beat - startBeat) * beatWidth }
        func beat(_ x: CGFloat) -> Double { startBeat + Double(x / beatWidth) }
        func y(_ midi: Int) -> CGFloat { CGFloat(topNote - midi) * rowHeight }
        func midi(_ y: CGFloat) -> Int { topNote - Int((y / rowHeight).rounded(.down)) }
        var lowNote: Int { topNote - Int(height / rowHeight) }
    }

    private var visibleBeats: Double { max(1, draft.lengthBeats / zoomX) }

    private func geo(_ size: CGSize) -> Geo {
        Geo(width: size.width, height: size.height, startBeat: startBeat, visibleBeats: visibleBeats,
            rowHeight: rowHeight, topNote: topNote)
    }

    private func pitches(of e: LoopEvent) -> [Int] {
        if let midi = e.midi { return [midi] }
        return Music.midiNotes(draft.tonic, e.degree, draft.flavor, e.color, accidental: e.accidental).map { $0 + e.octave * 12 }
    }

    /// MIDI note of a chord's root (where the pencil puts it and what ↑ ↓ moves).
    private func rootMidi(of e: LoopEvent) -> Int {
        60 + draft.tonic.index + Music.rootInterval(e.degree, draft.flavor) + e.accidental + e.octave * 12
    }

    /// A chord whose root is `root` (any note: off-scale ones become a raised degree).
    private func chord(root: Int, color: ChordColor, start: Double, length: Double, velocity: Int = 96) -> LoopEvent {
        let (degree, accidental) = Music.root(ofPitchClass: root, draft.tonic, draft.flavor)
        let base = 60 + draft.tonic.index + Music.rootInterval(degree, draft.flavor) + accidental
        let octave = Int((Double(root - base) / 12).rounded(.down))
        var e = LoopEvent(degree: degree, color: color, octave: max(-4, min(4, octave)), accidental: accidental,
                          start: start, length: length)
        e.velocity = velocity
        return e
    }

    /// The same chord moved by `semis` semitones (its notes follow its new root).
    private func moved(_ e: LoopEvent, by semis: Int) -> LoopEvent {
        if let m = e.midi {
            var copy = e
            copy.midi = max(0, min(127, m + semis))
            return copy
        }
        var copy = chord(root: rootMidi(of: e) + semis, color: e.color, start: e.start, length: e.length, velocity: e.velocity)
        copy.instrument = e.instrument
        return copy
    }

    private func label(of e: LoopEvent) -> String {
        if let midi = e.midi { return Note.at(midi).rawValue + "\(midi / 12 - 1)" }
        return Music.symbol(draft.tonic, e.degree, draft.flavor, e.color, accidental: e.accidental)
    }

    private func rect(_ e: LoopEvent, _ g: Geo) -> CGRect {
        let p = pitches(of: e)
        let top = g.y(p.max() ?? 60), bottom = g.y(p.min() ?? 60) + g.rowHeight
        return CGRect(x: g.x(e.start), y: top, width: max(4, CGFloat(e.length) * g.beatWidth), height: bottom - top)
    }

    private func snap(_ beat: Double) -> Double { (beat / gridStep).rounded() * gridStep }

    // MARK: Editor area (ruler, keys, roll, velocity lane)

    private var editorArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 56, height: 30)
                GeometryReader { geo in ruler(geo.size) }.frame(height: 30)
            }
            .background(Theme.sidebar)
            HStack(spacing: 0) {
                GeometryReader { geo in keys(geo.size) }.frame(width: 56)
                GeometryReader { geo in
                    roll(geo.size)
                        .onAppear { rollFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, f in rollFrame = f }
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                Text(tr("Fuerza")).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text3).frame(width: 56)
                GeometryReader { geo in velocityLane(geo.size) }
            }
            .frame(height: 90)
            .background(Theme.sidebar)
            scrollBar
        }
    }

    /// Overview of the whole loop with the visible part as a big box: drag the box to move,
    /// pull its edges to zoom, click anywhere to jump there.
    private var scrollBar: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "chevron.left", label: tr("Un compás atrás"), size: 34) { scroll(by: -4) }
                .disabled(startBeat <= 0.001)
            GeometryReader { geo in overview(geo.size) }
                .frame(height: 40)
                .help(tr("Arrastra el recuadro para moverte · tira de sus bordes para acercar o alejar · clic para saltar · rueda: desplazar · ⌘ rueda: zoom · ⌥ rueda: filas"))
            IconButton(symbol: "chevron.right", label: tr("Un compás adelante"), size: 34) { scroll(by: 4) }
                .disabled(startBeat >= draft.lengthBeats - visibleBeats - 0.001)
            Button { zoomX = 1; startBeat = 0 } label: { Text(tr("Ver todo")).fixedSize() }
                .buttonStyle(AppButtonStyle(kind: .secondary, height: 34, padding: 10))
                .disabled(zoomX <= 1.0001)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func scroll(by beats: Double) {
        startBeat = min(max(0, startBeat + beats), max(0, draft.lengthBeats - visibleBeats))
    }

    private enum OverviewDrag { case move(offset: Double), left(right: Double), right(left: Double) }

    private func overview(_ size: CGSize) -> some View {
        let length = max(0.001, draft.lengthBeats)
        let scale = size.width / CGFloat(length)
        let all = draft.events.flatMap { self.pitches(of: $0) }
        let low = (all.min() ?? 48) - 1, high = max((all.max() ?? 72) + 1, low + 8)
        return Canvas { context, _ in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Theme.window))
            // Bars.
            var bar = 0.0
            while bar <= length {
                let x = CGFloat(bar) * scale
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.line))
                if bar < length {
                    context.draw(Text("\(Int(bar / 4) + 1)").font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.text3),
                                 at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                }
                bar += 4
            }
            // Notes.
            for e in draft.events {
                let x = CGFloat(e.start) * scale, w = max(1.5, CGFloat(e.length) * scale)
                for p in pitches(of: e) {
                    let y = 14 + CGFloat(high - p) / CGFloat(high - low) * (size.height - 18)
                    context.fill(Path(CGRect(x: x, y: y, width: w, height: 2)), with: .color(Theme.accentFill.opacity(0.75)))
                }
            }
            if previewing, loops.playingId == draft.id {
                let x = CGFloat(playOffset + loops.progress * playLength) * scale
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.text))
            }
            // Visible part.
            let box = CGRect(x: CGFloat(startBeat) * scale, y: 1, width: max(14, CGFloat(visibleBeats) * scale), height: size.height - 2)
            context.fill(Path(roundedRect: box, cornerRadius: 7), with: .color(Theme.accentFill.opacity(0.16)))
            context.stroke(Path(roundedRect: box, cornerRadius: 7), with: .color(Theme.accentText), lineWidth: 2)
            for edge in [box.minX + 4, box.maxX - 6] {
                context.fill(Path(roundedRect: CGRect(x: edge, y: box.midY - 8, width: 2, height: 16), cornerRadius: 1),
                             with: .color(Theme.accentText))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let beat = Double(v.location.x / scale)
                    if overviewDrag == nil {
                        let b0 = Double(v.startLocation.x / scale)
                        let left = CGFloat(startBeat) * scale, right = CGFloat(startBeat + visibleBeats) * scale
                        if abs(v.startLocation.x - left) < 8 {
                            overviewDrag = .left(right: startBeat + visibleBeats)
                        } else if abs(v.startLocation.x - right) < 8 {
                            overviewDrag = .right(left: startBeat)
                        } else if v.startLocation.x > left, v.startLocation.x < right {
                            overviewDrag = .move(offset: b0 - startBeat)
                        } else {
                            // Click outside the box: center the view there, then keep dragging it.
                            overviewDrag = .move(offset: visibleBeats / 2)
                        }
                    }
                    switch overviewDrag {
                    case .move(let offset):
                        startBeat = min(max(0, beat - offset), max(0, length - visibleBeats))
                    case .left(let right):
                        let left = min(max(0, beat), right - 1)
                        zoomX = min(32, max(1, length / (right - left)))
                        startBeat = max(0, right - visibleBeats)
                    case .right(let left):
                        let right = max(min(length, beat), left + 1)
                        zoomX = min(32, max(1, length / (right - left)))
                        startBeat = min(left, max(0, length - visibleBeats))
                    case nil:
                        break
                    }
                }
                .onEnded { _ in overviewDrag = nil }
        )
    }

    private func ruler(_ size: CGSize) -> some View {
        let g = Geo(width: size.width, height: size.height, startBeat: startBeat, visibleBeats: visibleBeats,
                    rowHeight: rowHeight, topNote: topNote)
        return Canvas { context, _ in
            if let r = region {
                let rect = CGRect(x: g.x(r.lowerBound), y: 0, width: CGFloat(r.upperBound - r.lowerBound) * g.beatWidth, height: size.height)
                context.fill(Path(rect), with: .color(Theme.warn.opacity(abOn ? 0.25 : 0.1)))
                context.fill(Path(CGRect(x: rect.minX, y: 0, width: 2, height: size.height)), with: .color(Theme.warn))
                context.fill(Path(CGRect(x: rect.maxX - 2, y: 0, width: 2, height: size.height)), with: .color(Theme.warn))
                context.draw(Text("A").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.window),
                             at: CGPoint(x: rect.minX + 8, y: 8))
                context.draw(Text("B").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.window),
                             at: CGPoint(x: rect.maxX - 8, y: 8))
            }
            var b = (startBeat).rounded(.down)
            while b <= startBeat + visibleBeats {
                let bar = b.truncatingRemainder(dividingBy: LoopMath.beatsPerBar) == 0
                let x = g.x(b)
                context.fill(Path(CGRect(x: x, y: bar ? 6 : 16, width: 1, height: size.height)), with: .color(bar ? Theme.text2 : Theme.lineStrong))
                if bar {
                    context.draw(Text("\(Int(b / 4) + 1)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.text), at: CGPoint(x: x + 4, y: 16), anchor: .leading)
                } else if g.beatWidth > 34 {
                    context.draw(Text("\(Int(b.truncatingRemainder(dividingBy: 4)) + 1)").font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.text3), at: CGPoint(x: x + 3, y: 22), anchor: .leading)
                }
                b += 1
            }
            if previewing, loops.playingId == draft.id {
                let x = g.x(playOffset + loops.progress * playLength)
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.text))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    let a = max(0, snapToBeat(g.beat(v.startLocation.x)))
                    let b = min(draft.lengthBeats, max(0, snapToBeat(g.beat(v.location.x))))
                    if abs(b - a) >= gridStepOrBeat { region = min(a, b)...max(a, b); abOn = true }
                }
                .onEnded { _ in restartIfPlaying() }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { region = nil; restartIfPlaying() })
        .help(tr("Arrastra para marcar A–B · doble clic lo quita"))
    }

    private var gridStepOrBeat: Double { grid > 0 ? grid : 0.25 }
    private func snapToBeat(_ b: Double) -> Double { let s = gridStepOrBeat; return (b / s).rounded() * s }

    private func keys(_ size: CGSize) -> some View {
        let black: Set<Int> = [1, 3, 6, 8, 10]
        return Canvas { context, _ in
            let rows = Int(size.height / rowHeight) + 1
            for i in 0..<rows {
                let midi = topNote - i
                guard midi >= 0 else { break }
                let r = CGRect(x: 0, y: CGFloat(i) * rowHeight, width: size.width - 1, height: rowHeight - 0.5)
                context.fill(Path(r), with: .color(black.contains(midi % 12) ? Color(white: 0.17) : Color(white: 0.86)))
                if midi % 12 == 0 && rowHeight >= 10 {
                    context.draw(Text("C\(midi / 12 - 1)").font(.system(size: min(10, rowHeight - 3), design: .monospaced))
                        .foregroundColor(Color(white: 0.2)), at: CGPoint(x: 6, y: r.midY), anchor: .leading)
                }
            }
        }
        .clipped()
    }

    private func roll(_ size: CGSize) -> some View {
        let g = geo(size)
        return Canvas { context, _ in drawRoll(context, g) }
            .contentShape(Rectangle())
            .gesture(rollGesture(g))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { if tool == .select { addNote(at: $0.location, g) } })
            .clipped()
            .background(Theme.card)
    }

    private func drawRoll(_ context: GraphicsContext, _ g: Geo) {
        let black: Set<Int> = [1, 3, 6, 8, 10]
        for midi in stride(from: g.topNote, through: max(0, g.lowNote), by: -1) {
            let y = g.y(midi)
            if black.contains(midi % 12) {
                context.fill(Path(CGRect(x: 0, y: y, width: g.width, height: g.rowHeight)), with: .color(Theme.field))
            }
            if midi % 12 == 0 {
                context.fill(Path(CGRect(x: 0, y: y + g.rowHeight - 1, width: g.width, height: 1)), with: .color(Theme.lineStrong))
            }
        }
        // Grid: bars, beats and the chosen step when wide enough.
        let step = grid > 0 ? grid : 0.25
        var b = (startBeat / step).rounded(.down) * step
        while b <= startBeat + visibleBeats {
            let bar = abs(b.truncatingRemainder(dividingBy: LoopMath.beatsPerBar)) < 1e-6
            let beat = abs(b - b.rounded()) < 1e-6
            if bar || beat || CGFloat(step) * g.beatWidth > 7 {
                context.fill(Path(CGRect(x: g.x(b), y: 0, width: 1, height: g.height)),
                             with: .color(bar ? Theme.text3.opacity(0.6) : (beat ? Theme.lineStrong : Theme.line.opacity(0.6))))
            }
            b += step
        }
        context.fill(Path(CGRect(x: g.x(draft.lengthBeats), y: 0, width: max(0, g.width - g.x(draft.lengthBeats)), height: g.height)),
                     with: .color(Theme.window.opacity(0.6)))
        if let r = region, abOn {
            context.fill(Path(CGRect(x: g.x(r.lowerBound), y: 0, width: CGFloat(r.upperBound - r.lowerBound) * g.beatWidth,
                                     height: g.height)), with: .color(Theme.warn.opacity(0.06)))
        }
        for (i, e) in draft.events.enumerated() {
            let r = rect(e, g)
            guard r.maxX >= 0, r.minX <= g.width, r.maxY >= 0, r.minY <= g.height else { continue }
            let isSel = selected.contains(i)
            let shape = Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4)
            if e.midi != nil {
                context.fill(shape, with: .color((isSel ? Theme.accentText : Theme.accentFill).opacity(0.45 + 0.55 * Double(e.velocity) / 127)))
            } else {
                context.fill(shape, with: .color(Theme.accentSoft))
                context.stroke(shape, with: .color(Theme.accent), lineWidth: 1.5)
            }
            if isSel { context.stroke(shape, with: .color(Theme.text), lineWidth: 2) }
            if r.width > 26 && r.height >= 10 {
                context.draw(Text(label(of: e)).font(.system(size: min(10, r.height - 2), weight: .semibold))
                    .foregroundColor(e.midi != nil ? Theme.onAccent : Theme.accentText),
                             at: CGPoint(x: r.minX + 4, y: e.midi != nil ? r.midY : r.minY + 7), anchor: .leading)
            }
        }
        if let m = marquee {
            context.fill(Path(roundedRect: m, cornerRadius: 3), with: .color(Theme.text.opacity(0.06)))
            context.stroke(Path(roundedRect: m, cornerRadius: 3), with: .color(Theme.text), style: StrokeStyle(lineWidth: 1, dash: [4]))
        }
        if previewing, loops.playingId == draft.id {
            let x = g.x(playOffset + loops.progress * playLength)
            context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: g.height)), with: .color(Theme.text))
        }
    }

    private func hit(_ p: CGPoint, _ g: Geo) -> Int? {
        let order = draft.events.indices.sorted { (draft.events[$0].midi != nil ? 1 : 0) > (draft.events[$1].midi != nil ? 1 : 0) }
        return order.first { rect(draft.events[$0], g).insetBy(dx: -2, dy: -1).contains(p) }
    }

    private func rollGesture(_ g: Geo) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { beginDrag(v, g) }
                continueDrag(v, g)
            }
            .onEnded { _ in endDrag() }
    }

    private func beginDrag(_ v: DragGesture.Value, _ g: Geo) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        let p = v.startLocation
        let hitIndex = hit(p, g)
        var state = DragState(mode: .marquee, snapshot: draft, originals: [:], startBeat: g.beat(p.x), startNote: g.midi(p.y))
        switch tool {
        case .eraser:
            state.mode = .erase
        case .pencil where hitIndex == nil:
            let e = newEvent(at: p, g, in: draft)
            draft.events.append(e)
            let i = draft.events.count - 1
            selected = [i]
            state.mode = .create
            state.originals = [i: e]
        default:
            if let i = hitIndex {
                if shift { selected.formSymmetricDifference([i]) } else if !selected.contains(i) { selected = [i] }
                let r = rect(draft.events[i], g)
                state.mode = p.x > r.maxX - 7 ? .resize : .move
                state.originals = Dictionary(uniqueKeysWithValues: selected.map { ($0, draft.events[$0]) })
            } else {
                if !shift { selected = [] }
                state.mode = .marquee
            }
        }
        drag = state
    }

    /// What the pencil adds at `p`: a note on that row, or a chord with its root there.
    private func newEvent(at p: CGPoint, _ g: Geo, in loop: Loop) -> LoopEvent {
        let start = max(0, min(loop.lengthBeats - gridStep, snapDown(g.beat(p.x))))
        // Chords last a beat by default (notes a grid step): they're usually held.
        let length = paintChords ? min(loop.lengthBeats - start, max(1, grid)) : (grid > 0 ? grid : 0.25)
        let row = max(0, min(127, g.midi(p.y)))
        if paintChords { return chord(root: row, color: paintColor, start: start, length: length) }
        var e = LoopEvent(degree: 1, color: .diatonic, start: start, length: length)
        e.midi = row
        e.velocity = 96
        return e
    }

    private func snapDown(_ b: Double) -> Double { (b / gridStep).rounded(.down) * gridStep }

    private func continueDrag(_ v: DragGesture.Value, _ g: Geo) {
        guard var d = drag else { return }
        switch d.mode {
        case .marquee:
            let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                           width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
            marquee = r
            if r.width > 2 || r.height > 2 {
                let inside = Set(draft.events.indices.filter { rect(draft.events[$0], g).intersects(r) })
                selected = NSEvent.modifierFlags.contains(.shift) ? selected.union(inside) : inside
            }
        case .erase:
            if let i = hit(v.location, g) {
                draft.events.remove(at: i)
                selected = []
            }
        case .create, .resize:
            let delta = g.beat(v.location.x) - d.startBeat
            let free = NSEvent.modifierFlags.contains(.command)
            for (i, o) in d.originals where draft.events.indices.contains(i) {
                let raw = d.mode == .create ? max(o.start + gridStep, o.start + o.length + delta) : o.start + o.length + delta
                let end = free ? raw : snap(raw)
                draft.events[i].length = min(max(gridStep, end - o.start), draft.lengthBeats - o.start)
            }
        case .move:
            // ⌥ at the start of a move copies: the originals stay, the copies move.
            if !d.copied, NSEvent.modifierFlags.contains(.option), abs(v.translation.width) + abs(v.translation.height) > 3 {
                var map: [Int: LoopEvent] = [:]
                for (_, o) in d.originals {
                    draft.events.append(o)
                    map[draft.events.count - 1] = o
                }
                d.originals = map
                selected = Set(map.keys)
                d.copied = true
            }
            let delta = g.beat(v.location.x) - d.startBeat
            let semis = g.midi(v.location.y) - d.startNote
            // ⌘ while dragging places freely, ignoring the grid.
            let free = grid == 0 || NSEvent.modifierFlags.contains(.command)
            for (i, o) in d.originals where draft.events.indices.contains(i) {
                let start = free ? (o.start + delta) / LoopMath.fine * LoopMath.fine : snap(o.start + delta)
                draft.events[i].start = min(max(0, start), draft.lengthBeats - min(o.length, gridStep))
                draft.events[i].length = min(o.length, draft.lengthBeats - draft.events[i].start)
                if o.midi != nil {
                    draft.events[i].midi = max(0, min(127, o.midi! + semis))
                } else if semis != 0 || draft.events[i].degree != o.degree || draft.events[i].octave != o.octave {
                    let m = moved(o, by: semis)
                    draft.events[i].degree = m.degree
                    draft.events[i].accidental = m.accidental
                    draft.events[i].octave = m.octave
                }
            }
        }
        drag = d
    }

    private func endDrag() {
        if let d = drag, d.snapshot != draft { pushUndo(d.snapshot) }
        drag = nil
        marquee = nil
        sortKeepingSelection()
    }

    private func addNote(at p: CGPoint, _ g: Geo) {
        guard hit(p, g) == nil else { return }
        commit { d in
            d.events.append(newEvent(at: p, g, in: d))
        }
        selected = [draft.events.count - 1]
        sortKeepingSelection()
    }

    private func velocityLane(_ size: CGSize) -> some View {
        let g = Geo(width: size.width, height: size.height, startBeat: startBeat, visibleBeats: visibleBeats,
                    rowHeight: rowHeight, topNote: topNote)
        return Canvas { context, _ in
            for (i, e) in draft.events.enumerated() {
                let x = g.x(e.start)
                guard x >= -6, x <= size.width else { continue }
                let h = (size.height - 10) * CGFloat(e.velocity) / 127
                context.fill(Path(roundedRect: CGRect(x: x, y: size.height - 4 - h, width: 6, height: h), cornerRadius: 2),
                             with: .color(selected.contains(i) ? Theme.accentText : Theme.accentFill))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if drag == nil { drag = DragState(mode: .move, snapshot: draft, originals: [:], startBeat: 0, startNote: 0) }
                    let v127 = Int((1 - min(1, max(0, (v.location.y - 4) / (size.height - 10)))) * 126) + 1
                    let targets = draft.events.indices.filter { abs(g.x(draft.events[$0].start) + 3 - v.location.x) < 6 }
                    let chosen = targets.filter { selected.contains($0) }.isEmpty ? targets : targets.filter { selected.contains($0) }
                    for i in chosen { draft.events[i].velocity = v127 }
                }
                .onEnded { _ in
                    if let d = drag, d.snapshot != draft { pushUndo(d.snapshot) }
                    drag = nil
                }
        )
    }

    // MARK: Editing helpers

    private func commit(_ change: (inout Loop) -> Void) {
        let before = draft
        change(&draft)
        if before != draft { pushUndo(before) }
    }

    private func pushUndo(_ snapshot: Loop) {
        undoStack.append(snapshot)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = last
        selected = []
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draft)
        draft = next
        selected = []
    }

    private func sortKeepingSelection() {
        let tagged = draft.events.enumerated().map { ($0.offset, $0.element) }.sorted { $0.1.start < $1.1.start }
        let newSelection = Set(tagged.enumerated().filter { selected.contains($0.element.0) }.map(\.offset))
        draft.events = tagged.map(\.1)
        selected = newSelection
    }

    private var targets: [Int] { selected.isEmpty ? Array(draft.events.indices) : selected.sorted() }

    /// Snap starts (and ends) of the selection — or everything — to the grid, by `strength`,
    /// with swing on the off-steps.
    private func fitToTempo() {
        let g = grid > 0 ? grid : 0.25
        commit { d in
            for i in targets where d.events.indices.contains(i) {
                var e = d.events[i]
                let index = (e.start / g).rounded()
                var q = index * g
                if swing > 0, Int(index) % 2 == 1 { q += swing * g * 0.5 }
                let newStart = e.start + (q - e.start) * strength
                if quantizeEnds {
                    let end = e.start + e.length
                    let qe = (end / g).rounded() * g
                    let newEnd = end + (qe - end) * strength
                    e.length = max(g * 0.25, newEnd - newStart)
                }
                e.start = max(0, min(d.lengthBeats - g * 0.25, newStart))
                e.length = min(e.length, d.lengthBeats - e.start)
                d.events[i] = e
            }
        }
        sortKeepingSelection()
    }

    private func transposeSelection(_ semis: Int) {
        commit { d in
            for i in targets where d.events.indices.contains(i) {
                let m = moved(d.events[i], by: semis)
                d.events[i].midi = m.midi
                d.events[i].degree = m.degree
                d.events[i].accidental = m.accidental
                d.events[i].octave = m.octave
            }
        }
    }

    private func moveSelection(beats: Double) {
        guard !selected.isEmpty else { return }
        commit { d in
            for i in selected where d.events.indices.contains(i) {
                d.events[i].start = max(0, min(d.lengthBeats - d.events[i].length, d.events[i].start + beats))
            }
        }
        sortKeepingSelection()
    }

    private func scaleVelocity(_ factor: Double) {
        commit { d in
            for i in targets where d.events.indices.contains(i) {
                d.events[i].velocity = max(1, min(127, Int((Double(d.events[i].velocity) * factor).rounded())))
            }
        }
    }

    private func copySelection() {
        let picked = selected.sorted().compactMap { draft.events.indices.contains($0) ? draft.events[$0] : nil }
        guard let first = picked.map(\.start).min() else { return }
        Self.clipboard = picked.map { var e = $0; e.start -= first; return e }
    }

    /// Paste after the selection (or at A, or at the start).
    private func paste() {
        guard !Self.clipboard.isEmpty else { return }
        let at = selected.compactMap { draft.events.indices.contains($0) ? draft.events[$0].start + draft.events[$0].length : nil }.max()
            ?? region?.lowerBound ?? 0
        commit { d in
            for e in Self.clipboard {
                var n = e
                n.start = at + e.start
                guard n.start < d.lengthBeats else { continue }
                n.length = min(n.length, d.lengthBeats - n.start)
                d.events.append(n)
            }
        }
        let count = Self.clipboard.count
        selected = Set((draft.events.count - count)..<draft.events.count)
        sortKeepingSelection()
    }

    private func deleteSelection() {
        guard !selected.isEmpty else { return }
        commit { d in d.events = d.events.enumerated().filter { !selected.contains($0.offset) }.map(\.element) }
        selected = []
    }

    private func setLength(_ beats: Double) {
        let length = max(LoopMath.beatsPerBar, min(128, beats))
        commit { d in
            d.lengthBeats = length
            d.events = LoopMath.trim(d.events, start: 0, end: length)
        }
        selected = []
        startBeat = min(startBeat, max(0, length - visibleBeats))
        if let r = region, r.upperBound > length { region = nil }
    }

    private func zoom(_ factor: Double) {
        let center = startBeat + visibleBeats / 2
        zoomX = min(32, max(1, zoomX * factor))
        startBeat = min(max(0, center - visibleBeats / 2), max(0, draft.lengthBeats - visibleBeats))
    }

    // MARK: Preview

    private func togglePreview() { previewing ? stopPreview() : startPreview() }

    private func startPreview() {
        var loop = draft
        if let r = region, abOn {
            loop.events = LoopMath.trim(draft.events, start: r.lowerBound, end: r.upperBound)
            loop.lengthBeats = r.upperBound - r.lowerBound
            playOffset = r.lowerBound
        } else {
            playOffset = 0
        }
        playLength = loop.lengthBeats
        loops.preview(loop)
        previewing = true
        syncDrums()
    }

    private func stopPreview() {
        guard previewing else { return }
        loops.stopPlayback()
        previewing = false
        if startedDrums { drums.stop(); startedDrums = false }
    }

    private func restartIfPlaying() { if previewing { startPreview() } }

    private func syncDrums() {
        if withDrums, !drums.playing {
            drums.play()
            startedDrums = true
        } else if !withDrums, startedDrums {
            drums.stop()
            startedDrums = false
        }
    }

    // MARK: Keyboard and scroll

    private func installMonitors() {
        removeMonitors()
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { handleKey(e) }
            return handled ? nil : event
        }
        let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { handleScroll(e) }
            return handled ? nil : event
        }
        monitors = [keys as Any, wheel as Any].compactMap { $0 }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.window?.firstResponder is NSText { return false }
        let cmd = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        let alt = event.modifierFlags.contains(.option)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        // ⌥ ← →: the finest nudge (1/96 of a beat), whatever the grid.
        case 123: moveSelection(beats: -(alt ? LoopMath.fine : (shift ? LoopMath.beatsPerBar : gridStepOrBeat))); return !selected.isEmpty
        case 124: moveSelection(beats: alt ? LoopMath.fine : (shift ? LoopMath.beatsPerBar : gridStepOrBeat)); return !selected.isEmpty
        case 126: if !selected.isEmpty { transposeSelection(shift ? 12 : 1); return true }; return false
        case 125: if !selected.isEmpty { transposeSelection(shift ? -12 : -1); return true }; return false
        case 51, 117: if !selected.isEmpty { deleteSelection(); return true }; return false
        case 49 where !cmd: togglePreview(); return true
        default: break
        }
        guard cmd else { return false }
        switch chars {
        case "z": shift ? redo() : undo(); return true
        case "c": copySelection(); return true
        case "v": paste(); return true
        case "a": selected = Set(draft.events.indices); return true
        case "d": copySelection(); paste(); return true
        default: return false
        }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        let p = window.convertPoint(toScreen: event.locationInWindow)
        // `rollFrame` is in SwiftUI global (window, top-left) coordinates.
        let inWindow = CGPoint(x: event.locationInWindow.x, y: window.contentLayoutRect.height - event.locationInWindow.y)
        _ = p
        guard rollFrame.insetBy(dx: 0, dy: -30).contains(inWindow) else { return false }
        let flags = event.modifierFlags
        if flags.contains(.command) {
            zoom(event.scrollingDeltaY > 0 ? 1.1 : 0.9)
        } else if flags.contains(.option) {
            rowHeight = min(32, max(8, rowHeight + (event.scrollingDeltaY > 0 ? 1 : -1)))
        } else {
            let dx = flags.contains(.shift) ? event.scrollingDeltaY : event.scrollingDeltaX
            let beatWidth = rollFrame.width / CGFloat(visibleBeats)
            startBeat = min(max(0, startBeat - Double(dx / max(1, beatWidth))), max(0, draft.lengthBeats - visibleBeats))
            if !flags.contains(.shift), abs(event.scrollingDeltaY) > 0.5 {
                let rows = Int((event.scrollingDeltaY / rowHeight * (event.hasPreciseScrollingDeltas ? 1 : 3)).rounded())
                topNote = min(127, max(12, topNote + rows))
            }
        }
        return true
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                selectionPanel
                fitPanel
                abPanel
                EffectsEditor(effects: Binding(get: { draft.effects ?? .none },
                                               set: { v in commit { $0.effects = v.isOff ? nil : v } }))
            }
            .padding(16)
        }
        .background(Theme.sidebar)
    }

    private func position(_ b: Double) -> String {
        let bar = Int(b / 4) + 1, beat = Int(b.truncatingRemainder(dividingBy: 4)) + 1
        let step = Int(((b - b.rounded(.down)) / 0.25).rounded(.down)) + 1
        return "\(bar) . \(beat) . \(step)"
    }

    @ViewBuilder
    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(selected.isEmpty ? tr("Selección") : tr("Selección · %d", selected.count))
            if selected.count == 1, let i = selected.first, draft.events.indices.contains(i) {
                let e = draft.events[i]
                row(tr("Empieza"), position(e.start),
                    down: { commit { $0.events[i].start = max(0, e.start - gridStepOrBeat) } },
                    up: { commit { $0.events[i].start = min($0.lengthBeats - e.length, e.start + gridStepOrBeat) } })
                HStack(spacing: 4) {
                    Text(tr("Fino")).font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 64, alignment: .leading)
                    IconButton(symbol: "chevron.left", label: tr("Un poco antes (⌥ ←)"), size: 22) {
                        commit { $0.events[i].start = max(0, e.start - LoopMath.fine) }
                    }
                    Text(String(format: "%.0f ms", e.start * 60 / Double(draft.bpm) * 1000)).monospacedText(size: 12).frame(minWidth: 70)
                    IconButton(symbol: "chevron.right", label: tr("Un poco después (⌥ →)"), size: 22) {
                        commit { $0.events[i].start = min($0.lengthBeats - e.length, e.start + LoopMath.fine) }
                    }
                }
                row(tr("Dura"), String(format: "%.3g", e.length),
                    down: { commit { $0.events[i].length = max(gridStep, e.length - gridStepOrBeat) } },
                    up: { commit { $0.events[i].length = min($0.lengthBeats - e.start, e.length + gridStepOrBeat) } })
                if let midi = e.midi {
                    row(tr("Nota"), Note.at(midi).rawValue + "\(midi / 12 - 1)",
                        down: { commit { $0.events[i].midi = max(0, midi - 1) } },
                        up: { commit { $0.events[i].midi = min(127, midi + 1) } })
                } else {
                    HStack(spacing: 4) {
                        ForEach(Music.degrees, id: \.self) { deg in
                            Button { commit { $0.events[i].degree = deg; $0.events[i].accidental = 0 } } label: {
                                Text(Music.numeral(deg, draft.flavor)).font(.system(size: 10, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 24)
                                    .foregroundStyle(e.degree == deg && e.accidental == 0 ? Theme.onAccent : Theme.text)
                                    .background(e.degree == deg && e.accidental == 0 ? Theme.accentFill : Theme.field,
                                                in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Text(tr("Fuerza")).font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 64, alignment: .leading)
                    Slider(value: Binding(get: { Double(draft.events[i].velocity) },
                                          set: { v in commit { $0.events[i].velocity = Int(v.rounded()) } }), in: 1...127)
                        .controlSize(.small)
                    Text("\(e.velocity)").monospacedText(size: 11).frame(width: 28)
                }
            }
            let chords = selected.filter { draft.events.indices.contains($0) && draft.events[$0].midi == nil }
            if !chords.isEmpty { chordTypeGrid(Set(chords)) }
            Text(tr("Recuadro para elegir varias (⇧ suma) · ⌥ al arrastrar copia · ⌘ al arrastrar ignora la rejilla · ← → un paso de rejilla (⇧ un compás, ⌥ ajuste fino) · ↑ ↓ un semitono (⇧ una octava) · ⌘C ⌘V ⌘D ⌘A · ⌫ borra · espacio escucha"))
                .font(.system(size: 10)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Chord type for the selected chords: tap one to change them all.
    private func chordTypeGrid(_ indices: Set<Int>) -> some View {
        let current = Set(indices.map { draft.events[$0].color })
        let types: [ChordColor] = [.diatonic, .major, .minor, .diminished, .augmented, .seventh, .minor7, .maj7, .sus2, .sus4, .add9]
        return VStack(alignment: .leading, spacing: 6) {
            Text(indices.count == 1 ? tr("Tipo de acorde") : tr("Tipo de los %d acordes", indices.count))
                .font(.system(size: 11)).foregroundStyle(Theme.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                ForEach(types, id: \.self) { c in
                    let on = current == [c]
                    Button { commit { d in for i in indices where d.events.indices.contains(i) { d.events[i].color = c } } } label: {
                        Text(c == .diatonic ? tr("Del tono") : c.name.replacingOccurrences(of: " (", with: "\n(")
                            .components(separatedBy: "\n")[0])
                            .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(on ? Theme.onAccent : Theme.text)
                            .background(on ? Theme.accentFill : Theme.field, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(c.name)
                }
            }
        }
    }

    private var fitPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(tr("Ajustar al tempo"))
            HStack {
                Text(tr("Intensidad")).font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 80, alignment: .leading)
                Slider(value: $strength, in: 0.1...1).controlSize(.small)
                Text("\(Int((strength * 100).rounded())) %").monospacedText(size: 11).frame(width: 40)
            }
            HStack {
                Text(tr("Swing")).font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 80, alignment: .leading)
                Slider(value: $swing, in: 0...0.6).controlSize(.small)
                Text("\(Int((swing * 100).rounded())) %").monospacedText(size: 11).frame(width: 40)
            }
            Toggle(tr("Ajustar también el final"), isOn: $quantizeEnds).toggleStyle(.checkbox).font(.system(size: 11))
            Button { fitToTempo() } label: {
                Text(selected.isEmpty ? tr("Ajustar todo el loop") : tr("Ajustar la selección")).frame(maxWidth: .infinity)
            }
            .buttonStyle(AppButtonStyle(kind: .primary, height: 30, fullWidth: true))
            Text(tr("Usa la rejilla elegida (con «Libre», semicorcheas). 100 % = exacto; menos deja un poco de tu forma de tocar."))
                .font(.system(size: 10)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
    }

    private var abPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(tr("Bucle A–B"))
            if let r = region {
                HStack { Text("A").font(.system(size: 12, weight: .bold)); Spacer(); Text(position(r.lowerBound)).monospacedText(size: 12) }
                HStack { Text("B").font(.system(size: 12, weight: .bold)); Spacer(); Text(position(r.upperBound)).monospacedText(size: 12) }
                HStack {
                    Button { selected = Set(draft.events.indices.filter { r.contains(draft.events[$0].start) }) } label: {
                        Text(tr("Seleccionar A–B")).fixedSize()
                    }
                    .buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
                    Button { region = nil; restartIfPlaying() } label: { Text(tr("Quitar")).fixedSize() }
                        .buttonStyle(AppButtonStyle(kind: .ghost, height: 26))
                }
            } else {
                Text(tr("Arrastra en la regla de compases para marcar A y B; ▶ repite solo esa parte."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, _ value: String, down: @escaping () -> Void, up: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 64, alignment: .leading)
            IconButton(symbol: "minus", label: title, size: 22, action: down)
            Text(value).monospacedText(size: 12).frame(minWidth: 70)
            IconButton(symbol: "plus", label: title, size: 22, action: up)
        }
    }
}
