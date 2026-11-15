import AppKit
import SwiftUI

/// Colors of who is playing: each keyboard its own, the Mac keys/pads the accent, loops dimmer.
@MainActor
struct LaneColors {
    let keyboards: Keyboards

    func color(_ owner: String?, source: ChordSource) -> Color {
        if source == .loop { return Theme.accentBorder }
        if let owner, let config = keyboards.config(owner) { return config.tint }
        return Theme.accentFill
    }
}

// MARK: - Studio

/// The main window: every keyboard with its own sound, what sounds now, the drum machine,
/// and loops / chords / sound / MIDI on the right. Fills the screen in full screen.
struct StudioView: View {
    @ObservedObject var model = AppModel.shared
    @AppStorage("sideTab") private var sideTab = SideTab.loops
    @AppStorage("mainMode") private var mode = Mode.studio
    @ObservedObject private var keyboards = AppModel.shared.keyboards

    enum Mode: String { case studio, song, drums, synth, editor }

    enum SideTab: String, CaseIterable {
        case loops, chords, sound, midi

        var title: String {
            switch self {
            case .loops: return tr("Loops")
            case .chords: return tr("Acordes")
            case .sound: return tr("Sonido")
            case .midi: return "MIDI"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioHeader(engine: model.engine, loops: model.loops, drums: model.drums, keyboards: model.keyboards,
                         midi: model.midi, mode: $mode)
            Rectangle().fill(Theme.line).frame(height: 1)
            if mode == .drums {
                DrumView(drums: model.drums, engine: model.engine)
            } else if mode == .song {
                SongView(song: model.song, loops: model.loops, drums: model.drums, engine: model.engine)
            } else if mode == .synth {
                SynthStudio(sounds: model.sounds, keyboards: model.keyboards, engine: model.engine)
            } else if mode == .editor {
                EditorHost(loops: model.loops, instruments: model.instruments, drums: model.drums) { mode = .studio }
            } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 14) {
                    KeyboardCards(keyboards: model.keyboards, midi: model.midi, devices: model.midi.devices, engine: model.engine,
                                  instruments: model.instruments, editing: $keyboards.editing)
                    SoundRoll(engine: model.engine, keyboards: model.keyboards)
                        .frame(minHeight: 150, maxHeight: .infinity)
                    DrumPanel(drums: model.drums, instruments: model.instruments)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 14) {
                    MixerPanel(keyboards: model.keyboards, drums: model.drums, loops: model.loops)
                    SegmentedControl(options: SideTab.allCases.map { ($0.title, $0) }, selection: $sideTab, expand: true)
                    switch sideTab {
                    case .loops: LoopPanel(loops: model.loops)
                    case .chords: ChordsTab(engine: model.engine)
                    case .sound: SoundPanel(sounds: model.sounds, instruments: model.instruments)
                    case .midi: MidiPanel(midi: model.midi)
                    }
                }
                .frame(width: 360)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
            }
        }
        .background(Theme.window)
        .sheet(item: Binding(get: { keyboards.editing.map(EditingId.init) }, set: { keyboards.editing = $0?.id })) { item in
            ThemedRoot {
                KeyboardSheet(keyboards: model.keyboards, midi: model.midi, instruments: model.instruments, id: item.id) {
                    keyboards.editing = nil
                }
            }
        }
    }

    private struct EditingId: Identifiable { let id: String }
}

// MARK: - Header

struct StudioHeader: View {
    // Plain references: each piece below watches only what it shows, so a note or a drum
    // step doesn't rebuild the whole header.
    let engine: ChordEngine
    let loops: Loops
    let drums: DrumMachine
    let keyboards: Keyboards
    let midi: MidiController
    @Binding var mode: StudioView.Mode

    var body: some View {
        HStack(spacing: 14) {
            ProjectMenu(projects: AppModel.shared.projects)
                .padding(.leading, 64)
            SegmentedControl(options: [(tr("Estudio"), StudioView.Mode.studio), (tr("Canción"), .song), (tr("Batería"), .drums),
                                       (tr("Sintetizador"), .synth)], selection: $mode)
                .fixedSize()
                .background {
                    Button("") { mode = mode == .drums ? .studio : .drums }
                        .keyboardShortcut("b", modifiers: .command)
                        .opacity(0)
                }
                .help(tr("Estudio o batería a pantalla completa (⌘B)"))
            TransportButtons(loops: loops, drums: drums, engine: engine, mode: mode)
            BeatIndicator(loops: loops, drums: drums)
            Headline(engine: engine).frame(maxWidth: .infinity, alignment: .leading)
            KeyAndTempo(engine: engine)
            AudioOutputMenu()
            ConnectedBadge(keyboards: keyboards, devices: midi.devices)
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: tr("Pantalla completa")) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 10)
        .background(Theme.sidebar)
    }
}

/// The loop editor as a mode: shows the loop chosen with «Editar», or a hint.
private struct EditorHost: View {
    @ObservedObject var loops: Loops
    let instruments: InstrumentLibrary
    let drums: DrumMachine
    let back: () -> Void

    var body: some View {
        if let id = loops.studioId, let loop = loops.loops.first(where: { $0.id == id }) {
            LoopStudio(loops: loops, instruments: instruments, drums: drums, loop: loop) {
                loops.studioId = nil
                back()
            }
            .id(id)
        } else {
            VStack(spacing: 10) {
                Text(tr("Elige un loop y pulsa «Editar»")).font(.system(size: 15, weight: .semibold))
                Button(tr("Volver al estudio"), action: back).buttonStyle(.appSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Project name (● when edited) with New, Open, recent, Save and Save as.
private struct ProjectMenu: View {
    @ObservedObject var projects: Projects

    var body: some View {
        Menu {
            Button(tr("Nuevo proyecto")) { projects.newProject() }
            Button(tr("Abrir…")) { projects.open() }
            if !projects.recent.isEmpty {
                Menu(tr("Recientes")) {
                    ForEach(projects.recent, id: \.self) { u in
                        Button(u.deletingPathExtension().lastPathComponent) { projects.openRecent(u) }
                    }
                }
            }
            Divider()
            Button(tr("Guardar")) { projects.save() }
            Button(tr("Guardar como…")) { projects.saveAs() }
        } label: {
            HStack(spacing: 5) {
                if projects.dirty { Circle().fill(Theme.warn).frame(width: 6, height: 6) }
                Text(projects.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(projects.dirty ? tr("Hay cambios sin guardar (se autoguardan cada 30 s)") : tr("Proyecto guardado"))
        .background {
            Group {
                Button("") { projects.newProject() }.keyboardShortcut("n", modifiers: .command)
                Button("") { projects.open() }.keyboardShortcut("o", modifiers: .command)
                Button("") { projects.save() }.keyboardShortcut("s", modifiers: .command)
                Button("") { projects.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            .opacity(0)
        }
    }
}

private struct TransportButtons: View {
    @ObservedObject var loops: Loops
    @ObservedObject var drums: DrumMachine
    let engine: ChordEngine
    let mode: StudioView.Mode

    var body: some View {
        HStack(spacing: 6) {
            IconButton(symbol: loops.isPlaying || drums.playing ? "pause.fill" : "play.fill",
                       label: tr("Reproducir loop y batería (P)"), kind: .secondary) { playAll() }
            IconButton(symbol: "record.circle", label: mode == .drums ? tr("Grabar batería tocando los pads") : tr("Grabar loop (R)"),
                       kind: (mode == .drums ? drums.recording : loops.isRecording) ? .primary : .secondary) {
                mode == .drums ? drums.toggleRecord() : loops.toggleRecord()
            }
            IconButton(symbol: "stop.fill", label: tr("Parar todo (Esc)"), kind: .secondary) { stopAll() }
        }
    }

    private func playAll() {
        if mode == .drums { return drums.togglePlay() }
        if loops.isPlaying || drums.playing {
            loops.stopPlayback()
            drums.stop()
        } else {
            if loops.selected != nil { loops.togglePlay() }
            drums.play()
        }
    }

    private func stopAll() {
        loops.stopPlayback()
        drums.stop()
        engine.stopAll()
    }
}

/// 1 · 2 · 3 · 4 and the bar while anything plays; red while recording. Counts from the take's
/// first bar when a loop is recording.
struct BeatIndicator: View {
    @ObservedObject private var clock = BeatClock.shared
    @ObservedObject var loops: Loops
    @ObservedObject var drums: DrumMachine

    var body: some View {
        let recording = loops.recorderState == .recording || drums.recording
        Group {
            if loops.recorderState == .armed {
                Label(tr("Toca para empezar a grabar"), systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            } else if let position = BeatIndicator.position(beat: clock.beat, takeStart: loops.recordStartBeat) {
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        let on = i == position.inBar
                        Text("\(i + 1)")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(on ? Theme.window : Theme.text3)
                            .background(on ? (recording ? Theme.danger : Theme.accentFill) : Theme.field,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    Text(tr("Compás %d", position.bar))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(recording ? Theme.danger : Theme.text2)
                        .frame(minWidth: 70, alignment: .leading)
                        .padding(.leading, 4)
                }
            }
        }
        .fixedSize()
    }

    /// Beat in the bar (0…3) and bar number (from 1) for a transport beat.
    static func position(beat: Int?, takeStart: Double?) -> (inBar: Int, bar: Int)? {
        guard let beat else { return nil }
        let relative = max(0, beat - Int(takeStart ?? 0))
        return (relative % 4, relative / 4 + 1)
    }
}

private struct Headline: View {
    @ObservedObject var engine: ChordEngine

    var body: some View {
        Text(engine.headline.isEmpty ? tr("Toca algo") : engine.headline.joined(separator: " · "))
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(engine.headline.isEmpty ? Theme.text3 : Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Key and tempo: rebuilt only when they change, not on every note.
private struct KeyAndTempo: View {
    let engine: ChordEngine
    @State private var tonic = Note.c
    @State private var flavor = Flavor.major
    @State private var bpm = 110
    @State private var chordType = ChordColor.diatonic

    var body: some View {
        HStack(spacing: 14) {
            pill {
                Text(tr("Acorde")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                Menu {
                    ChordTypeMenuItems(selected: chordType) { engine.chordType = $0 }
                } label: {
                    Text(chordType.name).monospacedText(size: 13)
                        .foregroundStyle(chordType == .diatonic ? Theme.text : Theme.accentText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(tr("Tipo de los acordes que tocas (mantener W A S D o los pads de color lo cambia un momento)"))
            }
            pill {
                Text(tr("Tono")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                IconButton(symbol: "chevron.left", label: tr("Tono anterior (Z)"), size: 22) { engine.shiftTonic(-1) }
                Menu {
                    ForEach(Flavor.allCases, id: \.self) { f in Button(f.label) { engine.flavor = f } }
                } label: {
                    Text("\(tonic.rawValue) \(flavor.label)").monospacedText(size: 13)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                IconButton(symbol: "chevron.right", label: tr("Tono siguiente (C)"), size: 22) { engine.shiftTonic(1) }
            }
            pill {
                Text(tr("Tempo")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                IconButton(symbol: "minus", label: tr("Más lento (−)"), size: 22) { engine.setBpm(engine.bpm - 1) }
                Text("\(bpm)").monospacedText(size: 13).frame(minWidth: 28)
                IconButton(symbol: "plus", label: tr("Más rápido (+)"), size: 22) { engine.setBpm(engine.bpm + 1) }
            }
        }
        .onReceive(engine.$tonic.removeDuplicates()) { tonic = $0 }
        .onReceive(engine.$flavor.removeDuplicates()) { flavor = $0 }
        .onReceive(engine.$bpm.removeDuplicates()) { bpm = $0 }
        .onReceive(engine.$chordType.removeDuplicates()) { chordType = $0 }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line) }
    }
}

private struct ConnectedBadge: View {
    @ObservedObject var keyboards: Keyboards
    @ObservedObject var devices: DeviceList

    var body: some View {
        let count = keyboards.configs.filter { devices.names.contains($0.device) }.count
        HStack(spacing: 6) {
            Circle().fill(count > 0 ? Theme.ok : Theme.text3).frame(width: 7, height: 7)
            Text(tr("%d teclados", count)).font(.system(size: 11)).foregroundStyle(Theme.text2)
        }
    }
}

// MARK: - Keyboard cards

struct KeyboardCards: View {
    @ObservedObject var keyboards: Keyboards
    let midi: MidiController
    @ObservedObject var devices: DeviceList
    /// Not observed: the keybeds inside watch the engine themselves.
    let engine: ChordEngine
    @ObservedObject var instruments: InstrumentLibrary
    @Binding var editing: String?

    var body: some View {
        if keyboards.configs.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "pianokeys").foregroundStyle(Theme.text3)
                Text(tr("Conecta un teclado MIDI: se añade solo. También puedes tocar con J U K I L O ; y la rueda de acordes."))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                Spacer()
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        } else {
            let cards = ForEach(keyboards.configs) { config in
                KeyboardCard(config: config, connected: devices.names.contains(config.device), keyboards: keyboards,
                             engine: engine, instruments: instruments) { editing = config.id }
                    .frame(maxWidth: .infinity)
            }
            if keyboards.configs.count <= 3 {
                HStack(alignment: .top, spacing: 14) { cards }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) { cards }
            }
        }
    }
}

struct KeyboardCard: View {
    let config: KeyboardConfig
    let connected: Bool
    @ObservedObject var keyboards: Keyboards
    let engine: ChordEngine
    @ObservedObject var instruments: InstrumentLibrary
    let configure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(config.tint).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(connected ? config.device : tr("%@ · desconectado", config.device))
                        .font(.system(size: 10)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                if keyboards.active == config.id {
                    Text(tr("activo"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(config.tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay { Capsule().strokeBorder(config.tint.opacity(0.6)) }
                        .help(tr("◀ ▶ del Launchkey, las teclas 1–8 y los botones de sonido del teclado cambian el sonido de este teclado"))
                }
                Spacer(minLength: 4)
                IconButton(symbol: config.showDevice == true ? "pianokeys.inverse" : "pianokeys",
                           label: tr("Ver el aparato: teclas, pads y controles en directo y a qué están asignados"),
                           kind: config.showDevice == true ? .primary : .secondary, size: 26) {
                    keyboards.update(config.id) { $0.showDevice = $0.showDevice == true ? nil : true }
                }
                Button { configure() } label: { Text(tr("Configurar")).fixedSize() }
                    .buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            }
            HStack(spacing: 8) {
                InstrumentMenu(instruments: instruments, selected: config.instrument) { id in
                    keyboards.update(config.id) { $0.instrument = id }
                }
                SegmentedControl(options: KeyLayout.allCases.map { ($0.label, $0) },
                                 selection: Binding(get: { config.layout },
                                                    set: { v in keyboards.update(config.id) { $0.layout = v } }))
                    .fixedSize()
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    IconButton(symbol: "minus", label: tr("Octava abajo"), size: 22) { keyboards.update(config.id) { $0.octave -= 1 } }
                    Text(config.octave == 0 ? "8va 0" : String(format: "8va %+d", config.octave))
                        .monospacedText(size: 11).fixedSize().frame(minWidth: 42)
                    IconButton(symbol: "plus", label: tr("Octava arriba"), size: 22) { keyboards.update(config.id) { $0.octave += 1 } }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(keyboards.favorites.indices, id: \.self) { slot in
                    favorite(slot)
                }
            }
            if config.showDevice == true {
                DeviceDrawing(config: config, midi: AppModel.shared.midi, engine: engine, drums: AppModel.shared.drums)
                    .frame(maxWidth: .infinity, maxHeight: 340)
            } else {
            PianoStrip(engine: engine, low: max(21, min(config.low, 96)), high: max(min(config.high, 108), max(21, min(config.low, 96)) + 11),
                       tint: { light in light.owner == config.id ? config.tint : nil })
                .frame(height: 40)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12).fill(config.tint).frame(height: 2)
        }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
        .opacity(connected ? 1 : 0.7)
    }

    /// One-click sound: the slot's number is also its key (1–8) and program change.
    private func favorite(_ slot: Int) -> some View {
        let id = keyboards.favorites[slot]
        let on = id == config.instrument
        let missing = Instrument.with(id).flatMap { InstrumentPack.with($0.pack) }.map { instruments.fileURL($0) == nil } ?? false
        return Button {
            keyboards.markActive(config.id)
            keyboards.setSound(id, for: config.id)
        } label: {
            HStack(spacing: 4) {
                Text("\(slot + 1)").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(on ? Theme.onAccent.opacity(0.7) : Theme.text3)
                Text(Keyboards.soundName(id)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if missing { Image(systemName: "arrow.down.circle").font(.system(size: 9)) }
            }
            .foregroundStyle(on ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(on ? config.tint : Theme.field, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Clic: este sonido · clic derecho: cambiar la casilla"))
        .contextMenu {
            Text(tr("Poner en la casilla %d", slot + 1))
            Menu(tr("Sintetizador")) {
                ForEach(AppModel.shared.sounds.all) { p in
                    Button(p.name) { keyboards.setFavorite(slot, to: InstrumentLibrary.synth(p.id)) }
                }
            }
            ForEach(Instrument.Group.allCases, id: \.self) { group in
                Menu(group.title) {
                    ForEach(Instrument.all.filter { $0.group == group }) { instrument in
                        Button(instrument.name) { keyboards.setFavorite(slot, to: instrument.id) }
                    }
                }
            }
        }
    }
}

/// Instrument picker as a menu: the synth plus every instrument, grouped; ones not downloaded
/// show their size and download when picked.
struct InstrumentMenu: View {
    @ObservedObject var instruments: InstrumentLibrary
    @ObservedObject private var sounds = AppModel.shared.sounds
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        Menu {
            Section(tr("Sintetizador")) {
                ForEach(sounds.all) { p in Button(p.name) { pick(InstrumentLibrary.synth(p.id)) } }
                Button(tr("Crear o editar sonidos…")) { UserDefaults.standard.set("synth", forKey: "mainMode") }
            }
            ForEach(Instrument.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(Instrument.all.filter { $0.group == group }) { instrument in
                        Button(title(instrument)) {
                            if let pack = InstrumentPack.with(instrument.pack), instruments.fileURL(pack) == nil {
                                instruments.download(pack)
                            }
                            pick(instrument.id)
                        }
                    }
                }
            }
        } label: {
            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(minWidth: 120, maxWidth: 170)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.lineStrong) }
        .help(tr("Sonido de este teclado"))
    }

    private var name: String {
        Keyboards.soundName(selected)
    }

    private func title(_ instrument: Instrument) -> String {
        guard let pack = InstrumentPack.with(instrument.pack), instruments.fileURL(pack) == nil else { return instrument.name }
        return "\(instrument.name) · ↓ \(pack.sizeMB) MB"
    }
}

// MARK: - Keyboard settings

struct KeyboardSheet: View {
    @ObservedObject var keyboards: Keyboards
    @ObservedObject var midi: MidiController
    @ObservedObject var instruments: InstrumentLibrary
    let id: String
    let done: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        if let config = keyboards.config(id) {
            content(config)
        } else {
            Color.clear.onAppear(perform: done)
        }
    }

    private func content(_ c: KeyboardConfig) -> some View {
        ScrollView { form(c) }
            .frame(width: 600)
            .frame(minHeight: 520, idealHeight: 820, maxHeight: 900)
            .background(Theme.window)
    }

    private func form(_ c: KeyboardConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(c.tint).frame(width: 14, height: 14)
                TextField("", text: Binding(get: { c.name }, set: { v in keyboards.update(id) { $0.name = String(v.prefix(30)) } }))
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .bold))
                Spacer()
                Button(tr("Hecho"), action: done).buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
            }

            group(tr("Qué escucha")) {
                HStack(spacing: 10) {
                    Picker(tr("Aparato"), selection: Binding(get: { c.device }, set: { v in keyboards.update(id) { $0.device = v } })) {
                        ForEach(Array(Set(midi.inputs.filter(Keyboards.isKeyboard) + [c.device])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker(tr("Canal"), selection: Binding(get: { c.channel ?? 0 }, set: { v in keyboards.update(id) { $0.channel = v == 0 ? nil : v } })) {
                        Text(tr("Todos")).tag(0)
                        ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .frame(width: 150)
                }
                Text(tr("Cada teclado se reconoce por su aparato: aunque dos manden por el canal 1, cada uno suena con lo suyo."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }

            group(tr("Sonido y qué toca")) {
                HStack(spacing: 10) {
                    InstrumentMenu(instruments: instruments, selected: c.instrument) { v in keyboards.update(id) { $0.instrument = v } }
                    SegmentedControl(options: KeyLayout.allCases.map { ($0.label, $0) },
                                     selection: Binding(get: { c.layout }, set: { v in keyboards.update(id) { $0.layout = v } }))
                }
            }

            group(tr("Zona")) {
                HStack(spacing: 14) {
                    noteStepper(tr("Desde"), c.low) { d in keyboards.update(id) { $0.low += d } }
                    noteStepper(tr("Hasta"), c.high) { d in keyboards.update(id) { $0.high += d } }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Octava")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        HStack(spacing: 2) {
                            IconButton(symbol: "minus", label: tr("Octava abajo"), size: 22) { keyboards.update(id) { $0.octave -= 1 } }
                            Text(String(format: "%+d", c.octave)).monospacedText(size: 13).frame(minWidth: 26)
                            IconButton(symbol: "plus", label: tr("Octava arriba"), size: 22) { keyboards.update(id) { $0.octave += 1 } }
                        }
                    }
                    Spacer()
                    Button { keyboards.startZoneLearn(id) } label: {
                        Text(keyboards.learningZone == id ? tr("Toca la primera y la última tecla…") : tr("Aprender")).fixedSize()
                    }
                    .buttonStyle(AppButtonStyle(kind: keyboards.learningZone == id ? .primary : .secondary))
                }
                HStack(spacing: 8) {
                    Button { keyboards.update(id) { $0.low = 0; $0.high = 127 } } label: { Text(tr("Todo el teclado")).fixedSize() }
                        .buttonStyle(AppButtonStyle(kind: .ghost, height: 26))
                    Button { keyboards.addZone(from: id) } label: { Text(tr("Dividir en dos zonas")).fixedSize() }
                        .buttonStyle(AppButtonStyle(kind: .ghost, height: 26))
                }
            }

            HStack(alignment: .top, spacing: 14) {
                group(tr("Fuerza")) {
                    SegmentedControl(options: KeyboardConfig.Curve.allCases.map { ($0.label, $0) },
                                     selection: Binding(get: { c.curve }, set: { v in keyboards.update(id) { $0.curve = v } }))
                }
                group(tr("Volumen")) {
                    Slider(value: Binding(get: { c.volume }, set: { v in keyboards.update(id) { $0.volume = v } }), in: 0...1)
                        .controlSize(.small)
                }
            }

            EffectsEditor(effects: Binding(get: { c.effects ?? .none },
                                           set: { v in keyboards.update(id) { $0.effects = v.isOff ? nil : v } }))
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))

            group(tr("Color")) {
                HStack(spacing: 8) {
                    ForEach(KeyboardConfig.palette.indices, id: \.self) { i in
                        Button { keyboards.update(id) { $0.color = i } } label: {
                            Circle().fill(KeyboardConfig.palette[i]).frame(width: 22, height: 22)
                                .overlay { Circle().strokeBorder(Theme.text, lineWidth: c.color == i ? 2 : 0) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Color %d", i + 1))
                    }
                    Spacer()
                    Button(confirmingDelete ? tr("¿Seguro?") : tr("Quitar teclado")) {
                        if confirmingDelete { keyboards.remove(id) } else {
                            confirmingDelete = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { confirmingDelete = false }
                        }
                    }
                    .buttonStyle(.appDanger)
                }
            }
        }
        .padding(24)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func noteStepper(_ title: String, _ note: Int, change: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack(spacing: 2) {
                IconButton(symbol: "minus", label: tr("Bajar"), size: 22) { change(-1) }
                Text(Note.at(note).rawValue + "\(note / 12 - 1)").monospacedText(size: 13).frame(minWidth: 36)
                IconButton(symbol: "plus", label: tr("Subir"), size: 22) { change(1) }
            }
        }
    }
}

// MARK: - What sounds

/// Piano roll by pitch of everything played: notes and chords in their keyboard's color,
/// loop chords dimmer, chord names on their bars.
struct SoundRoll: View {
    @ObservedObject var engine: ChordEngine
    @ObservedObject var keyboards: Keyboards

    var body: some View {
        // Only the canvas redraws (no `.id(date)`: that re-laid out the whole window every
        // frame and kept the main thread, where MIDI and loops run, busy), and it pauses
        // when nothing is on screen.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: idle)) { timeline in
            Canvas { context, size in draw(context, size, at: now()) }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
        .accessibilityLabel(tr("Lo que suena"))
    }

    /// Nothing sounding and nothing left scrolling across the window.
    private var idle: Bool {
        let start = now() - engine.windowSeconds
        return engine.sounding.isEmpty && engine.heldNotes.isEmpty
            && !engine.history.contains { $0.end >= start } && !engine.noteHistory.contains { $0.end >= start }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize, at time: Double) {
        let colors = LaneColors(keyboards: keyboards)
        let window = engine.windowSeconds
        let start = time - window
        let labelWidth: CGFloat = 34, pad: CGFloat = 8
        var pitches = engine.noteHistory.filter { $0.end >= start }.map(\.midi) + engine.heldNotes.values.map(\.midi)
        pitches += engine.history.filter { $0.end >= start }.flatMap(\.notes) + engine.sounding.flatMap(\.notes)
        let low = min(48, (pitches.min() ?? 48) - 2), high = max(84, (pitches.max() ?? 84) + 2)
        let rows = CGFloat(high - low + 1)
        let rowHeight = (size.height - pad * 2) / rows
        let top = { (midi: Int) in pad + CGFloat(high - midi) * rowHeight }
        let toX = { (t: Double) in labelWidth + CGFloat((t - start) / window) * (size.width - labelWidth) }

        for midi in low...high where midi % 12 == 0 {
            let y = (top(midi) + rowHeight).rounded() + 0.5
            var line = Path()
            line.move(to: CGPoint(x: labelWidth, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(Theme.line), lineWidth: 1)
            context.draw(Text("C\(midi / 12 - 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.text3),
                         at: CGPoint(x: 6, y: top(midi) + rowHeight / 2), anchor: .leading)
        }

        func bar(_ midi: Int, _ from: Double, _ to: Double, _ color: Color, outlined: Bool = false) {
            guard to >= start else { return }
            let x = toX(max(from, start)), w = max(2, toX(min(to, time)) - toX(max(from, start)))
            let h = max(2, min(10, rowHeight - 1))
            let rect = CGRect(x: x, y: top(midi) + (rowHeight - h) / 2, width: w, height: h)
            let shape = Path(roundedRect: rect, cornerRadius: min(3, h / 2))
            if outlined { context.stroke(shape, with: .color(color), lineWidth: 1) } else { context.fill(shape, with: .color(color)) }
        }
        func label(_ text: String, _ midi: Int, _ from: Double, _ color: Color) {
            guard !text.isEmpty else { return }
            context.draw(Text(text).font(.system(size: 10, weight: .semibold)).foregroundColor(color),
                         at: CGPoint(x: toX(max(from, start)) + 2, y: top(midi) + rowHeight + 7), anchor: .leading)
        }

        for e in engine.history where e.end >= start {
            let color = colors.color(e.owner, source: e.source)
            e.notes.forEach { bar($0, e.start, e.end, color.opacity(0.75), outlined: e.source == .loop) }
            if let lowest = e.notes.min() { label(e.symbol, lowest, e.start, color) }
        }
        for c in engine.sounding {
            let color = colors.color(c.owner, source: c.source)
            c.notes.forEach { bar($0, c.start, time, color, outlined: c.source == .loop) }
            if let lowest = c.notes.min() { label(engine.symbol(of: c), lowest, c.start, color) }
        }
        for n in engine.noteHistory where n.end >= start { bar(n.midi, n.start, n.end, colors.color(n.owner, source: .user)) }
        for n in engine.heldNotes.values { bar(n.midi, n.start, time, colors.color(n.owner, source: .user)) }

        var nowLine = Path()
        nowLine.move(to: CGPoint(x: size.width - 1, y: pad))
        nowLine.addLine(to: CGPoint(x: size.width - 1, y: size.height - pad))
        context.stroke(nowLine, with: .color(Theme.text2), lineWidth: 1.5)
    }
}

// MARK: - Mixer

struct MixerPanel: View {
    @ObservedObject var keyboards: Keyboards
    @ObservedObject var drums: DrumMachine
    @ObservedObject var loops: Loops

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(tr("Mezcla"))
            ForEach(keyboards.configs) { c in
                row(c.name, c.tint, Binding(get: { c.volume }, set: { v in keyboards.update(c.id) { $0.volume = v } }))
            }
            row(tr("Batería"), Theme.text, Binding(get: { drums.pattern.volume }, set: { drums.setVolume($0) }))
            row(tr("Loops"), Theme.text3, Binding(get: { loops.volume }, set: { loops.volume = $0 }))
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
    }

    private func row(_ name: String, _ color: Color, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 11)).lineLimit(1).frame(width: 96, alignment: .leading)
            Slider(value: value, in: 0...1).controlSize(.mini)
            Text("\(Int((value.wrappedValue * 100).rounded())) %").monospacedText(size: 10).frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Chords tab

/// Playing chords with the Mac keyboard and the mouse: mode, tempo, color wheel, degree pads.
struct ChordsTab: View {
    @ObservedObject var engine: ChordEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlayControls(engine: engine)
            ChordWheel(engine: engine).frame(width: 210, height: 210).frame(maxWidth: .infinity)
            DegreePads(engine: engine).frame(height: 110)
            Text(tr("Teclado del Mac: J U K I L O ; grados · W A S D color · espacio octava abajo. Su sonido se elige en «Sonido»."))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Chord types for a menu: the key's own chords first, then the fixed qualities.
struct ChordTypeMenuItems: View {
    let selected: ChordColor
    let pick: (ChordColor) -> Void

    var body: some View {
        Button { pick(.diatonic) } label: { item(.diatonic, tr("Del tono (I, ii, iii…)")) }
        Divider()
        ForEach([ChordColor.major, .minor, .diminished, .augmented], id: \.self) { c in Button { pick(c) } label: { item(c, c.name) } }
        Divider()
        ForEach([ChordColor.seventh, .minor7, .maj7, .sus2, .sus4, .add9], id: \.self) { c in Button { pick(c) } label: { item(c, c.name) } }
    }

    @ViewBuilder
    private func item(_ c: ChordColor, _ title: String) -> some View {
        if c == selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
