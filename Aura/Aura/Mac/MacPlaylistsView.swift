import SwiftUI

struct MacPlaylistsView: View {
    @State private var serverManager = ServerManager.shared
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false

    var body: some View {
        MacGrid(items: playlists, isLoading: isLoading, emptyMessage: "No playlists") { playlist in
            NavigationLink(value: playlist) {
                MacCoverTile(coverArt: playlist.coverArt, title: playlist.name,
                             subtitle: playlist.songCount.map { "\($0) songs" },
                             placeholderName: playlist.name)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Playlists")
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        isLoading = true
        defer { isLoading = false }
        playlists = (try? await SubsonicClient.shared.getPlaylists(server: server)) ?? []
    }
}

struct MacPlaylistDetailView: View {
    let playlist: Playlist
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var songs: [Song] = []

    var body: some View {
        VStack(spacing: 0) {
            MacDetailHeader(
                coverArt: playlist.coverArt,
                title: playlist.name,
                subtitle: [playlist.songCount.map { "\($0) songs" },
                           MacFormat.duration(playlist.duration)]
                    .compactMap { $0 }.joined(separator: " · "),
                placeholderName: playlist.name
            ) {
                Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            }
            Divider()
            MacSongTable(songs: songs, source: .playlist(id: playlist.id, name: playlist.name))
        }
        .navigationTitle(playlist.name)
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        songs = (try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id))?.entry ?? []
    }

    private func play(shuffled: Bool) {
        guard !songs.isEmpty else { return }
        let source = PlaybackSource.playlist(id: playlist.id, name: playlist.name)
        shuffled ? player.playShuffled(songs, source: source)
                 : player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: source)
    }
}
