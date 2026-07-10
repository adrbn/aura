import Foundation
import SwiftUI
import CryptoKit

enum DownloadItemState: String {
    case waiting, downloading, completed, failed, cancelled, paused
}

struct DownloadQueueItem: Identifiable {
    let id: String // songId
    let song: Song
    var state: DownloadItemState
    var progress: Double
    var error: String?
}

@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    var downloadedSongs: [DownloadedSong] = []
    var activeDownloads: Set<String> = []
    var downloadProgress: [String: Double] = [:]  // songId -> 0.0...1.0
    var currentDownloadTitle: String?
    var currentDownloadAlbum: String?
    var totalQueueCount: Int = 0
    var completedQueueCount: Int = 0
    var queueItems: [DownloadQueueItem] = [] {
        didSet {
            // Persist only on membership/state changes — progress ticks mutate the
            // array many times per second and don't need to hit disk.
            let states = Dictionary(queueItems.map { ($0.id, $0.state.rawValue) }, uniquingKeysWith: { $1 })
            if states != lastSavedQueueStates {
                lastSavedQueueStates = states
                saveQueue()
            }
        }
    }
    private var lastSavedQueueStates: [String: String] = [:]
    // Group download tracking: maps a groupId (album/playlist id) to songIds
    var activeGroupDownloads: [String: Set<String>] = [:]
    var groupDownloadCompleted: [String: Int] = [:]
    var groupDownloadTotal: [String: Int] = [:]
    private var cancelledIds: Set<String> = []
    /// When true, the serial batch drivers (`downloadAlbum`, the artist multi-album loop)
    /// stop spawning new downloads. Set by Pause All / Stop All; cleared when a fresh
    /// batch begins or downloads are resumed. Without this, halting only cancels the one
    /// song currently in flight while the loop keeps starting the next.
    var isHalted = false
    /// Songs the user has paused — distinct from cancelled so we can resume them later.
    /// When a song is in this set, the download task being cancelled is treated as a pause.
    private var pausedIds: Set<String> = []
    /// Subset of paused songs that were parked automatically because the network was
    /// unavailable (not user-paused) — these auto-resume when the server comes back.
    private var networkPausedIds: Set<String> = []
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeURLTasks: [String: URLSessionDownloadTask] = [:]
    /// Song currently being downloaded — drives the progress ring in DownloadIndicatorView
    var currentDownloadId: String?

    var hasPaused: Bool { queueItems.contains { $0.state == .paused } }

    var isDownloading: Bool { !activeDownloads.isEmpty }

    private let metadataKey = "musika_downloaded_songs"
    private let queueKey = "musika_download_queue"

    /// Continuations parked by `downloadSong` while the delegate drives the transfer.
    /// MainActor-only access.
    private var pendingContinuations: [String: CheckedContinuation<Void, Error>] = [:]

    /// Song metadata readable from the URLSession delegate queue (off-main).
    private let knownSongsLock = NSLock()
    private var knownSongs: [String: Song] = [:]

    /// Background session: transfers keep running while the app is suspended and
    /// survive a system kill (iOS relaunches us via handleEventsForBackgroundURLSession).
    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.aura.goldian.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return Self.backupExcludedDirectory(docs.appendingPathComponent("Downloads"))
    }

    /// Resume blobs for paused/interrupted transfers — kept outside the Downloads
    /// directory so the orphan cleanup never touches them. Survives relaunch.
    private var resumeDataDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self.backupExcludedDirectory(support.appendingPathComponent("musika_download_resume"))
    }

    /// Creates the directory if needed and keeps it out of iCloud backups —
    /// downloads are re-fetchable from the server and shouldn't inflate backups.
    private static func backupExcludedDirectory(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }

    /// Headroom required before starting a download so a transfer can't fill the volume.
    private static let minimumFreeDiskSpace: Int64 = 200_000_000

    private func hasSufficientDiskSpace() -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return true }
        return available > Self.minimumFreeDiskSpace
    }

    private func resumeDataURL(for songId: String) -> URL {
        resumeDataDirectory.appendingPathComponent("\(songId).resume")
    }

    private func saveResumeData(_ data: Data, for songId: String) {
        try? data.write(to: resumeDataURL(for: songId), options: .atomic)
    }

    /// Returns and deletes the stored resume blob — it's single-use.
    private func consumeResumeData(for songId: String) -> Data? {
        let url = resumeDataURL(for: songId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    private func deleteResumeData(for songId: String) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: songId))
    }

    override init() {
        super.init()
        loadMetadata()
        restoreQueue()
        cleanupOrphanedFiles()
        reattachBackgroundSession()
    }

    private func rememberSong(_ song: Song) {
        knownSongsLock.lock()
        knownSongs[song.id] = song
        knownSongsLock.unlock()
    }

    private func knownSong(_ id: String) -> Song? {
        knownSongsLock.lock()
        defer { knownSongsLock.unlock() }
        return knownSongs[id]
    }

    /// Re-adopt download tasks that kept running while the app was dead
    /// (system kill — user force-quit cancels them, which restoreQueue covers).
    private func reattachBackgroundSession() {
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let songId = task.taskDescription,
                          let downloadTask = task as? URLSessionDownloadTask else { continue }
                    self.activeURLTasks[songId] = downloadTask
                    self.activeDownloads.insert(songId)
                    self.pausedIds.remove(songId)
                    if let idx = self.queueItems.firstIndex(where: { $0.id == songId }) {
                        self.queueItems[idx].state = .downloading
                    }
                    AppLogger.shared.log("🔄 Re-attached in-flight download: \(songId)")
                }
                self.restartWaitingDownloads()
            }
        }
    }

    /// Queue items persisted as `.waiting` belong to a batch whose driver died with
    /// the process — restart them, or park them as paused when offline.
    @MainActor
    private func restartWaitingDownloads() {
        let waiting = queueItems.filter {
            $0.state == .waiting && activeTasks[$0.id] == nil && !activeDownloads.contains($0.id)
        }
        guard !waiting.isEmpty else { return }
        if AppSettings.shared.offlineMode || !ServerManager.shared.hasNetwork {
            for item in waiting {
                pausedIds.insert(item.id)
                networkPausedIds.insert(item.id)
                if let idx = queueItems.firstIndex(where: { $0.id == item.id }) {
                    queueItems[idx].state = .paused
                    queueItems[idx].error = "Network unavailable"
                }
            }
            AppLogger.shared.log("📴 Parked \(waiting.count) download(s) — network unavailable")
            return
        }
        AppLogger.shared.log("🔁 Restarting \(waiting.count) queued download(s) from last session")
        for item in waiting {
            let song = item.song
            activeTasks[song.id] = Task { await self.downloadSong(song) }
        }
    }

    func buildExportURL(server: ServerConfig, id: String) -> URL? {
        return buildDownloadURL(server: server, id: id)
    }

    private func buildDownloadURL(server: ServerConfig, id: String) -> URL? {
        let salt = UUID().uuidString.prefix(8).lowercased()
        let data = Data("\(server.password)\(salt)".utf8)
        let hash = Insecure.MD5.hash(data: data)
        let token = hash.map { String(format: "%02hhx", $0) }.joined()
        var urlString = "\(server.baseURL)/rest/download?u=\(server.username)&t=\(token)&s=\(salt)&v=1.16.1&c=Aura&f=json&id=\(id)"
        if let maxBitRate = AppSettings.shared.downloadQuality.bitRate {
            urlString += "&maxBitRate=\(maxBitRate)"
        }
        return URL(string: urlString)
    }

    // MARK: - Group progress helpers

    func groupProgress(for groupId: String) -> Double {
        guard let total = groupDownloadTotal[groupId], total > 0 else { return 0 }
        let completed = groupDownloadCompleted[groupId] ?? 0
        return Double(completed) / Double(total)
    }

    func isGroupDownloading(_ groupId: String) -> Bool {
        activeGroupDownloads[groupId] != nil
    }

    // MARK: - Public

    @MainActor
    func downloadSong(_ song: Song, groupId: String? = nil) async {
        guard !isDownloaded(song.id), !activeDownloads.contains(song.id) else {
            // If already downloaded, count it towards the group
            if let gid = groupId {
                groupDownloadCompleted[gid, default: 0] += 1
            }
            return
        }
        guard let server = ServerManager.shared.currentServer,
              let url = buildDownloadURL(server: server, id: song.id) else { return }

        guard hasSufficientDiskSpace() else {
            AppLogger.shared.log("❌ Download blocked (low disk space): \(song.title)")
            if let idx = queueItems.firstIndex(where: { $0.id == song.id }) {
                queueItems[idx].state = .failed
                queueItems[idx].error = "Not enough free storage"
            } else {
                queueItems.append(DownloadQueueItem(id: song.id, song: song, state: .failed, progress: 0, error: "Not enough free storage"))
            }
            ToastManager.shared.show("Not enough free storage to download", icon: "exclamationmark.triangle.fill")
            return
        }

        AppLogger.shared.log("⬇️ Download start: \(song.title) by \(song.artist ?? "?")")
        rememberSong(song)
        activeDownloads.insert(song.id)
        currentDownloadTitle = song.title
        currentDownloadAlbum = song.album
        currentDownloadId = song.id
        // A transfer restarting from resume data keeps its shown progress; only a
        // from-scratch download starts back at zero.
        let resuming = FileManager.default.fileExists(atPath: resumeDataURL(for: song.id).path)
        downloadProgress[song.id] = resuming ? (queueItems.first(where: { $0.id == song.id })?.progress ?? 0) : 0

        // Track in queue
        if let idx = queueItems.firstIndex(where: { $0.id == song.id }) {
            queueItems[idx].state = .downloading
            if !resuming { queueItems[idx].progress = 0 }
            queueItems[idx].error = nil
        } else {
            queueItems.append(DownloadQueueItem(id: song.id, song: song, state: .downloading, progress: 0))
        }

        do {
            // Check cancellation before starting
            guard !cancelledIds.contains(song.id) else {
                throw CancellationError()
            }

            // The background-session delegate drives the transfer: progress via
            // didWriteData, file move + metadata in finalizeDownload, then it
            // resumes this continuation so batch drivers stay sequential.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingContinuations[song.id] = continuation
                // Resume from the last byte offset if a previous attempt left resume data.
                let task: URLSessionDownloadTask
                if let resumeData = consumeResumeData(for: song.id) {
                    AppLogger.shared.log("⏯ Resuming \(song.title) from saved offset")
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                task.taskDescription = song.id
                activeURLTasks[song.id] = task
                task.resume()
            }

            completedQueueCount += 1
            if let gid = groupId {
                groupDownloadCompleted[gid, default: 0] += 1
            }
            cleanupQueueCounts()
        } catch is CancellationError {
            handleInterruptedDownload(song)
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession's task.cancel() (used by pause/cancel) throws URLError.cancelled,
            // NOT CancellationError — treat it as an intentional interruption, not a failure.
            handleInterruptedDownload(song)
        } catch {
            AppLogger.shared.log("❌ Download failed: \(song.title) - \(error.localizedDescription)")
            downloadProgress.removeValue(forKey: song.id)
            activeDownloads.remove(song.id)
            activeURLTasks.removeValue(forKey: song.id)
            if let idx = queueItems.firstIndex(where: { $0.id == song.id }) {
                queueItems[idx].state = .failed
                queueItems[idx].error = error.localizedDescription
            }
            cleanupQueueCounts()
        }
    }

    /// Record a finished transfer: called on the main actor by the session delegate
    /// after the file has been moved into the Downloads directory. Works both for
    /// awaited downloads and for transfers that completed while the app was dead.
    @MainActor
    private func finalizeDownload(songId: String, filename: String, fileSize: Int64) {
        guard !cancelledIds.contains(songId) else {
            try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(filename))
            if let song = knownSong(songId) { handleInterruptedDownload(song) }
            pendingContinuations.removeValue(forKey: songId)?.resume(throwing: CancellationError())
            return
        }
        guard let song = knownSong(songId) ?? queueItems.first(where: { $0.id == songId })?.song else {
            // No metadata for this transfer (shouldn't happen — queue is persisted).
            AppLogger.shared.log("⚠️ Finished download with no metadata, discarding: \(songId)")
            try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(filename))
            pendingContinuations.removeValue(forKey: songId)?.resume(throwing: URLError(.unknown))
            return
        }

        if !isDownloaded(songId) {
            downloadedSongs.append(DownloadedSong(
                id: songId,
                song: song,
                localPath: filename,
                downloadDate: Date(),
                fileSize: fileSize
            ))
            saveMetadata()
        }
        downloadProgress.removeValue(forKey: songId)
        activeDownloads.remove(songId)
        activeURLTasks.removeValue(forKey: songId)
        if let idx = queueItems.firstIndex(where: { $0.id == songId }) {
            queueItems[idx].state = .completed
            queueItems[idx].progress = 1.0
        }
        AppLogger.shared.log("✅ Downloaded: \(song.title) (\(fileSize) bytes)")
        deleteResumeData(for: songId)

        // Persist a permanent master artwork so cover art shows offline.
        if let coverArt = song.coverArt, let server = ServerManager.shared.currentServer {
            Task.detached(priority: .utility) {
                await ArtworkCache.shared.cacheOfflineArtwork(forCoverArt: coverArt, server: server)
            }
        }
        // Lyrics are best-effort and shouldn't block the queue.
        Task { await self.downloadLyrics(for: song) }

        if let continuation = pendingContinuations.removeValue(forKey: songId) {
            continuation.resume(returning: ())
        } else {
            // Completed without an awaiting caller (app was relaunched mid-transfer).
            cleanupQueueCounts()
        }
    }

    /// Failure/interruption path shared by the delegate callbacks.
    @MainActor
    private func handleCompletionError(songId: String, error: Error) {
        if let continuation = pendingContinuations.removeValue(forKey: songId) {
            continuation.resume(throwing: error)
            return
        }
        // No awaiting caller — update state directly.
        downloadProgress.removeValue(forKey: songId)
        activeDownloads.remove(songId)
        activeURLTasks.removeValue(forKey: songId)
        if let idx = queueItems.firstIndex(where: { $0.id == songId }) {
            if pausedIds.contains(songId) {
                queueItems[idx].state = .paused
            } else if (error as? URLError)?.code == .cancelled {
                queueItems[idx].state = .cancelled
            } else {
                queueItems[idx].state = .failed
                queueItems[idx].error = error.localizedDescription
            }
        }
        cancelledIds.remove(songId)
        cleanupQueueCounts()
    }

    /// Shared cleanup when a download is paused or cancelled (vs. genuinely failed).
    private func handleInterruptedDownload(_ song: Song) {
        let isPaused = pausedIds.contains(song.id)
        AppLogger.shared.log(isPaused ? "⏸ Download paused: \(song.title)" : "🚫 Download cancelled: \(song.title)")
        downloadProgress.removeValue(forKey: song.id)
        activeDownloads.remove(song.id)
        activeURLTasks.removeValue(forKey: song.id)
        cancelledIds.remove(song.id)
        if let idx = queueItems.firstIndex(where: { $0.id == song.id }) {
            queueItems[idx].state = isPaused ? .paused : .cancelled
        }
        cleanupQueueCounts()
    }

    private func cleanupQueueCounts() {
        if activeDownloads.isEmpty {
            currentDownloadTitle = nil
            currentDownloadAlbum = nil
            currentDownloadId = nil
            totalQueueCount = 0
            completedQueueCount = 0
        }
    }

    /// Resume ONLY the downloads parked automatically for lack of network
    /// (`restartWaitingDownloads`), leaving user-paused items alone. Called from
    /// ServerManager when the server becomes reachable again.
    @MainActor
    func resumeNetworkPausedDownloads() {
        guard !networkPausedIds.isEmpty else { return }
        let ids = networkPausedIds
        networkPausedIds.removeAll()
        let toResume = ids.filter { id in
            queueItems.contains { $0.id == id && $0.state == .paused }
        }
        guard !toResume.isEmpty else { return }
        AppLogger.shared.log("🔁 Auto-resuming \(toResume.count) network-paused download(s)")
        for id in toResume {
            resumeDownload(id)
        }
    }

    @MainActor
    func cancelDownload(_ songId: String) {
        cancelledIds.insert(songId)
        pausedIds.remove(songId)
        networkPausedIds.remove(songId)
        activeURLTasks[songId]?.cancel()
        activeURLTasks.removeValue(forKey: songId)
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        deleteResumeData(for: songId)
    }

    @MainActor
    func pauseDownload(_ songId: String) {
        guard activeDownloads.contains(songId) || queueItems.contains(where: { $0.id == songId && ($0.state == .downloading || $0.state == .waiting) }) else { return }
        pausedIds.insert(songId)
        networkPausedIds.remove(songId)  // explicit user pause — no auto-resume
        cancelledIds.insert(songId)  // tell the in-flight task to stop
        // Produce resume data so resuming continues from the current byte offset.
        if let task = activeURLTasks[songId] {
            task.cancel { [weak self] resumeData in
                guard let self, let resumeData else { return }
                self.saveResumeData(resumeData, for: songId)
            }
        }
        activeURLTasks.removeValue(forKey: songId)
        activeTasks[songId]?.cancel()
        activeTasks.removeValue(forKey: songId)
        // A waiting (not-yet-started) item has no in-flight task whose catch block would
        // mark it paused, so set the state here.
        if let idx = queueItems.firstIndex(where: { $0.id == songId }), queueItems[idx].state == .waiting {
            queueItems[idx].state = .paused
        }
        AppLogger.shared.log("⏸ pauseDownload: \(songId)")
    }

    @MainActor
    func resumeDownload(_ songId: String) {
        guard let item = queueItems.first(where: { $0.id == songId && $0.state == .paused }) else { return }
        isHalted = false
        pausedIds.remove(songId)
        networkPausedIds.remove(songId)
        cancelledIds.remove(songId)
        if let idx = queueItems.firstIndex(where: { $0.id == songId }) {
            queueItems[idx].state = .waiting
            // Keep the shown progress when resume data lets the transfer continue
            // mid-file; only a from-scratch restart goes back to zero.
            if !FileManager.default.fileExists(atPath: resumeDataURL(for: songId).path) {
                queueItems[idx].progress = 0
            }
            queueItems[idx].error = nil
        }
        let task = Task { await downloadSong(item.song) }
        activeTasks[songId] = task
        AppLogger.shared.log("▶️ resumeDownload: \(songId)")
    }

    @MainActor
    func pauseAllDownloads() {
        // Halt the batch drivers FIRST so they stop spawning the next song, then pause
        // everything already queued.
        isHalted = true
        let toPause = queueItems
            .filter { $0.state == .downloading || $0.state == .waiting }
            .map(\.id)
        AppLogger.shared.log("⏸ pauseAllDownloads: \(toPause.count) items")
        for id in toPause {
            pauseDownload(id)
        }
    }

    @MainActor
    func resumeAllDownloads() {
        isHalted = false
        let toResume = queueItems
            .filter { $0.state == .paused }
            .map(\.id)
        AppLogger.shared.log("▶️ resumeAllDownloads: \(toResume.count) items")
        for id in toResume {
            resumeDownload(id)
        }
    }

    @MainActor
    func cancelGroupDownload(_ groupId: String) {
        guard let songIds = activeGroupDownloads[groupId] else { return }
        AppLogger.shared.log("🚫 Cancelling group download: \(groupId) (\(songIds.count) songs)")
        for songId in songIds {
            cancelDownload(songId)
        }
        activeGroupDownloads.removeValue(forKey: groupId)
        groupDownloadCompleted.removeValue(forKey: groupId)
        groupDownloadTotal.removeValue(forKey: groupId)
    }

    @MainActor
    func retryDownload(_ song: Song) {
        // Remove from queue to re-add
        queueItems.removeAll { $0.id == song.id }
        cancelledIds.remove(song.id)
        let task = Task { await downloadSong(song) }
        activeTasks[song.id] = task
    }

    @MainActor
    func cancelAllDownloads() {
        AppLogger.shared.log("🛑 cancelAllDownloads: \(activeDownloads.count) active, \(queueItems.filter { $0.state == .paused }.count) paused")
        // Halt the batch drivers so they stop spawning new downloads.
        isHalted = true
        // Clear paused items first — Stop All means stop everything, and late delegate
        // callbacks must not re-mark items as .paused (handleCompletionError checks pausedIds).
        pausedIds.removeAll()
        networkPausedIds.removeAll()
        for id in activeDownloads {
            cancelledIds.insert(id)
        }
        for (_, task) in activeURLTasks {
            task.cancel()
        }
        activeURLTasks.removeAll()
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        activeDownloads.removeAll()
        downloadProgress.removeAll()
        activeGroupDownloads.removeAll()
        groupDownloadCompleted.removeAll()
        groupDownloadTotal.removeAll()
        // Mark anything still in flight, paused, or not-yet-started as cancelled so it doesn't linger
        for idx in queueItems.indices where queueItems[idx].state == .paused || queueItems[idx].state == .waiting || queueItems[idx].state == .downloading {
            queueItems[idx].state = .cancelled
        }
        // Stop All discards partial transfers entirely.
        for item in queueItems where item.state == .cancelled {
            deleteResumeData(for: item.id)
        }
        cleanupQueueCounts()
    }

    @MainActor
    func clearFinishedFromQueue() {
        queueItems.removeAll { $0.state == .completed || $0.state == .cancelled || $0.state == .failed }
    }

    /// - Parameter isBatchStart: `true` for a user-initiated batch (clears a prior
    ///   Pause/Stop All). Pass `false` when called as one step of a larger batch the
    ///   caller is already managing (e.g. the artist multi-album loop), so an in-progress
    ///   halt isn't accidentally cleared between albums.
    @MainActor
    func downloadAlbum(_ songs: [Song], groupId: String? = nil, isBatchStart: Bool = true) async {
        if isBatchStart {
            isHalted = false
            for song in songs { cancelledIds.remove(song.id); pausedIds.remove(song.id) }
        }
        guard hasSufficientDiskSpace() else {
            AppLogger.shared.log("❌ Album download blocked (low disk space): \(songs.count) songs")
            ToastManager.shared.show("Not enough free storage to download", icon: "exclamationmark.triangle.fill")
            return
        }
        let gid = groupId ?? UUID().uuidString
        AppLogger.shared.log("⬇️ Download album: \(songs.count) songs, group: \(gid)")
        let songIds = Set(songs.map { $0.id })
        activeGroupDownloads[gid] = songIds
        groupDownloadTotal[gid] = songs.count
        groupDownloadCompleted[gid] = 0
        totalQueueCount += songs.count
        // Enqueue the whole batch up-front so Pause All / Stop All (and the queue UI)
        // see every pending song, not just the one currently downloading.
        for song in songs where !isDownloaded(song.id) {
            if !queueItems.contains(where: { $0.id == song.id }) {
                queueItems.append(DownloadQueueItem(id: song.id, song: song, state: .waiting, progress: 0))
            }
        }
        for song in songs {
            // Halting stops the whole driver, not just the active item.
            if isHalted || activeGroupDownloads[gid] == nil { break }
            if cancelledIds.contains(song.id) || pausedIds.contains(song.id) { continue }
            await downloadSong(song, groupId: gid)
        }
        activeGroupDownloads.removeValue(forKey: gid)
    }

    func isDownloaded(_ songId: String) -> Bool {
        downloadedSongs.contains { $0.id == songId }
    }

    func allDownloaded(_ songIds: [String]) -> Bool {
        songIds.allSatisfy { isDownloaded($0) }
    }

    func localURL(for songId: String) -> URL? {
        guard let downloaded = downloadedSongs.first(where: { $0.id == songId }) else { return nil }
        return downloadsDirectory.appendingPathComponent(downloaded.localPath)
    }

    func deleteSong(_ songId: String) {
        guard let idx = downloadedSongs.firstIndex(where: { $0.id == songId }) else { return }
        let song = downloadedSongs[idx]
        AppLogger.shared.log("🗑 Delete download: \(song.song.title)")
        let fileURL = downloadsDirectory.appendingPathComponent(song.localPath)
        try? FileManager.default.removeItem(at: fileURL)
        downloadedSongs.remove(at: idx)
        // Remove the offline master only if no remaining download shares this artwork.
        if let coverArt = song.song.coverArt,
           !downloadedSongs.contains(where: { $0.song.coverArt == coverArt }) {
            ArtworkCache.shared.removeOfflineArtwork(forCoverArt: coverArt)
        }
        saveMetadata()
    }

    func deleteAll() {
        AppLogger.shared.log("🗑 Delete ALL downloads: \(downloadedSongs.count) songs")
        for song in downloadedSongs {
            let fileURL = downloadsDirectory.appendingPathComponent(song.localPath)
            try? FileManager.default.removeItem(at: fileURL)
            if let coverArt = song.song.coverArt {
                ArtworkCache.shared.removeOfflineArtwork(forCoverArt: coverArt)
            }
        }
        downloadedSongs.removeAll()
        saveMetadata()
    }

    /// Backfill permanent artwork for everything available offline — both downloaded
    /// songs AND streamed/cached songs (whose albums also appear in the offline library).
    /// Safe to call repeatedly; only fetches what's missing. Online only.
    @MainActor
    func ensureOfflineArtwork() async {
        guard let server = ServerManager.shared.currentServer else { return }
        var coverArts = Set(downloadedSongs.compactMap { $0.song.coverArt })
        coverArts.formUnion(AudioCacheManager.shared.getCachedSongs().compactMap { $0.coverArt })
        for coverArt in coverArts where !ArtworkCache.shared.hasOfflineArtwork(forCoverArt: coverArt) {
            await ArtworkCache.shared.cacheOfflineArtwork(forCoverArt: coverArt, server: server)
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var totalDownloadSize: String {
        Self.formatBytes(downloadedSongs.reduce(Int64(0)) { $0 + $1.fileSize })
    }

    // MARK: - Lyrics Download

    private func downloadLyrics(for song: Song) async {
        guard let artist = song.artist, !artist.isEmpty else { return }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: song.title),
            URLQueryItem(name: "album_name", value: song.album ?? ""),
            URLQueryItem(name: "duration", value: String(song.duration ?? 0))
        ]
        guard let url = components?.url else { return }
        do {
            var request = URLRequest(url: url)
            request.setValue("Aura/1.0.0 (https://github.com/adrbn)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let syncedLyrics = json?["syncedLyrics"] as? String, !syncedLyrics.isEmpty {
                let lrcFile = downloadsDirectory.appendingPathComponent("\(song.id).lrc")
                try syncedLyrics.write(to: lrcFile, atomically: true, encoding: .utf8)
                AppLogger.shared.log("📝 Downloaded synced lyrics for: \(song.title)")
            } else if let plainLyrics = json?["plainLyrics"] as? String, !plainLyrics.isEmpty {
                let lrcFile = downloadsDirectory.appendingPathComponent("\(song.id).lrc")
                try plainLyrics.write(to: lrcFile, atomically: true, encoding: .utf8)
                AppLogger.shared.log("📝 Downloaded plain lyrics for: \(song.title)")
            }
        } catch {
            // Lyrics download is best-effort, don't fail the song download
        }
    }

    // MARK: - Persistence

    /// Download metadata lives in JSON files, not UserDefaults — the full Song array
    /// can outgrow the ~4MB defaults limit, and a silent write failure there would
    /// make every download look lost (and get its file orphan-cleaned).
    private var metadataDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self.backupExcludedDirectory(support.appendingPathComponent("musika_download_meta"))
    }

    private var metadataFileURL: URL { metadataDirectory.appendingPathComponent("downloaded_songs.json") }
    private var queueFileURL: URL { metadataDirectory.appendingPathComponent("download_queue.json") }

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(downloadedSongs) {
            try? data.write(to: metadataFileURL, options: .atomic)
        }
    }

    private func loadMetadata() {
        let data: Data
        if let fileData = try? Data(contentsOf: metadataFileURL) {
            data = fileData
        } else if let legacy = UserDefaults.standard.data(forKey: metadataKey) {
            // One-time migration out of UserDefaults.
            try? legacy.write(to: metadataFileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: metadataKey)
            data = legacy
        } else {
            return
        }
        if let decoded = try? JSONDecoder().decode([DownloadedSong].self, from: data) {
            downloadedSongs = decoded
        }
    }

    private struct PersistedQueueItem: Codable {
        let song: Song
        let state: String
    }

    /// Persist unfinished queue items so a crash or force-quit doesn't lose them.
    private func saveQueue() {
        let unfinished = queueItems
            .filter { $0.state == .waiting || $0.state == .downloading || $0.state == .paused || $0.state == .failed }
            .map { PersistedQueueItem(song: $0.song, state: $0.state.rawValue) }
        if let data = try? JSONEncoder().encode(unfinished) {
            try? data.write(to: queueFileURL, options: .atomic)
        }
    }

    /// Restore the unfinished queue from the previous run. Items that were in flight
    /// come back as `.paused` so the user can resume them from the download manager
    /// (reattachBackgroundSession flips them back to `.downloading` if the transfer
    /// actually survived in the background session). Items still `.waiting` — the rest
    /// of a killed batch — keep that state so restartWaitingDownloads picks them up.
    private func restoreQueue() {
        let data: Data
        if let fileData = try? Data(contentsOf: queueFileURL) {
            data = fileData
        } else if let legacy = UserDefaults.standard.data(forKey: queueKey) {
            // One-time migration out of UserDefaults.
            try? legacy.write(to: queueFileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: queueKey)
            data = legacy
        } else {
            return
        }
        guard let items = try? JSONDecoder().decode([PersistedQueueItem].self, from: data),
              !items.isEmpty else { return }
        var restored = 0
        for item in items where !isDownloaded(item.song.id) && !queueItems.contains(where: { $0.id == item.song.id }) {
            rememberSong(item.song)
            let state: DownloadItemState
            switch item.state {
            case DownloadItemState.failed.rawValue: state = .failed
            case DownloadItemState.waiting.rawValue: state = .waiting
            default: state = .paused
            }
            if state == .paused { pausedIds.insert(item.song.id) }
            queueItems.append(DownloadQueueItem(id: item.song.id, song: item.song, state: state, progress: 0))
            restored += 1
        }
        if restored > 0 {
            AppLogger.shared.log("🔁 Restored \(restored) interrupted download(s) from last session")
        }
    }

    /// Delete files in the Downloads directory that no metadata references —
    /// leftovers from a crash between file write and metadata save.
    private func cleanupOrphanedFiles() {
        let fm = FileManager.default
        let referenced = Set(downloadedSongs.map(\.localPath))
        let downloadedIds = Set(downloadedSongs.map(\.id))
        guard let files = try? fm.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            if file.pathExtension == "lrc" {
                let songId = String(name.dropLast(".lrc".count))
                if !downloadedIds.contains(songId) {
                    AppLogger.shared.log("🧹 Removing orphaned lyrics file: \(name)")
                    try? fm.removeItem(at: file)
                }
            } else if !referenced.contains(name) {
                AppLogger.shared.log("🧹 Removing orphaned download file: \(name)")
                try? fm.removeItem(at: file)
            }
        }
    }
}

// MARK: - Background URLSession delegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let songId = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.downloadProgress[songId] = value
            if let idx = self.queueItems.firstIndex(where: { $0.id == songId }) {
                self.queueItems[idx].progress = value
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let songId = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            AppLogger.shared.log("❌ Download HTTP \(http.statusCode) for \(songId)")
            Task { @MainActor in self.handleCompletionError(songId: songId, error: URLError(.badServerResponse)) }
            return
        }
        // The temp file disappears when this method returns — move it synchronously.
        let ext = knownSong(songId)?.suffix ?? "mp3"
        let destination = downloadsDirectory.appendingPathComponent("\(songId).\(ext)")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            Task { @MainActor in
                self.finalizeDownload(songId: songId, filename: destination.lastPathComponent, fileSize: size)
            }
        } catch {
            AppLogger.shared.log("❌ Could not move downloaded file for \(songId): \(error.localizedDescription)")
            Task { @MainActor in self.handleCompletionError(songId: songId, error: error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let songId = task.taskDescription, let error else { return }
        // Network loss / pause hand us resume data — keep it so the next attempt
        // continues from the same byte offset instead of restarting.
        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            saveResumeData(resumeData, for: songId)
        }
        Task { @MainActor in
            self.handleCompletionError(songId: songId, error: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            AppDelegate.backgroundSessionCompletionHandler?()
            AppDelegate.backgroundSessionCompletionHandler = nil
        }
    }
}
