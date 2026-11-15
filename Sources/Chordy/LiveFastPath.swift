import Foundation
import os

/// Sounds keyboard keys straight from the CoreMIDI thread, without waiting for the main thread
/// (measured: p95 13 ms, p99 39 ms, worst 50 ms when it is busy drawing). It covers what is
/// both common and simple: a keyboard in Notes layout playing a sampled instrument. Everything
/// else (chords layouts, the synth, mapped controls, MIDI learn) still goes through the main
/// thread as before. The main thread still gets every message, marked `presounded`, and only
/// updates the UI state for those (held notes, drawings, recorder).
final class LiveFastPath: @unchecked Sendable {
    /// What the MIDI thread needs to know, rebuilt on the main thread when settings change.
    struct Snapshot {
        var enabled = false
        var keyboards: [KeyboardConfig] = []
        /// Sampler gates by keyboard id (Notes layout + sampled sound only).
        var gates: [String: SamplerGate] = [:]
        /// Devices whose CC 64 is the sustain pedal (not mapped to an action).
        var pedalDevices: Set<String> = []
    }

    private struct State {
        var snapshot = Snapshot()
        /// Keys sounding now ("<device>:<channel>:<number>") and pedal-held notes per device.
        var held: [String: (gate: SamplerGate, midi: Int, device: String)] = [:]
        var sustain: Set<String> = []
        var deferred: [String: [(SamplerGate, Int)]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func update(_ snapshot: Snapshot) { state.withLock { $0.snapshot = snapshot } }

    /// CoreMIDI thread. True when it sounded (or stopped) the note itself.
    func handle(status: UInt8, data1: UInt8, data2: UInt8, device: String) -> Bool {
        let kind = status & 0xF0
        let channel = Int(status & 0x0F) + 1
        return state.withLock { s in
            guard s.snapshot.enabled else { return false }
            if kind == 0xB0, data1 == 64, s.snapshot.pedalDevices.contains(device) {
                // Pedal: hold our own notes; the main thread still handles the others.
                if data2 >= 64 {
                    s.sustain.insert(device)
                } else if s.sustain.remove(device) != nil {
                    for (gate, midi) in s.deferred.removeValue(forKey: device) ?? [] { gate.off(midi) }
                }
                return false
            }
            guard kind == 0x90 || kind == 0x80 else { return false }
            let number = Int(data1)
            let key = "\(device):\(channel):\(number)"
            if kind == 0x80 || data2 == 0 {
                // Ours to stop even if the settings changed while it was held.
                guard let note = s.held.removeValue(forKey: key) else { return false }
                if s.sustain.contains(device) {
                    s.deferred[device, default: []].append((note.gate, note.midi))
                } else {
                    note.gate.off(note.midi)
                }
                return true
            }
            guard let keyboard = s.snapshot.keyboards.first(where: { $0.accepts(device: device, channel: channel, note: number) }),
                  keyboard.layout == .notes else { return false }
            let midi = number + keyboard.octave * 12
            guard s.held[key] == nil, (0...127).contains(midi), let gate = s.snapshot.gates[keyboard.id] else { return false }
            // Like `MidiController.playKeyboard`: the keyboard's volume is the sampler's gain (set
            // on the main thread), the velocity is just the curved key velocity.
            let velocity = keyboard.curve.apply(max(1, Int(data2)))
            guard gate.on(midi, velocity: SamplerPlayer.curveValue(velocity)) else { return false }
            s.held[key] = (gate, midi, device)
            return true
        }
    }

    /// Panic / device changes: silence what this path holds.
    func allOff() {
        state.withLock { s in
            for note in s.held.values { note.gate.off(note.midi) }
            for list in s.deferred.values { for (gate, midi) in list { gate.off(midi) } }
            s.held.removeAll()
            s.deferred.removeAll()
            s.sustain.removeAll()
        }
    }
}
