import SwiftUI

/// The landing page: shelves of starting points rather than a list of everything.
///
/// Built the way the streaming services build theirs, because the shape is right for the
/// problem — a library of twenty thousand songs has no useful first screen unless something
/// picks a handful of doors and labels them.
struct MacHomeView: View {
    @State private var serverManager = ServerManager.shared
    @State private var generator = MixGenerator.shared
    @State private var player = AudioPlayer.shared
    @State private var preferences = MacPreferences.shared

    @State private var recent: [Album] = []
    @State private var newest: [Album] = []
    @State private var frequent: [Album] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                greeting
                quickPicks
                mixesShelf
                albumShelf("Recently Played", recent)
                albumShelf("Recently Added", newest)
                playlistShelf
                albumShelf("On Repeat", frequent)
                if isLoading && recent.isEmpty && newest.isEmpty {
                    MacLoadingState().frame(height: 240)
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Home")
        .task { await load() }
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(salutation).auraDisplay(42)
            Text(serverManager.currentServer?.friendlyName ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private var salutation: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<5: return "Still up"
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // MARK: Quick picks — the compact grid at the top

    /// Six wide tiles, two rows of three. Different in kind from the shelves below on
    /// purpose: these are the things you had open last, so they want to be reachable without
    /// a decision, and a wide tile with the name already visible is one glance rather than
    /// two.
    private var quickPicks: some View {
        let picks = Array(recent.prefix(6))
        return Group {
            if !picks.isEmpty {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                    spacing: 12
                ) {
                    ForEach(picks) { album in
                        NavigationLink(value: album) { quickTile(album) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 34)
            }
        }
    }

    private func quickTile(_ album: Album) -> some View {
        HStack(spacing: 0) {
            CoverArtImage(coverArt: album.coverArt, size: 58, cornerRadius: 0,
                          placeholderName: album.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(album.artist ?? "").font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(height: 58)
        .background(.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Shelves

    private var mixesShelf: some View {
        MacShelf(title: "Made For You",
                 subtitle: "Built from what you've been listening to",
                 items: generator.mixes) { mix in
            NavigationLink(value: mix) {
                MacPlayableCard(
                    coverArt: nil,
                    title: mix.title,
                    subtitle: mix.subtitle,
                    artwork: AnyView(mixArtwork(mix)),
                    play: { play(mix.songs, source: .mix(id: mix.id, name: mix.title)) }
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func mixArtwork(_ mix: Mix) -> some View {
        if let nature = mix.generatedCover {
            GeneratedCoverView(nature: nature, size: preferences.coverSize.shelfWidth, cornerRadius: 8)
        } else {
            MixCollageView(coverArts: mix.collageCoverArts, size: preferences.coverSize.shelfWidth, cornerRadius: 8)
        }
    }

    private func albumShelf(_ title: String, _ albums: [Album]) -> some View {
        MacShelf(title: title, items: albums) { album in
            NavigationLink(value: album) {
                MacPlayableCard(
                    coverArt: album.coverArt,
                    title: album.name,
                    subtitle: album.artist,
                    placeholderName: album.name,
                    play: { Task { await playAlbum(album) } }
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var playlistShelf: some View {
        MacShelf(title: "Your Playlists", items: MacPlaylistOrder.pinnedFirst(playlists)) { playlist in
            NavigationLink(value: playlist) {
                MacPlayableCard(
                    coverArt: playlist.coverArt,
                    title: playlist.name,
                    subtitle: playlist.songCount.map { "\($0) songs" },
                    placeholderName: playlist.name,
                    play: { Task { await playPlaylist(playlist) } }
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Loading and playing

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        defer { isLoading = false }
        // Four independent calls; issued together rather than in sequence, so the page fills
        // in one round trip's worth of time instead of four.
        async let recentCall  = try? await SubsonicClient.shared.getAlbumList2(server: server, type: "recent", size: 24)
        async let newestCall  = try? await SubsonicClient.shared.getAlbumList2(server: server, type: "newest", size: 24)
        async let frequentCall = try? await SubsonicClient.shared.getAlbumList2(server: server, type: "frequent", size: 24)
        async let playlistCall = try? await SubsonicClient.shared.getPlaylists(server: server)
        recent = await recentCall ?? []
        newest = await newestCall ?? []
        frequent = await frequentCall ?? []
        playlists = await playlistCall ?? []
        await generator.generateIfNeeded()
    }

    private func play(_ songs: [Song], source: PlaybackSource) {
        guard let first = songs.first else { return }
        player.playSong(first, fromQueue: songs, startIndex: 0, source: source)
    }

    private func playAlbum(_ album: Album) async {
        guard let server = serverManager.currentServer,
              let songs = try? await SubsonicClient.shared.getAlbum(server: server, id: album.id).song
        else { return }
        play(songs, source: .album(id: album.id, name: album.name))
    }

    private func playPlaylist(_ playlist: Playlist) async {
        guard let server = serverManager.currentServer,
              let songs = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id).entry
        else { return }
        play(songs, source: .playlist(id: playlist.id, name: playlist.name))
    }
}
