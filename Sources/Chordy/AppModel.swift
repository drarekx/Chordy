import Combine
import Foundation

/// Everything the windows share: chord engine, sounds and inputs.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let engine = ChordEngine()
    let sounds = SoundLibrary()
    let instruments = InstrumentLibrary()
    let keyboards: Keyboards
    let drums: DrumMachine
    let remote: RemoteServer
    let keyboard: KeyboardInput
    let midi: MidiController
    let loops: Loops
    let song: Song
    private(set) lazy var projects = Projects(model: self)

    private init() {
        keyboard = KeyboardInput(engine: engine)
        keyboards = Keyboards(instruments: instruments)
        drums = DrumMachine(engine: engine, instruments: instruments)
        midi = MidiController(engine: engine, sounds: sounds, instruments: instruments, keyboards: keyboards, drums: drums)
        loops = Loops(engine: engine, instruments: instruments)
        instruments.effects = { [unowned keyboards, unowned loops] bus in
            if bus.hasPrefix("kb:") { return keyboards.config(String(bus.dropFirst(3)))?.effects }
            if bus.hasPrefix("loop:") { return loops.effects(for: String(bus.dropFirst(5))) }
            return nil
        }
        engine.output = SoundOutput(instruments: instruments, patch: { [unowned sounds] id in sounds.patch(for: id) })
        let shortcuts = KeyboardInput.Shortcuts(
            toggleRecord: { [unowned loops] in loops.toggleRecord() },
            togglePlay: { [unowned loops] in loops.togglePlay() },
            panic: { [unowned loops] in loops.stopPlayback() },
            pickFavorite: { [unowned keyboards] slot in keyboards.pickFavorite(slot) })
        keyboard.shortcuts = shortcuts
        midi.shortcuts = shortcuts
        midi.isRecording = { [unowned loops] in loops.isRecording }
        midi.isPlaying = { [unowned loops] in loops.isPlaying }
        midi.watch(loops.objectWillChange)
        midi.watch(drums.objectWillChange)
        remote = RemoteServer(drums: drums, engine: engine, keyboards: keyboards, loops: loops,
                              midi: midi, sounds: sounds, instruments: instruments)
        song = Song(engine: engine, loops: loops, drums: drums, instruments: instruments)
    }

    func start() {
        Synth.shared.start()
        AudioOutputs.shared.start()
        instruments.restore()
        keyboard.start()
        midi.start()
        remote.start()
        projects.start()
    }

    func stop() {
        projects.saveOnQuit()
        midi.stop()
    }
}
