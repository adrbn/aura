import SwiftUI
import AppKit

/// Gives the window a full-bleed content area that still has its three buttons.
///
/// Two things had to be established by measurement rather than guessed at, because every
/// plausible SwiftUI modifier produced one of them at the cost of the other:
///
/// 1. The grey strip is an `NSToolbar`. SwiftUI keeps attaching one to this window whatever
///    `.toolbar(.hidden, for: .windowToolbar)` claims, so it is removed from the window
///    directly — the one instruction nothing downstream overrides.
/// 2. The buttons were never hidden. They sit at full alpha the whole time; it is their
///    container, `NSTitlebarView`, that SwiftUI drops to alpha 0, which takes them down
///    along with the strip. Restoring the container is what brings them back, and with the
///    bar transparent and no toolbar there is nothing else in it left to see.
///
/// Full screen is left alone: the system fades that same view on purpose there, and the
/// buttons are meant to be absent until the pointer reaches the top of the screen.
struct MacWindowChrome: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // No window until the view is in a hierarchy, so this waits a turn.
        DispatchQueue.main.async { context.coordinator.attach(to: probe.window) }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    final class Coordinator {
        private weak var window: NSWindow?

        /// Re-applied on the window's own events, not only on SwiftUI updates.
        ///
        /// Leaving full screen rebuilds the title bar and puts the container back to alpha 0,
        /// and there is no guarantee SwiftUI runs an update at that moment — which is exactly
        /// the case where the buttons stayed missing after coming out of full screen.
        func attach(to window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                self.window = window
                for name: NSNotification.Name in [
                    NSWindow.didExitFullScreenNotification,
                    NSWindow.didEnterFullScreenNotification,
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didResizeNotification,
                ] {
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.apply() }
                    }
                }
            }
            apply()
        }

        private func apply() {
            guard let window else { return }

            // Content runs the full height, under where the title bar would be.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // No visible bar left to grab, so the background does that job.
            window.isMovableByWindowBackground = true
            window.toolbar = nil

            guard !window.styleMask.contains(.fullScreen) else { return }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let view = window.standardWindowButton(button) else { continue }
                // Up the whole chain, not one step of it.
                //
                // The buttons live two containers deep — `NSTitlebarView` inside
                // `NSTitlebarContainerView` — and hiding the toolbar hides the *outer*
                // one. Restoring only the button and its immediate parent, as this did
                // before, left three perfectly visible widgets sitting inside an
                // invisible box: every property said `hidden = false, alpha = 1`, and
                // nothing was drawn. Walking to the window's frame view covers that, and
                // covers AppKit adding another layer in some later release.
                var node: NSView? = view
                while let current = node, current !== window.contentView?.superview {
                    current.isHidden = false
                    current.alphaValue = 1
                    node = current.superview
                }
            }
        }
    }
}
