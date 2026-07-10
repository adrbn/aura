import SwiftUI
import CryptoKit

// MARK: - Image Cache

final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL
    /// Permanent, non-evictable artwork store for downloaded/offline content.
    /// Lives in Application Support (unlike `diskCacheURL` which is in Caches and
    /// can be purged by iOS under storage pressure). One master image per coverArt id.
    private let offlineArtworkURL: URL

    /// Dedicated URLSession for image fetches — higher concurrency than default
    let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 12
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil // We use our own cache
        return URLSession(configuration: config)
    }()

    /// In-flight network fetches keyed by cache key — concurrent requests for the
    /// same artwork share a single download instead of hitting the server N times.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let inFlightLock = NSLock()

    /// Learned byte-signature of the server's built-in "no cover art" placeholder,
    /// per requested pixel size. Navidrome serves this generic image (a blue vinyl)
    /// for art that is missing OR not yet processed after a scan — so caching it
    /// would pin a freshly-added album to the placeholder forever. We learn the
    /// signature once per size by probing a cover id that cannot exist, then refuse
    /// to cache any response that matches it. See `fetchImage`.
    private var placeholderSignatures: [Int: String] = [:]
    private let placeholderLock = NSLock()
    /// A cover art id guaranteed to have no artwork, used to learn the server's
    /// placeholder image. Unknown ids make Navidrome return its default cover.
    private static let placeholderProbeId = "__aura_missing_art_probe__"

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    init() {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        diskCacheURL = paths[0].appendingPathComponent("musika_artwork")
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        offlineArtworkURL = support.appendingPathComponent("musika_offline_artwork")
        try? FileManager.default.createDirectory(at: offlineArtworkURL, withIntermediateDirectories: true)
        memoryCache.countLimit = 300
        memoryCache.totalCostLimit = 120 * 1024 * 1024
        migrateArtworkCacheIfNeeded()
    }

    /// One-time migration: flush the thumbnail disk cache once to purge entries that
    /// pinned freshly-added albums to Navidrome's "no art" placeholder (now prevented
    /// by placeholder detection in `fetchImage`). The permanent offline/downloaded
    /// masters live in a separate store (`offlineArtworkURL`) and are left untouched.
    private func migrateArtworkCacheIfNeeded() {
        let key = "artworkCacheVersion"
        guard UserDefaults.standard.integer(forKey: key) < 1 else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        UserDefaults.standard.set(1, forKey: key)
        AppLogger.shared.log("🔄 Artwork thumbnail cache flushed (purge placeholder-poisoned entries)")
    }

    // MARK: - Offline (permanent) artwork

    private func offlineFileURL(forCoverArt coverArt: String) -> URL {
        let hash = SHA256.hash(data: Data("offline_\(coverArt)".utf8)).compactMap { String(format: "%02x", $0) }.joined()
        return offlineArtworkURL.appendingPathComponent(hash)
    }

    private func offlineMemKey(_ coverArt: String) -> NSString { "offline_master_\(coverArt)" as NSString }

    func hasOfflineArtwork(forCoverArt coverArt: String) -> Bool {
        FileManager.default.fileExists(atPath: offlineFileURL(forCoverArt: coverArt).path)
    }

    /// Returns the permanently-stored master artwork for a coverArt id (any size). Offline-safe.
    func offlineArtwork(forCoverArt coverArt: String) -> UIImage? {
        let memKey = offlineMemKey(coverArt)
        if let img = memoryCache.object(forKey: memKey) { return img }
        let url = offlineFileURL(forCoverArt: coverArt)
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            memoryCache.setObject(img, forKey: memKey)
            return img
        }
        return nil
    }

    func storeOfflineArtwork(_ image: UIImage, forCoverArt coverArt: String) {
        memoryCache.setObject(image, forKey: offlineMemKey(coverArt))
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: offlineFileURL(forCoverArt: coverArt))
        }
    }

    func removeOfflineArtwork(forCoverArt coverArt: String) {
        memoryCache.removeObject(forKey: offlineMemKey(coverArt))
        try? FileManager.default.removeItem(at: offlineFileURL(forCoverArt: coverArt))
    }

    /// Download (if not already stored) and persist a permanent master artwork for offline use.
    func cacheOfflineArtwork(forCoverArt coverArt: String, server: ServerConfig) async {
        guard !hasOfflineArtwork(forCoverArt: coverArt) else { return }
        guard let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: 1200) else { return }
        do {
            let (data, _) = try await imageSession.data(from: url)
            if let img = UIImage(data: data) {
                storeOfflineArtwork(img, forCoverArt: coverArt)
                AppLogger.shared.log("🖼 Cached offline artwork for \(coverArt)")
            }
        } catch {
            AppLogger.shared.log("❌ Offline artwork cache failed for \(coverArt): \(error.localizedDescription)")
        }
    }

    /// Normalize pixel size to standard buckets so thumbnails share cache entries.
    /// Small sizes get bucketed; large sizes (cover art in NowPlaying) get a high-res bucket.
    static func normalizedSize(_ pixels: Int) -> Int {
        if pixels <= 100 { return 100 }
        if pixels <= 200 { return 200 }
        if pixels <= 400 { return 400 }
        if pixels <= 800 { return 800 }
        return 1200
    }

    func image(for key: String) -> UIImage? {
        let nsKey = key as NSString
        if let img = memoryCache.object(forKey: nsKey) { return img }
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let fileURL = diskCacheURL.appendingPathComponent(hash)
        if let data = try? Data(contentsOf: fileURL), let img = UIImage(data: data) {
            memoryCache.setObject(img, forKey: nsKey)
            return img
        }
        return nil
    }

    /// Best instant in-memory image at ANY already-cached normalized size for the
    /// same coverArt. Used as a progressive placeholder (shown upscaled) while the
    /// exact requested size loads, so a row never flashes the grey placeholder when
    /// a thumbnail of any size is already in memory. Memory-only — cheap enough to
    /// call from a SwiftUI view body during scrolling.
    func cachedImageAnySize(forCoverArt coverArt: String, cacheToken: String? = nil) -> UIImage? {
        // Prefer mid-sized buckets first (good quality, commonly warmed), then widen out.
        for size in [400, 200, 800, 100, 1200] {
            let key = cacheToken.map { "\(coverArt)_\($0)_\(size)" } ?? "\(coverArt)_\(size)"
            if let img = memoryCache.object(forKey: key as NSString) { return img }
        }
        // Permanent offline master (downloaded content) as the last in-memory resort.
        return memoryCache.object(forKey: offlineMemKey(coverArt))
    }

    func store(_ image: UIImage, for key: String) {
        let nsKey = key as NSString
        memoryCache.setObject(image, forKey: nsKey)
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let fileURL = diskCacheURL.appendingPathComponent(hash)
        Task.detached(priority: .utility) {
            if let data = image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Current disk cache size in bytes
    var currentCacheSizeBytes: Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Remove all cached images
    func clearAll() {
        memoryCache.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Deduplicated fetch & prefetch

    /// Resolve artwork: cache first, then network with in-flight deduplication.
    /// Offline mode and missing-server cases fall back to the permanent offline master.
    func fetchImage(coverArt: String, requestSize: Int, key: String) async -> UIImage? {
        if let cached = image(for: key) { return cached }
        if AppSettings.shared.offlineMode {
            return offlineArtwork(forCoverArt: coverArt)
        }
        inFlightLock.lock()
        if let existing = inFlight[key] {
            inFlightLock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            guard let server = ServerManager.shared.currentServer,
                  let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: requestSize) else {
                return self.offlineArtwork(forCoverArt: coverArt)
            }
            do {
                let (data, resp) = try await self.imageSession.data(from: url)
                guard let img = UIImage(data: data) else {
                    // A 404 / error body decodes as no image — log the details so missing
                    // art is diagnosable (this path was previously silent).
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    AppLogger.shared.log("❌ Cover art undecodable id=\(coverArt) http=\(code) bytes=\(data.count)")
                    return nil
                }
                // Freshly-scanned albums often return the server's generic "no art"
                // placeholder before Navidrome has processed the real cover. Caching it
                // would pin the album to the placeholder permanently: the thumbnail size
                // is fetched first (carousel), so it gets stuck, while the larger detail
                // size later fetches the real art. Detect the placeholder and skip caching
                // so the entry re-fetches — showing the app's own placeholder meanwhile.
                if let sig = await self.placeholderSignature(forSize: requestSize, server: server),
                   Self.sha256Hex(data) == sig {
                    AppLogger.shared.log("🕳 Cover art id=\(coverArt) matched server placeholder (size \(requestSize)) — not caching")
                    return nil
                }
                self.store(img, for: key)
                return img
            } catch {
                AppLogger.shared.log("❌ Cover art download failed id=\(coverArt): \(error.localizedDescription)")
                // Network failed mid-session — use the offline master as a fallback.
                return self.offlineArtwork(forCoverArt: coverArt)
            }
        }
        inFlight[key] = task
        inFlightLock.unlock()
        let result = await task.value
        inFlightLock.lock()
        inFlight[key] = nil
        inFlightLock.unlock()
        return result
    }

    /// Byte-signature of the server's placeholder image at `size`, learned once per
    /// size by probing a cover id that cannot exist. Returns nil if the server can't
    /// be probed (e.g. it 404s instead of serving a placeholder), in which case
    /// placeholder detection is simply skipped — no behavioral regression.
    private func placeholderSignature(forSize size: Int, server: ServerConfig) async -> String? {
        placeholderLock.lock()
        if let sig = placeholderSignatures[size] { placeholderLock.unlock(); return sig }
        placeholderLock.unlock()
        guard let url = SubsonicClient.shared.coverArtURL(server: server, id: Self.placeholderProbeId, size: size),
              let (data, _) = try? await imageSession.data(from: url),
              UIImage(data: data) != nil else { return nil }
        let sig = Self.sha256Hex(data)
        placeholderLock.lock(); placeholderSignatures[size] = sig; placeholderLock.unlock()
        return sig
    }

    /// Warm the cache for a list of cover art ids at a given point size so list
    /// thumbnails are already on disk/memory before their rows scroll into view.
    /// Skips cached entries; shares in-flight requests with on-screen views.
    /// `cacheToken` (e.g. a playlist's `changed` timestamp) must match what the
    /// displaying view passes to `CoverArtImage` so keys line up.
    func prefetch(_ items: [(coverArt: String, cacheToken: String?)], pointSize: CGFloat) {
        let requestSize = Self.normalizedSize(Int(pointSize * UIScreen.main.scale))
        // Dedupe while preserving order (nearest rows first)
        var seen = Set<String>()
        let unique = items.filter { seen.insert("\($0.coverArt)_\($0.cacheToken ?? "")").inserted }
        guard !unique.isEmpty else { return }
        Task.detached(priority: .utility) {
            guard !AppSettings.shared.offlineMode else { return }
            await withTaskGroup(of: Void.self) { group in
                for (i, item) in unique.enumerated() {
                    if i >= 4 { await group.next() } // sliding window of 4 concurrent fetches
                    group.addTask {
                        let key = item.cacheToken.map { "\(item.coverArt)_\($0)_\(requestSize)" }
                            ?? "\(item.coverArt)_\(requestSize)"
                        _ = await self.fetchImage(coverArt: item.coverArt, requestSize: requestSize, key: key)
                    }
                }
            }
        }
    }

    /// Convenience prefetch without cache tokens (songs, albums).
    func prefetch(coverArtIds: [String], pointSize: CGFloat) {
        prefetch(coverArtIds.map { ($0, nil) }, pointSize: pointSize)
    }

    /// Remove all cached images for a given cover art ID (all sizes)
    func removeImages(forCoverArt coverArt: String) {
        // Normalized thumbnail buckets + common exact retina sizes for large displays
        let sizes = [100, 200, 400, 780, 800, 840, 999, 1000, 1170, 1200]
        for size in sizes {
            let key = "\(coverArt)_\(size)"
            let nsKey = key as NSString
            memoryCache.removeObject(forKey: nsKey)
            let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
            let fileURL = diskCacheURL.appendingPathComponent(hash)
            try? FileManager.default.removeItem(at: fileURL)
        }
        // Also remove background key
        let bgKey = "\(coverArt)_bg" as NSString
        memoryCache.removeObject(forKey: bgKey)
        let bgHash = SHA256.hash(data: Data("\(coverArt)_bg".utf8)).compactMap { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: diskCacheURL.appendingPathComponent(bgHash))
    }
}

// MARK: - Cached Image Loader

struct CoverArtImage: View {
    let coverArt: String?
    var size: CGFloat = 50
    var cornerRadius: CGFloat = 8
    /// Optional cache-busting token (e.g. a playlist's `changed` timestamp).
    /// When it changes, the image is re-fetched once and re-cached — without
    /// nuking the whole artwork cache.
    var cacheToken: String? = nil
    /// Secondary id tried when the primary `coverArt` has no art on the server
    /// (e.g. a song with no track-level art falls back to its album cover).
    var fallbackCoverArt: String? = nil
    /// When set, the missing-art placeholder is a templated gradient seeded by
    /// this string (usually the item's name) instead of a grey box.
    var placeholderName: String? = nil
    var placeholderKind: PlaceholderCoverView.Kind = .generic

    @State private var image: UIImage?

    private var requestSize: Int {
        ArtworkCache.normalizedSize(Int(size * UIScreen.main.scale))
    }

    private var cacheKey: String? {
        guard let coverArt = coverArt else { return nil }
        if let cacheToken { return "\(coverArt)_\(cacheToken)_\(requestSize)" }
        return "\(coverArt)_\(requestSize)"
    }

    /// Resolve image synchronously from cache to avoid placeholder flash
    private var resolvedImage: UIImage? {
        if let image { return image }
        guard let coverArt, let key = cacheKey else { return nil }
        if let exact = ArtworkCache.shared.image(for: key) { return exact }
        // Progressive: reuse any already-cached size (upscaled) until the exact one arrives.
        if let any = ArtworkCache.shared.cachedImageAnySize(forCoverArt: coverArt, cacheToken: cacheToken) { return any }
        if let fb = fallbackCoverArt { return ArtworkCache.shared.cachedImageAnySize(forCoverArt: fb, cacheToken: cacheToken) }
        return nil
    }

    var body: some View {
        Group {
            if let img = resolvedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear {
            if image == nil, let key = cacheKey, let cached = ArtworkCache.shared.image(for: key) {
                image = cached
            }
        }
        .task(id: cacheKey) { await loadCached() }
    }

    private func loadCached() async {
        guard let coverArt = coverArt, let key = cacheKey else { return }
        // No early return on image != nil: the task id (cacheKey) changing means the
        // cover or its token changed, and a cache hit is near-free anyway.
        if let result = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: requestSize, key: key) {
            await MainActor.run { self.image = result }
        } else if let fb = fallbackCoverArt, fb != coverArt {
            // Primary id had no art — try the album cover.
            let fbKey = cacheToken.map { "\(fb)_\($0)_\(requestSize)" } ?? "\(fb)_\(requestSize)"
            if let result = await ArtworkCache.shared.fetchImage(coverArt: fb, requestSize: requestSize, key: fbKey) {
                await MainActor.run { self.image = result }
            }
        }
    }

    private var placeholderView: some View {
        PlaceholderCoverView(seed: placeholderName ?? coverArt ?? "music",
                             kind: placeholderKind, size: size, cornerRadius: cornerRadius)
    }
}

struct CoverArtAsyncImage: View {
    let coverArt: String?
    var size: CGFloat = 300
    /// Secondary id tried when `coverArt` has no art on the server.
    var fallbackCoverArt: String? = nil
    /// When set, the missing-art placeholder is a templated gradient seeded by
    /// this string (usually the item's name) instead of a grey box.
    var placeholderName: String? = nil
    var placeholderKind: PlaceholderCoverView.Kind = .generic

    @State private var image: UIImage?
    /// Track the coverArt we loaded so we can detect changes without re-flashing
    @State private var loadedCoverArt: String?

    /// Large display images — always request at least 1200px for consistent high quality
    private var requestSize: Int {
        max(1200, Int(size * UIScreen.main.scale))
    }

    private func cacheKey(for id: String) -> String {
        "\(id)_\(requestSize)"
    }

    /// Try to resolve image from cache immediately (avoids placeholder flash)
    private var resolvedImage: UIImage? {
        if let image { return image }
        guard let coverArt else { return nil }
        if let exact = ArtworkCache.shared.image(for: cacheKey(for: coverArt)) { return exact }
        // Progressive: a small list thumbnail (any cached size) shows instantly,
        // upscaled, until the high-res hero image finishes loading.
        if let any = ArtworkCache.shared.cachedImageAnySize(forCoverArt: coverArt) { return any }
        if let fb = fallbackCoverArt { return ArtworkCache.shared.cachedImageAnySize(forCoverArt: fb) }
        return nil
    }

    var body: some View {
        Group {
            if let img = resolvedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                PlaceholderCoverView(seed: placeholderName ?? coverArt ?? "music",
                                     kind: placeholderKind, size: size, cornerRadius: 12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { loadFromCacheSync() }
        .task(id: coverArt) { await loadImage() }
    }

    /// Load from memory/disk cache synchronously to avoid placeholder flash on re-appear
    private func loadFromCacheSync() {
        guard image == nil || loadedCoverArt != coverArt,
              let coverArt else { return }
        let key = cacheKey(for: coverArt)
        if let cached = ArtworkCache.shared.image(for: key) {
            image = cached
            loadedCoverArt = coverArt
        }
    }

    private func loadImage() async {
        guard let coverArt else { return }
        let key = cacheKey(for: coverArt)
        // If coverArt changed, try cache first before clearing
        if loadedCoverArt != coverArt {
            if let cached = ArtworkCache.shared.image(for: key) {
                await MainActor.run {
                    self.image = cached
                    self.loadedCoverArt = coverArt
                }
                return
            }
        }
        // Already loaded for this coverArt
        if image != nil && loadedCoverArt == coverArt { return }
        if let result = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: requestSize, key: key) {
            await MainActor.run {
                self.image = result
                self.loadedCoverArt = coverArt
            }
        } else if let fb = fallbackCoverArt, fb != coverArt {
            // Primary id had no art — try the album cover.
            let fbKey = cacheKey(for: fb)
            if let result = await ArtworkCache.shared.fetchImage(coverArt: fb, requestSize: requestSize, key: fbKey) {
                await MainActor.run {
                    self.image = result
                    self.loadedCoverArt = coverArt
                }
            }
        }
    }
}

extension SubsonicClient {
    nonisolated func coverArtURL(server: ServerConfig, id: String, size: Int = 300) -> URL? {
        let urlString = "\(server.baseURL)/rest/getCoverArt?\(SubsonicClient.authQuery(for: server))&id=\(id)&size=\(size)"
        return URL(string: urlString)
    }

    nonisolated func streamURL(server: ServerConfig, id: String, maxBitRate: Int? = nil, songSuffix: String? = nil, songContentType: String? = nil) -> URL? {
        var urlString = "\(server.baseURL)/rest/stream?\(SubsonicClient.authQuery(for: server))&id=\(id)"

        let suffix = songSuffix?.lowercased() ?? ""
        let contentType = songContentType?.lowercased() ?? ""
        let quality = AppSettings.shared.streamingQuality

        let lossySuffixes: Set<String> = ["mp3", "m4a", "aac", "mp4", "m4b", "opus", "ogg"]
        let lossyContentTypes = ["audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/opus", "audio/ogg"]

        var isLossy = false
        if !suffix.isEmpty {
            isLossy = lossySuffixes.contains(suffix)
        } else if !contentType.isEmpty {
            isLossy = lossyContentTypes.contains { contentType.contains($0) }
        }

        AppLogger.shared.log("🎚 streamURL id=\(id) suffix=\(suffix.isEmpty ? "n/a" : suffix) isLossy=\(isLossy) quality=\(quality.rawValue)")

        if isLossy {
            // Opus/OGG are lossy but iOS can't play them — must transcode
            let unsupportedLossySuffixes: Set<String> = ["ogg", "opus"]
            if unsupportedLossySuffixes.contains(suffix) {
                let br = quality.bitRate ?? 320
                urlString += "&format=mp3&maxBitRate=\(br)"
            }
            // Other lossy formats (mp3, m4a, aac) — never downsample
        } else {
            // Lossless file (FLAC, ALAC, etc.)
            if quality == .lossless {
                // Stream original — format=raw avoids server's default OGG transcoding
                urlString += "&format=raw"
            } else {
                // Transcode to MP3 at the selected quality
                let br = quality.bitRate ?? 320
                urlString += "&format=mp3&maxBitRate=\(br)"
            }
        }

        return URL(string: urlString)
    }

    nonisolated func downloadURL(server: ServerConfig, id: String) -> URL? {
        let urlString = "\(server.baseURL)/rest/download?\(SubsonicClient.authQuery(for: server))&id=\(id)"
        return URL(string: urlString)
    }
}
