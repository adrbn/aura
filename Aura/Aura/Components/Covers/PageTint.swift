import SwiftUI
import UIKit

/// Spotify's page tint: the top of an album, playlist or mix page takes the artwork's colour
/// and fades into the canvas, so every page opens in its own light.
enum PageTint {
    private final class Box {
        let color: UIColor
        init(_ color: UIColor) { self.color = color }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    static func cached(_ coverArt: String) -> UIColor? {
        cache.object(forKey: coverArt as NSString)?.color
    }

    /// The tint for a cover-art id, read from the smallest size of it the app keeps.
    static func load(_ coverArt: String) async -> UIColor? {
        if let hit = cached(coverArt) { return hit }
        let size = ArtworkCache.thumbSize
        guard let image = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: size,
                                                              key: "\(coverArt)_\(size)") else { return nil }
        let color = await Task.detached(priority: .utility) {
            FaceFraming.upright(image).map { tone(dominant(in: $0)) }
        }.value
        if let color { cache.setObject(Box(color), forKey: coverArt as NSString) }
        return color
    }

    /// `color` as a page tint: dark and still coloured behind white text; a pale wash in light
    /// mode. Greys stay grey rather than being pushed to an invented hue.
    static func tone(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let neutral = s < 0.12
        let dark = UIColor(hue: h, saturation: neutral ? s : min(0.75, max(0.4, s)), brightness: 0.38, alpha: 1)
        let light = UIColor(hue: h, saturation: neutral ? s : 0.22, brightness: 0.96, alpha: 1)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// The picture's most present colour: the hue carrying the most saturated, lit pixels,
    /// averaged over those pixels. A picture with almost no colour gives its plain average.
    static func dominant(in cg: CGImage) -> UIColor {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .gray }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var weights = [CGFloat](repeating: 0, count: 12)
        var sums = [[CGFloat]](repeating: [0, 0, 0], count: 12)
        var total: [CGFloat] = [0, 0, 0]
        for i in 0..<(n * n) {
            let rgb = (0..<3).map { CGFloat(px[i * 4 + $0]) / 255 }
            for c in 0..<3 { total[c] += rgb[c] }
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard s > 0.2, v > 0.15 else { continue }
            let bin = min(11, Int(h * 12))
            weights[bin] += s * v
            for c in 0..<3 { sums[bin][c] += rgb[c] * s * v }
        }
        let count = CGFloat(n * n)
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[best] > count * 0.03 else {
            return UIColor(red: total[0] / count, green: total[1] / count, blue: total[2] / count, alpha: 1)
        }
        let w = weights[best]
        return UIColor(red: sums[best][0] / w, green: sums[best][1] / w, blue: sums[best][2] / w, alpha: 1)
    }
}

/// The page canvas with a tint washed over its top, running up under the navigation bar.
struct TintedCanvas: View {
    let tint: UIColor?
    var height: CGFloat = 440

    var body: some View {
        ZStack(alignment: .top) {
            Color.themeBg
            if let tint {
                let color = Color(uiColor: tint)
                LinearGradient(stops: [.init(color: color, location: 0),
                                       .init(color: color.opacity(0.55), location: 0.45),
                                       .init(color: color.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.4), value: tint)
    }
}

/// `TintedCanvas` in the colour of a cover-art id.
struct ArtworkCanvas: View {
    let coverArt: String?

    @State private var loaded: (key: String, color: UIColor)?

    var body: some View {
        let tint = coverArt.flatMap { key in loaded?.key == key ? loaded?.color : PageTint.cached(key) }
        TintedCanvas(tint: tint)
            .task(id: coverArt) {
                guard let coverArt, loaded?.key != coverArt,
                      let color = await PageTint.load(coverArt), !Task.isCancelled else { return }
                loaded = (coverArt, color)
            }
    }
}
