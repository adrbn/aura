import SwiftUI

// MARK: - Offline grouping models

/// An album reconstructed purely from locally-available songs (downloads + cache).
struct OfflineAlbum: Identifiable {
    let id: String
    let name: String
    let artist: String
    let coverArt: String?
    let songs: [Song]

    /// The album a song is grouped under.
    static func key(of song: Song) -> String { song.albumId ?? song.album ?? "unknown" }

    static func group(_ songs: [Song]) -> [OfflineAlbum] {
        var order: [String] = []
        var map: [String: [Song]] = [:]
        for song in songs {
            let key = key(of: song)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(song)
        }
        return order.map { key in
            let items = map[key]!
            let sorted = items.sorted { ($0.track ?? 0) < ($1.track ?? 0) }
            return OfflineAlbum(
                id: key,
                name: items.first?.album ?? "Unknown Album",
                artist: items.first?.artist ?? "Unknown Artist",
                coverArt: items.first?.coverArt,
                songs: sorted
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// An artist reconstructed from locally-available songs.
struct OfflineArtist: Identifiable {
    let id: String
    let name: String
    let coverArt: String?
    let songs: [Song]

    var albumCount: Int { Set(songs.map(OfflineAlbum.key(of:))).count }

    static func group(_ songs: [Song]) -> [OfflineArtist] {
        var order: [String] = []
        var map: [String: [Song]] = [:]
        for song in songs {
            let key = song.artistId ?? song.artist ?? "unknown"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(song)
        }
        return order.map { key in
            let items = map[key]!
            return OfflineArtist(
                id: key,
                name: items.first?.artist ?? "Unknown Artist",
                coverArt: items.first?.coverArt,
                songs: items
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Library, offline

/// The Library tab as online — the big title, the reader's own categories as a list —
/// keeping the categories that can be answered from this iPhone. Recently and Frequently
/// Played and the Radar need the server, so they wait for it.
struct OfflineLibraryView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.scenePhase) private var scenePhase
    @State private var appSettings = AppSettings.shared
    @State private var library = OfflineLibrary.shared
    @State private var navPath: [OfflineRoute] = []
    @State private var scrollY: CGFloat = 0

    /// The enabled categories that open something offline, each once.
    private var categories: [LibraryCategory] {
        let enabled = appSettings.enabledLibraryCategories
        return enabled.filter { category in
            switch category {
            case .recentlyPlayed, .frequentlyPlayed, .radar: return false
            // Offline, both are the artists of the songs here: one row is enough.
            case .albumArtists: return !enabled.contains(.artists)
            default: return true
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                TabTitleRow("library").clearRow()
                OfflineStatusLine()
                    .padding(.bottom, 10)
                    .clearRow()
                ForEach(categories) { category in
                    if let route = Self.route(for: category) {
                        NavigationLink(value: route) {
                            Label {
                                Text(category.rawValue).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: category.icon).foregroundStyle(accentColor)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                Text("Downloads stay until you remove them. Streamed songs are kept too, but iOS may clear them when storage runs low.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .clearRow()
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
            consumePending()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        .onChange(of: player.pendingArtistId) { _, _ in consumePending() }
        .onChange(of: player.pendingAlbumId) { _, _ in consumePending() }
        .onChange(of: player.pendingGenreName) { _, _ in consumePending() }
        .onChange(of: player.pendingFavoritesOpen) { _, _ in consumePending() }
    }

    static func route(for category: LibraryCategory) -> OfflineRoute? {
        switch category {
        case .songs: return .songs(.all)
        case .albums: return .albums
        case .favourites: return .songs(.favourites)
        case .random: return .songs(.random)
        case .genres: return .genres
        case .artists, .albumArtists: return .artists
        case .downloaded: return .downloads
        case .recentlyPlayed, .frequentlyPlayed, .radar: return nil
        }
    }

    /// Now Playing's links — the album, the artist, the genre, the favourites — opened
    /// here. Each is read live and cleared before the push, so it can't open twice.
    private func consumePending() {
        if let id = player.pendingArtistId {
            player.pendingArtistId = nil
            navPath.append(.artist(id))
        }
        if let id = player.pendingAlbumId {
            player.pendingAlbumId = nil
            navPath.append(.album(id))
        }
        if let name = player.pendingGenreName {
            player.pendingGenreName = nil
            navPath.append(.songs(.genre(name)))
        }
        if player.pendingFavoritesOpen {
            player.pendingFavoritesOpen = false
            navPath.append(.songs(.favourites))
        }
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

// MARK: - Library pages

/// Songs, Favorite Songs, Random or a genre: Shuffle and Play, then the songs.
struct OfflineSongsPage: View {
    let list: OfflineSongList
    @State private var library = OfflineLibrary.shared

    var body: some View {
        let songs = library.songs(of: list)
        List {
            if songs.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "music.note",
                                       description: Text("Download songs while you're online, and they'll be here."))
                    .padding(.top, 60)
                    .clearRow()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(OfflineLibraryView.count(songs.count, "song"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    OfflinePlayButtons(songs: songs, source: list.source)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .clearRow()
                OfflineSongRows(songs: songs, source: list.source)
            }
            ListEndSpacer(height: 60).clearRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .scrollIndicators(.hidden)
        .navigationTitle(list.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { library.refresh() }
    }

    private var emptyTitle: LocalizedStringKey {
        switch list {
        case .favourites: return "No Favorite Songs Here"
        default: return "No Songs Here"
        }
    }
}

/// Every album with songs here, in the online Albums grid.
struct OfflineAlbumsPage: View {
    @State private var library = OfflineLibrary.shared
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(library.albums) { album in
                    OfflineAlbumCard(album: album)
                }
            }
            .padding()
            ListEndSpacer()
        }
        .scrollIndicators(.hidden)
        .background(Color.themeBg)
        .navigationTitle("albums")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { library.refresh() }
    }
}

/// Every artist with songs here.
struct OfflineArtistsPage: View {
    @State private var library = OfflineLibrary.shared

    var body: some View {
        List {
            ForEach(library.artists) { artist in
                NavigationLink(value: OfflineRoute.artist(artist.id)) {
                    OfflineRow(title: artist.name,
                               detail: OfflineLibraryView.count(artist.albumCount, "album") + " · "
                                   + OfflineLibraryView.count(artist.songs.count, "song")) {
                        CoverArtImage(coverArt: artist.coverArt, size: 44, cornerRadius: 22,
                                      placeholderName: artist.name, placeholderKind: .artist)
                    }
                }
                .offlineRowStyle()
            }
            ListEndSpacer(height: 60).clearRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .scrollIndicators(.hidden)
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { library.refresh() }
    }
}

/// The genres of the songs here, as the online list shows them.
struct OfflineGenresPage: View {
    @State private var library = OfflineLibrary.shared

    var body: some View {
        List {
            ForEach(library.genres, id: \.name) { genre in
                NavigationLink(value: OfflineRoute.songs(.genre(genre.name))) {
                    HStack {
                        Text(genre.name)
                        Spacer()
                        Text(OfflineLibraryView.count(genre.songs.count, "song"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            ListEndSpacer(height: 60).clearRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .scrollIndicators(.hidden)
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { library.refresh() }
    }
}

/// A Made For You mix, reduced to its songs on this iPhone.
struct OfflineMixDetailView: View {
    let mix: Mix

    var body: some View {
        List {
            OfflinePageHeader(title: mix.title, subtitle: mix.subtitle,
                              songs: mix.songs, source: .mix(id: mix.id, name: mix.title)) {
                EditorialMixCover(mix: mix, size: 260, cornerRadius: 12)
            }
            .clearRow()
            OfflineSongRows(songs: mix.songs, source: .mix(id: mix.id, name: mix.title))
            ListSummaryRow(text: ListSummaryRow.text(songs: mix.songs))
            ListEndSpacer().clearRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .background(Color.themeBg)
        .navigationTitle(mix.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Shared pieces

/// Shuffle beside a wide Play, as on the online album pages.
struct OfflinePlayButtons: View {
    let songs: [Song]
    var source: PlaybackSource = .unknown
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        HStack(spacing: 12) {
            Button { player.playShuffled(songs, source: source) } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .frame(width: 50, height: 40)
                    .background(Color.themeGroupedBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Shuffle")

            Button {
                guard let first = songs.first else { return }
                player.playSong(first, fromQueue: songs, startIndex: 0, source: source)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.borderless)
        }
        .disabled(songs.isEmpty)
    }
}

/// A cover, a name and what's held of it — the list layout's row, offline.
struct OfflineRow<Cover: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var cover: () -> Cover

    var body: some View {
        HStack(spacing: 12) {
            cover()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

extension View {
    func offlineRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// An album as the grids draw it, opening its offline page.
struct OfflineAlbumCard: View {
    let album: OfflineAlbum
    var size: CGFloat = 160
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        NavigationLink(value: OfflineRoute.album(album.id)) {
            VStack(alignment: .leading, spacing: 4) {
                CoverArtImage(coverArt: album.coverArt, size: size, cornerRadius: 10,
                              placeholderName: album.name, placeholderKind: .album)
                Text(album.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(album.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let first = album.songs.first {
                    player.playSong(first, fromQueue: album.songs, startIndex: 0)
                }
            } label: { Label("Play", systemImage: "play.fill") }
            Button { player.playShuffled(album.songs) } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            Button { player.addToQueue(album.songs) } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
        }
    }
}

/// The head of an offline album, playlist, artist or mix page, in the online pages'
/// layout: the cover, the name, Shuffle and Play, then what's held.
private struct OfflinePageHeader<Cover: View>: View {
    let title: String
    var subtitle: String?
    /// A line under the buttons, for a page with no song list to close with one.
    var detail: String?
    let songs: [Song]
    var source: PlaybackSource = .unknown
    @ViewBuilder var cover: () -> Cover

    var body: some View {
        // The online album header's rhythm, space for space.
        VStack(spacing: 12) {
            Spacer().frame(height: 16)
            cover()
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            OfflinePlayButtons(songs: songs, source: source)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            if let detail {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(detail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, DetailListLayout.gap)
    }
}

/// A page's songs, as rows the way the online pages list them, with the swipes the
/// online lists have: queue it, or remove the download.
private struct OfflineSongRows: View {
    let songs: [Song]
    var showArt = true
    var showTrackNumber = false
    var source: PlaybackSource = .unknown
    @Environment(AudioPlayer.self) private var player
    @State private var downloadManager = DownloadManager.shared

    var body: some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            SongRowView(song: song, showArt: showArt, showTrackNumber: showTrackNumber,
                        disableSwipeActions: true) {
                player.playSong(song, fromQueue: songs, startIndex: index, source: source)
            }
            .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                      leading: 16,
                                      bottom: AppSettings.shared.listDensity.verticalPadding,
                                      trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing) {
                Button { player.addToQueue([song]) } label: {
                    Image(systemName: "text.append")
                }
                .tint(.blue)
                .accessibilityLabel("Add to Queue")
                if downloadManager.isDownloaded(song.id) {
                    Button(role: .destructive) {
                        downloadManager.deleteSong(song.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete download")
                }
            }
        }
    }
}

private extension View {
    /// An offline page: a plain list on its cover's colour, its bar bare like the online
    /// pages' — the name is under the cover already.
    func offlinePage(title: String, coverArt: String?) -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .background(ArtworkCanvas(coverArt: coverArt))
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Offline Album Detail

struct OfflineAlbumDetailView: View {
    let album: OfflineAlbum

    var body: some View {
        List {
            OfflinePageHeader(title: album.name, subtitle: album.artist,
                              songs: album.songs, source: .album(id: album.id, name: album.name)) {
                CoverArtAsyncImage(coverArt: album.coverArt, size: 260)
            }
            .clearRow()
            OfflineSongRows(songs: album.songs, showArt: false, showTrackNumber: true,
                            source: .album(id: album.id, name: album.name))
            ListSummaryRow(text: ListSummaryRow.text(year: album.songs.first?.year, songs: album.songs))
            ListEndSpacer().clearRow()
        }
        .offlinePage(title: album.name, coverArt: album.coverArt)
    }
}

// MARK: - Offline Playlist Detail

/// The locally-playable subset of a snapshotted playlist.
struct OfflinePlaylistDetailView: View {
    let snapshot: OfflinePlaylistSnapshot
    let availableSongs: [Song]

    var body: some View {
        List {
            OfflinePageHeader(title: snapshot.name,
                              songs: availableSongs, source: .playlist(id: snapshot.id, name: snapshot.name)) {
                if let period = WrappedCovers.period(for: snapshot.id) {
                    GeneratedCoverView(nature: .retrospective(period.coverLabel), size: 260, cornerRadius: 12)
                } else {
                    CoverArtAsyncImage(coverArt: snapshot.coverArt, size: 260)
                }
            }
            .clearRow()
            OfflineSongRows(songs: availableSongs, source: .playlist(id: snapshot.id, name: snapshot.name))
            ListSummaryRow(text: ListSummaryRow.text(songs: availableSongs))
            ListEndSpacer().clearRow()
        }
        .offlinePage(title: snapshot.name, coverArt: snapshot.coverArt)
    }
}

// MARK: - Offline Artist Detail

struct OfflineArtistDetailView: View {
    let artist: OfflineArtist
    @State private var layoutWidth: CGFloat = 0

    private var albums: [OfflineAlbum] { OfflineAlbum.group(artist.songs) }

    /// Two covers across, as the artist pages online.
    private var cardSize: CGFloat {
        guard layoutWidth > 0 else { return 160 }
        return max((layoutWidth - 32 - 16) / 2, 100)
    }

    var body: some View {
        List {
            OfflinePageHeader(title: artist.name,
                              detail: OfflineLibraryView.count(albums.count, "album") + " · "
                                  + OfflineLibraryView.count(artist.songs.count, "song"),
                              songs: artist.songs, source: .artist(id: artist.id, name: artist.name)) {
                CoverArtImage(coverArt: artist.coverArt, size: 180, cornerRadius: 90,
                              placeholderName: artist.name, placeholderKind: .artist)
            }
            .clearRow()
            Text("Albums")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .clearRow()
            // Fixed columns rather than adaptive ones: each card is laid out at the width
            // it's given, so the covers can't overhang their cells.
            LazyVGrid(columns: [GridItem(.fixed(cardSize), spacing: 16), GridItem(.fixed(cardSize))],
                      alignment: .leading, spacing: 16) {
                ForEach(albums) { album in OfflineAlbumCard(album: album, size: cardSize) }
            }
            .padding(.horizontal, 16)
            .clearRow()
            ListEndSpacer().clearRow()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layoutWidth = $0 }
        .offlinePage(title: artist.name, coverArt: artist.coverArt)
    }
}
