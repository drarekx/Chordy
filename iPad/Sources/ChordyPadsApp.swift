import SwiftUI

@main
struct ChordyPadsApp: App {
    @StateObject private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            Group {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    PhoneView(client: client)
                } else {
                    RootView(client: client)
                }
            }
                .preferredColorScheme(.dark)
                .onAppear {
                    client.start()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

/// The house dark palette (same as Chordy on the Mac).
enum Pal {
    static let window = Color(red: 0.071, green: 0.071, blue: 0.078)
    static let bar = Color(red: 0.086, green: 0.086, blue: 0.098)
    static let card = Color(red: 0.102, green: 0.102, blue: 0.114)
    static let field = Color(red: 0.122, green: 0.122, blue: 0.137)
    static let control = Color(red: 0.149, green: 0.149, blue: 0.169)
    static let line = Color(red: 0.18, green: 0.18, blue: 0.204)
    static let text = Color(red: 0.91, green: 0.91, blue: 0.918)
    static let text2 = Color(red: 0.63, green: 0.63, blue: 0.66)
    static let text3 = Color(red: 0.54, green: 0.54, blue: 0.576)
    static let accent = Color(red: 0.361, green: 0.549, blue: 1.0)
    static let onAccent = Color(red: 0.055, green: 0.086, blue: 0.188)
    static let accentSoft = Color(red: 0.114, green: 0.153, blue: 0.251)
    static let drum = Color(red: 0.141, green: 0.29, blue: 0.208)
    static let ok = Color(red: 0.235, green: 0.812, blue: 0.478)
    static let warn = Color(red: 0.96, green: 0.77, blue: 0.42)
    static let rec = Color(red: 1.0, green: 0.48, blue: 0.48)
    static let keyboards: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.95, green: 0.65, blue: 0.35),
        Color(red: 0.30, green: 0.80, blue: 0.50), Color(red: 0.95, green: 0.45, blue: 0.65),
        Color(red: 0.30, green: 0.78, blue: 0.85), Color(red: 0.65, green: 0.50, blue: 0.95),
    ]
}

struct RootView: View {
    @ObservedObject var client: RemoteClient
    @AppStorage("tab") private var tab = Tab.pads

    enum Tab: String, CaseIterable {
        case pads, steps, keys, mix
        var title: String {
            switch self {
            case .pads: return "Pads"
            case .steps: return "Pasos"
            case .keys: return "Teclados"
            case .mix: return "Mezcla"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Pal.line).frame(height: 1)
            if let state = client.state {
                Group {
                    switch tab {
                    case .pads: PadsView(client: client, state: state)
                    case .steps: StepsView(client: client, state: state)
                    case .keys: KeysView(client: client, state: state)
                    case .mix: MixView(client: client, state: state)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                waiting
            }
        }
        .background(Pal.window.ignoresSafeArea())
        .foregroundStyle(Pal.text)
        .persistentSystemOverlays(.hidden)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                if client.macs.isEmpty { Text("Buscando Chordy en la red…") }
                ForEach(client.macs, id: \.self) { name in Button(name) { client.connect(to: name) } }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(client.connected ? Pal.ok : Pal.warn).frame(width: 9, height: 9)
                    Text(statusText).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let ms = client.latency {
                        // One way is about half the round trip.
                        Text("\(max(1, Int((ms / 2).rounded()))) ms")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ms < 30 ? Pal.ok : (ms < 70 ? Pal.warn : Pal.rec))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Pal.card, in: Capsule())
                    }
                }
            }
            BeatBadge(client: client)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            Spacer()
            if let state = client.state {
                Button { client.send(.togglePlay) } label: {
                    Image(systemName: state.playing ? "stop.fill" : "play.fill").font(.system(size: 18, weight: .bold))
                        .frame(width: 56, height: 44)
                        .foregroundStyle(state.playing ? Pal.onAccent : Pal.text)
                        .background(state.playing ? Pal.accent : Pal.control, in: RoundedRectangle(cornerRadius: 11))
                }
                Button { client.send(.toggleRecord) } label: {
                    Image(systemName: "record.circle").font(.system(size: 18, weight: .bold))
                        .frame(width: 56, height: 44)
                        .foregroundStyle(state.recording ? Pal.window : Pal.rec)
                        .background(state.recording ? Pal.rec : Pal.control, in: RoundedRectangle(cornerRadius: 11))
                }
                HStack(spacing: 4) {
                    Button { client.send(.setBpm(state.bpm - 1)) } label: { Image(systemName: "minus").frame(width: 36, height: 44) }
                    Text("\(state.bpm)").font(.system(size: 18, weight: .semibold, design: .monospaced)).frame(minWidth: 40)
                    Button { client.send(.setBpm(state.bpm + 1)) } label: { Image(systemName: "plus").frame(width: 36, height: 44) }
                }
                .foregroundStyle(Pal.text)
                .padding(.horizontal, 6)
                .background(Pal.card, in: RoundedRectangle(cornerRadius: 11))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Pal.bar)
    }

    private var statusText: String {
        switch client.status {
        case .searching: return "Buscando Chordy…"
        case .connecting(let name): return "Conectando con \(name)…"
        case .connected(let name): return name
        }
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(client.macs.isEmpty ? "Buscando Chordy en tu red" : "Conectando…").font(.title3.weight(.semibold))
            Text("Abre Chordy en el Mac. El iPad y el Mac tienen que estar en la misma wifi.\nSi iOS pregunta por la red local, acepta.")
                .multilineTextAlignment(.center).foregroundStyle(Pal.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 1 · 2 · 3 · 4 and the bar, as on the Mac; red while recording.
struct BeatBadge: View {
    @ObservedObject var client: RemoteClient

    var body: some View {
        if client.armed {
            Label("Toca para grabar", systemImage: "record.circle")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Pal.rec)
        } else if let inBar = client.beatInBar {
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    let on = i == inBar
                    Text("\(i + 1)")
                        .font(.system(size: 22, weight: .heavy, design: .monospaced))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(on ? Pal.window : Pal.text3)
                        .background(on ? (client.recording ? Pal.rec : Pal.accent) : Pal.card,
                                    in: RoundedRectangle(cornerRadius: 9))
                }
                if let bar = client.bar {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("COMPÁS").font(.system(size: 9, weight: .semibold)).foregroundStyle(Pal.text3)
                        Text("\(bar)").font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(client.recording ? Pal.rec : Pal.text)
                    }
                    .frame(minWidth: 54, alignment: .leading)
                    .padding(.leading, 4)
                }
            }
        }
    }
}

/// Pattern buttons A–H shared by Pads and Steps.
struct PatternBar: View {
    @ObservedObject var client: RemoteClient
    let state: RemoteState
    /// Pads launch (start playing); Steps just select for editing.
    let launches: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(state.patterns.indices, id: \.self) { i in
                let p = state.patterns[i]
                let on = i == state.selected
                let sounding = state.playing && client.playingPattern == i
                Button { client.send(launches ? .launch(pattern: i) : .select(pattern: i)) } label: {
                    VStack(spacing: 1) {
                        Text(["A", "B", "C", "D", "E", "F", "G", "H"][i]).font(.system(size: 19, weight: .bold))
                        Text(p.title ?? (p.isEmpty ? "vacío" : " ")).font(.system(size: 10)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(on ? Pal.onAccent : (p.isEmpty ? Pal.text3 : Pal.text))
                    .background(on ? Pal.accent : Pal.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(sounding ? Pal.ok : .clear, lineWidth: 2.5) }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
