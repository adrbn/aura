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
    @State private var random: [Album] = []
    @State private var starred = Starred2(artist: nil, album: nil, song: nil)
    @State private var songCount = 0
    @State private var albumCount = 0
    @State private var settings = AppSettings.shared
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                greeting
                wrappedCard
                quickPicks
                mixesShelf
                // The phone's section order, the same setting; the playlists shelf is the
                // Mac's own and follows them.
                ForEach(settings.homeSectionOrder) { section($0) }
                playlistShelf
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
            // The phone's title setting: a custom title replaces the greeting, None drops it,
            // and only Server names the server beneath.
            switch settings.homeTitleStyle {
            case .none: EmptyView()
            case .custom:
                let text = settings.homeCustomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(text.isEmpty ? salutation : text).auraDisplay(58)
            default: Text(salutation).auraDisplay(58)
            }
            HStack(spacing: 6) {
                if settings.homeTitleStyle == .server {
                    Text(serverManager.currentServer?.friendlyName ?? "")
                }
                // The phone's stats line, as quiet: only the counts the server reported.
                if settings.showStatsOnHome {
                    ForEach(Array(stats.enumerated()), id: \.offset) { index, part in
                        if index > 0 || settings.homeTitleStyle == .server { Text(verbatim: "·") }
                        part
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private var salutation: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<5: return String(localized: "Still up")
        case 5..<12: return String(localized: "Good morning")
        case 12..<18: return String(localized: "Good afternoon")
        default: return String(localized: "Good evening")
        }
    }

    private var stats: [Text] {
        var parts: [Text] = []
        if songCount > 0 { parts.append(Text("\(songCount) songs")) }
        if albumCount > 0 { parts.append(Text("\(albumCount) albums")) }
        if !playlists.isEmpty { parts.append(Text("\(playlists.count) playlists")) }
        return parts
    }

    // MARK: Wrapped

    /// The phone's retrospective card, on the same terms: only when Home is set to show it,
    /// and only while a period is being offered.
    @ViewBuilder
    private var wrappedCard: some View {
        if settings.wrappedShowOnHome, let period = WrappedAvailability.offeredPeriods().first {
            NavigationLink(value: period) {
                HStack(spacing: 14) {
                    GeneratedCoverView(nature: .retrospective(period.coverLabel), size: 58, cornerRadius: 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your \(period.title) Wrapped").font(.system(size: 14, weight: .semibold))
                        Text("Your top songs, artists & genres").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.trailing, 16)
                .background(.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(MacPressStyle())
            .macHoverLift(scale: 1.01)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
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
                        NavigationLink(value: album) { quickTile(album) }.buttonStyle(MacPressStyle())
                            .macHoverLift(scale: 1.015)
                            .contextMenu { MacAlbumMenuItems(album: album) }
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

    @ViewBuilder
    private func section(_ section: HomeSection) -> some View {
        switch section {
        case .upNext: upNextShelf
        case .recentlyPlayed: albumShelf("Recently Played", recent)
        case .recentlyAdded: albumShelf("Recently Added", newest)
        case .frequentlyPlayed: albumShelf("On Repeat", frequent)
        case .randomAlbums: albumShelf("Random Albums", random)
        case .favoriteSongs: songShelf("Favorite Songs", starred.song ?? [], source: .favorites)
        case .favoriteArtists: artistShelf
        }
    }

    private var mixesShelf: some View {
        MacShelf(title: "Made For You",
                 subtitle: "Built from what you've been listening to",
                 items: CoverArtists.distinctLeads(generator.mixes)) { mix in
            NavigationLink(value: mix) {
                MacPlayableCard(
                    coverArt: nil,
                    title: mix.title,
                    subtitle: mix.subtitle,
                    artwork: AnyView(mixArtwork(mix)),
                    play: { play(mix.songs, source: .mix(id: mix.id, name: mix.title)) }
                )
            }
            .buttonStyle(MacPressStyle())
            .contextMenu { MacMixMenuItems(mix: mix) }
        }
    }

    @ViewBuilder
    private func mixArtwork(_ mix: Mix) -> some View {
        // The phone's editorial cover: the most-played artist's photo under the mix's type.
        EditorialMixCover(mix: mix, size: preferences.coverSize.shelfWidth, cornerRadius: 8)
    }

    private func albumShelf(_ title: LocalizedStringKey, _ albums: [Album]) -> some View {
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
            .buttonStyle(MacPressStyle())
            .contextMenu { MacAlbumMenuItems(album: album) }
        }
    }

    /// What plays next, as the phone shows it: a card plays the queue from there.
    @ViewBuilder
    private var upNextShelf: some View {
        if settings.showUpNext {
            MacShelf(title: "Up Next", items: Array(player.upNextSongs.prefix(15))) { song in
                Button {
                    if let index = player.queue.firstIndex(where: { $0.id == song.id }) {
                        player.playSong(song, fromQueue: player.queue, startIndex: index, source: .queue)
                    }
                } label: { songCard(song) }
                .buttonStyle(MacPressStyle())
                .contextMenu { MacSongCardMenuItems(song: song) }
            }
        }
    }

    private func songShelf(_ title: LocalizedStringKey, _ songs: [Song], source: PlaybackSource) -> some View {
        MacShelf(title: title, items: Array(songs.prefix(30))) { song in
            Button {
                player.playSong(song, fromQueue: songs, startIndex: songs.firstIndex { $0.id == song.id } ?? 0, source: source)
            } label: { songCard(song) }
            .buttonStyle(MacPressStyle())
            .contextMenu { MacSongCardMenuItems(song: song) }
        }
    }

    private func songCard(_ song: Song) -> some View {
        MacPlayableCard(coverArt: song.coverArt, title: song.title, subtitle: song.artist,
                        placeholderName: song.album ?? song.title)
    }

    private var artistShelf: some View {
        MacShelf(title: "Favorite Artists", items: starred.artist ?? []) { artist in
            NavigationLink(value: artist) {
                MacPlayableCard(coverArt: artist.coverArt, title: artist.name,
                                placeholderName: artist.name, circular: true)
            }
            .buttonStyle(MacPressStyle())
            .contextMenu { MacArtistMenuItems(artist: artist) }
        }
    }

    private var playlistShelf: some View {
        MacShelf(title: "Your Playlists", items: MacPlaylistOrder.pinnedFirst(playlists)) { playlist in
            NavigationLink(value: playlist) {
                MacPlayableCard(
                    coverArt: playlist.coverArt,
                    title: playlist.name,
                    subtitle: playlist.songCount.map { String(localized: "\($0) songs") },
                    placeholderName: playlist.name,
                    play: { Task { await playPlaylist(playlist) } }
                )
            }
            .buttonStyle(MacPressStyle())
            .contextMenu { MacPlaylistMenuItems(playlist: playlist) }
        }
    }

    // MARK: Loading and playing

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        defer { isLoading = false }
        // Independent calls, issued together rather than in sequence, so the page fills
        // in one round trip's worth of time instead of eight.
        //
        // Each one says what happened. A shelf whose call fails renders as nothing at all —
        // `MacShelf` draws no heading for an empty list — so a `try?` here turns any server
        // error into a page that is simply, silently short, with no way to tell a library
        // that has no recent albums from a request that never came back.
        async let recentCall   = Self.shelf("recent")   { try await SubsonicClient.shared.getAlbumList2(server: server, type: "recent", size: 24) }
        async let newestCall   = Self.shelf("newest")   { try await SubsonicClient.shared.getAlbumList2(server: server, type: "newest", size: 24) }
        async let frequentCall = Self.shelf("frequent") { try await SubsonicClient.shared.getAlbumList2(server: server, type: "frequent", size: 24) }
        async let playlistCall = Self.shelf("playlists") { try await SubsonicClient.shared.getPlaylists(server: server) }
        async let randomCall   = Self.shelf("random")   { try await SubsonicClient.shared.getAlbumList2(server: server, type: "random", size: 24) }
        async let starredCall  = try? SubsonicClient.shared.getStarred2(server: server)
        async let scanCall     = try? SubsonicClient.shared.getScanStatus(server: server)
        async let albumsCall   = try? SubsonicClient.shared.getAlbumCount(server: server)
        recent = await recentCall
        newest = await newestCall
        frequent = await frequentCall
        playlists = await playlistCall
        random = await randomCall
        if let found = await starredCall { starred = found }
        songCount = await scanCall?.count ?? 0
        albumCount = await albumsCall ?? 0
        await generator.generateIfNeeded()
    }

    /// Runs one shelf's request, reporting what it returned rather than swallowing it.
    private static func shelf<T>(_ name: String, _ call: () async throws -> [T]) async -> [T] {
        do {
            let items = try await call()
            if items.isEmpty { AppLogger.shared.log("🖥 home shelf '\(name)': empty (server returned nothing)") }
            return items
        } catch {
            AppLogger.shared.log("❌ home shelf '\(name)' failed: \(error.localizedDescription)")
            return []
        }
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
