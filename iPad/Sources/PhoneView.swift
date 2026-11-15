import QuartzCore
import SwiftUI

/// iPhone: a simple remote for the Mac — the count, the tempo (buttons and tap tempo),
/// record a loop, play loops or drums, stop everything.
struct PhoneView: View {
    @ObservedObject var client: RemoteClient
    @State private var taps: [Double] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if let state = client.state {
                ScrollView {
                    VStack(spacing: 16) {
                        count
                        tempo(state)
                        record(state)
                        transport(state)
                    }
                    .padding(16)
                }
            } else {
                waiting
            }
        }
        .background(Pal.window.ignoresSafeArea())
        .foregroundStyle(Pal.text)
    }

    // MARK: Header

    private var header: some View {
        Menu {
            if client.macs.isEmpty { Text("Buscando Chordy en la red…") }
            ForEach(client.macs, id: \.self) { name in Button(name) { client.connect(to: name) } }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(client.connected ? Pal.ok : Pal.warn).frame(width: 9, height: 9)
                Text(statusText).font(.system(size: 15, weight: .semibold)).lineLimit(1).foregroundStyle(Pal.text)
                Spacer()
                if let ms = client.latency {
                    Text("\(max(1, Int((ms / 2).rounded()))) ms")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ms < 30 ? Pal.ok : (ms < 70 ? Pal.warn : Pal.rec))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(Pal.bar)
    }

    private var statusText: String {
        switch client.status {
        case .searching: return "Buscando Chordy…"
        case .connecting(let name): return "Conectando con \(name)…"
        case .connected(let name): return name
        }
    }

    // MARK: Count

    private var count: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    let on = client.beatInBar == i
                    Text("\(i + 1)")
                        .font(.system(size: 30, weight: .heavy, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .foregroundStyle(on ? Pal.window : Pal.text3)
                        .background(on ? (client.recording ? Pal.rec : Pal.accent) : Pal.card, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            Text(countText).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(client.recording || client.armed ? Pal.rec : Pal.text3)
        }
    }

    private var countText: String {
        if client.armed { return "Toca una nota para empezar a grabar" }
        if let bar = client.bar { return client.recording ? "Grabando · compás \(bar)" : "Compás \(bar)" }
        return "Parado"
    }

    // MARK: Tempo

    private func tempo(_ state: RemoteState) -> some View {
        VStack(spacing: 14) {
            Text("TEMPO").font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text2).tracking(0.6)
            HStack(spacing: 10) {
                big("−") { client.send(.setBpm(state.bpm - 1)) }
                VStack(spacing: 0) {
                    Text("\(state.bpm)").font(.system(size: 64, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("bpm").font(.system(size: 13)).foregroundStyle(Pal.text3)
                }
                .frame(maxWidth: .infinity)
                big("+") { client.send(.setBpm(state.bpm + 1)) }
            }
            HStack(spacing: 8) {
                small("−5") { client.send(.setBpm(state.bpm - 5)) }
                Button { tap() } label: {
                    Text(taps.count >= 2 ? "Marcar · \(tappedBpm.map(String.init) ?? "…")" : "Marcar tempo")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Pal.onAccent)
                        .background(Pal.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                small("+5") { client.send(.setBpm(state.bpm + 5)) }
            }
            Text("Toca «Marcar tempo» al ritmo (4 veces o más).").font(.system(size: 11)).foregroundStyle(Pal.text3)
        }
        .padding(16)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var tappedBpm: Int? {
        guard taps.count >= 2 else { return nil }
        let gaps = zip(taps.dropFirst(), taps).map { $0 - $1 }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        return avg > 0 ? Int((60 / avg).rounded()) : nil
    }

    /// Tap tempo: the average of the last taps; a pause over 2 s starts again.
    private func tap() {
        let now = CACurrentMediaTime()
        if let last = taps.last, now - last > 2 { taps = [] }
        taps.append(now)
        if taps.count > 8 { taps.removeFirst() }
        if taps.count >= 3, let bpm = tappedBpm { client.send(.setBpm(bpm)) }
    }

    // MARK: Record and play

    private func record(_ state: RemoteState) -> some View {
        let on = state.loopsRecording || client.armed
        return Button { client.send(.loopsToggleRecord) } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "stop.circle.fill" : "record.circle").font(.system(size: 30, weight: .bold))
                Text(on ? (client.armed ? "Esperando la primera nota…" : "Parar y guardar el loop") : "Grabar loop")
                    .font(.system(size: 20, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .foregroundStyle(on ? Pal.window : Pal.rec)
            .background(on ? Pal.rec : Pal.rec.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func transport(_ state: RemoteState) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                toggle(state.loopsPlaying ? "Parar loops" : "Loops", symbol: state.loopsPlaying ? "stop.fill" : "play.fill",
                       on: state.loopsPlaying) { client.send(.loopsTogglePlay) }
                toggle(state.playing ? "Parar batería" : "Batería", symbol: state.playing ? "stop.fill" : "play.fill",
                       on: state.playing) { client.send(.togglePlay) }
            }
            Button { client.send(.stopAll) } label: {
                Label("Parar todo", systemImage: "stop.fill").font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(Pal.text)
                    .background(Pal.control, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22, weight: .bold))
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .foregroundStyle(on ? Pal.onAccent : Pal.text)
            .background(on ? Pal.accent : Pal.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func big(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 34, weight: .bold))
                .frame(width: 72, height: 72)
                .background(Pal.control, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func small(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .semibold, design: .monospaced))
                .frame(width: 64, height: 48)
                .background(Pal.control, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(client.macs.isEmpty ? "Buscando Chordy en tu red" : "Conectando…").font(.title3.weight(.semibold))
            Text("Abre Chordy en el Mac. El iPhone y el Mac tienen que estar en la misma wifi.\nSi iOS pregunta por la red local, acepta.")
                .multilineTextAlignment(.center).foregroundStyle(Pal.text2).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
