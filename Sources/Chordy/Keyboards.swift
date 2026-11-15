import Combine
import Foundation
import SwiftUI

/// What a keyboard's keys play.
/// - notes: each key is its own note, like a piano.
/// - chromatic: each key plays a major chord on its note (pads or WASD add color).
/// - degrees: white keys play degrees I–vii, black keys hold colors.
enum KeyLayout: String, CaseIterable, Codable {
    case notes, chromatic, degrees

    var label: String {
        switch self {
        case .notes: return tr("Notas")
        case .chromatic: return tr("Cromático")
        case .degrees: return tr("Grados")
        }
    }
}

/// One MIDI keyboard (or a zone of one) with its own sound.
struct KeyboardConfig: Codable, Identifiable, Equatable {
    enum Curve: String, CaseIterable, Codable {
        case soft, normal, hard, fixed

        var label: String {
            switch self {
            case .soft: return tr("Suave")
            case .normal: return tr("Normal")
            case .hard: return tr("Dura")
            case .fixed: return tr("Fija")
            }
        }

        /// Key velocity → played velocity.
        func apply(_ velocity: Int) -> Int {
            let v = Double(max(1, min(127, velocity))) / 127
            switch self {
            case .soft: return max(1, Int((pow(v, 0.6) * 127).rounded()))
            case .normal: return velocity
            case .hard: return max(1, Int((pow(v, 1.6) * 127).rounded()))
            case .fixed: return 100
            }
        }
    }

    var id: String
    var name: String
    /// CoreMIDI source name ("Digital Keyboard", "Launchkey MK2 25 Launchkey MIDI").
    var device: String
    /// nil = every channel except 10 (drum pads).
    var channel: Int?
    /// `InstrumentLibrary.synthId` or an `Instrument.id`.
    var instrument: String
    var layout: KeyLayout
    var low = 0
    var high = 127
    var octave = 0
    var curve = Curve.normal
    var volume = 0.85
    var color = 0
    /// Reverb, delay and filter on this keyboard's sampled sound.
    var effects: Effects?
    /// Show the drawing of the device instead of the plain keybed on its card.
    var showDevice: Bool?

    /// The sound plus this keyboard's effects bus.
    var route: String { SoundRoute.make(instrument, bus: "kb:\(id)") }

    /// Lane colors, told apart by lightness too: blue, amber, green, pink, teal, purple.
    static let palette: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.95, green: 0.65, blue: 0.35),
        Color(red: 0.30, green: 0.80, blue: 0.50), Color(red: 0.95, green: 0.45, blue: 0.65),
        Color(red: 0.30, green: 0.78, blue: 0.85), Color(red: 0.65, green: 0.50, blue: 0.95),
    ]
    var tint: Color { Self.palette[color % Self.palette.count] }

    func accepts(device: String, channel: Int, note: Int) -> Bool {
        guard device == self.device, (low...high).contains(note) else { return false }
        if let only = self.channel { return channel == only }
        return channel != 10
    }
}

/// The keyboards Chordy knows, saved in `~/Library/Application Support/Chordy/keyboards.json`.
/// A newly connected MIDI keyboard is added on its own, playing notes with a piano.
@MainActor
final class Keyboards: ObservableObject {
    @Published private(set) var configs: [KeyboardConfig] = [] { didSet { persist() } }
    /// Keyboards added since launch, for a one-line notice.
    @Published var justAdded: String?
    /// Keyboard whose settings sheet is open.
    @Published var editing: String?
    /// The keyboard played last: ◀ ▶, the 1–8 keys and program changes switch its sound.
    @Published var active: String?
    /// Eight quick sounds shown on every card (slot 1–8).
    @Published private(set) var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favoriteSounds")
        ?? Keyboards.defaultFavorites {
        didSet { UserDefaults.standard.set(favorites, forKey: "favoriteSounds") }
    }
    static let defaultFavorites = ["salamander", "upright", "gu:rhodes", "gu:organ", "gu:strings", "gu:warmpad",
                                   "gu:bass", InstrumentLibrary.synthId]
    /// Zone learning: the next two notes from this keyboard set its low and high keys.
    @Published private(set) var learningZone: String?
    private var learnedLow: Int?

    private let instruments: InstrumentLibrary

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keyboards.json")
    }

    init(instruments: InstrumentLibrary) {
        self.instruments = instruments
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([KeyboardConfig].self, from: data) {
            configs = saved
        }
    }

    func config(_ id: String) -> KeyboardConfig? { configs.first { $0.id == id } }

    /// The keyboard a note belongs to (first match wins, so zones can split one keyboard).
    func match(device: String, channel: Int, note: Int) -> KeyboardConfig? {
        configs.first { $0.accepts(device: device, channel: channel, note: note) }
    }

    func hasKeyboard(on device: String) -> Bool { configs.contains { $0.device == device } }

    func update(_ id: String, _ body: (inout KeyboardConfig) -> Void) {
        guard let i = configs.firstIndex(where: { $0.id == id }) else { return }
        var c = configs[i]
        body(&c)
        c.low = max(0, min(127, c.low))
        c.high = max(c.low, min(127, c.high))
        c.octave = max(-4, min(4, c.octave))
        c.volume = max(0, min(1, c.volume))
        guard c != configs[i] else { return }
        let effectsChanged = c.effects != configs[i].effects
        configs[i] = c
        if effectsChanged { instruments.effectsChanged(bus: "kb:\(id)") }
    }

    func remove(_ id: String) { configs.removeAll { $0.id == id } }

    /// Opening a project: its keyboards replace these (effects buses follow).
    func replaceAll(_ new: [KeyboardConfig]) {
        configs = new
        for c in new { instruments.effectsChanged(bus: "kb:\(c.id)") }
    }

    /// A second zone on the same device (split keyboard): upper half of the first.
    func addZone(from id: String) {
        guard let source = config(id) else { return }
        let split = (source.low + source.high + 1) / 2
        update(id) { $0.high = split - 1 }
        var zone = source
        zone.id = UUID().uuidString
        zone.name = tr("%@ (zona alta)", source.name)
        zone.low = split
        zone.color = nextColor()
        zone.instrument = defaultInstrument(skipping: source.instrument)
        configs.append(zone)
    }

    /// Add keyboards for MIDI sources that have none (not pad ports, not our own output).
    func adopt(sources: [String], legacy: (layout: KeyLayout, instrument: String)?) {
        for device in sources where !hasKeyboard(on: device) && Self.isKeyboard(device) {
            let isLaunchkey = device.localizedCaseInsensitiveContains("launchkey")
            let config = KeyboardConfig(
                id: UUID().uuidString,
                name: isLaunchkey ? "Launchkey" : Self.friendlyName(device),
                device: device,
                channel: isLaunchkey ? 1 : nil,
                instrument: isLaunchkey ? (legacy?.instrument ?? defaultInstrument()) : defaultInstrument(),
                layout: isLaunchkey ? (legacy?.layout ?? .chromatic) : .notes,
                color: nextColor())
            configs.append(config)
            justAdded = config.name
        }
    }

    // MARK: Sounds

    /// Give a keyboard a sound (downloading its bank when missing). nil = the active keyboard.
    func setSound(_ instrument: String, for id: String? = nil) {
        guard let target = id ?? active ?? configs.first?.id else { return }
        if let i = Instrument.with(instrument), let pack = InstrumentPack.with(i.pack), instruments.fileURL(pack) == nil {
            instruments.download(pack)
        }
        update(target) { $0.instrument = instrument }
        if let config = config(target) { _ = instruments.player(for: config.route) }
    }

    /// Favorite slot 0…7 on a keyboard (nil = the active one).
    func pickFavorite(_ slot: Int, for id: String? = nil) {
        guard favorites.indices.contains(slot) else { return }
        setSound(favorites[slot], for: id)
    }

    /// Next / previous favorite on the active keyboard.
    func stepFavorite(_ step: Int) {
        guard let id = active ?? configs.first?.id, let config = config(id) else { return }
        let i = favorites.firstIndex(of: config.instrument) ?? (step > 0 ? -1 : 0)
        pickFavorite(((i + step) % favorites.count + favorites.count) % favorites.count, for: id)
    }

    func setFavorite(_ slot: Int, to instrument: String) {
        guard favorites.indices.contains(slot) else { return }
        favorites[slot] = instrument
    }

    func markActive(_ id: String) { if active != id { active = id } }

    static func soundName(_ id: String) -> String {
        if id == InstrumentLibrary.synthId { return tr("Sintetizador") }
        if let patch = InstrumentLibrary.synthPatchId(id) { return AppModel.shared.sounds.name(of: patch) }
        return Instrument.with(id)?.name ?? id
    }

    // MARK: Zone learning

    func startZoneLearn(_ id: String) {
        learningZone = learningZone == id ? nil : id
        learnedLow = nil
    }

    /// Feed notes while learning; returns true when it used the note.
    func learn(device: String, note: Int) -> Bool {
        guard let id = learningZone, config(id)?.device == device else { return false }
        if let low = learnedLow {
            update(id) { $0.low = min(low, note); $0.high = max(low, note) }
            learningZone = nil
            learnedLow = nil
        } else {
            learnedLow = note
        }
        return true
    }

    // MARK: Helpers

    static func isKeyboard(_ device: String) -> Bool {
        !device.localizedCaseInsensitiveContains("incontrol") && device != AppInfo.name
    }

    private static func friendlyName(_ device: String) -> String {
        device == "Digital Keyboard" ? "Yamaha" : device
    }

    private func nextColor() -> Int {
        let used = Set(configs.map(\.color))
        return (0..<KeyboardConfig.palette.count).first { !used.contains($0) } ?? configs.count
    }

    private func defaultInstrument(skipping: String? = nil) -> String {
        let preferred = ["salamander", "upright", "gu:strings", "gu:rhodes", "macos:piano"]
        for id in preferred where id != skipping {
            if let i = Instrument.with(id), let pack = InstrumentPack.with(i.pack), instruments.fileURL(pack) != nil { return id }
        }
        return InstrumentLibrary.synthId
    }

    private func persist() {
        do {
            try JSONEncoder().encode(configs).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Chordy: could not save keyboards: \(error)")
        }
    }
}
