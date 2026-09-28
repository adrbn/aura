import CoreText
import SwiftUI
import WatchKit

// What only a watch has, kept to this file: the pages call these, and the Mac that draws
// the pages' pictures (scripts/watch-screenshots) stands in its own versions.

extension View {
    /// The backdrop behind a screen of the navigation stack, laid as the container's own
    /// background so it reaches every edge of the display and holds still through a push.
    func screenBackdrop() -> some View {
        containerBackground(for: .navigation) { Backdrop() }
    }

    /// The phone's volume in the top trailing corner, beside the clock — which moves to the
    /// middle, as in the watch's own Now Playing — with the Crown on it, while `shown`.
    func volumeCorner(_ shown: Bool, tint: Color) -> some View {
        toolbar {
            if shown {
                ToolbarItem(placement: .topBarTrailing) {
                    CompanionVolume(tint: tint, isFocused: true)
                        .frame(width: 30, height: 30)
                }
            }
        }
    }

    /// The pinch of thumb and finger — double tap — presses this button.
    func primaryAction() -> some View {
        handGestureShortcut(.primaryAction)
    }

    /// The Crown walks through the lyrics a line at a time, with a detent's tick for each.
    /// `turned` hears only the Crown, never a value set from code; `idle` is called once it
    /// has been still for a moment.
    func lyricCrown(_ line: Binding<Double>, lines: Int,
                    turned: @escaping (Double) -> Void, idle: @escaping () -> Void) -> some View {
        modifier(LyricCrown(line: line, lines: lines, turned: turned, idle: idle))
    }
}

private struct LyricCrown: ViewModifier {
    @Binding var line: Double
    let lines: Int
    let turned: (Double) -> Void
    let idle: () -> Void
    @FocusState private var hasCrown: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($hasCrown)
            .digitalCrownRotation(detent: $line, from: 0, through: Double(max(0, lines - 1)), by: 1,
                                  sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true,
                                  onChange: { turned($0.offset) }, onIdle: idle)
            // The volume let go of the Crown as the lyrics came up; they take it.
            .onAppear { hasCrown = true }
    }
}

/// The watch's volume control, turned towards the phone: the Crown sets the iPhone's volume.
struct CompanionVolume: WKInterfaceObjectRepresentable {
    let tint: Color
    let isFocused: Bool

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .companion)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.setTintColor(UIColor(tint))
        if isFocused { control.focus() } else { control.resignFocus() }
    }
}

/// The phone's display face, Vavin Condensed, for the page titles it sets on the phone too.
enum WatchFonts {
    static func register() {
        for name in ["VavinCondensed-Bold-Latin"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
