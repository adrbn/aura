import SwiftUI

/// Turns "go to this id" into a pushed screen.
///
/// The player bar and the sidebar sit outside the `NavigationStack`, so neither can hold a
/// `NavigationLink`. They set one of the player's `pending…Id` fields instead — the same
/// mechanism the iPhone app uses to jump from the Lock Screen — and this resolves the id to
/// a value the stack can actually push.
struct MacPendingNavigation: ViewModifier {
    @Binding var path: NavigationPath
    @State private var player = AudioPlayer.shared
    @State private var serverManager = ServerManager.shared

    func body(content: Content) -> some View {
        content
            .task(id: player.pendingArtistId) { await openArtist() }
            .task(id: player.pendingAlbumId) { await openAlbum() }
            .task(id: player.pendingPlaylistId) { await openPlaylist() }
    }

    private func openArtist() async {
        guard let id = player.pendingArtistId, let server = serverManager.currentServer else { return }
        player.pendingArtistId = nil
        guard let found = try? await SubsonicClient.shared.getArtist(server: server, id: id) else { return }
        path.append(Artist(id: found.id, name: found.name, coverArt: found.coverArt,
                           albumCount: found.albumCount, starred: nil,
                           artistImageUrl: found.artistImageUrl, playCount: nil))
    }

    private func openAlbum() async {
        guard let id = player.pendingAlbumId, let server = serverManager.currentServer else { return }
        player.pendingAlbumId = nil
        guard let found = try? await SubsonicClient.shared.getAlbum(server: server, id: id) else { return }
        path.append(Album(id: found.id, name: found.name, artist: found.artist,
                          artistId: found.artistId, coverArt: found.coverArt,
                          songCount: found.songCount, duration: found.duration,
                          year: found.year, genre: found.genre, starred: nil,
                          created: nil, playCount: nil))
    }

    private func openPlaylist() async {
        guard let id = player.pendingPlaylistId, let server = serverManager.currentServer else { return }
        player.pendingPlaylistId = nil
        guard let found = try? await SubsonicClient.shared.getPlaylist(server: server, id: id) else { return }
        path.append(Playlist(id: found.id, name: found.name, songCount: found.songCount,
                             duration: found.duration, coverArt: found.coverArt,
                             owner: found.owner, created: nil, changed: nil,
                             comment: found.comment, public: found.public))
    }
}

extension View {
    func macPendingNavigation(path: Binding<NavigationPath>) -> some View {
        modifier(MacPendingNavigation(path: path))
    }
}
