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
                        SongCard(client: client, song: client.song, state: state)
                        record(state)
                        tempo(state)
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

/// The song from the phone: where it is, play / stop, back to the start, and its sections to
/// jump to (tap one and it plays from there).
private struct SongCard: View {
    let client: RemoteClient
    @ObservedObject var song: SongClock
    let state: RemoteState

    private var bars: Int { max(1, state.songBars ?? 8) }
    private var sections: [RemoteSection] { state.songSections ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CANCIÓN").font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.text2).tracking(0.6)
                Spacer()
                Text(position).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Pal.text2)
            }
            if state.songHasClips == false {
                Text("La canción está vacía: móntala en el Mac (modo Canción).")
                    .font(.system(size: 13)).foregroundStyle(Pal.text3)
            }
            progress.frame(height: 26)
            HStack(spacing: 10) {
                Button { client.send(.songRewind) } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 20, weight: .bold))
                        .frame(width: 64, height: 64)
                        .background(Pal.control, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                Button { client.send(.songTogglePlay) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: song.playing ? "stop.fill" : "play.fill").font(.system(size: 24, weight: .bold))
                        Text(song.playing ? "Parar canción" : "Tocar canción").font(.system(size: 18, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .foregroundStyle(song.playing ? Pal.onAccent : Pal.text)
                    .background(song.playing ? Pal.accent : Pal.control, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(state.songHasClips == false)
            }
            if !sections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sections) { s in
                            let here = song.playing && song.beat >= Double(s.start * 4) && song.beat < Double((s.start + s.bars) * 4)
                            Button { client.send(.songPlay(fromBar: s.start)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                                    Text("compás \(s.start + 1)").font(.system(size: 11)).foregroundStyle(here ? Pal.window.opacity(0.7) : Pal.text3)
                                }
                                .padding(.horizontal, 14).frame(minWidth: 96, minHeight: 54, alignment: .leading)
                                .foregroundStyle(here ? Pal.window : Pal.text)
                                .background(here ? color(s) : color(s).opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Toca una sección para tocar desde ahí.").font(.system(size: 11)).foregroundStyle(Pal.text3)
            }
        }
        .padding(16)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func color(_ s: RemoteSection) -> Color { Pal.keyboards[s.color % Pal.keyboards.count] }

    private var position: String {
        let bar = Int(song.beat / 4) + 1, beat = Int(song.beat.truncatingRemainder(dividingBy: 4)) + 1
        return "\(bar).\(beat) · \(clock(song.beat)) / \(clock(Double(bars) * 4))"
    }

    private func clock(_ beats: Double) -> String {
        let s = Int((beats * 60 / Double(max(1, song.bpm))).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Bars with the sections under them and the playhead.
    private var progress: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Pal.field)
                ForEach(sections) { s in
                    RoundedRectangle(cornerRadius: 4).fill(color(s).opacity(0.35))
                        .frame(width: max(2, w * CGFloat(s.bars) / CGFloat(bars) - 2))
                        .offset(x: w * CGFloat(s.start) / CGFloat(bars) + 1)
                        .padding(.vertical, 3)
                }
                Rectangle().fill(Pal.text).frame(width: 3)
                    .offset(x: min(w - 3, w * CGFloat(song.beat / Double(bars * 4))))
            }
        }
    }
}
