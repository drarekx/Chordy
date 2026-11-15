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
    private var sampleRate = 48_000.0

    private enum Command {
        case noteOn(Voice)
        case noteOff(id: Int, release: Double?)
        case allOff(release: Double)
        case live(LiveParams)
        case bend(semitones: Double)
        case click(accent: Bool)
    }

    private let pending = OSAllocatedUnfairLock(initialState: [Command]())

    // Render-thread state.
    private var voices: [Voice] = []
    private var clicks: [Click] = []
    private var bend = 0.0

    private(set) var running = false
    private var nextId = 1

    private init() {
        voices.reserveCapacity(Self.maxVoices)
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        let output = engine.outputNode.inputFormat(forBus: 0)
        sampleRate = output.sampleRate > 0 ? output.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, buffers in
            self.render(frames: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        compressor = AVAudioUnitEffect(audioComponentDescription: desc)
        engine.attach(source)
        engine.attach(compressor)
        engine.connect(source, to: compressor, format: format)
        engine.connect(compressor, to: engine.mainMixerNode, format: format)
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

    /// Adds another sound source (the sampler) to the same engine, straight into the mixer.
    func attach(_ node: AVAudioNode, to next: AVAudioNode? = nil) {
        start()
        engine.attach(node)
        engine.connect(node, to: next ?? engine.mainMixerNode, format: nil)
    }

    func detach(_ node: AVAudioNode) {
        guard node.engine === engine else { return }
        engine.detach(node)
    }

    /// Output device changed (headphones, AirPods…): start again on the new one.
    private func restart() {
        engine.stop()
        do { try engine.start() } catch { NSLog("Chordy: audio engine restart failed: \(error)") }
    }

    // MARK: - Commands (main thread)

    /// Starts one note and returns its id for `noteOff`.
    @discardableResult
    func noteOn(midi: Int, patch: Patch) -> Int {
        let id = nextId
        nextId += 1
        let voice = Voice(id: id, midi: Double(midi), patch: patch,
                          table: patch.oscillators.contains { $0.enabled && $0.wave == .custom }
                              ? Self.wavetable(patch.harmonics) : [],
                          sampleRate: sampleRate)
        send(.noteOn(voice))
        return id
    }

    /// Fades out from wherever the envelope is (patch release unless given).
    func noteOff(_ id: Int, release: Double? = nil) { send(.noteOff(id: id, release: release)) }

    func allOff(release: Double = 0.1) { send(.allOff(release: release)) }

    /// Sound edits that apply to notes already sounding (filter, levels, vibrato, volume).
    func updateLive(_ patch: Patch) { send(.live(LiveParams(patch))) }

    /// Pitch bend for every voice, in semitones.
    func setBend(_ semitones: Double) { send(.bend(semitones: semitones)) }

    /// Metronome tick.
    func click(accent: Bool) { send(.click(accent: accent)) }

    private func send(_ command: Command) {
        pending.withLock { $0.append(command) }
    }

    // MARK: - Render thread

    private func drain() {
        guard let commands = pending.withLockIfAvailable({ state -> [Command] in
            defer { state.removeAll(keepingCapacity: true) }
            return state
        }) else { return }
        for command in commands {
            switch command {
            case .noteOn(let voice):
                if voices.count >= Self.maxVoices { voices.removeFirst() }
                voices.append(voice)
            case .noteOff(let id, let release):
                if let i = voices.firstIndex(where: { $0.id == id }) { voices[i].release(release, sampleRate: sampleRate) }
            case .allOff(let release):
                for i in voices.indices { voices[i].release(release, sampleRate: sampleRate) }
            case .live(let params):
                for i in voices.indices { voices[i].live = params }
            case .bend(let semitones):
                bend = semitones
            case .click(let accent):
                clicks.append(Click(accent: accent))
            }
        }
    }

    private func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        drain()
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        for f in 0..<frames { first[f] = 0 }

        let bendRatio = pow(2, bend / 12)
        voices.withUnsafeMutableBufferPointer { list in
            for i in list.indices {
                list[i].render(into: first, frames: frames, sampleRate: sampleRate, bendRatio: bendRatio)
            }
        }
        voices.removeAll { $0.finished }

        clicks.withUnsafeMutableBufferPointer { list in
            for i in list.indices { list[i].render(into: first, frames: frames, sampleRate: sampleRate) }
        }
        clicks.removeAll { $0.finished }

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

    init(_ patch: Patch) {
        oscillators = patch.oscillators
        filter = patch.filter
        vibrato = patch.vibrato
        peak = patch.volume * 0.25
    }
}

private struct Voice {
    let id: Int
    let frequency: Double
    let table: [Float]
    var live: LiveParams

    // Amp envelope (0…1, scaled by `live.peak`).
    private let attack: Double
    private let decay: Double
    private let sustain: Double
    private let patchRelease: Double
    private var level = 0.0
    private var stage = Stage.attack
    private var releaseStep = 0.0
    private(set) var finished = false

    private var time = 0.0
    private var phases = [Double](repeating: 0, count: Patch.oscillatorCount)
    private var lfoPhase = 0.0

    // Biquad state (transposed direct form II) and coefficients.
    private var z1 = 0.0, z2 = 0.0
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var coefCountdown = 0

    private enum Stage { case attack, decay, sustain, release }

    init(id: Int, midi: Double, patch: Patch, table: [Float], sampleRate: Double) {
        self.id = id
        frequency = Music.frequency(midi)
        self.table = table
        live = LiveParams(patch)
        attack = max(0.002, patch.envelope.attack)
        decay = max(0.001, patch.envelope.decay)
        sustain = patch.envelope.sustain
        patchRelease = patch.envelope.release
    }

    mutating func release(_ seconds: Double?, sampleRate: Double) {
        guard stage != .release else { return }
        stage = .release
        let time = max(0.01, seconds ?? patchRelease)
        releaseStep = level / (time * sampleRate)
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
        let decayStep = (1 - sustain) / (decay * sampleRate)
        let vib = live.vibrato
        let ratios = live.oscillators.map { pow(2, Double($0.octave) + $0.detune / 1200) }

        for f in 0..<frames {
            switch stage {
            case .attack:
                level += attackStep
                if level >= 1 { level = 1; stage = .decay }
            case .decay:
                level -= decayStep
                if level <= sustain { level = sustain; stage = .sustain }
            case .sustain:
                level = sustain
            case .release:
                level -= releaseStep
                if level <= 0 { level = 0; finished = true }
            }
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
            for o in 0..<live.oscillators.count where o < phases.count {
                let osc = live.oscillators[o]
                guard osc.enabled, osc.level > 0 else { continue }
                let dt = min(0.5, pitch * ratios[o] * dtime)
                mix += sample(osc.wave, phase: phases[o], dt: dt) * osc.level
                phases[o] += dt
                if phases[o] >= 1 { phases[o] -= 1 }
            }

            let y = b0 * mix + z1
            z1 = b1 * mix - a1 * y + z2
            z2 = b2 * mix - a2 * y
            out[f] += Float(y * level * live.peak)
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

    init(accent: Bool) { self.accent = accent }

    mutating func render(into out: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) {
        let freq = accent ? 1760.0 : 1320.0
        let peak = accent ? 0.08 : 0.04
        for f in 0..<frames {
            if time >= 0.05 { finished = true; return }
            let env = time < 0.002 ? time / 0.002 : exp(-(time - 0.002) * 120)
            out[f] += Float((phase < 0.5 ? 1 : -1) * peak * env)
            phase += freq / sampleRate
            if phase >= 1 { phase -= 1 }
            time += 1 / sampleRate
        }
    }
}
