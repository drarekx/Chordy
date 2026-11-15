import Foundation

/// A complete synth sound. Plain values so it encodes to JSON.
struct Patch: Codable, Equatable, Identifiable {
    enum Waveform: String, Codable, CaseIterable { case sine, triangle, sawtooth, square, custom }
    enum FilterType: String, Codable, CaseIterable { case lowpass, highpass, bandpass }

    struct Oscillator: Codable, Equatable {
        var enabled = true
        var wave: Waveform
        /// -2…+2 octaves from the played note.
        var octave = 0
        /// Fine tune in cents.
        var detune = 0.0
        /// 0–1 mix level.
        var level = 1.0
    }

    struct Filter: Codable, Equatable {
        var type: FilterType
        var cutoff: Double
        var resonance: Double
        /// Octaves the cutoff jumps on note start, then decays back.
        var envAmount: Double
        /// Seconds for the filter envelope to settle.
        var envDecay: Double
    }

    struct Envelope: Codable, Equatable {
        var attack: Double
        var decay: Double
        var sustain: Double
        var release: Double
    }

    struct Vibrato: Codable, Equatable {
        var rate: Double
        /// Cents.
        var depth: Double
    }

    var id: String
    var name: String
    var oscillators: [Oscillator]
    /// Amplitudes (0–1) of harmonics 1…16, used by `custom` oscillators.
    var harmonics: [Double]
    var filter: Filter
    var envelope: Envelope
    var vibrato: Vibrato
    /// 0–1
    var volume: Double

    var isBuiltin: Bool { id.hasPrefix("builtin:") }

    static let harmonicCount = 16
    static let oscillatorCount = 3

    /// Parameter ranges shared by the editor, knobs and validation.
    enum Range {
        static let octave = -2...2
        static let detune = -50.0...50.0
        static let cutoff = 40.0...18000.0
        static let resonance = 0.1...20.0
        static let envAmount = -4.0...6.0
        static let envDecay = 0.02...3.0
        static let attack = 0.001...3.0
        static let decay = 0.01...3.0
        static let release = 0.01...4.0
        static let vibratoRate = 0.1...12.0
        static let vibratoDepth = 0.0...50.0
    }

    /// Clamp every value into range and fix array sizes (data read from disk).
    func sanitized() -> Patch {
        var p = self
        let base = Patch.builtins[0]
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(r.upperBound, max(r.lowerBound, v)) : r.lowerBound }
        p.name = String(name.prefix(40))
        p.oscillators = (0..<Patch.oscillatorCount).map { i in
            var o = i < oscillators.count ? oscillators[i] : base.oscillators[i]
            o.octave = min(Range.octave.upperBound, max(Range.octave.lowerBound, o.octave))
            o.detune = clamp(o.detune, Range.detune)
            o.level = clamp(o.level, 0...1)
            return o
        }
        p.harmonics = (0..<Patch.harmonicCount).map { i in clamp(i < harmonics.count ? harmonics[i] : 0, 0...1) }
        p.filter.cutoff = clamp(filter.cutoff, Range.cutoff)
        p.filter.resonance = clamp(filter.resonance, Range.resonance)
        p.filter.envAmount = clamp(filter.envAmount, Range.envAmount)
        p.filter.envDecay = clamp(filter.envDecay, Range.envDecay)
        p.envelope.attack = clamp(envelope.attack, Range.attack)
        p.envelope.decay = clamp(envelope.decay, Range.decay)
        p.envelope.sustain = clamp(envelope.sustain, 0...1)
        p.envelope.release = clamp(envelope.release, Range.release)
        p.vibrato.rate = clamp(vibrato.rate, Range.vibratoRate)
        p.vibrato.depth = clamp(vibrato.depth, Range.vibratoDepth)
        p.volume = clamp(volume, 0...1)
        return p
    }
}

// MARK: - Factory sounds

enum Harmonics {
    static func pad(_ values: [Double]) -> [Double] {
        (0..<Patch.harmonicCount).map { $0 < values.count ? values[$0] : 0 }
    }
    static let sine = pad([1])
    static let saw = (0..<Patch.harmonicCount).map { 1 / Double($0 + 1) }
    static let square = (0..<Patch.harmonicCount).map { $0 % 2 == 0 ? 1 / Double($0 + 1) : 0 }
    static let organ = pad([1, 0.8, 0.6, 0, 0.5, 0, 0, 0.4])
    static let bell = pad([1, 0, 0.5, 0, 0.3, 0.1, 0.2, 0, 0, 0.15, 0, 0.1])
}

private func osc(_ wave: Patch.Waveform, octave: Int = 0, detune: Double = 0, level: Double = 1) -> Patch.Oscillator {
    Patch.Oscillator(enabled: true, wave: wave, octave: octave, detune: detune, level: level)
}

private let off = Patch.Oscillator(enabled: false, wave: .sine, octave: 0, detune: 0, level: 0.5)

extension Patch {
    /// Factory sounds, same as the web version. Ids are stable so a saved selection survives.
    static let builtins: [Patch] = [
        Patch(id: "builtin:chordboy", name: "ChordBoy",
              oscillators: [osc(.sawtooth, detune: -8, level: 0.85), osc(.triangle), osc(.sawtooth, detune: 8, level: 0.85)],
              harmonics: Harmonics.saw,
              filter: Filter(type: .lowpass, cutoff: 4000, resonance: 2, envAmount: 0, envDecay: 0.3),
              envelope: Envelope(attack: 0.05, decay: 0.1, sustain: 0.7, release: 0.15),
              vibrato: Vibrato(rate: 5, depth: 0), volume: 0.48),
        Patch(id: "builtin:pad", name: "Warm Pad",
              oscillators: [osc(.sawtooth, detune: -12, level: 0.8), osc(.sawtooth, detune: 12, level: 0.8), osc(.triangle, octave: -1, level: 0.6)],
              harmonics: Harmonics.saw,
              filter: Filter(type: .lowpass, cutoff: 1200, resonance: 1, envAmount: 1, envDecay: 1.5),
              envelope: Envelope(attack: 0.6, decay: 0.8, sustain: 0.8, release: 1.2),
              vibrato: Vibrato(rate: 5, depth: 4), volume: 0.4),
        Patch(id: "builtin:organ", name: "Organ",
              oscillators: [osc(.custom), off, off],
              harmonics: Harmonics.organ,
              filter: Filter(type: .lowpass, cutoff: 8000, resonance: 0.5, envAmount: 0, envDecay: 0.3),
              envelope: Envelope(attack: 0.01, decay: 0.05, sustain: 1, release: 0.08),
              vibrato: Vibrato(rate: 6.5, depth: 6), volume: 0.4),
        Patch(id: "builtin:pluck", name: "Pluck",
              oscillators: [osc(.sawtooth), osc(.square, octave: -1, level: 0.4), off],
              harmonics: Harmonics.saw,
              filter: Filter(type: .lowpass, cutoff: 600, resonance: 6, envAmount: 4, envDecay: 0.25),
              envelope: Envelope(attack: 0.003, decay: 0.6, sustain: 0, release: 0.3),
              vibrato: Vibrato(rate: 5, depth: 0), volume: 0.55),
        Patch(id: "builtin:keys", name: "Keys",
              oscillators: [osc(.sine), osc(.sine, octave: 1, level: 0.35), osc(.triangle, detune: 4, level: 0.3)],
              harmonics: Harmonics.sine,
              filter: Filter(type: .lowpass, cutoff: 5000, resonance: 0.7, envAmount: 1, envDecay: 0.4),
              envelope: Envelope(attack: 0.005, decay: 1.2, sustain: 0.3, release: 0.4),
              vibrato: Vibrato(rate: 4, depth: 2), volume: 0.5),
        Patch(id: "builtin:lead", name: "Square Lead",
              oscillators: [osc(.square, detune: -5), osc(.square, detune: 5, level: 0.7), off],
              harmonics: Harmonics.square,
              filter: Filter(type: .lowpass, cutoff: 2500, resonance: 4, envAmount: 2, envDecay: 0.3),
              envelope: Envelope(attack: 0.01, decay: 0.2, sustain: 0.6, release: 0.2),
              vibrato: Vibrato(rate: 5.5, depth: 10), volume: 0.35),
        Patch(id: "builtin:glass", name: "Glass",
              oscillators: [osc(.custom), osc(.sine, octave: 1, level: 0.3), off],
              harmonics: Harmonics.bell,
              filter: Filter(type: .highpass, cutoff: 300, resonance: 0.5, envAmount: 0, envDecay: 0.3),
              envelope: Envelope(attack: 0.02, decay: 1.5, sustain: 0.2, release: 1),
              vibrato: Vibrato(rate: 3, depth: 3), volume: 0.45),
        Patch(id: "builtin:poly-pad", name: "Poly Pad",
              oscillators: [osc(.sawtooth, detune: -18, level: 0.7), osc(.square, detune: 7, level: 0.45), osc(.sawtooth, octave: 1, detune: 18, level: 0.35)],
              harmonics: Harmonics.saw,
              filter: Filter(type: .lowpass, cutoff: 900, resonance: 3, envAmount: 2, envDecay: 2.5),
              envelope: Envelope(attack: 0.9, decay: 1.5, sustain: 0.75, release: 2),
              vibrato: Vibrato(rate: 0.4, depth: 7), volume: 0.38),
        Patch(id: "builtin:house-stab", name: "House Stab",
              oscillators: [osc(.sawtooth, detune: -10), osc(.sawtooth, detune: 10), osc(.square, octave: -1, level: 0.5)],
              harmonics: Harmonics.saw,
              filter: Filter(type: .lowpass, cutoff: 450, resonance: 9, envAmount: 4.5, envDecay: 0.18),
              envelope: Envelope(attack: 0.002, decay: 0.35, sustain: 0.15, release: 0.12),
              vibrato: Vibrato(rate: 5, depth: 0), volume: 0.5),
        Patch(id: "builtin:sub-bass", name: "Sub Bass",
              oscillators: [osc(.sine, octave: -2), osc(.square, octave: -1, level: 0.25), off],
              harmonics: Harmonics.sine,
              filter: Filter(type: .lowpass, cutoff: 380, resonance: 1.5, envAmount: 1.5, envDecay: 0.15),
              envelope: Envelope(attack: 0.004, decay: 0.3, sustain: 0.85, release: 0.12),
              vibrato: Vibrato(rate: 5, depth: 0), volume: 0.7),
        Patch(id: "builtin:strings", name: "Strings",
              oscillators: [osc(.sawtooth, detune: -7, level: 0.75), osc(.sawtooth, detune: 7, level: 0.75), osc(.sawtooth, octave: 1, detune: 3, level: 0.3)],
              harmonics: Harmonics.saw,
              filter: Filter(type: .lowpass, cutoff: 2200, resonance: 0.8, envAmount: 0.5, envDecay: 1),
              envelope: Envelope(attack: 0.35, decay: 0.5, sustain: 0.9, release: 0.9),
              vibrato: Vibrato(rate: 5.5, depth: 9), volume: 0.38),
        Patch(id: "builtin:brass", name: "Brass",
              oscillators: [osc(.sawtooth), osc(.sawtooth, detune: 6, level: 0.6), off],
              harmonics: Harmonics.saw,
              filter: Filter(type: .lowpass, cutoff: 700, resonance: 2, envAmount: 2.5, envDecay: 0.5),
              envelope: Envelope(attack: 0.08, decay: 0.3, sustain: 0.8, release: 0.25),
              vibrato: Vibrato(rate: 5, depth: 5), volume: 0.42),
        Patch(id: "builtin:music-box", name: "Music Box",
              oscillators: [osc(.custom, octave: 1), osc(.sine, octave: 2, level: 0.2), off],
              harmonics: Harmonics.pad([1, 0, 0, 0.35, 0, 0, 0, 0, 0.15]),
              filter: Filter(type: .highpass, cutoff: 500, resonance: 0.5, envAmount: 0, envDecay: 0.3),
              envelope: Envelope(attack: 0.002, decay: 0.9, sustain: 0, release: 0.6),
              vibrato: Vibrato(rate: 5, depth: 0), volume: 0.5),
        Patch(id: "builtin:chiptune", name: "Chiptune",
              oscillators: [osc(.square), osc(.square, octave: 1, level: 0.25), off],
              harmonics: Harmonics.square,
              filter: Filter(type: .lowpass, cutoff: 18000, resonance: 0.1, envAmount: 0, envDecay: 0.3),
              envelope: Envelope(attack: 0.001, decay: 0.08, sustain: 0.7, release: 0.03),
              vibrato: Vibrato(rate: 7, depth: 0), volume: 0.3),
    ]
}
