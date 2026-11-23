import SwiftUI

/// «Atril»: the song open in the Mac's «Repertorio», big enough to read while playing. The
/// chord being played lights up and the page scrolls with it; the Mac decides what's played.
struct SheetStandView: View {
    @ObservedObject var client: RemoteClient
    @ObservedObject var follow: SheetFollow
    let state: RemoteState
    @AppStorage("sheetFontSize") private var fontSize = 26.0
    @AppStorage("sheetListHidden") private var listHidden = false
    @StateObject private var cache = ParsedCache()

    var body: some View {
        HStack(spacing: 16) {
            if !listHidden { list.frame(width: 260) }
            if let sheet = state.sheet {
                page(sheet, cache.parsed(sheet.source))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list").font(.system(size: 44)).foregroundStyle(Pal.text3)
                    Text("No hay ninguna canción abierta").font(.title3.weight(.semibold))
                    Text("Importa canciones con acordes en el Mac, en «Repertorio», y elige una aquí.")
                        .foregroundStyle(Pal.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CANCIONES").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Pal.text3)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(state.sheets ?? []) { s in
                        let on = s.id == state.sheet?.id
                        Button { client.send(.sheetOpen(id: s.id)) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                    if let a = s.artist {
                                        Text(a).font(.system(size: 12)).foregroundStyle(on ? Pal.onAccent.opacity(0.75) : Pal.text3).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if let k = s.key {
                                    Text(k).font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(on ? Pal.onAccent.opacity(0.15) : Pal.control, in: Capsule())
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .foregroundStyle(on ? Pal.onAccent : Pal.text)
                            .background(on ? Pal.accent : Pal.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func page(_ sheet: RemoteSheet, _ parsed: ParsedSheet) -> some View {
        let position = follow.id == sheet.id ? follow.index : -1
        return VStack(spacing: 0) {
            header(sheet, parsed, position: position)
            Rectangle().fill(Pal.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    ChordSheetBody(parsed: parsed, transpose: sheet.transpose,
                                   position: sheet.following ? position : nil,
                                   style: style, latin: sheet.latin ? true : nil) { client.send(.sheetSeek(index: $0)) }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                }
                .onChange(of: position) { _, p in
                    guard parsed.chordLines.indices.contains(p) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(parsed.chordLines[p], anchor: UnitPoint(x: 0, y: 0.3)) }
                }
                .onChange(of: sheet.id) { _, _ in
                    if let first = parsed.sections.first?.lines.first?.id { proxy.scrollTo(first, anchor: .top) }
                }
            }
        }
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var style: SheetStyle {
        SheetStyle(text: Pal.text, text2: Pal.text2, text3: Pal.text3, chord: Pal.accent, current: Pal.accent,
                   onCurrent: Pal.onAccent, chorus: Pal.field, line: Pal.control, fontSize: fontSize)
    }

    private func header(_ sheet: RemoteSheet, _ parsed: ParsedSheet, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { listHidden.toggle() } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheet.title).font(.system(size: 22, weight: .bold)).lineLimit(1)
                    HStack(spacing: 10) {
                        if let a = sheet.artist { Text(a).foregroundStyle(Pal.text2).lineLimit(1) }
                        if let k = parsed.displayKey(transpose: sheet.transpose) {
                            Text("Tono \(sheet.latin ? (ChordName(k)?.symbol(latin: true) ?? k) : k)")
                                .fontWeight(.semibold).foregroundStyle(Pal.text2).fixedSize()
                        }
                        if let capo = parsed.capo, capo > 0 { Text("Cejilla \(capo)").foregroundStyle(Pal.text3).fixedSize() }
                    }
                    .font(.system(size: 14))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                stepper(sheet.transpose == 0 ? "Original" : String(format: "%+d", sheet.transpose),
                        minus: { client.send(.sheetTranspose(id: sheet.id, semitones: sheet.transpose - 1)) },
                        plus: { client.send(.sheetTranspose(id: sheet.id, semitones: sheet.transpose + 1)) })
                stepper("Aa", minus: { fontSize = max(16, fontSize - 2) }, plus: { fontSize = min(48, fontSize + 2) })
                Button { client.send(.sheetFollow(!sheet.following)) } label: {
                    Label("Seguir", systemImage: sheet.following ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize()
                        .padding(.horizontal, 12).frame(height: 44)
                        .foregroundStyle(sheet.following ? Pal.onAccent : Pal.text)
                        .background(sheet.following ? Pal.accent : Pal.control, in: RoundedRectangle(cornerRadius: 11))
                }
                Spacer(minLength: 0)
                bigButton("backward.end.fill") { client.send(.sheetSeek(index: -1)) }
                bigButton("chevron.left") { client.send(.sheetSeek(index: max(-1, position - 1))) }
                bigButton("chevron.right") { client.send(.sheetSeek(index: min(parsed.chords.count - 1, position + 1))) }
            }
        }
        .foregroundStyle(Pal.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func stepper(_ title: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: minus) { Image(systemName: "minus").frame(width: 40, height: 44) }
            Text(title).font(.system(size: 14, weight: .semibold, design: .monospaced)).frame(minWidth: 64)
            Button(action: plus) { Image(systemName: "plus").frame(width: 40, height: 44) }
        }
        .background(Pal.control, in: RoundedRectangle(cornerRadius: 11))
    }

    private func bigButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold))
                .frame(width: 52, height: 44)
                .background(Pal.control, in: RoundedRectangle(cornerRadius: 11))
        }
    }
}

/// The open song parsed once per text (the view redraws often: latency, beats…).
@MainActor
final class ParsedCache: ObservableObject {
    private var source = ""
    private var value: ParsedSheet?

    func parsed(_ source: String) -> ParsedSheet {
        if let value, source == self.source { return value }
        let p = ParsedSheet(source)
        self.source = source
        value = p
        return p
    }
}
