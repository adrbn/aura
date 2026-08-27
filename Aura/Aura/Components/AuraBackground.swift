import SwiftUI

// MARK: - Style

/// What grounds a page.
///
/// The default is deliberately the quiet one. A colour field under every screen sounds
/// richer than it looks: the navigation tabs are already full of artwork, and a second
/// colour underneath them competes with the covers instead of supporting them. So the
/// tabs get a plain ground, and the colour is spent where it means something — the top
/// of an album, playlist or artist page, taken from that record's own sleeve.
///
/// The mesh characters stay for anyone who wants the whole app tinted.
enum AuraBackgroundStyle: String, Codable, CaseIterable, Identifiable {
    /// Near-black, warmed by a trace of the accent. Uniform.
    case plain
    case aurora
    case horizon
    case halo

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .plain:   return "Plain"
        case .aurora:  return "Aurora"
        case .horizon: return "Horizon"
        case .halo:    return "Halo"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .plain:   return "An even ground. Colour comes from the artwork."
        case .aurora:  return "Light pooling in the corners."
        case .horizon: return "Light rising from below the player."
        case .halo:    return "One soft bloom behind the title."
        }
    }

    var isMesh: Bool { self != .plain }
}

// MARK: - The ground

/// The ground a page sits on: an even tone, plus — on pages that have artwork of their
/// own — a short fade of that artwork's colour at the very top.
///
/// The even tone is not black. On an OLED screen pure black is not a dark colour, it is
/// the absence of one, and content stops sitting *on* anything. A few percent of
/// brightness, carrying a trace of the accent's hue, is the whole difference between a
/// canvas and a void, and it is not visible as a colour — only as the absence of a hole.
///
/// The fade is where the colour actually lives. It is strong at the top edge, and gone
/// by a little under half the page, before any track list begins. Carrying it further
/// down would put a coloured wash behind every cover thumbnail in the list, which is
/// exactly the fight it is meant to avoid.
struct AuraBackground: View {
    /// Overrides the stored preference — used by the settings previews.
    var style: AuraBackgroundStyle?
    /// The page's own artwork colour, if it has one.
    var tint: ArtworkTintValue?

    @Environment(\.colorScheme) private var scheme

    private var resolved: AuraBackgroundStyle { style ?? AppSettings.shared.backgroundStyle }

    var body: some View {
        ZStack {
            if resolved.isMesh {
                MeshGradient(width: 3, height: 4,
                             points: Self.points(for: resolved),
                             colors: colors(for: resolved))
            } else {
                tone(level: 0)
            }

            if let tint {
                LinearGradient(
                    stops: [
                        .init(color: tint.color(for: scheme).opacity(0.85), location: 0.00),
                        .init(color: tint.color(for: scheme).opacity(0.45), location: 0.12),
                        .init(color: tint.color(for: scheme).opacity(0.14), location: 0.28),
                        .init(color: .clear,                                location: 0.46),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Geometry

    /// A 3×4 mesh: wide enough to place light left, centre and right, tall enough to keep
    /// a band of deep ground across the middle, where the text sits. The rows are nudged
    /// off their even thirds so the field reads as weather rather than as a grid.
    private static func points(for style: AuraBackgroundStyle) -> [SIMD2<Float>] {
        switch style {
        case .plain, .aurora:
            return [
                .init(0, 0),    .init(0.50, 0),    .init(1, 0),
                .init(0, 0.32), .init(0.55, 0.28), .init(1, 0.34),
                .init(0, 0.68), .init(0.45, 0.72), .init(1, 0.66),
                .init(0, 1),    .init(0.50, 1),    .init(1, 1),
            ]
        case .horizon:
            return [
                .init(0, 0),    .init(0.50, 0),    .init(1, 0),
                .init(0, 0.42), .init(0.50, 0.40), .init(1, 0.42),
                .init(0, 0.74), .init(0.50, 0.76), .init(1, 0.74),
                .init(0, 1),    .init(0.50, 1),    .init(1, 1),
            ]
        case .halo:
            return [
                .init(0, 0),    .init(0.50, 0),    .init(1, 0),
                .init(0, 0.26), .init(0.50, 0.24), .init(1, 0.26),
                .init(0, 0.60), .init(0.50, 0.62), .init(1, 0.60),
                .init(0, 1),    .init(0.50, 1),    .init(1, 1),
            ]
        }
    }

    // MARK: Palette

    /// One hue — the accent's — and nothing else. Depth comes from brightness alone,
    /// which is what a single lamp in a room actually does; rotating the hue between
    /// tones just read as several different colours smeared together.
    private func colors(for style: AuraBackgroundStyle) -> [Color] {
        let base = tone(level: 0), deep = tone(level: 1)
        let mid  = tone(level: 2), glow = tone(level: 3)

        switch style {
        case .plain, .aurora:
            return [glow, deep, glow,
                    deep, base, mid,
                    base, base, base,
                    mid,  deep, glow]
        case .horizon:
            return [base, base, base,
                    deep, base, deep,
                    mid,  mid,  mid,
                    glow, glow, glow]
        case .halo:
            return [deep, mid,  deep,
                    mid,  glow, mid,
                    base, deep, base,
                    base, base, base]
        }
    }

    /// One tone of the ground, at one of four depths.
    ///
    /// The whole ramp spans six percent of brightness. That sounds like nothing, and on
    /// the page it nearly is — which is the point: the moment the steps are far enough
    /// apart to be told apart, the mesh's control points stop being light and start being
    /// blobs. Depth you can see the shape of is wallpaper.
    ///
    /// Dark and light are not one palette inverted. Dark can carry real saturation,
    /// because colour has room to show against black; light has to stay a whisper or the
    /// page stops being paper.
    private func tone(level: Int) -> Color {
        let h = AppSettings.shared.appAccentColor.hue
        if scheme == .dark {
            switch level {
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
    /// Clears a list row's opaque fill so the page ground shows through, keeping the row's
    /// insets and separator. Goes on the `ForEach`/`Section` inside a `List` —
    /// `auraPageBackground()`, applied to the list itself, cannot reach the rows.
    func clearListRows() -> some View { listRowBackground(Color.clear) }

    /// The app's page ground.
    ///
    /// Hides the scroll view's own fill; the *rows* keep theirs, so anything with a `List`
    /// also needs `clearListRows()` on its rows, or a black slab the exact height of the
    /// rows sits on the ground — worse than no ground at all.
    func auraPageBackground(style: AuraBackgroundStyle? = nil, tint: ArtworkTintValue? = nil) -> some View {
        scrollContentBackground(.hidden)
            .background { AuraBackground(style: style, tint: tint) }
    }

    /// A page grounded in its own artwork: resolves `coverArt`'s colour and fades it in
    /// behind the top of the page. Cheap to call — the colour is worked out once per cover
    /// and remembered, and it reuses whatever bitmap the artwork cache already holds.
    func auraArtworkBackground(coverArt: String?) -> some View {
        modifier(ArtworkGroundedPage(coverArt: coverArt))
    }
}

/// Resolves a page's artwork colour and hands it to the ground.
private struct ArtworkGroundedPage: ViewModifier {
    let coverArt: String?
    @State private var tintService = ArtworkTint.shared

    func body(content: Content) -> some View {
        content
            .auraPageBackground(tint: tintService.tint(for: coverArt))
            // The colour arrives after the page does — a cover that is not cached yet has
            // to be fetched — so it fades in rather than snapping on once the list has
            // already been read.
            .animation(.easeInOut(duration: 0.45), value: tintService.tint(for: coverArt))
            .task(id: coverArt) { await tintService.resolve(coverArt: coverArt) }
    }
}
