import SwiftUI

/// What lies behind every page: the cover, blurred into a field of its own colours — the
/// phone's Now Playing backdrop at the watch's scale — or, with nothing playing, the
/// time-of-day glow of the phone's tab roots.
///
/// One layer for all three pages, so swiping between them moves the content over a
/// colour that stays put.
struct Backdrop: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isDimmed

    var body: some View {
        ZStack {
            Color.black
            if let artwork = model.artwork, model.state?.songId != nil {
                cover(artwork)
                    .transition(.opacity)
            } else {
                IdleGlow()
                    .transition(.opacity)
            }
        }
        // Always On: the colour stays, much quieter, as the system asks of large fields.
        .opacity(isDimmed ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.6), value: model.state?.artworkId)
        .animation(.easeInOut(duration: 0.6), value: model.artwork == nil)
        .ignoresSafeArea()
    }

    /// The phone's recipe: blurred far past recognition, scaled so the blur's soft edges
    /// fall off-screen, a veil the phone measured so white text always reads, and for a
    /// dark cover its liveliest colour screened back in.
    private func cover(_ artwork: UIImage) -> some View {
        // Sized by the screen, never by the picture: a square cover filling a taller screen
        // would otherwise widen the layer past the display and shift what's laid over it.
        Color.clear
            .overlay {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 36)
                    .scaleEffect(1.6)
                    .saturation(model.tone.saturation)
            }
            .overlay { Color.black.opacity(model.tone.veil) }
            .overlay {
                if let rgb = model.tone.vibrant, rgb.count == 3 {
                    Color(red: rgb[0], green: rgb[1], blue: rgb[2])
                        .opacity(0.4)
                        .blendMode(.screen)
                }
            }
            .drawingGroup()
    }
}

/// The phone's tab-root glow, over the #121212 page: the hue of the hour at the top,
/// fading to the page by the bottom. It breathes only while the screen is fully lit.
struct IdleGlow: View {
    @Environment(\.isLuminanceReduced) private var isDimmed

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: isDimmed)) { context in
            GlowField(hue: DayHue.hue(at: context.date),
                      time: context.date.timeIntervalSinceReferenceDate, isDark: true)
        }
        .background(Color.auraCanvas)
    }
}

extension Color {
    /// #121212, the phone's dark page.
    static let auraCanvas = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
}
