import Combine
import Foundation

/// Everything the windows share: chord engine, sounds and inputs.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let engine = ChordEngine()
    let sounds = SoundLibrary()
    let keyboard: KeyboardInput
    let midi: MidiController
    let loops: Loops

    private init() {
        keyboard = KeyboardInput(engine: engine)
        midi = MidiController(engine: engine, sounds: sounds)
        loops = Loops(engine: engine)
        engine.patch = { [unowned sounds] in sounds.draft }
        let shortcuts = KeyboardInput.Shortcuts(
            toggleRecord: { [unowned loops] in loops.toggleRecord() },
            togglePlay: { [unowned loops] in loops.togglePlay() },
            panic: { [unowned loops] in loops.stopPlayback() })
        keyboard.shortcuts = shortcuts
        midi.shortcuts = shortcuts
        midi.isRecording = { [unowned loops] in loops.isRecording }
        midi.isPlaying = { [unowned loops] in loops.isPlaying }
        midi.watch(loops.objectWillChange)
    }

    func start() {
        Synth.shared.start()
        keyboard.start()
        midi.start()
    }

    func stop() {
        midi.stop()
    }
}
