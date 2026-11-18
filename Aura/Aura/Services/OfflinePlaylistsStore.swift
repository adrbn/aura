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
    /// The server's last-modified stamp: a playlist whose stamp hasn't moved isn't fetched again.
    var changed: String? = nil
    var created: String? = nil

    var asPlaylist: Playlist {
        Playlist(id: id, name: name, songCount: songCount, duration: nil, coverArt: coverArt, owner: nil,
                 created: created, changed: changed, comment: nil, public: nil)
    }
}

/// Persists playlist snapshots to disk (Application Support, backup-excluded, JSON)
/// so OfflineLibraryView can show playlists whose songs are downloaded or cached.
/// Refreshed opportunistically after PlaylistsView loads playlists online.
@MainActor
@Observable
final class OfflinePlaylistsStore {
    static let shared = OfflinePlaylistsStore()

    private(set) var playlists: [OfflinePlaylistSnapshot] = [] {
        didSet { rebuildIndex() }
    }
    /// songId → the playlists holding it, so membership is a lookup, not a scan.
    private var index: [String: Set<String>] = [:]

    func playlistIds(containing songId: String) -> Set<String> { index[songId] ?? [] }

    private func rebuildIndex() {
        var built: [String: Set<String>] = [:]
        for playlist in playlists {
            for song in playlist.songs { built[song.id, default: []].insert(playlist.id) }
        }
        index = built
    }

    private var isRefreshing = false
    private var lastRefresh: Date?
    /// Snapshots are metadata, not user data — don't hammer the server with N+1
    /// playlist fetches on every visit to the Playlists tab.
    /// Only playlists whose `changed` stamp moved are fetched, so a refresh is cheap.
    private let refreshInterval: TimeInterval = 60

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
        rebuildIndex() // didSet doesn't run during init
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
    /// Asks the server for the playlist list, then refreshes from it.
    func refreshFromServer() {
        guard !AppSettings.shared.offlineMode, ServerManager.shared.hasNetwork,
              let server = ServerManager.shared.currentServer else { return }
        Task {
            guard let list = try? await SubsonicClient.shared.getPlaylists(server: server) else { return }
            var seen = Set<String>()
            refresh(from: list.filter { seen.insert($0.id).inserted })
        }
    }

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
            let saved = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for playlist in serverPlaylists {
                if let kept = saved[playlist.id], kept.changed != nil, kept.changed == playlist.changed {
                    snapshots.append(kept)
                    continue
                }
                guard let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id) else { continue }
                let songs = detail.entry ?? []
                snapshots.append(OfflinePlaylistSnapshot(
                    id: playlist.id,
                    name: playlist.name,
                    songCount: songs.count,
                    coverArt: playlist.coverArt,
                    songs: songs,
                    changed: playlist.changed,
                    created: playlist.created
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
