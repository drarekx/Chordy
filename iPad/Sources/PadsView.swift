import SwiftUI

/// 16 big pads (top: the eight lanes, bottom: other kit sounds) to play live, with kit,
/// swing, a quick mix and the Mac's loop transport beside them.
struct PadsView: View {
    @ObservedObject var client: RemoteClient
    let state: RemoteState

    /// Extra GM drum sounds on the bottom row.
    static let extras: [(note: Int, short: String, name: String)] = [
        (35, "BD2", "Bombo 2"), (37, "RIM", "Aro"), (54, "TB", "Pandereta"), (56, "CB", "Cencerro"),
        (51, "RD", "Ride"), (48, "MT", "Tom medio"), (55, "SP", "Splash"), (52, "CN", "China"),
    ]

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 12) {
                PatternBar(client: client, state: state, launches: true)
                GeometryReader { geo in
                    let gap: CGFloat = 12
                    let size = min((geo.size.width - gap * 3) / 4, (geo.size.height - gap * 3) / 4)
                    VStack(spacing: gap) {
                        ForEach(0..<4, id: \.self) { row in
                            HStack(spacing: gap) {
                                ForEach(0..<4, id: \.self) { col in
                                    pad(row * 4 + col).frame(width: size, height: size)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            side.frame(width: 270)
        }
    }

    @ViewBuilder
    private func pad(_ index: Int) -> some View {
        if index < 8 {
            Pad(short: state.laneShorts[safe: index] ?? "", name: state.laneNames[safe: index] ?? "",
                fill: Pal.drum, lit: client.flash.contains(index)) { velocity in
                client.hit(track: index, velocity: velocity)
            }
        } else {
            let extra = Self.extras[index - 8]
            Pad(short: extra.short, name: extra.name, fill: Pal.accentSoft, lit: false) { velocity in
                client.send(.hitNote(note: extra.note, velocity: velocity))
            }
        }
    }

    private var side: some View {
        let pattern = state.patterns[state.selected]
        return VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                label("KIT")
                Menu {
                    ForEach(state.kits) { kit in Button(kit.name) { client.send(.setKit(kit.id)) } }
                } label: {
                    Text(state.kits.first { $0.id == pattern.kit }?.name ?? "Kit").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Pal.accent)
                }
                label("SWING")
                RemoteSlider(value: pattern.swing, range: 0...0.5) { client.send(.setSwing($0)) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                label("MEZCLA RÁPIDA")
                ForEach(state.faders) { fader in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(fader.name).font(.system(size: 13))
                            Spacer()
                            Text("\(Int((fader.value * 100).rounded())) %").font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Pal.text2)
                        }
                        RemoteSlider(value: fader.value, range: 0...1,
                                     tint: fader.color.map { Pal.keyboards[$0 % Pal.keyboards.count] } ?? Pal.accent) {
                            client.send(.setFader(id: fader.id, value: $0))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 8) {
                transport(state.loopsPlaying ? "Loop ■" : "Loop ▶", on: state.loopsPlaying, color: Pal.accent) {
                    client.send(.loopsTogglePlay)
                }
                transport("Loop ●", on: state.loopsRecording, color: Pal.rec) { client.send(.loopsToggleRecord) }
                transport("■ Todo", on: false, color: Pal.text) { client.send(.stopAll) }
            }
            .padding(10)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text2).tracking(0.6)
    }

    private func transport(_ title: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(on ? Pal.window : color)
                .background(on ? color : Pal.control, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// A pad that fires on touch-down; hitting nearer the top is louder.
struct Pad: View {
    let short: String
    let name: String
    let fill: Color
    let lit: Bool
    let hit: (Int) -> Void
    @State private var down = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 4) {
                Text(short).font(.system(size: 26, weight: .heavy))
                Text(name).font(.system(size: 13)).opacity(0.8).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(lit || down ? Pal.window : Pal.text)
            .background(lit || down ? Pal.text : fill, in: RoundedRectangle(cornerRadius: 20))
            .scaleEffect(down ? 0.97 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !down else { return }
                        down = true
                        let y = min(max(0, value.startLocation.y / max(1, geo.size.height)), 1)
                        hit(Int(127 - y * 70))
                    }
                    .onEnded { _ in down = false }
            )
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isButton)
    }
}

/// A slider that sends while you drag and follows the Mac's value otherwise.
struct RemoteSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var tint: Color = Pal.accent
    let send: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        Slider(value: Binding(get: { dragging ?? value }, set: { v in
            dragging = v
            send(v)
        }), in: range) { editing in if !editing { dragging = nil } }
        .tint(tint)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
