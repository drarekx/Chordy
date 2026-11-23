import AudioToolbox
import Foundation

/// Reads a Standard MIDI File (.mid, .midi, .kar) with AudioToolbox's `MusicSequence`:
/// notes by track (in beats), program, the first tempo and time signature, key signature and
/// karaoke lyrics. Then finds the chords.
enum MidiFileReader {
    enum Failure: Error { case unreadable, empty }

    static func read(_ data: Data) throws -> MidiScore {
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr, let sequence else { throw Failure.unreadable }
        defer { DisposeMusicSequence(sequence) }
        guard MusicSequenceFileLoadData(sequence, data as CFData, .midiType, []) == noErr else { throw Failure.unreadable }

        var bpm = 120.0
        var barBeats = 4.0
        var timeSignature = "4/4"
        var key: String?
        var lyrics: [MidiScore.Lyric] = []
        var texts: [MidiScore.Lyric] = []

        func readMeta(_ meta: UnsafePointer<MIDIMetaEvent>, at beat: Double) -> (type: UInt8, bytes: [UInt8]) {
            let length = Int(meta.pointee.dataLength)
            // The bytes run past the struct's one-byte `data` field: read them where they are.
            let start = UnsafeRawPointer(meta) + MemoryLayout<MIDIMetaEvent>.offset(of: \MIDIMetaEvent.data)!
            let bytes = Array(UnsafeRawBufferPointer(start: start, count: length))
            return (meta.pointee.metaEventType, bytes)
        }

        func text(_ bytes: [UInt8]) -> String {
            String(data: Data(bytes), encoding: .utf8) ?? String(data: Data(bytes), encoding: .isoLatin1) ?? ""
        }

        /// Walks every event of a track.
        func events(_ track: MusicTrack, _ body: (MusicTimeStamp, MusicEventType, UnsafeRawPointer) -> Void) {
            var iterator: MusicEventIterator?
            guard NewMusicEventIterator(track, &iterator) == noErr, let iterator else { return }
            defer { DisposeMusicEventIterator(iterator) }
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            while hasEvent.boolValue {
                var time: MusicTimeStamp = 0
                var type: MusicEventType = 0
                var data: UnsafeRawPointer?
                var size: UInt32 = 0
                if MusicEventIteratorGetEventInfo(iterator, &time, &type, &data, &size) == noErr, let data {
                    body(time, type, data)
                }
                MusicEventIteratorNextEvent(iterator)
                MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
            }
        }

        // Tempo track: tempo, time signature, key; some files keep lyrics there too.
        var gotTempo = false, gotTime = false
        func readGlobalMeta(_ time: MusicTimeStamp, _ type: MusicEventType, _ data: UnsafeRawPointer) {
            if type == kMusicEventType_ExtendedTempo, !gotTempo {
                bpm = data.assumingMemoryBound(to: ExtendedTempoEvent.self).pointee.bpm
                gotTempo = true
            } else if type == kMusicEventType_Meta {
                let (metaType, bytes) = readMeta(data.assumingMemoryBound(to: MIDIMetaEvent.self), at: time)
                switch metaType {
                case 0x58 where bytes.count >= 2 && !gotTime:
                    let num = Int(bytes[0]), den = 1 << Int(bytes[1])
                    if num > 0, den > 0 {
                        barBeats = Double(num) * 4 / Double(den)
                        timeSignature = "\(num)/\(den)"
                        gotTime = true
                    }
                case 0x59 where bytes.count >= 2 && key == nil:
                    let sharps = Int(Int8(bitPattern: bytes[0])), minor = bytes[1] == 1
                    // Circle of fifths from C (or A minor).
                    let pc = ((sharps * 7) % 12 + 12 + (minor ? 9 : 0)) % 12
                    key = ChordName.noteName(pc, flat: sharps < 0, latin: false) + (minor ? "m" : "")
                case 0x05: lyrics.append(.init(beat: time, text: text(bytes)))
                case 0x01: texts.append(.init(beat: time, text: text(bytes)))
                default: break
                }
            }
        }
        var tempoTrack: MusicTrack?
        if MusicSequenceGetTempoTrack(sequence, &tempoTrack) == noErr, let tempoTrack {
            events(tempoTrack, readGlobalMeta)
        }

        var count: UInt32 = 0
        MusicSequenceGetTrackCount(sequence, &count)
        var tracks: [MidiScore.Track] = []
        var length = 0.0
        for t in 0..<count {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(sequence, t, &track) == noErr, let track else { continue }
            var name = ""
            // Notes by channel: one MIDI track can carry several instruments.
            var byChannel: [Int: [MidiScore.Note]] = [:]
            var programs: [Int: Int] = [:]
            events(track) { time, type, data in
                switch type {
                case kMusicEventType_MIDINoteMessage:
                    let n = data.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                    guard n.velocity > 0, n.duration > 0 else { return }
                    byChannel[Int(n.channel & 0x0F), default: []].append(
                        MidiScore.Note(pitch: Int(n.note), start: time, length: Double(n.duration), velocity: Int(n.velocity)))
                    length = max(length, time + Double(n.duration))
                case kMusicEventType_MIDIChannelMessage:
                    let m = data.assumingMemoryBound(to: MIDIChannelMessage.self).pointee
                    if m.status & 0xF0 == 0xC0, programs[Int(m.status & 0x0F)] == nil { programs[Int(m.status & 0x0F)] = Int(m.data1) }
                case kMusicEventType_Meta:
                    let (metaType, bytes) = readMeta(data.assumingMemoryBound(to: MIDIMetaEvent.self), at: time)
                    if metaType == 0x03, name.isEmpty { name = text(bytes).trimmingCharacters(in: .whitespacesAndNewlines) }
                    else { readGlobalMeta(time, type, data) }
                default:
                    readGlobalMeta(time, type, data)
                }
            }
            for (channel, notes) in byChannel.sorted(by: { $0.key < $1.key }) {
                let drums = channel == 9
                tracks.append(MidiScore.Track(id: tracks.count, name: name, channel: channel,
                                              program: programs[channel] ?? 0, drums: drums,
                                              notes: notes.sorted { $0.start < $1.start }))
            }
        }
        guard !tracks.isEmpty else { throw Failure.empty }

        // .kar files keep the lyrics as text events (and «@» headers); standard files as lyric events.
        if lyrics.isEmpty { lyrics = texts.filter { !$0.text.hasPrefix("@") && !$0.text.hasPrefix("%") } }
        // A handful of text events is copyright or notes, not lyrics.
        if lyrics.count < 8 { lyrics = [] }
        lyrics.sort { $0.beat < $1.beat }

        var score = MidiScore(tracks: tracks, bpm: bpm, barBeats: barBeats, timeSignature: timeSignature,
                              lengthBeats: (length / barBeats).rounded(.up) * barBeats, lyrics: lyrics, chords: [], key: key)
        score.chords = MidiChords.named(score)
        return score
    }
}
