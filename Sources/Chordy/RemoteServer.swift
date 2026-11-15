import Combine
import Foundation
import Network
import QuartzCore

/// Lets Chordy Pads (iPad) control the drum machine and the mix over the local network:
/// advertises `_chordypads._tcp` with Bonjour, sends the state when it changes and the
/// playhead on every step, and runs the commands it receives.
@MainActor
final class RemoteServer: ObservableObject {
    /// iPads connected now, by name.
    @Published private(set) var clients: [String] = []

    private let drums: DrumMachine
    private let engine: ChordEngine
    private let keyboards: Keyboards
    private let loops: Loops
    private let midi: MidiController
    private let sounds: SoundLibrary
    private let instruments: InstrumentLibrary
    private var lastNotes: [String: Set<Int>] = [:]
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Client] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var stateScheduled = false
    private var lastState: RemoteState?
    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "chordy.remote")

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var buffer = LineBuffer()
        var name = "iPad"
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(drums: DrumMachine, engine: ChordEngine, keyboards: Keyboards, loops: Loops,
         midi: MidiController, sounds: SoundLibrary, instruments: InstrumentLibrary) {
        self.drums = drums
        self.engine = engine
        self.keyboards = keyboards
        self.loops = loops
        self.midi = midi
        self.sounds = sounds
        self.instruments = instruments
    }

    func start() {
        guard listener == nil else { return }
        do {
            // No Nagle: every hit and every tick leaves at once instead of being batched.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Chordy", type: RemoteProtocol.service)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("Chordy: remote listener failed: \(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Chordy: could not start the remote listener: \(error)")
        }
        for publisher in [drums.objectWillChange, engine.objectWillChange, keyboards.objectWillChange, loops.objectWillChange,
                          sounds.objectWillChange, instruments.objectWillChange, midi.devices.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleState() }.store(in: &cancellables)
        }
        midi.live.$keyWindow.removeDuplicates().sink { [weak self] _ in self?.scheduleState() }.store(in: &cancellables)
        // Keys held on each MIDI keyboard, sent as they change (the iPad lights them).
        midi.live.$notes.sink { [weak self] notes in self?.sendNotes(notes) }.store(in: &cancellables)
        drums.$step.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.sendTick() }
        }.store(in: &cancellables)
        // The 1-2-3-4 count for the iPad, on every beat and when recording starts or stops.
        BeatClock.shared.$beat.removeDuplicates().sink { [weak self] beat in
            self?.sendBeat(beat)
        }.store(in: &cancellables)
        loops.$recorderState.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sendBeat(BeatClock.shared.beat) }
        }.store(in: &cancellables)
        drums.$recording.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.sendBeat(BeatClock.shared.beat) }
        }.store(in: &cancellables)
        drums.$flash.sink { [weak self] new in
            guard let self else { return }
            for track in new.subtracting(self.drums.flash) { self.broadcast(.flash(track: track.rawValue)) }
        }.store(in: &cancellables)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        connections[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.sendState(force: true) }
            case .failed, .cancelled:
                DispatchQueue.main.async { self?.drop(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: ObjectIdentifier) {
        guard let client = connections[id] else { return }
        let connection = client.connection
        let fastHit = drums.fastHit
        let encoder = self.encoder
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            // When the hits arrived: recording places them by this, not by when main gets to them.
            let received = CACurrentMediaTime()
            // Decode on the network queue. Hits sound and pings answer right here, without
            // waiting for the main thread (busy drawing); the rest goes to the main thread.
            var commands: [RemoteCommand] = []
            if let data, !data.isEmpty {
                for line in client.buffer.append(data) {
                    guard let command = try? JSONDecoder().decode(RemoteCommand.self, from: line) else { continue }
                    switch command {
                    case .ping(let n):
                        if let reply = encoder.line(RemoteMessage.pong(id: n)) {
                            connection.send(content: reply, completion: .contentProcessed { _ in })
                        }
                        continue
                    case .hit(let track, let velocity):
                        fastHit(track, velocity)
                    case .hitNote(let note, let velocity):
                        fastHit(-1 - note, velocity)
                    default:
                        break
                    }
                    commands.append(command)
                }
            }
            DispatchQueue.main.async {
                guard let self, let client = self.connections[id] else { return }
                for command in commands { self.run(command, from: client, received: received) }
                if done || error != nil { self.drop(id) } else { self.receive(id) }
            }
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        connections.removeValue(forKey: id)?.connection.cancel()
        clients = connections.values.map(\.name).sorted()
    }

    private func broadcast(_ message: RemoteMessage) {
        guard !connections.isEmpty, let data = encoder.line(message) else { return }
        for client in connections.values { client.connection.send(content: data, completion: .contentProcessed { _ in }) }
    }

    // MARK: State

    private func scheduleState() {
        guard !stateScheduled, !connections.isEmpty else { return }
        stateScheduled = true
        // objectWillChange fires before the change; coalesce bursts (a knob, a drag) to ~20/s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.stateScheduled = false
            self?.sendState()
        }
    }

    private func sendState(force: Bool = false) {
        let state = snapshot()
        guard force || state != lastState else { return }
        lastState = state
        broadcast(.state(state))
        sendTick()
        if force { sendBeat(BeatClock.shared.beat) }
    }

    private func sendBeat(_ beat: Int?) {
        let position = BeatIndicator.position(beat: beat, takeStart: loops.recordStartBeat)
        broadcast(.beat(inBar: position?.inBar, bar: position?.bar,
                        recording: loops.recorderState == .recording || drums.recording,
                        armed: loops.recorderState == .armed))
    }

    private func sendNotes(_ notes: [String: Set<Int>]) {
        for device in Set(notes.keys).union(lastNotes.keys) where (notes[device] ?? []) != (lastNotes[device] ?? []) {
            broadcast(.notes(device: device, midi: (notes[device] ?? []).sorted()))
        }
        lastNotes = notes
    }

    private func sendTick() {
        broadcast(.tick(step: drums.step, pattern: drums.playingPattern, chainPosition: drums.chainPosition))
    }

    private func snapshot() -> RemoteState {
        let tracks = DrumTrack.allCases
        let patterns = drums.patterns.map { p in
            RemotePattern(title: p.title, steps: p.steps, laneVolumes: tracks.map { p.laneVolume($0) },
                          laneNotes: tracks.map { Int(p.laneNote($0)) }, swing: p.swing, volume: p.volume, kit: p.kit,
                          isEmpty: p.isEmpty)
        }
        var faders = [RemoteFader(id: "drums", name: tr("Batería"), value: drums.pattern.volume, color: nil)]
        faders += keyboards.configs.map { RemoteFader(id: "kb:\($0.id)", name: $0.name, value: $0.volume, color: $0.color) }
        faders.append(RemoteFader(id: "loops", name: tr("Loops"), value: loops.volume, color: nil))
        let connected = Set(midi.devices.names)
        let boards = keyboards.configs.map { c -> RemoteKeyboard in
            let e = c.effects ?? .none
            // The Launchkey shows its 25 keys where its octave buttons put them; others their zone,
            // or 61 keys (C2–C7) when the zone is the whole range.
            var first = 36, count = 61
            if c.device.localizedCaseInsensitiveContains("launchkey") {
                first = midi.live.keyWindow[c.device] ?? 48
                count = 25
            } else if c.high - c.low < 60 {
                first = c.low; count = c.high - c.low + 1
            }
            return RemoteKeyboard(
                id: c.id, name: c.name, device: c.device, color: c.color, sound: c.instrument,
                soundName: Keyboards.soundName(c.instrument), isSynth: InstrumentLibrary.isSynth(c.instrument),
                volume: c.volume,
                effects: RemoteEffects(reverb: e.reverb, delay: e.delay, delayTime: e.delayTime, feedback: e.feedback, filter: e.filter),
                connected: connected.contains(c.device), firstKey: first, keyCount: count)
        }
        var soundList = [RemoteSound(id: InstrumentLibrary.synthId, name: Keyboards.soundName(InstrumentLibrary.synthId),
                                     group: tr("Sintetizador"))]
        soundList += sounds.all.map { RemoteSound(id: InstrumentLibrary.synth($0.id), name: $0.name, group: tr("Sintetizador")) }
        for group in Instrument.Group.allCases where group != .drums {
            for i in Instrument.all where i.group == group {
                let pack = InstrumentPack.with(i.pack)
                let missing = pack.flatMap { instruments.fileURL($0) == nil ? $0.sizeMB : nil }
                soundList.append(RemoteSound(id: i.id, name: i.name, group: group.title, download: missing))
            }
        }
        return RemoteState(
            macName: Host.current().localizedName ?? "Mac",
            bpm: engine.bpm, playing: drums.playing, recording: drums.recording,
            selected: drums.selected, track: drums.track.rawValue, patterns: patterns,
            kits: drums.kits.map { RemoteKit(id: $0.id, name: $0.name) },
            laneNames: tracks.map(\.label), laneShorts: tracks.map(\.short),
            variants: tracks.map { $0.variants.map { RemoteVariant(note: Int($0.note), name: $0.name) } },
            muted: drums.muted.map(\.rawValue).sorted(), solo: drums.solo?.rawValue,
            chain: drums.chain, chainOn: drums.chainOn, faders: faders,
            loopsPlaying: loops.isPlaying, loopsRecording: loops.isRecording,
            keyboards: boards, sounds: soundList, favorites: keyboards.favorites)
    }

    // MARK: Commands

    private func track(_ i: Int) -> DrumTrack? { DrumTrack(rawValue: i) }

    private func run(_ command: RemoteCommand, from client: Client, received: Double? = nil) {
        switch command {
        case .hello(_, let device):
            client.name = device
            clients = connections.values.map(\.name).sorted()
        // Already sounded on the network queue (`fastHit`): here only the flash and recording.
        case .hit(let t, let v): if let t = track(t) { drums.hit(t, velocity: v, sound: false, at: received) }
        case .hitNote: break
        case .ping: break
        case .toggleStep(let t, let s, let accent): if let t = track(t), (0..<16).contains(s) { drums.toggleStep(t, s, accent: accent) }
        case .setVelocity(let t, let s, let v): if let t = track(t), (0..<16).contains(s) { drums.setVelocity(t, s, v) }
        case .select(let p): if drums.patterns.indices.contains(p) { drums.selected = p }
        case .launch(let p): drums.launch(p)
        case .selectTrack(let t): if let t = track(t) { drums.track = t }
        case .togglePlay: drums.togglePlay()
        case .toggleRecord: drums.toggleRecord()
        case .setBpm(let bpm): engine.setBpm(bpm)
        case .setSwing(let v): drums.setSwing(v)
        case .setKit(let id): drums.setKit(id)
        case .setLaneVolume(let t, let v): if let t = track(t) { drums.setLaneVolume(t, v) }
        case .setLaneNote(let t, let n): if let t = track(t) { drums.setLaneNote(t, UInt8(max(0, min(127, n)))) }
        case .toggleMute(let t): if let t = track(t) { drums.toggleMute(t) }
        case .toggleSolo(let t): if let t = track(t) { drums.toggleSolo(t) }
        case .chainAppend(let p): if drums.patterns.indices.contains(p) { drums.appendToChain(p) }
        case .chainRemove(let i): drums.removeFromChain(at: i)
        case .chainClear: drums.clearChain()
        case .setChainOn(let on): drums.chainOn = on
        case .setFader(let id, let v):
            if id == "drums" { drums.setVolume(v) } else if id == "loops" { loops.volume = max(0, min(1, v)) }
            else if id.hasPrefix("kb:") { keyboards.update(String(id.dropFirst(3))) { $0.volume = v } }
        case .fill(let t, let every, let offset): if let t = track(t) { drums.fill(t, every: max(1, every), offset: max(0, offset)) }
        case .shift(let t, let d): if let t = track(t) { drums.shift(t, by: d) }
        case .randomize(let t): if let t = track(t) { drums.randomize(t) }
        case .clearLane(let t): if let t = track(t) { drums.clearLane(t) }
        case .clearPattern: drums.clear()
        case .copyPattern(let to): drums.copy(to: to)
        case .loopsTogglePlay: loops.togglePlay()
        case .loopsToggleRecord: loops.toggleRecord()
        case .setSound(let id, let sound):
            let known = InstrumentLibrary.isSynth(sound) || Instrument.with(sound) != nil
            if known, keyboards.config(id) != nil { keyboards.setSound(sound, for: id) }
        case .setEffects(let id, let e):
            func clamp(_ v: Double, _ hi: Double = 1) -> Double { v.isFinite ? max(0, min(hi, v)) : 0 }
            let effects = Effects(reverb: clamp(e.reverb), delay: clamp(e.delay), delayTime: max(0.05, clamp(e.delayTime, 1.5)),
                                  feedback: clamp(e.feedback, 0.9), filter: clamp(e.filter))
            keyboards.update(id) { $0.effects = effects.isOff ? nil : effects }
        case .stopAll:
            loops.stopPlayback()
            drums.stop()
            engine.stopAll()
        }
    }
}
