import SwiftUI

/// Main window: the instrument on the left, loops / sound / MIDI on the right.
struct MainView: View {
    @ObservedObject var model = AppModel.shared
    @AppStorage("sideTab") private var sideTab = SideTab.loops

    enum SideTab: String, CaseIterable {
        case loops, sound, midi

        var title: String {
            switch self {
            case .loops: return tr("Loops")
            case .sound: return tr("Sonido")
            case .midi: return "MIDI"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            PlayArea(engine: model.engine)
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.line).frame(width: 1)

            VStack(alignment: .leading, spacing: 16) {
                SegmentedControl(options: SideTab.allCases.map { ($0.title, $0) }, selection: $sideTab, expand: true)
                switch sideTab {
                case .loops: LoopPanel(loops: model.loops)
                case .sound: SoundPanel(sounds: model.sounds)
                case .midi: MidiPanel(midi: model.midi)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 36)
            .padding(.bottom, 20)
            .frame(width: 360)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebar)
        }
        .ignoresSafeArea()
    }
}

/// The instrument: header, chord history, mode and tempo, color wheel and degree pads.
struct PlayArea: View {
    @ObservedObject var engine: ChordEngine

    var body: some View {
        VStack(spacing: 16) {
            PlayHeader(engine: engine)
            ChordDisplay(engine: engine)
                .frame(minHeight: 120, maxHeight: .infinity)
            PlayControls(engine: engine)
            HStack(alignment: .bottom, spacing: 24) {
                ChordWheel(engine: engine)
                    .frame(width: 210, height: 210)
                DegreePads(engine: engine)
            }
        }
    }
}
