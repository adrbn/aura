import SwiftUI

/// The library, as on the iPhone: albums, artists, songs, genres and playlists, each with
/// its own orders and filters in the menu beside the sections.
struct TVLibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case albums, artists, songs, genres, playlists
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .albums: "Albums"
            case .artists: "Artists"
            case .songs: "Songs"
            case .genres: "Genres"
            case .playlists: "Playlists"
            }
        }
    }

    enum SongList: String, CaseIterable {
        case starred = "Favorite Songs", recent = "Recently Played", frequent = "Frequently Played", random = "Random"
    }

    /// The server's own album orders, as on the iPhone.
    private static let albumOrders: [(type: String, label: LocalizedStringKey)] = [
        ("alphabeticalByName", "Name"), ("alphabeticalByArtist", "Artist"), ("newest", "Recently Added"),
        ("frequent", "Most Played"), ("recent", "Recently Played"), ("random", "Random"),
    ]

    @State private var section: Section = .albums
    @AppStorage("albums_sort") private var albumSort = "alphabeticalByName"
    @AppStorage("artists_sort") private var artistSort: ArtistSortOrder = .name
    @AppStorage("tv_album_artists_only") private var albumArtistsOnly = false
    @AppStorage("tv_song_list") private var songList: SongList = .starred
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var songs: [Song] = []
    @State private var genres: [GenreEntry] = []
    @State private var playlists: [Playlist] = []
    @State private var loading = false

    private let columns = Array(repeating: GridItem(.fixed(300), spacing: 48, alignment: .top), count: 5)

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                HStack(spacing: 30) {
                    Picker("Library", selection: $section) {
                        ForEach(Section.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 1100)
                    if section != .playlists && section != .genres { options }
                }
                content
                if isEmpty { TVStatus(loading: loading) }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .task(id: loadKey) { await load() }
    }

    @ViewBuilder private var options: some View {
        Menu {
            switch section {
            case .albums:
                Picker("Sort By", selection: $albumSort) {
                    ForEach(Self.albumOrders, id: \.type) { Text($0.label).tag($0.type) }
                }
            case .artists:
                Picker("Sort By", selection: $artistSort) {
                    ForEach(ArtistSortOrder.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                Toggle("Album Artists", isOn: $albumArtistsOnly)
            case .songs:
                Picker("Songs", selection: $songList) {
                    ForEach(SongList.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
            default: EmptyView()
            }
        } label: {
            Image(systemName: section == .songs ? "line.3.horizontal.decrease" : "arrow.up.arrow.down")
                .accessibilityLabel("Sort By")
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .albums:
            LazyVGrid(columns: columns, spacing: 60) { ForEach(albums) { TVAlbumLink(album: $0) } }
        case .artists:
            LazyVGrid(columns: columns, spacing: 60) { ForEach(shownArtists) { TVArtistLink(artist: $0, width: 300) } }
        case .songs:
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 24) {
                        Button { TVPlayback.shared.play(songs, source: songSource) } label: { Label("Play", systemImage: "play.fill") }
                        Button { TVPlayback.shared.play(songs, source: songSource, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 40), GridItem(.flexible())], spacing: 6) {
                        ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                            TVSongRow(song: song, showsArtwork: true) {
                                TVPlayback.shared.play(songs, from: index, source: songSource)
                            }
                        }
                    }
                }
                .padding(.horizontal, 80)
            }
        case .genres:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 4), spacing: 40) {
                ForEach(genres, id: \.value) { genre in
                    NavigationLink(value: TVGenre(name: genre.value)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(genre.value).font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                            if let count = genre.songCount {
                                Text("\(count) songs").font(.system(size: 22)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 80)
        case .playlists:
            LazyVGrid(columns: columns, spacing: 60) { ForEach(playlists) { TVPlaylistLink(playlist: $0) } }
        }
    }

    private var shownArtists: [Artist] {
        let base = albumArtistsOnly ? artists.filter { ($0.albumCount ?? 0) > 0 } : artists
        switch artistSort {
        case .name: return base.sorted { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
        case .mostPlayed: return base.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .albumCount: return base.sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
        }
    }

    private var songSource: PlaybackSource {
        switch songList {
        case .starred: .favorites
        case .recent: .recentlyPlayed
        case .frequent: .frequentlyPlayed
        case .random: .songs
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .albums: albums.isEmpty
        case .artists: shownArtists.isEmpty
        case .songs: songs.isEmpty
        case .genres: genres.isEmpty
        case .playlists: playlists.isEmpty
        }
    }

    /// What a change reloads: the section, the album order (the server sorts) and the song list.
    private var loadKey: String {
        switch section {
        case .albums: "albums-\(albumSort)"
        case .songs: "songs-\(songList.rawValue)"
        default: section.rawValue
        }
    }

    private func load() async {
        guard let server = ServerManager.shared.currentServer else { return }
        let client = SubsonicClient.shared
        loading = true
        defer { loading = false }
        switch section {
        case .albums:
            // The server pages its album list; the pages are asked for until one comes back
            // short. Random is one page: more of it is just more random.
            albums = []
            let page = 500, order = albumSort
            var all: [Album] = []
            while let batch = try? await client.getAlbumList2(server: server, type: order, size: page, offset: all.count),
                  !Task.isCancelled {
                all += batch
                albums = all
                if batch.count < page || order == "random" { break }
            }
        case .artists:
            guard artists.isEmpty else { return }
            artists = (try? await client.getArtists(server: server)) ?? []
        case .songs:
            songs = []
            let list = songList
            let found: [Song]
            switch list {
            case .starred: found = (try? await client.getStarred2(server: server).song) ?? []
            case .random: found = (try? await client.getRandomSongs(server: server, size: 100)) ?? []
            case .recent, .frequent: found = await songsOfAlbums(list == .frequent ? "frequent" : "recent", server: server)
            }
            if !Task.isCancelled { songs = found }
        case .genres:
            guard genres.isEmpty else { return }
            genres = ((try? await client.getGenres(server: server)) ?? []).sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        case .playlists:
            guard playlists.isEmpty else { return }
            playlists = (try? await client.getPlaylists(server: server)) ?? []
        }
    }

    /// As on the iPhone: the server has no list of songs by plays, so the songs of its recent
    /// or frequent albums, narrowed to those played, in that order.
    private func songsOfAlbums(_ type: String, server: ServerConfig) async -> [Song] {
        let client = SubsonicClient.shared
        let albums = (try? await client.getAlbumList2(server: server, type: type, size: 20)) ?? []
        var all: [Song] = []
        for album in albums {
            all += (try? await client.getAlbum(server: server, id: album.id).song) ?? []
        }
        let narrowed = type == "frequent"
            ? all.filter { ($0.playCount ?? 0) > 0 }.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            : all.filter { $0.played != nil }.sorted { ($0.played ?? "") > ($1.played ?? "") }
        return narrowed.isEmpty ? all : Array(narrowed.prefix(100))
    }
}

/// A genre to open: its songs, as an album's page.
struct TVGenre: Hashable { let name: String }

struct TVGenreView: View {
    let genre: TVGenre
    @State private var songs: [Song] = []
    @State private var loading = true
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        TVCollectionPage(title: genre.name, songs: songs, source: .genre(name: genre.name),
                         loading: loading, showsArtwork: true) {
            ZStack {
                accent
                Image(systemName: "guitars.fill").font(.system(size: 160, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .task {
            defer { loading = false }
            guard let server = ServerManager.shared.currentServer else { return }
            songs = (try? await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre.name, count: 500)) ?? []
        }
    }
}

/// Search: the system's on-screen keyboard and dictation, results as shelves.
struct TVSearchView: View {
    @State private var query = ""
    @State private var result: SearchResult3?
    @State private var searching = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if let songs = result?.song, !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Songs").font(.system(size: 36, weight: .bold))
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 40), GridItem(.flexible())], spacing: 6) {
                            ForEach(Array(songs.prefix(10).enumerated()), id: \.offset) { index, song in
                                TVSongRow(song: song, showsArtwork: true) {
                                    TVPlayback.shared.play(songs, from: index, source: .search(query: query))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                }
                TVShelf(title: "Artists", items: result?.artist ?? []) { TVArtistLink(artist: $0) }
                TVShelf(title: "Albums", items: result?.album ?? []) { TVAlbumLink(album: $0) }
                if searching && result == nil { TVStatus(loading: true) }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .searchable(text: $query)
        .task(id: query) { await search() }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { result = nil; return }
        // A moment's pause, so each letter typed doesn't send a request of its own.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, let server = ServerManager.shared.currentServer else { return }
        searching = true
        defer { searching = false }
        let found = try? await SubsonicClient.shared.search3(server: server, query: text, artistCount: 12,
                                                             albumCount: 20, songCount: 20)
        guard !Task.isCancelled else { return }
        result = found
    }
}
