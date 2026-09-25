import SwiftUI
import UIKit
import Vision

/// Frames an artist's photograph on the face instead of on the middle of the picture.
///
/// Press shots are composed for a square, with the face high — often in the top fifth, and
/// sometimes cropped through the forehead. Centred in a header that runs up under the clock
/// and the floating buttons, that face ends up behind them, or cut by the top of the screen.
/// Knowing where the face is lets the header zoom in on it until it sits in the open part of
/// the header — the photo always fills the frame with its own pixels, nothing stretched or
/// blurred in above it.
enum FaceFraming {
    /// What Vision found in one photo.
    final class Analysis: Sendable {
        /// All the faces together — a band is framed as a group — normalised, with a top-left
        /// origin. Nil when there is no face to frame on (a logo, a drawing, an album cover).
        let face: CGRect?
        /// Whether the top of the photo — what the clock sits on — is bright enough to lose it.
        let topIsBright: Bool

        init(face: CGRect?, topIsBright: Bool = false) {
            self.face = face
            self.topIsBright = topIsBright
        }
    }

    /// Where the face should land, in points from the top of the frame.
    struct Target: Equatable {
        let faceCenterY: CGFloat
    }

    /// Faces smaller than this share of the biggest one are people in the background.
    private static let minFaceShare: CGFloat = 0.35
    /// How far a photo may be enlarged to bring a high face down: past this a press shot,
    /// often a thousand pixels wide, turns soft on a phone.
    private static let maxZoom: CGFloat = 1.7
    /// A face enlarged past this share of the frame's height is no longer a portrait.
    private static let maxFaceShare: CGFloat = 0.5
    /// The band under the status bar, as a share of the photo, and the average luminance
    /// above which white text on it stops reading — a sky, a white studio wall.
    private static let clockShare: CGFloat = 0.12
    private static let brightLuminance: CGFloat = 0.62

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
        guard let cg = upright(image) else { return Analysis(face: nil) }
        let band = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width,
                                          height: max(1, Int(CGFloat(cg.height) * clockShare))))
        return Analysis(face: faces(in: cg),
                        topIsBright: band.map(luminance).map { $0 > brightLuminance } ?? false)
    }

    /// Average luminance of a picture, 0 to 1: drawn into a single pixel, which averages it.
    static func luminance(of cg: CGImage) -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
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
    /// is no face; otherwise enlarged until the face centre comes down to `target` — within
    /// `maxZoom`, and short of the face filling the frame — and moved to put it there, as far
    /// as the photo still covers every edge.
    static func placement(imageSize: CGSize, in box: CGSize, face: CGRect?,
                          target: Target) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: box) }
        let cover = max(box.width / imageSize.width, box.height / imageSize.height)
        let covered = CGSize(width: imageSize.width * cover, height: imageSize.height * cover)
        guard let face, face.midY > 0, face.height > 0 else {
            return CGRect(origin: CGPoint(x: (box.width - covered.width) / 2,
                                          y: (box.height - covered.height) / 2), size: covered)
        }
        // With the photo's top at the frame's top, the face centre sits at midY × height:
        // the zoom that makes that the target, unless the face would grow too big first.
        let wanted = target.faceCenterY / (face.midY * covered.height)
        let faceRoom = maxFaceShare * box.height / (face.height * covered.height)
        let zoom = max(1, min(wanted, maxZoom, faceRoom))
        let size = CGSize(width: covered.width * zoom, height: covered.height * zoom)
        let x = min(0, max(box.width - size.width, box.width / 2 - face.midX * size.width))
        let y = min(0, max(box.height - size.height, target.faceCenterY - face.midY * size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// A photo filling its frame, framed — and if need be enlarged — on the face.
struct FaceFramedPhoto: View {
    let image: UIImage
    let analysis: FaceFraming.Analysis
    let target: FaceFraming.Target

    var body: some View {
        GeometryReader { geo in
            let place = FaceFraming.placement(imageSize: image.size, in: geo.size,
                                              face: analysis.face, target: target)
            Image(uiImage: image)
                .resizable()
                .frame(width: place.width, height: place.height)
                .offset(x: place.minX, y: place.minY)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}
