import AVFoundation
import Combine
import Foundation
import QuartzCore
import os

// MARK: - Catalog

/// A sound bank file (SF2/DLS): bundled with macOS or downloaded on demand.
struct InstrumentPack: Identifiable, Hashable {
    let id: String
    let name: String
    /// Download size in MB (0 for the system bank).
    let sizeMB: Int
    let license: String
    let credit: String
    /// Archive or .sf2 to download; nil for the system bank.
    let source: URL?
    /// Path of a bank that ships with macOS.
    let systemPath: String?

    static let system = InstrumentPack(
        id: "macos", name: "macOS GM", sizeMB: 0, license: "Apple", credit: "General MIDI bank included with macOS",
        source: nil, systemPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    static let salamander = InstrumentPack(
        id: "salamander", name: "Salamander Grand Piano", sizeMB: 296, license: "CC BY 3.0",
        credit: "Salamander Grand Piano V3 by Alexander Holm (Yamaha C5), SF2 by FreePats",
        source: URL(string: "https://freepats.zenvoid.org/Piano/SalamanderGrandPiano/SalamanderGrandPiano-SF2-V3+20200602.tar.xz"),
        systemPath: nil)
    static let upright = InstrumentPack(
        id: "upright", name: "Upright Piano KW", sizeMB: 28, license: "CC0",
        credit: "Upright Piano KW by FreePats",
        source: URL(string: "https://freepats.zenvoid.org/Piano/UprightPianoKW/UprightPianoKW-SF2-20220221.7z"),
        systemPath: nil)
    static let generalUser = InstrumentPack(
        id: "generaluser", name: "GeneralUser GS", sizeMB: 31, license: "GeneralUser GS License v2.0",
        credit: "GeneralUser GS by S. Christian Collins",
        source: URL(string: "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2"),
        systemPath: nil)
    static let muldjord = InstrumentPack(
        id: "muldjord", name: "MuldjordKit", sizeMB: 55, license: "CC BY 4.0",
        credit: "MuldjordKit by Lars Muldjord, SF2 by FreePats",
        source: URL(string: "https://github.com/freepats/muldjordkit/releases/download/2020-10-18/MuldjordKit-SF2-20201018.7z"),
        systemPath: nil)

    // GeneralUser's programs 0–1 (grand pianos) crash AUSampler when they render, and
    // MuldjordKit's kick and snare zones play silent in it: neither is offered.
    static let all = [system, salamander, upright, generalUser]
    static func with(_ id: String) -> InstrumentPack? { all.first { $0.id == id } }
}

/// A playable preset inside a pack.
struct Instrument: Identifiable, Hashable {
    enum Group: CaseIterable {
        case pianos, keys, strings, guitars, winds, pads, drums

        var title: String {
            switch self {
            case .pianos: return tr("Pianos")
            case .keys: return tr("Teclados")
            case .strings: return tr("Cuerdas y coro")
            case .guitars: return tr("Guitarras y bajos")
            case .winds: return tr("Vientos")
            case .pads: return tr("Pads")
            case .drums: return tr("Baterías")
            }
        }
    }

    let id: String
    let name: String
    let group: Group
    let pack: String
    let program: UInt8
    /// 121 melodic, 120 percussion (AUSampler conventions).
    let bankMSB: UInt8

    private static func gm(_ id: String, _ name: String, _ group: Group, _ program: UInt8, drums: Bool = false) -> Instrument {
        Instrument(id: "gu:\(id)", name: name, group: group, pack: InstrumentPack.generalUser.id, program: program,
                   bankMSB: drums ? 120 : 121)
    }

    static let all: [Instrument] = [
        Instrument(id: "salamander", name: tr("Piano de cola"), group: .pianos, pack: InstrumentPack.salamander.id,
                   program: 0, bankMSB: 121),
        Instrument(id: "upright", name: tr("Piano vertical"), group: .pianos, pack: InstrumentPack.upright.id,
                   program: 0, bankMSB: 121),
        Instrument(id: "macos:piano", name: tr("Piano de macOS"), group: .pianos, pack: InstrumentPack.system.id,
                   program: 0, bankMSB: 121),
        gm("rhodes", tr("Piano eléctrico"), .keys, 4),
        gm("fm", tr("Piano eléctrico FM"), .keys, 5),
        gm("harpsichord", tr("Clavecín"), .keys, 6),
        gm("vibes", tr("Vibráfono"), .keys, 11),
        gm("organ", tr("Órgano Hammond"), .keys, 16),
        gm("church", tr("Órgano de iglesia"), .keys, 19),
        gm("accordion", tr("Acordeón"), .keys, 21),
        gm("strings", tr("Cuerdas"), .strings, 48),
        gm("slowstrings", tr("Cuerdas lentas"), .strings, 49),
        gm("choir", tr("Coro"), .strings, 52),
        gm("nylon", tr("Guitarra española"), .guitars, 24),
        gm("steel", tr("Guitarra acústica"), .guitars, 25),
        gm("clean", tr("Guitarra eléctrica"), .guitars, 27),
        gm("upbass", tr("Contrabajo"), .guitars, 32),
        gm("bass", tr("Bajo eléctrico"), .guitars, 33),
        gm("brass", tr("Metales"), .winds, 61),
        gm("sax", tr("Saxo alto"), .winds, 65),
        gm("flute", tr("Flauta"), .winds, 73),
        gm("warmpad", tr("Pad cálido"), .pads, 89),
        gm("polysynth", tr("Polysynth"), .pads, 90),
        gm("kit:standard", tr("Batería estándar"), .drums, 0, drums: true),
        gm("kit:room", tr("Batería room"), .drums, 8, drums: true),
        gm("kit:power", tr("Batería power"), .drums, 16, drums: true),
        gm("kit:electronic", tr("Batería electrónica"), .drums, 24, drums: true),
        gm("kit:808", tr("Caja de ritmos 808/909"), .drums, 25, drums: true),
        gm("kit:dance", tr("Batería dance"), .drums, 26, drums: true),
        gm("kit:jazz", tr("Batería jazz"), .drums, 32, drums: true),
        gm("kit:brush", tr("Batería escobillas"), .drums, 40, drums: true),
    ]

    static func with(_ id: String) -> Instrument? { all.first { $0.id == id } }
}

// MARK: - Library (selection and downloads)

/// Which instrument plays (or the synth) and the downloaded banks in
/// `~/Library/Application Support/Chordy/Instruments`.
@MainActor
final class InstrumentLibrary: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum PackState: Equatable {
        case missing
        case downloading(Double)
        case installing
        case ready
        case failed(String)
    }

    nonisolated static let synthId = "synth"

    /// "synth" (the sound being edited) or "synth:<patch id>" (a saved synth sound).
    nonisolated static func isSynth(_ id: String) -> Bool { id == synthId || id.hasPrefix("synth:") }
    nonisolated static func synthPatchId(_ id: String) -> String? { id.hasPrefix("synth:") ? String(id.dropFirst(6)) : nil }
    nonisolated static func synth(_ patchId: String) -> String { "synth:\(patchId)" }

    /// `synthId` or an `Instrument.id`.
    @Published private(set) var selectedId: String
    @Published private(set) var states: [String: PackState] = [:]
    /// The selected instrument is loading into the sampler.
    @Published private(set) var loading = false

    /// One sampler per instrument in use: the selected one, and each loop's own.
    private var players: [String: SamplerPlayer] = [:]
    private var session: URLSession!
    private var tasks: [Int: String] = [:]
    /// Instrument to select once its pack finishes downloading.
    private var pendingSelection: String?

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
            .appendingPathComponent("Instruments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override init() {
        let saved = UserDefaults.standard.string(forKey: "instrument") ?? Self.synthId
        selectedId = Instrument.with(saved) == nil ? Self.synthId : saved
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        for pack in InstrumentPack.all { states[pack.id] = fileURL(pack) != nil ? .ready : .missing }
    }

    var usesSynth: Bool { selectedId == Self.synthId }
    var selected: Instrument? { Instrument.with(selectedId) }

    func state(_ pack: InstrumentPack) -> PackState { states[pack.id] ?? .missing }

    /// Bank file on disk, if present.
    func fileURL(_ pack: InstrumentPack) -> URL? {
        if let path = pack.systemPath { return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil }
        let url = Self.directory.appendingPathComponent("\(pack.id).sf2")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Load what was selected last time (call once audio is running).
    func restore() {
        if let instrument = selected { _ = player(for: instrument.id) }
        for pack in InstrumentPack.all { slimIfNeeded(pack) }
    }

    /// Banks too big for AUSampler (it drops the left channel of part of them): rewritten once
    /// with every n-th velocity layer. Salamander: 16 → 8 layers, 1.27 GB → 0.64 GB.
    private static let slimLayers: [String: Int] = ["salamander": 2]
    private static func slimKey(_ id: String) -> String { "slimmed.\(id)" }

    private func slimIfNeeded(_ pack: InstrumentPack, then done: (() -> Void)? = nil) {
        guard let every = Self.slimLayers[pack.id], !UserDefaults.standard.bool(forKey: Self.slimKey(pack.id)),
              let url = fileURL(pack) else {
            done?()
            return
        }
        states[pack.id] = .installing
        let temp = Self.directory.appendingPathComponent("\(pack.id).slim.sf2")
        DispatchQueue.global(qos: .utility).async {
            var ok = true
            do {
                try? FileManager.default.removeItem(at: temp)
                try SF2Slimmer.reduceLayers(source: url, destination: temp, every: every)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try FileManager.default.moveItem(at: temp, to: url)
            } catch {
                NSLog("Chordy: could not slim \(pack.id): \(error)")
                try? FileManager.default.removeItem(at: temp)
                ok = false
            }
            DispatchQueue.main.async {
                if ok { UserDefaults.standard.set(true, forKey: Self.slimKey(pack.id)) }
                self.states[pack.id] = self.fileURL(pack) != nil ? .ready : .missing
                if ok { self.reloadPlayers(of: pack) }
                done?()
            }
        }
    }

    /// Load the bank again into every sampler that uses it (after it was rewritten).
    private func reloadPlayers(of pack: InstrumentPack) {
        for (key, player) in players {
            guard let instrument = Instrument.with(SoundRoute.parse(key).instrument), instrument.pack == pack.id else { continue }
            load(instrument, into: player)
        }
    }

    func selectSynth() {
        pendingSelection = nil
        selectedId = Self.synthId
        UserDefaults.standard.set(selectedId, forKey: "instrument")
    }

    /// The sampler for an instrument, created and loaded on first use (nil for the synth
    /// or a bank that isn't downloaded).
    /// `id` may carry an effects bus (`SoundRoute`): each bus gets its own sampler and chain.
    func player(for id: String) -> SamplerPlayer? {
        if let player = players[id] { return player }
        let (plain, bus) = SoundRoute.parse(id)
        guard let instrument = Instrument.with(plain), let pack = InstrumentPack.with(instrument.pack),
              fileURL(pack) != nil else { return nil }
        let player = SamplerPlayer()
        player.bus = bus
        player.setVolume(knobVolume)
        player.setEffects(bus.flatMap { effects($0) } ?? .none)
        players[id] = player
        load(instrument, into: player)
        return player
    }

    /// Effects of a bus ("loop:<id>", "kb:<id>"); set by `AppModel`.
    var effects: (String) -> Effects? = { _ in nil }

    /// A bus's effects changed: retune every sampler on it.
    func effectsChanged(bus: String) {
        let value = effects(bus) ?? .none
        for player in players.values where player.bus == bus { player.setEffects(value) }
        Synth.shared.setEffects(bus: bus, value)
    }

    /// Bend, modulation and volume reach every sampler.
    func forEachPlayer(_ body: (SamplerPlayer) -> Void) { players.values.forEach(body) }

    /// Samplers the player plays (not loop playback): bend and modulation stay off the loops.
    func forEachLivePlayer(_ body: (SamplerPlayer) -> Void) {
        players.values.filter { !($0.bus?.hasPrefix("loop:") ?? false) }.forEach(body)
    }

    /// Last volume knob value, given to samplers created later (a loop's first play).
    var knobVolume = 1.0

    /// Select an instrument; downloads its pack first when missing.
    func select(_ instrument: Instrument) {
        guard let pack = InstrumentPack.with(instrument.pack) else { return }
        guard fileURL(pack) != nil else {
            pendingSelection = instrument.id
            download(pack)
            return
        }
        pendingSelection = nil
        selectedId = instrument.id
        UserDefaults.standard.set(selectedId, forKey: "instrument")
        _ = player(for: instrument.id)
    }

    /// Step through the synth and the instruments that are ready (MIDI sound ◀ ▶).
    func selectNext(_ step: Int) {
        let ready = Instrument.all.filter { i in InstrumentPack.with(i.pack).map { fileURL($0) != nil } ?? false }
        let ids = [Self.synthId] + ready.map(\.id)
        let i = ids.firstIndex(of: selectedId) ?? 0
        let next = ids[((i + step) % ids.count + ids.count) % ids.count]
        if let instrument = Instrument.with(next) { select(instrument) } else { selectSynth() }
    }

    private func load(_ instrument: Instrument, into player: SamplerPlayer) {
        guard let pack = InstrumentPack.with(instrument.pack), let url = fileURL(pack) else { return }
        if selectedId == instrument.id { loading = true }
        player.load(url: url, program: instrument.program, bankMSB: instrument.bankMSB) { [weak self] ok in
            guard let self else { return }
            if self.selectedId == instrument.id { self.loading = false }
            if !ok {
                for (key, p) in self.players where p === player { self.players[key] = nil }
                self.states[pack.id] = .failed(tr("No se pudo cargar el instrumento"))
            }
        }
    }

    // MARK: Downloads

    func download(_ pack: InstrumentPack) {
        guard let source = pack.source else { return }
        if case .downloading = state(pack) { return }
        let task = session.downloadTask(with: source)
        tasks[task.taskIdentifier] = pack.id
        states[pack.id] = .downloading(0)
        task.resume()
    }

    func cancel(_ pack: InstrumentPack) {
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                for task in tasks where self.tasks[task.taskIdentifier] == pack.id { task.cancel() }
            }
        }
        if pendingSelection.flatMap(Instrument.with)?.pack == pack.id { pendingSelection = nil }
        states[pack.id] = .missing
    }

    /// Moves a downloaded bank to the Trash.
    func remove(_ pack: InstrumentPack) {
        guard pack.systemPath == nil, let url = fileURL(pack) else { return }
        if selected?.pack == pack.id { selectSynth() }
        for (key, player) in players where Instrument.with(SoundRoute.parse(key).instrument)?.pack == pack.id {
            player.allOff()
            players[key] = nil
        }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        UserDefaults.standard.removeObject(forKey: Self.slimKey(pack.id))
        states[pack.id] = .missing
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        MainActor.assumeIsolated {
            guard let pack = tasks[id] else { return }
            states[pack] = .downloading(progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns: move it somewhere of ours first.
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "download"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("chordy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent(name)
        let moved = (try? FileManager.default.moveItem(at: location, to: archive)) != nil
        MainActor.assumeIsolated {
            guard let packId = tasks.removeValue(forKey: id), let pack = InstrumentPack.with(packId) else { return }
            guard moved, (200..<300).contains(status) else {
                states[packId] = .failed(tr("La descarga falló"))
                return
            }
            install(pack, archive: archive, work: work)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        let id = task.taskIdentifier
        MainActor.assumeIsolated {
            guard let pack = tasks.removeValue(forKey: id) else { return }
            states[pack] = .failed(error.localizedDescription)
        }
    }

    /// Extract (tar reads .tar.xz and .7z) and keep the first .sf2 as `<pack>.sf2`.
    private func install(_ pack: InstrumentPack, archive: URL, work: URL) {
        states[pack.id] = .installing
        let destination = Self.directory.appendingPathComponent("\(pack.id).sf2")
        DispatchQueue.global(qos: .userInitiated).async {
            var bank: URL?
            if archive.pathExtension.lowercased() == "sf2" {
                bank = archive
            } else {
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-xf", archive.path, "-C", work.path]
                try? tar.run()
                tar.waitUntilExit()
                let files = FileManager.default.enumerator(at: work, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL } ?? []
                bank = files.first { $0.pathExtension.lowercased() == "sf2" }
            }
            var ok = false
            if let bank {
                try? FileManager.default.removeItem(at: destination)
                ok = (try? FileManager.default.moveItem(at: bank, to: destination)) != nil
            }
            try? FileManager.default.removeItem(at: work)
            DispatchQueue.main.async {
                guard ok else {
                    self.states[pack.id] = .failed(tr("No se encontró el instrumento en la descarga"))
                    return
                }
                UserDefaults.standard.removeObject(forKey: Self.slimKey(pack.id))
                self.slimIfNeeded(pack) {
                    self.states[pack.id] = .ready
                    if let id = self.pendingSelection, let instrument = Instrument.with(id), instrument.pack == pack.id {
                        self.select(instrument)
                    }
                }
            }
        }
    }
}

// MARK: - Effects

/// Per-loop or per-keyboard effects on sampled instruments (the synth has none).
struct Effects: Codable, Equatable {
    /// 0…1 wet amounts.
    var reverb = 0.0
    var delay = 0.0
    /// Seconds between echoes and how much comes back (0…0.9).
    var delayTime = 0.375
    var feedback = 0.35
    /// Low-pass: 1 = open, 0 ≈ 200 Hz.
    var filter = 1.0

    static let none = Effects()
    var isOff: Bool { self == .none }
}

/// A sound plus the effects bus it plays through, packed in one string ("salamander@loop:<id>")
/// so the existing instrument plumbing carries it.
enum SoundRoute {
    static func make(_ instrument: String, bus: String?) -> String {
        guard let bus else { return instrument }
        return "\(instrument)@\(bus)"
    }

    static func parse(_ route: String) -> (instrument: String, bus: String?) {
        guard let at = route.firstIndex(of: "@") else { return (route, nil) }
        return (String(route[..<at]), String(route[route.index(after: at)...]))
    }
}

// MARK: - Sampler

/// The thread-safe heart of a `SamplerPlayer`: its unit, whether it may sound, and how many
/// holders each pitch has. The main thread (chords, loops) and the MIDI thread (live keys, see
/// `LiveFastPath`) both go through it; its lock serializes them and the MIDI they send.
final class SamplerGate: @unchecked Sendable {
    let unit: AVAudioUnitSampler
    private struct State {
        var ready = false
        var counts: [Int: Int] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(unit: AVAudioUnitSampler) { self.unit = unit }

    var isReady: Bool { state.withLock { $0.ready } }

    /// Turning it off first is what makes detaching the unit safe: no MIDI goes out after this.
    func setReady(_ ready: Bool) {
        state.withLock { s in
            s.ready = ready
            if !ready { s.counts.removeAll() }
        }
    }

    /// False (silent) while the bank loads.
    @discardableResult
    func on(_ midi: Int, velocity: UInt8, at time: Double? = nil) -> Bool {
        state.withLock { s in
            guard s.ready else { return false }
            s.counts[midi, default: 0] += 1
            AudioClock.send(unit, 0x90, UInt8(midi), velocity, at: time)
            return true
        }
    }

    /// Stops the pitch when its last holder lets go.
    func off(_ midi: Int, at time: Double? = nil) {
        state.withLock { s in
            guard s.ready, let held = s.counts[midi] else { return }
            s.counts[midi] = held > 1 ? held - 1 : nil
            if held <= 1 { AudioClock.send(unit, 0x80, UInt8(midi), 0, at: time) }
        }
    }

    func allOff() {
        state.withLock { s in
            if s.ready { for midi in s.counts.keys { unit.stopNote(UInt8(midi), onChannel: 0) } }
            s.counts.removeAll()
        }
    }
}

/// An `AVAudioUnitSampler` on the synth's engine. Note ids let two chords share a note:
/// it only stops when the last one lets go.
@MainActor
final class SamplerPlayer {
    private let unit = AVAudioUnitSampler()
    /// Thread-safe note gate on `unit` (the MIDI thread plays live keys through it).
    nonisolated let gate: SamplerGate
    private let eq = AVAudioUnitEQ(numberOfBands: 1)
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private var chainAttached = false
    /// Sampler gain at level 1: room for two samplers of fff chords plus drums under 0 dBFS,
    /// so the master limiter only catches rare peaks.
    nonisolated static let headroomDB: Float = -6
    private var level = 1.0
    /// Effects bus this sampler plays through, if any.
    var bus: String?
    /// The unit renders only once its bank is in: loading into a sampler that is rendering
    /// crashes CoreAudio (playing while a program change switched the sound did).
    private var ready = false
    private var notes: [Int: Int] = [:]
    /// Host time each scheduled note starts at, so its note-off never lands before it.
    private var starts: [Int: Double] = [:]
    private var nextId = 1
    private var generation = 0

    init() { gate = SamplerGate(unit: unit) }

    /// Every sound bank load goes through this one queue: AUSampler crashes (CAVerboseAbort in
    /// AudioUnitSetProperty) when several samplers load banks at the same time, as happened
    /// when all keyboards prepared their sounds at launch.
    nonisolated static let loadQueue = DispatchQueue(label: "chordy.sampler-load", qos: .userInitiated)

    func load(url: URL, program: UInt8, bankMSB: UInt8, done: @escaping (Bool) -> Void) {
        allOff()
        if ready {
            gate.setReady(false)
            Synth.shared.detach(unit)
            ready = false
        }
        generation += 1
        let current = generation
        let unit = self.unit
        SamplerPlayer.loadQueue.async {
            var ok = true
            do {
                try unit.loadSoundBankInstrument(at: url, program: program, bankMSB: bankMSB, bankLSB: 0)
            } catch {
                NSLog("Chordy: could not load \(url.lastPathComponent) \(program): \(error)")
                ok = false
            }
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                if ok {
                    // Sampler → filter → delay → reverb → mixer. Headroom comes from the sampler's
                    // gain; only the master limiter guards 0 dBFS.
                    if !self.chainAttached {
                        Synth.shared.attach(self.reverb)
                        Synth.shared.attach(self.delay, to: self.reverb)
                        Synth.shared.attach(self.eq, to: self.delay)
                        self.chainAttached = true
                    }
                    Synth.shared.attach(unit, to: self.eq)
                    self.applyGain()
                    self.ready = true
                    self.gate.setReady(true)
                }
                done(ok)
            }
        }
    }

    func setEffects(_ e: Effects) { Effects.apply(e, eq: eq, delay: delay, reverb: reverb) }
}

extension Effects {
    /// Filter → echo → reverb settings, shared by the samplers and the synth's outputs.
    static func apply(_ e: Effects, eq: AVAudioUnitEQ, delay: AVAudioUnitDelay, reverb: AVAudioUnitReverb) {
        let band = eq.bands[0]
        band.filterType = .lowPass
        band.frequency = Float(200 * pow(100, min(1, max(0, e.filter))))
        band.bandwidth = 0.7
        band.bypass = e.filter >= 0.999
        eq.bypass = e.filter >= 0.999
        delay.delayTime = min(2, max(0.05, e.delayTime))
        delay.feedback = Float(min(0.9, max(0, e.feedback)) * 100)
        delay.lowPassCutoff = 9000
        delay.wetDryMix = Float(e.delay * 50)
        delay.bypass = e.delay <= 0.001
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = Float(e.reverb * 60)
        reverb.bypass = e.reverb <= 0.001
    }
}

extension SamplerPlayer {

    /// Notes played while the bank loads are silent but keep their ids. `time`: host time it
    /// must sound at, sample-accurately (loop playback schedules ahead); nil = now.
    func noteOn(midi: Int, velocity: Int, at time: Double? = nil) -> Int {
        let id = nextId
        nextId += 1
        guard ready, gate.on(midi, velocity: Self.curve(velocity), at: time) else { return id }
        notes[id] = midi
        if let time { starts[id] = time }
        return id
    }

    /// AUSampler applies the SF2 velocity curve, which is very steep: velocity 30 sounds ~40 dB
    /// under 127, almost silent. Squeeze 1…127 into 45…127 so soft playing stays audible
    /// (≈ 25–30 dB of dynamics, like a real piano) and the keyboard feels even.
    static func curve(_ velocity: Int) -> UInt8 { curveValue(velocity) }

    nonisolated static func curveValue(_ velocity: Int) -> UInt8 {
        let v = Double(max(1, min(127, velocity))) / 127
        return UInt8((45 + 82 * pow(v, 0.75)).rounded())
    }

    func noteOff(_ id: Int, at time: Double? = nil) {
        guard let midi = notes.removeValue(forKey: id) else { return }
        let start = starts.removeValue(forKey: id)
        // A note scheduled ahead may not have started yet: stop it just after it does.
        let when = max(time ?? 0, start.map { $0 + 0.002 } ?? 0)
        gate.off(midi, at: when > CACurrentMediaTime() ? when : nil)
    }

    func allOff() {
        // Notes scheduled to start a few ms from now get their own note-off after they start.
        for (id, start) in starts where ready && start > CACurrentMediaTime() {
            if let midi = notes[id] { gate.off(midi, at: start + 0.002) }
        }
        gate.allOff()
        notes.removeAll()
        starts.removeAll()
    }

    /// Semitones, ±2 range (the sampler's default bend range).
    func setBend(_ semitones: Double) {
        guard ready else { return }
        let value = Int(8192 + semitones / 2 * 8191)
        unit.sendPitchBend(UInt16(max(0, min(16383, value))), onChannel: 0)
    }

    func setModulation(_ value: Double) { guard ready else { return }; unit.sendController(1, withValue: UInt8(value * 127), onChannel: 0) }

    func setVolume(_ value: Double) { unit.volume = Float(value) }

    /// Keyboard or loops volume as gain (1 = the 0.85 default), not velocity.
    func setLevel(_ value: Double) {
        let clamped = max(0, min(2, value))
        guard clamped != level else { return }
        level = clamped
        applyGain()
    }

    private func applyGain() {
        let db = level > 0.0001 ? Float(20 * log10(level)) : -90
        unit.overallGain = max(-90, min(12, Self.headroomDB + db))
    }
}

// MARK: - Output router

/// Where chords and notes sound: the synth (current patch) or the sampler. Ids are
/// positive for synth voices and negative for sampler notes. Holds note-offs while
/// the sustain pedal is down.
@MainActor
final class SoundOutput {
    private let instruments: InstrumentLibrary
    private let patch: (String?) -> Patch
    private var sustain = false
    private var deferred: [(Int, Double?)] = []
    /// Sampler notes: our id (negative) → its player and that player's note id.
    private var samplerNotes: [Int: (player: SamplerPlayer, note: Int)] = [:]
    private var nextId = -1

    /// `patch`: the synth sound for "synth" (nil, the one being edited) or "synth:<id>".
    init(instruments: InstrumentLibrary, patch: @escaping (String?) -> Patch) {
        self.instruments = instruments
        self.patch = patch
    }

    /// `instrument` is a loop's own (`synthId` or an `Instrument.id`); nil = the selected one.
    /// `time`: host time to sound at (scheduled loop notes); nil = now.
    func noteOn(midi: Int, velocity: Int, instrument: String? = nil, at time: Double? = nil) -> Int {
        let id = instrument ?? instruments.selectedId
        let plain = SoundRoute.parse(id).instrument
        if !InstrumentLibrary.isSynth(plain), let player = instruments.player(for: id) {
            let ours = nextId
            nextId -= 1
            samplerNotes[ours] = (player, player.noteOn(midi: midi, velocity: velocity, at: time))
            return ours
        }
        var sound = patch(InstrumentLibrary.synthPatchId(plain))
        sound.volume *= 0.35 + 0.65 * Double(velocity) / 127
        let bus = SoundRoute.parse(id).bus
        let slot = Synth.shared.slot(for: bus, effects: bus.flatMap { instruments.effects($0) } ?? .none)
        return Synth.shared.noteOn(midi: midi, patch: sound, slot: slot, at: time)
    }

    /// `pedal: false` for loop notes: the sustain pedal only holds what the player plays.
    func noteOff(_ id: Int, release: Double? = nil, pedal: Bool = true, at time: Double? = nil) {
        if sustain && pedal {
            deferred.append((id, release))
            return
        }
        if id < 0 {
            if let entry = samplerNotes.removeValue(forKey: id) { entry.player.noteOff(entry.note, at: time) }
        } else {
            Synth.shared.noteOff(id, release: release, at: time)
        }
    }

    func setSustain(_ down: Bool) {
        guard down != sustain else { return }
        sustain = down
        if !down {
            let pending = deferred
            deferred.removeAll()
            for (id, release) in pending { noteOff(id, release: release) }
        }
    }
}
