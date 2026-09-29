#if os(iOS)
import CarPlay
import SwiftUI

/// The car's pictures: the server's covers from the phone's own cache, the Home's editorial
/// mix covers drawn as the phone draws them, and a glyph on a tile where there is no cover.
@MainActor
enum CarPlayArtwork {
    /// A server cover at the phone's thumbnail size, the list's rows being smaller still.
    static func cover(_ coverArt: String?) async -> UIImage? {
        guard let coverArt, !coverArt.isEmpty else { return nil }
        let size = ArtworkCache.thumbSize
        return await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: size,
                                                    key: "\(coverArt)_\(size)")
    }

    /// A mix's cover as the Home shows it. Without `photo`, only what's already cached: the
    /// typographic cover is complete on its own, so the shelf never waits on a portrait.
    static func mixCover(_ mix: Mix, photo: Bool, scale: CGFloat) async -> UIImage {
        let spec = MixCoverSpec(mix)
        let art = photo ? await MixCoverArt.load(spec) : MixCoverArt.cached(spec)
        let box = CPListImageRowItemRowElement.maximumImageSize
        let side = min(box.width, box.height)
        let renderer = ImageRenderer(content: EditorialMixCover.template(spec, art, size: side)
            .frame(width: side, height: side)
            .clipped())
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage ?? glyph("music.note.list")
    }

    /// A glyph centred on a tinted tile, for a row whose item has no picture of its own —
    /// the favourites' heart in the accent, as on the phone.
    static func glyph(_ symbol: String, tint: UIColor = .white) -> UIImage {
        let side: CGFloat = 60
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            tint.withAlphaComponent(0.22).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.4, weight: .semibold)
            guard let image = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
            image.draw(at: CGPoint(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2))
        }
    }

    /// A bare symbol that stays legible in both of the car's appearances. The car draws a
    /// template image as it comes — black, lost on the dark list — so each look gets its own.
    static func symbol(_ name: String) -> UIImage {
        guard let base = UIImage(systemName: name) else { return glyph(name) }
        let asset = UIImageAsset()
        asset.register(base.withTintColor(.black, renderingMode: .alwaysOriginal),
                       with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(base.withTintColor(.white, renderingMode: .alwaysOriginal),
                       with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
    }

    /// Header buttons' faces — each symbol and its word drawn as one picture, since the car
    /// shortens a button's own title to "…". The car scales a picture to its button by width,
    /// so all share the widest one's canvas and come out the same size.
    @available(iOS 26.4, *)
    static func labels(_ faces: [(title: String, symbol: String)]) -> [UIImage] {
        let limit = CPListTemplateDetailsHeader.maximumActionButtonSize
        let font = UIFont.systemFont(ofSize: min(17, limit.height * 0.5), weight: .semibold)
        let gap = font.pointSize * 0.4
        let parts = faces.map { face in
            (text: face.title,
             icon: UIImage(systemName: face.symbol, withConfiguration: UIImage.SymbolConfiguration(font: font)))
        }
        let widths = parts.map { part in
            (part.icon?.size.width ?? 0) + (part.icon == nil ? 0 : gap)
                + NSAttributedString(string: part.text, attributes: [.font: font]).size().width
        }
        let size = CGSize(width: min(limit.width, ceil(widths.max() ?? 0)), height: limit.height)
        return zip(parts, widths).map { part, width in
            let draw = { (tint: UIColor) -> UIImage in
                let text = NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: tint])
                let icon = part.icon?.withTintColor(tint, renderingMode: .alwaysOriginal)
                let left = max(0, (size.width - width) / 2)
                return UIGraphicsImageRenderer(size: size).image { _ in
                    icon?.draw(at: CGPoint(x: left, y: (size.height - (icon?.size.height ?? 0)) / 2))
                    let start = left + (icon.map { $0.size.width + gap } ?? 0)
                    text.draw(at: CGPoint(x: start, y: (size.height - text.size().height) / 2))
                }
            }
            let asset = UIImageAsset()
            asset.register(draw(.black), with: UITraitCollection(userInterfaceStyle: .light))
            asset.register(draw(.white), with: UITraitCollection(userInterfaceStyle: .dark))
            return asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
        }
    }

    static var accent: UIColor {
        UIColor(AppSettings.shared.activeTheme.accentColor)
    }
}
#endif
