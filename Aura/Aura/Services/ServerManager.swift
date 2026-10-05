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
    /// Cellular data or a personal hotspot: streams at the cellular quality when one is set.
    private(set) var isExpensiveNetwork = false
    /// False until the monitor has reported the device's network once.
    private var pathKnown = false
    /// How long the network has to stay gone, while the app is in use, before offline mode
    /// takes over — long enough that a tunnel or a lift doesn't flip the whole app.
    private let lostNetworkGrace: TimeInterval = 10
    private var lostNetworkTask: Task<Void, Never>?

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
        #if DEBUG
        // tools/app-store-shots/shoot.sh points a fresh install at a demo server, past onboarding:
        // `-shotServer <url> -shotUser <name> -shotPassword <password>`.
        let defaults = UserDefaults.standard
        if servers.isEmpty, let url = defaults.string(forKey: "shotServer") {
            addServer(ServerConfig(url: url, username: defaults.string(forKey: "shotUser") ?? "",
                                   password: defaults.string(forKey: "shotPassword") ?? "", friendlyName: "Demo"))
            defaults.set(true, forKey: "hasCompletedOnboarding")
        }
        #endif
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

    @MainActor
    func removeServer(_ server: ServerConfig) {
        AppLogger.shared.log("🖥 removeServer: \(server.friendlyName)")
        KeychainHelper.delete(for: server.id.uuidString)
        // The server's generated mixes are only meaningful against it, so they go too —
        // otherwise they'd sit in defaults forever under an id nothing can reach again.
        MixCache().removeAll(for: server.id)
        #if os(iOS)
        RadarStore.removeAll(for: server.id)
        #endif
        servers.removeAll { $0.id == server.id }
        saveServers()
        if currentServer?.id == server.id {
            currentServer = servers.first
            saveCurrentServer()
            // Same reasoning as `selectServer`: the shelf must follow the active server
            // immediately, not one refresh later.
            MixGenerator.shared.restoreForServer(currentServer?.id)
        }
    }

    @MainActor
    func selectServer(_ server: ServerConfig) {
        guard server.id != currentServer?.id else { return }
        AppLogger.shared.log("🖥 selectServer: \(server.friendlyName)")
        // Save the outgoing server's playback + tear down the (now-unreachable) live track,
        // switch, then resume the incoming server's own saved session (paused).
        AudioPlayer.shared.prepareForServerSwitch()
        currentServer = server
        saveCurrentServer()
        AudioPlayer.shared.restoreForCurrentServer()
        // Mixes are built from one library and are just as unreachable across a switch as
        // the playing track. Swap them synchronously, here, so Home never renders a frame
        // of the previous server's songs before its own `onChange` gets to refresh.
        MixGenerator.shared.restoreForServer(server.id)
    }

    /// Pings the server and records the answer. True when it answered.
    @discardableResult
    func testConnection(timeout: TimeInterval? = nil) async -> Bool {
        guard let server = currentServer else {
            connectionError = "No server configured"
            isConnected = false
            AppLogger.shared.log("❌ testConnection: no server configured")
            return false
        }
        // Short-circuit if device has no network at all — saves a 30s timeout per failure
        if !hasNetwork {
            await MainActor.run {
                self.isConnected = false
                self.connectionError = "No network connection"
                self.consecutiveFailures += 1
                self.enableAutoOfflineIfNeeded()
            }
            return false
        }
        await chooseAddress(for: server)
        AppLogger.shared.log("🖥 testConnection: \(server.baseURL)")
        do {
            let ok = try await SubsonicClient.shared.ping(server: server, timeout: timeout)
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
                        self.goBackOnline(manual: false)
                        ToastManager.shared.show(String(localized: "Back online"), icon: "wifi")
                        AppLogger.shared.log("🟢 Server back online — auto-resumed online mode")
                    }
                    ScrobbleQueue.shared.flush()
                    SongRatings.shared.flush()
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
            return ok
        } catch is CancellationError {
            AppLogger.shared.log("⚠️ testConnection cancelled (view lifecycle)")
            return false
        } catch let error as URLError where error.code == .cancelled {
            AppLogger.shared.log("⚠️ testConnection URL request cancelled")
            return false
        } catch {
            await MainActor.run {
                self.isConnected = false
                self.connectionError = error.localizedDescription
                self.consecutiveFailures += 1
                self.enableAutoOfflineIfNeeded()
            }
            AppLogger.shared.log("❌ testConnection error: \(error.localizedDescription)")
            return false
        }
    }

    /// Uses the server's home address while it answers within two seconds, its main
    /// address otherwise. Checked on every connection test, so leaving home Wi-Fi switches
    /// back at the next network change.
    private func chooseAddress(for server: ServerConfig) async {
        guard let local = server.localURL, !local.isEmpty else { return }
        var probe = server
        probe.url = local
        probe.localURL = nil
        let reachable = (try? await SubsonicClient.shared.ping(server: probe, timeout: 2)) == true
        if reachable != ServerAddress.isLocal(server.id) {
            AppLogger.shared.log("🏠 Server address → \(reachable ? "home" : "main")")
        }
        ServerAddress.setLocal(reachable, for: server.id)
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
        guard consecutiveFailures >= autoOfflineThreshold else { return }
        goOfflineAutomatically(announce: true)
    }

    /// Offline mode, switched on because the server can't be reached — and so switched off
    /// again by itself once it can. Only with something downloaded: offline mode shows the
    /// downloads, and with none it would be an empty screen in place of the error states.
    private func goOfflineAutomatically(announce: Bool) {
        guard !AppSettings.shared.offlineMode, !DownloadManager.shared.downloadedSongs.isEmpty else { return }
        AppSettings.shared.offlineMode = true
        AppSettings.shared.save()
        wasAutoOffline = true
        if announce { ToastManager.shared.show(String(localized: "Switched to offline mode"), icon: "wifi.slash") }
        AppLogger.shared.log("📴 Offline mode — \(hasNetwork ? "server unreachable" : "no network") (\(consecutiveFailures) failures)")
    }

    // MARK: - Choosing the Mode When the App Opens

    /// True while `settleModeOnOpen` runs, so reopening twice in quick succession can't
    /// start a second check racing the first.
    private var isSettlingMode = false
    /// How long each ping made on opening waits. Short, because the app is deciding which
    /// face to show; a server that takes longer than this to answer a ping isn't one to
    /// browse anyway.
    private let openCheckTimeout: TimeInterval = 5

    /// On launch and on every return to the app: online if the server answers, offline if
    /// it doesn't — unless the reader chose offline by hand, which holds until they leave it.
    ///
    /// Opening used to trust the saved mode. Offline chosen by hand never lifted by itself;
    /// offline switched on automatically lifted only if the first ping, fired before the
    /// network (or the VPN the server sits behind) was up, happened to succeed, and then
    /// waited out the backoff; and a phone with no network at all stayed "online" with an
    /// error on every screen, because the checks that count failures skip themselves when
    /// there's no network. The mode only changes on opening: while the app is in use, the
    /// existing rules stand, so a hand-picked offline mode holds until the next opening.
    @MainActor
    func settleModeOnOpen() async {
        guard currentServer != nil, !isSettlingMode else { return }
        isSettlingMode = true
        defer { isSettlingMode = false }

        await waitForFirstPath()
        var reachable = false
        if hasNetwork {
            reachable = await testConnection(timeout: openCheckTimeout)
            if !reachable, hasNetwork {
                // The first request after a wake often fails while Wi-Fi or the VPN comes
                // back up; one more try, a moment later, before calling it offline.
                try? await Task.sleep(for: .seconds(1.5))
                reachable = await testConnection(timeout: openCheckTimeout)
            }
        }
        if reachable {
            // Only an offline mode the app chose lifts by itself: one the reader picked is
            // theirs — on a plane, saving data — and reopening the app isn't changing it.
            if AppSettings.shared.offlineMode && wasAutoOffline { goBackOnline(manual: false) }
        } else {
            goOfflineAutomatically(announce: false)
        }
        AppLogger.shared.log("🔌 Opened \(AppSettings.shared.offlineMode ? "offline" : "online") — server \(reachable ? "answered" : "unreachable")")
    }

    /// The path monitor answers within moments of starting; until it has, `hasNetwork` is
    /// only its optimistic default.
    @MainActor
    private func waitForFirstPath() async {
        var waits = 0
        while !pathKnown && waits < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            waits += 1
        }
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
                self.isExpensiveNetwork = path.isExpensive
                self.pathKnown = true

                if !isReachable {
                    // Network gone — short-circuit ping logic
                    self.isConnected = false
                    self.connectionError = "No network connection"
                    AppLogger.shared.log("📡 Network unavailable")
                    self.goOfflineIfNetworkStaysLost()
                    return
                }
                self.lostNetworkTask?.cancel()

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

    /// Without a network the periodic checks skip themselves, so no failure is ever counted
    /// and the failure rule can't fire: the app stayed "online" with an error on every
    /// screen. A network that stays gone switches it here instead; the monitor's next
    /// satisfied path pings, and the ping brings it back online.
    private func goOfflineIfNetworkStaysLost() {
        lostNetworkTask?.cancel()
        lostNetworkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.lostNetworkGrace ?? 10))
            guard let self, !Task.isCancelled, !self.hasNetwork else { return }
            if let manualDate = self.manualOnlineDate,
               Date().timeIntervalSince(manualDate) < self.manualOnlineGracePeriod { return }
            self.goOfflineAutomatically(announce: true)
        }
    }

    /// Offline mode because the reader asked for it: it stays until they leave it, the app
    /// reopening or the server answering included.
    func goOfflineManually() {
        AppSettings.shared.offlineMode = true
        AppSettings.shared.save()
        wasAutoOffline = false
        AppLogger.shared.log("📴 Offline mode — chosen")
    }

    /// Leaves offline mode and resets state. `manual` is the user's own choice, which holds
    /// off automatic offline for a while; the app coming back online by itself doesn't.
    func goBackOnline(manual: Bool = true) {
        AppSettings.shared.offlineMode = false
        AppSettings.shared.save()
        wasAutoOffline = false
        consecutiveFailures = 0
        if manual { manualOnlineDate = Date() }
        // Offline mode short-circuits artwork fetches to the downloaded-only master, so
        // anything not downloaded is showing a placeholder. Leaving offline mode has to
        // let those retry — nothing else will.
        ArtworkRetry.shared.requestRetry()
        AppLogger.shared.log("🟢 Back online")
        ScrobbleQueue.shared.flush()
        SongRatings.shared.flush()
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

// MARK: - Song Ratings

/// Ratings set in Aura. A song carries the server's rating; one set here shows at once,
/// and waits in the pending list until the server has taken it — offline, until it is
/// back.
@Observable
final class SongRatings {
    static let shared = SongRatings()
    private let pendingKey = "aura_pending_ratings"
    private var local: [String: Int] = [:]
    @ObservationIgnored private var isFlushing = false

    func rating(for song: Song) -> Int { local[song.id] ?? song.userRating ?? 0 }

    /// `rating` 0 clears it.
    func set(_ rating: Int, for song: Song) {
        guard !song.isPreview else { return }
        local[song.id] = rating
        var pending = loadPending()
        pending[song.id] = rating
        savePending(pending)
        flush()
    }

    func flush() {
        guard !isFlushing, let server = ServerManager.shared.currentServer,
              !AppSettings.shared.offlineMode else { return }
        let pending = loadPending()
        guard !pending.isEmpty else { return }
        isFlushing = true
        Task { @MainActor in
            defer { isFlushing = false }
            for (id, rating) in pending {
                do {
                    try await SubsonicClient.shared.setRating(server: server, id: id, rating: rating)
                } catch {
                    AppLogger.shared.log("⭐️ Rating kept for later: \(error.localizedDescription)")
                    return
                }
                // A newer rating set meanwhile stays pending.
                var now = loadPending()
                if now[id] == rating { now[id] = nil; savePending(now) }
            }
        }
    }

    private func loadPending() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Int] ?? [:]
    }

    private func savePending(_ pending: [String: Int]) {
        UserDefaults.standard.set(pending, forKey: pendingKey)
    }
}

extension AppSettings {
    /// The quality to stream at now: the cellular one on cellular data, when it is set.
    var effectiveStreamingQuality: StreamingQuality {
        if let cellularQuality, ServerManager.shared.isExpensiveNetwork { return cellularQuality }
        return streamingQuality
    }
}

