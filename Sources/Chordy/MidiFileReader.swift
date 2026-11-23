import AudioToolbox
import Foundation

/// Reads a Standard MIDI File (.mid, .midi, .kar) with AudioToolbox's `MusicSequence`:
/// notes by track and channel (in beats, held on by the sustain pedal), program, volume,
/// every tempo and time signature, key signature, track names and karaoke lyrics. Then finds
/// the chords.
enum MidiFileReader {
    enum Failure: Error { case unreadable, empty }

    private struct RawTrack {
        var name = ""
        var instrumentName = ""
        var texts: [MidiScore.Lyric] = []
        var lyrics: [MidiScore.Lyric] = []
        var notes: [Int: [MidiScore.Note]] = [:]
        var programs: [Int: Int] = [:]
        var volume: [Int: Int] = [:]
        var expression: [Int: Int] = [:]
        /// Sustain pedal changes by channel: (beat, down).
        var pedal: [Int: [(Double, Bool)]] = [:]
    }

    static func read(_ data: Data) throws -> MidiScore {
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr, let sequence else { throw Failure.unreadable }
        defer { DisposeMusicSequence(sequence) }
        guard MusicSequenceFileLoadData(sequence, data as CFData, .midiType, []) == noErr else { throw Failure.unreadable }

        var tempos: [MidiScore.Tempo] = []
        var meters: [MidiScore.Meter] = []
        var key: String?
        var raws: [RawTrack] = []
        var length = 0.0

        func read(_ track: MusicTrack, into raw: inout RawTrack) {
            var iterator: MusicEventIterator?
            guard NewMusicEventIterator(track, &iterator) == noErr, let iterator else { return }
            defer { DisposeMusicEventIterator(iterator) }
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            while hasEvent.boolValue {
                var time: MusicTimeStamp = 0
                var type: MusicEventType = 0
                var pointer: UnsafeRawPointer?
                var size: UInt32 = 0
                if MusicEventIteratorGetEventInfo(iterator, &time, &type, &pointer, &size) == noErr, let pointer {
                    switch type {
                    case kMusicEventType_MIDINoteMessage:
                        let n = pointer.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                        if n.velocity > 0, n.duration > 0 {
                            raw.notes[Int(n.channel & 0x0F), default: []].append(
                                MidiScore.Note(pitch: Int(n.note), start: time, length: Double(n.duration), velocity: Int(n.velocity)))
                            length = max(length, time + Double(n.duration))
                        }
                    case kMusicEventType_MIDIChannelMessage:
                        let m = pointer.assumingMemoryBound(to: MIDIChannelMessage.self).pointee
                        let channel = Int(m.status & 0x0F)
                        switch m.status & 0xF0 {
                        case 0xC0: if raw.programs[channel] == nil { raw.programs[channel] = Int(m.data1) }
                        case 0xB0 where m.data1 == 7: if raw.volume[channel] == nil { raw.volume[channel] = Int(m.data2) }
                        case 0xB0 where m.data1 == 11: if raw.expression[channel] == nil { raw.expression[channel] = Int(m.data2) }
                        case 0xB0 where m.data1 == 64: raw.pedal[channel, default: []].append((time, m.data2 >= 64))
                        default: break
                        }
                    case kMusicEventType_ExtendedTempo:
                        let bpm = pointer.assumingMemoryBound(to: ExtendedTempoEvent.self).pointee.bpm
                        if bpm > 0 { tempos.append(.init(beat: time, bpm: bpm)) }
                    case kMusicEventType_Meta:
                        let meta = pointer.assumingMemoryBound(to: MIDIMetaEvent.self)
                        let count = Int(meta.pointee.dataLength)
                        // The bytes run past the struct's one-byte `data` field: read them where they are.
                        let start = UnsafeRawPointer(meta) + MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data)!
                        let bytes = Array(UnsafeRawBufferPointer(start: start, count: count))
                        switch meta.pointee.metaEventType {
                        case 0x03: if raw.name.isEmpty { raw.name = text(bytes) }
                        case 0x04: if raw.instrumentName.isEmpty { raw.instrumentName = text(bytes) }
                        case 0x05: raw.lyrics.append(.init(beat: time, text: text(bytes)))
                        case 0x01: raw.texts.append(.init(beat: time, text: text(bytes)))
                        case 0x58 where bytes.count >= 2:
                            let num = Int(bytes[0]), den = 1 << Int(bytes[1])
                            if num > 0 { meters.append(.init(beat: time, barBeats: Double(num) * 4 / Double(den), label: "\(num)/\(den)")) }
                        case 0x59 where bytes.count >= 2 && key == nil:
                            let sharps = Int(Int8(bitPattern: bytes[0])), minor = bytes[1] == 1
                            // Circle of fifths from C (or A minor).
                            let pc = ((sharps * 7) % 12 + 12 + (minor ? 9 : 0)) % 12
                            key = ChordName.noteName(pc, flat: sharps < 0, latin: false) + (minor ? "m" : "")
                        default: break
                        }
                    default: break
                    }
                }
                MusicEventIteratorNextEvent(iterator)
                MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            }
        }

        var tempoTrack: MusicTrack?
        var global = RawTrack()
        if MusicSequenceGetTempoTrack(sequence, &tempoTrack) == noErr, let tempoTrack { read(tempoTrack, into: &global) }
        var count: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &count)
        for t in 0..<count {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(sequence, t, &track) == noErr, let track else { continue }
            var raw = RawTrack()
            read(track, into: &raw)
            raws.append(raw)
        }

        // Lyrics: lyric events wherever they are; else (.kar) the text events of the track that
        // has most of them, without «@» headers. A few texts are names or credits, not lyrics.
        var lyrics = (raws + [global]).flatMap(\.lyrics)
        if lyrics.count < 8 {
            let karaoke = (raws + [global]).max { $0.texts.count < $1.texts.count }
            lyrics = (karaoke?.texts ?? []).filter { !$0.text.hasPrefix("@") && !$0.text.hasPrefix("%") }
        }
        if lyrics.count < 8 { lyrics = [] }
        lyrics.sort { $0.beat < $1.beat }

        // Mix: a channel's volume and expression scale its velocities (relative to the loudest).
        var levels: [Int: Double] = [:]
        for raw in raws {
            for ch in raw.notes.keys { levels[ch] = Double(raw.volume[ch] ?? 100) * Double(raw.expression[ch] ?? 127) / 127 }
        }
        let loudest = max(1, levels.values.max() ?? 100)

        var tracks: [MidiScore.Track] = []
        for raw in raws {
            // A track's name: its name event, its instrument name, or a lone text at the start.
            var name = raw.name.isEmpty ? raw.instrumentName : raw.name
            if name.isEmpty, raw.texts.count <= 2, let first = raw.texts.first, first.beat < 1e-6 { name = first.text }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            for (channel, notes) in raw.notes.sorted(by: { $0.key < $1.key }) {
                let level = (levels[channel] ?? 100) / loudest
                let held = sustained(notes.sorted { $0.start < $1.start }, pedal: raw.pedal[channel] ?? [])
                    .map { n -> MidiScore.Note in
                        var n = n
                        n.velocity = max(1, min(127, Int((Double(n.velocity) * level).rounded())))
                        return n
                    }
                for n in held { length = max(length, n.start + n.length) }
                tracks.append(MidiScore.Track(id: tracks.count, name: raw.notes.count > 1 && !name.isEmpty ? "\(name) \(channel + 1)" : name,
                                              channel: channel, program: raw.programs[channel] ?? 0, drums: channel == 9,
                                              notes: held))
            }
        }
        guard !tracks.isEmpty else { throw Failure.empty }

        tempos.sort { $0.beat < $1.beat }
        meters.sort { $0.beat < $1.beat }
        // Repeated changes to the same value say nothing.
        tempos = tempos.reduce(into: []) { out, t in if out.last?.bpm != t.bpm { out.append(t) } }
        meters = meters.reduce(into: []) { out, m in if out.last?.label != m.label { out.append(m) } }
        if meters.first.map({ $0.beat > 1e-6 }) ?? true { meters.insert(MidiScore.Meter(beat: 0, barBeats: 4, label: "4/4"), at: 0) }
        let first = meters[0]
        var score = MidiScore(tracks: tracks, bpm: tempos.first { $0.beat < 1e-6 }?.bpm ?? tempos.first?.bpm ?? 120,
                              barBeats: first.barBeats, timeSignature: first.label, lengthBeats: length,
                              lyrics: lyrics, chords: [], key: key, tempos: tempos, meters: meters)
        // The song ends with the bar of its last note.
        if let last = score.barStarts.last {
            let m = meters.last { $0.beat <= last + 1e-6 } ?? first
            score.lengthBeats = max(length, last + m.barBeats)
        }
        score.chords = MidiChords.named(score)
        return score
    }

    private static func text(_ bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: .isoLatin1) ?? ""
    }

    /// Notes let go while the sustain pedal is down keep sounding until it comes up (or the same
    /// key is played again).
    private static func sustained(_ notes: [MidiScore.Note], pedal: [(Double, Bool)]) -> [MidiScore.Note] {
        guard !pedal.isEmpty else { return notes }
        let pedal = pedal.sorted { $0.0 < $1.0 }
        func isDown(at beat: Double) -> Bool { pedal.last { $0.0 <= beat }?.1 ?? false }
        func upAfter(_ beat: Double) -> Double? { pedal.first { $0.0 > beat && !$0.1 }?.0 }
        var nextSame: [Int: Double] = [:]
        var out = notes
        for i in out.indices.reversed() {
            let n = out[i]
            let end = n.start + n.length
            if isDown(at: end) {
                var newEnd = upAfter(end) ?? end
                if let again = nextSame[n.pitch] { newEnd = min(newEnd, again) }
                out[i].length = max(n.length, newEnd - n.start)
            }
            nextSame[n.pitch] = n.start
        }
        return out
    }
}
