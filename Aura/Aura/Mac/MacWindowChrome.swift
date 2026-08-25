import SwiftUI
import AppKit

/// Puts the close / minimise / zoom buttons back.
///
/// Hiding the toolbar outright is the only thing that removes the grey strip — but it takes
/// the three window buttons with it, because they live in the same titlebar view. They are
/// the system's, so they can be asked back individually without the strip coming with them.
struct MacWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // The view has no window until it is in the hierarchy, so this waits a turn.
        DispatchQueue.main.async { configure(probe.window) }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Dragging the window by its background, since there is no title bar left to grab.
        window.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
            window.standardWindowButton(button)?.alphaValue = 1
        }
    }
}
