import SwiftUI

// MARK: - Style

/// Where the light on a page comes from.
///
/// All three characters are the same idea — a mesh of accent-tinted light over a deep
/// ground — and differ only in the direction they're lit from. `.flat` is the app's
/// original single fill, kept because a plain ground is a legitimate taste and because
/// any whole-app change to the canvas should be one the user can undo.
enum AuraBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case flat
    case aurora
    case horizon
    case halo

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .flat:    return "Flat"
        case .aurora:  return "Aurora"
        case .horizon: return "Horizon"
        case .halo:    return "Halo"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .flat:    return "A single, even fill."
        case .aurora:  return "Light pooling in the corners."
        case .horizon: return "Light rising from below the player."
        case .halo:    return "One soft bloom behind the title."
        }
    }
}

// MARK: - The ground

/// The ground every page sits on.
///
/// A mesh gradient rather than a linear one, for the same reason as `MacBackground`:
/// a linear gradient always reads as a *direction*, and this should read as light in a
/// room. Two things are deliberately different on the phone.
///
/// It does not drift. The Mac's ground breathes because a desktop window is still while
/// you look at it; a phone screen is already moving under your thumb, and a field
/// sliding beneath a scrolling list is noise rather than atmosphere — bought, on top of
/// that, with frames that cost battery in your hand.
///
/// And it never reaches pure black. The darkest tone here is a deeply desaturated
/// accent, not `#000`: that single degree of colour is most of what separates a canvas
/// from a void, and it is what the flat fill was missing.
struct AuraBackground: View {
    /// Overrides the stored preference — used by the settings previews to show each
    /// character side by side.
    var style: AuraBackgroundStyle?

    @Environment(\.colorScheme) private var scheme

    private var resolved: AuraBackgroundStyle { style ?? AppSettings.shared.backgroundStyle }

    var body: some View {
        Group {
            if resolved == .flat {
                Color.themeBg
            } else {
                MeshGradient(width: 3, height: 4,
                             points: Self.points(for: resolved),
                             colors: colors(for: resolved))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Geometry

    /// A 3×4 mesh: wide enough to place light left, centre and right, tall enough to
    /// keep a band of deep ground across the middle, where the text actually sits.
    /// The rows are nudged off their even thirds so the field reads as weather rather
    /// than as a grid.
    private static func points(for style: AuraBackgroundStyle) -> [SIMD2<Float>] {
        switch style {
        case .flat, .aurora:
            return [
                .init(0, 0),    .init(0.50, 0),    .init(1, 0),
                .init(0, 0.32), .init(0.55, 0.28), .init(1, 0.34),
                .init(0, 0.68), .init(0.45, 0.72), .init(1, 0.66),
                .init(0, 1),    .init(0.50, 1),    .init(1, 1),
            ]
        case .horizon:
            // Rows crowd towards the bottom so the rise is gradual across the page and
            // then quick in the last stretch, the way a horizon actually falls off.
            return [
                .init(0, 0),    .init(0.50, 0),    .init(1, 0),
                .init(0, 0.42), .init(0.50, 0.40), .init(1, 0.42),
                .init(0, 0.74), .init(0.50, 0.76), .init(1, 0.74),
                .init(0, 1),    .init(0.50, 1),    .init(1, 1),
            ]
        case .halo:
            // The bloom's centre sits at roughly a quarter height — behind the big
            // title, above where any list begins.
            return [
                .init(0, 0),    .init(0.50, 0),    .init(1, 0),
                .init(0, 0.26), .init(0.50, 0.24), .init(1, 0.26),
                .init(0, 0.60), .init(0.50, 0.62), .init(1, 0.60),
                .init(0, 1),    .init(0.50, 1),    .init(1, 1),
            ]
        }
    }

    // MARK: Palette

    /// Four tones, darkest to brightest. Analogous hues — the accent and its immediate
    /// neighbours — rather than complementary ones: neighbours read as a single light
    /// source, opposites read as two lamps fighting over the room.
    private func colors(for style: AuraBackgroundStyle) -> [Color] {
        // One hue — the accent's — and nothing else. Earlier versions rotated the hue
        // between tones to give the field dimension; on a phone it just read as several
        // different colours smeared together. Depth here comes from brightness alone,
        // which is what a single lamp in a room actually does.
        let base  = tone(level: 0)
        let deep  = tone(level: 1)
        let midW  = tone(level: 2)
        let midC  = tone(level: 2)
        let glowW = tone(level: 3)
        let glowC = tone(level: 3)

        switch style {
        case .flat, .aurora:
            return [
                glowC, deep, glowW,
                deep,  base, midW,
                base,  base, base,
                midC,  deep, glowW,
            ]
        case .horizon:
            return [
                base,  base, base,
                deep,  base, deep,
                midC,  midW, midC,
                glowC, glowW, glowC,
            ]
        case .halo:
            return [
                deep,  midW,  deep,
                midC,  glowW, midC,
                base,  deep,  base,
                base,  base,  base,
            ]
        }
    }

    /// One tone of the ground: the accent's hue at one of four fixed depths. Dark and
    /// light are not the same palette inverted — dark carries
    /// real saturation because the colour has room to show against black, while light
    /// has to stay a whisper or the page stops being paper.
    private func tone(level: Int) -> Color {
        let h = AppSettings.shared.appAccentColor.hue
        if scheme == .dark {
            switch level {
            // The whole ramp spans six percent of brightness. That sounds like nothing,
            // and on the page it nearly is — which is the point: the moment the steps
            // are far enough apart to be told apart, the mesh's control points stop
            // being light and start being blobs. Depth you can see the shape of is
            // wallpaper. This is only meant to keep the screen from being a void.
            case 0:  return Color(hue: h, saturation: 0.24, brightness: 0.030)
            case 1:  return Color(hue: h, saturation: 0.29, brightness: 0.046)
            case 2:  return Color(hue: h, saturation: 0.34, brightness: 0.066)
            default: return Color(hue: h, saturation: 0.38, brightness: 0.090)
            }
        } else {
            switch level {
            case 0:  return Color(hue: h, saturation: 0.010, brightness: 1.000)
            case 1:  return Color(hue: h, saturation: 0.020, brightness: 0.997)
            case 2:  return Color(hue: h, saturation: 0.034, brightness: 0.992)
            default: return Color(hue: h, saturation: 0.050, brightness: 0.986)
            }
        }
    }
}

// MARK: - Page background

extension View {
    /// The app's page ground. Replaces a flat `Color.themeBg` fill on every full-page
    /// surface, so the canvas is defined in one place rather than twenty-six.
    /// Clears a list row's opaque fill so the page ground shows through, keeping the
    /// row's insets and separator. Goes on the `ForEach`/`Section` inside a `List` —
    /// `auraPageBackground()`, applied to the list itself, cannot reach the rows.
    func clearListRows() -> some View { listRowBackground(Color.clear) }

    func auraPageBackground(_ style: AuraBackgroundStyle? = nil) -> some View {
        // Hides the scroll view's own fill. The *rows* keep theirs — `listRowBackground`
        // does not reach them from out here — so anything with a `List` also needs
        // `clearListRows()` on its rows, or a black slab the height of the rows sits on
        // the ground, which is worse than no ground at all.
        scrollContentBackground(.hidden)
            .background { AuraBackground(style: style) }
    }
}
