import SwiftUI

/// Big vertical faders: drums, every keyboard and loops; then each drum lane with mute and
/// solo; kit, swing and tempo.
struct MixView: View {
    @ObservedObject var client: RemoteClient
    let state: RemoteState

    private var pattern: RemotePattern { state.patterns[state.selected] }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                section("GENERAL") {
                    HStack(spacing: 18) {
                        ForEach(state.faders) { f in
                            VFader(name: f.name, value: f.value,
                                   tint: f.color.map { Pal.keyboards[$0 % Pal.keyboards.count] } ?? Pal.accent) {
                                client.send(.setFader(id: f.id, value: $0))
                            }
                        }
                    }
                }
                section("BATERÍA · PATRÓN \(["A", "B", "C", "D", "E", "F", "G", "H"][state.selected])") {
                    HStack(spacing: 12) {
                        ForEach(0..<8, id: \.self) { lane in
                            VStack(spacing: 8) {
                                VFader(name: state.laneShorts[safe: lane] ?? "", value: pattern.laneVolumes[safe: lane] ?? 0.85,
                                       tint: state.muted.contains(lane) ? Pal.text3 : Pal.accent) {
                                    client.send(.setLaneVolume(track: lane, value: $0))
                                }
                                HStack(spacing: 4) {
                                    toggle("M", on: state.muted.contains(lane)) { client.send(.toggleMute(track: lane)) }
                                    toggle("S", on: state.solo == lane) { client.send(.toggleSolo(track: lane)) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                section("KIT") {
                    Menu {
                        ForEach(state.kits) { kit in Button(kit.name) { client.send(.setKit(kit.id)) } }
                    } label: {
                        Text(state.kits.first { $0.id == pattern.kit }?.name ?? "Kit").font(.system(size: 16, weight: .semibold))
                    }
                }
                section("SWING") {
                    RemoteSlider(value: pattern.swing, range: 0...0.5) { client.send(.setSwing($0)) }
                }
                section("TEMPO") {
                    HStack {
                        Button { client.send(.setBpm(state.bpm - 5)) } label: { Text("−5").frame(width: 50, height: 40) }
                        Button { client.send(.setBpm(state.bpm - 1)) } label: { Text("−1").frame(width: 50, height: 40) }
                        Text("\(state.bpm)").font(.system(size: 24, weight: .bold, design: .monospaced)).frame(minWidth: 60)
                        Button { client.send(.setBpm(state.bpm + 1)) } label: { Text("+1").frame(width: 50, height: 40) }
                        Button { client.send(.setBpm(state.bpm + 5)) } label: { Text("+5").frame(width: 50, height: 40) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text2).tracking(0.6)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func toggle(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 32)
                .foregroundStyle(on ? Pal.window : Pal.text2)
                .background(on ? Pal.warn : Pal.field, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

/// A tall fader you drag up and down; shows the level and its name.
struct VFader: View {
    let name: String
    let value: Double
    let tint: Color
    let send: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: 8) {
            Text("\(Int(((dragging ?? value) * 100).rounded()))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text2)
            GeometryReader { geo in
                let v = dragging ?? value
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 10).fill(Pal.field)
                    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.85))
                        .frame(height: max(4, geo.size.height * CGFloat(v)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let new = min(1, max(0, 1 - Double(g.location.y / max(1, geo.size.height))))
                            dragging = new
                            send(new)
                        }
                        .onEnded { _ in dragging = nil }
                )
            }
            .frame(width: 54)
            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 70)
        }
        .frame(minHeight: 200)
    }
}
