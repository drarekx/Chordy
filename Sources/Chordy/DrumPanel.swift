import AppKit
import SwiftUI

/// Step sequencer: patterns A–H, kit, swing, the 8 × 16 grid and what the Launchkey pads do.
struct DrumPanel: View {
    @ObservedObject var drums: DrumMachine
    @ObservedObject var instruments: InstrumentLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel(tr("Batería"))
                HStack(spacing: 3) {
                    ForEach(DrumPattern.names.indices, id: \.self) { i in
                        Button { drums.selected = i } label: {
                            Text(DrumPattern.names[i]).font(.system(size: 11, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(i == drums.selected ? Theme.onAccent
                                                 : (drums.patterns[i].isEmpty ? Theme.text3 : Theme.text))
                                .background(i == drums.selected ? Theme.accentFill : Theme.field,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(tr("Patrón %@", DrumPattern.names[i]))
                    }
                }
                Menu {
                    ForEach(drums.kits) { kit in Button(kit.name) { drums.setKit(kit.id) } }
                } label: {
                    Text(Instrument.with(drums.pattern.kit)?.name ?? tr("Kit")).font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                HStack(spacing: 4) {
                    Text(tr("Swing")).font(.system(size: 10)).foregroundStyle(Theme.text3).fixedSize()
                    Slider(value: Binding(get: { drums.pattern.swing }, set: { drums.setSwing($0) }), in: 0...0.5)
                        .controlSize(.mini).frame(width: 70)
                }
                Spacer(minLength: 4)
                Text(tr("Pads")).font(.system(size: 10)).foregroundStyle(Theme.text3).fixedSize()
                SegmentedControl(options: [(tr("Acordes"), DrumMachine.PadMode.chords), (tr("Pasos"), .steps), (tr("Tocar"), .play)],
                                 selection: $drums.padMode)
                    .fixedSize()
                IconButton(symbol: "trash", label: tr("Vaciar patrón"), size: 26) { drums.clear() }
                IconButton(symbol: "record.circle", label: tr("Grabar batería tocando los pads"),
                           kind: drums.recording ? .primary : .secondary, size: 26) { drums.toggleRecord() }
                IconButton(symbol: drums.playing ? "stop.fill" : "play.fill", label: tr("Reproducir batería"),
                           kind: drums.playing ? .primary : .secondary, size: 26) { drums.togglePlay() }
            }

            VStack(spacing: 3) {
                ForEach(DrumTrack.allCases, id: \.self) { track in
                    HStack(spacing: 6) {
                        Button { drums.track = track; drums.hit(track, velocity: 100) } label: {
                            Text(track.short).font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(track == drums.track ? Theme.accentText : Theme.text2)
                                .frame(width: 30, height: 16)
                                .background(drums.flash.contains(track) ? Theme.accentSoft : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(tr("%@ · clic para oírlo y elegirlo para los pads", track.label))
                        HStack(spacing: 3) {
                            ForEach(0..<DrumPattern.stepCount, id: \.self) { step in
                                cell(track, step)
                            }
                        }
                    }
                }
            }
            Text(tr("Clic: paso · ⌥ clic: acento. En «Pasos» los 16 pads son los pasos de la pista elegida (◀ ▶ cambian de pista); en «Tocar» los de arriba son los tambores y los de abajo los patrones A–H."))
                .font(.system(size: 10)).foregroundStyle(Theme.text3)
                .lineLimit(2)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
    }

    private func cell(_ track: DrumTrack, _ step: Int) -> some View {
        let velocity = drums.pattern.steps[track.rawValue][step]
        let current = drums.step == step && drums.playing
        let fill: Color = velocity > 0
            ? (current ? Theme.text : Theme.accentFill.opacity(0.45 + 0.55 * Double(velocity) / 127))
            : (current ? Theme.lineStrong : (step % 4 == 0 ? Theme.control : Theme.field))
        return Button {
            drums.toggleStep(track, step, accent: NSEvent.modifierFlags.contains(.option))
        } label: {
            RoundedRectangle(cornerRadius: 3).fill(fill)
                .overlay {
                    if track == drums.track && drums.padMode == .steps {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.warn.opacity(0.5), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("%@, paso %d", track.label, step + 1))
    }
}
