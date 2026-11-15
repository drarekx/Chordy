import SwiftUI

/// Top of the Sound tab: pick the synth or a sampled instrument, and manage the banks.
struct InstrumentPicker: View {
    @ObservedObject var instruments: InstrumentLibrary
    @State private var showBanks = false

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(tr("Instrumento"))
                Spacer()
                if instruments.loading {
                    ProgressView().controlSize(.small)
                    Text(tr("Cargando…")).font(.system(size: 10)).foregroundStyle(Theme.text3)
                }
                Button { showBanks.toggle() } label: {
                    Text(showBanks ? tr("Ocultar bancos") : tr("Bancos")).lineLimit(1).fixedSize()
                }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 24))
            }

            if showBanks { banks }

            chip(name: tr("Sintetizador"), detail: tr("editor abajo"), selected: instruments.usesSynth, state: .ready) {
                instruments.selectSynth()
            }
            ForEach(Instrument.Group.allCases, id: \.self) { group in
                Text(group.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(Instrument.all.filter { $0.group == group }) { instrument in
                        let pack = InstrumentPack.with(instrument.pack)!
                        chip(name: instrument.name, detail: nil, selected: instruments.selectedId == instrument.id,
                             state: instruments.state(pack), size: pack.sizeMB) {
                            instruments.select(instrument)
                        }
                        .help(pack.name)
                    }
                }
            }
        }
    }

    private func chip(name: String, detail: String?, selected: Bool, state: InstrumentLibrary.PackState,
                      size: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(Theme.text3)
                    }
                }
                Spacer(minLength: 2)
                switch state {
                case .ready:
                    EmptyView()
                case .missing:
                    Label("\(size) MB", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.text3).lineLimit(1).fixedSize()
                case .downloading(let progress):
                    Text("\(Int(progress * 100)) %").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accentText)
                case .installing:
                    ProgressView().controlSize(.mini)
                case .failed:
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.warn)
                }
            }
            .foregroundStyle(selected ? Theme.onAccent : (state == .ready ? Theme.text : Theme.text2))
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(selected ? Theme.accentFill : Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(selected ? Color.clear : Theme.line)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Download, cancel or remove each bank; credits for the licenses.
    private var banks: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(InstrumentPack.all) { pack in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pack.name).font(.system(size: 12, weight: .semibold))
                        Text("\(pack.credit) · \(pack.license)").font(.system(size: 10)).foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .downloading(let progress) = instruments.state(pack) {
                            ProgressView(value: progress).controlSize(.small)
                        }
                        if case .failed(let message) = instruments.state(pack) {
                            Text(message).font(.system(size: 10)).foregroundStyle(Theme.warn)
                        }
                    }
                    Spacer(minLength: 4)
                    bankButton(pack)
                }
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line) }
    }

    @ViewBuilder
    private func bankButton(_ pack: InstrumentPack) -> some View {
        if pack.systemPath != nil {
            Text(tr("Incluido")).font(.system(size: 10)).foregroundStyle(Theme.text3)
        } else {
            switch instruments.state(pack) {
            case .missing, .failed:
                Button { instruments.download(pack) } label: { Text(tr("Descargar %d MB", pack.sizeMB)).fixedSize() }
                    .buttonStyle(AppButtonStyle(kind: .secondary, height: 24))
            case .downloading:
                Button { instruments.cancel(pack) } label: { Text(tr("Cancelar")).fixedSize() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 24))
            case .installing:
                ProgressView().controlSize(.small)
            case .ready:
                Button { instruments.remove(pack) } label: { Text(tr("Quitar")).fixedSize() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 24))
            }
        }
    }
}
