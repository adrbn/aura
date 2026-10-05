import SwiftUI

/// The five-band equaliser, driven by the same `EqualizerManager` the phone uses — the
/// filtering itself is a vDSP biquad on the audio tap, identical on both platforms.
struct MacEqualizerView: View {
    @State private var settings = AppSettings.shared
    @State private var gains: [Float] = EqualizerManager.shared.gains

    /// Centre frequencies of the five biquads, matching `EQPreset.bands`.
    private let labels = ["60", "230", "910", "3.6k", "14k"]
    private let range: ClosedRange<Float> = -12...12

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Equaliser").auraDisplay(22)
                Spacer()
                Button("Flat") { apply(EQPreset.flat.bands, preset: .flat) }
                    .disabled(gains.allSatisfy { $0 == 0 })
            }

            Picker("Preset", selection: presetBinding) {
                ForEach(EQPreset.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .labelsHidden()

            HStack(alignment: .bottom, spacing: 18) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    band(index: index, label: label)
                }
            }
            .frame(height: 180)
        }
        .padding(18)
        .frame(width: 380)
    }

    private func band(index: Int, label: String) -> some View {
        VStack(spacing: 6) {
            Text(gains.indices.contains(index) ? String(format: "%+.0f", gains[index]) : "0")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { gains.indices.contains(index) ? gains[index] : 0 },
                    set: { newValue in
                        guard gains.indices.contains(index) else { return }
                        gains[index] = newValue
                        // Any hand adjustment makes the setting Custom — otherwise the
                        // named preset would keep claiming credit for bands it no longer
                        // describes, and reselecting it would appear to do nothing.
                        apply(gains, preset: .custom)
                    }
                ),
                in: range
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 130)
            .frame(width: 26, height: 130)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var presetBinding: Binding<EQPreset> {
        Binding(
            get: { settings.eqPreset },
            set: { preset in
                let bands = preset == .custom ? settings.eqCustomBands : preset.bands
                gains = bands
                apply(bands, preset: preset)
            }
        )
    }

    private func apply(_ bands: [Float], preset: EQPreset) {
        gains = bands
        settings.eqPreset = preset
        if preset == .custom { settings.eqCustomBands = bands }
        settings.save()
        EqualizerManager.shared.applyBands(bands)
    }
}
