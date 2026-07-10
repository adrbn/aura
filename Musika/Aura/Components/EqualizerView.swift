import SwiftUI

struct EqualizerView: View {
    @State private var appSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Preset picker — fixed height so the horizontal ScrollView doesn't
                // greedily expand vertically (which pushed the bands down and left a gap).
                presetPicker
                    .frame(height: 44)
                    .padding(.top, 8)

                // EQ bands visualizer
                eqBandsView
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                // Reset / Info
                HStack {
                    if appSettings.eqPreset == .custom {
                        Button("Reset to Flat") {
                            withAnimation(.spring(response: 0.3)) {
                                appSettings.eqCustomBands = [0, 0, 0, 0, 0]
                                EqualizerManager.shared.applyBands(appSettings.eqCustomBands)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(accentColor)
                    }
                    Spacer()
                    Text("Drag sliders to adjust")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .background(Color.themeBg)
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(accentColor)
                }
            }
        }
    }

    // MARK: - Preset Picker

    private var presetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EQPreset.allCases, id: \.self) { preset in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            appSettings.eqPreset = preset
                            if preset == .custom {
                                EqualizerManager.shared.applyBands(appSettings.eqCustomBands)
                            } else {
                                EqualizerManager.shared.applyPreset(preset)
                            }
                        }
                    } label: {
                        Text(preset.rawValue)
                            .font(.subheadline.weight(appSettings.eqPreset == preset ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                appSettings.eqPreset == preset
                                    ? accentColor.opacity(0.2)
                                    : Color.themeGroupedBg
                            )
                            .foregroundStyle(
                                appSettings.eqPreset == preset
                                    ? accentColor
                                    : .primary
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        appSettings.eqPreset == preset
                                            ? accentColor.opacity(0.5)
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - EQ Bands

    private var eqBandsView: some View {
        GeometryReader { geo in
            let bandWidth = (geo.size.width - 48) / 5
            let sliderHeight = geo.size.height - 50

            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    eqBandSlider(index: i, height: sliderHeight)
                        .frame(width: bandWidth)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func eqBandSlider(index: Int, height: CGFloat) -> some View {
        let currentBands = appSettings.eqPreset == .custom
            ? appSettings.eqCustomBands
            : appSettings.eqPreset.bands

        let value = currentBands[index]
        let isCustom = appSettings.eqPreset == .custom

        return VStack(spacing: 6) {
            // dB label
            Text(String(format: "%+.0fdB", value))
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : accentColor)
                .frame(height: 16)

            // Vertical slider
            EQVerticalSlider(
                value: value,
                range: -20...20,
                height: height,
                isActive: isCustom,
                onChange: { newVal in
                    if appSettings.eqPreset != .custom {
                        // Copy current preset bands to custom before editing
                        appSettings.eqCustomBands = appSettings.eqPreset.bands
                        appSettings.eqPreset = .custom
                    }
                    appSettings.eqCustomBands[index] = newVal
                    EqualizerManager.shared.applyBands(appSettings.eqCustomBands)
                }
            )

            // Hz label
            Text(EQPreset.bandLabels[index])
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(height: 16)
        }
    }
}

// MARK: - Vertical EQ Slider

private struct EQVerticalSlider: View {
    let value: Float
    let range: ClosedRange<Float>
    let height: CGFloat
    let isActive: Bool
    let onChange: (Float) -> Void
    @Environment(\.appAccentColor) private var accentColor

    @State private var isDragging = false

    private let trackWidth: CGFloat = 4
    private let thumbSize: CGFloat = 26

    // Map value to Y position (top = max, bottom = min)
    private func yPosition(for val: Float) -> CGFloat {
        let fraction = CGFloat((val - range.lowerBound) / (range.upperBound - range.lowerBound))
        return height * (1.0 - fraction)
    }

    // Map Y position to value
    private func valueForY(_ y: CGFloat) -> Float {
        let fraction = 1.0 - (y / height)
        let clamped = max(0, min(1, Float(fraction)))
        let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        // Snap to 0.5 increments
        return (raw * 2).rounded() / 2
    }

    var body: some View {
        ZStack {
            // Track background
            RoundedRectangle(cornerRadius: trackWidth / 2)
                .fill(Color.white.opacity(0.08))
                .frame(width: trackWidth, height: height)

            // Zero line
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 16, height: 1)
                .offset(y: yPosition(for: 0) - height / 2)

            // Active fill from center to value
            let zeroY = yPosition(for: 0)
            let valY = yPosition(for: value)
            let fillHeight = abs(valY - zeroY)
            let fillOffset = (valY + zeroY) / 2 - height / 2

            RoundedRectangle(cornerRadius: trackWidth / 2)
                .fill(
                    value == 0
                        ? Color.clear
                        : (value > 0 ? accentColor : accentColor.opacity(0.7))
                )
                .frame(width: trackWidth, height: fillHeight)
                .offset(y: fillOffset)

            // Thumb
            Circle()
                .fill(.clear)
                .frame(width: isDragging ? thumbSize * 1.2 : thumbSize,
                       height: isDragging ? thumbSize * 1.2 : thumbSize)
                .glassEffect(.regular, in: .circle)
                .overlay(
                    Circle()
                        .fill(accentColor.opacity(0.5))
                        .frame(width: 8, height: 8)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .offset(y: valY - height / 2)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
        }
        .frame(width: thumbSize * 1.5, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    isDragging = true
                    let localY = gesture.location.y
                    let clamped = max(0, min(height, localY))
                    let newVal = valueForY(clamped)
                    onChange(newVal)
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: value)
    }
}

#Preview {
    EqualizerView()
}
