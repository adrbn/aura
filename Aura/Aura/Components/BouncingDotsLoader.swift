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

    /// One full bounce, and how far apart the dots are within it.
    ///
    /// A third of a cycle each, so the three are evenly spread and no two can ever share a
    /// position — which is the whole point of a travelling wave.
    private let rise: CGFloat = 13
    private let period: Double = 0.9
    private let phaseStep: Double = 1.0 / 3.0

    var body: some View {
        // Driven from a clock, not from `.delay()` on a repeating animation. Delays attached
        // to `.repeatForever` are unreliable: when all three dots animate off the same value
        // change in one transaction SwiftUI can collapse them, and the first two ended up
        // moving in lockstep. Here each dot's height is a pure function of time and index,
        // so the offsets are correct by construction and cannot drift or merge.
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate / period
            HStack(spacing: spacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: -rise * lift(at: t - Double(index) * phaseStep))
                }
            }
        }
        // Reserve the travel so the row doesn't reflow as the dots move.
        .frame(height: dotSize + rise)
        .accessibilityElement()
        .accessibilityLabel("Searching")
    }
}

extension View {
    /// Centres the dots on their own row, with breathing room above and below.
    func searchLoadingRow() -> some View {
        frame(maxWidth: .infinity, alignment: .center)
            // A fixed inset, not `containerRelativeFrame`. The scroll container extends
            // behind the keyboard, so centring within it put the dots well above the middle
            // of the black area actually visible — which, while searching, is the strip
            // between the search field and the keyboard.
            .padding(.top, 170)
            .padding(.bottom, 40)
    }
}

private extension BouncingDotsLoader {
    /// Height of one dot at phase `t`, in 0...1.
    ///
    /// Only the positive half of a sine is used, so a dot rises, falls, and then *rests* on
    /// the line before its next hop — a bounce rather than a hover.
    func lift(at t: Double) -> CGFloat {
        CGFloat(max(0, sin(t * 2 * .pi)))
    }
}
