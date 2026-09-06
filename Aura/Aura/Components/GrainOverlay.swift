import SwiftUI

/// A film grain laid over the whole window.
///
/// Pure black on an OLED panel is not a dark colour, it is the absence of one: no texture,
/// no reflection, nothing for the eye to land on. Content ends up floating on a hole rather
/// than sitting on a surface. Every earlier attempt to fix that put *something* behind the
/// content — a mesh, a bloom, a tint pulled from the artwork — and each one failed the same
/// way, by being visible. A ground you can see the shape of has already lost.
///
/// Grain is the one addition that carries no hue and no contour. It reads as the material a
/// dark surface is made of — film, vinyl, paper — at a strength where you would struggle to
/// point at it, and it disappears entirely under artwork. It is drawn once for the window
/// rather than per page, because that is what grain is: a property of the screen, not of a
/// screenful.
struct GrainOverlay: View {
    /// Roughly three percent. Past about five it stops reading as material and starts
    /// reading as a dirty screen; below two it may as well not be there.
    var intensity: Double = 0.032
    /// Shimmering grain, for the splash and onboarding only.
    ///
    /// It costs a full-screen redraw several times a second, which is affordable for two
    /// seconds of launch and not for a list being scrolled. Everywhere else the grain
    /// holds still, and nobody notices that it does.
    var animated: Bool = false

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { timeline in
                    tile(seed: UInt64(timeline.date.timeIntervalSince1970 * 8))
                }
            } else {
                tile(seed: 0)
            }
        }
        .opacity(intensity)
        // Lightens only — grain on black has to add light, since there is none to remove.
        .blendMode(.plusLighter)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func tile(seed: UInt64) -> some View {
        Image(decorative: Self.tiles[Int(seed % UInt64(Self.tiles.count))], scale: 1)
            .resizable(resizingMode: .tile)
    }

    /// A handful of 128×128 tiles, built once and repeated.
    ///
    /// Generated rather than shipped as assets so they cost no download and no binary
    /// weight. Several of them because the animated mode cycles between them — swapping a
    /// ready texture is most of the shimmer at none of the price of redrawing every pixel.
    private static let tiles: [CGImage] = (0..<6).map { _ in makeTile(side: 128) }

    private static func makeTile(side: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: side * side)
        var generator = SystemRandomNumberGenerator()
        for i in 0..<pixels.count {
            // A narrow band rather than the full range: full-range noise sparkles, and
            // sparkle is the thing that makes grain look cheap.
            pixels[i] = UInt8.random(in: 96...255, using: &generator)
        }
        let context = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        // A blank tile is the correct failure: the overlay simply contributes nothing.
        return context?.makeImage() ?? Self.blankTile(side: side)
    }

    private static func blankTile(side: Int) -> CGImage {
        var pixel: UInt8 = 0
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        return context!.makeImage()!
    }
}
