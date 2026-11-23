import AppKit
import SwiftUI

/// Build the song: a big transport, coloured sections to jump to or repeat, tracks with colour,
/// volume, mute and solo, clips that show their notes or drum hits, a library with search and
/// preview, and a bar for the selected clip.
struct SongView: View {
    @ObservedObject var song: Song
    @ObservedObject var loops: Loops
    @ObservedObject var drums: DrumMachine
    @ObservedObject var engine: ChordEngine
    @State private var selected: String?
    @State private var selectedSection: String?
    @State private var barWidth: CGFloat = 56
    @State private var drag: ClipDrag?
    @State private var sectionDrag: SectionDrag?
    @State private var monitor: Any?
    @State private var libraryTab = 0
    @State private var search = ""
    @State private var renamingSection: String?
    @State private var sectionName = ""

    private let headerWidth: CGFloat = 210
    private let laneHeight: CGFloat = 76
    private let sectionsHeight: CGFloat = 26
    private let rulerHeight: CGFloat = 24

    private struct ClipDrag {
        let id: String
        let resize: Bool
        let original: SongData.Clip
    }

    private struct SectionDrag {
        let id: String
        let resize: Bool
        let original: SongData.Section
    }

    var body: some View {
        VStack(spacing: 0) {
            transportBar
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                library.frame(width: 250)
                Rectangle().fill(Theme.line).frame(width: 1)
                VStack(spacing: 0) {
                    timeline
                    if let clip = selectedClip { clipBar(clip) }
                }
            }
        }
        .onAppear(perform: installMonitor)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    private var selectedClip: SongData.Clip? { selected.flatMap { id in song.data.clips.first { $0.id == id } } }

    private func tint(_ index: Int?) -> Color { KeyboardConfig.palette[(index ?? 0) % KeyboardConfig.palette.count] }

    // MARK: Transport bar

    private var transportBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                IconButton(symbol: "backward.end.fill", label: tr("Al principio"), size: 36) {
                    song.startBar = song.loopRange?.lowerBound ?? 0
                    if song.playing { song.play(fromBar: song.startBar) }
                }
                Button { song.togglePlay() } label: {
                    Image(systemName: song.playing ? "stop.fill" : "play.fill").font(.system(size: 16, weight: .bold))
                        .frame(width: 48, height: 36)
                        .foregroundStyle(Theme.onAccent)
                        .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(tr("Reproducir la canción (espacio)"))
                Button { toggleSectionLoop() } label: {
                    Label(tr("Repetir sección"), systemImage: "repeat").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 12).frame(height: 36)
                        .foregroundStyle(song.loopRange != nil ? Theme.window : Theme.warn)
                        .background(song.loopRange != nil ? Theme.warn : Theme.warn.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(selectedSection == nil && song.loopRange == nil)
                .help(tr("Elige una sección arriba y repítela mientras tocas"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(positionText).font(.system(size: 22, weight: .bold, design: .monospaced))
                Text(tr("compás · tiempo")).font(.system(size: 10)).foregroundStyle(Theme.text3)
                Text("\(clock(song.seconds(atBeat: currentBeat))) / \(clock(song.seconds(atBeat: Double(song.lengthBars) * 4)))")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text2).padding(.leading, 6)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
            HStack(spacing: 6) {
                chip("\(engine.bpm) bpm")
                chip("\(engine.tonic.rawValue) \(engine.flavor.label)")
                chip(tr("%d compases", song.lengthBars))
            }
            Spacer()
            Button { song.addSection(at: song.startBar); selectedSection = song.sections.last?.id } label: {
                Label(tr("Sección"), systemImage: "plus").fixedSize()
            }
            .buttonStyle(AppButtonStyle(kind: .secondary, height: 30))
            Button { song.addTrack() } label: { Label(tr("Pista"), systemImage: "plus").fixedSize() }
                .buttonStyle(AppButtonStyle(kind: .secondary, height: 30))
            IconButton(symbol: "minus.magnifyingglass", label: tr("Alejar"), size: 30) { barWidth = max(20, barWidth * 0.8) }
            IconButton(symbol: "plus.magnifyingglass", label: tr("Acercar"), size: 30) { barWidth = min(220, barWidth * 1.25) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.sidebar)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private var currentBeat: Double { song.playing ? song.position : Double(song.startBar) * 4 }

    private var positionText: String {
        "\(Int(currentBeat / 4) + 1) . \(Int(currentBeat.truncatingRemainder(dividingBy: 4)) + 1)"
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func toggleSectionLoop() {
        if song.loopRange != nil {
            song.loopRange = nil
        } else if let id = selectedSection, let s = song.sections.first(where: { $0.id == id }) {
            song.startBar = s.start
            song.loopRange = s.start..<(s.start + s.bars)
            if !song.playing { song.play(fromBar: s.start) }
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentedControl(options: [(tr("Loops"), 0), (tr("Batería"), 1)], selection: $libraryTab, expand: true)
            if libraryTab == 0 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    TextField(tr("Buscar"), text: $search).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line) }
                ScrollView {
                    VStack(spacing: 8) {
                        let list = loops.loops.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                        if list.isEmpty {
                            Text(loops.loops.isEmpty ? tr("Graba loops en el estudio y aparecerán aquí.") : tr("Nada con ese nombre."))
                                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        ForEach(list) { loop in loopItem(loop) }
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(DrumPattern.names.indices, id: \.self) { i in drumItem(i) }
                    }
                }
            }
            Text(tr("Arrastra a una pista · ▶ lo escuchas antes")).font(.system(size: 10)).foregroundStyle(Theme.text3)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private func loopItem(_ loop: Loop) -> some View {
        let playing = loops.playingId == loop.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(loop.tint ?? Theme.accentFill).frame(width: 9, height: 9)
                if loop.isLocked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.warn) }
                Text(loop.name.trimmingCharacters(in: .whitespaces).isEmpty ? tr("Loop") : loop.name)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 2)
                Text(LoopMath.formatLength(loop.lengthBeats)).font(.system(size: 10)).foregroundStyle(Theme.text3)
                Button { song.stop(); loops.togglePlay(loop.id) } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 10))
                        .frame(width: 22, height: 22)
                        .background(playing ? Theme.accentFill : Theme.control, in: Circle())
                        .foregroundStyle(playing ? Theme.onAccent : Theme.text)
                }
                .buttonStyle(.plain)
                .help(tr("Escuchar"))
            }
            LoopPreview(events: loop.events, length: loop.lengthBeats, progress: playing ? loops.progress : nil, tint: loop.tint)
                .frame(height: 24)
        }
        .padding(9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
        .contentShape(Rectangle())
        .draggable("loop:\(loop.id)")
    }

    private func drumItem(_ i: Int) -> some View {
        let p = drums.patterns[i]
        return HStack(spacing: 10) {
            Text(DrumPattern.names[i]).font(.system(size: 16, weight: .bold)).frame(width: 30, height: 30)
                .background(Theme.ok.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title ?? (p.isEmpty ? tr("vacío") : tr("Patrón %@", DrumPattern.names[i]))).font(.system(size: 12, weight: .semibold))
                Canvas { context, size in drawSteps(context, CGRect(origin: .zero, size: size), pattern: p, color: Theme.ok) }
                    .frame(height: 16)
            }
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
        .opacity(p.isEmpty ? 0.6 : 1)
        .contentShape(Rectangle())
        .draggable("drums:\(i)")
    }

    // MARK: Timeline

    private var timeline: some View {
        GeometryReader { geo in timelineBody(visible: geo.size.width - headerWidth) }
    }

    private func timelineBody(visible: CGFloat) -> some View {
        let bars = max(song.lengthBars + 8, Int((visible / barWidth).rounded(.up)))
        let width = CGFloat(bars) * barWidth
        return ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: sectionsHeight + rulerHeight)
                    ForEach(song.data.tracks) { trackHeader($0) }
                }
                .frame(width: headerWidth)
                .background(Theme.sidebar)
                VStack(spacing: 0) {
                    Canvas { context, size in drawSections(context, size) }
                        .frame(width: width, height: sectionsHeight)
                        .contentShape(Rectangle())
                        .gesture(sectionGesture)
                        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { renameSection(at: $0.location) })
                        .popover(isPresented: Binding(get: { renamingSection != nil }, set: { if !$0 { renamingSection = nil } })) {
                            sectionEditor
                        }
                    Canvas { context, size in drawLanes(context, size, bars: bars) }
                        .frame(width: width, height: rulerHeight + CGFloat(song.data.tracks.count) * laneHeight)
                        .contentShape(Rectangle())
                        .gesture(timelineGesture)
                        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { openClip(at: $0.location) })
                        .dropDestination(for: String.self) { items, location in drop(items, at: location) }
                }
            }
        }
        .background(Theme.card)
    }

    private func trackColor(_ track: SongData.Track) -> Color {
        tint(track.color ?? song.data.tracks.firstIndex { $0.id == track.id })
    }

    private func trackHeader(_ track: SongData.Track) -> some View {
        let color = trackColor(track)
        let sound = soundName(of: track)
        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(KeyboardConfig.palette.indices, id: \.self) { i in
                            Button(tr("Color %d", i + 1)) { song.updateTrack(track.id) { $0.color = i } }
                        }
                    } label: { Circle().fill(color).frame(width: 9, height: 9) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    TextField("", text: Binding(get: { track.name }, set: { v in song.updateTrack(track.id) { $0.name = String(v.prefix(24)) } }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                    small("M", on: track.muted, help: tr("Silenciar la pista")) { song.toggleMute(track.id) }
                    small("S", on: track.soloed, help: tr("Solo")) { song.toggleSolo(track.id) }
                    if !track.isDrums {
                        Button { song.removeTrack(track.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.text3).help(tr("Quitar la pista"))
                    }
                }
                Text(sound).font(.system(size: 10)).foregroundStyle(Theme.text3).lineLimit(1)
                Slider(value: Binding(get: { track.level }, set: { v in song.updateTrack(track.id) { $0.volume = v } }), in: 0...1.2)
                    .controlSize(.mini).tint(color)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: laneHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func small(_ label: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                .foregroundStyle(on ? Theme.window : Theme.text2)
                .background(on ? Theme.warn : Theme.field, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func soundName(of track: SongData.Track) -> String {
        if track.isDrums {
            let kit = song.data.clips.first { $0.track == track.id }.flatMap { c -> String? in
                if case .drums(let i) = c.source { return drums.patterns[safe: i]?.kit }
                return nil
            } ?? drums.pattern.kit
            return Instrument.with(kit)?.name ?? tr("Batería")
        }
        for c in song.data.clips where c.track == track.id {
            if case .loop(let id) = c.source, let loop = loops.loops.first(where: { $0.id == id }) {
                return Keyboards.soundName(loop.instrument ?? loop.events.first?.instrument ?? InstrumentLibrary.synthId)
            }
        }
        return tr("Sin clips")
    }

    private func laneTop(_ index: Int) -> CGFloat { rulerHeight + CGFloat(index) * laneHeight }

    private func clipRect(_ c: SongData.Clip) -> CGRect? {
        guard let lane = song.data.tracks.firstIndex(where: { $0.id == c.track }) else { return nil }
        return CGRect(x: CGFloat(c.start) * barWidth + 1, y: laneTop(lane) + 7,
                      width: CGFloat(c.bars) * barWidth - 3, height: laneHeight - 14)
    }

    private func drawSections(_ context: GraphicsContext, _ size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.sidebar))
        if song.sections.isEmpty {
            context.draw(Text(tr("Sin secciones: pulsa «+ Sección» para marcar intro, estrofa, estribillo…"))
                .font(.system(size: 11)).foregroundColor(Theme.text3), at: CGPoint(x: 8, y: size.height / 2), anchor: .leading)
        }
        for s in song.sections {
            let r = CGRect(x: CGFloat(s.start) * barWidth + 1, y: 3, width: CGFloat(s.bars) * barWidth - 2, height: size.height - 6)
            let on = s.id == selectedSection
            let looping = song.loopRange == s.start..<(s.start + s.bars)
            context.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(tint(s.color).opacity(on ? 0.55 : 0.32)))
            if on || looping {
                context.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(looping ? Theme.warn : Theme.text), lineWidth: 1.5)
            }
            context.draw(Text((looping ? "⟲ " : "") + s.name).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.text),
                         at: CGPoint(x: r.minX + 8, y: r.midY), anchor: .leading)
        }
    }

    private func drawLanes(_ context: GraphicsContext, _ size: CGSize, bars: Int) {
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerHeight)), with: .color(Theme.sidebar))
        for b in 0...bars {
            let x = CGFloat(b) * barWidth
            context.fill(Path(CGRect(x: x, y: b % 4 == 0 ? 2 : 12, width: 1, height: size.height)),
                         with: .color(b % 4 == 0 ? Theme.lineStrong : Theme.line))
            if b < bars, barWidth > 26 || b % 4 == 0 {
                context.draw(Text("\(b + 1)").font(.system(size: 10, weight: b % 4 == 0 ? .bold : .regular, design: .monospaced))
                    .foregroundColor(b % 4 == 0 ? Theme.text : Theme.text3), at: CGPoint(x: x + 4, y: 12), anchor: .leading)
            }
        }
        if let r = song.loopRange {
            context.fill(Path(CGRect(x: CGFloat(r.lowerBound) * barWidth, y: rulerHeight,
                                     width: CGFloat(r.count) * barWidth, height: size.height)), with: .color(Theme.warn.opacity(0.06)))
        }
        let anySolo = song.data.tracks.contains { $0.soloed }
        for (i, t) in song.data.tracks.enumerated() {
            let y = laneTop(i)
            if t.muted || (anySolo && !t.soloed) {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: laneHeight)), with: .color(Theme.window.opacity(0.45)))
            }
            context.fill(Path(CGRect(x: 0, y: y + laneHeight - 1, width: size.width, height: 1)), with: .color(Theme.line))
        }
        context.fill(Path(CGRect(x: CGFloat(song.lengthBars) * barWidth, y: rulerHeight, width: 2, height: size.height)),
                     with: .color(Theme.text3.opacity(0.5)))
        for c in song.data.clips { drawClip(context, c) }
        // Start marker and playhead.
        let sx = CGFloat(song.startBar) * barWidth
        var marker = Path()
        marker.move(to: CGPoint(x: sx, y: 0)); marker.addLine(to: CGPoint(x: sx + 9, y: 0)); marker.addLine(to: CGPoint(x: sx, y: 11))
        context.fill(marker, with: .color(Theme.warn))
        if song.playing {
            let x = CGFloat(song.position / 4) * barWidth
            context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.text))
        }
    }

    private func drawClip(_ context: GraphicsContext, _ c: SongData.Clip) {
        guard let r = clipRect(c), let track = song.data.tracks.first(where: { $0.id == c.track }) else { return }
        // A loop with its own colour shows it; otherwise the track's.
        let color: Color = {
            if case .loop(let id) = c.source, let tint = loops.loops.first(where: { $0.id == id })?.tint { return tint }
            return trackColor(track)
        }()
        let shape = Path(roundedRect: r, cornerRadius: 8)
        context.fill(shape, with: .color(color.opacity(0.2)))
        context.stroke(shape, with: .color(selected == c.id ? Theme.text : color), lineWidth: selected == c.id ? 2 : 1.2)
        context.draw(Text(clipName(c)).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.text),
                     at: CGPoint(x: r.minX + 7, y: r.minY + 10), anchor: .leading)
        let body = CGRect(x: r.minX + 6, y: r.minY + 20, width: r.width - 12, height: r.height - 26)
        guard body.width > 4, body.height > 4 else { return }
        switch c.source {
        case .drums(let i):
            guard let p = drums.patterns[safe: i] else { return }
            for bar in 0..<c.bars {
                let cell = CGRect(x: body.minX + CGFloat(bar) * barWidth, y: body.minY, width: barWidth - 2, height: body.height)
                guard cell.minX < body.maxX else { break }
                drawSteps(context, cell, pattern: p, color: color)
            }
        case .loop(let id):
            guard let loop = loops.loops.first(where: { $0.id == id }), loop.lengthBeats > 0 else { return }
            let repWidth = CGFloat(loop.lengthBeats / 4) * barWidth
            let pitches = loop.events.compactMap(\.midi) + loop.events.filter { $0.midi == nil }.map { _ in 60 }
            let low = (pitches.min() ?? 48) - 1, high = max((pitches.max() ?? 72) + 1, low + 6)
            var rep = 0
            while CGFloat(rep) * repWidth < body.width {
                let x0 = body.minX + CGFloat(rep) * repWidth
                if rep > 0 {
                    context.fill(Path(CGRect(x: x0, y: r.minY + 4, width: 1, height: r.height - 8)), with: .color(color.opacity(0.6)))
                }
                for e in loop.events {
                    let x = x0 + CGFloat(e.start / loop.lengthBeats) * repWidth
                    guard x < body.maxX else { continue }
                    let w = min(max(2, CGFloat(e.length / loop.lengthBeats) * repWidth - 1), body.maxX - x)
                    let pitch = e.midi ?? 60
                    let y = body.minY + CGFloat(high - pitch) / CGFloat(high - low) * (body.height - 3)
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: e.midi == nil ? 6 : 3), cornerRadius: 1.5),
                                 with: .color(color))
                }
                rep += 1
            }
        }
    }

    /// 16 steps of a pattern as ticks: kick tall, snare middle, the rest short.
    private func drawSteps(_ context: GraphicsContext, _ r: CGRect, pattern p: DrumPattern, color: Color) {
        let w = r.width / 16
        for s in 0..<16 {
            let hits = p.steps.indices.filter { p.steps[$0][s] > 0 }
            guard !hits.isEmpty else { continue }
            let h: CGFloat = hits.contains(DrumTrack.kick.rawValue) ? 1 : (hits.contains(DrumTrack.snare.rawValue) ? 0.7 : 0.4)
            context.fill(Path(roundedRect: CGRect(x: r.minX + CGFloat(s) * w, y: r.maxY - r.height * h,
                                                  width: max(1.5, w * 0.5), height: r.height * h), cornerRadius: 1),
                         with: .color(color))
        }
    }

    private func clipName(_ c: SongData.Clip) -> String {
        switch c.source {
        case .loop(let id): return loops.loops.first { $0.id == id }?.name ?? tr("Loop borrado")
        case .drums(let i):
            return DrumPattern.names[safe: i].map { $0 + (drums.patterns[safe: i]?.title.map { " · \($0)" } ?? "") } ?? "?"
        }
    }

    // MARK: Gestures

    private func hit(_ p: CGPoint) -> SongData.Clip? { song.data.clips.last { clipRect($0)?.contains(p) == true } }

    private func lane(at y: CGFloat) -> SongData.Track? { song.data.tracks[safe: Int((y - rulerHeight) / laneHeight)] }

    private var timelineGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil {
                    if v.startLocation.y < rulerHeight {
                        song.startBar = max(0, Int(v.startLocation.x / barWidth))
                        return
                    }
                    guard let c = hit(v.startLocation), let r = clipRect(c) else {
                        selected = nil
                        return
                    }
                    selected = c.id
                    drag = ClipDrag(id: c.id, resize: v.startLocation.x > r.maxX - 8, original: c)
                }
                guard let d = drag else { return }
                let deltaBars = Int((v.translation.width / barWidth).rounded())
                song.update(d.id) { c in
                    if d.resize {
                        c.bars = max(1, d.original.bars + deltaBars)
                    } else {
                        c.start = max(0, d.original.start + deltaBars)
                        if let target = lane(at: v.location.y),
                           target.isDrums == (song.data.tracks.first { $0.id == d.original.track }?.isDrums ?? false) {
                            c.track = target.id
                        }
                    }
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func sectionAt(_ x: CGFloat) -> SongData.Section? {
        song.sections.last { CGFloat($0.start) * barWidth <= x && x <= CGFloat($0.start + $0.bars) * barWidth }
    }

    private var sectionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if sectionDrag == nil {
                    guard let s = sectionAt(v.startLocation.x) else { selectedSection = nil; return }
                    selectedSection = s.id
                    song.startBar = s.start
                    let edge = CGFloat(s.start + s.bars) * barWidth
                    sectionDrag = SectionDrag(id: s.id, resize: v.startLocation.x > edge - 8, original: s)
                }
                guard let d = sectionDrag else { return }
                let delta = Int((v.translation.width / barWidth).rounded())
                song.updateSection(d.id) { s in
                    if d.resize { s.bars = d.original.bars + delta } else { s.start = d.original.start + delta }
                }
            }
            .onEnded { _ in
                sectionDrag = nil
                if let id = selectedSection, let s = song.sections.first(where: { $0.id == id }), song.loopRange != nil {
                    song.loopRange = s.start..<(s.start + s.bars)
                }
            }
    }

    private func renameSection(at p: CGPoint) {
        guard let s = sectionAt(p.x) else { return }
        sectionName = s.name
        renamingSection = s.id
    }

    private var sectionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(tr("Nombre"), text: $sectionName).frame(width: 200)
                .onSubmit { commitSectionName() }
            HStack(spacing: 6) {
                ForEach(KeyboardConfig.palette.indices, id: \.self) { i in
                    Button { if let id = renamingSection { song.updateSection(id) { $0.color = i } } } label: {
                        Circle().fill(KeyboardConfig.palette[i]).frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button(tr("Quitar"), role: .destructive) {
                    if let id = renamingSection { song.removeSection(id) }
                    renamingSection = nil
                }
                Spacer()
                Button(tr("Hecho")) { commitSectionName() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func commitSectionName() {
        if let id = renamingSection {
            let name = sectionName.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { song.updateSection(id) { $0.name = String(name.prefix(24)) } }
        }
        renamingSection = nil
    }

    private func drop(_ items: [String], at location: CGPoint) -> Bool {
        guard let item = items.first, let track = lane(at: location.y) else { return false }
        let bar = max(0, Int(location.x / barWidth))
        if item.hasPrefix("loop:") {
            guard !track.isDrums else { return false }
            song.add(.loop(String(item.dropFirst(5))), track: track.id, at: bar)
            selected = song.data.clips.last?.id
            return true
        }
        if item.hasPrefix("drums:"), let i = Int(item.dropFirst(6)) {
            guard let drumTrack = song.data.tracks.first(where: { $0.isDrums }) else { return false }
            song.add(.drums(i), track: drumTrack.id, at: bar)
            selected = song.data.clips.last?.id
            return true
        }
        return false
    }

    private func openClip(at p: CGPoint) {
        guard let c = hit(p) else { return }
        open(c)
    }

    private func open(_ c: SongData.Clip) {
        switch c.source {
        case .loop(let id):
            loops.studioId = id
            UserDefaults.standard.set("editor", forKey: "mainMode")
        case .drums(let i):
            drums.selected = i
            UserDefaults.standard.set("drums", forKey: "mainMode")
        }
    }

    // MARK: Selected clip

    private func clipBar(_ c: SongData.Clip) -> some View {
        let repeats: Int = {
            guard case .loop(let id) = c.source, let loop = loops.loops.first(where: { $0.id == id }), loop.lengthBeats > 0 else { return c.bars }
            return Int((Double(c.bars) * 4 / loop.lengthBeats).rounded(.up))
        }()
        return HStack(spacing: 16) {
            Text(tr("Clip")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            Text(clipName(c)).font(.system(size: 13, weight: .bold)).lineLimit(1)
            stepper(tr("Empieza en el compás"), "\(c.start + 1)") { d in song.update(c.id) { $0.start += d } }
            stepper(tr("Dura"), tr("%d compases (%d rep.)", c.bars, repeats)) { d in song.update(c.id) { $0.bars += d } }
            HStack(spacing: 6) {
                Text(tr("Volumen")).font(.system(size: 11)).foregroundStyle(Theme.text2)
                Slider(value: Binding(get: { c.volume ?? 1 }, set: { v in song.update(c.id) { $0.volume = v } }), in: 0...1.2)
                    .controlSize(.mini).frame(width: 90)
            }
            if case .loop = c.source {
                stepper(tr("Transponer"), "\(c.transpose ?? 0)") { d in song.update(c.id) { $0.transpose = ($0.transpose ?? 0) + d } }
            }
            Spacer(minLength: 6)
            Button { if let id = song.duplicate(c.id) { selected = id } } label: { Text(tr("Duplicar ⌘D")).fixedSize() }
                .buttonStyle(AppButtonStyle(kind: .secondary, height: 28))
            Button { open(c) } label: {
                Text({ if case .loop = c.source { return tr("Editar loop") } else { return tr("Editar patrón") } }()).fixedSize()
            }
            .buttonStyle(AppButtonStyle(kind: .secondary, height: 28))
            Button { song.remove(c.id); selected = nil } label: { Text(tr("Quitar")).fixedSize() }
                .buttonStyle(AppButtonStyle(kind: .danger, height: 28))
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func stepper(_ title: String, _ value: String, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2)
            IconButton(symbol: "minus", label: title, size: 22) { change(-1) }
            Text(value).monospacedText(size: 12).fixedSize()
            IconButton(symbol: "plus", label: title, size: 22) { change(1) }
        }
        .fixedSize()
    }

    // MARK: Keys

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard UserDefaults.standard.string(forKey: "mainMode") == "song",
                      !(e.window?.firstResponder is NSText) else { return false }
                if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "d", let s = selected {
                    if let id = song.duplicate(s) { selected = id }
                    return true
                }
                switch e.keyCode {
                case 49: song.togglePlay(); return true
                case 51, 117:
                    if let s = selected { song.remove(s); selected = nil; return true }
                    return false
                default: return false
                }
            }
            return handled ? nil : event
        }
    }
}
