import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Cross-platform aliases
//
// Aura's engine — the cache, the player, the typography — is shared verbatim between the
// iOS app and the Mac one. These aliases are what let it be: the handful of places that
// genuinely need a bitmap, a font or a screen say so once, here, instead of every shared
// file carrying its own `#if`.

#if canImport(UIKit)
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
#else
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
// The cover templates are drawn in UIKit's terms; on the Mac the same names are AppKit's,
// with the few calls AppKit spells differently given below.
typealias UIImage = NSImage
typealias UIColor = NSColor

extension NSImage {
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Pixels and points are the same here: the size above is the bitmap's own.
    enum Orientation { case up }
    var scale: CGFloat { 1 }

    convenience init(cgImage: CGImage, scale: CGFloat, orientation: Orientation) {
        self.init(cgImage: cgImage)
    }
}

extension ImageRenderer {
    @MainActor var uiImage: NSImage? { nsImage }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}
#endif

extension PlatformImage {
    /// JPEG data, on either platform.
    ///
    /// `UIImage` hands this over directly; `NSImage` has no equivalent and has to be taken
    /// through a bitmap representation first, because it may be backed by anything at all —
    /// a PDF, a vector, several resolutions at once — rather than by pixels.
    func auraJPEGData(quality: CGFloat) -> Data? {
        #if canImport(UIKit)
        return jpegData(compressionQuality: quality)
        #else
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }
}

extension Image {
    /// `Image(uiImage:)` / `Image(nsImage:)`, spelled once.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// What the artwork cache needs to know about the display: how many pixels a point is worth,
/// and how wide a full-width image can get.
///
/// Both are only ever used to pick a download size, so an approximation is fine — which is
/// just as well on the Mac, where a window can be dragged between screens of different
/// scales and there is no single right answer.
enum PlatformScreen {
    static var scale: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.scale
        #else
        return NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }

    /// Width to size a full-bleed image against. On the Mac this is the screen rather than
    /// the window: the window is resizable, and re-fetching artwork on every drag would be
    /// far worse than occasionally fetching one size larger than needed.
    static var width: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #else
        return NSScreen.main?.frame.width ?? 1440
        #endif
    }
}
