import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// «Repertorio»: the songs with chords (list on the left, the open song on the right). The
/// chord being played lights up as you play along; the iPad shows the same song.
struct SongbookView: View {
    @ObservedObject var songbook: Songbook
    let loops: Loops
    @State private var search = ""
    @State private var pasting = false
    @State private var editing: String?
    @State private var deleting: String?
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 290)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if let sheet = songbook.open, let parsed = songbook.openParsed {
                    SheetReader(songbook: songbook, sheet: sheet, parsed: parsed, loops: loops) { editing = sheet.id }
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $pasting) {
            ThemedRoot { PasteSheet(songbook: songbook) { pasting = false } }
        }
        .sheet(item: Binding(get: { editing.map(SheetId.init) }, set: { editing = $0?.id })) { item in
            ThemedRoot { EditSheet(songbook: songbook, id: item.id) { editing = nil } }
        }
        .alert(tr("¿Borrar «%@»?", songbook.sheets.first { $0.id == deleting }?.title ?? ""),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("Borrar"), role: .destructive) { if let id = deleting { songbook.remove(id) }; deleting = nil }
            Button(tr("Cancelar"), role: .cancel) { deleting = nil }
        }
    }

    private struct SheetId: Identifiable { let id: String }

    private var filtered: [ChordSheet] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return songbook.sheets }
        return songbook.sheets.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.artist?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(tr("Canciones"))
                Spacer()
                IconButton(symbol: "doc.on.clipboard", label: tr("Pegar el texto de una canción")) { pasting = true }
                IconButton(symbol: "square.and.arrow.down", label: tr("Importar archivos (.txt, .cho)…")) { importFiles() }
            }
            AppTextField(placeholder: tr("Buscar"), text: $search, icon: "magnifyingglass")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { sheet in row(sheet) }
                }
            }
            Text(tr("Arrastra aquí archivos .txt o .cho, o pega el texto copiado de una web."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            songbook.importFiles(urls) > 0
        } isTargeted: { dropping = $0 }
    }

    private func row(_ sheet: ChordSheet) -> some View {
        let selected = sheet.id == songbook.openId
        return Button { songbook.open(sheet.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheet.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(Theme.text)
                    if let artist = sheet.artist {
                        Text(artist).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.text3)
                    }
                }
                Spacer(minLength: 4)
                if let key = songbook.shownKey(sheet).map({ songbook.latin ? (ChordName($0)?.symbol(latin: true) ?? $0) : $0 }) {
                    Text(key).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.control, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tr("Editar…")) { editing = sheet.id }
            Button(tr("Borrar…"), role: .destructive) { deleting = sheet.id }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list").font(.system(size: 40)).foregroundStyle(Theme.text3)
            Text(tr("Aún no hay canciones")).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text(tr("Copia una canción con acordes de cualquier web y pégala, o importa archivos .txt o ChordPro (.cho)."))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text2)
                .frame(maxWidth: 380)
            HStack {
                Button(tr("Pegar texto…")) { pasting = true }.buttonStyle(.appPrimary)
                Button(tr("Importar archivos…")) { importFiles() }.buttonStyle(.appSecondary)
            }
        }
        .padding(40)
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Songbook.fileTypes.compactMap { UTType(filenameExtension: $0) } + [.plainText]
        guard panel.runModal() == .OK else { return }
        songbook.importFiles(panel.urls)
    }
}

// MARK: - Reader

/// The open song: header with key, transpose and following, and the lyrics with chords.
private struct SheetReader: View {
    @ObservedObject var songbook: Songbook
    let sheet: ChordSheet
    let parsed: ParsedSheet
    let loops: Loops
    let edit: () -> Void
    @AppStorage("sheetFontSize") private var fontSize = 18.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    ChordSheetBody(parsed: parsed, transpose: sheet.transpose,
                                   position: songbook.following ? songbook.position : nil,
                                   style: style, latin: songbook.latin ? true : nil) { songbook.seek($0) }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: songbook.position) { _, p in
                    guard parsed.chordLines.indices.contains(p) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(parsed.chordLines[p], anchor: UnitPoint(x: 0, y: 0.35)) }
                }
            }
        }
    }

    private var style: SheetStyle {
        SheetStyle(text: Theme.text, text2: Theme.text2, text3: Theme.text3, chord: Theme.accentText,
                   current: Theme.accentFill, onCurrent: Theme.onAccent, chorus: Theme.card, line: Theme.field,
                   fontSize: fontSize)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(sheet.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                if let artist = sheet.artist {
                    Text(artist).font(.system(size: 14)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                Spacer()
                Button(tr("Editar…"), action: edit).buttonStyle(.appGhost)
            }
            HStack(spacing: 14) {
                keyBox
                transposeBox
                if let capo = parsed.capo, capo > 0 { chip(tr("Cejilla %d", capo)) }
                if let tempo = parsed.tempo { chip("\(tempo) BPM") }
                HStack(spacing: 2) {
                    IconButton(symbol: "textformat.size.smaller", label: tr("Letra más pequeña")) { fontSize = max(12, fontSize - 2) }
                    IconButton(symbol: "textformat.size.larger", label: tr("Letra más grande")) { fontSize = min(40, fontSize + 2) }
                }
                Button(songbook.latin ? "Do Re Mi" : "C D E") { songbook.latin.toggle() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 28, padding: 10))
                    .help(tr("Nombres de las notas"))
                Spacer()
                followBox
                Button(tr("Usar el tono")) { songbook.useKey() }
                    .buttonStyle(.appSecondary)
                    .disabled(parsed.keyChord == nil)
                    .help(tr("Pone Chordy en el tono de la canción: los pads de grados tocan sus acordes"))
                Button(tr("Crear loop")) {
                    if let id = songbook.makeLoop(into: loops) {
                        loops.studioId = id
                        UserDefaults.standard.set("editor", forKey: "mainMode")
                    }
                }
                .buttonStyle(.appSecondary)
                .disabled(parsed.chords.isEmpty)
                .help(tr("Un loop con los acordes de la canción, un compás cada uno, para acompañarte o pasarlo a la canción"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
            .padding(.horizontal, 8).frame(height: 26)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
    }

    private var keyBox: some View {
        HStack(spacing: 6) {
            Text(tr("Tono")).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Text(parsed.displayKey(transpose: sheet.transpose).map { songbook.latin ? (ChordName($0)?.symbol(latin: true) ?? $0) : $0 } ?? "—")
                .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            if parsed.keyGuessed { Text(tr("(calculado)")).font(.system(size: 10)).foregroundStyle(Theme.text3) }
        }
    }

    private var transposeBox: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "minus", label: tr("Bajar medio tono"), size: 26) { songbook.setTranspose(sheet.id, sheet.transpose - 1) }
            Text(sheet.transpose == 0 ? tr("Original") : String(format: "%+d", sheet.transpose))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(sheet.transpose == 0 ? Theme.text2 : Theme.accentText)
                .frame(minWidth: 58)
                .onTapGesture { songbook.setTranspose(sheet.id, 0) }
                .help(tr("Transponer (clic: volver al original)"))
            IconButton(symbol: "plus", label: tr("Subir medio tono"), size: 26) { songbook.setTranspose(sheet.id, sheet.transpose + 1) }
        }
        .padding(.horizontal, 2)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var followBox: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "backward.end.fill", label: tr("Al principio"), size: 26) { songbook.seek(-1) }
            IconButton(symbol: "chevron.left", label: tr("Acorde anterior"), size: 26) { songbook.step(-1) }
            IconButton(symbol: "chevron.right", label: tr("Acorde siguiente"), size: 26) { songbook.step(1) }
            Toggle(tr("Seguir lo que toco"), isOn: $songbook.following)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accentFill)
                .foregroundStyle(Theme.text2)
                .help(tr("El acorde resaltado avanza cuando tocas el siguiente (teclado MIDI, pads o teclado del Mac)"))
        }
    }
}

// MARK: - Paste and edit

private struct PasteSheet: View {
    @ObservedObject var songbook: Songbook
    let close: () -> Void
    @State private var title = ""
    @State private var text = NSPasteboard.general.string(forType: .string) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Pegar una canción")).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text(tr("Copia la canción de la web (acordes encima de la letra) y pégala aquí. También vale ChordPro."))
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
            AppTextField(placeholder: tr("Título (si lo dejas vacío, la primera línea)"), text: $title)
            SourceEditor(text: $text)
            HStack {
                Spacer()
                Button(tr("Cancelar"), action: close).buttonStyle(.appGhost).keyboardShortcut(.cancelAction)
                Button(tr("Importar")) {
                    songbook.importText(text, title: title)
                    close()
                }
                .buttonStyle(.appPrimary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .background(Theme.window)
    }
}

private struct EditSheet: View {
    @ObservedObject var songbook: Songbook
    let id: String
    let close: () -> Void
    @State private var title = ""
    @State private var artist = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Editar canción")).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            HStack {
                AppTextField(placeholder: tr("Título"), text: $title)
                AppTextField(placeholder: tr("Artista"), text: $artist)
            }
            Text(tr("ChordPro: los acordes entre corchetes dentro de la letra, [Am]así. {key: G} fija el tono, {start_of_chorus} … {end_of_chorus} marca el estribillo."))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            SourceEditor(text: $text)
            HStack {
                Spacer()
                Button(tr("Cancelar"), action: close).buttonStyle(.appGhost).keyboardShortcut(.cancelAction)
                Button(tr("Guardar")) {
                    songbook.update(id, title: title, artist: artist, source: text)
                    close()
                }
                .buttonStyle(.appPrimary)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
        .background(Theme.window)
        .onAppear {
            guard let s = songbook.sheets.first(where: { $0.id == id }) else { return }
            title = s.title
            artist = s.artist ?? ""
            text = s.source
        }
    }
}

private struct SourceEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.lineStrong) }
            .foregroundStyle(Theme.text)
    }
}
