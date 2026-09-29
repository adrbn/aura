import SwiftUI

/// A single line of text that scrolls back and forth when it doesn't fit, so a long
/// title can be read in full instead of ending in an ellipsis.
///
/// When the text fits, this renders exactly like a plain `Text` and never animates.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    /// Used only when the text fits; a scrolling line always starts flush left.
    var alignment: Alignment = .center
    /// False while the line can't be seen, so it waits at its start instead of being
    /// found halfway through when it comes back.
    var isActive: Bool = true

    var body: some View {
        Marquee(key: text, alignment: alignment, isActive: isActive) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
        }
    }
}

/// One line of any content — a title, or a row of tappable artist names — that scrolls
/// back and forth when it doesn't fit, instead of being cut short.
///
/// Two layout traps this deliberately avoids, both of which it fell into first:
///
/// 1. `.fixedSize()` in the *layout* path propagates an unbounded width requirement all
///    the way up the tree. One long title in the mini player stretched the entire screen
///    sideways. The wide copy therefore lives in an `overlay`, which never feeds its size
///    back to its parent, over a hidden ordinary copy that drives height and accepts
///    whatever width is offered — exactly like the plain line this replaced.
/// 2. Measuring with `PreferenceKey` from inside that overlay does not reliably reach an
///    `onPreferenceChange` on the parent, so the widths stayed at zero, `shouldScroll` was
///    always false, and the title just sat there centred and clipped at both ends.
///    `onGeometryChange` writes straight to state and works from either branch.
///
/// Every run starts flush left and holds there before moving. The loop used to carry on
/// behind Now Playing, under the open lyrics and in the background, so a line was usually
/// found halfway through its travel, its beginning out of sight. It now stops whenever it
/// can't be seen and starts over when it can.
struct Marquee<Content: View>: View {
    /// What the line says. A new one starts over from the left.
    let key: String
    var alignment: Alignment = .center
    var isActive: Bool = true
    @ViewBuilder let content: () -> Content

    @Environment(\.scenePhase) private var scenePhase

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
    /// Identity of the moving copy. A fresh one per run, so a slide still in flight from
    /// the previous run can't carry over into the next one's first frames.
    @State private var run = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    /// A point of slack, so text that "overflows" by a rounding error doesn't animate.
    private var shouldScroll: Bool { overflow > 1 }
    private var isMoving: Bool { isActive && scenePhase == .active }

    var body: some View {
        content()
            .lineLimit(1)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay(alignment: shouldScroll ? .leading : alignment) {
                content()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: offset)
                    .id(run)
            }
            .clipped()
            // Re-runs when the line, the fit, the available width or visibility changes,
            // cancelling the previous loop — so a song change never stacks two animations.
            .task(id: "\(key)|\(shouldScroll)|\(Int(overflow))|\(isMoving)") { await loop() }
    }

    private func loop() async {
        guard shouldScroll, isMoving else {
            // Stopped, or nothing to scroll: back to the first word, gently. Never by
            // replacing the text — see `startOver`.
            if offset != 0 { withAnimation(.easeOut(duration: 0.3)) { offset = 0 } }
            return
        }
        startOver()
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

    /// A fresh copy at the first word — only when the text has moved off it. A copy at rest
    /// is left alone: a new one has no earlier frame, so it's drawn straight at its final
    /// place, outside any animation moving the view around it. Stopping the title as the
    /// lyrics opened did exactly that — it vanished from under the cover and reappeared
    /// over the year below, fading there.
    private func startOver() {
        guard offset != 0 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = 0
            run &+= 1
        }
    }
}
