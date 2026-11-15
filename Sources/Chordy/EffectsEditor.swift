import SwiftUI

/// Reverb, delay and filter sliders (instruments and synth alike).
struct EffectsEditor: View {
    @Binding var effects: Effects

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(tr("Efectos"))
                Spacer()
                Button(tr("Quitar")) { effects = .none }.buttonStyle(AppButtonStyle(kind: .ghost, height: 22)).disabled(effects.isOff)
            }
            ParamSlider(label: tr("Reverb"), value: $effects.reverb, range: 0...1, format: Format.percent)
            ParamSlider(label: tr("Eco"), value: $effects.delay, range: 0...1, format: Format.percent)
            ParamSlider(label: tr("Tiempo eco"), value: $effects.delayTime, range: 0.05...1.5, log: true, format: Format.seconds)
            ParamSlider(label: tr("Repeticiones"), value: $effects.feedback, range: 0...0.9, format: Format.percent)
            ParamSlider(label: tr("Filtro"), value: $effects.filter, range: 0...1,
                        format: { $0 >= 0.999 ? tr("abierto") : Format.hz(200 * pow(100, $0)) })
        }
    }
}
