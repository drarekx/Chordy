import SwiftUI

/// The pattern grid on the iPad: tap a step, drag up/down on it for velocity; lanes with
/// mute/solo; tools for the chosen lane; the chain.
struct StepsView: View {
    @ObservedObject var client: RemoteClient
    let state: RemoteState

    private var pattern: RemotePattern { state.patterns[state.selected] }

    var body: some View {
        VStack(spacing: 12) {
            PatternBar(client: client, state: state, launches: false)
            VStack(spacing: 6) {
                ForEach(0..<8, id: \.self) { lane in row(lane) }
            }
            .frame(maxHeight: .infinity)
            tools
            chain
        }
    }

    private func row(_ lane: Int) -> some View {
        let selected = state.track == lane
        let muted = state.muted.contains(lane)
        let soloed = state.solo == lane
        return HStack(spacing: 8) {
            Button {
                client.send(.selectTrack(track: lane))
                client.hit(track: lane, velocity: 100)
            } label: {
                Text(state.laneShorts[safe: lane] ?? "").font(.system(size: 14, weight: .bold, design: .monospaced))
                    .frame(width: 52, height: 44)
                    .foregroundStyle(selected || client.flash.contains(lane) ? Pal.window : Pal.text)
                    .background(client.flash.contains(lane) ? Pal.text : (selected ? Pal.warn : Pal.control),
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            small("M", on: muted) { client.send(.toggleMute(track: lane)) }
            small("S", on: soloed) { client.send(.toggleSolo(track: lane)) }
            HStack(spacing: 4) {
                ForEach(0..<16, id: \.self) { step in
                    StepPad(velocity: pattern.steps[safe: lane]?[safe: step] ?? 0,
                            current: state.playing && client.step == step && client.playingPattern == state.selected,
                            beat: step % 4 == 0, silent: muted || (state.solo != nil && !soloed)) { action in
                        switch action {
                        case .toggle: client.send(.toggleStep(track: lane, step: step, accent: false))
                        case .velocity(let v): client.send(.setVelocity(track: lane, step: step, velocity: v))
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func small(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 36)
                .foregroundStyle(on ? Pal.window : Pal.text2)
                .background(on ? Pal.warn : Pal.field, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var tools: some View {
        let lane = state.track
        let note = pattern.laneNotes[safe: lane] ?? 0
        return HStack(spacing: 8) {
            Text(state.laneNames[safe: lane] ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.warn)
            Menu {
                ForEach(state.variants[safe: lane] ?? [], id: \.note) { v in
                    Button(v.name) { client.send(.setLaneNote(track: lane, note: v.note)) }
                }
            } label: {
                Text((state.variants[safe: lane] ?? []).first { $0.note == note }?.name ?? "\(note)")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(Pal.field, in: RoundedRectangle(cornerRadius: 8))
            }
            tool("Cada paso") { client.send(.fill(track: lane, every: 1, offset: 0)) }
            tool("Cada 2") { client.send(.fill(track: lane, every: 2, offset: 0)) }
            tool("Cada 4") { client.send(.fill(track: lane, every: 4, offset: 0)) }
            tool("Contra") { client.send(.fill(track: lane, every: 4, offset: 2)) }
            tool("←") { client.send(.shift(track: lane, delta: -1)) }
            tool("→") { client.send(.shift(track: lane, delta: 1)) }
            tool("Aleatorio") { client.send(.randomize(track: lane)) }
            tool("Vaciar pista") { client.send(.clearLane(track: lane)) }
            Spacer(minLength: 4)
            Menu {
                ForEach(0..<8, id: \.self) { i in
                    if i != state.selected { Button("Copiar en \(["A", "B", "C", "D", "E", "F", "G", "H"][i])") { client.send(.copyPattern(to: i)) } }
                }
                Button("Vaciar patrón", role: .destructive) { client.send(.clearPattern) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 22)).frame(width: 44, height: 36)
            }
        }
    }

    private func tool(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 36)
                .background(Pal.control, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var chain: some View {
        HStack(spacing: 8) {
            Text("CADENA").font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(state.chain.enumerated()), id: \.offset) { position, index in
                        let current = state.chainOn && state.playing && client.chainPosition == position
                        Button { client.send(.chainRemove(position: position)) } label: {
                            Text(["A", "B", "C", "D", "E", "F", "G", "H"][index]).font(.system(size: 16, weight: .bold))
                                .frame(width: 40, height: 40)
                                .foregroundStyle(current ? Pal.onAccent : Pal.text)
                                .background(current ? Pal.accent : Pal.control, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    Menu {
                        ForEach(0..<8, id: \.self) { i in
                            Button(["A", "B", "C", "D", "E", "F", "G", "H"][i] + (state.patterns[i].title.map { " · \($0)" } ?? "")) {
                                client.send(.chainAppend(pattern: i))
                            }
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 40, height: 40)
                            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Pal.line, style: StrokeStyle(lineWidth: 1, dash: [4])) }
                    }
                }
            }
            Toggle("Cadena", isOn: Binding(get: { state.chainOn }, set: { client.send(.setChainOn($0)) }))
                .toggleStyle(.switch).fixedSize().disabled(state.chain.isEmpty)
            Button("Vaciar") { client.send(.chainClear) }.disabled(state.chain.isEmpty)
        }
        .padding(10)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// One step: tap toggles, vertical drag sets the velocity (shown as a bar).
struct StepPad: View {
    enum Action { case toggle, velocity(Int) }

    let velocity: Int
    let current: Bool
    let beat: Bool
    let silent: Bool
    let action: (Action) -> Void
    @State private var start: Int?
    @State private var shown: Int?

    var body: some View {
        GeometryReader { geo in
            let v = shown ?? velocity
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7).fill(current ? Pal.line : (beat ? Pal.control : Pal.field))
                if v > 0 {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(current ? Pal.text : (silent ? Pal.text3 : Pal.accent))
                        .opacity(0.55 + 0.45 * Double(v) / 127)
                        .frame(height: max(6, geo.size.height * CGFloat(v) / 127))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.height) > 6 else { return }
                        if start == nil { start = velocity > 0 ? velocity : 100 }
                        let new = max(1, min(127, (start ?? 100) - Int(value.translation.height / max(1, geo.size.height) * 127)))
                        shown = new
                        action(.velocity(new))
                    }
                    .onEnded { value in
                        if start == nil && abs(value.translation.height) <= 6 { action(.toggle) }
                        start = nil
                        shown = nil
                    }
            )
        }
    }
}
