import Foundation
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

/// Manages audio stream caching using AVAssetResourceLoaderDelegate.
/// Intercepts requests using a custom URL scheme, serves from disk cache when available,
/// otherwise downloads from the real server URL and writes to cache.
final class AudioCacheManager: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = AudioCacheManager()

    private let cacheScheme = "musika-cache"
    private let delegateQueue = DispatchQueue(label: "com.aura.musika.audiocache", qos: .userInitiated)
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private let lock = NSLock()

    private let metadataCacheKey = "musika_cached_audio_metadata"
    private var cachedMetadata: [String: Song] = [:]

    private func persistMetadata(_ snapshot: [String: Song]) {
        DispatchQueue.global(qos: .utility).async { [metadataCacheKey] in
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: metadataCacheKey)
            }
        }
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: metadataCacheKey),
           let dict = try? JSONDecoder().decode([String: Song].self, from: data) {
            cachedMetadata = dict
        }
        migrateCacheIfNeeded()
    }

    /// One-time migration: clear cache that may contain OGG files (iOS can't play OGG).
    /// Now that we request format=mp3, new downloads will be in a playable format.
    private func migrateCacheIfNeeded() {
        let key = "audioCacheVersion"
        if UserDefaults.standard.integer(forKey: key) < 6 {
            clearCache()
            UserDefaults.standard.set(6, forKey: key)
            AppLogger.shared.log("🔄 Audio cache cleared (purge poisoned entries)")
        }
    }

    private var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("musika_audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Public API

    func saveMetadata(_ song: Song) {
        lock.lock()
        cachedMetadata[song.id] = song
        let snapshot = cachedMetadata
        lock.unlock()
        persistMetadata(snapshot)
    }

    /// Persist the song's album artwork to the permanent offline store so the cached
    /// song's album shows cover art in offline mode (without waiting for the next launch).
    private func persistOfflineArtwork(for songId: String) {
        lock.lock()
        let coverArt = cachedMetadata[songId]?.coverArt
        lock.unlock()
        guard let coverArt, let server = ServerManager.shared.currentServer else { return }
        Task.detached(priority: .utility) {
            await ArtworkCache.shared.cacheOfflineArtwork(forCoverArt: coverArt, server: server)
        }
    }

    /// Returns a list of cached songs that are currently on disk
    func getCachedSongs() -> [Song] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        let audioFiles = files.filter { $0.hasSuffix(".audio") }
        
        lock.lock()
        let dict = cachedMetadata
        lock.unlock()
        
        var cachedSongs: [Song] = []
        for (id, song) in dict {
            if audioFiles.contains(where: { $0.hasPrefix(id + "_") }) {
                cachedSongs.append(song)
            }
        }
        
        return cachedSongs.sorted { $0.title < $1.title }
    }

    /// True when this song's audio sits in the stream cache on disk, resolving
    /// bitRate/transcoding exactly the way `playerItem(songId:...)` does.
    func hasCachedAudio(for song: Song, bitRate: Int?) -> Bool {
        let transcoded = shouldTranscodeStream(songSuffix: song.suffix, songContentType: song.contentType)
        return isCached(songId: song.id, bitRate: bitRate, transcoded: transcoded)
    }

    /// Create an AVPlayerItem. Cached files are served via resource loader delegate.
    /// Non-cached files use the real URL directly for instant progressive playback,
    /// with a background download to populate the cache.
    func playerItem(songId: String, server: ServerConfig, bitRate: Int?, songSuffix: String? = nil, songContentType: String? = nil) -> AVPlayerItem {
        // Check for offline download first (these have proper file extensions)
        if let localURL = DownloadManager.shared.localURL(for: songId) {
            AppLogger.shared.log("📀 Playing from download: \(songId)")
            return AVPlayerItem(url: localURL)
        }

        let usesTranscoding = shouldTranscodeStream(songSuffix: songSuffix, songContentType: songContentType)

        // Build the real streaming URL
        guard let realURL = SubsonicClient.shared.streamURL(server: server, id: songId, maxBitRate: bitRate, songSuffix: songSuffix, songContentType: songContentType) else {
            return AVPlayerItem(url: URL(string: "about:blank")!)
        }

        // If cached, use resource loader delegate to serve from disk with correct UTI
        if isCached(songId: songId, bitRate: bitRate, transcoded: usesTranscoding) {
            AppLogger.shared.log("💾 Playing from cache: \(songId) | mode: \(usesTranscoding ? "mp3" : "source")")
            guard let cacheURL = cacheSchemedURL(songId: songId, bitRate: bitRate, transcoded: usesTranscoding, realURL: realURL) else {
                return AVPlayerItem(url: realURL)
            }
            let asset = AVURLAsset(url: cacheURL)
            asset.resourceLoader.setDelegate(self, queue: delegateQueue)
            return AVPlayerItem(asset: asset)
        }

        // Not cached — use real URL directly for instant progressive playback
        AppLogger.shared.log("🌐 Streaming directly: \(songId) | mode: \(usesTranscoding ? "mp3" : "source")")
        // Start background cache download
        if AppSettings.shared.cacheEnabled {
            backgroundCache(songId: songId, realURL: realURL, bitRate: bitRate, transcoded: usesTranscoding)
        }
        return AVPlayerItem(url: realURL)
    }

    /// Download audio in the background for caching (doesn't block playback)
    /// The server's stream of a song it converts as it sends, begun `offset` seconds in.
    ///
    /// Such a stream carries no length and answers no byte range, so the player can't seek
    /// past what has arrived; a jump further on asks the server to start converting from
    /// there instead. Nil when the song plays from a download or the cache, or is streamed
    /// as the file itself, all of which seek anywhere. No background cache starts: the one
    /// begun with the song's first stream is still under way.
    func streamItem(songId: String, server: ServerConfig, bitRate: Int?, songSuffix: String?,
                    songContentType: String?, from offset: Int) -> AVPlayerItem? {
        guard DownloadManager.shared.localURL(for: songId) == nil,
              shouldTranscodeStream(songSuffix: songSuffix, songContentType: songContentType),
              !isCached(songId: songId, bitRate: bitRate, transcoded: true),
              let url = SubsonicClient.shared.streamURL(server: server, id: songId, maxBitRate: bitRate,
                                                        songSuffix: songSuffix, songContentType: songContentType)
        else { return nil }
        guard offset > 0 else { return AVPlayerItem(url: url) }
        return URL(string: url.absoluteString + "&timeOffset=\(offset)").map(AVPlayerItem.init(url:))
    }

    private func backgroundCache(songId: String, realURL: URL, bitRate: Int?, transcoded: Bool) {
        lock.lock()
        let alreadyActive = activeTasks[songId] != nil
        lock.unlock()
        if alreadyActive { return }

        let task = URLSession.shared.dataTask(with: realURL) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                self?.lock.lock()
                self?.activeTasks.removeValue(forKey: songId)
                self?.lock.unlock()
                return
            }
            // Don't cache error responses (Subsonic returns HTTP 200 with error JSON/XML)
            guard data.count > 1024 else {
                AppLogger.shared.log("⚠️ Background cache skipped: \(songId) — response too small (\(data.count) bytes, likely error)")
                self.lock.lock()
                self.activeTasks.removeValue(forKey: songId)
                self.lock.unlock()
                return
            }
            if let firstByte = data.first, firstByte == 0x7B || firstByte == 0x3C { // '{' or '<'
                AppLogger.shared.log("⚠️ Background cache skipped: \(songId) — response is JSON/XML error, not audio")
                self.lock.lock()
                self.activeTasks.removeValue(forKey: songId)
                self.lock.unlock()
                return
            }
            let fileURL = self.cacheFileURL(songId: songId, bitRate: bitRate, transcoded: transcoded)
            do {
                try data.write(to: fileURL, options: .atomic)
                self.touchFile(at: fileURL)
                self.persistOfflineArtwork(for: songId)
                AppLogger.shared.log("💾 Background cached: \(songId) (\(data.count) bytes)")
                self.enforceCacheLimit()
            } catch { AppLogger.shared.log("❌ Background cache write failed for \(songId): \(error.localizedDescription)") }
            self.lock.lock()
            self.activeTasks.removeValue(forKey: songId)
            self.lock.unlock()
        }

        lock.lock()
        activeTasks[songId] = task
        lock.unlock()
        task.resume()
    }

    /// Prefetch a song into cache without playing it
    func prefetch(songId: String, server: ServerConfig, bitRate: Int?, songSuffix: String? = nil, songContentType: String? = nil) {
        guard AppSettings.shared.cacheEnabled else { return }

        let usesTranscoding = shouldTranscodeStream(songSuffix: songSuffix, songContentType: songContentType)

        // Already cached or downloaded
        if isCached(songId: songId, bitRate: bitRate, transcoded: usesTranscoding) || DownloadManager.shared.isDownloaded(songId) { return }

        lock.lock()
        let alreadyActive = activeTasks[songId] != nil
        lock.unlock()
        if alreadyActive { return }

        guard let realURL = SubsonicClient.shared.streamURL(server: server, id: songId, maxBitRate: bitRate, songSuffix: songSuffix, songContentType: songContentType) else { return }

        AppLogger.shared.log("🔮 Prefetching: \(songId)")
        let task = URLSession.shared.dataTask(with: realURL) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                if let error = error, (error as NSError).code != NSURLErrorCancelled {
                    AppLogger.shared.log("❌ Prefetch failed: \(songId) — \(error.localizedDescription)")
                }
                self?.lock.lock()
                self?.activeTasks.removeValue(forKey: songId)
                self?.lock.unlock()
                return
            }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                self.lock.lock()
                self.activeTasks.removeValue(forKey: songId)
                self.lock.unlock()
                return
            }

            // Don't cache error responses (Subsonic returns HTTP 200 with error JSON/XML)
            guard data.count > 1024 else {
                AppLogger.shared.log("⚠️ Prefetch skipped: \(songId) — response too small (\(data.count) bytes, likely error)")
                self.lock.lock()
                self.activeTasks.removeValue(forKey: songId)
                self.lock.unlock()
                return
            }
            if let firstByte = data.first, firstByte == 0x7B || firstByte == 0x3C { // '{' or '<'
                AppLogger.shared.log("⚠️ Prefetch skipped: \(songId) — response is JSON/XML error, not audio")
                self.lock.lock()
                self.activeTasks.removeValue(forKey: songId)
                self.lock.unlock()
                return
            }

            let fileURL = self.cacheFileURL(songId: songId, bitRate: bitRate, transcoded: usesTranscoding)
            do {
                try data.write(to: fileURL, options: .atomic)
                self.touchFile(at: fileURL)
                self.persistOfflineArtwork(for: songId)
                AppLogger.shared.log("💾 Prefetch cached: \(songId) (\(data.count) bytes)")
                self.enforceCacheLimit()
            } catch {
                AppLogger.shared.log("❌ Prefetch write error: \(error.localizedDescription)")
            }

            self.lock.lock()
            self.activeTasks.removeValue(forKey: songId)
            self.lock.unlock()
        }

        lock.lock()
        activeTasks[songId] = task
        lock.unlock()
        task.resume()
    }

    /// Cancel a prefetch in progress
    func cancelPrefetch(songId: String) {
        lock.lock()
        let task = activeTasks.removeValue(forKey: songId)
        lock.unlock()
        task?.cancel()
    }

    /// Clear the entire audio cache
    func clearCache() {
        lock.lock()
        cachedMetadata.removeAll()
        lock.unlock()
        persistMetadata([:])

        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
        AppLogger.shared.log("🗑 Audio cache cleared")
    }

    /// Current cache size in bytes
    var currentCacheSizeBytes: Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    var currentCacheSizeFormatted: String {
        let bytes = currentCacheSizeBytes
        if bytes > 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else if bytes > 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }

    // MARK: - Cache File Management

    private func cacheFileURL(songId: String, bitRate: Int?, transcoded: Bool) -> URL {
        let suffix = bitRate.map { "_\($0)" } ?? "_orig"
        let mode = transcoded ? "_mp3" : "_src"
        return cacheDirectory.appendingPathComponent("\(songId)\(suffix)\(mode).audio")
    }

    func isCached(songId: String, bitRate: Int?, transcoded: Bool) -> Bool {
        FileManager.default.fileExists(atPath: cacheFileURL(songId: songId, bitRate: bitRate, transcoded: transcoded).path)
    }

    /// Update modification date (for LRU)
    private func touchFile(at url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: - Cache Eviction (LRU)

    func enforceCacheLimit() {
        guard AppSettings.shared.cacheEnabled else { return }
        let maxBytes = Int64(AppSettings.shared.cacheMaxSize) * 1_000_000 // MB → bytes
        guard maxBytes > 0 else { return }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }

        // Build list with metadata
        struct CacheEntry {
            let url: URL
            let size: Int64
            let modified: Date
        }

        var entries: [CacheEntry] = []
        var totalSize: Int64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            entries.append(CacheEntry(url: file, size: size, modified: modified))
            totalSize += size
        }

        guard totalSize > maxBytes else { return }

        // Sort by modification date ascending (oldest = least recently used first)
        entries.sort { $0.modified < $1.modified }

        var freed: Int64 = 0
        for entry in entries {
            guard totalSize - freed > maxBytes else { break }
            try? fm.removeItem(at: entry.url)
            freed += entry.size
            AppLogger.shared.log("🗑 Cache evict: \(entry.url.lastPathComponent) (\(entry.size) bytes)")
        }
    }

    // MARK: - Custom URL Scheme

    /// Encode the real URL into a custom-scheme URL: musika-cache://<songId>?br=<bitRate>&mode=<mode>&real=<encodedRealURL>
    private func cacheSchemedURL(songId: String, bitRate: Int?, transcoded: Bool, realURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = cacheScheme
        components.host = songId
        var queryItems = [URLQueryItem(name: "real", value: realURL.absoluteString)]
        if let br = bitRate {
            queryItems.append(URLQueryItem(name: "br", value: String(br)))
        }
        queryItems.append(URLQueryItem(name: "mode", value: transcoded ? "mp3" : "source"))
        components.queryItems = queryItems
        return components.url
    }

    /// Parse song ID, bitrate, and real URL from a custom-scheme URL
    private func parseSchemeURL(_ url: URL) -> (songId: String, bitRate: Int?, transcoded: Bool, realURL: URL)? {
        guard url.scheme == cacheScheme else { return nil }
        let songId = url.host ?? ""
        guard !songId.isEmpty else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        guard let realString = items.first(where: { $0.name == "real" })?.value,
              let realURL = URL(string: realString) else { return nil }
        let bitRate = items.first(where: { $0.name == "br" })?.value.flatMap(Int.init)
        let transcoded = items.first(where: { $0.name == "mode" })?.value == "mp3"
        return (songId, bitRate, transcoded, realURL)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              let parsed = parseSchemeURL(url) else {
            return false
        }

        let songId = parsed.songId
        let bitRate = parsed.bitRate
        let realURL = parsed.realURL
        let fileURL = cacheFileURL(songId: songId, bitRate: bitRate, transcoded: parsed.transcoded)

        // Serve from cache if available
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            let contentType = detectUTI(from: data)
            if isUnsupportedPlaybackType(contentType) {
                AppLogger.shared.log("🗑 Removing unsupported cached audio for \(songId) | UTI: \(contentType)")
                try? FileManager.default.removeItem(at: fileURL)
                // Fall through to download below
            } else {
                serve(data: data, contentType: contentType, loadingRequest: loadingRequest)
                touchFile(at: fileURL)
                return true
            }
        }

        // Download, cache, then serve
        let task = URLSession.shared.dataTask(with: realURL) { [weak self] data, response, error in
            guard let self = self else {
                loadingRequest.finishLoading(with: URLError(.cancelled))
                return
            }
            if let error = error {
                AppLogger.shared.log("❌ ResourceLoader: download error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let data = data, let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.shared.log("❌ ResourceLoader: bad response status \(status)")
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }
            // Write to cache
            if AppSettings.shared.cacheEnabled {
                do {
                    try data.write(to: fileURL, options: .atomic)
                    self.touchFile(at: fileURL)
                    self.persistOfflineArtwork(for: songId)
                    self.enforceCacheLimit()
                } catch {
                    AppLogger.shared.log("⚠️ Cache write failed: \(error.localizedDescription)")
                }
            }

            // Detect content type UTI from actual file data (not MIME header)
            let contentType = self.detectUTI(from: data)

            if self.isUnsupportedPlaybackType(contentType) {
                AppLogger.shared.log("❌ ResourceLoader: unsupported stream format for \(songId) | UTI: \(contentType)")
            }

            self.serve(data: data, contentType: contentType, loadingRequest: loadingRequest)
        }

        lock.lock()
        activeTasks[songId] = task
        lock.unlock()
        task.resume()

        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        if let url = loadingRequest.request.url, let parsed = parseSchemeURL(url) {
            lock.lock()
            let task = activeTasks.removeValue(forKey: parsed.songId)
            lock.unlock()
            task?.cancel()
        }
    }

    private func serveFromFile(fileURL: URL, loadingRequest: AVAssetResourceLoadingRequest) {
        guard let data = try? Data(contentsOf: fileURL) else {
            AppLogger.shared.log("❌ serveFromFile: can't open \(fileURL.lastPathComponent)")
            loadingRequest.finishLoading(with: URLError(.cannotOpenFile))
            return
        }

        // Detect content type from file magic bytes (the .audio extension is unrecognisable)
        let contentType = detectUTI(from: data)

        serve(data: data, contentType: contentType, loadingRequest: loadingRequest)
    }

    private func serve(data: Data, contentType: String, loadingRequest: AVAssetResourceLoadingRequest) {
        if isUnsupportedPlaybackType(contentType) {
            loadingRequest.finishLoading(with: URLError(.fileDoesNotExist))
            return
        }

        if let infoRequest = loadingRequest.contentInformationRequest {
            infoRequest.contentType = contentType
            infoRequest.contentLength = Int64(data.count)
            infoRequest.isByteRangeAccessSupported = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            let offset = Int(dataRequest.requestedOffset)
            let length = dataRequest.requestedLength
            let end = min(offset + length, data.count)
            if offset < data.count {
                dataRequest.respond(with: data[offset..<end])
            }
        }

        loadingRequest.finishLoading()
    }

    private func shouldTranscodeStream(songSuffix: String?, songContentType: String?) -> Bool {
        let suffix = songSuffix?.lowercased() ?? ""
        let contentType = songContentType?.lowercased() ?? ""
        let isLossless = AppSettings.shared.streamingQuality == .lossless

        // Lossy formats iOS can play natively — never transcode
        let nativeSuffixes: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "mp4", "m4b"]
        // Lossless formats iOS can play natively — transcode only if quality != lossless
        let losslessNativeSuffixes: Set<String> = ["flac", "alac"]

        if !suffix.isEmpty {
            if nativeSuffixes.contains(suffix) { return false }
            if losslessNativeSuffixes.contains(suffix) { return !isLossless }
            // Everything else (ogg, opus, wma, ape, etc.) always needs transcoding
            return true
        }

        if !contentType.isEmpty {
            let nativeContentTypes = [
                "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac",
                "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff", "audio/vnd.wave"
            ]
            if nativeContentTypes.contains(where: { contentType.contains($0) }) { return false }
            if contentType.contains("flac") { return !isLossless }
            return true
        }

        return false
    }

    private func isUnsupportedPlaybackType(_ contentType: String) -> Bool {
        let normalized = contentType.lowercased()
        // Only OGG (Vorbis/Opus) is unsupported on iOS. FLAC is natively supported since iOS 11.
        return normalized == "org.xiph.ogg"
    }

    /// Detect audio format UTI from file magic bytes
    private func detectUTI(from data: Data) -> String {
        guard data.count >= 12 else { return UTType.mp3.identifier }
        let bytes = [UInt8](data.prefix(12))

        // FLAC: "fLaC"
        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            return "org.xiph.flac"
        }
        // OGG/Opus: "OggS"
        if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            return "org.xiph.ogg"
        }
        // WAV: "RIFF"
        if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
            return UTType.wav.identifier
        }
        // MP4/M4A: "ftyp" at offset 4
        if data.count >= 8, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return UTType.mpeg4Audio.identifier
        }
        // MP3: ID3 tag
        if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            return UTType.mp3.identifier
        }
        // MP3: frame sync
        if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
            return UTType.mp3.identifier
        }
        // Default to MP3 (most common transcoded format)
        return UTType.mp3.identifier
    }
}
