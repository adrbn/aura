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
            // `onChange` and a detached `Task`, NOT `.task(id:)`. The id has to be cleared
            // so the same one can be requested twice — but clearing it changes the task id,
            // which cancels the very fetch that was reading it. Nothing ever arrived.
            .onChange(of: player.pendingAlbumId) { _, id in
                guard let id else { return }
                player.pendingAlbumId = nil
                Task { await openAlbum(id) }
            }
            .onChange(of: player.pendingArtistId) { _, id in
                guard let id else { return }
                player.pendingArtistId = nil
                Task { await openArtist(id) }
            }
            .onChange(of: player.pendingPlaylistId) { _, id in
                guard let id else { return }
                player.pendingPlaylistId = nil
                Task { await openPlaylist(id) }
            }
    }

    /// Anything pushed has to be visible, and the lyrics screen covers the whole window.
    private func reveal() {
        if player.isShowingNowPlaying {
            withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying = false }
        }
    }

    private func openArtist(_ id: String) async {
        guard let server = serverManager.currentServer,
              let found = try? await SubsonicClient.shared.getArtist(server: server, id: id)
        else { return }
        reveal()
        path.append(Artist(id: found.id, name: found.name, coverArt: found.coverArt,
                           albumCount: found.albumCount, starred: nil,
                           artistImageUrl: found.artistImageUrl, playCount: nil))
    }

    private func openAlbum(_ id: String) async {
        guard let server = serverManager.currentServer,
              let found = try? await SubsonicClient.shared.getAlbum(server: server, id: id)
        else { return }
        reveal()
        path.append(Album(id: found.id, name: found.name, artist: found.artist,
                          artistId: found.artistId, coverArt: found.coverArt,
                          songCount: found.songCount, duration: found.duration,
                          year: found.year, genre: found.genre, starred: nil,
                          created: nil, playCount: nil))
    }

    private func openPlaylist(_ id: String) async {
        guard let server = serverManager.currentServer,
              let found = try? await SubsonicClient.shared.getPlaylist(server: server, id: id)
        else { return }
        reveal()
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
