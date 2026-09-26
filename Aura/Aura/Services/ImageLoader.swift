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

    private let placeholderLock = NSLock()

    /// A size so small no real artwork survives it untouched — the question put to the
    /// server when a response is ambiguous. See `classifyArtwork`.
    private static let proofSize = 64
    /// Below this, a square of the requested size is a flat shape rather than a picture.
    /// The server's artist silhouette is 546 bytes; the smallest real 300px cover seen on
    /// a full library is over six kilobytes.
    private static let plausibleArtworkBytes = 3_072

    /// Hashes proven to be one of the server's fixed "no artwork" images, and hashes
    /// proven to be real artwork. A verdict is reached once and then costs nothing:
    /// one library's worth of art-less albums all share a single hash.
    private var genericHashes: Set<String> = []
    private var artworkHashes: Set<String> = []
    /// Covers proven to have real artwork, whatever size was asked for — so a cover
    /// resolved in a list never pays for proof again when its hero is loaded.
    private var provenArtworkCovers: Set<String> = []
    /// Covers already shown to have none. Re-asking costs a full round trip — on this
    /// library about ten seconds each, because the server goes out to Last.fm before
    /// giving up — and the answer cannot change until the library is rescanned.
    private var missingArtCovers: Set<String> = []
    /// Set the first time the server answers with exactly the size asked for. Until then
    /// nothing can be concluded from a size that does not match: a server that ignores
    /// `size` altogether would otherwise have every one of its covers called generic.
    private var serverResizesArtwork = false

    /// Roughly what an image occupies once decoded: four bytes a pixel. Artwork is built
    /// with `PlatformImage(data:)`, whose `size` is already in pixels.
    private static func decodedByteCost(_ image: PlatformImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    /// The last few full-size covers, held strongly so nothing can take them away.
    ///
    /// `NSCache` evicts whenever it feels like it, and now that entries carry their real
    /// byte cost, the biggest image in the app — the one filling the Now Playing screen —
    /// is the first to go. Losing it meant that reopening the screen had to fetch the
    /// cover again, and until it arrived the view showed either a smaller copy or Aura's
    /// own placeholder. Four is the song playing plus its neighbours in the queue; at
    /// hero resolution that is about 25 MB, which is worth it for the one picture the
    /// user is actually looking at.
    private var pinned: [(key: String, image: PlatformImage)] = []
    private static let pinnedLimit = 4
    /// Only full-size covers are worth pinning; thumbnails are cheap to rebuild.
    private static let pinnableWidth: CGFloat = 700
    private let pinLock = NSLock()

    private func pinIfLarge(_ image: PlatformImage, for key: String) {
        guard image.size.width >= Self.pinnableWidth else { return }
        pinLock.lock(); defer { pinLock.unlock() }
        pinned.removeAll { $0.key == key }
        pinned.append((key, image))
        if pinned.count > Self.pinnedLimit { pinned.removeFirst(pinned.count - Self.pinnedLimit) }
    }

    private func pinnedImage(for key: String) -> PlatformImage? {
        pinLock.lock(); defer { pinLock.unlock() }
        return pinned.first { $0.key == key }?.image
    }

    private func unpinAll(matching coverArt: String) {
        pinLock.lock(); defer { pinLock.unlock() }
        pinned.removeAll { $0.key.hasPrefix("\(coverArt)_") }
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

    /// One-time migration: flush the thumbnail disk cache to purge entries that pinned
    /// art-less albums to Navidrome's "no art" placeholder (now prevented by placeholder
    /// detection in `fetchImage`). Version 3 purges the ones kept since Navidrome began
    /// resizing its placeholder, which slipped past the size test. The permanent
    /// offline/downloaded masters live in a separate store (`offlineArtworkURL`) and are
    /// checked as they load instead.
    private func migrateArtworkCacheIfNeeded() {
        let key = "artworkCacheVersion"
        guard UserDefaults.standard.integer(forKey: key) < 3 else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        UserDefaults.standard.set(3, forKey: key)
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
            // Saved with a download before the server's placeholder was recognised: let it go.
            if GenericArtwork.isGeneric(img) {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
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
            if var img = PlatformImage(data: data) {
                // The server has no picture: keep the one found for it, or none at all.
                if GenericArtwork.isGeneric(img) {
                    guard let found = await standIn(for: coverArt, requestSize: ArtworkCache.fullSize) else { return }
                    img = found
                }
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
        if let pinned = pinnedImage(for: key) { return pinned }
        let nsKey = key as NSString
        if let img = memoryCache.object(forKey: nsKey) { return img }
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let fileURL = diskCacheURL.appendingPathComponent(hash)
        if let data = try? Data(contentsOf: fileURL), let img = PlatformImage(data: data) {
            // Same cost as `store`: an image promoted from disk occupies exactly as much
            // memory as one that arrived over the network, and cost 0 would exempt it.
            memoryCache.setObject(img, forKey: nsKey, cost: Self.decodedByteCost(img))
            pinIfLarge(img, for: key)
            return img
        }
        return nil
    }

    /// The largest copy of this cover already in hand that is at least `minSize` — the
    /// answer to "do we need to go to the network at all?".
    ///
    /// Reopening Now Playing used to re-fetch the cover it had just shown, because the
    /// view only looked for the one exact key it wanted. An 800-pixel copy satisfies a
    /// request for 800 and is the best there will ever be for a cover the server holds
    /// at 800 — asking again buys nothing and risks showing a placeholder while it waits.
    func cachedImage(forCoverArt coverArt: String, atLeast minSize: Int,
                     cacheToken: String? = nil) -> (image: PlatformImage, size: Int)? {
        for size in [Self.heroSize, Self.fullSize, Self.thumbSize] where size >= minSize {
            let key = cacheToken.map { "\(coverArt)_\($0)_\(size)" } ?? "\(coverArt)_\(size)"
            if let img = image(for: key) { return (img, size) }
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
        pinIfLarge(image, for: key)
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
        pinLock.lock(); pinned.removeAll(); pinLock.unlock()
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
        if hasNoArtwork(coverArt) { return await standIn(for: coverArt, requestSize: requestSize, key: key) }
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
                // A catalogue cover (a radar preview's) comes at one fixed size whatever is
                // asked — the very sign of a generic picture below — and is never one.
                if coverArt.hasPrefix("https://") {
                    self.store(img, for: key)
                    return img
                }
                // Recognised by eye, whatever size it came at: Navidrome now resizes its
                // placeholder to order like any cover, which the size test below can't see.
                if GenericArtwork.isGeneric(img) {
                    self.markMissing(coverArt, data: data)
                    AppLogger.shared.log("🕳 Cover art id=\(coverArt): the server's placeholder — looking for the real one")
                    return nil
                }
                let width = Int(img.size.width.rounded())
                var verdict = self.classifyArtwork(data: data, width: width, coverArt: coverArt, size: requestSize)
                if verdict == .undecided {
                    // Still inside the download gate on purpose: the proof is a 64-pixel
                    // thumbnail, and taking a second slot for it could deadlock the gate.
                    verdict = await self.prove(artworkOf: coverArt, data: data, server: server) ? .artwork : .generic
                }
                if verdict == .generic {
                    AppLogger.shared.log("🕳 Cover art id=\(coverArt): the server has none (\(width)px for a \(requestSize)px request) — using Aura's placeholder")
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
        if result == nil, hasNoArtwork(coverArt) {
            return await standIn(for: coverArt, requestSize: requestSize, key: key)
        }
        return result
    }

    /// The real cover of an album the server has no picture for, found in the catalogue —
    /// or nil, and Aura draws its own. Looked for outside the download gate: it asks
    /// someone else, and must not hold up the server's covers while it waits.
    private func standIn(for coverArt: String, requestSize: Int, key: String? = nil) async -> PlatformImage? {
        #if os(iOS)
        guard let server = ServerManager.shared.currentServer,
              let url = await CoverFinder.shared.coverURL(for: coverArt, server: server, pixels: requestSize),
              let (data, _) = try? await imageSession.data(from: url),
              let image = PlatformImage(data: data)
        else { return nil }
        if let key { store(image, for: key) }
        return image
        #else
        return nil
        #endif
    }

    private func markMissing(_ coverArt: String, data: Data) {
        let hash = Self.sha256Hex(data)
        placeholderLock.lock(); defer { placeholderLock.unlock() }
        genericHashes.insert(hash)
        missingArtCovers.insert(coverArt)
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

    /// Whether a downloaded image is this cover's artwork, the server's generic "no
    /// artwork" picture, or not yet decidable without asking the server again.
    private enum ArtworkVerdict { case artwork, generic, undecided }

    /// Decides what came back, from the one thing a server cannot fake: the size.
    ///
    /// Artwork is resized to order — ask for 300 pixels and 300 come back, ask for 64 and
    /// 64 come back — capped by the picture's own size. The "no artwork" images bypass
    /// that entirely: they are fixed files, served at their own size whatever was asked.
    /// So a response that is exactly the size requested is this cover's artwork, and one
    /// that is larger cannot be. Smaller is ambiguous — a real cover whose original is
    /// small looks the same as a fixed file — and `prove(artworkOf:)` settles it.
    ///
    /// This replaces two tests that did not hold here. Probing a made-up cover id only
    /// works on servers that answer an unknown id with the fallback image; Navidrome
    /// answers with an error, so it learned nothing. Comparing one cover's bytes across
    /// two sizes looked sound and is not: Navidrome caps output at the original's size,
    /// so every cover smaller than the bucket asked for comes back identical in both —
    /// which is most of them, and would have blanked most of a library.
    private func classifyArtwork(data: Data, width: Int, coverArt: String, size: Int) -> ArtworkVerdict {
        let hash = Self.sha256Hex(data)
        placeholderLock.lock(); defer { placeholderLock.unlock() }

        if genericHashes.contains(hash) {
            missingArtCovers.insert(coverArt)
            return .generic
        }
        // Resized to order: nothing but this cover's own artwork can answer that.
        if width == size && data.count >= Self.plausibleArtworkBytes {
            serverResizesArtwork = true
            artworkHashes.insert(hash)
            provenArtworkCovers.insert(coverArt)
            return .artwork
        }
        if artworkHashes.contains(hash) || provenArtworkCovers.contains(coverArt) { return .artwork }
        // Nothing is known yet about how this server treats `size`, so a mismatch proves
        // nothing. Show the picture rather than hide real artwork on a guess.
        guard serverResizesArtwork else { return .artwork }
        return .undecided
    }

    /// Ask for the same cover at a size no picture survives untouched. Artwork comes back
    /// shrunk; a fixed "no artwork" file comes back byte for byte the same, and that is
    /// the proof. Costs one small request, once per image — a library's worth of art-less
    /// albums share a single one between them.
    private func prove(artworkOf coverArt: String, data: Data, server: ServerConfig) async -> Bool {
        let hash = Self.sha256Hex(data)
        guard let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: Self.proofSize),
              let (proof, _) = try? await imageSession.data(from: url) else { return true }
        let isArtwork = Self.sha256Hex(proof) != hash
        placeholderLock.lock(); defer { placeholderLock.unlock() }
        if isArtwork {
            artworkHashes.insert(hash)
            provenArtworkCovers.insert(coverArt)
        } else {
            genericHashes.insert(hash)
            missingArtCovers.insert(coverArt)
        }
        return isArtwork
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
        unpinAll(matching: coverArt)
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
    /// The bucket `image` was actually loaded at. One view serves both the hero and the
    /// 44-point header beside the lyrics, so its requested size changes under it — and
    /// without this, whichever size happened to load first was kept forever.
    @State private var loadedSize: Int = 0

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

    /// Re-runs when the cover changes, when the size asked for grows, and when a
    /// reconnection asks stuck placeholders to retry. `loadImage()` already returns early
    /// for covers that resolved at a big enough size, so a bump only costs a refetch
    /// where one is actually needed.
    private var retryKey: String {
        "\(coverArt ?? "")#\(requestSize)#\(ArtworkRetry.shared.generation)"
    }

    /// Whether what is in hand is already at least as sharp as what is being asked for.
    private var haveSharpEnough: Bool {
        image != nil && loadedCoverArt == coverArt && loadedSize >= requestSize
    }

    /// Load from memory/disk cache synchronously to avoid placeholder flash on re-appear.
    /// Any copy at least as large as the one wanted counts — a cover the server only
    /// holds at 800 pixels is already as good as it will ever get.
    private func loadFromCacheSync() {
        guard !haveSharpEnough, let coverArt else { return }
        if let cached = ArtworkCache.shared.cachedImage(forCoverArt: coverArt, atLeast: requestSize) {
            image = cached.image
            loadedCoverArt = coverArt
            loadedSize = cached.size
        }
    }

    private func loadImage() async {
        guard let coverArt else {
            AppLogger.shared.log("🖼 CoverArtAsyncImage has no coverArt id", level: .debug)
            return
        }
        let key = cacheKey(for: coverArt)
        // Anything already in hand that is big enough ends it here — no network, no
        // window during which the screen shows a smaller copy or a placeholder.
        if !haveSharpEnough,
           let cached = ArtworkCache.shared.cachedImage(forCoverArt: coverArt, atLeast: requestSize) {
            await MainActor.run {
                self.image = cached.image
                self.loadedCoverArt = coverArt
                self.loadedSize = cached.size
            }
            return
        }
        // Already loaded for this cover, at this size or better. Shrinking to the
        // 44-point lyrics header must NOT throw the hero copy away and fetch a
        // thumbnail: the picture would come back coarse the next time it grows.
        if haveSharpEnough { return }
        if let result = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: requestSize, key: key) {
            await MainActor.run {
                self.image = result
                self.loadedCoverArt = coverArt
                self.loadedSize = requestSize
            }
        } else if let fb = fallbackCoverArt, fb != coverArt {
            // Primary id had no art — try the album cover.
            let fbKey = cacheKey(for: fb)
            if let result = await ArtworkCache.shared.fetchImage(coverArt: fb, requestSize: requestSize, key: fbKey) {
                await MainActor.run {
                    self.image = result
                    self.loadedCoverArt = coverArt
                    self.loadedSize = requestSize
                }
            }
        }
    }
}

/// The pictures a server shows for an album that has none, recognised by how they look.
///
/// Their bytes can't be trusted to repeat: Navidrome resizes its placeholder to whatever
/// size is asked, as it does real covers. What survives any resize is the picture itself,
/// so each image is reduced to a 16×16 grey thumbnail — averaged from a 128-pixel copy, so
/// a small original doesn't alias — and compared with the known placeholders'. Copies of
/// Navidrome's record, from 64 to 800 pixels, JPEG or PNG, differ from it by under 2 levels
/// of 255 on average; real covers by 80 and more.
enum GenericArtwork {
    private static let side = 16
    private static let drawn = 128
    private static let tolerance: Double = 8

    /// Navidrome's "no artwork" record (resources/album-placeholder.webp, 0.63), as
    /// `thumbnail(of:)` reduces it. Only the thumbnail is kept, not the picture.
    private static let known: [[UInt8]] = [
        "//////////v8///////////////nnm5bXHKj6v////////+8XVpaW1xdYXjI///////AXVtZW1xdXm55bcf////tZF1dW1taW2N4a2Vt8f//rFxcXlxHM0NoZ2RlZrX//4BbXF5JRlJjV1RlZ2aM//9rWVtcNh8dJCA+Zmtnev//blhZWzspOyEeQ2VnZX3//4pVV1lVUzciL1tlZWOW///CVVVfcVxMTVtiY2Nhyv///HVccWlZWlxdX2Bggv3////odWxYVlhZWlxdcev//////+yIU1VWV1lai+///////////9yoj5Cq3v///////////////////////////w==",
    ].compactMap { Data(base64Encoded: $0).map(Array.init) }

    static func isGeneric(_ image: PlatformImage) -> Bool {
        guard let thumbnail = thumbnail(of: image) else { return false }
        return known.contains { reference in
            let total = zip(reference, thumbnail).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
            return total / Double(reference.count) < tolerance
        }
    }

    /// The image in grey, flattened onto white — a placeholder may come with its
    /// transparency or without — and averaged down to `side`×`side`.
    private static func thumbnail(of image: PlatformImage) -> [UInt8]? {
        #if os(iOS)
        guard let picture = image.cgImage else { return nil }
        #else
        guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        var pixels = [UInt8](repeating: 255, count: drawn * drawn)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: drawn, height: drawn,
                                          bitsPerComponent: 8, bytesPerRow: drawn,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: drawn, height: drawn))
            context.draw(picture, in: CGRect(x: 0, y: 0, width: drawn, height: drawn))
            return true
        }
        guard drew else { return nil }
        let block = drawn / side
        return (0..<(side * side)).map { cell in
            let (row, column) = (cell / side, cell % side)
            var sum = 0
            for y in 0..<block {
                for x in 0..<block { sum += Int(pixels[(row * block + y) * drawn + column * block + x]) }
            }
            return UInt8(sum / (block * block))
        }
    }
}
