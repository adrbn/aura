import SwiftUI
import UIKit
import Vision

/// Frames an artist's photograph on the face instead of on the middle of the picture.
///
/// Press shots are composed for a square, with the face high — often in the top fifth, and
/// sometimes cropped through the forehead. Centred in a header that runs up under the clock
/// and the floating buttons, that face ends up behind them, or cut by the top of the screen.
/// Knowing where the face is lets the header bring the photo down until the face sits in the
/// open part of the header, and grow the headroom that opens above it out of the photo's own
/// top edge.
enum FaceFraming {
    /// What Vision found in one photo.
    final class Analysis: Sendable {
        /// All the faces together — a band is framed as a group — normalised, with a top-left
        /// origin. Nil when there is no face to frame on (a logo, a drawing, an album cover).
        let face: CGRect?
        /// The photo's top rows, stretched to fill any headroom the framing opens above it.
        let topStrip: UIImage?

        init(face: CGRect?, topStrip: UIImage?) {
            self.face = face
            self.topStrip = topStrip
        }
    }

    /// Where the face should land, in points from the top of the frame.
    struct Target: Equatable {
        let faceCenterY: CGFloat
        /// How far the photo may come down to get it there.
        let maxHeadroom: CGFloat
    }

    /// Faces smaller than this share of the biggest one are people in the background.
    private static let minFaceShare: CGFloat = 0.35
    /// Height of the top strip grown into headroom, as a share of the photo.
    private static let stripShare: CGFloat = 0.04

    private static let cache: NSCache<NSString, Analysis> = {
        let cache = NSCache<NSString, Analysis>()
        cache.countLimit = 64
        return cache
    }()

    static func cached(_ key: String) -> Analysis? {
        cache.object(forKey: key as NSString)
    }

    /// Analyses once per image key; Vision runs off the main thread.
    static func analyse(_ image: UIImage, key: String) async -> Analysis {
        if let hit = cached(key) { return hit }
        let analysis = await Task.detached(priority: .userInitiated) { detect(in: image) }.value
        cache.setObject(analysis, forKey: key as NSString)
        return analysis
    }

    private static func detect(in image: UIImage) -> Analysis {
        guard let cg = upright(image) else { return Analysis(face: nil, topStrip: nil) }
        let strip = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width,
                                           height: max(1, Int(CGFloat(cg.height) * stripShare))))
            .map { UIImage(cgImage: $0) }

        return Analysis(face: faces(in: cg), topStrip: strip)
    }

    /// All the faces in an upright picture together, normalised with a top-left origin;
    /// people far smaller than the biggest face are left out as background.
    static func faces(in cg: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
        } catch {
            AppLogger.shared.log("⚠️ Face detection failed: \(error.localizedDescription)", level: .debug)
            return nil
        }
        let boxes = (request.results ?? []).map(\.boundingBox)
        let biggest = boxes.map(\.height).max() ?? 0
        let faces = boxes.filter { $0.height >= biggest * minFaceShare }
        guard let first = faces.first else { return nil }
        let union = faces.dropFirst().reduce(first) { $0.union($1) }
        // Vision measures from the bottom-left.
        return CGRect(x: union.minX, y: 1 - union.maxY, width: union.width, height: union.height)
    }

    /// The pixels as the photo is displayed. A JPEG carrying an EXIF rotation stores them
    /// sideways; read raw, the face and the "top" strip would come from the wrong axis.
    static func upright(_ image: UIImage) -> CGImage? {
        guard image.imageOrientation != .up else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format)
            .image { _ in image.draw(at: .zero) }
            .cgImage
    }

    /// Size and top-left position of a photo of `imageSize` filling `box`: centred when there
    /// is no face; otherwise moved so the face centre sits on `target` — as far as the photo
    /// still covers the sides and the bottom, and opens at most `maxHeadroom` at the top.
    static func placement(imageSize: CGSize, in box: CGSize, face: CGRect?,
                          target: Target) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: box) }
        let scale = max(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        guard let face else {
            return CGRect(origin: CGPoint(x: (box.width - size.width) / 2,
                                          y: (box.height - size.height) / 2), size: size)
        }
        let x = min(0, max(box.width - size.width, box.width / 2 - face.midX * size.width))
        let y = min(target.maxHeadroom,
                    max(box.height - size.height, target.faceCenterY - face.midY * size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// A photo filling its frame, framed on the face. Headroom opened above the photo is its own
/// top edge stretched upward and blurred, and the seam is feathered, so it reads as more of
/// the backdrop rather than a band.
struct FaceFramedPhoto: View {
    let image: UIImage
    let analysis: FaceFraming.Analysis
    let target: FaceFraming.Target

    /// Length of the feather where the photo's top edge melts into the headroom.
    private static let seam: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let place = FaceFraming.placement(imageSize: image.size, in: geo.size,
                                              face: analysis.face, target: target)
            let headroom = max(0, place.minY)
            ZStack(alignment: .topLeading) {
                if headroom > 0, let strip = analysis.topStrip {
                    Image(uiImage: strip)
                        .resizable()
                        .frame(width: place.width, height: headroom + Self.seam)
                        .blur(radius: 18, opaque: true)
                        .offset(x: place.minX)
                }
                Image(uiImage: image)
                    .resizable()
                    .frame(width: place.width, height: place.height)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: headroom > 0 ? .clear : .black, location: 0),
                            .init(color: .black, location: min(1, Self.seam / place.height)),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .offset(x: place.minX, y: place.minY)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}
