import SwiftUI

/// The synth full size: your sounds and the factory ones, the whole editor in two columns, a
/// keyboard to try the sound with the mouse, and which keyboards use it.
struct SynthStudio: View {
    @ObservedObject var sounds: SoundLibrary
    @ObservedObject var keyboards: Keyboards
    let engine: ChordEngine
    @State private var renaming: String?
    @State private var name = ""
    @State private var confirmingDelete = false

    private var selected: Patch { sounds.selected }
    private var route: String { InstrumentLibrary.synth(sounds.selectedId) }
    private var users: [KeyboardConfig] { keyboards.configs.filter { $0.instrument == route } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            library.frame(width: 250)
            VStack(spacing: 14) {
                topBar
                HStack(alignment: .top, spacing: 14) {
                    ScrollView { SynthSourceEditor(sounds: sounds).padding(16) }
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line) }
                    ScrollView { SynthShapeEditor(sounds: sounds).padding(16) }
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line) }
                }
                .frame(maxHeight: .infinity)
                TryKeyboard(engine: engine, route: route).frame(height: 96)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { sounds.newSound() } label: { Label(tr("Nuevo"), systemImage: "plus").fixedSize() }
                    .buttonStyle(AppButtonStyle(kind: .primary, height: 28))
                Button { sounds.duplicate(sounds.selectedId) } label: {
                    Label(tr("Duplicar"), systemImage: "plus.square.on.square").fixedSize()
                }
                .buttonStyle(AppButtonStyle(kind: .secondary, height: 28))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !sounds.userPatches.isEmpty {
                        header(tr("Tus sonidos"))
                        ForEach(sounds.userPatches) { row($0) }
                    }
                    header(tr("De fábrica"))
                    ForEach(Patch.builtins) { row($0) }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line) }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3).padding(.top, 6)
    }

    private func row(_ patch: Patch) -> some View {
        let on = patch.id == sounds.selectedId
        let used = keyboards.configs.filter { $0.instrument == InstrumentLibrary.synth(patch.id) }
        return Group {
            if renaming == patch.id {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { sounds.rename(patch.id, to: name); renaming = nil }
                    .onExitCommand { renaming = nil }
            } else {
                Button { if !on { sounds.select(patch.id) } } label: {
                    HStack(spacing: 6) {
                        Text(patch.name).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                        if on && sounds.dirty { Circle().fill(Theme.warn).frame(width: 6, height: 6) }
                        Spacer(minLength: 4)
                        ForEach(used) { c in Circle().fill(c.tint).frame(width: 7, height: 7).help(c.name) }
                    }
                    .foregroundStyle(on ? Theme.onAccent : Theme.text)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(on ? Theme.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !patch.isBuiltin {
                        Button(tr("Renombrar")) { name = patch.name; renaming = patch.id }
                    }
                    Button(tr("Duplicar")) { sounds.duplicate(patch.id) }
                    if !patch.isBuiltin {
                        Button(tr("Borrar"), role: .destructive) { remove(patch.id) }
                    }
                }
            }
        }
    }

    private func remove(_ id: String) {
        // Keyboards that used it go back to the sound being edited.
        for c in keyboards.configs where c.instrument == InstrumentLibrary.synth(id) {
            keyboards.update(c.id) { $0.instrument = InstrumentLibrary.synthId }
        }
        sounds.remove(id)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            if selected.isBuiltin {
                Text(selected.name).font(.system(size: 20, weight: .bold))
                Text(tr("de fábrica")).font(.system(size: 11)).foregroundStyle(Theme.text3)
            } else {
                TextField("", text: Binding(get: { sounds.draft.name }, set: { sounds.draft.name = String($0.prefix(40)) }))
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .bold)).frame(maxWidth: 320)
            }
            if sounds.dirty {
                Text(tr("editado")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warn)
            }
            Spacer()
            if !users.isEmpty {
                Text(tr("Lo usan: %@", users.map(\.name).joined(separator: ", ")))
                    .font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Menu {
                ForEach(keyboards.configs) { c in
                    Button(c.name) { assign(to: c.id) }
                }
            } label: { Label(tr("Usar en un teclado"), systemImage: "pianokeys").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.radius))
                .disabled(keyboards.configs.isEmpty)
            Button { sounds.revert() } label: { Text(tr("Deshacer cambios")).fixedSize() }
                .buttonStyle(.appGhost).disabled(!sounds.dirty)
            Button { save() } label: { Text(selected.isBuiltin ? tr("Guardar como sonido nuevo") : tr("Guardar")).fixedSize() }
                .buttonStyle(.appPrimary).disabled(!sounds.dirty)
        }
    }

    /// A factory sound can't change: saving makes your own copy (and keyboards that used the
    /// factory one follow the copy).
    private func save() {
        let before = route
        sounds.save(as: selected.isBuiltin ? sounds.draft.name : nil)
        let after = route
        if before != after {
            for c in keyboards.configs where c.instrument == before { keyboards.update(c.id) { $0.instrument = after } }
        }
    }

    private func assign(to keyboard: String) {
        if selected.isBuiltin && sounds.dirty { save() }
        keyboards.setSound(route, for: keyboard)
    }
}

/// Three octaves to try the sound with the mouse (drag across keys to glide).
private struct TryKeyboard: View {
    let engine: ChordEngine
    let route: String
    @State private var playing: (midi: Int, voice: Int)?
    private let low = 48, high = 84
    private static let black: Set<Int> = [1, 3, 6, 8, 10]

    var body: some View {
        GeometryReader { geo in
            let whites = (low...high).filter { !Self.black.contains($0 % 12) }
            let w = geo.size.width / CGFloat(whites.count)
            Canvas { context, size in
                for (i, n) in whites.enumerated() {
                    let r = CGRect(x: CGFloat(i) * w + 0.5, y: 0, width: w - 1, height: size.height)
                    context.fill(Path(roundedRect: r, cornerRadius: 4),
                                 with: .color(playing?.midi == n ? Theme.accentFill : Theme.text.opacity(0.88)))
                    if n % 12 == 0 {
                        context.draw(Text("C\(n / 12 - 1)").font(.system(size: 9)).foregroundColor(Theme.window.opacity(0.6)),
                                     at: CGPoint(x: r.midX, y: size.height - 9))
                    }
                }
                for (i, n) in whites.enumerated() where n + 1 <= high && Self.black.contains((n + 1) % 12) {
                    let r = CGRect(x: CGFloat(i + 1) * w - w * 0.3, y: 0, width: w * 0.6, height: size.height * 0.6)
                    context.fill(Path(roundedRect: r, cornerRadius: 3),
                                 with: .color(playing?.midi == n + 1 ? Theme.accentFill : Theme.window))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let n = key(at: g.location, size: geo.size, whites: whites, w: w)
                        guard n != playing?.midi else { return }
                        stop()
                        if let n { play(n) }
                    }
                    .onEnded { _ in stop() }
            )
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(tr("Teclado para probar el sonido"))
    }

    private func key(at p: CGPoint, size: CGSize, whites: [Int], w: CGFloat) -> Int? {
        guard p.x >= 0, p.x < size.width, p.y >= 0, p.y <= size.height else { return nil }
        let i = min(whites.count - 1, max(0, Int(p.x / w)))
        if p.y < size.height * 0.6 {
            let local = p.x - CGFloat(i) * w
            if local > w * 0.7, whites[i] + 1 <= high, Self.black.contains((whites[i] + 1) % 12) { return whites[i] + 1 }
            if local < w * 0.3, i > 0, Self.black.contains((whites[i] - 1) % 12) { return whites[i] - 1 }
        }
        return whites[i]
    }

    private func play(_ midi: Int) {
        Synth.shared.start()
        playing = (midi, engine.output.noteOn(midi: midi, velocity: 100, instrument: route))
    }

    private func stop() {
        if let p = playing { engine.output.noteOff(p.voice, pedal: false) }
        playing = nil
    }
}
