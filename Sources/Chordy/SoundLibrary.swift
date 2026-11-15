import Combine
import Foundation

/// Factory and user sounds, the selected one and the draft being edited.
/// User sounds live in `~/Library/Application Support/Chordy/sounds.json`.
@MainActor
final class SoundLibrary: ObservableObject {
    @Published private(set) var userPatches: [Patch] = []
    @Published private(set) var selectedId: String
    /// What plays: the selected sound plus unsaved edits.
    @Published var draft: Patch {
        didSet { if draft != oldValue { Synth.shared.updateLive(draft) } }
    }

    private static let selectedKey = "selectedSound"

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sounds.json")
    }

    init() {
        let saved = (try? Data(contentsOf: Self.fileURL))
            .flatMap { try? JSONDecoder().decode([Patch].self, from: $0) } ?? []
        let user = saved.map { $0.sanitized() }.filter { !$0.isBuiltin }
        let id = UserDefaults.standard.string(forKey: Self.selectedKey) ?? Patch.builtins[0].id
        let all = Patch.builtins + user
        let patch = all.first { $0.id == id } ?? Patch.builtins[0]
        userPatches = user
        selectedId = patch.id
        draft = patch
    }

    var all: [Patch] { Patch.builtins + userPatches }
    var selected: Patch { all.first { $0.id == selectedId } ?? Patch.builtins[0] }
    /// The draft differs from the saved sound.
    var dirty: Bool { draft != selected }

    func select(_ id: String) {
        guard let patch = all.first(where: { $0.id == id }) else { return }
        selectedId = id
        draft = patch
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
    }

    /// Step through all sounds (MIDI buttons, menu).
    func selectNext(_ step: Int) {
        let list = all
        guard let i = list.firstIndex(where: { $0.id == selectedId }) else { return }
        select(list[((i + step) % list.count + list.count) % list.count].id)
    }

    func revert() { draft = selected }

    /// Save edits: over a user sound, or as a new one when editing a factory sound.
    func save(as name: String? = nil) {
        var patch = draft
        if selected.isBuiltin || name != nil {
            patch.id = "user:\(UUID().uuidString)"
            patch.name = String((name ?? tr("%@ (copia)", draft.name)).prefix(40))
            userPatches.append(patch)
        } else if let i = userPatches.firstIndex(where: { $0.id == patch.id }) {
            userPatches[i] = patch
        }
        persist()
        select(patch.id)
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = userPatches.firstIndex(where: { $0.id == id }) else { return }
        userPatches[i].name = String(trimmed.prefix(40))
        if draft.id == id { draft.name = userPatches[i].name }
        persist()
    }

    func remove(_ id: String) {
        userPatches.removeAll { $0.id == id }
        persist()
        if selectedId == id { select(Patch.builtins[0].id) }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(userPatches)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Chordy: could not save sounds: \(error)")
        }
    }
}
