import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - The value

/// A colour borrowed from a piece of artwork, kept as hue and saturation rather than as
/// a finished `Color`.
///
/// Split that way because the same record has to ground a dark page and a light one, and
/// those are not the same colour at different opacities — one is a deep tone the page
/// sinks into, the other a wash the page barely notices.
struct ArtworkTintValue: Equatable, Sendable {
    let hue: Double
    let saturation: Double
    /// How bright the cover itself is, 0...1. Only ever used to move the header within a
    /// narrow band, so a bright sleeve reads a little lighter than a dark one — never
    /// enough to make one header pale and another black.
    let weight: Double

    func color(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hue: hue, saturation: saturation, brightness: 0.23 + 0.11 * weight)
            : Color(hue: hue, saturation: saturation * 0.40, brightness: 0.975 - 0.02 * weight)
    }
}

// MARK: - The service

/// The colour a page borrows from its own cover.
///
/// This is the thing a flat theme cannot do: an album, playlist or artist page grounded
/// in a colour taken from its own artwork feels like it belongs to that record rather
/// than to the app. The colour lives in a short fade at the very top and is gone before
/// the track list begins — the same shape Spotify uses, and for the same reason. A tint
/// that carried on down the page would fight every cover thumbnail in the list.
///
/// What comes back is never the cover's colour as measured. Sleeves are white, or black,
/// or neon, and a header has to stay dark enough to carry white text while still reading
/// as a colour at all. So only the *hue* is the artwork's; saturation and brightness are
/// forced into a band. That is why a washed-out sleeve and a garish one produce headers
/// of the same weight, which is the whole point — the page is grounded, not decorated.
@MainActor
@Observable
final class ArtworkTint {
    static let shared = ArtworkTint()
    private init() {}

    private var tints: [String: ArtworkTintValue] = [:]
    /// Covers already looked at and found to have no usable hue — grey sleeves, black and
    /// white photography. Remembered so they aren't re-analysed on every appearance.
    private var monochrome: Set<String> = []
    private var inFlight: Set<String> = []

    func tint(for coverArt: String?) -> ArtworkTintValue? {
        guard let coverArt else { return nil }
        return tints[coverArt]
    }

    /// Works out a cover's tint, preferring a bitmap the artwork cache already holds.
    ///
    /// Falls back to `fetchImage`, which is throttled and cached like every other cover —
    /// and which, on a detail page, is very often the exact request the header artwork is
    /// making anyway, so the two share one download rather than racing for two.
    func resolve(coverArt: String?) async {
        guard let coverArt,
              tints[coverArt] == nil,
              !monochrome.contains(coverArt),
              !inFlight.contains(coverArt) else { return }
        inFlight.insert(coverArt)
        defer { inFlight.remove(coverArt) }

        var image = ArtworkCache.shared.cachedImageAnySize(forCoverArt: coverArt)
        if image == nil {
            image = await ArtworkCache.shared.fetchImage(
                coverArt: coverArt,
                requestSize: ArtworkCache.thumbSize,
                key: "\(coverArt)_\(ArtworkCache.thumbSize)")
        }
        guard let image else { return }

        let value = await Task.detached(priority: .utility) {
            Self.tintValue(from: image)
        }.value

        if let value { tints[coverArt] = value } else { monochrome.insert(coverArt) }
    }

    // MARK: Extraction

    /// Averages the hue of the pixels that actually carry colour.
    ///
    /// Not "the most saturated pixel": on a noisy sleeve that is a coin-flip, and a single
    /// red logo in a corner would set the colour of the whole page. Hues are averaged as
    /// unit vectors rather than as numbers, because hue wraps — the mean of 0.02 and 0.98
    /// is red, not the cyan that averaging them arithmetically would give.
    private nonisolated static func tintValue(from image: PlatformImage) -> ArtworkTintValue? {
        guard let cg = image.auraCGImage else { return nil }
        // Forty pixels a side is plenty: this wants the record's overall colour, not any
        // of its detail, and the cost is paid on every page that opens.
        let w = min(cg.width, 40), h = min(cg.height, 40)
        guard w > 0, h > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var vectorX = 0.0, vectorY = 0.0, totalSaturation = 0.0, totalBrightness = 0.0, total = 0.0
        var overallBrightness = 0.0

        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            let (hue, saturation, brightness) = hsb(r, g, b)
            overallBrightness += brightness

            // Saturation squared: a pixel twice as colourful counts four times. Washed-out
            // and near-black pixels carry no hue worth averaging and are dropped outright.
            let weight = saturation * saturation * brightness
            guard weight > 0.002 else { continue }

            let angle = hue * 2 * .pi
            vectorX += cos(angle) * weight
            vectorY += sin(angle) * weight
            totalSaturation += saturation * weight
            totalBrightness += brightness * weight
            total += weight
        }

        // A monochrome sleeve has no hue to lend; the page keeps the app's own accent.
        guard total > 0 else { return nil }

        var hue = atan2(vectorY / total, vectorX / total) / (2 * .pi)
        if hue < 0 { hue += 1 }

        return ArtworkTintValue(
            hue: hue,
            // Held well clear of both ends: below this it stops being a colour, above it
            // the header starts competing with the artwork sitting on top of it.
            saturation: min(max(totalSaturation / total, 0.32), 0.62),
            weight: min(max(overallBrightness / Double(w * h), 0), 1)
        )
    }

    /// RGB to hue/saturation/brightness, all 0...1.
    private nonisolated static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b)
        let range = high - low
        var hue = 0.0
        if range > 0 {
            if high == r {
                hue = ((g - b) / range).truncatingRemainder(dividingBy: 6)
            } else if high == g {
                hue = (b - r) / range + 2
            } else {
                hue = (r - g) / range + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, high > 0 ? range / high : 0, high)
    }
}
