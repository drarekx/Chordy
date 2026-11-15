import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Everything a project holds: song, loops, drums, key/mode/tempo, keyboards and your synth
/// sounds. Saved as JSON in a `.chordy` file.
struct ProjectFile: Codable {
    var version = 1
    var song: SongData
    var loops: [Loop]
    var drums: [DrumPattern]
    var drumChain: [Int]
    var drumChainOn: Bool
    var bpm: Int
    var tonic: Note
    var flavor: Flavor
    var keyboards: [KeyboardConfig]
    var sounds: [Patch]
}

/// New, open, save, save as, recent projects and autosave every 30 s (only when something
/// changed). Without a file yet, autosave keeps a copy in Application Support.
@MainActor
final class Projects: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var dirty = false
    @Published private(set) var lastSaved: Date?
    @Published private(set) var recent: [URL] = []

    static let autosaveInterval: TimeInterval = 30
    private let model: AppModel
    private var savedData: Data?
    private var checkTimer: Timer?
    private var autosaveTimer: Timer?

    static let fileType = UTType(filenameExtension: "chordy", conformingTo: .json) ?? .json

    private static var autosaveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Autoguardado.chordy")
    }

    static var defaultFolder: URL {
        let dir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent(AppInfo.name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var name: String { url?.deletingPathExtension().lastPathComponent ?? tr("Sin título") }

    init(model: AppModel) {
        self.model = model
        recent = (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let path = UserDefaults.standard.string(forKey: "currentProject"), FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        }
    }

    func start() {
        savedData = encode()
        // Cheap check every 2 s for the "edited" dot; write every 30 s when needed.
        let check = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDirty() }
        }
        let autosave = Timer(timeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        RunLoop.main.add(check, forMode: .common)
        RunLoop.main.add(autosave, forMode: .common)
        checkTimer = check
        autosaveTimer = autosave
    }

    // MARK: Snapshot

    func snapshot() -> ProjectFile {
        let drums = model.drums
        return ProjectFile(song: model.song.data, loops: model.loops.loops, drums: drums.patterns, drumChain: drums.chain,
                           drumChainOn: drums.chainOn, bpm: model.engine.bpm, tonic: model.engine.tonic,
                           flavor: model.engine.flavor, keyboards: model.keyboards.configs, sounds: model.sounds.userPatches)
    }

    private func encode(_ project: ProjectFile? = nil) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(project ?? snapshot())
    }

    private func refreshDirty() {
        let now = encode() != savedData
        if now != dirty { dirty = now }
    }

    private func apply(_ p: ProjectFile) {
        model.song.stop()
        model.loops.replaceAll(p.loops)
        model.drums.replaceAll(patterns: p.drums, chain: p.drumChain, chainOn: p.drumChainOn)
        model.sounds.merge(p.sounds)
        model.keyboards.replaceAll(p.keyboards)
        model.engine.tonic = p.tonic
        model.engine.flavor = p.flavor
        model.engine.setBpm(p.bpm)
        model.song.replace(p.song)
    }

    // MARK: Commands

    /// Start empty (the current one is saved first if it has a file; otherwise asked).
    func newProject() {
        guard confirmDiscard() else { return }
        apply(ProjectFile(song: .empty, loops: [], drums: [.starter()], drumChain: [], drumChainOn: false,
                          bpm: 110, tonic: .c, flavor: .major, keyboards: model.keyboards.configs, sounds: []))
        setURL(nil)
        markSaved()
    }

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        panel.directoryURL = Self.defaultFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let project = try? decoder.decode(ProjectFile.self, from: data) else {
            let alert = NSAlert()
            alert.messageText = tr("No se pudo abrir el proyecto")
            alert.informativeText = url.lastPathComponent
            alert.runModal()
            return
        }
        apply(project)
        setURL(url)
        markSaved()
    }

    func openRecent(_ url: URL) {
        guard confirmDiscard() else { return }
        open(url)
    }

    @discardableResult
    func save() -> Bool {
        guard let url else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.directoryURL = url?.deletingLastPathComponent() ?? Self.defaultFolder
        panel.nameFieldStringValue = url?.lastPathComponent ?? tr("Mi canción") + ".chordy"
        guard panel.runModal() == .OK, let target = panel.url else { return false }
        setURL(target)
        return write(to: target)
    }

    private func autosave() {
        refreshDirty()
        guard dirty else { return }
        if let url { write(to: url) } else if let data = encode() { try? data.write(to: Self.autosaveURL, options: .atomic) }
    }

    @discardableResult
    private func write(to target: URL) -> Bool {
        guard let data = encode() else { return false }
        do {
            try data.write(to: target, options: .atomic)
            markSaved(data)
            addRecent(target)
            return true
        } catch {
            NSLog("Chordy: could not save project: \(error)")
            return false
        }
    }

    private func markSaved(_ data: Data? = nil) {
        savedData = data ?? encode()
        dirty = false
        lastSaved = Date()
    }

    private func setURL(_ new: URL?) {
        url = new
        UserDefaults.standard.set(new?.path, forKey: "currentProject")
        if let new { addRecent(new) }
    }

    private func addRecent(_ u: URL) {
        recent.removeAll { $0.path == u.path }
        recent.insert(u, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent.map(\.path), forKey: "recentProjects")
    }

    /// Unsaved changes: save into its file silently, or ask when it has none.
    private func confirmDiscard() -> Bool {
        refreshDirty()
        guard dirty else { return true }
        if url != nil { return save() }
        let alert = NSAlert()
        alert.messageText = tr("¿Guardar los cambios del proyecto?")
        alert.informativeText = tr("Si no los guardas, se pierden.")
        alert.addButton(withTitle: tr("Guardar…"))
        alert.addButton(withTitle: tr("No guardar"))
        alert.addButton(withTitle: tr("Cancelar"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveAs()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// On quit: write whatever changed.
    func saveOnQuit() {
        refreshDirty()
        guard dirty else { return }
        if let url { write(to: url) } else if let data = encode() { try? data.write(to: Self.autosaveURL, options: .atomic) }
    }
}
