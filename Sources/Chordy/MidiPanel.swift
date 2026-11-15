import SwiftUI

/// MIDI side panel: devices, monitor, auto-map, Launchkey lights, MIDI out and the mapping list.
struct MidiPanel: View {
    @ObservedObject var midi: MidiController
    @State private var expanded = Set<MidiAction>()

    private static let chipLimit = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                devices
                monitor
                autoMap
                if midi.learning != nil || midi.awaitingKey { learnBanner }
                options
                ForEach(MidiAction.Group.allCases, id: \.self) { group in
                    mappingGroup(group)
                }
                Button(tr("Borrar mapeo")) { midi.clearAll() }
                    .buttonStyle(.appDanger)
                    .disabled(midi.bindings.isEmpty)
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Sections

    private var devices: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(tr("Dispositivos"))
            if midi.inputs.isEmpty {
                Text(tr("Conecta un teclado o controlador MIDI.")).font(.system(size: 12)).foregroundStyle(Theme.text3)
            } else {
                ForEach(midi.inputs, id: \.self) { name in
                    Label(name, systemImage: "pianokeys").font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    private var monitor: some View {
        HStack(spacing: 8) {
            SectionLabel(tr("Último"))
            if let event = midi.lastEvent {
                Text(event.label).monospacedText(size: 11).lineLimit(1).fixedSize()
                Text("\(event.value)").monospacedText(size: 11).foregroundStyle(Theme.text3)
                Spacer(minLength: 4)
                Text(event.action ?? tr("sin asignar"))
                    .font(.system(size: 11, weight: event.action == nil ? .regular : .semibold))
                    .foregroundStyle(event.action == nil ? Theme.text3 : Theme.accentText)
                    .lineLimit(1)
            } else {
                Text(tr("Toca un control de tu aparato")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
        .help(midi.lastEvent?.device ?? "")
    }

    private var autoMap: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(tr("Automapeo"))
            HStack(spacing: 6) {
                Button(tr("Teclas")) { midi.autoMapKeys() }
                    .buttonStyle(AppButtonStyle(kind: midi.awaitingKey ? .primary : .secondary, fullWidth: true))
                Button { midi.autoMapLaunchkey() } label: { Text("Launchkey").lineLimit(1).fixedSize() }
                    .buttonStyle(AppButtonStyle(kind: midi.hasLaunchkey ? .primary : .secondary, fullWidth: true))
                Button(tr("Guiado")) { midi.startGuided() }
                    .buttonStyle(AppButtonStyle(kind: midi.guided ? .primary : .secondary, fullWidth: true))
            }
            Text(tr("Teclas: las blancas tocan los grados I–vii en todas las octavas y las negras mantienen el color (C# min · D# may · F# dim · G# aum · A# octava abajo). Launchkey 25 MK2: pads de abajo grados + octava, de arriba colores · tono · modo · stop; knobs al sonido; transporte. Guiado: recorre cada acción; toca un control o salta."))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var learnBanner: some View {
        HStack(spacing: 8) {
            if midi.awaitingKey {
                Text(tr("Pulsa cualquier tecla de tu teclado…"))
            } else if let action = midi.learning {
                let step = (MidiAction.allCases.firstIndex(of: action) ?? 0) + 1
                Text(midi.guided ? tr("%d/%d · Mueve o pulsa el control para «%@»…", step, MidiAction.allCases.count, action.label)
                                 : tr("Mueve o pulsa el control para «%@»…", action.label))
            }
            Spacer(minLength: 4)
            if midi.guided {
                Button(tr("Saltar")) { midi.skip() }.buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
            }
            Button(midi.guided ? tr("Hecho") : tr("Cancelar")) { midi.cancelLearn() }
                .buttonStyle(AppButtonStyle(kind: .secondary, height: 26))
        }
        .font(.system(size: 12))
        .padding(10)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accentBorder) }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(title: tr("Luces del Launchkey"),
                      detail: tr("Ilumina los pads con lo que suena. Pone el Launchkey en modo InControl."),
                      isOn: $midi.lightsEnabled)
                .disabled(!midi.hasLaunchkey)
            SwitchRow(title: tr("Salida MIDI «Chordy»"),
                      detail: tr("Los acordes que tocas salen por un dispositivo MIDI virtual para grabarlos en Logic, GarageBand o Ableton."),
                      isOn: $midi.sendToVirtual)
        }
    }

    private func mappingGroup(_ group: MidiAction.Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(group.title)
            VStack(spacing: 0) {
                ForEach(MidiAction.allCases.filter { $0.group == group }, id: \.self) { action in
                    row(action)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
    }

    private func row(_ action: MidiAction) -> some View {
        let controls = midi.controls(for: action)
        let visible = expanded.contains(action) ? controls : Array(controls.prefix(Self.chipLimit))
        let learning = midi.learning == action
        return HStack(alignment: .center, spacing: 6) {
            Text(action.label).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            FlowChips(controls: visible, hidden: controls.count - visible.count,
                      onRemove: { midi.unbind($0) }, onExpand: { expanded.insert(action) })
            Button(learning ? tr("cancelar") : tr("learn")) { midi.startLearn(action) }
                .buttonStyle(AppButtonStyle(kind: learning ? .primary : .ghost, height: 24))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(learning ? Theme.accentSoft : .clear)
    }
}

/// Bound controls as small removable chips.
private struct FlowChips: View {
    let controls: [MidiControl]
    let hidden: Int
    let onRemove: (MidiControl) -> Void
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            ForEach(controls, id: \.self) { control in
                HStack(spacing: 2) {
                    Text(control.label).monospacedText(size: 10)
                    Button { onRemove(control) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                    .help(tr("Quitar"))
                }
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 4))
            }
            if hidden > 0 {
                Button("+\(hidden)", action: onExpand)
                    .buttonStyle(.plain)
                    .monospacedText(size: 10)
                    .foregroundStyle(Theme.accentText)
            }
        }
        .fixedSize()
    }
}
