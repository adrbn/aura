import SwiftUI

/// Home on the TV: the phone's mixes and album shelves, as rows to move along with the remote.
struct TVHomeView: View {
    @State private var serverManager = ServerManager.shared
    @State private var generator = MixGenerator.shared

    @State private var recent: [Album] = []
    @State private var newest: [Album] = []
    @State private var frequent: [Album] = []
    @State private var random: [Album] = []
    @State private var playlists: [Playlist] = []
    @State private var starred = Starred2(artist: nil, album: nil, song: nil)
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                TVShelf(title: "Made For You", items: generator.mixes) { mix in
                    NavigationLink(value: mix) {
                        TVCoverCard(title: mix.title, subtitle: mix.subtitle) {
                            EditorialMixCover(mix: mix, size: 300, cornerRadius: 0)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                TVShelf(title: "Recently Played", items: recent) { TVAlbumLink(album: $0) }
                TVShelf(title: "Recently Added", items: newest) { TVAlbumLink(album: $0) }
                TVShelf(title: "On Repeat", items: frequent) { TVAlbumLink(album: $0) }
                TVShelf(title: "Your Playlists", items: playlists) { TVPlaylistLink(playlist: $0) }
                TVShelf(title: "Favorite Artists", items: starred.artist ?? []) { TVArtistLink(artist: $0) }
                TVShelf(title: "Random Albums", items: random) { TVAlbumLink(album: $0) }
                if isLoading && recent.isEmpty && newest.isEmpty { TVStatus(loading: true) }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        defer { isLoading = false }
        let client = SubsonicClient.shared
        async let recentCall = try? client.getAlbumList2(server: server, type: "recent", size: 24)
        async let newestCall = try? client.getAlbumList2(server: server, type: "newest", size: 24)
        async let frequentCall = try? client.getAlbumList2(server: server, type: "frequent", size: 200)
        async let randomCall = try? client.getAlbumList2(server: server, type: "random", size: 24)
        async let playlistCall = try? client.getPlaylists(server: server)
        async let starredCall = try? client.getStarred2(server: server)
        recent = await recentCall ?? []
        newest = await newestCall ?? []
        frequent = Album.frequentLately(await frequentCall ?? [], count: 24)
        random = await randomCall ?? []
        playlists = await playlistCall ?? []
        if let found = await starredCall { starred = found }
        await generator.generateIfNeeded()
    }
}
