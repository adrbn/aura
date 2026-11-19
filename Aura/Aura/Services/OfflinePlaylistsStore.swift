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

    /// An edit kept for the server (`PlaylistEditQueue`) shows in the saved copy at once. The
    /// stamp goes, so the server's copy is fetched again once the edit has landed there.
    func applyLocally(_ playlistId: String, _ edit: ([Song]) -> [Song]) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        let old = playlists[i]
        let songs = edit(old.songs)
        playlists[i] = OfflinePlaylistSnapshot(id: old.id, name: old.name, songCount: songs.count,
                                               coverArt: old.coverArt, songs: songs,
                                               changed: nil, created: old.created)
        persist()
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
            let saved = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Unchanged playlists are kept as saved; the others are fetched a few at a time
            // (the server's worker pool is small) rather than one after another.
            var fetched: [String: OfflinePlaylistSnapshot] = [:]
            // A playlist with edits still waiting keeps its saved copy, which already shows them;
            // the server's would undo them on screen until they're sent.
            let waiting = PlaylistEditQueue.shared.pendingPlaylistIds
            let stale = serverPlaylists.filter { p in
                if waiting.contains(p.id), saved[p.id] != nil { return false }
                guard let kept = saved[p.id], kept.changed != nil, kept.changed == p.changed else { return true }
                return false
            }
            for start in stride(from: 0, to: stale.count, by: 6) {
                let batch = stale[start..<min(start + 6, stale.count)]
                await withTaskGroup(of: OfflinePlaylistSnapshot?.self) { group in
                    for playlist in batch {
                        group.addTask {
                            guard let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
                            else { return nil }
                            let songs = detail.entry ?? []
                            return OfflinePlaylistSnapshot(id: playlist.id, name: playlist.name, songCount: songs.count,
                                                           coverArt: playlist.coverArt, songs: songs,
                                                           changed: playlist.changed, created: playlist.created)
                        }
                    }
                    for await snapshot in group { if let snapshot { fetched[snapshot.id] = snapshot } }
                }
            }
            // A playlist that failed to load keeps its saved copy rather than vanishing.
            let snapshots = serverPlaylists.compactMap { fetched[$0.id] ?? saved[$0.id] }
            guard !snapshots.isEmpty else { return }
            playlists = snapshots
            lastRefresh = Date()
            persist()
            AppLogger.shared.log("📋 Offline playlist snapshots refreshed: \(snapshots.count) playlists")
        }
    }
}
