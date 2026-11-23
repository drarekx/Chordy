import AVFoundation
import AudioToolbox
import os

/// Polyphonic subtractive synth rendered in an `AVAudioSourceNode`.
///
/// Mirrors the web version's Web Audio graph: per voice up to three oscillators
/// (basic waves or a wavetable built from 16 harmonics) → biquad filter with its
/// own envelope → amp ADSR, with a vibrato LFO on pitch, into a gentle compressor.
/// The main thread only queues commands; voices live on the render thread.
final class Synth: @unchecked Sendable {
    static let shared = Synth()

    /// Per-voice peak gain at volume 1; headroom for 4-note chords × 3 oscillators.
    private static let maxPeak = 0.25
    private static let maxVoices = 48
    private static let tableSize = 2048

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private var compressor: AVAudioUnitEffect!
    /// Every synth output (dry and each effects bus) meets here before the compressor.
    private let synthMixer = AVAudioMixerNode()
    /// The synth after its compressor: to the mix and to the shared room.
    private let synthOut = AVAudioMixerNode()
    /// The shared room: every source sends a little here (one reverb for everything, instead of
    /// each sound dry or with its own hall that crossfades its dry signal away).
    private let roomSend = AVAudioMixerNode()
    private let room = AVAudioUnitReverb()
    /// High-pass on the room's return, so the low end stays clean.
    private let roomEQ = AVAudioUnitEQ(numberOfBands: 1)
    /// Every sampler (instruments, MIDI files) and the drum kit meet here, then go to the mix
    /// and the room. A mixer whose output is split to two places stays uninitialized (silent,
    /// "pending connections") unless it already has an input when the engine starts: each
    /// gets a silent source at bus 0 so samplers can join later.
    let samplerBus = AVAudioMixerNode()
    let drumBus = AVAudioMixerNode()
    /// How much of each kind of source goes to the room by default.
    static let roomSendLevel: Float = 0.16
    static let drumRoomSendLevel: Float = 0.08
    private var format: AVAudioFormat?

    /// Outputs: slot 0 is dry; each effects bus ("kb:<id>", "loop:<id>") gets its own slot with
    /// a source node → filter → echo → reverb, so a keyboard's effects also shape the synth.
    private static let maxSlots = 12
    private final class SlotChain {
        let source: AVAudioSourceNode
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()
        init(source: AVAudioSourceNode) { self.source = source }
    }
    private var chains: [Int: SlotChain] = [:]
    private var slotByBus: [String: Int] = [:]
    private var sampleRate = 48_000.0

    /// `at`: host time (seconds) the event must sound at; nil = start of the next buffer.
    private enum Command {
        case noteOn(Voice, slot: Int, at: Double?)
        case noteOff(id: Int, release: Double?, at: Double?)
        case allOff(release: Double)
        /// Live edits of one sound (by `Patch.id` hash): only its voices follow them.
        case live(LiveParams, patch: Int)
        case bend(semitones: Double)
        case click(accent: Bool, at: Double?)
    }

    private let pending = OSAllocatedUnfairLock(initialState: [Command]())
    /// Render-thread buffer swapped with `pending`, so neither side allocates once warm.
    private var drained: [Command] = []

    // Render-thread state: voices per output slot.
    private var voices: [[Voice]] = []
    private var lastDrainHost = -1.0
    private var clicks: [Click] = []
    private var bend = 0.0

    private(set) var running = false
    /// Output device chosen in Chordy; nil = the system's (the engine follows it by itself).
    private var outputDevice: AudioDeviceID?
    private var nextId = 1

    private init() {
        voices = (0..<Self.maxSlots).map { _ in
            var list: [Voice] = []
            list.reserveCapacity(Self.maxVoices)
            return list
        }
    }

    // MARK: - Lifecycle

    /// Peak limiter with a 1 ms look-ahead: Apple's default (12 ms) delays everything that
    /// goes through it by that much, and limiters in series add up.
    static func limiter() -> AVAudioUnitEffect {
        let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        AudioUnitSetParameter(unit.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(unit.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        return unit
    }

    /// Ask the output device for a small I/O buffer (128 frames ≈ 3 ms instead of ~11 ms).
    private func lowerLatency() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames: UInt32 = 128
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
    }

    func start() {
        guard !running else { return }
        lowerLatency()
        let output = engine.outputNode.inputFormat(forBus: 0)
        sampleRate = output.sampleRate > 0 ? output.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        self.format = format

        source = makeSource(slot: 0, format: format)
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        compressor = AVAudioUnitEffect(audioComponentDescription: desc)
        engine.attach(source)
        engine.attach(compressor)
        engine.attach(synthMixer)
        engine.connect(source, to: synthMixer, format: format)
        engine.connect(synthMixer, to: compressor, format: format)
        // The room: send mixer → reverb (all wet) → high-pass → mix.
        for node in [roomSend, room, roomEQ] as [AVAudioNode] { engine.attach(node) }
        room.loadFactoryPreset(.mediumRoom)
        room.wetDryMix = 100
        let band = roomEQ.bands[0]
        band.filterType = .highPass
        band.frequency = 250
        band.bypass = false
        engine.connect(roomSend, to: room, format: format)
        engine.connect(room, to: roomEQ, format: format)
        engine.connect(roomEQ, to: engine.mainMixerNode, format: format)
        engine.attach(synthOut)
        engine.connect(compressor, to: synthOut, format: format)
        connectOutput(synthOut, send: Self.roomSendLevel, format: format)
        for bus in [samplerBus, drumBus] {
            engine.attach(bus)
            let silence = AVAudioSourceNode(format: format) { silent, _, frames, buffers in
                for b in UnsafeMutableAudioBufferListPointer(buffers) { memset(b.mData, 0, Int(b.mDataByteSize)) }
                silent.pointee = true
                return noErr
            }
            engine.attach(silence)
            engine.connect(silence, to: bus, fromBus: 0, toBus: 0, format: format)
        }
        connectOutput(samplerBus, send: Self.roomSendLevel, format: format)
        connectOutput(drumBus, send: Self.drumRoomSendLevel, format: format)
        // Master limiter: synth + samplers + drums together must never pass 0 dBFS (a full
        // kit hit alone reached +0.9 dB and distorted).
        let master = Self.limiter()
        engine.attach(master)
        engine.connect(engine.mainMixerNode, to: master, format: format)
        engine.connect(master, to: engine.outputNode, format: format)
        // No pregain: the sources leave their own headroom (samplers −6 dB), so this only
        // catches rare peaks instead of ducking the piano on every loud drum hit.
        AudioUnitSetParameter(master.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        let unit = compressor.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -12, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.2, 0)

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in self?.restart() }
        do {
            try engine.start()
            running = true
        } catch {
            NSLog("Chordy: audio engine failed to start: \(error)")
        }
    }

    private func makeSource(slot: Int, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, buffers in
            let ts = timestamp.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: ts.mHostTime) : nil
            self.render(slot: slot, frames: Int(frameCount), host: host, buffers: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
    }

    /// The output slot for an effects bus, created on first use (main thread). Effects that are
    /// off use the dry slot; with every slot taken, the dry one too.
    func slot(for bus: String?, effects: Effects) -> Int {
        guard let bus, !effects.isOff else { return 0 }
        if let slot = slotByBus[bus] { return slot }
        start()
        guard running, let format, let slot = (1..<Self.maxSlots).first(where: { chains[$0] == nil }) else { return 0 }
        let chain = SlotChain(source: makeSource(slot: slot, format: format))
        for node in [chain.source, chain.eq, chain.delay, chain.reverb] as [AVAudioNode] { engine.attach(node) }
        engine.connect(chain.reverb, to: synthMixer, fromBus: 0, toBus: synthMixer.nextAvailableInputBus, format: format)
        engine.connect(chain.delay, to: chain.reverb, format: format)
        engine.connect(chain.eq, to: chain.delay, format: format)
        engine.connect(chain.source, to: chain.eq, format: format)
        Effects.apply(effects, eq: chain.eq, delay: chain.delay, reverb: chain.reverb)
        chains[slot] = chain
        slotByBus[bus] = slot
        return slot
    }

    /// A bus's effects changed: retune its synth chain, if it has one.
    func setEffects(bus: String, _ effects: Effects) {
        guard let slot = slotByBus[bus], let chain = chains[slot] else { return }
        Effects.apply(effects, eq: chain.eq, delay: chain.delay, reverb: chain.reverb)
    }

    #if DEBUG
    /// The device the output unit is on now.
    func debugOutputDevice() -> AudioDeviceID {
        guard let unit = engine.outputNode.audioUnit else { return 0 }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return id
    }

    /// Listens to the main mix (before the master limiter) for `seconds` and reports the peak
    /// and RMS in dBFS, to compare levels without listening.
    func debugMeter(seconds: Double, done: @escaping (String) -> Void) {
        start()
        let mixer = engine.mainMixerNode
        let box = OSAllocatedUnfairLock(initialState: (peak: Float(0), sum: Double(0), count: 0))
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var peak: Float = 0, sum = 0.0
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { let v = data[c][i]; peak = max(peak, abs(v)); sum += Double(v * v) }
            }
            let n = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            let (p, q) = (peak, sum)
            box.withLock { $0.peak = max($0.peak, p); $0.sum += q; $0.count += n }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            mixer.removeTap(onBus: 0)
            let r = box.withLock { $0 }
            let db = { (x: Double) in x > 0 ? 20 * log10(x) : -120 }
            done(String(format: "peak=%.1f rms=%.1f", db(Double(r.peak)), db(sqrt(r.sum / Double(max(1, r.count))))))
        }
    }

    /// The engine's graph as AVAudioEngine prints it (debug).
    func debugGraph() -> String { engine.description }

    /// Voices alive per slot and the slots in use (debug only; racy read, fine for a check).
    func debugSlots() -> String {
        "voices=\(voices.map(\.count)) buses=\(slotByBus)"
    }
    #endif

    /// An output mixer to the mix and, at `send` level, to the room (only before the engine starts).
    private func connectOutput(_ node: AVAudioMixerNode, send: Float, format: AVAudioFormat) {
        let main = engine.mainMixerNode
        let sendBus = roomSend.nextAvailableInputBus
        engine.connect(node, to: [AVAudioConnectionPoint(node: main, bus: main.nextAvailableInputBus),
                                  AVAudioConnectionPoint(node: roomSend, bus: sendBus)], fromBus: 0, format: format)
        node.destination(forMixer: roomSend, bus: sendBus)?.volume = send
    }

    /// Adds another sound source (the sampler) to the same engine, straight into the mixer.
    /// Adds a node to the engine, into `next` (a mixer: its next free input), or the main mix.
    /// At the engine's rate: samplers otherwise render at 44.1 kHz and get converted.
    func attach(_ node: AVAudioNode, to next: AVAudioNode? = nil) {
        start()
        engine.attach(node)
        if let mixer = (next ?? engine.mainMixerNode) as? AVAudioMixerNode {
            engine.connect(node, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: format)
        } else {
            engine.connect(node, to: next!, format: format)
        }
    }

    func detach(_ node: AVAudioNode) {
        guard node.engine === engine else { return }
        engine.detach(node)
    }

    /// Send the sound to a device (nil = the system output). Stops the engine for a moment.
    func setOutputDevice(_ device: AudioDeviceID?) {
        guard device != outputDevice else { return }
        outputDevice = device
        guard running else { return }
        engine.stop()
        route()
        lowerLatency()
        do { try engine.start() } catch { NSLog("Chordy: audio engine restart failed: \(error)") }
    }

    /// Point the output unit at the chosen device, or at the system's again.
    private func route() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var id = outputDevice ?? Self.systemOutput() ?? 0
        guard id != 0 else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private static func systemOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    /// Output device changed (headphones, AirPods…): start again on the new one (or keep the
    /// one chosen in Chordy).
    private func restart() {
        engine.stop()
        route()
        lowerLatency()
        do { try engine.start() } catch { NSLog("Chordy: audio engine restart failed: \(error)") }
    }

    // MARK: - Commands (main thread)

    /// Starts one note and returns its id for `noteOff`.
    @discardableResult
    func noteOn(midi: Int, patch: Patch, slot: Int = 0, at time: Double? = nil, velocity: Double = 1) -> Int {
        let id = nextId
        nextId += 1
        let voice = Voice(id: id, midi: Double(midi), patch: patch, velocity: velocity,
                          table: patch.oscillators.contains { $0.enabled && $0.wave == .custom }
                              ? Self.wavetable(patch.harmonics) : [],
                          sampleRate: sampleRate)
        send(.noteOn(voice, slot: max(0, min(Self.maxSlots - 1, slot)), at: time))
        return id
    }

    /// Fades out from wherever the envelope is (patch release unless given).
    func noteOff(_ id: Int, release: Double? = nil, at time: Double? = nil) {
        send(.noteOff(id: id, release: release, at: time))
    }

    func allOff(release: Double = 0.1) { send(.allOff(release: release)) }

    /// Sound edits that apply to notes already sounding (filter, levels, vibrato, volume).
    func updateLive(_ patch: Patch) { send(.live(LiveParams(patch), patch: patch.id.hashValue)) }

    /// Pitch bend for every voice, in semitones.
    func setBend(_ semitones: Double) { send(.bend(semitones: semitones)) }

    /// Metronome tick, at host time `time` (sample-accurate) or now.
    func click(accent: Bool, at time: Double? = nil) { send(.click(accent: accent, at: time)) }

    private func send(_ command: Command) {
        pending.withLock { $0.append(command) }
    }

    // MARK: - Render thread

    /// Frames from the start of this buffer to host time `time` (0 when unknown or past).
    private func offset(_ time: Double?, host: Double?) -> Int {
        guard let time, let host else { return 0 }
        return max(0, Int(((time - host) * sampleRate).rounded()))
    }

    private func drain(host: Double?) {
        guard pending.withLockIfAvailable({ swap(&$0, &drained) }) != nil else { return }
        defer { drained.removeAll(keepingCapacity: true) }
        for command in drained {
            switch command {
            case .noteOn(var voice, let slot, let time):
                if voices[slot].count >= Self.maxVoices { voices[slot].removeFirst() }
                voice.delay = offset(time, host: host)
                voices[slot].append(voice)
            case .noteOff(let id, let release, let time):
                for s in voices.indices {
                    if let i = voices[s].firstIndex(where: { $0.id == id }) {
                        voices[s][i].release(release, sampleRate: sampleRate, after: offset(time, host: host))
                        break
                    }
                }
            case .allOff(let release):
                for s in voices.indices { for i in voices[s].indices { voices[s][i].release(release, sampleRate: sampleRate) } }
            case .live(let params, let patch):
                for s in voices.indices { for i in voices[s].indices where voices[s][i].patch == patch { voices[s][i].live = params } }
            case .bend(let semitones):
                bend = semitones
            case .click(let accent, let time):
                clicks.append(Click(accent: accent, delay: offset(time, host: host)))
            }
        }
    }

    /// Every output node renders on the same audio thread, one after another, with the same
    /// timestamp: the first one of each cycle drains the commands for all of them.
    private func render(slot: Int, frames: Int, host: Double?, buffers: UnsafeMutableAudioBufferListPointer) {
        if host == nil || host != lastDrainHost {
            lastDrainHost = host ?? -1
            drain(host: host)
        }
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        for f in 0..<frames { first[f] = 0 }

        let bendRatio = pow(2, bend / 12)
        voices[slot].withUnsafeMutableBufferPointer { list in
            for i in list.indices {
                list[i].render(into: first, frames: frames, sampleRate: sampleRate, bendRatio: bendRatio)
            }
        }
        voices[slot].removeAll { $0.finished }

        if slot == 0 {
            clicks.withUnsafeMutableBufferPointer { list in
                for i in list.indices { list[i].render(into: first, frames: frames, sampleRate: sampleRate) }
            }
            clicks.removeAll { $0.finished }
        }

        for buffer in buffers.dropFirst() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            data.update(from: first, count: frames)
        }
    }

    /// One cycle of the harmonic mix, normalized to ±1 (like a Web Audio PeriodicWave).
    static func wavetable(_ harmonics: [Double]) -> [Float] {
        var amps = harmonics
        if !amps.contains(where: { $0 > 0 }) { amps = [1] }
        var table = [Float](repeating: 0, count: tableSize)
        var peak: Float = 0
        for s in 0..<tableSize {
            let phase = Double(s) / Double(tableSize)
            var value = 0.0
            for (h, amp) in amps.enumerated() where amp > 0 {
                value += amp * sin(2 * .pi * Double(h + 1) * phase)
            }
            table[s] = Float(value)
            peak = max(peak, abs(table[s]))
        }
        if peak > 0 { for s in 0..<tableSize { table[s] /= peak } }
        return table
    }
}

// MARK: - Voice

/// Patch values that may change while a note sounds.
private struct LiveParams {
    var oscillators: [Patch.Oscillator]
    var filter: Patch.Filter
    var vibrato: Patch.Vibrato
    var peak: Double
    /// Frequency ratio per oscillator, computed here so the render thread never allocates.
    var ratios: [Double]

    init(_ patch: Patch) {
        oscillators = patch.oscillators
        ratios = patch.oscillators.map { pow(2, Double($0.octave) + $0.detune / 1200) }
        filter = patch.filter
        vibrato = patch.vibrato
        peak = patch.volume * 0.25
    }
}

private struct Voice {
    let id: Int
    /// `Patch.id` hash, so live edits of one sound don't touch another's notes.
    let patch: Int
    let frequency: Double
    let table: [Float]
    var live: LiveParams
    /// Velocity as gain (0.35…1), kept apart from the patch so live edits don't reset it.
    let velocity: Double
    /// Output gain now, gliding to `live.peak · velocity` (no clicks when the volume moves).
    private var gain = -1.0

    // Amp envelope (0…1, scaled by `live.peak`).
    private let attack: Double
    private let decay: Double
    private let sustain: Double
    private let patchRelease: Double
    private var level = 0.0
    private var stage = Stage.attack
    /// Exponential decay and release: the level falls by a constant ratio per sample (linear
    /// ramps sounded like a fade, not a ring). Patch times were tuned for linear ramps, so −60 dB
    /// comes at 3× the decay and 2.5× the release: about as long and loud as before, but ringing.
    private var releaseCoef = 0.0
    private(set) var finished = false
    /// Frames of silence before it starts (scheduled notes), and a release waiting for its frame.
    var delay = 0
    private var pendingRelease: (frames: Int, seconds: Double?)?

    private var time = 0.0
    private var phases = [Double](repeating: 0, count: Patch.oscillatorCount)
    private var lfoPhase = 0.0

    // Biquad state (transposed direct form II) and coefficients.
    private var z1 = 0.0, z2 = 0.0
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var coefCountdown = 0

    private enum Stage { case attack, decay, sustain, release }

    init(id: Int, midi: Double, patch: Patch, velocity: Double, table: [Float], sampleRate: Double) {
        self.id = id
        self.velocity = velocity
        self.patch = patch.id.hashValue
        frequency = Music.frequency(midi)
        self.table = table
        live = LiveParams(patch)
        attack = max(0.002, patch.envelope.attack)
        decay = max(0.001, patch.envelope.decay)
        sustain = patch.envelope.sustain
        patchRelease = patch.envelope.release
    }

    /// `after`: frames from now; never before the note itself started.
    mutating func release(_ seconds: Double?, sampleRate: Double, after frames: Int = 0) {
        if frames > 0 || delay > 0 {
            pendingRelease = (max(frames, delay + 1), seconds)
            return
        }
        guard stage != .release else { return }
        stage = .release
        let time = max(0.01, seconds ?? patchRelease)
        releaseCoef = exp(-6.9 / (2.5 * time * sampleRate))
    }

    /// Cutoff right now, following the filter envelope (exponential rise, then decay back).
    private func cutoff() -> Double {
        let f = live.filter
        guard f.envAmount != 0 else { return f.cutoff }
        let target = min(20_000, max(20, f.cutoff * pow(2, f.envAmount)))
        if time < attack { return f.cutoff * pow(target / f.cutoff, time / attack) }
        let tau = max(0.001, f.envDecay / 3)
        return f.cutoff + (target - f.cutoff) * exp(-(time - attack) / tau)
    }

    /// RBJ cookbook biquad. Like Web Audio, low/high-pass Q is in dB.
    private mutating func updateCoefficients(sampleRate: Double) {
        let f = live.filter
        let freq = min(sampleRate * 0.45, max(20, cutoff()))
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let q = f.type == .bandpass ? max(0.0001, f.resonance) : pow(10, f.resonance / 20)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        switch f.type {
        case .lowpass:
            b0 = (1 - cosw) / 2 / a0; b1 = (1 - cosw) / a0; b2 = b0
        case .highpass:
            b0 = (1 + cosw) / 2 / a0; b1 = -(1 + cosw) / a0; b2 = b0
        case .bandpass:
            b0 = alpha / a0; b1 = 0; b2 = -alpha / a0
        }
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    /// PolyBLEP residual that rounds the jumps of saw and square waves (less aliasing).
    private static func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    private func sample(_ wave: Patch.Waveform, phase p: Double, dt: Double) -> Double {
        switch wave {
        case .sine: return sin(2 * .pi * p)
        case .triangle: return 1 - 4 * abs(p - 0.25 - floor(p + 0.25))
        case .sawtooth: return 2 * p - 1 - Voice.blep(p, dt)
        case .square:
            var v = p < 0.5 ? 1.0 : -1.0
            v += Voice.blep(p, dt)
            var q = p + 0.5; if q >= 1 { q -= 1 }
            return v - Voice.blep(q, dt)
        case .custom:
            guard !table.isEmpty else { return sin(2 * .pi * p) }
            let x = p * Double(table.count)
            let i = Int(x) % table.count
            let frac = Float(x - floor(x))
            return Double(table[i] + (table[(i + 1) % table.count] - table[i]) * frac)
        }
    }

    mutating func render(into out: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double, bendRatio: Double) {
        let dtime = 1 / sampleRate
        let attackStep = 1 / (attack * sampleRate)
        let decayCoef = exp(-6.9 / (3 * decay * sampleRate))
        let vib = live.vibrato
        let target = live.peak * velocity
        if gain < 0 { gain = target }
        let glide = 1 - exp(-1 / (0.005 * sampleRate))

        for f in 0..<frames {
            if let pending = pendingRelease {
                if pending.frames <= 0 {
                    pendingRelease = nil
                    release(pending.seconds, sampleRate: sampleRate)
                } else {
                    pendingRelease = (pending.frames - 1, pending.seconds)
                }
            }
            if delay > 0 { delay -= 1; continue }
            switch stage {
            case .attack:
                level += attackStep
                if level >= 1 { level = 1; stage = .decay }
            case .decay:
                level = sustain + (level - sustain) * decayCoef
                if level - sustain < 1e-4 { level = sustain; stage = .sustain }
            case .sustain:
                level = sustain
            case .release:
                level *= releaseCoef
                if level < 1e-4 { level = 0; finished = true }
            }
            gain += (target - gain) * glide
            if finished { return }

            if coefCountdown <= 0 {
                updateCoefficients(sampleRate: sampleRate)
                coefCountdown = 32
            }
            coefCountdown -= 1

            var pitch = frequency * bendRatio
            if vib.depth > 0 {
                pitch *= pow(2, vib.depth * sin(2 * .pi * lfoPhase) / 1200)
                lfoPhase += vib.rate * dtime
                if lfoPhase >= 1 { lfoPhase -= 1 }
            }

            var mix = 0.0
            for o in 0..<live.oscillators.count where o < phases.count && o < live.ratios.count {
                let osc = live.oscillators[o]
                guard osc.enabled, osc.level > 0 else { continue }
                let dt = min(0.5, pitch * live.ratios[o] * dtime)
                mix += sample(osc.wave, phase: phases[o], dt: dt) * osc.level
                phases[o] += dt
                if phases[o] >= 1 { phases[o] -= 1 }
            }

            let y = b0 * mix + z1
            z1 = b1 * mix - a1 * y + z2
            z2 = b2 * mix - a2 * y
            out[f] += Float(y * level * gain)
            time += dtime
        }
    }
}

/// Short square blip for the metronome.
private struct Click {
    let accent: Bool
    private var time = 0.0
    private var phase = 0.0
    private(set) var finished = false

    private var delay: Int

    init(accent: Bool, delay: Int = 0) {
        self.accent = accent
        self.delay = delay
    }

    mutating func render(into out: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) {
        let freq = accent ? 1760.0 : 1320.0
        let peak = accent ? 0.08 : 0.04
        for f in 0..<frames {
            if delay > 0 { delay -= 1; continue }
            if time >= 0.05 { finished = true; return }
            let env = time < 0.002 ? time / 0.002 : exp(-(time - 0.002) * 120)
            out[f] += Float((phase < 0.5 ? 1 : -1) * peak * env)
            phase += freq / sampleRate
            if phase >= 1 { phase -= 1 }
            time += 1 / sampleRate
        }
    }
}
