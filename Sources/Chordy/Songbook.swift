import Combine
import Foundation

/// The songs with chords to play along with: imported from text or ChordPro files, kept in
/// `~/Library/Application Support/Chordy/songbook.json`. Follows what the player plays and
/// moves the highlighted chord along the open song (on the Mac and on the iPad).
@MainActor
final class Songbook: ObservableObject {
    @Published private(set) var sheets: [ChordSheet] = []
    /// Song open in «Repertorio» (and on the iPad).
    @Published private(set) var openId: String?
    /// Chord being played in the open song (−1: before the first).
    @Published private(set) var position = -1
    /// Move along the song as the player plays.
    @Published var following = UserDefaults.standard.object(forKey: "sheetFollow") as? Bool ?? true {
        didSet { UserDefaults.standard.set(following, forKey: "sheetFollow") }
    }

    /// Chord names in solfège (Do, Re, Mi) instead of letters.
    @Published var latin = UserDefaults.standard.bool(forKey: "sheetLatin") {
        didSet { UserDefaults.standard.set(latin, forKey: "sheetLatin") }
    }

    private let engine: ChordEngine
    /// Plays the open song when it came from a MIDI file.
    let player: MidiSongPlayer
    /// Key shown for each song, by id (parsing every song on each redraw adds up).
    private var keys: [String: (source: String, transpose: Int, key: String?)] = [:]
    private var follower = ChordFollower()
    private var cancellables = Set<AnyCancellable>()
    private var cache: (id: String, source: String, parsed: ParsedSheet)?

    static let textTypes = ["txt", "cho", "chordpro", "chopro", "crd", "pro", "text"]
    static let midiTypes = ["mid", "midi", "kar", "smf"]
    static var fileTypes: [String] { textTypes + midiTypes }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("songbook.json")
    }

    init(engine: ChordEngine, instruments: InstrumentLibrary) {
        self.engine = engine
        player = MidiSongPlayer(engine: engine, instruments: instruments)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL), let list = try? decoder.decode([ChordSheet].self, from: data) {
            sheets = list
        }
        let saved = UserDefaults.standard.string(forKey: "songbookOpen")
        openId = sheets.contains { $0.id == saved } ? saved : sheets.first?.id
    }

    func start() {
        // What the player holds: chords from pads/keys and single notes from MIDI keyboards.
        // @Published fires before the change, so read it on the next run loop turn.
        engine.$sounding.combineLatest(engine.$heldNotes)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.played() }
            .store(in: &cancellables)
        // A MIDI song playing moves the highlighted chord by time.
        player.$beat.receive(on: RunLoop.main).sink { [weak self] _ in self?.followPlayer() }.store(in: &cancellables)
        player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        loadPlayer()
    }

    private func loadPlayer() {
        player.load(open?.id, score: open?.midi, transpose: open?.transpose ?? 0)
    }

    private func followPlayer() {
        guard player.playing || player.beat > 0, let sheet = open, let score = sheet.midi, player.sheetId == sheet.id,
              let parsed = openParsed, parsed.chords.count == score.chords.count else { return }
        let i = score.chordIndex(at: player.beat)
        if i != position {
            follower.seek(i)
            position = i
        }
    }

    // MARK: Open song

    var open: ChordSheet? { sheets.first { $0.id == openId } }

    /// The open song read into lines and chords (kept until its text changes).
    var openParsed: ParsedSheet? {
        guard let sheet = open else { return nil }
        if let cache, cache.id == sheet.id, cache.source == sheet.source { return cache.parsed }
        let parsed = sheet.parsed
        cache = (sheet.id, sheet.source, parsed)
        return parsed
    }

    /// The song's key as shown (transposed), for lists.
    func shownKey(_ sheet: ChordSheet) -> String? {
        if let k = keys[sheet.id], k.source == sheet.source, k.transpose == sheet.transpose { return k.key }
        let key = sheet.parsed.displayKey(transpose: sheet.transpose)
        keys[sheet.id] = (sheet.source, sheet.transpose, key)
        return key
    }

    func open(_ id: String?) {
        guard id != openId else { return }
        openId = id
        UserDefaults.standard.set(id, forKey: "songbookOpen")
        seek(-1)
        loadPlayer()
    }

    func seek(_ index: Int) {
        let count = openParsed?.chords.count ?? 0
        let i = max(-1, min(count - 1, index))
        follower.seek(i)
        position = i
    }

    func step(_ delta: Int) { seek(position + delta) }

    func setTranspose(_ id: String, _ semitones: Int) {
        guard let i = sheets.firstIndex(where: { $0.id == id }) else { return }
        // −6…+6 covers every key; wrap so ± keeps going round.
        var t = semitones
        while t > 6 { t -= 12 }
        while t < -6 { t += 12 }
        sheets[i].transpose = t
        persist()
        if id == openId { loadPlayer() }
    }

    private func played() {
        // A playing MIDI song moves by time, not by what's played.
        guard following, !player.playing, let sheet = open, let parsed = openParsed else { return }
        var pcs = Set<Int>()
        for chord in engine.sounding where chord.source == .user { for n in chord.notes { pcs.insert(n % 12) } }
        for note in engine.heldNotes.values { pcs.insert(note.midi % 12) }
        if follower.update(pcs, chords: parsed.chords, transpose: sheet.transpose) {
            position = follower.position
        }
    }

    // MARK: Library

    /// Adds a song from pasted text or a file's contents; returns its id.
    @discardableResult
    func importText(_ text: String, title: String? = nil) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let result = ChordSheetImport.chordPro(from: trimmed, fallbackTitle: title.flatMap { $0.isEmpty ? nil : $0 })
        let sheet = ChordSheet(id: UUID().uuidString, title: result.title, artist: result.artist, source: result.source,
                               addedAt: Date())
        sheets.append(sheet)
        sortSheets()
        persist()
        open(sheet.id)
        return sheet.id
    }

    /// Text and ChordPro files. Returns how many were added.
    @discardableResult
    func importFiles(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls where Self.fileTypes.contains(url.pathExtension.lowercased()) {
            var name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            name = name.prefix(1).uppercased() + name.dropFirst()
            if Self.midiTypes.contains(url.pathExtension.lowercased()) {
                if let data = try? Data(contentsOf: url), data.count < 8_000_000, importMidi(data, title: name) != nil { added += 1 }
                continue
            }
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { continue }
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
            guard let text else { continue }
            if importText(text, title: name) != nil { added += 1 }
        }
        return added
    }

    /// Adds a song from a MIDI file: its notes, and its chords (and lyrics) as the text.
    @discardableResult
    func importMidi(_ data: Data, title: String) -> String? {
        guard let score = try? MidiFileReader.read(data) else { return nil }
        let source = MidiChords.chordPro(score, title: title, artist: nil)
        let sheet = ChordSheet(id: UUID().uuidString, title: title, artist: nil, source: source, addedAt: Date(), midi: score)
        sheets.append(sheet)
        sortSheets()
        persist()
        open(sheet.id)
        return sheet.id
    }

    func update(_ id: String, title: String, artist: String, source: String) {
        guard let i = sheets.firstIndex(where: { $0.id == id }) else { return }
        var s = sheets[i]
        s.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? s.title : title.trimmingCharacters(in: .whitespaces)
        let a = artist.trimmingCharacters(in: .whitespaces)
        s.artist = a.isEmpty ? nil : a
        // Edited text may be chords over lyrics again (pasted in): convert it the same way.
        s.source = ChordSheetImport.isChordPro(source) ? source : ChordSheetImport.chordPro(from: source, fallbackTitle: s.title).source
        s.updatedAt = Date()
        sheets[i] = s
        sortSheets()
        persist()
        if id == openId { seek(-1) }
    }

    func remove(_ id: String) {
        sheets.removeAll { $0.id == id }
        persist()
        if openId == id { open(sheets.first?.id) }
    }

    private func sortSheets() {
        sheets.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(sheets).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("Chordy: could not save the songbook: \(error)")
        }
    }

    // MARK: Into Chordy

    /// The song's key (transposed) as Chordy's tonic and mode.
    func key(of sheet: ChordSheet, _ parsed: ParsedSheet) -> (Note, Flavor)? {
        guard let k = parsed.keyChord else { return nil }
        let minor = [.minor, .minor7, .minor6].contains(k.quality)
        return (Note.at(k.root + sheet.transpose), minor ? .minor : .major)
    }

    /// Sets Chordy's key to the song's, so the degree pads play its chords.
    func useKey() {
        guard let sheet = open, let parsed = openParsed, let (tonic, flavor) = key(of: sheet, parsed) else { return }
        engine.tonic = tonic
        engine.flavor = flavor
    }

    /// A loop with the song's chords, one bar each, in its key. Returns the loop id.
    func makeLoop(into loops: Loops) -> String? {
        guard let sheet = open, let parsed = openParsed, !parsed.chords.isEmpty else { return nil }
        let (tonic, flavor) = key(of: sheet, parsed) ?? (Note.at(parsed.chords[0].root + sheet.transpose), .major)
        let beats = LoopMath.beatsPerBar
        // From a MIDI file the chords keep their place in time; otherwise one bar each.
        let timed = sheet.midi.flatMap { $0.chords.count == parsed.chords.count ? $0 : nil }
        let total = timed.map { ($0.lengthBeats / beats).rounded(.up) * beats } ?? Double(parsed.chords.count) * beats
        let events = parsed.chords.enumerated().map { i, chord -> LoopEvent in
            let c = chord.transposed(sheet.transpose)
            let (degree, accidental) = Music.root(ofPitchClass: c.root, tonic, flavor)
            let start = timed.map { $0.chords[i].beat } ?? Double(i) * beats
            let end = timed.map { i + 1 < $0.chords.count ? $0.chords[i + 1].beat : total } ?? start + beats
            return LoopEvent(degree: degree, color: Self.color(c.quality), accidental: accidental,
                             start: start, length: max(0.25, end - start))
        }
        var loop = loops.createEmpty(bars: Int(total / beats))
        loop.name = sheet.title
        loop.tonic = tonic
        loop.flavor = flavor
        loop.events = events
        loops.save(loop)
        return loop.id
    }

    /// A loop with one track of the open MIDI song (its notes, its instrument). Returns the loop id.
    func makeLoop(track id: Int, into loops: Loops) -> String? {
        guard let sheet = open, let score = sheet.midi, let track = score.tracks.first(where: { $0.id == id }),
              !track.notes.isEmpty else { return nil }
        let shift = track.drums ? 0 : sheet.transpose
        let events = track.notes.compactMap { n -> LoopEvent? in
            let pitch = n.pitch + shift
            guard (0...127).contains(pitch) else { return nil }
            var e = LoopEvent(degree: 1, color: .diatonic, start: n.start, length: n.length)
            e.midi = pitch
            e.velocity = n.velocity
            return e
        }
        let bars = max(1, Int((score.lengthBeats / LoopMath.beatsPerBar).rounded(.up)))
        var loop = loops.createEmpty(bars: bars)
        loop.name = "\(sheet.title) · \(trackName(track))"
        loop.bpm = Int(score.bpm.rounded())
        loop.events = events
        loop.instrument = SoundRoute.parse(player.route(track)).instrument
        loops.save(loop)
        return loop.id
    }

    func trackName(_ track: MidiScore.Track) -> String {
        if !track.name.isEmpty { return track.name }
        return track.drums ? tr("Batería") : tr("Pista %d", track.id + 1)
    }

    /// The nearest of Chordy's chord colors.
    static func color(_ q: ChordName.Quality) -> ChordColor {
        switch q {
        case .major, .power, .sixth: return .major
        case .minor, .minorMajor7, .minor6: return .minor
        case .diminished, .diminished7, .halfDiminished: return .diminished
        case .augmented: return .augmented
        case .sus2: return .sus2
        case .sus4: return .sus4
        case .seventh: return .seventh
        case .major7: return .maj7
        case .minor7: return .minor7
        case .add9: return .add9
        }
    }
}
