import SwiftUI

/// Controls of a MIDI song in «Repertorio»: play, where it is, speed, tracks (mute, to a loop)
/// and practice (one track is yours: the song waits for its notes).
struct MidiSongBar: View {
    @ObservedObject var player: MidiSongPlayer
    let songbook: Songbook
    let score: MidiScore
    let loops: Loops
    @Binding var showRoll: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "stop.fill" : "play.fill").frame(width: 30)
            }
            .buttonStyle(AppButtonStyle(kind: player.playing ? .primary : .secondary, height: 30, padding: 0))
            .help(player.playing ? tr("Parar") : tr("Reproducir el MIDI"))
            IconButton(symbol: "backward.end.fill", label: tr("Al principio"), size: 30) { player.rewind() }
            Text(position)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .frame(minWidth: 92, alignment: .leading)
            Menu {
                ForEach([0.5, 0.6, 0.75, 0.9, 1.0, 1.1, 1.25], id: \.self) { s in
                    Button("\(Int(s * 100)) %") { player.speed = s }
                }
            } label: {
                Text(tr("Velocidad %d %%", Int((player.speed * 100).rounded())) + " · \(Int(player.bpm.rounded())) BPM")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            tracksMenu
            practiceMenu
            if player.waiting {
                Label(tr("Toca: %@", expectedNames), systemImage: "hand.point.down.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warn)
            }
            Spacer()
            Toggle(tr("Notas"), isOn: $showRoll)
                .toggleStyle(.switch).controlSize(.small).tint(Theme.accentFill)
                .foregroundStyle(Theme.text2)
                .help(tr("Ver las notas cayendo sobre un teclado"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Theme.sidebar)
    }

    private var position: String {
        let bar = Int(player.beat / score.barBeats) + 1
        return tr("Compás %d / %d", min(bar, score.bars), score.bars)
    }

    private var expectedNames: String {
        player.expected.sorted().map { Note.at($0).rawValue + "\($0 / 12 - 1)" }.joined(separator: " ")
    }

    private var tracksMenu: some View {
        Menu {
            ForEach(score.tracks) { t in
                Menu("\(songbook.trackName(t)) · \(MidiScore.family(t)) · \(t.notes.count)") {
                    Button(player.muted.contains(t.id) ? tr("Que suene") : tr("Silenciar")) {
                        if player.muted.contains(t.id) { player.muted.remove(t.id) } else { player.muted.insert(t.id) }
                    }
                    Button(tr("Crear un loop con esta pista")) {
                        if let id = songbook.makeLoop(track: t.id, into: loops) {
                            loops.studioId = id
                            UserDefaults.standard.set("editor", forKey: "mainMode")
                        }
                    }
                }
            }
        } label: {
            Text(tr("Pistas (%d)", score.tracks.count) + (player.muted.isEmpty ? "" : " · " + tr("%d en silencio", player.muted.count)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var practiceMenu: some View {
        Menu {
            Button(tr("Sin práctica")) { player.practiceTrack = nil }
            Divider()
            ForEach(score.tracks.filter { !$0.drums }) { t in
                Button("\(songbook.trackName(t)) · \(MidiScore.family(t))") { player.practiceTrack = t.id }
            }
            Divider()
            Toggle(tr("En la octava exacta"), isOn: $player.exactOctave)
        } label: {
            if let p = player.practiceTrack, let t = score.tracks.first(where: { $0.id == p }) {
                Text(tr("Práctica: %@", songbook.trackName(t)))
            } else {
                Text(tr("Práctica"))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tr("Elige la pista que tocas tú: la canción espera a que toques sus notas"))
    }
}

/// The falling notes of the open MIDI song, with the keys the player holds.
struct MidiRollPanel: View {
    @ObservedObject var player: MidiSongPlayer
    let score: MidiScore
    let transpose: Int
    let engine: ChordEngine

    var body: some View {
        PianoRoll(score: score, transpose: transpose, playing: player.playing,
                  beat: { [player] in player.beatNow() },
                  muted: player.muted, practice: player.practiceTrack, expected: player.expected,
                  held: { [engine] in
                      MainActor.assumeIsolated {
                          var set = Set(engine.heldNotes.values.map(\.midi))
                          for c in engine.sounding where c.source == .user { set.formUnion(c.notes) }
                          return set
                      }
                  },
                  style: RollStyle(background: Theme.field, line: Theme.line, text: Theme.text3,
                                   whiteKey: Color(white: 0.93), blackKey: Color(white: 0.12), held: Theme.accentFill,
                                   expected: Theme.warn, tracks: KeyboardConfig.palette))
    }
}

extension MidiScore {
    /// General MIDI family of a track's program («Piano», «Cuerdas»…).
    static func family(_ track: Track) -> String {
        if track.drums { return tr("Batería") }
        let names = [tr("Piano"), tr("Percusión afinada"), tr("Órgano"), tr("Guitarra"), tr("Bajo"), tr("Cuerdas"),
                     tr("Conjunto"), tr("Metales"), tr("Lengüeta"), tr("Flauta"), tr("Sinte solista"), tr("Pad"),
                     tr("Efectos de sinte"), tr("Étnico"), tr("Percusión"), tr("Efectos")]
        return names[max(0, min(127, track.program)) / 8]
    }
}
