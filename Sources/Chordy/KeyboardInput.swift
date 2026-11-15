import AppKit

/// Mac keyboard → chords, while a Chordy window is active (no permissions needed).
///
///   J U K I L O ;  degrees I–vii (hold)
///   W A S D        chord color (hold; two = diagonal)
///   Space          octave down (hold)
///   Z / C          key down / up
///   Q / E          mode prev / next
///   + / -          bpm
///   R              record loop
///   P              play / stop loop
///   Esc            stop everything
@MainActor
final class KeyboardInput {
    struct Shortcuts {
        var toggleRecord: () -> Void = {}
        var togglePlay: () -> Void = {}
        var panic: () -> Void = {}
    }

    private let engine: ChordEngine
    var shortcuts = Shortcuts()
    private var monitor: Any?
    private var heldDegreeKeys = Set<Character>()
    /// Only what this keyboard pressed is released on blur; MIDI holds keep working in the background.
    private var heldDirectionKeys = Set<Character>()
    private var holdingOctave = false

    private static let directionKeys: Set<Character> = ["w", "a", "s", "d"]
    private static let escape: UInt16 = 53

    init(engine: ChordEngine) {
        self.engine = engine
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        // keyUp never arrives if focus leaves mid-press: release everything.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        }
    }

    func releaseAll() {
        for key in heldDegreeKeys { if let degree = Music.degreeKeys[key] { engine.releaseDegree(degree) } }
        heldDegreeKeys.removeAll()
        for key in heldDirectionKeys { engine.setDirectionKey(key, pressed: false) }
        heldDirectionKeys.removeAll()
        if holdingOctave { engine.setOctaveDown(false) }
        holdingOctave = false
    }

    /// Returns true when the event was used (so it doesn't beep or reach other views).
    private func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return false }
        // Typing in a text field (sound or loop names) keeps the keys.
        if event.window?.firstResponder is NSText { return false }
        let down = event.type == .keyDown

        if event.keyCode == Self.escape {
            if !down {
                shortcuts.panic()
                engine.stopAll()
                heldDegreeKeys.removeAll()
            }
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased().first else { return false }

        if let degree = Music.degreeKeys[key] {
            if down {
                if heldDegreeKeys.insert(key).inserted { engine.pressDegree(degree) }
            } else {
                heldDegreeKeys.remove(key)
                engine.releaseDegree(degree)
            }
            return true
        }
        if Self.directionKeys.contains(key) {
            if down { heldDirectionKeys.insert(key) } else { heldDirectionKeys.remove(key) }
            engine.setDirectionKey(key, pressed: down)
            return true
        }
        if key == " " {
            holdingOctave = down
            engine.setOctaveDown(down)
            return true
        }
        guard down else { return ["z", "c", "q", "e", "+", "=", "-", "_", "r", "p"].contains(key) }
        if event.isARepeat { return true }

        switch key {
        case "z": engine.shiftTonic(-1)
        case "c": engine.shiftTonic(1)
        case "q": engine.shiftFlavor(-1)
        case "e": engine.shiftFlavor(1)
        case "+", "=": engine.setBpm(engine.bpm + 1)
        case "-", "_": engine.setBpm(engine.bpm - 1)
        case "r": shortcuts.toggleRecord()
        case "p": shortcuts.togglePlay()
        default: return false
        }
        return true
    }
}
