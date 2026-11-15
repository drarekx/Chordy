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
    let keyboard: KeyboardInput
    let midi: MidiController
    let loops: Loops

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
        engine.output = SoundOutput(instruments: instruments, patch: { [unowned sounds] in sounds.draft })
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
    }

    func start() {
        Synth.shared.start()
        instruments.restore()
        keyboard.start()
        midi.start()
    }

    func stop() {
        midi.stop()
    }
}
