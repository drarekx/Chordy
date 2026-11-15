import SwiftUI

/// Loops side panel: recorder, list, and the trim editor of one loop at a time.
struct LoopPanel: View {
    @ObservedObject var loops: Loops
    @State private var editingId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(tr("Loops"))
                Spacer()
                Text(tr("R grabar · P reproducir · Esc parar"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
            }
            RecorderBar(loops: loops)
            if loops.loops.isEmpty {
                Text(tr("Aún no hay loops. Pulsa R, toca unos acordes y vuelve a pulsar R para guardarlo."))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(loops.loops) { loop in
                            LoopRow(loops: loops, loop: loop, editing: editingId == loop.id) {
                                editingId = editingId == loop.id ? nil : loop.id
                            }
                            if editingId == loop.id {
                                LoopEditor(loops: loops, loop: loop) { editingId = nil }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Recorder

private struct RecorderBar: View {
    @ObservedObject var loops: Loops

    var body: some View {
        HStack(spacing: 10) {
            Button { loops.toggleRecord() } label: {
                HStack(spacing: 6) {
                    Image(systemName: loops.recorderState == .idle ? "record.circle" : "stop.circle.fill")
                    Text(label)
                }
            }
            .buttonStyle(AppButtonStyle(kind: loops.recorderState == .idle ? .secondary : .primary))
            .help(tr("Grabar loop (R)"))
            Text(status).monospacedText(size: 12)
                .foregroundStyle(loops.recorderState == .recording ? Theme.danger : Theme.text3)
            Spacer()
            Toggle(tr("Clic"), isOn: $loops.metronome)
                .toggleStyle(.checkbox)
                .help(tr("Metrónomo mientras grabas"))
        }
    }

    private var label: String {
        switch loops.recorderState {
        case .idle: return tr("Grabar")
        case .armed: return tr("Cancelar")
        case .recording: return tr("Guardar")
        }
    }

    private var status: String {
        switch loops.recorderState {
        case .idle: return tr("R para grabar")
        case .armed: return tr("toca un acorde…")
        case .recording:
            let beat = Int(loops.elapsedBeats)
            return "● \(beat / 4 + 1) · \(beat % 4 + 1)"
        }
    }
}

// MARK: - Row

private struct LoopRow: View {
    @ObservedObject var loops: Loops
    let loop: Loop
    let editing: Bool
    let toggleEditor: () -> Void
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let playing = loops.playingId == loop.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: playing ? "stop.fill" : "play.fill",
                           label: playing ? tr("Parar") : tr("Reproducir"),
                           kind: playing ? .primary : .secondary) { loops.togglePlay(loop.id) }
                VStack(alignment: .leading, spacing: 1) {
                    if renaming {
                        TextField("", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .onSubmit { loops.rename(loop.id, to: name); renaming = false }
                            .onExitCommand { renaming = false }
                    } else {
                        Text(loop.name).font(.system(size: 13, weight: .semibold))
                            .onTapGesture(count: 2) { name = loop.name; renaming = true }
                            .help(tr("Doble clic para renombrar"))
                    }
                    Text("\(LoopMath.formatLength(loop.lengthBeats)) · \(loop.tonic.rawValue) \(loop.flavor.label) · \(loop.bpm) bpm")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                IconButton(symbol: "scissors", label: tr("Recortar"), kind: editing ? .primary : .ghost, action: toggleEditor)
                IconButton(symbol: "trash", label: tr("Borrar")) { loops.remove(loop.id) }
            }
            LoopPreview(events: loop.events, length: loop.lengthBeats, progress: playing ? loops.progress : nil)
                .frame(height: 36)
        }
        .padding(10)
        .background(loops.selectedId == loop.id ? Theme.navSelected : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
    }
}

/// Mini piano roll of a loop with an optional playhead.
struct LoopPreview: View {
    let events: [LoopEvent]
    let length: Double
    let progress: Double?

    var body: some View {
        Canvas { context, size in
            let rowHeight = size.height / 7
            for bar in 1..<Int(max(1, length / LoopMath.beatsPerBar)) {
                let x = size.width * CGFloat(Double(bar) * LoopMath.beatsPerBar / length)
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Theme.line))
            }
            for e in events {
                let rect = CGRect(x: size.width * e.start / length, y: CGFloat(7 - e.degree) * rowHeight + 0.5,
                                  width: max(2, size.width * e.length / length - 1), height: rowHeight - 1)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Theme.accentFill))
            }
            if let progress {
                let x = size.width * progress
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.text))
            }
        }
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Trim editor

private struct LoopEditor: View {
    @ObservedObject var loops: Loops
    let loop: Loop
    let close: () -> Void

    @State private var snap = 1.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var offset = 0.0

    /// Room to extend the loop with up to one bar of silence.
    private var total: Double { loop.lengthBeats + LoopMath.beatsPerBar }
    private var length: Double { end - start }
    private var draftEvents: [LoopEvent] {
        LoopMath.rotate(LoopMath.trim(loop.events, start: start, end: end), length: length, offset: offset)
    }
    private var draft: Loop {
        var d = loop
        d.lengthBeats = length
        d.events = draftEvents
        return d
    }
    private var changed: Bool {
        start != 0 || end != loop.lengthBeats || offset.truncatingRemainder(dividingBy: length) != 0
    }
    private var previewing: Bool { loops.playingId == loop.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(tr("Recortar"))
                Spacer()
                SegmentedControl(options: [(tr("Compás"), 4.0), (tr("Tiempo"), 1.0), ("1/16", 0.25)], selection: $snap)
            }
            TrimTimeline(events: loop.events, total: total, snap: snap, start: $start, end: $end)
                .frame(height: 70)
            HStack(spacing: 6) {
                SectionLabel(tr("Desplazar"))
                Spacer()
                IconButton(symbol: "arrowtriangle.left.fill", label: tr("Acordes antes"), kind: .secondary) { shift(-1) }
                Text(tr("%@ tiempos", signed)).monospacedText(size: 11).frame(minWidth: 70)
                IconButton(symbol: "arrowtriangle.right.fill", label: tr("Acordes después"), kind: .secondary) { shift(1) }
                Button(tr("1.er acorde → 1")) { alignFirstChord() }.buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
            }
            HStack {
                SectionLabel(tr("Resultado"))
                Spacer()
                Text(LoopMath.formatLength(length)).monospacedText(size: 11)
            }
            LoopPreview(events: draftEvents, length: length, progress: previewing ? loops.progress : nil)
                .frame(height: 36)
            HStack(spacing: 6) {
                Button(previewing ? tr("■ Parar") : tr("▶ Escuchar")) {
                    previewing ? loops.stopPlayback() : loops.preview(draft)
                }
                .buttonStyle(.appSecondary)
                Button(tr("Restablecer")) { start = 0; end = loop.lengthBeats; offset = 0 }
                    .buttonStyle(.appGhost).disabled(!changed)
                Spacer()
                Button(tr("Cancelar")) { if previewing { loops.stopPlayback() }; close() }.buttonStyle(.appGhost)
                Button(tr("Aplicar")) {
                    loops.update(loop.id, length: length, events: draftEvents)
                    close()
                }
                .buttonStyle(.appPrimary).disabled(!changed)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accentBorder) }
        .onAppear { end = loop.lengthBeats }
        // While auditioning, restart playback whenever the edit changes.
        .onChange(of: draftEvents) { _, _ in if previewing { loops.preview(draft) } }
        .onChange(of: length) { _, _ in if previewing { loops.preview(draft) } }
    }

    private var signed: String {
        let v = (offset * 100).rounded() / 100
        if v == 0 { return "0" }
        return (v > 0 ? "+" : "") + v.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func shift(_ direction: Double) {
        offset = (offset + direction * snap).truncatingRemainder(dividingBy: length)
    }

    /// Rotate so the first chord lands on beat 1.
    private func alignFirstChord() {
        if let first = LoopMath.trim(loop.events, start: start, end: end).first { offset = -first.start }
    }
}

/// Loop chords with two draggable handles marking the part to keep.
private struct TrimTimeline: View {
    let events: [LoopEvent]
    let total: Double
    let snap: Double
    @Binding var start: Double
    @Binding var end: Double
    @State private var dragging: Handle?

    private enum Handle { case start, end }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x = { (beat: Double) in w * CGFloat(beat / total) }
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for beat in 1..<Int(total) {
                        let bar = Double(beat).truncatingRemainder(dividingBy: LoopMath.beatsPerBar) == 0
                        context.fill(Path(CGRect(x: x(Double(beat)), y: 0, width: 1, height: size.height)),
                                     with: .color(bar ? Theme.lineStrong : Theme.line))
                    }
                    let rowHeight = size.height / 7
                    for e in events {
                        let rect = CGRect(x: x(e.start), y: CGFloat(7 - e.degree) * rowHeight + rowHeight * 0.12,
                                          width: max(1, x(e.length) - 1), height: rowHeight * 0.76)
                        context.fill(Path(rect), with: .color(Theme.accentFill))
                    }
                    // Dim what gets cut.
                    context.fill(Path(CGRect(x: 0, y: 0, width: x(start), height: size.height)), with: .color(Theme.window.opacity(0.7)))
                    context.fill(Path(CGRect(x: x(end), y: 0, width: size.width - x(end), height: size.height)), with: .color(Theme.window.opacity(0.7)))
                }
                handle(at: x(start), height: h)
                handle(at: x(end), height: h)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let beat = ((Double(value.location.x / w) * total) / snap).rounded() * snap
                        if dragging == nil {
                            // Grab the nearest handle.
                            dragging = abs(value.startLocation.x - x(start)) <= abs(value.startLocation.x - x(end)) ? .start : .end
                        }
                        // Keep at least one grid step between the handles.
                        if dragging == .start { start = min(max(0, beat), end - snap) }
                        else { end = max(min(total, beat), start + snap) }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(tr("Recorte del loop"))
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(Theme.accent).frame(width: 3, height: height).offset(x: x - 1.5)
    }
}
