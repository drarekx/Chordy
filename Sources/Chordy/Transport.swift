import AVFoundation
import QuartzCore
import os

/// The one musical clock that drums, loops, the loop recorder and the metronome share.
/// Position is a pure function of host time (`CACurrentMediaTime`, the same clock as
/// `AudioTimeStamp.mHostTime`), never accumulated, so nothing drifts:
///
///     beat(t) = anchorBeat + (t - anchorTime) · bpm / 60
///
/// Starting from rest puts beat 0 just ahead of now; joining while it runs starts on the next
/// bar line, so whatever starts second lines up with whatever is already playing. A tempo change
/// re-anchors at the current position: no jump. Callable from any thread.
final class Transport: @unchecked Sendable {
    static let shared = Transport()
    static let beatsPerBar = 4.0
    /// Gap between "start" and beat 0: room for the schedulers' lookahead.
    static let startLead = 0.03

    struct Snapshot {
        var running = false
        var anchorTime = 0.0
        var anchorBeat = 0.0
        var bpm = 110.0

        func beat(at time: Double) -> Double { anchorBeat + (time - anchorTime) * bpm / 60 }
        func time(ofBeat beat: Double) -> Double { anchorTime + (beat - anchorBeat) * 60 / bpm }
    }

    private struct State {
        var snapshot = Snapshot()
        var users = Set<String>()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var snapshot: Snapshot { state.withLock { $0.snapshot } }
    var isRunning: Bool { state.withLock { $0.snapshot.running } }
    func beat(at time: Double = CACurrentMediaTime()) -> Double { snapshot.beat(at: time) }
    func time(ofBeat beat: Double) -> Double { snapshot.time(ofBeat: beat) }

    /// Join as `user` ("drums", "loops", "recorder") and get the beat to start on: 0 when the
    /// transport was at rest (it starts at `downbeat`, default now + `startLead`), else the next
    /// bar line at least `startLead` away.
    func join(_ user: String, downbeat: Double? = nil) -> Double {
        state.withLock { s in
            let now = CACurrentMediaTime()
            s.users.remove(user)
            guard s.snapshot.running, !s.users.isEmpty else {
                s.snapshot.running = true
                s.snapshot.anchorTime = downbeat ?? now + Self.startLead
                s.snapshot.anchorBeat = 0
                s.users = [user]
                return 0
            }
            s.users.insert(user)
            let beat = s.snapshot.beat(at: now + Self.startLead)
            return (beat / Self.beatsPerBar).rounded(.up) * Self.beatsPerBar
        }
    }

    /// The transport stops when its last user leaves.
    func leave(_ user: String) {
        state.withLock { s in
            s.users.remove(user)
            if s.users.isEmpty { s.snapshot.running = false }
        }
    }

    /// New tempo from now on, continuing from the current beat.
    func setBpm(_ bpm: Double) {
        guard bpm > 0 else { return }
        state.withLock { s in
            guard bpm != s.snapshot.bpm else { return }
            let now = CACurrentMediaTime()
            if s.snapshot.running {
                s.snapshot.anchorBeat = s.snapshot.beat(at: max(now, s.snapshot.anchorTime))
                s.snapshot.anchorTime = max(now, s.snapshot.anchorTime)
            }
            s.snapshot.bpm = bpm
        }
    }
}

/// Host time → a node's render timeline, for sample-accurate MIDI on AU instruments.
enum AudioClock {
    /// Sample time at which `node` renders host time `time` (seconds), or nil when it has
    /// not rendered yet. A time already past plays at the start of the next render slice.
    static func sampleTime(for node: AVAudioNode, at time: Double) -> AUEventSampleTime? {
        guard let last = node.lastRenderTime, last.isSampleTimeValid, last.isHostTimeValid else { return nil }
        let anchor = AVAudioTime.seconds(forHostTime: last.hostTime)
        return AUEventSampleTime(Double(last.sampleTime) + (time - anchor) * last.sampleRate)
    }

    /// Sends a 3-byte MIDI message to `unit` at host time `time` (nil = now), sample-accurately.
    /// Calls for one unit must come from one thread at a time (its scheduling queue).
    static func send(_ unit: AVAudioUnitMIDIInstrument, _ status: UInt8, _ data1: UInt8, _ data2: UInt8,
                     at time: Double?) {
        if let schedule = unit.auAudioUnit.scheduleMIDIEventBlock {
            let when = time.flatMap { sampleTime(for: unit, at: $0) } ?? AUEventSampleTimeImmediate
            var bytes = (status, data1, data2)
            withUnsafeBytes(of: &bytes) { raw in
                schedule(when, 0, 3, raw.bindMemory(to: UInt8.self).baseAddress!)
            }
        } else if status & 0xF0 == 0x90 {
            unit.startNote(data1, withVelocity: data2, onChannel: status & 0x0F)
        } else if status & 0xF0 == 0x80 {
            unit.stopNote(data1, onChannel: status & 0x0F)
        }
    }
}

/// The transport's whole beat for the screen (1-2-3-4 counters on the Mac and the iPad):
/// polled at display rate, published only when the beat changes. nil while stopped.
@MainActor
final class BeatClock: ObservableObject {
    static let shared = BeatClock()

    /// Whole beats since the transport started (beat 0 = first downbeat).
    @Published private(set) var beat: Int?
    private var timer: Timer?

    private init() {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let t = Transport.shared
        let now: Int? = t.isRunning ? Int(t.beat().rounded(.down)) : nil
        // Before beat 0 (start lead) counts as not started yet.
        let value = now.map { $0 < 0 ? nil : $0 } ?? nil
        if value != beat { beat = value }
    }
}
