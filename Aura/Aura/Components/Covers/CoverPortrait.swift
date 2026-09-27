import SwiftUI
import UIKit
import Vision
import CoreImage
import os

/// An artist's photograph, read for a cover: where the face is, where the head starts, the
/// person cut out, and the colours the photo can lend the cover.
final class CoverPortrait: @unchecked Sendable {
    let artistId: String
    /// Upright pixels — any EXIF rotation is already applied.
    let image: UIImage
    /// All the faces together, normalised with a top-left origin. Nil: no face to frame on.
    let face: CGRect?
    /// The person cut out, transparent elsewhere. Only analysed when a template asked for it.
    let subject: UIImage?
    /// Top of the person, as a fraction of the height; near 0 when the photo cuts the head.
    let headTop: CGFloat
    /// Average colour of the photo's top strip, to extend its backdrop upwards.
    let topColor: UIColor
    /// A band colour matched to the photo; nil for a neutral photo.
    let band: UIColor?

    init(artistId: String, image: UIImage, face: CGRect?, subject: UIImage?, headTop: CGFloat,
         topColor: UIColor, band: UIColor?) {
        self.artistId = artistId
        self.image = image
        self.face = face
        self.subject = subject
        self.headTop = headTop
        self.topColor = topColor
        self.band = band
    }
}

/// Photographs for covers — an artist's, or an album cover standing in — read with Vision
/// once per picture per launch.
enum CoverPortraits {
    private static let cache: NSCache<NSString, CoverPortrait> = {
        let cache = NSCache<NSString, CoverPortrait>()
        cache.countLimit = 48
        return cache
    }()
    /// Reads under way, so two covers leading with the same artist share one.
    private static let inFlight = OSAllocatedUnfairLock(initialState: [String: Task<CoverPortrait?, Never>]())
    private static let context = CIContext()

    static func cached(_ key: String, subject: Bool) -> CoverPortrait? {
        guard let hit = cache.object(forKey: key as NSString) else { return nil }
        return !subject || hit.subject != nil ? hit : nil
    }

    /// The first of `artists` that has a photo, analysed.
    static func first(of artists: [ArtistRef], subject: Bool) async -> CoverPortrait? {
        for artist in artists {
            if Task.isCancelled { return nil }
            if let portrait = await load(artist, subject: subject) { return portrait }
        }
        return nil
    }

    static func load(_ artist: ArtistRef, subject: Bool) async -> CoverPortrait? {
        await read(key: artist.id, subject: subject) {
            await ArtistPhotos.image(for: artist.name)
        }
    }

    /// An album cover, for when the catalogue has no photo of the artist.
    static func album(_ coverArt: String, subject: Bool) async -> CoverPortrait? {
        await read(key: "album:\(coverArt)", subject: subject) {
            let size = ArtworkCache.fullSize
            return await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: size,
                                                        key: "\(coverArt)_\(size)")
        }
    }

    private static func read(key: String, subject: Bool,
                             image: @escaping @Sendable () async -> UIImage?) async -> CoverPortrait? {
        if let hit = cached(key, subject: subject) { return hit }
        let flightKey = "\(key)|\(subject)"
        let task = inFlight.withLock { tasks -> Task<CoverPortrait?, Never> in
            if let running = tasks[flightKey] { return running }
            let task = Task<CoverPortrait?, Never> {
                guard let picture = await image() else { return nil }
                let portrait = await Task.detached(priority: .utility) {
                    analyse(picture, artistId: key, subject: subject)
                }.value
                if let portrait { cache.setObject(portrait, forKey: key as NSString) }
                return portrait
            }
            tasks[flightKey] = task
            return task
        }
        let portrait = await task.value
        inFlight.withLock { _ = $0.removeValue(forKey: flightKey) }
        return portrait
    }

    private static func analyse(_ image: UIImage, artistId: String, subject wantsSubject: Bool) -> CoverPortrait? {
        guard let cg = FaceFraming.upright(image) else { return nil }
        let face = FaceFraming.faces(in: cg)
        let cut = wantsSubject ? cutout(cg) : nil
        // Without a cut-out, the head starts roughly half a face above the face box.
        let estimatedTop = face.map { max(0, $0.minY - $0.height * 0.45) } ?? 0.1
        return CoverPortrait(artistId: artistId,
                             image: UIImage(cgImage: cg, scale: image.scale, orientation: .up),
                             face: face,
                             subject: cut?.image,
                             headTop: cut?.headTop ?? estimatedTop,
                             topColor: CoverImaging.average(of: cg, from: 0, to: 0.04),
                             band: CoverPalette.band(in: cg))
    }

    /// The person cut out of the photo, and the row where the top of their head is.
    private static func cutout(_ cg: CGImage) -> (image: UIImage, headTop: CGFloat)? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
        } catch {
            AppLogger.shared.log("⚠️ Person segmentation failed: \(error.localizedDescription)", level: .debug)
            return nil
        }
        guard let mask = request.results?.first?.pixelBuffer,
              let headTop = firstOpaqueRow(mask) else { return nil }

        let source = CIImage(cgImage: cg)
        let scaledMask = CIImage(cvPixelBuffer: mask).transformed(by: CGAffineTransform(
            scaleX: source.extent.width / CGFloat(CVPixelBufferGetWidth(mask)),
            y: source.extent.height / CGFloat(CVPixelBufferGetHeight(mask))))
        let cut = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: scaledMask])
        guard let out = context.createCGImage(cut, from: source.extent) else { return nil }
        return (UIImage(cgImage: out), headTop)
    }

    /// First mask row with a person in it, as a fraction of the height; nil when empty.
    private static func firstOpaqueRow(_ mask: CVPixelBuffer) -> CGFloat? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        for y in 0..<height where (0..<width).contains(where: { base[y * stride + $0] > 128 }) {
            return CGFloat(y) / CGFloat(height)
        }
        return nil
    }
}

// MARK: - Framing

/// Where a photo goes in a box: scaled to fill it (times `zoom`) and slid so the face centre
/// lands on `target` (fractions of the box). The photo always covers the sides and the
/// bottom; the top may open by at most `maxTopGap` of the box height, filled by the caller.
struct CoverFraming {
    let size: CGSize
    let origin: CGPoint

    init(_ p: CoverPortrait, box: CGSize, target: CGPoint, zoom: CGFloat = 1, maxTopGap: CGFloat = 0) {
        let px = p.image.size
        let fill = max(box.width / max(1, px.width), box.height / max(1, px.height)) * zoom
        let d = CGSize(width: px.width * fill, height: px.height * fill)
        let f = p.face ?? CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.2)
        let x = target.x * box.width - f.midX * d.width
        let y = target.y * box.height - f.midY * d.height
        size = d
        origin = CGPoint(x: min(0, max(box.width - d.width, x)),
                         y: min(maxTopGap * box.height, max(box.height - d.height, y)))
    }
}

struct FramedPortrait: View {
    let image: UIImage
    let framing: CoverFraming
    let box: CGSize
    /// Fills any headroom the framing opened above the photo, with a feathered seam.
    var backdrop: Color? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let backdrop { backdrop }
            Image(uiImage: image)
                .resizable()
                .frame(width: framing.size.width, height: framing.size.height)
                .mask {
                    if backdrop != nil && framing.origin.y > 0 {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black, location: 0.06)],
                                       startPoint: .top, endPoint: .bottom)
                    } else {
                        Rectangle()
                    }
                }
                .offset(x: framing.origin.x, y: framing.origin.y)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - Source

/// Artist photographs from Deezer's key-less catalogue, kept in the artwork cache.
///
/// Not from the server: Navidrome answers `ar-<id>` by looking the artist up on its agents
/// and downloading the picture there and then, behind a two-worker artwork pool. A shelf of
/// covers asking for a dozen artists at once queued there past the request timeout, and
/// held every album cover in the app behind them. Deezer's CDN answers in a fraction of a
/// second, and a picture fetched once is on disk for good.
enum ArtistPhotos {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    /// Where Deezer redirects a picture it doesn't have: its grey silhouette, filed under the
    /// MD5 of an empty string. Artists without a photo still list a hash that lands here.
    private static let silhouette = "d41d8cd98f00b204e9800998ecf8427e"
    /// Photos download three at a time; the lookups before them go through their own lane of
    /// `DeezerPacer`, beside the radar's, the two under Deezer's 50 calls per 5 seconds.
    private static let gate = DownloadGate(limit: 3)
    /// Names Deezer answered for without a matching artist that has a picture. Failed calls
    /// are not remembered: a timeout says nothing about the artist.
    private static let unknown = OSAllocatedUnfairLock(initialState: Set<String>())

    private struct Search: Decodable {
        struct Hit: Decodable {
            let name: String
            let picture_xl: String?
        }
        let data: [Hit]?
    }

    private enum Lookup {
        case found(URL)
        case none
        case failed
    }

    static func image(for name: String) async -> UIImage? {
        let folded = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !folded.isEmpty else { return nil }
        // "v2": the first build cached the silhouette as a photo under the old key.
        let key = "dz_artist_v2_\(folded)"
        if let hit = ArtworkCache.shared.image(for: key) { return hit }
        if unknown.withLock({ $0.contains(folded) }) { return nil }

        await gate.acquire()
        defer { gate.release() }
        switch await lookup(name) {
        case .failed:
            return nil
        case .none:
            unknown.withLock { _ = $0.insert(folded) }
            return nil
        case .found(let url):
            do {
                let (data, response) = try await session.data(from: url)
                if response.url?.absoluteString.contains(silhouette) == true {
                    unknown.withLock { _ = $0.insert(folded) }
                    return nil
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                    return nil
                }
                ArtworkCache.shared.store(image, for: key)
                return image
            } catch {
                AppLogger.shared.log("⚠️ Artist photo download failed for \(name): \(error.localizedDescription)",
                                     level: .debug)
                return nil
            }
        }
    }

    private static func lookup(_ name: String) async -> Lookup {
        var components = URLComponents(string: "https://api.deezer.com/search/artist")
        components?.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "5")]
        guard let url = components?.url else { return .failed }
        await DeezerPacer.photos.wait()
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let hits = try JSONDecoder().decode(Search.self, from: data).data else {
                // Over quota, Deezer answers 200 with an error object and no `data`.
                return .failed
            }
            // An artist without a photo lists an empty hash (".../artist//1000x1000-…") or the
            // silhouette's own.
            let match = hits.first { hit in
                SongQuery.isExactArtist(hit.name, query: name)
                    && hit.picture_xl.map { !$0.contains("/artist//") && !$0.contains(silhouette) } == true
            }
            guard let picture = match?.picture_xl, let pictureURL = URL(string: picture) else { return .none }
            return .found(pictureURL)
        } catch {
            AppLogger.shared.log("⚠️ Artist photo lookup failed for \(name): \(error.localizedDescription)",
                                 level: .debug)
            return .failed
        }
    }
}
