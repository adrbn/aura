import Foundation

/// A server playlist snapshotted for offline browsing: identity, display metadata,
/// and the full member Songs (playlists are small — keeping the structs makes the
/// offline library self-sufficient without any server round trip).
struct OfflinePlaylistSnapshot: Codable, Identifiable {
    let id: String
    let name: String
    let songCount: Int
    let coverArt: String?
    let songs: [Song]
}

/// Persists playlist snapshots to disk (Application Support, backup-excluded, JSON)
/// so OfflineLibraryView can show playlists whose songs are downloaded or cached.
/// Refreshed opportunistically after PlaylistsView loads playlists online.
@MainActor
@Observable
final class OfflinePlaylistsStore {
    static let shared = OfflinePlaylistsStore()

    private(set) var playlists: [OfflinePlaylistSnapshot] = []

    private var isRefreshing = false
    private var lastRefresh: Date?
    /// Snapshots are metadata, not user data — don't hammer the server with N+1
    /// playlist fetches on every visit to the Playlists tab.
    private let refreshInterval: TimeInterval = 900

    private var storeDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("musika_offline_playlists")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }

    private var storeFileURL: URL {
        storeDirectory.appendingPathComponent("playlists.json")
    }

    private init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeFileURL),
              let decoded = try? JSONDecoder().decode([OfflinePlaylistSnapshot].self, from: data) else { return }
        playlists = decoded
    }

    private func persist() {
        let snapshot = playlists
        let url = storeFileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Refresh snapshots from a freshly-fetched playlist list, pulling each
    /// playlist's songs. Fire-and-forget, throttled, online only.
    func refresh(from serverPlaylists: [Playlist]) {
        guard !serverPlaylists.isEmpty,
              !isRefreshing,
              !AppSettings.shared.offlineMode,
              ServerManager.shared.hasNetwork,
              let server = ServerManager.shared.currentServer else { return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < refreshInterval { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            var snapshots: [OfflinePlaylistSnapshot] = []
            for playlist in serverPlaylists {
                guard let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id) else { continue }
                let songs = detail.entry ?? []
                snapshots.append(OfflinePlaylistSnapshot(
                    id: playlist.id,
                    name: playlist.name,
                    songCount: songs.count,
                    coverArt: playlist.coverArt,
                    songs: songs
                ))
            }
            guard !snapshots.isEmpty else { return }
            playlists = snapshots
            lastRefresh = Date()
            persist()
            AppLogger.shared.log("📋 Offline playlist snapshots refreshed: \(snapshots.count) playlists")
        }
    }
}
