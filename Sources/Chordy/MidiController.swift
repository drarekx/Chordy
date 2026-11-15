import Combine
import CoreMIDI
import Foundation

/// MIDI input mapped to Chordy actions ("MIDI learn" + presets), MIDI out of the
/// chords you play, and Launchkey pad lights. Mapping is saved to
/// `~/Library/Application Support/Chordy/midi-map.json`.
@MainActor
final class MidiController: ObservableObject {
    struct Monitor {
        let label: String
        let device: String
        let value: Int
        let action: String?
    }

    @Published private(set) var bindings = MidiBindings() { didSet { persist() } }
    @Published private(set) var inputs: [String] = []
    @Published private(set) var learning: MidiAction?
    @Published private(set) var guided = false
    @Published private(set) var awaitingKey = false
    @Published private(set) var lastEvent: Monitor?
    /// Light the Launchkey pads (switches it to InControl mode).
    @Published var lightsEnabled = UserDefaults.standard.bool(forKey: "launchkeyLights") {
        didSet {
            UserDefaults.standard.set(lightsEnabled, forKey: "launchkeyLights")
            applyInControl()
        }
    }
    /// Send played chords to the virtual "Chordy" MIDI source.
    @Published var sendToVirtual = UserDefaults.standard.object(forKey: "midiOut") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sendToVirtual, forKey: "midiOut") }
    }

    var hasLaunchkey: Bool { inputs.contains { $0.localizedCaseInsensitiveContains("launchkey") } }

    private let io = MidiIO()
    private let engine: ChordEngine
    private let sounds: SoundLibrary
    var shortcuts = KeyboardInput.Shortcuts()
    /// Loop state for the round-button lights.
    var isRecording: () -> Bool = { false }
    var isPlaying: () -> Bool = { false }

    /// Hold actions engaged per control id, so the release undoes the right one.
    private var holds: [String: MidiAction] = [:]
    private var lights: [Int: UInt8] = [:]
    private var lightsScheduled = false
    private var cancellables = Set<AnyCancellable>()

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("midi-map.json")
    }

    init(engine: ChordEngine, sounds: SoundLibrary) {
        self.engine = engine
        self.sounds = sounds
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            bindings = saved.reduce(into: MidiBindings()) { out, pair in
                if let control = MidiControl(id: pair.key), let action = MidiAction(rawValue: pair.value),
                   action.accepts(control) { out[pair.key] = action }
            }
        }
    }

    func start() {
        io.onMessage = { [weak self] in self?.receive($0) }
        io.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        io.start()
        engine.onNotes = { [weak self] notes, on in self?.forward(notes, on: on) }
        engine.objectWillChange.sink { [weak self] _ in self?.scheduleLights() }.store(in: &cancellables)
    }

    /// Leave the Launchkey in its normal mode on quit.
    func stop() {
        if lightsEnabled { sendInControl(false) }
    }

    private func devicesChanged() {
        inputs = io.inputNames
        releaseHolds()
        applyInControl()
    }

    /// Other state the pad lights show (loop record/play).
    func watch(_ publisher: ObservableObjectPublisher) {
        publisher.sink { [weak self] _ in self?.scheduleLights() }.store(in: &cancellables)
    }

    // MARK: - Mapping

    /// Controls bound to an action, for the mapping UI.
    func controls(for action: MidiAction) -> [MidiControl] {
        bindings.filter { $0.value == action }.compactMap { MidiControl(id: $0.key) }
            .sorted { ($0.kind.rawValue, $0.channel, $0.number) < ($1.kind.rawValue, $1.channel, $1.number) }
    }

    func startLearn(_ action: MidiAction) {
        guided = false
        awaitingKey = false
        learning = learning == action ? nil : action
    }

    func startGuided() {
        awaitingKey = false
        guided = true
        learning = MidiAction.allCases.first
    }

    func skip() { advance() }

    func cancelLearn() {
        guided = false
        awaitingKey = false
        learning = nil
    }

    func autoMapKeys() {
        cancelLearn()
        awaitingKey = true
    }

    func autoMapLaunchkey() {
        cancelLearn()
        apply(MidiPresets.launchkeyMK2())
    }

    func unbind(_ control: MidiControl) {
        if let held = holds.removeValue(forKey: control.id) { setHold(held, false) }
        bindings[control.id] = nil
    }

    func clearAll() {
        releaseHolds()
        cancelLearn()
        bindings = [:]
    }

    private func apply(_ preset: MidiBindings) {
        releaseHolds()
        bindings.merge(preset) { _, new in new }
    }

    private func advance() {
        guard guided, let current = learning, let i = MidiAction.allCases.firstIndex(of: current) else {
            learning = nil
            return
        }
        let next = MidiAction.allCases.index(after: i)
        if next < MidiAction.allCases.endIndex {
            learning = MidiAction.allCases[next]
        } else {
            learning = nil
            guided = false
        }
    }

    /// Learn takes the first deliberate gesture: a press, a knob turn, or a wheel moved off centre.
    private func tryLearn(_ event: MidiEvent) -> Bool {
        guard let action = learning, action.accepts(event.control) else { return false }
        if action.kind != .range && !event.pressed { return false }
        if event.control.kind == .pb && abs(event.value - 0.5) < 0.1 { return false }
        bindings[event.control.id] = action
        advance()
        return true
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(bindings.mapValues(\.rawValue))
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Chordy: could not save MIDI mapping: \(error)")
        }
    }

    // MARK: - Input

    #if DEBUG
    /// Debug hook: feed a raw message as if a device sent it.
    func inject(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        receive(MidiIO.Message(status: status, data1: data1, data2: data2, device: "debug"))
    }
    #endif

    private func receive(_ message: MidiIO.Message) {
        guard let event = MidiEvent(status: message.status, data1: message.data1, data2: message.data2) else { return }
        let id = event.control.id

        if awaitingKey, event.control.kind == .note, event.pressed {
            awaitingKey = false
            apply(MidiPresets.keys(channel: event.control.channel))
            return
        }
        if learning != nil {
            if let held = holds.removeValue(forKey: id) { setHold(held, false) }
            if tryLearn(event) { return }
        }

        let action = bindings[id]
        lastEvent = Monitor(label: event.control.label, device: message.device,
                            value: Int((event.value * 127).rounded()), action: action?.label)
        guard let action else { return }
        dispatch(id, action, event)
    }

    private func dispatch(_ id: String, _ action: MidiAction, _ event: MidiEvent) {
        switch action.kind {
        case .range:
            setRange(action, event.value)
        case .press:
            if event.pressed { firePress(action) }
        case .hold:
            if event.pressed, holds[id] == nil {
                holds[id] = action
                setHold(action, true)
            } else if !event.pressed, let held = holds.removeValue(forKey: id) {
                setHold(held, false)
            }
        }
    }

    private func setHold(_ action: MidiAction, _ pressed: Bool) {
        if let degree = action.degree {
            pressed ? engine.pressDegree(degree) : engine.releaseDegree(degree)
            return
        }
        switch action {
        case .colorUp: engine.setDirectionKey("w", pressed: pressed)
        case .colorDown: engine.setDirectionKey("s", pressed: pressed)
        case .colorLeft: engine.setDirectionKey("a", pressed: pressed)
        case .colorRight: engine.setDirectionKey("d", pressed: pressed)
        case .octaveDown: engine.setOctaveDown(pressed)
        default: break
        }
    }

    private func firePress(_ action: MidiAction) {
        switch action {
        case .tonicDown: engine.shiftTonic(-1)
        case .tonicUp: engine.shiftTonic(1)
        case .modePrev: engine.shiftFlavor(-1)
        case .modeNext: engine.shiftFlavor(1)
        case .bpmDown: engine.setBpm(engine.bpm - 1)
        case .bpmUp: engine.setBpm(engine.bpm + 1)
        case .record: shortcuts.toggleRecord()
        case .play: shortcuts.togglePlay()
        case .stop:
            shortcuts.panic()
            engine.stopAll()
        case .soundPrev: sounds.selectNext(-1)
        case .soundNext: sounds.selectNext(1)
        default: break
        }
    }

    private func setRange(_ action: MidiAction, _ v: Double) {
        let pick = { (count: Int) in min(count - 1, Int(v * Double(count))) }
        switch action {
        case .bpmSet:
            let range = ChordEngine.bpmRange
            engine.setBpm(range.lowerBound + Int((v * Double(range.upperBound - range.lowerBound)).rounded()))
        case .tonicSet:
            let note = Note.allCases[pick(12)]
            if engine.tonic != note { engine.tonic = note }
        case .modeSet:
            let flavor = Flavor.allCases[pick(Flavor.allCases.count)]
            if engine.flavor != flavor { engine.flavor = flavor }
        case .pitchBend:
            let semitones = (v - 0.5) * 4
            Synth.shared.setBend(abs(semitones) < 0.02 ? 0 : semitones)
            if sendToVirtual {
                let raw = Int((v * 16383).rounded())
                io.sendVirtual(0xE0, UInt8(raw & 0x7F), UInt8(raw >> 7))
            }
        default:
            editSound(action, v)
        }
    }

    /// Knobs edit the current sound (filter, levels and vibrato apply to held notes too).
    private func editSound(_ action: MidiAction, _ v: Double) {
        var p = sounds.draft
        typealias R = Patch.Range
        func lerp(_ r: ClosedRange<Double>, _ t: Double) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * t }
        switch action {
        case .cutoff: p.filter.cutoff = R.cutoff.lowerBound * pow(R.cutoff.upperBound / R.cutoff.lowerBound, v)
        case .resonance: p.filter.resonance = lerp(R.resonance, v * v)
        case .filterEnv: p.filter.envAmount = lerp(R.envAmount, v)
        case .attack: p.envelope.attack = lerp(R.attack, v * v * v)
        case .decay: p.envelope.decay = lerp(R.decay, v * v)
        case .sustain: p.envelope.sustain = v
        case .release: p.envelope.release = lerp(R.release, v * v)
        case .vibratoDepth: p.vibrato.depth = lerp(R.vibratoDepth, v)
        case .vibratoRate: p.vibrato.rate = lerp(R.vibratoRate, v)
        case .volume: p.volume = v
        default: return
        }
        sounds.draft = p
    }

    private func releaseHolds() {
        for action in holds.values { setHold(action, false) }
        holds.removeAll()
    }

    // MARK: - Output

    /// Played chords → virtual source, channel 1.
    private func forward(_ notes: [Int], on: Bool) {
        guard sendToVirtual else { return }
        for note in notes where (0...127).contains(note) {
            io.sendVirtual(on ? 0x90 : 0x80, UInt8(note), on ? 100 : 0)
        }
    }

    // MARK: - Launchkey lights

    /// The Launchkey port that accepts InControl messages (pad colors).
    private var launchkeyDestination: MIDIEndpointRef? {
        let all = io.destinations().filter { $0.1.localizedCaseInsensitiveContains("launchkey") }
        return (all.first { $0.1.localizedCaseInsensitiveContains("incontrol") } ?? all.last)?.0
    }

    private func applyInControl() {
        guard hasLaunchkey else { return }
        sendInControl(lightsEnabled)
        lights.removeAll()
        if lightsEnabled { scheduleLights() }
    }

    /// Note 12 on channel 1: velocity 127 enters InControl mode, 0 leaves it.
    private func sendInControl(_ on: Bool) {
        guard let destination = launchkeyDestination else { return }
        io.send(0x90, 12, on ? 127 : 0, to: destination)
    }

    private func scheduleLights() {
        guard lightsEnabled, !lightsScheduled else { return }
        lightsScheduled = true
        // objectWillChange fires before the change: read the state on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.lightsScheduled = false
            self?.updateLights()
        }
    }

    /// Palette indices (velocity → color) of the Launchkey MK2 pads.
    private enum Pad {
        static let off: UInt8 = 0
        static let white: UInt8 = 3
        static let red: UInt8 = 5
        static let dimRed: UInt8 = 7
        static let yellow: UInt8 = 13
        static let green: UInt8 = 21
        static let dimGreen: UInt8 = 23
        static let cyan: UInt8 = 37
        static let blue: UInt8 = 45
        static let dimBlue: UInt8 = 47
        static let purple: UInt8 = 53
        static let dimPurple: UInt8 = 55
    }

    func updateLights() {
        guard lightsEnabled, let destination = launchkeyDestination else { return }
        var wanted: [Int: UInt8] = [:]
        let sounding = Set(engine.sounding.map(\.degree))
        let held = held(engine.direction)
        for (i, action) in MidiPresets.bottomPads.enumerated() {
            let note = MidiPresets.inControlBottom[i]
            if let degree = action.degree {
                wanted[note] = sounding.contains(degree) ? Pad.white : Pad.dimBlue
            } else {
                wanted[note] = engine.octaveDown ? Pad.purple : Pad.dimPurple
            }
        }
        for (i, action) in MidiPresets.topPads.enumerated() {
            let note = MidiPresets.inControlTop[i]
            switch action {
            case .colorUp, .colorDown, .colorLeft, .colorRight:
                wanted[note] = held.contains(action) ? Pad.yellow : Pad.cyan
            case .tonicDown, .tonicUp: wanted[note] = Pad.green
            case .modeNext: wanted[note] = Pad.blue
            case .stop: wanted[note] = Pad.dimRed
            default: wanted[note] = Pad.off
            }
        }
        wanted[MidiPresets.roundTop] = isRecording() ? Pad.red : Pad.dimRed
        wanted[MidiPresets.roundBottom] = isPlaying() ? Pad.green : Pad.dimGreen

        for (note, color) in wanted where lights[note] != color {
            io.send(0x90, UInt8(note), color, to: destination)
            lights[note] = color
        }
    }

    /// Color pads lit by the current direction (diagonals light two).
    private func held(_ direction: Direction?) -> Set<MidiAction> {
        guard let direction else { return [] }
        var out = Set<MidiAction>()
        if direction.keys.contains("w") { out.insert(.colorUp) }
        if direction.keys.contains("s") { out.insert(.colorDown) }
        if direction.keys.contains("a") { out.insert(.colorLeft) }
        if direction.keys.contains("d") { out.insert(.colorRight) }
        return out
    }
}
