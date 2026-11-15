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
    /// Layout of the old single "keys zone" (before per-keyboard settings), for the migration.
    private let legacyLayout: KeyLayout = {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "keysLayout").flatMap(KeyLayout.init(rawValue:)) { return saved }
        return d.object(forKey: "keysChromatic") as? Bool == false ? .degrees : .chromatic
    }()
    /// Last chord layout per keyboard, for the Notes ⇄ Chords button.
    private var lastChordLayout: [String: KeyLayout] = [:]

    /// Notes ⇄ chords on the Launchkey's keyboard (or the first one).
    func toggleKeysMode() {
        guard let keyboard = keyboards.configs.first(where: { $0.device.localizedCaseInsensitiveContains("launchkey") })
                ?? keyboards.configs.first else { return }
        releaseKeys()
        keyboards.update(keyboard.id) { c in
            if c.layout == .notes {
                c.layout = lastChordLayout[c.id] ?? .chromatic
            } else {
                lastChordLayout[c.id] = c.layout
                c.layout = .notes
            }
        }
    }
    @Published private(set) var lastEvent: Monitor?
    /// Live state of each device for the drawings, in its own object so a key press only
    /// redraws the drawings (not every view that watches the controller).
    let live = LiveMIDI()
    /// Connected inputs, observable on their own (cards and header only care about this).
    let devices = DeviceList()
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
    /// Sounds Notes-layout keys on the MIDI thread (see `LiveFastPath`).
    let fastPath = LiveFastPath()
    private var fastPathScheduled = false
    private let engine: ChordEngine
    private let sounds: SoundLibrary
    private let instruments: InstrumentLibrary
    private let keyboards: Keyboards
    private let drums: DrumMachine
    var shortcuts = KeyboardInput.Shortcuts()
    /// Loop state for the round-button lights.
    var isRecording: () -> Bool = { false }
    var isPlaying: () -> Bool = { false }

    /// Hold actions engaged per control id, so the release undoes the right one.
    private var holds: [String: MidiAction] = [:]
    /// Keys-zone degrees held per control id, with their octave.
    private var keyHolds: [String: HeldChord] = [:]
    private var lights: [Int: UInt8] = [:]
    private var lightsScheduled = false
    private var cancellables = Set<AnyCancellable>()

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("midi-map.json")
    }

    init(engine: ChordEngine, sounds: SoundLibrary, instruments: InstrumentLibrary, keyboards: Keyboards,
         drums: DrumMachine) {
        self.engine = engine
        self.sounds = sounds
        self.instruments = instruments
        self.keyboards = keyboards
        self.drums = drums
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            bindings = saved.reduce(into: MidiBindings()) { out, pair in
                if let control = MidiControl(id: pair.key), let action = MidiAction(rawValue: pair.value),
                   action.accepts(control) { out[pair.key] = action }
            }
            migrateKeysPreset()
            migrateRoundButtons()
        }
    }

    /// The round buttons beside the pads now switch the keyboard (top) and the pads (bottom);
    /// record and play stay on the transport buttons.
    private func migrateRoundButtons() {
        let top = MidiControl(.note, channel: 1, number: MidiPresets.roundTop).id
        let bottom = MidiControl(.note, channel: 1, number: MidiPresets.roundBottom).id
        if bindings[top] == .record { bindings[top] = .keysMode }
        if bindings[bottom] == .play { bindings[bottom] = .padsMode }
    }

    /// Earlier versions saved the Keys preset as one binding per note, without octaves.
    /// Turn such a channel into a keys zone so both octaves (and the octave buttons) work.
    private func migrateKeysPreset() {
        for channel in 1...16 {
            let ids = MidiPresets.keysRange.map { MidiControl(.note, channel: channel, number: $0).id }
            let matching = ids.filter { id in
                guard let control = MidiControl(id: id), let action = bindings[id] else { return false }
                return MidiPresets.keyActions[control.number % 12] == action
            }
            guard matching.count >= 84 else { continue }
            for id in matching { bindings[id] = nil }
        }
    }

    func start() {
        io.onMessage = { [weak self] in self?.receive($0) }
        let fast = fastPath
        io.fastPath = { status, d1, d2, device in fast.handle(status: status, data1: d1, data2: d2, device: device) }
        let settings: [AnyPublisher<Void, Never>] = [
            $learning.map { _ in () }.eraseToAnyPublisher(), $awaitingKey.map { _ in () }.eraseToAnyPublisher(),
            $bindings.map { _ in () }.eraseToAnyPublisher(), keyboards.objectWillChange.eraseToAnyPublisher(),
            instruments.objectWillChange.eraseToAnyPublisher(),
        ]
        for publisher in settings {
            publisher.sink { [weak self] _ in self?.scheduleFastPath() }.store(in: &cancellables)
        }
        refreshFastPath()
        io.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        io.start()
        engine.onNotes = { [weak self] notes, on in self?.forward(notes, on: on) }
        engine.objectWillChange.sink { [weak self] _ in self?.scheduleLights() }.store(in: &cancellables)
    }

    private func scheduleFastPath() {
        guard !fastPathScheduled else { return }
        fastPathScheduled = true
        // objectWillChange fires before the change: read the settings on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.fastPathScheduled = false
            self?.refreshFastPath()
        }
    }

    /// What the MIDI thread may play on its own: Notes-layout keyboards with a sampled sound,
    /// and never while something is being learned.
    private func refreshFastPath() {
        var snap = LiveFastPath.Snapshot()
        snap.enabled = learning == nil && !awaitingKey && keyboards.learningZone == nil
        snap.keyboards = keyboards.configs
        for config in keyboards.configs where config.layout == .notes && !InstrumentLibrary.isSynth(config.instrument) {
            guard let player = instruments.player(for: config.route) else { continue }
            player.setLevel(config.volume / 0.85)
            snap.gates[config.id] = player.gate
        }
        snap.pedalDevices = Set(keyboards.configs.map(\.device).filter { _ in
            !(1...16).contains { bindings[MidiControl(.cc, channel: $0, number: 64).id] != nil }
        })
        fastPath.update(snap)
    }

    /// Leave the Launchkey in its normal mode on quit.
    func stop() {
        if lightsEnabled { sendInControl(false) }
    }

    private func devicesChanged() {
        inputs = io.inputNames
        if devices.names != inputs { devices.names = inputs }
        keyboards.adopt(sources: inputs, legacy: (legacyLayout, instruments.selectedId))
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
    func inject(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, device: String = "debug") {
        receive(MidiIO.Message(status: status, data1: data1, data2: data2, device: device, time: now()))
    }
    #endif

    private func receive(_ message: MidiIO.Message) {
        // Program change from a keyboard (a Yamaha's voice buttons): favorite sound 1–8 on it.
        if message.status & 0xF0 == 0xC0, let keyboard = keyboards.configs.first(where: { $0.device == message.device }) {
            keyboards.markActive(keyboard.id)
            keyboards.pickFavorite(Int(message.data1) % keyboards.favorites.count, for: keyboard.id)
            lastEvent = Monitor(label: tr("Cambio de programa %d", Int(message.data1) + 1), device: message.device,
                                value: Int(message.data1), action: Keyboards.soundName(keyboards.config(keyboard.id)?.instrument ?? ""))
            return
        }
        guard let event = MidiEvent(status: message.status, data1: message.data1, data2: message.data2) else { return }
        let id = event.control.id
        let device = message.device
        trackLive(event, device: device)
        let isNote = event.control.kind == .note

        if awaitingKey, isNote, event.pressed {
            awaitingKey = false
            keyboards.adopt(sources: [device], legacy: nil)
            return
        }
        if isNote, event.pressed, keyboards.learn(device: device, note: event.control.number) { return }
        if learning != nil {
            if let held = holds.removeValue(forKey: id) { setHold(held, false) }
            if tryLearn(event) { return }
        }

        // A keyboard's keys play its own sound; a key mapped explicitly still wins.
        if isNote, bindings[id] == nil || keyboards.hasKeyboard(on: device),
           let keyboard = keyboards.match(device: device, channel: event.control.channel, note: event.control.number) {
            playKeyboard(keyboard, event, device: device, message: message)
            return
        }
        // Sustain pedal of a keyboard, unless mapped to something else.
        if event.control.kind == .cc, event.control.number == 64, bindings[id] == nil, keyboards.hasKeyboard(on: device) {
            lastEvent = Monitor(label: event.control.label, device: device,
                                value: Int((event.value * 127).rounded()), action: tr("Pedal de sustain"))
            engine.output.setSustain(event.pressed)
            return
        }
        // Launchkey pads in drum modes.
        if isNote, drums.padMode != .chords, let pad = padIndex(event.control, device: device) {
            lastEvent = Monitor(label: event.control.label, device: device,
                                value: Int((event.value * 127).rounded()), action: padLabel(pad))
            if event.pressed { handlePad(pad, velocity: max(1, Int((event.value * 127).rounded()))) }
            return
        }

        let action = bindings[id]
        lastEvent = Monitor(label: event.control.label, device: device,
                            value: Int((event.value * 127).rounded()), action: action?.label)
        guard let action else { return }
        dispatch(id, action, event)
    }

    // MARK: - Live state (device drawings)

    private func trackLive(_ event: MidiEvent, device: String) {
        let key = "\(device)|\(event.control.id)"
        switch event.control.kind {
        case .note:
            var held = live.notes[device] ?? []
            if event.pressed { held.insert(event.control.number) } else { held.remove(event.control.number) }
            live.notes[device] = held
            if event.pressed { live.pressed.insert(key) } else { live.pressed.remove(key) }
            if event.pressed, event.control.channel != 10 {
                let base = live.keyWindow[device] ?? 48
                let n = event.control.number
                if n < base || n > base + 24 { live.keyWindow[device] = n - ((n - base) % 12 + 12) % 12 - (n < base ? 0 : 12) }
            }
        case .cc, .pb:
            live.values[key] = event.value
            if event.control.kind == .cc {
                if event.pressed { live.pressed.insert(key) } else { live.pressed.remove(key) }
            }
        }
    }

    /// What a control does, for the drawings.
    func mapping(_ control: MidiControl) -> String? { bindings[control.id]?.label }

    /// Pad 0…15: label and color index for the drawing, by pad mode.
    func padInfo(_ pad: Int) -> (label: String, lit: Bool) {
        switch drums.padMode {
        case .chords:
            let note = pad < 8 ? MidiPresets.inControlTop[pad] : MidiPresets.inControlBottom[pad - 8]
            let basic = pad < 8 ? MidiPresets.basicTop[pad] : MidiPresets.basicBottom[pad - 8]
            let action = bindings[MidiControl(.note, channel: 1, number: note).id]
                ?? bindings[MidiControl(.note, channel: 10, number: basic).id]
            return (action.map(Self.shortLabel) ?? "", false)
        case .steps:
            let on = drums.pattern.steps[drums.track.rawValue][pad] > 0
            return ("\(pad + 1)", on)
        case .play:
            return (pad < 8 ? DrumTrack.allCases[pad].short : DrumPattern.names[pad - 8],
                    pad >= 8 && pad - 8 == drums.selected)
        }
    }

    static func shortLabel(_ action: MidiAction) -> String {
        if let degree = action.degree { return Music.numeral(degree, AppModel.shared.engine.flavor) }
        switch action {
        case .colorUp: return "maj"
        case .colorDown: return "min"
        case .colorLeft: return "dim"
        case .colorRight: return "aug"
        case .octaveDown: return "8vb"
        case .tonicDown: return tr("Tono−")
        case .tonicUp: return tr("Tono+")
        case .modeNext, .modePrev: return tr("Modo")
        case .stop: return "■"
        case .record: return "●"
        case .play: return "▶"
        case .keysMode: return tr("Notas")
        case .padsMode: return tr("Pads")
        case .soundPrev: return "◀"
        case .soundNext: return "▶"
        default: return action.label
        }
    }

    /// What a key plays on a keyboard, for its drawing (nil: nothing worth printing).
    func keyLabel(_ keyboard: KeyboardConfig, note raw: Int) -> String? {
        let note = raw + keyboard.octave * 12
        switch keyboard.layout {
        case .notes:
            return note % 12 == 0 ? "C\(note / 12 - 1)" : nil
        case .chromatic:
            let chord = chromaticChord(note: note)
            return Music.symbol(engine.tonic, chord.degree, engine.flavor, .major, accidental: chord.accidental)
        case .degrees:
            guard let action = MidiPresets.keyActions[((note % 12) + 12) % 12] else { return nil }
            return Self.shortLabel(action)
        }
    }

    /// Plays a key on its keyboard: notes, chromatic chords or degrees, with its sound,
    /// octave, velocity curve and volume.
    private func playKeyboard(_ keyboard: KeyboardConfig, _ event: MidiEvent, device: String,
                              message: MidiIO.Message? = nil) {
        let key = "\(keyboard.id):\(event.control.number)"
        let arrival = message.flatMap { $0.time > 0 ? $0.time : nil }
        let note = event.control.number + keyboard.octave * 12
        let raw = max(1, Int((event.value * 127).rounded()))
        // Sampled sounds take the keyboard's volume as gain, so the velocity (what gets recorded
        // into loops) is just the curved key velocity; the synth still scales velocity.
        let curved = keyboard.curve.apply(raw)
        let sampled = !InstrumentLibrary.isSynth(SoundRoute.parse(keyboard.route).instrument)
        if sampled, event.pressed { instruments.player(for: keyboard.route)?.setLevel(keyboard.volume / 0.85) }
        let velocity = sampled ? curved
                               : max(1, min(127, Int((Double(curved) * keyboard.volume / 0.85).rounded())))
        lastEvent = Monitor(label: event.control.label, device: device, value: raw, action: keyboard.name)
        if event.pressed { keyboards.markActive(keyboard.id) }
        switch keyboard.layout {
        case .notes:
            let presounded = message?.presounded ?? false
            if event.pressed {
                engine.playNote(key: key, midi: note, velocity: velocity, instrument: keyboard.route, owner: keyboard.id,
                                presounded: presounded, time: message.flatMap { $0.time > 0 ? $0.time : nil })
            } else {
                engine.stopNote(key: key, time: message.flatMap { $0.time > 0 ? $0.time : nil })
            }
        case .chromatic:
            if event.pressed, keyHolds[key] == nil {
                var chord = chromaticChord(note: note)
                chord.owner = keyboard.id
                keyHolds[key] = chord
                engine.press(chord, chromatic: true, velocity: velocity, instrument: keyboard.route, time: arrival)
            } else if !event.pressed, let held = keyHolds.removeValue(forKey: key) {
                engine.release(held, time: arrival)
            }
        case .degrees:
            guard let action = MidiPresets.keyActions[((note % 12) + 12) % 12] else { return }
            guard let degree = action.degree else { return dispatch(key, action, event) }
            if event.pressed, keyHolds[key] == nil {
                let chord = HeldChord(degree: degree, octave: MidiPresets.octave(ofNote: note), owner: keyboard.id)
                keyHolds[key] = chord
                engine.press(chord, velocity: velocity, instrument: keyboard.route, time: arrival)
            } else if !event.pressed, let held = keyHolds.removeValue(forKey: key) {
                engine.release(held, time: arrival)
            }
        }
    }

    /// The chord rooted on a key's real note, at the key's own pitch.
    private func chromaticChord(note: Int) -> HeldChord {
        let (degree, accidental) = Music.root(ofPitchClass: ((note % 12) + 12) % 12, engine.tonic, engine.flavor)
        let rootFromC4 = engine.tonic.index + Music.rootInterval(degree, engine.flavor) + accidental
        let octave = Int((Double(note - 60 - rootFromC4) / 12).rounded(.down))
        return HeldChord(degree: degree, octave: octave, accidental: accidental)
    }

    // MARK: - Drum pads

    /// Pad 0…15 (top row left → right, then bottom row) from the InControl port or basic-mode pads.
    private func padIndex(_ control: MidiControl, device: String) -> Int? {
        guard device.localizedCaseInsensitiveContains("launchkey") || device == "debug" else { return nil }
        if control.channel == 1, device.localizedCaseInsensitiveContains("incontrol") || device == "debug" {
            if let i = MidiPresets.inControlTop.firstIndex(of: control.number) { return i }
            if let i = MidiPresets.inControlBottom.firstIndex(of: control.number) { return 8 + i }
        }
        if control.channel == 10 {
            if let i = MidiPresets.basicTop.firstIndex(of: control.number) { return i }
            if let i = MidiPresets.basicBottom.firstIndex(of: control.number) { return 8 + i }
        }
        return nil
    }

    private func padLabel(_ pad: Int) -> String {
        switch drums.padMode {
        case .steps: return tr("Paso %d · %@", pad + 1, drums.track.label)
        case .play: return pad < 8 ? DrumTrack.allCases[pad].label : tr("Patrón %@", DrumPattern.names[pad - 8])
        case .chords: return ""
        }
    }

    /// Steps: the 16 pads are the 16 steps of the selected track. Play: top row hits the
    /// eight drums, bottom row launches patterns A–H.
    private func handlePad(_ pad: Int, velocity: Int) {
        switch drums.padMode {
        case .steps: drums.toggleStep(drums.track, pad)
        case .play: pad < 8 ? drums.hit(DrumTrack.allCases[pad], velocity: velocity) : drums.launch(pad - 8)
        case .chords: break
        }
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
        case .record: drums.padMode == .chords ? shortcuts.toggleRecord() : drums.toggleRecord()
        case .play: drums.padMode == .chords ? shortcuts.togglePlay() : drums.togglePlay()
        case .padsMode: cyclePadMode()
        case .stop:
            shortcuts.panic()
            engine.stopAll()
        case .soundPrev: drums.padMode == .chords ? keyboards.stepFavorite(-1) : drums.selectTrack(-1)
        case .soundNext: drums.padMode == .chords ? keyboards.stepFavorite(1) : drums.selectTrack(1)
        case .keysMode: toggleKeysMode()
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
            instruments.forEachLivePlayer { $0.setBend(abs(semitones) < 0.02 ? 0 : semitones) }
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
        if action == .volume { instruments.knobVolume = v; instruments.forEachPlayer { $0.setVolume(v) } }
        if action == .vibratoDepth { instruments.forEachLivePlayer { $0.setModulation(v) } }
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
        releaseKeys()
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
        if drums.padMode != .chords {
            drumLights(&wanted)
            for (note, color) in wanted where lights[note] != color {
                io.send(0x90, UInt8(note), color, to: destination)
                lights[note] = color
            }
            return
        }
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
        wanted[MidiPresets.roundTop] = Pad.dimPurple
        wanted[MidiPresets.roundBottom] = Pad.dimGreen

        for (note, color) in wanted where lights[note] != color {
            io.send(0x90, UInt8(note), color, to: destination)
            lights[note] = color
        }
    }

    /// Steps: lit steps in amber, the playing step white. Play: drums green (white on hit),
    /// patterns blue (the selected one bright). Round buttons: keyboard mode and pad mode.
    private func drumLights(_ wanted: inout [Int: UInt8]) {
        let pads = MidiPresets.inControlTop + MidiPresets.inControlBottom
        switch drums.padMode {
        case .steps:
            let lane = drums.pattern.steps[drums.track.rawValue]
            for (i, note) in pads.enumerated() {
                if drums.playing && drums.step == i { wanted[note] = Pad.white } else {
                    wanted[note] = lane[i] > 0 ? Pad.yellow : (i % 4 == 0 ? Pad.dimRed : Pad.off)
                }
            }
        case .play:
            for (i, note) in MidiPresets.inControlTop.enumerated() {
                wanted[note] = drums.flash.contains(DrumTrack.allCases[i]) ? Pad.white : Pad.green
            }
            for (i, note) in MidiPresets.inControlBottom.enumerated() {
                wanted[note] = i == drums.selected ? (drums.playing ? Pad.white : Pad.blue)
                    : (drums.patterns[i].isEmpty ? Pad.off : Pad.dimBlue)
            }
        case .chords:
            break
        }
        wanted[MidiPresets.roundTop] = Pad.dimPurple
        wanted[MidiPresets.roundBottom] = drums.padMode == .steps ? Pad.yellow : Pad.green
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

    private func releaseKeys() {
        fastPath.allOff()
        for chord in keyHolds.values { engine.release(chord) }
        keyHolds.removeAll()
        for key in engine.heldNotes.keys { engine.stopNote(key: key) }
    }

    /// Chords → Steps → Play → Chords (round button below the pads).
    func cyclePadMode() {
        releaseHolds()
        let all = DrumMachine.PadMode.allCases
        drums.padMode = all[(all.firstIndex(of: drums.padMode)! + 1) % all.count]
        lights.removeAll()
        scheduleLights()
    }
}

/// Raw keys held, control values (0…1) and pressed buttons/pads per device, keyed
/// "<device>|<control id>", for the device drawings.
@MainActor
final class LiveMIDI: ObservableObject {
    @Published var notes: [String: Set<Int>] = [:]
    @Published var values: [String: Double] = [:]
    @Published var pressed: Set<String> = []
    /// Lowest note of the 25-key window per device (follows the hardware octave buttons).
    @Published var keyWindow: [String: Int] = [:]

    func value(_ device: String, _ control: MidiControl) -> Double? { values["\(device)|\(control.id)"] }
    func isPressed(_ device: String, _ control: MidiControl) -> Bool { pressed.contains("\(device)|\(control.id)") }
}

/// MIDI inputs connected now.
@MainActor
final class DeviceList: ObservableObject {
    @Published var names: [String] = []
}
