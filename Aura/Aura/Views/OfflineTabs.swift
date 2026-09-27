import SwiftUI

// MARK: - Home, offline

/// Home as it is online — the big title, a quiet line under it, rows of covers — filled
/// with what's on this iPhone: the mixes that can still play, what arrived last, the
/// playlists, the favourites and the artists.
struct OfflineHomeView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var library = OfflineLibrary.shared
    @State private var appSettings = AppSettings.shared
    @State private var scrollY: CGFloat = 0
    @State private var layoutWidth: CGFloat = 0
    @State private var navPath: [OfflineRoute] = []

    /// Section titles, as online: they name a row, they don't shout over it.
    private static let sectionFont = Font.title3.weight(.semibold)
    private static let artistCircle: CGFloat = 110

    /// The same title Home has online.
    private var title: String {
        switch appSettings.homeTitleStyle {
        case .none: return ""
        case .home: return String(localized: "Home")
        case .server:
            let name = serverManager.currentServer?.friendlyName ?? ""
            return !name.isEmpty && name != serverManager.currentServer?.username ? name : String(localized: "Home")
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 15) {
                        if !title.isEmpty {
                            Text(title)
                                .auraDisplay(40)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                        }
                        OfflineStatusLine()
                    }
                    .padding(.bottom, 15 - 24)

                    if library.songs.isEmpty {
                        ContentUnavailableView(
                            "Nothing on This iPhone Yet",
                            systemImage: "arrow.down.circle",
                            description: Text("Download songs, albums or playlists while you're online, and they'll be here.")
                        )
                        .padding(.top, 60)
                    } else {
                        sections
                    }
                    ListEndSpacer()
                }
                .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .contentMargins(.top, TabChrome.contentTop, for: .scrollContent)
            .overlay(alignment: .top) { TopEdgeVeil(scrollY: scrollY) }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layoutWidth = $0 }
            .tabRootCanvas(grid: true)
            .toolbar(.hidden, for: .navigationBar)
            .offlineDestinations()
        }
        .onAppear {
            library.refresh()
            consumePendingMix()
        }
        .onChange(of: player.pendingMixId) { _, _ in consumePendingMix() }
    }

    /// A mix Now Playing was playing from, opened here.
    private func consumePendingMix() {
        guard let id = player.pendingMixId else { return }
        player.pendingMixId = nil
        navPath.append(.mix(id))
    }

    @ViewBuilder
    private var sections: some View {
        let mixes = library.mixes
        if !mixes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Made For You").font(Self.sectionFont).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(mixes) { mix in
                            NavigationLink(value: OfflineRoute.mix(mix.id)) {
                                EditorialMixCover(mix: mix, size: 150, cornerRadius: 12)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(mix.title), \(mix.subtitle)"))
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }

        let albums = Array(library.recentAlbums.prefix(20))
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink(value: OfflineRoute.albums) { sectionHeader("Recently Downloaded") }
                    .buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(albums) { album in
                            OfflineAlbumCard(album: album, size: albumCardSize)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }

        let playlists = library.playlists
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Playlists").font(Self.sectionFont).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(playlists, id: \.snapshot.id) { item in
                            NavigationLink(value: OfflineRoute.playlist(item.snapshot.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    PlaylistCoverView(playlistId: item.snapshot.id, coverArt: item.snapshot.coverArt,
                                                      size: 150, cornerRadius: 10, placeholderName: item.snapshot.name)
                                    Text(item.snapshot.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(item.available.count) of \(item.snapshot.songCount) songs")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }

        let favourites = library.favourites
        if !favourites.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink(value: OfflineRoute.songs(.favourites)) { sectionHeader("Favorite Songs") }
                    .buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(favourites.prefix(50).enumerated()), id: \.element.id) { index, song in
                            songCard(song, queue: favourites, index: index)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }

        let artists = Array(library.artists.sorted { $0.songs.count > $1.songs.count }.prefix(25))
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink(value: OfflineRoute.artists) { sectionHeader("Artists") }
                    .buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(artists) { artist in
                            NavigationLink(value: OfflineRoute.artist(artist.id)) {
                                VStack(spacing: 8) {
                                    CoverArtImage(coverArt: artist.coverArt, size: Self.artistCircle,
                                                  cornerRadius: Self.artistCircle / 2,
                                                  placeholderName: artist.name, placeholderKind: .artist)
                                    Text(artist.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .frame(width: Self.artistCircle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    /// Two covers across, as Home's album rows online.
    private var albumCardSize: CGFloat {
        guard layoutWidth > 0 else { return 160 }
        return max((layoutWidth - 16 - 12) / 2, 100)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        HStack {
            Text(title).font(Self.sectionFont)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal)
    }

    private func songCard(_ song: Song, queue: [Song], index: Int) -> some View {
        Button {
            player.playSong(song, fromQueue: queue, startIndex: index, source: .favorites)
        } label: {
            HStack(spacing: 12) {
                CoverArtImage(coverArt: song.coverArt, size: 50, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(song.artist ?? "Unknown Artist").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 220, alignment: .leading)
            .padding(.trailing, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Playlists, offline

/// The Playlists tab as online, in its list layout: the playlists with songs on this iPhone,
/// each showing how many of its songs are here.
struct OfflinePlaylistsView: View {
    @Environment(AudioPlayer.self) private var player
    @State private var library = OfflineLibrary.shared
    @State private var searchText = ""
    @State private var scrollY: CGFloat = 0
    @State private var navPath: [OfflineRoute] = []

    private var items: [(snapshot: OfflinePlaylistSnapshot, available: [Song])] {
        let all = library.playlists
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.snapshot.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                TabTitleRow("playlists").clearRow()
                SearchFieldBar(text: $searchText, prompt: "Search in Playlists")
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .clearRow()
                if items.isEmpty {
                    Text(searchText.isEmpty
                         ? "Playlists show up here once some of their songs are on this iPhone."
                         : "No playlists here yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32)
                        .padding(.top, 60)
                        .clearRow()
                } else {
                    ForEach(items, id: \.snapshot.id) { item in
                        NavigationLink(value: OfflineRoute.playlist(item.snapshot.id)) {
                            OfflineRow(title: item.snapshot.name,
                                       detail: "\(item.available.count) of \(OfflineLibraryView.count(item.snapshot.songCount, "song"))") {
                                PlaylistCoverView(playlistId: item.snapshot.id, coverArt: item.snapshot.coverArt,
                                                  size: 56, cornerRadius: 8, placeholderName: item.snapshot.name)
                            }
                        }
                        .offlineRowStyle()
                    }
                }
                ListEndSpacer().clearRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .tabRootGlass(scrollY: $scrollY)
            .offlineDestinations()
        }
        .onAppear {
            library.refresh()
            consumePendingPlaylist()
        }
        .onChange(of: player.pendingPlaylistId) { _, _ in consumePendingPlaylist() }
    }

    /// The playlist Now Playing was playing from, opened here.
    private func consumePendingPlaylist() {
        guard let id = player.pendingPlaylistId else { return }
        player.pendingPlaylistId = nil
        navPath.append(.playlist(id))
    }
}

// MARK: - Search, offline

/// Search as online — the title, the field, results by kind — over the songs on this iPhone.
struct OfflineSearchView: View {
    @Environment(AudioPlayer.self) private var player
    @State private var library = OfflineLibrary.shared
    @State private var query = ""
    @State private var scrollY: CGFloat = 0

    private static let sectionLimit = 6

    private var songs: [Song] {
        library.songs.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(query)
                || ($0.album ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                TabTitleRow("search").clearRow()
                SearchFieldBar(text: $query, prompt: "Songs, Artists, Albums on This iPhone")
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .clearRow()
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    genres
                } else {
                    results
                }
                ListEndSpacer().clearRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .tabRootGlass(scrollY: $scrollY)
            .offlineDestinations()
        }
        .onAppear { library.refresh() }
    }

    /// With nothing typed: the genres on this iPhone, as a way in.
    @ViewBuilder
    private var genres: some View {
        let genres = library.genres
        if !genres.isEmpty {
            sectionTitle("Genres")
            ForEach(genres, id: \.name) { genre in
                NavigationLink(value: OfflineRoute.songs(.genre(genre.name))) {
                    OfflineRow(title: genre.name, detail: OfflineLibraryView.count(genre.songs.count, "song")) {
                        Image(systemName: "guitars.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, height: 56)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .offlineRowStyle()
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let songs = songs
        let artists = OfflineArtist.group(songs).filter { $0.name.localizedCaseInsensitiveContains(query) }
        let albums = OfflineAlbum.group(songs).filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
        }
        if songs.isEmpty {
            Text("Nothing on this iPhone matches “\(query)”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .clearRow()
        }
        if !artists.isEmpty {
            sectionTitle("Artists")
            ForEach(artists.prefix(Self.sectionLimit)) { artist in
                NavigationLink(value: OfflineRoute.artist(artist.id)) {
                    OfflineRow(title: artist.name, detail: OfflineLibraryView.count(artist.songs.count, "song")) {
                        CoverArtImage(coverArt: artist.coverArt, size: 56, cornerRadius: 28,
                                      placeholderName: artist.name, placeholderKind: .artist)
                    }
                }
                .offlineRowStyle()
            }
        }
        if !albums.isEmpty {
            sectionTitle("Albums")
            ForEach(albums.prefix(Self.sectionLimit)) { album in
                NavigationLink(value: OfflineRoute.album(album.id)) {
                    OfflineRow(title: album.name, detail: album.artist) {
                        CoverArtImage(coverArt: album.coverArt, size: 56, cornerRadius: 8,
                                      placeholderName: album.name, placeholderKind: .album)
                    }
                }
                .offlineRowStyle()
            }
        }
        if !songs.isEmpty {
            sectionTitle("Songs")
            ForEach(Array(songs.prefix(50).enumerated()), id: \.element.id) { index, song in
                SongRowView(song: song) {
                    player.playSong(song, fromQueue: songs, startIndex: index, source: .search(query: query))
                }
                .offlineRowStyle()
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .clearRow()
    }
}
