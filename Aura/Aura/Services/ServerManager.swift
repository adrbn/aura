import Foundation
import SwiftUI
import Network

@Observable
final class ServerManager {
    static let shared = ServerManager()

    var servers: [ServerConfig] = []
    var currentServer: ServerConfig?
    var isConnected = false
    var connectionError: String?
    /// True when the device has any network path available (WiFi/cellular/wired)
    var hasNetwork = true
    /// True when the app automatically switched to offline mode due to server being unreachable
    /// True when offline mode was switched on automatically (server unreachable) rather
    /// than chosen by the user. MUST persist: `offlineMode` itself survives relaunch, so a
    /// memory-only flag reset to false on launch and the "return online by itself" rule
    /// (`wasAutoOffline && offlineMode`) could never fire again — the app stayed stuck in
    /// offline mode forever even with the server plainly reachable.
    var wasAutoOffline = UserDefaults.standard.bool(forKey: "musika_was_auto_offline") {
        didSet { UserDefaults.standard.set(wasAutoOffline, forKey: "musika_was_auto_offline") }
    }
    /// Counts consecutive connection failures before auto-offline kicks in
    private var consecutiveFailures = 0
    /// Number of failures required before auto-switching to offline
    private let autoOfflineThreshold = 3
    /// Timestamp when user manually went online — suppresses auto-offline for a grace period
    private var manualOnlineDate: Date?

    private let serversKey = "musika_servers"
    private let currentServerKey = "musika_current_server"
    private var connectivityTimer: Timer?

    /// Network path monitor — fires on WiFi/cellular/airplane changes (instant, no polling)
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "musika.pathmonitor")
    private var lastPathStatus: NWPath.Status = .satisfied

    /// Polling interval grows exponentially while server is unreachable: 30s → 60s → 120s → 300s (max)
    private let baseInterval: TimeInterval = 30
    private let maxInterval: TimeInterval = 300

    init() {
        loadServers()
        startPathMonitoring()
    }

    deinit {
        pathMonitor.cancel()
        connectivityTimer?.invalidate()
    }

    func loadServers() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = decoded
        }
        if let data = UserDefaults.standard.data(forKey: currentServerKey),
           let decoded = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            currentServer = decoded
        }
    }

    func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
    }

    func saveCurrentServer() {
        if let data = try? JSONEncoder().encode(currentServer) {
            UserDefaults.standard.set(data, forKey: currentServerKey)
        }
    }

    func addServer(_ server: ServerConfig) {
        AppLogger.shared.log("🖥 addServer: \(server.friendlyName)")
        servers.append(server)
        saveServers()
        if currentServer == nil {
            currentServer = server
            saveCurrentServer()
        }
    }

    func removeServer(_ server: ServerConfig) {
        AppLogger.shared.log("🖥 removeServer: \(server.friendlyName)")
        KeychainHelper.delete(for: server.id.uuidString)
        servers.removeAll { $0.id == server.id }
        saveServers()
        if currentServer?.id == server.id {
            currentServer = servers.first
            saveCurrentServer()
        }
    }

    func selectServer(_ server: ServerConfig) {
        guard server.id != currentServer?.id else { return }
        AppLogger.shared.log("🖥 selectServer: \(server.friendlyName)")
        // Save the outgoing server's playback + tear down the (now-unreachable) live track,
        // switch, then resume the incoming server's own saved session (paused).
        AudioPlayer.shared.prepareForServerSwitch()
        currentServer = server
        saveCurrentServer()
        AudioPlayer.shared.restoreForCurrentServer()
    }

    func testConnection() async {
        guard let server = currentServer else {
            connectionError = "No server configured"
            isConnected = false
            AppLogger.shared.log("❌ testConnection: no server configured")
            return
        }
        // Short-circuit if device has no network at all — saves a 30s timeout per failure
        if !hasNetwork {
            await MainActor.run {
                self.isConnected = false
                self.connectionError = "No network connection"
                self.consecutiveFailures += 1
                self.enableAutoOfflineIfNeeded()
            }
            return
        }
        AppLogger.shared.log("🖥 testConnection: \(server.baseURL)")
        do {
            let ok = try await SubsonicClient.shared.ping(server: server)
            await MainActor.run {
                let wasConnected = self.isConnected
                self.isConnected = ok
                self.connectionError = ok ? nil : "Server returned error"

                if ok {
                    self.consecutiveFailures = 0
                    if !wasConnected {
                        // Server reachable again — artwork that fell back to a placeholder
                        // while offline is never retried on its own (the cover id, and so
                        // the task id, never changes). Ask those views to try once more.
                        ArtworkRetry.shared.requestRetry()
                    }
                    if self.wasAutoOffline && AppSettings.shared.offlineMode {
                        // Offline mode was enabled automatically — leave it automatically
                        // too. Manual offline (user toggle) is never overridden.
                        self.goBackOnline()
                        ToastManager.shared.show("Back online", icon: "wifi")
                        AppLogger.shared.log("🟢 Server back online — auto-resumed online mode")
                    }
                    ScrobbleQueue.shared.flush()
                    // Server reachable again — restart downloads that were parked
                    // for lack of network (never user-paused ones).
                    if !AppSettings.shared.offlineMode {
                        DownloadManager.shared.resumeNetworkPausedDownloads()
                    }
                } else {
                    self.consecutiveFailures += 1
                    self.enableAutoOfflineIfNeeded()
                }
            }
            AppLogger.shared.log("🖥 testConnection: \(ok ? "connected" : "failed")")
        } catch is CancellationError {
            AppLogger.shared.log("⚠️ testConnection cancelled (view lifecycle)")
        } catch let error as URLError where error.code == .cancelled {
            AppLogger.shared.log("⚠️ testConnection URL request cancelled")
        } catch {
            await MainActor.run {
                self.isConnected = false
                self.connectionError = error.localizedDescription
                self.consecutiveFailures += 1
                self.enableAutoOfflineIfNeeded()
            }
            AppLogger.shared.log("❌ testConnection error: \(error.localizedDescription)")
        }
    }

    /// Grace period after the user manually goes online during which auto-offline
    /// stays suppressed — respects an explicit "I want to be online" choice.
    private let manualOnlineGracePeriod: TimeInterval = 600

    /// Auto-enable offline mode when server is unreachable and downloads exist
    private func enableAutoOfflineIfNeeded() {
        // Don't auto-offline within 10 minutes of user manually going online
        if let manualDate = manualOnlineDate, Date().timeIntervalSince(manualDate) < manualOnlineGracePeriod {
            return
        }
        guard !AppSettings.shared.offlineMode,
              !DownloadManager.shared.downloadedSongs.isEmpty,
              consecutiveFailures >= autoOfflineThreshold else { return }
        AppSettings.shared.offlineMode = true
        AppSettings.shared.save()
        wasAutoOffline = true
        ToastManager.shared.show("Switched to offline mode", icon: "wifi.slash")
        AppLogger.shared.log("📴 Auto-enabled offline mode — server unreachable (\(consecutiveFailures) failures)")
    }

    // MARK: - Network Path Monitoring

    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isReachable = path.status == .satisfied
            let prev = self.lastPathStatus
            self.lastPathStatus = path.status

            DispatchQueue.main.async {
                self.hasNetwork = isReachable

                if !isReachable {
                    // Network gone — short-circuit ping logic
                    self.isConnected = false
                    self.connectionError = "No network connection"
                    AppLogger.shared.log("📡 Network unavailable")
                    return
                }

                // Network came back (or first satisfied) — re-test the server immediately
                if prev != .satisfied {
                    AppLogger.shared.log("📡 Network restored — testing server")
                }
                Task { await self.testConnection() }

                // Restart timer with base interval after a state change
                if self.connectivityTimer != nil {
                    self.startMonitoring()
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Leaves offline mode (user action or automatic reconnection) and resets state
    func goBackOnline() {
        AppSettings.shared.offlineMode = false
        AppSettings.shared.save()
        wasAutoOffline = false
        consecutiveFailures = 0
        manualOnlineDate = Date()
        // Offline mode short-circuits artwork fetches to the downloaded-only master, so
        // anything not downloaded is showing a placeholder. Leaving offline mode has to
        // let those retry — nothing else will.
        ArtworkRetry.shared.requestRetry()
        AppLogger.shared.log("🟢 Back online")
        ScrobbleQueue.shared.flush()
    }

    // MARK: - Periodic Connectivity Check (with exponential backoff while failing)

    func startMonitoring() {
        stopMonitoring()
        scheduleNextCheck()
    }

    func stopMonitoring() {
        connectivityTimer?.invalidate()
        connectivityTimer = nil
    }

    /// Schedule the next ping with backoff based on consecutiveFailures.
    /// 0 failures → 30s, 1 → 60s, 2 → 120s, 3+ → 300s (capped).
    private func scheduleNextCheck() {
        let multiplier = pow(2.0, Double(min(consecutiveFailures, 4)))
        let interval = min(baseInterval * multiplier, maxInterval)
        connectivityTimer?.invalidate()
        connectivityTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.hasNetwork {
                    await self.testConnection()
                }
                self.scheduleNextCheck()
            }
        }
    }

    var hasServer: Bool { currentServer != nil }
}

// MARK: - Offline Scrobble Queue

final class ScrobbleQueue {
    static let shared = ScrobbleQueue()
    private let key = "musika_scrobble_queue"
    private let lock = NSLock()
    private var isFlushing = false

    func enqueue(songId: String) {
        lock.lock()
        defer { lock.unlock() }
        var queue = load()
        queue.append(songId)
        save(queue)
        AppLogger.shared.log("📝 Scrobble queued offline: \(songId) (total: \(queue.count))")
    }

    /// Entries stay persisted until their individual send succeeds — a crash
    /// mid-flush loses nothing (at worst the in-flight scrobble is sent twice).
    func flush() {
        lock.lock()
        guard !isFlushing else { lock.unlock(); return }
        let queue = load()
        guard !queue.isEmpty else { lock.unlock(); return }
        guard let server = ServerManager.shared.currentServer else { lock.unlock(); return }
        isFlushing = true
        lock.unlock()

        AppLogger.shared.log("📤 Flushing \(queue.count) offline scrobbles")
        Task {
            var sent = 0
            for songId in queue {
                do {
                    try await SubsonicClient.shared.scrobble(server: server, id: songId)
                    // Success — now remove this entry from the persisted queue.
                    self.removeFirstOccurrence(of: songId)
                    sent += 1
                } catch {
                    // Server unreachable again — stop; survivors stay persisted
                    // and the next flush picks them up.
                    break
                }
            }
            AppLogger.shared.log("📤 Scrobble flush done: \(sent)/\(queue.count) sent")
            self.lock.lock()
            self.isFlushing = false
            self.lock.unlock()
        }
    }

    /// Drop a single occurrence (duplicates are legitimate — same song played twice
    /// offline) while holding the lock so concurrent enqueues aren't clobbered.
    private func removeFirstOccurrence(of songId: String) {
        lock.lock()
        defer { lock.unlock() }
        var queue = load()
        if let idx = queue.firstIndex(of: songId) {
            queue.remove(at: idx)
            save(queue)
        }
    }

    private func load() -> [String] {
        (UserDefaults.standard.stringArray(forKey: key)) ?? []
    }

    private func save(_ queue: [String]) {
        UserDefaults.standard.set(queue, forKey: key)
    }
}
