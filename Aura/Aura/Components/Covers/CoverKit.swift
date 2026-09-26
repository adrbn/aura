import SwiftUI
import UIKit
import CoreText
import CoreImage

// The editorial covers' small design system, shared by every template instead of eleven
// one-offs:
// • one margin (6 % of the side) and one left axis every element snaps to;
// • one type family, Archivo (SIL OFL): extra-condensed black for titles, expanded for labels;
// • titles sized to fill their column exactly, laid out on their capital height;
// • the brand is the red play mark locked up with the series label — never a word.

enum CoverFont {
    static let title = "ArchivoXCondBlack"
    static let wide = "ArchivoExpBlack"
    static let label = "ArchivoExpBold"
}

/// The app icon's red.
let coverRed = Color(red: 1, green: 0.23, blue: 0.33)

struct CoverMetrics {
    let ascent: CGFloat
    let descent: CGFloat
    let cap: CGFloat

    init(_ font: String, _ size: CGFloat) {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        ascent = CTFontGetAscent(f)
        descent = CTFontGetDescent(f)
        cap = CTFontGetCapHeight(f)
    }

    static func width(_ text: String, _ font: String, _ size: CGFloat, tracking: CGFloat = 0) -> CGFloat {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f])
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + tracking * CGFloat(text.count)
    }

    /// Largest size at which `text` fits `width` without its capitals exceeding `maxCap`.
    static func fit(_ text: String, _ font: String, width: CGFloat, maxCap: CGFloat) -> CGFloat {
        let byWidth = 100 * width / max(1, Self.width(text, font, 100))
        let byCap = 100 * maxCap / max(1, CoverMetrics(font, 100).cap)
        return min(byWidth, byCap)
    }
}

/// Text whose layout box is exactly its capital height, so bands, margins and baselines line
/// up on the letters rather than on the font's ascender and descender padding.
struct CapText: View {
    let text: String
    let font: String
    let size: CGFloat
    var color: Color = .white
    var tracking: CGFloat = 0

    var body: some View {
        let m = CoverMetrics(font, size)
        Text(verbatim: text)
            .font(.custom(font, fixedSize: size))
            .tracking(tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.top, -(m.ascent - m.cap))
            .padding(.bottom, -m.descent)
    }
}

/// The app icon's play triangle, corners rounded like the icon's.
struct PlayMark: Shape {
    func path(in r: CGRect) -> Path {
        let radius = r.width * 0.16
        let a = CGPoint(x: r.minX, y: r.minY)
        let b = CGPoint(x: r.maxX, y: r.midY)
        let c = CGPoint(x: r.minX, y: r.maxY)
        var p = Path()
        p.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        p.addArc(tangent1End: a, tangent2End: b, radius: radius)
        p.addArc(tangent1End: b, tangent2End: c, radius: radius)
        p.addArc(tangent1End: c, tangent2End: a, radius: radius)
        p.closeSubpath()
        return p
    }
}

/// ▶ LABEL — the brand and the series in one lockup, top-left on every cover.
struct CoverLockup: View {
    static func size(_ s: CGFloat) -> CGFloat { s * 0.042 }
    static func height(_ s: CGFloat) -> CGFloat { CoverMetrics(CoverFont.label, size(s)).cap * 1.3 }

    let label: String
    let s: CGFloat
    var color: Color = .white
    var mark: Color = coverRed

    var body: some View {
        let size = Self.size(s)
        let cap = CoverMetrics(CoverFont.label, size).cap
        HStack(alignment: .center, spacing: cap * 0.6) {
            PlayMark().fill(mark).frame(width: cap * 1.15, height: cap * 1.3)
            if !label.isEmpty {
                CapText(text: label.uppercased(), font: CoverFont.wide, size: size, color: color,
                        tracking: size * 0.06)
            }
        }
    }
}

/// Darkens the top of a photo just enough for a white lockup to read over sky or a white wall.
struct CoverTopScrim: View {
    let s: CGFloat

    var body: some View {
        LinearGradient(colors: [.black.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: s * 0.24)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct CoverGrid {
    let s: CGFloat
    var margin: CGFloat { s * 0.06 }
    var column: CGFloat { s - 2 * margin }
}

// MARK: - Colour

/// A cover never invents a colour: it picks one from a short list that works as a flat band,
/// matched to the photo, and writes on it in whichever of black or white reads.
enum CoverPalette {
    static let bands: [UInt32] = [0xF7E11B, 0xC6F432, 0x6FF0C4, 0x3DCBFF, 0x2F5BFF,
                                  0x8C5CFF, 0xFF5FA8, 0xFF3B30, 0xFF7A1A]

    /// Shadow → highlight pairs for the duotone treatment, one picked per genre.
    static let duotones: [(dark: UInt32, light: UInt32)] = [
        (0x1A1150, 0xFF6FB5), (0x0B2E24, 0xC6F432), (0x0E1B4D, 0x3DCBFF),
        (0x2B0A3D, 0xF7E11B), (0x3A0B0B, 0xFF7A1A), (0x0E1B4D, 0x6FF0C4),
        (0x161616, 0xFF3B30), (0x1B0B3A, 0x8C5CFF),
    ]

    static func ui(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// The same band for the same seed on every launch.
    static func hashed(_ seed: String) -> UIColor {
        ui(bands[GeneratedCoverView.stableHash(seed) % bands.count])
    }

    static func duotone(for seed: String) -> (dark: UIColor, light: UIColor) {
        let pair = duotones[GeneratedCoverView.stableHash(seed) % duotones.count]
        return (ui(pair.dark), ui(pair.light))
    }

    static func luminance(_ c: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func ink(on c: UIColor) -> Color { luminance(c) > 0.55 ? .black : .white }

    /// The band closest in hue to the photo's dominant colour. Skin is left out — a face
    /// would otherwise pick salmon for every portrait. Nil for a neutral photo.
    static func band(in cg: CGImage) -> UIColor? {
        let n = 48
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var bins = [CGFloat](repeating: 0, count: 18)
        for i in 0..<(n * n) {
            let c = UIColor(red: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255,
                            blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            guard s > 0.28, v > 0.25 else { continue }
            if h < 0.12 && s < 0.75 { continue } // skin
            bins[min(17, Int(h * 18))] += s * v
        }
        guard let best = bins.enumerated().max(by: { $0.element < $1.element }),
              best.element > CGFloat(n * n) * 0.02 else { return nil }
        let hue = (CGFloat(best.offset) + 0.5) / 18
        return bands.map(ui).min { hueDistance($0, hue) < hueDistance($1, hue) }
    }

    private static func hueDistance(_ c: UIColor, _ hue: CGFloat) -> CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let d = abs(h - hue)
        return min(d, 1 - d)
    }
}

// MARK: - Image treatments

enum CoverImaging {
    private static let context = CIContext()

    /// Grey, contrast up, then shadows mapped to `dark` and highlights to `light` — how
    /// unrelated press shots are made to belong to one series.
    static func duotone(_ image: UIImage, dark: UIColor, light: UIColor) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let out = CIImage(cgImage: cg)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0,
                                                            kCIInputContrastKey: 1.2])
            .applyingFilter("CIFalseColor", parameters: ["inputColor0": CIColor(color: dark),
                                                         "inputColor1": CIColor(color: light)])
        guard let result = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: result, scale: image.scale, orientation: .up)
    }

    /// Fine grey noise, made once. Laid over a cover it reads as print rather than as a flat
    /// fill; stretched to the cover, so it grows finer on a small one and all but vanishes.
    static let grain: UIImage? = {
        let side: CGFloat = 512
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]),
              let cg = context.createCGImage(noise, from: noise.extent) else { return nil }
        return UIImage(cgImage: cg)
    }()

    /// Average colour of a horizontal strip of the picture, `from`…`to` as fractions from the top.
    static func average(of cg: CGImage, from: CGFloat, to: CGFloat) -> UIColor {
        let src = CIImage(cgImage: cg)
        let h = src.extent.height
        // Core Image's y axis points up.
        let strip = CGRect(x: 0, y: h * (1 - to), width: src.extent.width, height: h * (to - from))
        let avg = src.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: strip)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

/// The grain, blended into whatever the cover drew beneath it.
struct CoverGrain: View {
    var opacity: CGFloat = 0.16

    var body: some View {
        if let grain = CoverImaging.grain {
            Image(uiImage: grain)
                .resizable()
                .interpolation(.none)
                .blendMode(.overlay)
                .opacity(opacity)
                .allowsHitTesting(false)
        }
    }
}

/// A cover drawn once into a picture — a playlist saved from a mix or a radio takes its cover
/// along to the server.
enum CoverRendering {
    /// Points; rendered at 2× for 1200 pixels, what the server keeps of a playlist picture.
    static let side: CGFloat = 600

    @MainActor
    static func jpeg(_ cover: some View) -> Data? {
        let renderer = ImageRenderer(content: cover.frame(width: side, height: side))
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.uiImage?.jpegData(compressionQuality: 0.9)
    }
}
