import SwiftUI

/// The accent row of Settings: the ready-made colours, then any colour at all through the
/// system colour picker — its grid, spectrum, sliders, hex field, eyedropper and saved
/// colours — shown last in the row as the rainbow ring iOS uses for "any colour".
///
/// The swatches share the row's width evenly, so each is a full-height target rather
/// than a 20 pt dot squeezed beside the label.
struct AccentColourPicker: View {
    @Binding var accent: AppAccentColor
    @Binding var customRGB: [Double]

    private static let swatch: CGFloat = 26
    /// Below this relative luminance an accent all but vanishes on Aura's near-black.
    private static let darkest = 0.06
    /// Above it, the white labels on accent buttons stop reading.
    private static let lightest = 0.75

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accent Colour")
            HStack(spacing: 0) {
                ForEach(AppAccentColor.presets, id: \.self) { preset in
                    Button { accent = preset } label: {
                        swatch(preset.color, selected: accent == preset)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(preset.rawValue))
                    .accessibilityAddTraits(accent == preset ? .isSelected : [])
                }
                ColorPicker(selection: custom, supportsOpacity: false) {
                    Text("Custom Colour")
                }
                .labelsHidden()
                .overlay {
                    if accent == .custom {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .accessibilityAddTraits(accent == .custom ? .isSelected : [])
            }
            if accent == .custom, let warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ colour: Color, selected: Bool) -> some View {
        Circle()
            .fill(colour)
            .frame(width: Self.swatch, height: Self.swatch)
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    /// The picker writes the reader's colour and makes it the accent in one go.
    private var custom: Binding<Color> {
        Binding {
            Color(.sRGB, red: customRGB[0], green: customRGB[1], blue: customRGB[2])
        } set: { colour in
            let resolved = colour.resolve(in: EnvironmentValues())
            customRGB = [Double(resolved.red), Double(resolved.green), Double(resolved.blue)]
                .map { min(max($0, 0), 1) }
            if accent != .custom { accent = .custom }
        }
    }

    /// A word when the colour picked will be hard to read, without refusing it.
    private var warning: String? {
        let luminance = Self.relativeLuminance(customRGB)
        if luminance < Self.darkest {
            return String(localized: "This colour is hard to see on Aura's dark background.")
        }
        if luminance > Self.lightest {
            return String(localized: "White labels are hard to read on this colour.")
        }
        return nil
    }

    /// WCAG relative luminance of an sRGB colour.
    static func relativeLuminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { c in c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
