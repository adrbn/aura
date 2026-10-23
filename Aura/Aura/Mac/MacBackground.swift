import SwiftUI

/// The window's ground, the iPhone's tab-root ground: the page colour (#121212 in dark,
/// white in light), the time-of-day glow across its top and the cutting-mat grid over both.
struct MacBackground: View {
    var grid = true
    /// Thirty frames a second: the motion is measured in seconds.
    private static let frameInterval = 1.0 / 30

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color.canvas
            TimelineView(.animation(minimumInterval: Self.frameInterval, paused: reduceMotion)) { context in
                GlowField(hue: DayHue.hue(at: Date()),
                          time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                          isDark: scheme == .dark)
            }
            .frame(height: 420)
            if grid { MacFadingGrid() }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The cutting mat, fading out as it goes down: firm under the titles, gone by the rows.
struct MacFadingGrid: View {
    var body: some View {
        WorkshopGrid()
            .mask(LinearGradient(colors: [.black, .black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
    }
}
