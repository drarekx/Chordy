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
            mainWindow = makeWindow(title: AppInfo.name, size: NSSize(width: 1180, height: 760),
                                    minSize: NSSize(width: 980, height: 620), autosave: "MainWindow",
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
    /// `midi:<status>,<d1>,<d2>`, `tab:<loops|sound|midi>`, `map:<launchkey|keys|guided|clear>`, `record`, `play`.
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
                case "record": AppModel.shared.loops.toggleRecord()
                case "play": AppModel.shared.loops.togglePlay()
                case let command? where command.hasPrefix("midi:"):
                    // midi:<status>,<data1>,<data2> in decimal, e.g. midi:144,60,100.
                    let bytes = command.dropFirst(5).split(separator: ",").compactMap { UInt8($0) }
                    if bytes.count == 3 { AppModel.shared.midi.inject(bytes[0], bytes[1], bytes[2]) }
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
