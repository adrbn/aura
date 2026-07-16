import Foundation

/// Pre-fetches which playlists contain the currently playing song.
/// Triggered when a new song starts playing in NowPlayingView, so data is ready
/// by the time the user opens "Add to Playlist".
@Observable
final class PlaylistMembershipCache {
    static let shared = PlaylistMembershipCache()

    /// songId → set of playlistIds that contain it
    private(set) var cache: [String: Set<String>] = [:]

    /// Whether a fetch is currently in progress for a given songId
    private(set) var loadingSongId: String?

    /// All playlists (cached from last fetch)
    private(set) var playlists: [String] = [] // playlist IDs

    private var currentTask: Task<Void, Never>?

    /// Call this when the current song changes — kicks off background detection
    func preloadMembership(for songId: String) {
        // No point firing N+1 playlist fetches without a reachable server
        guard !AppSettings.shared.offlineMode, ServerManager.shared.hasNetwork else { return }
        // Skip if already cached or already loading this song
        if cache[songId] != nil || loadingSongId == songId { return }

        // Cancel any in-flight fetch for a previous song
        currentTask?.cancel()

        loadingSongId = songId
        currentTask = Task { [weak self] in
            guard let server = ServerManager.shared.currentServer else {
                await MainActor.run { self?.loadingSongId = nil }
                return
            }

            do {
                let allPlaylists = try await SubsonicClient.shared.getPlaylists(server: server)
                if Task.isCancelled { return }

                var containingSong: Set<String> = []
                let batchSize = 20

                for batchStart in stride(from: 0, to: allPlaylists.count, by: batchSize) {
                    if Task.isCancelled { return }
                    let batchEnd = min(batchStart + batchSize, allPlaylists.count)
                    let batch = Array(allPlaylists[batchStart..<batchEnd])

                    await withTaskGroup(of: (String, Bool).self) { group in
                        for playlist in batch {
                            group.addTask {
                                do {
                                    let detail = try await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
                                    let contains = detail.entry?.contains(where: { $0.id == songId }) ?? false
                                    return (playlist.id, contains)
                                } catch {
                                    return (playlist.id, false)
                                }
                            }
                        }
                        for await (id, contains) in group {
                            if contains { containingSong.insert(id) }
                        }
                    }

                    // Update cache progressively after each batch
                    if !Task.isCancelled {
                        let snapshot = containingSong
                        await MainActor.run {
                            self?.cache[songId] = snapshot
                        }
                    }
                }

                await MainActor.run {
                    self?.cache[songId] = containingSong
                    self?.loadingSongId = nil
                }
            } catch {
                await MainActor.run { self?.loadingSongId = nil }
            }
        }
    }

    /// Update cache after user adds/removes a song from a playlist
    func markSongInPlaylist(songId: String, playlistId: String) {
        var set = cache[songId] ?? []
        set.insert(playlistId)
        cache[songId] = set
    }

    func unmarkSongFromPlaylist(songId: String, playlistId: String) {
        cache[songId]?.remove(playlistId)
    }

    /// Clear stale entries (keep only last 5 songs to save memory)
    func trimCache(keeping songId: String) {
        if cache.count > 5 {
            let keysToRemove = cache.keys.filter { $0 != songId }
                .prefix(cache.count - 5)
            for key in keysToRemove {
                cache.removeValue(forKey: key)
            }
        }
    }
}
