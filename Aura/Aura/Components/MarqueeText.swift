import SwiftUI

/// A single line of text that scrolls back and forth when it doesn't fit, so a long
/// title can be read in full instead of ending in an ellipsis.
///
/// Two layout traps this deliberately avoids, both of which it fell into first:
///
/// 1. `.fixedSize()` in the *layout* path propagates an unbounded width requirement all
///    the way up the tree. One long title in the mini player stretched the entire screen
///    sideways. The wide copy therefore lives in an `overlay`, which never feeds its size
///    back to its parent, over a hidden ordinary `Text` that drives height and accepts
///    whatever width is offered — exactly like the plain `Text` this replaced.
/// 2. Measuring with `PreferenceKey` from inside that overlay does not reliably reach an
///    `onPreferenceChange` on the parent, so the widths stayed at zero, `shouldScroll` was
///    always false, and the title just sat there centred and clipped at both ends.
///    `onGeometryChange` writes straight to state and works from either branch.
///
/// When the text fits, this renders exactly like a plain `Text` and never animates.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    /// Used only when the text fits; a scrolling line always starts flush left.
    var alignment: Alignment = .center

    /// Points per second — a reading pace, not a duration. A slightly-too-long title
    /// creeps and a very long one doesn't take a minute; both move at the same speed.
    private let speed: CGFloat = 20
    /// Hold still on the first word before setting off — a marquee that moves the instant
    /// it appears is unreadable, the eye hasn't landed yet — and again at the far end.
    private let startPause: Double = 1.6
    private let endPause: Double = 1.0

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    /// A point of slack, so text that "overflows" by a rounding error doesn't animate.
    private var shouldScroll: Bool { overflow > 1 }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay(alignment: shouldScroll ? .leading : alignment) {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: offset)
            }
            .clipped()
            // Re-runs when the text, the fit, or the available width changes, cancelling the
            // previous loop — so a song change never stacks two animations on one line.
            .task(id: "\(text)|\(shouldScroll)|\(Int(overflow))") { await run() }
    }

    private func run() async {
        offset = 0
        guard shouldScroll else { return }
        let travel = Double(overflow / speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(startPause))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: travel)) { offset = -overflow }

            try? await Task.sleep(for: .seconds(travel + endPause))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: travel)) { offset = 0 }

            try? await Task.sleep(for: .seconds(travel))
        }
    }
}
