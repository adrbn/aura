import SwiftUI

/// Home on the TV: the phone's mixes and album shelves, as rows to move along with the remote.
struct TVHomeView: View {
    @State private var serverManager = ServerManager.shared
    @State private var generator = MixGenerator.shared
    @State private var player = AudioPlayer.shared

    @State private var recent: [Album] = []
    @State private var newest: [Album] = []
    @State private var frequent: [Album] = []
    @State private var random: [Album] = []
    @State private var playlists: [Playlist] = []
    @State private var starred = Starred2(artist: nil, album: nil, song: nil)
    @State private var isLoading = true
    @AppStorage(TVHomeView.mixesPlacementKey) private var mixesPlacement = MixesPlacement.first.rawValue

    enum MixesPlacement: String, CaseIterable { case first, last, off }
    static let mixesPlacementKey = "tv.home.mixesPlacement"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if mixesPlacement == MixesPlacement.first.rawValue { madeForYou }
                TVShelf(title: "Recently Played", items: recent) { TVAlbumLink(album: $0) }
                TVShelf(title: "Recently Added", items: newest) { TVAlbumLink(album: $0) }
                TVShelf(title: "On Repeat", items: frequent) { TVAlbumLink(album: $0) }
                TVShelf(title: "Your Playlists", items: playlists) { TVPlaylistLink(playlist: $0) }
                TVShelf(title: "Favorite Artists", items: starred.artist ?? []) { TVArtistLink(artist: $0) }
                TVShelf(title: "Random Albums", items: random) { TVAlbumLink(album: $0) }
                if mixesPlacement == MixesPlacement.last.rawValue { madeForYou }
                if isLoading && recent.isEmpty && newest.isEmpty { TVStatus(loading: true) }
            }
            .padding(.vertical, 40)
            .animation(.easeOut(duration: 0.5), value: generator.mixes.isEmpty)
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    private var madeForYou: some View {
        TVShelf(title: "Made For You", items: shelf) { mix in
            if mix.id == Self.nonstopId {
                Button {
                    // Already playing: a press opens it rather than starting over.
                    if !player.isNonstop {
                        player.nonstopCoverArtists = mix.coverArtists ?? CoverArtists.ranked(mix.songs)
                        Task { await player.startNonstop(liked: mix.songs) }
                    } else if !player.isPlaying {
                        player.play()
                    }
                    TVPlayback.shared.showNowPlaying = true
                } label: {
                    TVCoverCard(title: mix.title, subtitle: player.isNonstop ? String(localized: "Now Playing") : "") {
                        EditorialMixCover(mix: mix, size: 300, cornerRadius: 0)
                    }
                }
                .buttonStyle(.borderless)
            } else {
                NavigationLink(value: mix) {
                    TVCoverCard(title: mix.title, subtitle: mix.subtitle) {
                        EditorialMixCover(mix: mix, size: 300, cornerRadius: 0)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Nonstop first, as on the phone, once the mixes are there to stand beside it.
    private var shelf: [Mix] {
        guard !generator.mixes.isEmpty else { return [] }
        let nonstop = Mix(id: Self.nonstopId, title: AudioPlayer.nonstopName, subtitle: "", songs: starred.song ?? [])
        return CoverArtists.distinctLeads([nonstop] + generator.mixes)
    }

    private static let nonstopId = "aura.nonstop"

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
        // Every row's covers start now, not as each card comes into view.
        let albums = (recent + newest + frequent + random).compactMap(\.coverArt)
        ArtworkCache.shared.prefetch(coverArtIds: albums + playlists.compactMap(\.coverArt), pointSize: 300)
        ArtworkCache.shared.prefetch(coverArtIds: (starred.artist ?? []).compactMap(\.coverArt), pointSize: 260)
        guard mixesPlacement != MixesPlacement.off.rawValue else { return }
        await generator.generateIfNeeded()
        for mix in generator.mixes { Task { _ = await MixCoverArt.load(MixCoverSpec(mix)) } }
    }
}
