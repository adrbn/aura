import SwiftUI

/// Three dots rising and falling one after the other — the app's "still looking" state.
///
/// It replaces `ProgressView()` on the search-style waits. A stock spinner is a thin
/// stroked ring: tinted `.secondary` over Aura's pure-black background it is very nearly
/// invisible, which is why a search could look frozen while it was in fact running. Solid
/// filled dots read at a glance on any background, and the travelling wave says "working"
/// without needing a word of copy next to it.
///
/// The motion is modelled on `LoadingThreeBallsBouncing` from SwiftfulLoadingIndicators
/// (github.com/SwiftfulThinking/SwiftfulLoadingIndicators). That package is NOT a
/// dependency here and deliberately so: it ships without a LICENSE file — so no usage
/// rights are granted at all — and hasn't been touched since March 2021. It also drives
/// its animation from an always-on `Timer.publish`, where a plain `repeatForever`
/// animation costs nothing and stops with the view.
struct BouncingDotsLoader: View {
    /// `.primary`, not `.secondary`: secondary is a translucent grey that washed out to
    /// near-nothing on the black background — the same reason the old spinner was invisible.
    /// Primary resolves to solid white in dark mode and solid black in light.
    var color: Color = .primary
    var dotSize: CGFloat = 17
    var spacing: CGFloat = 14

    /// How far a dot lifts, and how long one rise takes. The stagger is a third of the
    /// cycle so the three dots read as a travelling wave rather than a shared pulse.
    private let rise: CGFloat = 13
    private let riseDuration: Double = 0.32
    private let stagger: Double = 0.15

    @State private var lifted = false

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: lifted ? -rise : 0)
                    .animation(
                        .easeInOut(duration: riseDuration)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * stagger),
                        value: lifted
                    )
            }
        }
        // Reserve the travel so the row doesn't reflow as the dots move.
        .frame(height: dotSize + rise)
        .onAppear { lifted = true }
        .accessibilityElement()
        .accessibilityLabel("Searching")
    }
}

extension View {
    /// Centres the dots on their own row, with breathing room above and below.
    func searchLoadingRow() -> some View {
        frame(maxWidth: .infinity, alignment: .center)
            // Claims most of the empty area below the search field and centres itself in it,
            // rather than sitting just under the field with fixed padding — which read as
            // cramped against results that hadn't arrived yet. Relative, not a fixed height,
            // so it stays centred on every screen size.
            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height * 0.62 }
    }
}
