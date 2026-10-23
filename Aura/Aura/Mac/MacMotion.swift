import SwiftUI
import AppKit

/// A tile giving under the click: a touch smaller and dimmer while held, springing back.
struct MacPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.3), value: configuration.isPressed)
    }
}

/// A page arriving: in from a little to the right, fading up, settling on a spring, so a
/// push reads as moving forward. Only the fade under Reduce Motion.
struct MacPageEntrance: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown || reduceMotion ? 0 : 28)
            .overlay(alignment: .leading) { MacSwipeBackArrow() }
            .onAppear { withAnimation(.spring(duration: 0.38, bounce: 0.18)) { shown = true } }
    }
}

extension EnvironmentValues {
    /// The room a pushed page leaves above its header, which it lays out from the window's top.
    @Entry var macTopRoom: CGFloat = 0
}

extension View {
    func macPageEntrance() -> some View { modifier(MacPageEntrance()) }
}

/// The way back drawn in from the left edge as two fingers swipe right, as in Chrome:
/// the page stays put (there is nothing to show under it), and the arrow fills once letting
/// go will take you back.
private struct MacSwipeBackArrow: View {
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        let swipe = MacSwipeBack.shared
        let progress = min(swipe.offset / MacSwipeBack.threshold, 1)
        let armed = progress >= 1
        Image(systemName: "chevron.left")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(armed ? .white : .primary)
            .frame(width: 40, height: 40)
            .background(armed ? AnyShapeStyle(accentColor) : AnyShapeStyle(.regularMaterial), in: Circle())
            .scaleEffect(0.7 + 0.3 * progress)
            .opacity(progress)
            .offset(x: -44 + 64 * progress)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: armed)
            .allowsHitTesting(false)
    }
}

/// Two fingers swiping right on the trackpad take you back, the page following the fingers
/// and springing home if the swipe falls short — as in Safari and Finder.
@MainActor @Observable
final class MacSwipeBack {
    static let shared = MacSwipeBack()
    /// How far the page has been drawn to the right by the fingers.
    private(set) var offset: CGFloat = 0
    @ObservationIgnored private var travel: CGFloat = 0
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var swallowGlide = false
    @ObservationIgnored var canGoBack: () -> Bool = { false }
    @ObservationIgnored var goBack: () -> Void = {}

    /// How far the fingers travel before letting go goes back.
    static let threshold: CGFloat = 110

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // A swipe taken as a way back is the page's alone: passed on, the table under
            // the fingers scrolled sideways as well.
            self?.handle(event) == true ? nil : event
        }
    }

    /// Whether the event went to the swipe.
    private func handle(_ event: NSEvent) -> Bool {
        // The glide after the fingers lift belongs to the swipe that set it off.
        guard event.momentumPhase.isEmpty else { return swallowGlide }
        guard event.hasPreciseScrollingDeltas, canGoBack() else { return false }
        if event.phase.contains(.began) {
            travel = 0
            tracking = false
            swallowGlide = false
        }
        if event.phase.contains(.changed) {
            travel += event.scrollingDeltaX
            // Mostly sideways, or it's an ordinary scroll and left alone.
            if !tracking, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5, travel > 4 {
                tracking = true
            }
            if tracking { offset = max(0, travel) }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            guard tracking else { return false }
            tracking = false
            swallowGlide = true
            if travel >= Self.threshold {
                goBack()
            }
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { offset = 0 }
            return true
        }
        return tracking
    }
}
