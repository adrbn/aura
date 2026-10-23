import SwiftUI

/// The five-band equaliser, driven by the same `EqualizerManager` the phone uses — the
/// filtering itself is a vDSP biquad on the audio tap, identical on both platforms.
struct MacEqualizerView: View {
    @State private var settings = AppSettings.shared
    @State private var gains: [Float] = EqualizerManager.shared.gains

    /// Centre frequencies of the five biquads, matching `EQPreset.bands`.
    private let labels = ["60", "230", "910", "3.6k", "14k"]
    private let range: ClosedRange<Float> = -12...12

    @Environment(\.appAccentColor) private var accentColor
    private static let faderHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Equaliser").auraDisplay(24)
                Spacer()
                Button("Flat") { apply(EQPreset.flat.bands, preset: .flat) }
                    .buttonStyle(.borderless)
                    .disabled(gains.allSatisfy { $0 == 0 })
            }

            Picker("Preset", selection: presetBinding) {
                ForEach(EQPreset.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    band(index: index, label: label).frame(maxWidth: .infinity)
                }
            }
            // The 0 dB line across every band, so a curve reads at a glance.
            .background {
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func gain(_ index: Int) -> Float { gains.indices.contains(index) ? gains[index] : 0 }

    private func band(index: Int, label: String) -> some View {
        VStack(spacing: 8) {
            Text(String(format: "%+.0f", gain(index)))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            fader(index: index)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// A thin track filled from 0 dB to the band's gain, dragged anywhere along it.
    private func fader(index: Int) -> some View {
        let h = Self.faderHeight
        let span = CGFloat(range.upperBound - range.lowerBound)
        let y = h / 2 - CGFloat(gain(index)) / span * h
        return ZStack(alignment: .top) {
            Capsule().fill(.primary.opacity(0.12)).frame(width: 4, height: h)
            Capsule().fill(accentColor)
                .frame(width: 4, height: abs(y - h / 2))
                .offset(y: min(y, h / 2))
            Circle().fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .frame(width: 14, height: 14)
                .offset(y: y - 7)
        }
        .frame(width: 28, height: h)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            guard gains.indices.contains(index) else { return }
            let value = Float((h / 2 - drag.location.y) / h * span)
            gains[index] = min(range.upperBound, max(range.lowerBound, value.rounded()))
            // Any hand adjustment makes the setting Custom — otherwise the named preset
            // would keep claiming credit for bands it no longer describes.
            apply(gains, preset: .custom)
        })
        .onTapGesture(count: 2) {
            guard gains.indices.contains(index) else { return }
            gains[index] = 0
            apply(gains, preset: .custom)
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
