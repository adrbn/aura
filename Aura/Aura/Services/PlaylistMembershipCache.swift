import Foundation

/// Which playlists hold a song, answered at once from the playlists saved on the device
/// (`OfflinePlaylistsStore`), which refreshes from the server in the background. Adds and
/// removes made here count straight away, before the next refresh brings them back.
@MainActor
@Observable
final class PlaylistMembershipCache {
    static let shared = PlaylistMembershipCache()

    /// songId → playlists it was added to / removed from in this session.
    private var added: [String: Set<String>] = [:]
    private var removed: [String: Set<String>] = [:]

    func containing(_ songId: String) -> Set<String> {
        OfflinePlaylistsStore.shared.playlistIds(containing: songId)
            .union(added[songId] ?? [])
            .subtracting(removed[songId] ?? [])
    }

    func markSongInPlaylist(songId: String, playlistId: String) {
        added[songId, default: []].insert(playlistId)
        removed[songId]?.remove(playlistId)
    }

    func unmarkSongFromPlaylist(songId: String, playlistId: String) {
        removed[songId, default: []].insert(playlistId)
        added[songId]?.remove(playlistId)
    }
}
