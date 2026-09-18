import SwiftUI
import CryptoKit

// MARK: - Image Cache

/// Counting semaphore for async callers.
///
/// Lock-based rather than an actor so `release()` is synchronous and safe to call from a
/// `defer` — an actor would force `await` there, which `defer` can't express.
final class DownloadGate: @unchecked Sendable {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        lock.lock()
        if active < limit {
            active += 1
            lock.unlock()
            return
        }
        // The continuation body runs synchronously, so unlocking inside it is safe and
        // closes the race where a release could land between append and unlock.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            active -= 1
            lock.unlock()
            return
        }
        // Hand the slot straight to the next waiter — `active` stays put.
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }
}

/// "Try the artwork again" signal.
///
/// A cover that fails to load is deliberately NOT cached as a failure, so a fresh fetch
/// would succeed — but nothing ever asked for one. Both cover views key their
/// `.task(id:)` on the cover id, which doesn't change when connectivity returns, and the
/// view stays alive in the scroll hierarchy, so the task never re-runs.
///
/// Views watch this counter in their task id. Ones still showing a placeholder refetch;
/// ones that already resolved return immediately, so a bump doesn't re-download the screen.
@Observable
final class ArtworkRetry {
    static let shared = ArtworkRetry()
    private(set) var generation = 0
    /// Call on the main actor when the app regains a usable connection.
    func requestRetry() {
        generation += 1
        // "This album has no art" was a verdict about a server we may not have been
        // reaching properly. Ask again rather than carry it across a reconnection.
        ArtworkCache.shared.forgetMissingArtwork()
    }
}

final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let diskCacheURL: URL
    /// Permanent, non-evictable artwork store for downloaded/offline content.
    /// Lives in Application Support (unlike `diskCacheURL` which is in Caches and
    /// can be purged by iOS under storage pressure). One master image per coverArt id.
    private let offlineArtworkURL: URL

    /// Dedicated URLSession for image fetches.
    ///
    /// Left at stock settings on purpose. The placeholder bug turned out to be the server
    /// answering 429 to every artwork request, not a transport problem — `maxConcurrentDownloads`
    /// below is the fix. Re-tuning timeouts here would only mask a saturated server again.
    let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 12
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        config.urlCache = nil // We use our own cache
        return URLSession(configuration: config)
    }()

    /// Ceiling on simultaneous artwork downloads.
    ///
    /// Set to 2 while the server was answering 429 to everything — its artwork workers were
    /// wedged and any parallelism made it worse. That server is healthy again, and 2 is now
    /// the bottleneck instead of the cure: a screen of 20 covers becomes 10 sequential
    /// round-trips, and over a relayed connection each one costs real latency.
    ///
    /// If 429s ever come back in the server log, this is the first number to lower.
    static let maxConcurrentDownloads = 5
    private let downloadGate = DownloadGate(limit: ArtworkCache.maxConcurrentDownloads)

    /// True when artwork must come from local storage only: the user asked for offline
    /// mode AND the server really is out of reach. Offline mode on its own is not enough —
    /// see the note in `fetchImage`.
    var isArtworkOffline: Bool {
        AppSettings.shared.offlineMode
            && (!ServerManager.shared.hasNetwork || !ServerManager.shared.isConnected)
    }

    /// In-flight network fetches keyed by cache key — concurrent requests for the
    /// same artwork share a single download instead of hitting the server N times.
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private let inFlightLock = NSLock()

    /// Learned byte-signature of the server's built-in "no cover art" placeholder,
    /// per requested pixel size. Navidrome serves this generic image (a blue vinyl)
    /// for art that is missing OR not yet processed after a scan — so caching it
    /// would pin a freshly-added album to the placeholder forever. We learn the
    /// signature once per size by probing a cover id that cannot exist, then refuse
    /// to cache any response that matches it. See `fetchImage`.
    private var placeholderSignatures: [Int: String] = [:]
    /// Sizes whose probe has already been attempted — success OR failure.
    ///
    /// Only successes used to be remembered. This server answers an unknown cover id with
    /// a JSON error rather than a placeholder image, so the probe never succeeded, nothing
    /// was ever memoized, and every single cover fetch fired its own fresh probe — inside
    /// the download gate, doubling the load on the exact endpoint already under strain.
    private var probedSizes: Set<Int> = []
    private let placeholderLock = NSLock()
    /// A cover art id guaranteed to have no artwork, used to learn the server's
    /// placeholder image. Unknown ids make Navidrome return its default cover.
    private static let placeholderProbeId = "__aura_missing_art_probe__"

    /// Byte-hash of what each cover id returned, per size bucket — the raw material for
    /// the size-invariance test in `classifyArtwork`. Two buckets exist (`thumbSize`,
    /// `fullSize`), so this holds at most two entries per cover seen.
    private var seenArtworkHashes: [String: String] = [:]
    /// Hashes proven to be the server's one generic "no cover art" image.
    private var placeholderHashes: Set<String> = []
    /// Covers already shown to resolve to it. Re-asking costs a full round trip — on this
    /// library about ten seconds each, because the server goes out to Last.fm before
    /// giving up — and the answer cannot change until the library is rescanned.
    private var missingArtCovers: Set<String> = []

    /// Roughly what an image occupies once decoded: four bytes a pixel. Artwork is built
    /// with `PlatformImage(data:)`, whose `size` is already in pixels.
    private static func decodedByteCost(_ image: PlatformImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

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
        guard UserDefaults.standard.integer(forKey: key) < 2 else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        UserDefaults.standard.set(2, forKey: key)
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
    func offlineArtwork(forCoverArt coverArt: String) -> PlatformImage? {
        let memKey = offlineMemKey(coverArt)
        if let img = memoryCache.object(forKey: memKey) { return img }
        let url = offlineFileURL(forCoverArt: coverArt)
        if let data = try? Data(contentsOf: url), let img = PlatformImage(data: data) {
            memoryCache.setObject(img, forKey: memKey)
            return img
        }
        return nil
    }

    func storeOfflineArtwork(_ image: PlatformImage, forCoverArt coverArt: String) {
        memoryCache.setObject(image, forKey: offlineMemKey(coverArt))
        if let data = image.auraJPEGData(quality: 0.9) {
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
        guard let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: ArtworkCache.fullSize) else { return }
        do {
            let (data, _) = try await imageSession.data(from: url)
            if let img = PlatformImage(data: data) {
                storeOfflineArtwork(img, forCoverArt: coverArt)
                AppLogger.shared.log("🖼 Cached offline artwork for \(coverArt)")
            }
        } catch {
            AppLogger.shared.log("❌ Offline artwork cache failed for \(coverArt): \(error.localizedDescription)")
        }
    }

    /// Normalize pixel size to standard buckets so views of similar size share cache
    /// entries instead of each fetching its own resize.
    /// Small bucket: list rows, artist circles, blurred backdrops.
    static let thumbSize = 300
    /// Middle bucket: album-grid cards and anything else around a third of the screen.
    static let fullSize = 800
    /// Hero bucket: Now Playing, artist and album headers, the full-screen viewer.
    ///
    /// These render edge to edge. On a 3x phone that is 1200 physical pixels and more, so
    /// the 800 they used to share with grid cards was being stretched by half again —
    /// visibly soft on artwork the library holds at 3000px. Clears the widest iPhone
    /// full-screen (1320) with room to spare.
    static let heroSize = 1400

    /// TWO buckets, deliberately.
    ///
    /// Navidrome resizes on demand and caches per (id, size), so every extra bucket is a
    /// separate server-side resize that shares nothing with the others. Aura used to ask
    /// for the same cover at 100/200/300/400/600/800/1200 — up to five resizes for one
    /// image. Against an artwork pool of ~2 workers that saturated the queue and the
    /// server answered 429 to everything, including its own web UI.
    ///
    /// The 400 px split keeps list rows (≈180 px @3x) on the small bucket while album
    /// cards (≈480 px @3x) land on the large one, so cards stay sharp and share their
    /// resize with the heroes.
    static func normalizedSize(_ pixels: Int) -> Int {
        if pixels <= 400 { return thumbSize }
        if pixels <= 900 { return fullSize }
        return heroSize
    }

    /// THE bucket a `CoverArtAsyncImage` of `pointSize` will ask for. Single source of
    /// truth: prefetching and displaying MUST derive the key the same way or the warm
    /// entry lands in a different bucket and the prefetch silently does nothing.
    static func displayRequestSize(pointSize: CGFloat) -> Int {
        normalizedSize(Int(pointSize * PlatformScreen.scale))
    }

    func image(for key: String) -> PlatformImage? {
        let nsKey = key as NSString
        if let img = memoryCache.object(forKey: nsKey) { return img }
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let fileURL = diskCacheURL.appendingPathComponent(hash)
        if let data = try? Data(contentsOf: fileURL), let img = PlatformImage(data: data) {
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
    func cachedImageAnySize(forCoverArt coverArt: String, cacheToken: String? = nil) -> PlatformImage? {
        // Sharpest first, so a hero waiting on its own fetch borrows the best already in
        // hand rather than the smallest. These are THE buckets: the list this walked
        // before (400, 200, 100, 1200) named four sizes nothing ever stored and left out
        // the thumbnail every list row warms, so it almost never found anything.
        for size in [Self.heroSize, Self.fullSize, Self.thumbSize] {
            let key = cacheToken.map { "\(coverArt)_\($0)_\(size)" } ?? "\(coverArt)_\(size)"
            if let img = memoryCache.object(forKey: key as NSString) { return img }
        }
        // Permanent offline master (downloaded content) as the last in-memory resort.
        return memoryCache.object(forKey: offlineMemKey(coverArt))
    }

    func store(_ image: PlatformImage, for key: String) {
        let nsKey = key as NSString
        // With no cost, `totalCostLimit` was dead and `countLimit` alone governed: 300
        // images of whatever size, which at hero resolution is gigabytes. Decoded bytes
        // are what they actually occupy.
        memoryCache.setObject(image, forKey: nsKey, cost: Self.decodedByteCost(image))
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let fileURL = diskCacheURL.appendingPathComponent(hash)
        Task.detached(priority: .utility) {
            // 0.85 is fine for a 300px row and wasteful of a 1400px hero, where the
            // artefacts land on exactly the detail the larger fetch went to get.
            let quality: CGFloat = image.size.width >= 1000 ? 0.94 : 0.85
            if let data = image.auraJPEGData(quality: quality) {
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
    func fetchImage(coverArt: String, requestSize: Int, key: String) async -> PlatformImage? {
        if let cached = image(for: key) { return cached }
        // Already established that the server has nothing for this one. Asking again would
        // hold a download slot for seconds and come back with the same generic picture.
        if hasNoArtwork(coverArt) { return nil }
        // Fall back to the downloaded-only master ONLY when the server is genuinely out
        // of reach. Gating on `offlineMode` alone produced the worst possible state: every
        // JSON call (albums, favourites, songs) still went to the server and succeeded, so
        // Home filled with real content — while every single cover stayed a placeholder,
        // because artwork alone refused a network the rest of the app was already using.
        // Artwork now follows the same rule as the metadata beside it.
        if isArtworkOffline {
            let local = offlineArtwork(forCoverArt: coverArt)
            if local == nil {
                // Never let this path be silent again: its silence is exactly why a
                // screenful of placeholders produced zero diagnostic output.
                AppLogger.shared.log("🖼 Offline: no local artwork for \(coverArt)", level: .debug)
            }
            return local
        }
        inFlightLock.lock()
        if let existing = inFlight[key] {
            inFlightLock.unlock()
            return await existing.value
        }
        let task = Task<PlatformImage?, Never> {
            guard let server = ServerManager.shared.currentServer,
                  let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: requestSize) else {
                return self.offlineArtwork(forCoverArt: coverArt)
            }
            // Navidrome serves artwork from a worker pool sized off CPU count (2 on this
            // 4-CPU box) behind a bounded queue. 147 parallel covers overran that queue and
            // it answered 429 to EVERYTHING — including Navidrome's own web UI. Fewer
            // requests in flight is strictly faster: the queue drains instead of overflowing.
            await self.downloadGate.acquire()
            defer { self.downloadGate.release() }
            do {
                let (data, resp) = try await self.imageSession.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode == 429 {
                    // Throttled, not missing. Nothing is cached, so the next appearance or
                    // an ArtworkRetry bump refetches instead of pinning a placeholder.
                    AppLogger.shared.log("⏳ Cover art throttled 429 id=\(coverArt)", level: .debug)
                    return nil
                }
                guard let img = PlatformImage(data: data) else {
                    // A 404 / error body decodes as no image — log the details so missing
                    // art is diagnosable (this path was previously silent).
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    AppLogger.shared.log("❌ Cover art undecodable id=\(coverArt) http=\(code) bytes=\(data.count)")
                    return nil
                }
                // An album with no cover art does not come back empty: the server answers
                // with its own generic image — a vinyl record with the server's name
                // printed on it. Showing that would put another product's branding in the
                // middle of Aura, and inconsistently, since it only ever reached some of
                // the screens. Aura draws its own placeholder for missing art instead.
                let verdict = self.classifyArtwork(data: data, coverArt: coverArt, size: requestSize)
                if verdict.generic {
                    // Whatever we cached from this same image was that generic picture too.
                    for id in verdict.purge { self.removeImages(forCoverArt: id) }
                    AppLogger.shared.log("🕳 Cover art id=\(coverArt): the server has none — using Aura's placeholder")
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

    /// Whether `coverArt` is already known to have no artwork on the server.
    private func hasNoArtwork(_ coverArt: String) -> Bool {
        placeholderLock.lock(); defer { placeholderLock.unlock() }
        return missingArtCovers.contains(coverArt)
    }

    /// Forget every "no artwork" verdict, so the next appearance asks the server again.
    func forgetMissingArtwork() {
        placeholderLock.lock(); defer { placeholderLock.unlock() }
        missingArtCovers.removeAll()
    }

    /// Decides whether a downloaded image is this album's cover or the server's generic
    /// "no cover art" fallback, and returns the covers whose cached copies that verdict
    /// has just invalidated.
    ///
    /// The test is size invariance. A server resizes real artwork, so one album's cover
    /// cannot come back byte-for-byte identical in the thumbnail bucket and the full-size
    /// one. The fallback can: it is a single fixed file, served whatever size is asked
    /// for. Two covers legitimately sharing an image (a single and its album, a deluxe
    /// edition) share it at every size equally and so never trip this — the match has to
    /// be the SAME cover id at two different sizes.
    ///
    /// This replaces probing a made-up cover id, which only ever worked on servers that
    /// answer an unknown id with the fallback image; Navidrome answers it with an XML
    /// error, so that probe learned nothing here and the check silently did nothing. The
    /// probe's answer is still honoured where it does work. Neither costs a request.
    private func classifyArtwork(data: Data, coverArt: String, size: Int) -> (generic: Bool, purge: [String]) {
        let hash = Self.sha256Hex(data)
        placeholderLock.lock(); defer { placeholderLock.unlock() }

        if let probed = placeholderSignatures[size], probed == hash {
            placeholderHashes.insert(hash)
        }
        if placeholderHashes.contains(hash) {
            missingArtCovers.insert(coverArt)
            return (true, [])
        }

        let key = "\(coverArt)#\(size)"
        let sameCoverOtherSize = seenArtworkHashes.contains { seen, seenHash in
            seenHash == hash && seen != key && seen.hasPrefix("\(coverArt)#")
        }
        guard sameCoverOtherSize else {
            // Two buckets per cover, so this cannot run away; the ceiling is a safety net
            // for a server that somehow varies its output.
            if seenArtworkHashes.count < 4000 { seenArtworkHashes[key] = hash }
            return (false, [])
        }

        placeholderHashes.insert(hash)
        // Every cover that ever returned these bytes was this same generic image.
        let affected = Set(seenArtworkHashes.filter { $0.value == hash }
            .keys.compactMap { $0.split(separator: "#").first.map(String.init) })
        seenArtworkHashes = seenArtworkHashes.filter { $0.value != hash }
        missingArtCovers.formUnion(affected)
        missingArtCovers.insert(coverArt)
        return (true, Array(affected))
    }

    private func placeholderSignature(forSize size: Int, server: ServerConfig) async -> String? {
        placeholderLock.lock()
        if let sig = placeholderSignatures[size] { placeholderLock.unlock(); return sig }
        // Attempted once per size and never again: a server that can't be probed must cost
        // one wasted request in total, not one per cover.
        if probedSizes.contains(size) { placeholderLock.unlock(); return nil }
        probedSizes.insert(size)
        placeholderLock.unlock()
        guard let url = SubsonicClient.shared.coverArtURL(server: server, id: Self.placeholderProbeId, size: size),
              let (data, _) = try? await imageSession.data(from: url),
              PlatformImage(data: data) != nil else { return nil }
        let sig = Self.sha256Hex(data)
        placeholderLock.lock(); placeholderSignatures[size] = sig; placeholderLock.unlock()
        return sig
    }

    /// Learn the server's placeholder signatures for the sizes we actually use, in
    /// the background, right after connecting — so the per-fetch placeholder check in
    /// `fetchImage` finds them cached and NEVER blocks a real cover on a probe download.
    /// Call once per server. This is the single biggest cover-load latency win.
    func primePlaceholderSignatures(server: ServerConfig) {
        Task.detached(priority: .utility) {
            for size in [Self.thumbSize, Self.fullSize] {
                _ = await self.placeholderSignature(forSize: size, server: server)
            }
        }
    }

    /// Warm the cache for a list of cover art ids at a given point size so list
    /// thumbnails are already on disk/memory before their rows scroll into view.
    /// Skips cached entries; shares in-flight requests with on-screen views.
    /// `cacheToken` (e.g. a playlist's `changed` timestamp) must match what the
    /// displaying view passes to `CoverArtImage` so keys line up.
    func prefetch(_ items: [(coverArt: String, cacheToken: String?)], pointSize: CGFloat) {
        let requestSize = Self.normalizedSize(Int(pointSize * PlatformScreen.scale))
        // Dedupe while preserving order (nearest rows first)
        var seen = Set<String>()
        let unique = items.filter { seen.insert("\($0.coverArt)_\($0.cacheToken ?? "")").inserted }
        guard !unique.isEmpty else { return }
        Task.detached(priority: .utility) {
            guard !self.isArtworkOffline else { return }
            await withTaskGroup(of: Void.self) { group in
                for (i, item) in unique.enumerated() {
                    // Window of 2, half the download gate: prefetch is speculative, so it
                    // must never be able to hold every slot and starve the covers the user
                    // is actually looking at.
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

    /// Warm the full-size cover the Now Playing screen will ask for, at playback time —
    /// so opening Now Playing mid-track shows the HD art immediately instead of starting
    /// the fetch on appear. Uses `displayRequestSize` (same clamp as the view), so the
    /// warmed entry lands in exactly the bucket the view reads. High priority: the user
    /// can open Now Playing a second after pressing play.
    func prefetchNowPlayingCover(coverArt: String?, priority: TaskPriority = .userInitiated) {
        guard let coverArt, !coverArt.isEmpty else { return }
        // Any near-full-width hero clamps to the same bucket, so the screen width is a
        // safe stand-in for the view's exact art size.
        let requestSize = Self.displayRequestSize(pointSize: PlatformScreen.width)
        let key = "\(coverArt)_\(requestSize)"
        guard image(for: key) == nil else { return }   // already warm
        Task.detached(priority: priority) {
            guard !self.isArtworkOffline else { return }
            _ = await self.fetchImage(coverArt: coverArt, requestSize: requestSize, key: key)
        }
    }

    /// Remove all cached images for a given cover art ID (all sizes)
    func removeImages(forCoverArt coverArt: String) {
        // Normalized thumbnail buckets + common exact retina sizes for large displays
        // 300 is `thumbSize`, the bucket every list row uses: leaving it out meant a
        // cover could be "removed" and still be exactly what the next list drew.
        let sizes = [100, 200, ArtworkCache.thumbSize, 400, 780, ArtworkCache.fullSize,
                     840, 999, 1000, 1170, 1200, ArtworkCache.heroSize]
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

    @State private var image: PlatformImage?
    /// The cache key the current `image` was resolved for — lets a retry bump tell
    /// "already loaded" apart from "still a placeholder".
    @State private var loadedKey: String?

    private var requestSize: Int {
        ArtworkCache.normalizedSize(Int(size * PlatformScreen.scale))
    }

    private var cacheKey: String? {
        guard let coverArt = coverArt else { return nil }
        if let cacheToken { return "\(coverArt)_\(cacheToken)_\(requestSize)" }
        return "\(coverArt)_\(requestSize)"
    }

    /// Resolve image synchronously from cache to avoid placeholder flash
    private var resolvedImage: PlatformImage? {
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
                Image(platformImage: img)
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
        .task(id: retryKey) { await loadCached() }
    }

    /// Re-runs the fetch both when the cover itself changes and when a reconnection
    /// asks every stuck placeholder to try again.
    private var retryKey: String? {
        guard let cacheKey else { return nil }
        return "\(cacheKey)#\(ArtworkRetry.shared.generation)"
    }

    private func loadCached() async {
        guard let coverArt = coverArt, let key = cacheKey else {
            AppLogger.shared.log("🖼 CoverArtImage has no coverArt id", level: .debug)
            return
        }
        // Skip covers that already resolved for this exact key, so a retry bump doesn't
        // re-download the whole screen. A changed cover/token yields a different key and
        // still refetches, as before.
        if image != nil, loadedKey == key { return }
        if let result = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: requestSize, key: key) {
            await MainActor.run { self.image = result; self.loadedKey = key }
        } else if let fb = fallbackCoverArt, fb != coverArt {
            // Primary id had no art — try the album cover.
            let fbKey = cacheToken.map { "\(fb)_\($0)_\(requestSize)" } ?? "\(fb)_\(requestSize)"
            if let result = await ArtworkCache.shared.fetchImage(coverArt: fb, requestSize: requestSize, key: fbKey) {
                await MainActor.run { self.image = result; self.loadedKey = key }
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

    @State private var image: PlatformImage?
    /// Track the coverArt we loaded so we can detect changes without re-flashing
    @State private var loadedCoverArt: String?

    /// Whichever bucket this view's size falls in — grid cards land in the middle one,
    /// anything near full width in the hero one.
    ///
    /// Heroes used to be capped at the middle bucket on the grounds that the difference
    /// was imperceptible on a phone and that sharing with grid cards meant an album
    /// already seen appeared instantly. It is not imperceptible: the cap was a 1.5x
    /// upscale on every full-width cover. Sharing is preserved where it matters —
    /// `resolvedImage` shows the grid's copy immediately and swaps when the sharp one
    /// lands, rather than making the user wait on a placeholder.
    private var requestSize: Int {
        ArtworkCache.displayRequestSize(pointSize: size)
    }

    private func cacheKey(for id: String) -> String {
        "\(id)_\(requestSize)"
    }

    /// Try to resolve image from cache immediately (avoids placeholder flash)
    private var resolvedImage: PlatformImage? {
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
                Image(platformImage: img)
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
        .task(id: retryKey) { await loadImage() }
    }

    /// Re-runs both when the cover changes and when a reconnection asks stuck
    /// placeholders to retry. `loadImage()` already returns early for covers that
    /// resolved, so the bump only costs a refetch where one is actually needed.
    private var retryKey: String {
        "\(coverArt ?? "")#\(ArtworkRetry.shared.generation)"
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
        guard let coverArt else {
            AppLogger.shared.log("🖼 CoverArtAsyncImage has no coverArt id", level: .debug)
            return
        }
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
