import AppKit
import Combine
import SwiftUI

/// App identity shared by the updater, menus and storage.
enum AppInfo {
    static let name = "Chordy"
    /// GitHub repository the updater and installer read releases from.
    static let repo = "drarekx/Chordy"
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/drarek")!
    /// Menu bar app (no Dock icon). `build-app.sh` sets LSUIElement to match (`MENU_BAR`).
    static let menuBarApp = false
    /// SF Symbol of the menu bar icon.
    static let statusSymbol = "pianokeys"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        if AppInfo.menuBarApp { setupStatusItem() }
        Localizer.shared.$choice
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMainMenu() }
            .store(in: &cancellables)
        // @Published fires in willSet: apply after the change.
        Settings.shared.$theme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &cancellables)
        AppModel.shared.start()
        LoginItem.enableOnceFromApplications()
        Updater.shared.start()
        installDebugHook()

        // Dock apps open their window; menu bar apps only the first time.
        if !AppInfo.menuBarApp || !Settings.shared.hasLaunched { showMainWindow() }
        Settings.shared.hasLaunched = true
    }

    /// Opening the app again (Finder, Spotlight, Dock) shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: AppInfo.statusSymbol, accessibilityDescription: AppInfo.name)
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time it opens, so state and language are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ClosureMenuItem(title: tr("Abrir %@", AppInfo.name)) { [weak self] in self?.showMainWindow() })
        // App-specific items go here.
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: tr("Ajustes…"), keyEquivalent: ",") { [weak self] in self?.showSettings() })
        menu.addItem(.separator())
        let updating = Updater.shared.state != .idle
        let update = ClosureMenuItem(title: updating ? tr("Actualizando…") : tr("Buscar actualizaciones…")) {
            Task { await Updater.shared.check(userInitiated: true) }
        }
        update.isEnabled = !updating
        menu.addItem(update)
        let coffee = ClosureMenuItem(title: tr("Invítame a un café…")) { NSWorkspace.shared.open(AppInfo.buyMeACoffee) }
        coffee.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        menu.addItem(coffee)
        let version = NSMenuItem(title: "\(AppInfo.name) \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(ClosureMenuItem(title: tr("Salir de %@", AppInfo.name), keyEquivalent: "q") { NSApp.terminate(nil) })
    }

    // MARK: - Windows

    @objc func showMainWindow() {
        if mainWindow == nil {
            mainWindow = makeWindow(title: AppInfo.name, size: NSSize(width: 1360, height: 880),
                                    minSize: NSSize(width: 1120, height: 740), autosave: "StudioWindow",
                                    root: ThemedRoot { MainView() })
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: tr("Ajustes de %@", AppInfo.name), size: NSSize(width: 620, height: 720),
                                        minSize: NSSize(width: 520, height: 480), autosave: "SettingsWindow",
                                        root: ThemedRoot { SettingsPane() })
        }
        settingsWindow?.title = tr("Ajustes de %@", AppInfo.name)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, minSize: NSSize, autosave: String,
                                           root: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = minSize
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingController(rootView: root)
        // NSHostingController would otherwise shrink the window to its ideal size.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        // After setContentSize: restores the last frame, if any, and saves it from now on.
        window.setFrameAutosaveName(autosave)
        style(window)
        return window
    }

    private func style(_ window: NSWindow) {
        window.appearance = NSAppearance(named: Theme.palette.isLight ? .aqua : .darkAqua)
        window.backgroundColor = Theme.nsWindow
    }

    private func applyTheme() {
        for window in [mainWindow, settingsWindow].compactMap({ $0 }) { style(window) }
    }

    // MARK: - Main menu

    /// Dock apps show it; menu bar apps don't, but it still gives text fields ⌘C/⌘V/⌘A and windows ⌘W.
    private func setupMainMenu() {
        let main = NSMenu()
        let name = AppInfo.name

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Acerca de %@", name),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Ajustes…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: tr("Buscar actualizaciones…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        let coffee = appMenu.addItem(withTitle: tr("Invítame a un café…"), action: #selector(openBuyMeACoffee), keyEquivalent: "")
        coffee.target = self
        coffee.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Ocultar %@", name), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: tr("Ocultar otras"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: tr("Mostrar todo"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Salir de %@", name), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Edición"))
        edit.addItem(withTitle: tr("Deshacer"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Rehacer"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: tr("Ventana"))
        window.addItem(withTitle: tr("Cerrar ventana"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: tr("Minimizar"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(.separator())
        window.addItem(withTitle: name, action: #selector(showMainWindow), keyEquivalent: "0").target = self
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    @objc private func checkForUpdates() { Task { await Updater.shared.check(userInitiated: true) } }
    @objc private func openBuyMeACoffee() { NSWorkspace.shared.open(AppInfo.buyMeACoffee) }

    // MARK: - Debug hook

    /// Debug builds only: `DistributedNotificationCenter` `com.egluu.chordy.debug` with an object
    /// string drives the app for screenshots and checks: `main`, `settings`, `theme:<id>`, `shot:<folder>`,
    /// `press:<1-7>`, `release:<1-7>`, `dir:<direction|none>`, `octave:<0|1>`, `sound:<id>`, `stop`,
    /// `midi:<status>,<d1>,<d2>`, `tab:<loops|sound|midi>`, `map:<launchkey|keys|guided|clear>`, `record`, `play`, `dump:<file>`.
    private func installDebugHook() {
        #if DEBUG
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.egluu.chordy.debug"),
                                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                switch note.object as? String {
                case "main": self?.showMainWindow()
                case "settings": self?.showSettings()
                case let command? where command.hasPrefix("shot:"):
                    // Renders every visible window of the app to <folder>/<title>.png (no permissions needed).
                    let folder = URL(fileURLWithPath: String(command.dropFirst(5)), isDirectory: true)
                    for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                        guard let view = window.contentView?.superview ?? window.contentView,
                              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let name = window.title.isEmpty ? "window\(index)" : window.title
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: folder.appendingPathComponent("\(name).png"))
                    }
                case let command? where command.hasPrefix("press:"):
                    if let degree = Int(command.dropFirst(6)) { AppModel.shared.engine.pressDegree(degree) }
                case let command? where command.hasPrefix("release:"):
                    if let degree = Int(command.dropFirst(8)) { AppModel.shared.engine.releaseDegree(degree) }
                case let command? where command.hasPrefix("dir:"):
                    // dir:<direction> holds a wheel direction, dir:none lets go.
                    let engine = AppModel.shared.engine
                    engine.releaseAllDirections()
                    if let direction = Direction(rawValue: String(command.dropFirst(4))) {
                        engine.setDirection(direction, pressed: true)
                    }
                case let command? where command.hasPrefix("octave:"):
                    AppModel.shared.engine.setOctaveDown(command.hasSuffix("1"))
                case let command? where command.hasPrefix("sound:"):
                    AppModel.shared.sounds.select(String(command.dropFirst(6)))
                case "stop": AppModel.shared.engine.stopAll()
                case let command? where command.hasPrefix("dump:"):
                    // dump:<file> writes the sounding chords (degree, octave, MIDI notes), one per line.
                    let lines = AppModel.shared.engine.sounding.map { "\($0.degree) \($0.octave) \($0.notes) \($0.id) \(String(format: "%.3f", $0.start))" }
                    try? lines.joined(separator: "\n").write(toFile: String(command.dropFirst(5)), atomically: true, encoding: .utf8)
                case let command? where command.hasPrefix("instrument:"):
                    // instrument:<id|synth>
                    let id = String(command.dropFirst(11))
                    if let instrument = Instrument.with(id) { AppModel.shared.instruments.select(instrument) }
                    else { AppModel.shared.instruments.selectSynth() }
                case let command? where command.hasPrefix("download:"):
                    if let pack = InstrumentPack.with(String(command.dropFirst(9))) { AppModel.shared.instruments.download(pack) }
                case let command? where command.hasPrefix("layout:"):
                    // layout:<notes|chromatic|degrees> for every keyboard.
                    if let layout = KeyLayout(rawValue: String(command.dropFirst(7))) {
                        for c in AppModel.shared.keyboards.configs { AppModel.shared.keyboards.update(c.id) { $0.layout = layout } }
                    }
                case let command? where command.hasPrefix("state:"):
                    // state:<file> writes instrument, loading flag and pack states.
                    let lib = AppModel.shared.instruments
                    let lines = ["selected \(lib.selectedId) loading \(lib.loading)"]
                        + InstrumentPack.all.map { "\($0.id) \(lib.state($0))" }
                    try? lines.joined(separator: "\n").write(toFile: String(command.dropFirst(6)), atomically: true, encoding: .utf8)
                case "record": AppModel.shared.loops.toggleRecord()
                case "play": AppModel.shared.loops.togglePlay()
                case let command? where command.hasPrefix("midi:"):
                    // midi:<status>,<data1>,<data2> in decimal, e.g. midi:144,60,100.
                    let bytes = command.dropFirst(5).split(separator: ",").compactMap { UInt8($0) }
                    if bytes.count == 3 { AppModel.shared.midi.inject(bytes[0], bytes[1], bytes[2]) }
                case let command? where command.hasPrefix("mididev:"):
                    // mididev:<device>|<status>,<data1>,<data2> as if that device sent it.
                    let parts = command.dropFirst(8).split(separator: "|", maxSplits: 1)
                    let bytes = parts.count == 2 ? parts[1].split(separator: ",").compactMap { UInt8($0) } : []
                    if bytes.count == 3 { AppModel.shared.midi.inject(bytes[0], bytes[1], bytes[2], device: String(parts[0])) }
                case "drums": AppModel.shared.drums.togglePlay()
                case let command? where command.hasPrefix("mode:"):
                    UserDefaults.standard.set(String(command.dropFirst(5)), forKey: "mainMode")
                case let command? where command.hasPrefix("chordtype:"):
                    // chordtype:<diatonic|major|minor|7|m7|…> sets the header chord type.
                    if let c = ChordColor(rawValue: String(command.dropFirst(10))) { AppModel.shared.engine.chordType = c }
                case let command? where command.hasPrefix("synthslots:"):
                    try? Synth.shared.debugSlots().write(toFile: String(command.dropFirst(11)), atomically: true, encoding: .utf8)
                case let command? where command.hasPrefix("audioout:"):
                    // audioout:<uid|system> picks the output; audiodump:<file> lists devices and the one in use.
                    let uid = String(command.dropFirst(9))
                    AudioOutputs.shared.select(uid == "system" ? nil : uid)
                case let command? where command.hasPrefix("audiodump:"):
                    let o = AudioOutputs.shared
                    let lines = o.devices.map { "\($0.id) \($0.uid) | \($0.name)" }
                        + ["selected=\(o.selectedUID ?? "system") current=\(o.current?.name ?? "-") engine=\(Synth.shared.debugOutputDevice())"]
                    try? lines.joined(separator: "\n").write(toFile: String(command.dropFirst(10)), atomically: true, encoding: .utf8)
                case let command? where command.hasPrefix("loopcolor:"):
                    // loopcolor:<index>,<colour|-1>; looplock:<index>,<0|1>; loopdelete:<index> (tries to).
                    let p = command.dropFirst(10).split(separator: ",").compactMap { Int($0) }
                    let l = AppModel.shared.loops
                    if p.count == 2, l.loops.indices.contains(p[0]) { l.setColor(l.loops[p[0]].id, p[1] < 0 ? nil : p[1]) }
                case let command? where command.hasPrefix("looplock:"):
                    let p = command.dropFirst(9).split(separator: ",").compactMap { Int($0) }
                    let l = AppModel.shared.loops
                    if p.count == 2, l.loops.indices.contains(p[0]) { l.setLocked(l.loops[p[0]].id, p[1] == 1) }
                case let command? where command.hasPrefix("loopdelete:"):
                    let l = AppModel.shared.loops
                    if let i = Int(command.dropFirst(11)), l.loops.indices.contains(i) { l.remove(l.loops[i].id) }
                case "editloop":
                    AppModel.shared.loops.studioId = AppModel.shared.loops.loops.first?.id
                    UserDefaults.standard.set("editor", forKey: "mainMode")
                case let command? where command.hasPrefix("songdemo"):
                    // songdemo: drums A on bars 1–4 and the first loop on bars 1–4 (for testing).
                    let song = AppModel.shared.song
                    if let drumTrack = song.data.tracks.first(where: { $0.isDrums }) { song.add(.drums(0), track: drumTrack.id, at: 0) }
                    if let loop = AppModel.shared.loops.loops.first, let t = song.data.tracks.first(where: { !$0.isDrums }) {
                        song.add(.loop(loop.id), track: t.id, at: 0)
                    }
                case "songsections":
                    let song = AppModel.shared.song
                    song.addSection(at: 0); song.addSection(at: 4)
                case "songplay": AppModel.shared.song.togglePlay()
                case let command? where command.hasPrefix("sheetimport:"):
                    // sheetimport:<file>[,<file>…] imports songs; sheetopen:<index>; sheetseek:<chord>;
                    // sheettranspose:<semitones> (open song).
                    let urls = command.dropFirst(12).split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                    AppModel.shared.songbook.importFiles(urls)
                case let command? where command.hasPrefix("sheetopen:"):
                    let book = AppModel.shared.songbook
                    if let i = Int(command.dropFirst(10)), book.sheets.indices.contains(i) { book.open(book.sheets[i].id) }
                case let command? where command.hasPrefix("sheetseek:"):
                    if let i = Int(command.dropFirst(10)) { AppModel.shared.songbook.seek(i) }
                case let command? where command.hasPrefix("meter:"):
                    // meter:<seconds>,<file>[,<label>] appends «label peak=… rms=…» (main mix, before the limiter).
                    let p = command.dropFirst(6).split(separator: ",", maxSplits: 2).map(String.init)
                    if p.count >= 2, let seconds = Double(p[0]) {
                        let label = p.count > 2 ? p[2] : ""
                        Synth.shared.debugMeter(seconds: seconds) { line in
                            let text = "\(label) \(line)\n"
                            if let h = FileHandle(forWritingAtPath: p[1]) { h.seekToEndOfFile(); h.write(Data(text.utf8)); h.closeFile() }
                            else { try? text.write(toFile: p[1], atomically: true, encoding: .utf8) }
                        }
                    }
                case let command? where command.hasPrefix("graph:"):
                    try? Synth.shared.debugGraph().write(toFile: String(command.dropFirst(6)), atomically: true, encoding: .utf8)
                case "midiplay": AppModel.shared.songbook.player.toggle()
                case let command? where command.hasPrefix("midipractice:"):
                    // midipractice:<track|none>; mididump:<file> writes the player's state.
                    AppModel.shared.songbook.player.practiceTrack = Int(command.dropFirst(13))
                case let command? where command.hasPrefix("mididump:"):
                    let p = AppModel.shared.songbook.player
                    let line = "playing=\(p.playing) beat=\(String(format: "%.2f", p.beatNow())) bpm=\(p.bpm) expected=\(p.expected.sorted()) "
                        + "position=\(AppModel.shared.songbook.position) tracks=\(p.score?.tracks.map { p.route($0) } ?? [])"
                    try? line.write(toFile: String(command.dropFirst(9)), atomically: true, encoding: .utf8)
                case let command? where command.hasPrefix("sheetloop:"):
                    // sheetloop:<file> makes a loop from the open song and writes its events.
                    let loops = AppModel.shared.loops
                    if let id = AppModel.shared.songbook.makeLoop(into: loops), let loop = loops.loops.first(where: { $0.id == id }) {
                        let lines = ["\(loop.name) \(loop.tonic) \(loop.flavor) \(loop.lengthBeats)"]
                            + loop.events.map { "\($0.start) \($0.degree) \($0.color) +\($0.accidental)" }
                        try? lines.joined(separator: "\n").write(toFile: String(command.dropFirst(10)), atomically: true, encoding: .utf8)
                    }
                case let command? where command.hasPrefix("sheettranspose:"):
                    let book = AppModel.shared.songbook
                    if let t = Int(command.dropFirst(15)), let id = book.openId { book.setTranspose(id, t) }
                case "devices":
                    // Toggle the device drawing on every keyboard card.
                    let kb = AppModel.shared.keyboards
                    for c in kb.configs { kb.update(c.id) { $0.showDevice = $0.showDevice == true ? nil : true } }
                case let command? where command.hasPrefix("configure:"):
                    // configure:<index> opens that keyboard's settings; configure:none closes them.
                    let kb = AppModel.shared.keyboards
                    kb.editing = Int(command.dropFirst(10)).flatMap { kb.configs.indices.contains($0) ? kb.configs[$0].id : nil }
                case let command? where command.hasPrefix("pads:"):
                    if let mode = DrumMachine.PadMode(rawValue: String(command.dropFirst(5))) { AppModel.shared.drums.padMode = mode }
                case let command? where command.hasPrefix("tab:"):
                    UserDefaults.standard.set(String(command.dropFirst(4)), forKey: "sideTab")
                case let command? where command.hasPrefix("map:"):
                    switch command.dropFirst(4) {
                    case "launchkey": AppModel.shared.midi.autoMapLaunchkey()
                    case "keys": AppModel.shared.midi.autoMapKeys()
                    case "guided": AppModel.shared.midi.startGuided()
                    case "clear": AppModel.shared.midi.clearAll()
                    default: break
                    }
                case let command? where command.hasPrefix("theme:"):
                    if let theme = AppTheme(rawValue: String(command.dropFirst(6))) { Settings.shared.theme = theme }
                default: break
                }
            }
        }
        #endif
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
