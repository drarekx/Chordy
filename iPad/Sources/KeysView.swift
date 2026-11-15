import SwiftUI

/// The Mac's MIDI keyboards side by side: each one drawn with the keys you press, its eight
/// quick sounds, every sound in a list, its volume and its effects.
struct KeysView: View {
    @ObservedObject var client: RemoteClient
    let state: RemoteState
    @State private var picking: RemoteKeyboard?

    var body: some View {
        let boards = state.keyboards ?? []
        if boards.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "pianokeys").font(.system(size: 40)).foregroundStyle(Pal.text3)
                Text(state.keyboards == nil ? "Actualiza Chordy en el Mac para ver los teclados." : "Conecta un teclado MIDI al Mac.")
                    .font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(boards) { kb in
                        KeyboardPanel(client: client, keyboard: kb, favorites: state.favorites ?? [],
                                      sounds: state.sounds ?? []) { picking = kb }
                    }
                }
            }
            .sheet(item: $picking) { kb in
                SoundPicker(keyboard: kb, sounds: state.sounds ?? []) { id in
                    client.send(.setSound(keyboard: kb.id, sound: id))
                    picking = nil
                }
            }
        }
    }
}

private struct KeyboardPanel: View {
    @ObservedObject var client: RemoteClient
    let keyboard: RemoteKeyboard
    let favorites: [String]
    let sounds: [RemoteSound]
    let showAll: () -> Void

    private var tint: Color { Pal.keyboards[keyboard.color % Pal.keyboards.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Keybed(live: client.live, keyboard: keyboard, tint: tint).frame(height: 92)
            favoritesGrid
            effects
        }
        .padding(16)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16).fill(tint).frame(height: 4)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(keyboard.name).font(.system(size: 18, weight: .bold)).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(keyboard.connected ? Pal.ok : Pal.text3).frame(width: 6, height: 6)
                    Text(keyboard.connected ? "Conectado" : "Desconectado").font(.system(size: 11)).foregroundStyle(Pal.text3)
                }
            }
            Spacer()
            Button(action: showAll) {
                HStack(spacing: 6) {
                    Text(keyboard.soundName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 14).frame(height: 40)
                .foregroundStyle(Pal.text)
                .background(Pal.field, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.6)) }
            }
            .buttonStyle(.plain)
        }
    }

    private var favoritesGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(Array(favorites.enumerated()), id: \.offset) { slot, id in
                let on = id == keyboard.sound
                Button { client.send(.setSound(keyboard: keyboard.id, sound: id)) } label: {
                    VStack(spacing: 2) {
                        Text("\(slot + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(on ? Pal.window.opacity(0.7) : Pal.text3)
                        Text(name(id)).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .padding(.horizontal, 4)
                    .foregroundStyle(on ? Pal.window : Pal.text)
                    .background(on ? tint : Pal.field, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func name(_ id: String) -> String { sounds.first { $0.id == id }?.name ?? id }

    // MARK: Effects

    private var effects: some View {
        let e = keyboard.effects
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VOLUMEN Y EFECTOS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text2).tracking(0.6)
                Spacer()
                Button("Quitar efectos") {
                    send(RemoteEffects(reverb: 0, delay: 0, delayTime: 0.375, feedback: 0.35, filter: 1))
                }
                .font(.system(size: 13, weight: .semibold))
                .disabled(e.reverb == 0 && e.delay == 0 && e.filter >= 0.999)
            }
            row("Volumen", "\(Int((keyboard.volume * 100).rounded()))") {
                RemoteSlider(value: keyboard.volume, range: 0...1, tint: tint) {
                    client.send(.setFader(id: "kb:\(keyboard.id)", value: $0))
                }
            }
            row("Reverb", percent(e.reverb)) {
                RemoteSlider(value: e.reverb, range: 0...1, tint: tint) { v in send(change(e) { $0.reverb = v }) }
            }
            row("Eco", percent(e.delay)) {
                RemoteSlider(value: e.delay, range: 0...1, tint: tint) { v in send(change(e) { $0.delay = v }) }
            }
            row("Tiempo eco", String(format: "%.2f s", e.delayTime)) {
                RemoteSlider(value: e.delayTime, range: 0.05...1.5, tint: tint) { v in send(change(e) { $0.delayTime = v }) }
            }
            row("Repeticiones", percent(e.feedback)) {
                RemoteSlider(value: e.feedback, range: 0...0.9, tint: tint) { v in send(change(e) { $0.feedback = v }) }
            }
            row("Filtro", e.filter >= 0.999 ? "abierto" : hz(200 * pow(100, e.filter))) {
                RemoteSlider(value: e.filter, range: 0...1, tint: tint) { v in send(change(e) { $0.filter = v }) }
            }
        }
    }

    private func row<Content: View>(_ title: String, _ value: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14)).frame(width: 104, alignment: .leading)
            content()
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(Pal.text2).frame(width: 64, alignment: .trailing)
        }
    }

    private func change(_ e: RemoteEffects, _ body: (inout RemoteEffects) -> Void) -> RemoteEffects {
        var copy = e
        body(&copy)
        return copy
    }

    private func send(_ e: RemoteEffects) { client.send(.setEffects(keyboard: keyboard.id, effects: e)) }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
    private func hz(_ v: Double) -> String { v >= 1000 ? String(format: "%.1f kHz", v / 1000) : "\(Int(v)) Hz" }
}

/// The keyboard's keys; the ones held on the Mac light up in the keyboard's color.
private struct Keybed: View {
    @ObservedObject var live: LiveKeys
    let keyboard: RemoteKeyboard
    let tint: Color
    private static let black: Set<Int> = [1, 3, 6, 8, 10]

    var body: some View {
        let held = live.notes[keyboard.device] ?? []
        let low = keyboard.firstKey, high = keyboard.firstKey + keyboard.keyCount - 1
        Canvas { context, size in
            let whites = (low...max(low, high)).filter { !Self.black.contains($0 % 12) }
            guard !whites.isEmpty else { return }
            let w = size.width / CGFloat(whites.count)
            for (i, n) in whites.enumerated() {
                let r = CGRect(x: CGFloat(i) * w + 0.5, y: 0, width: w - 1, height: size.height)
                context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(held.contains(n) ? tint : Pal.text.opacity(0.9)))
                if n % 12 == 0, w > 9 {
                    context.draw(Text("C\(n / 12 - 1)").font(.system(size: 9)).foregroundColor(Pal.window.opacity(0.55)),
                                 at: CGPoint(x: r.midX, y: size.height - 9))
                }
            }
            for (i, n) in whites.enumerated() where n + 1 <= high && Self.black.contains((n + 1) % 12) {
                let r = CGRect(x: CGFloat(i + 1) * w - w * 0.32, y: 0, width: w * 0.64, height: size.height * 0.6)
                context.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(held.contains(n + 1) ? tint : Pal.window))
            }
        }
        .background(Pal.window, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Every sound, grouped; tap one to give it to the keyboard.
private struct SoundPicker: View {
    let keyboard: RemoteKeyboard
    let sounds: [RemoteSound]
    let pick: (String) -> Void
    @State private var search = ""

    private var groups: [String] {
        var seen: [String] = []
        for s in sounds where !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.self) { group in
                    let items = sounds.filter { $0.group == group && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                    if !items.isEmpty {
                        Section(group) {
                            ForEach(items) { s in
                                Button { pick(s.id) } label: {
                                    HStack {
                                        Text(s.name).foregroundStyle(Pal.text)
                                        Spacer()
                                        if let mb = s.download {
                                            Text("↓ \(mb) MB").font(.system(size: 12)).foregroundStyle(Pal.text3)
                                        }
                                        if s.id == keyboard.sound {
                                            Image(systemName: "checkmark").foregroundStyle(Pal.accent)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Buscar sonido")
            .navigationTitle("Sonido de \(keyboard.name)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
