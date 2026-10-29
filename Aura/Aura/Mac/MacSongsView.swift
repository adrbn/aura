import SwiftUI

/// Every song in the library, in one table — or the songs of one of the library's lists: the
/// favourites, the ones played last, a genre's.
///
/// Subsonic has no "all songs" call, so this is `search3` with an empty query, paged — the
/// same trick the iOS app's bulk operations use. The whole library is pulled once per
/// launch rather than paged in on scroll: a `Table` that grows underneath you loses the
/// selection and the scroll position, and a personal library fits in memory comfortably.
struct MacSongsView: View {
    enum Kind: Hashable {
        case all, favorites, recentlyPlayed, frequentlyPlayed, random
        case genre(String)
    }

    /// The phone's song sorts, under the same names.
    enum Sort: String, CaseIterable {
        case none = "Default"
        case title = "Title"
        case artist = "Artist"
        case album = "Album"
        case year = "Year"
        case duration = "Duration"
        case recentlyAdded = "Recently Added"
    }

    var kind: Kind = .all
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var songs: [Song] = []
    /// `songs` in the chosen order, kept rather than resorted on every render.
    @State private var sorted: [Song] = []
    @State private var isLoading = false
    /// Saved per list, as on the phone.
    @AppStorage private var sortOrder: Sort
    @AppStorage private var sortAscending: Bool

    init(kind: Kind = .all) {
        self.kind = kind
        let key: String
        switch kind {
        case .all: key = "all"
        case .favorites: key = "starred"
        case .recentlyPlayed: key = "recentSongs"
        case .frequentlyPlayed: key = "frequentSongs"
        case .random: key = "random"
        case .genre: key = "genre"
        }
        // The phone's defaults: the whole library and the favourites newest first, the rest
        // in their own order.
        let byDate = kind == .all || kind == .favorites
        _sortOrder = AppStorage(wrappedValue: byDate ? .recentlyAdded : .none, "mac_songs_sort_\(key)")
        _sortAscending = AppStorage(wrappedValue: true, "mac_songs_sort_ascending_\(key)")
    }

    private let pageSize = 500
    /// A stop, so a mis-configured server can't spin forever.
    private let ceiling = 20_000

    private var title: Text {
        switch kind {
        case .all: return Text("Songs")
        case .favorites: return Text("Favorites")
        case .recentlyPlayed: return Text("Recently Played")
        case .frequentlyPlayed: return Text("Frequently Played")
        case .random: return Text("Random")
        case .genre(let name): return Text(verbatim: name)
        }
    }

    private var source: PlaybackSource {
        switch kind {
        case .all: return .songs
        case .favorites: return .favorites
        case .recentlyPlayed: return .recentlyPlayed
        case .frequentlyPlayed, .random: return .songs
        case .genre(let name): return .genre(name: name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if songs.isEmpty && isLoading {
                MacLoadingState()
            } else if songs.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    title.auraDisplay(52).lineLimit(1)
                    Text("^[\(songs.count) song](inflect: true)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    sortMenu
                    Button { player.playShuffled(songs, source: source) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 10)
                MacSongTable(songs: sorted, source: source)
            }
        }
        .navigationTitle(title)
        .task { await load() }
        .onChange(of: songs) { _, _ in resort() }
        .onChange(of: isLoading) { _, _ in resort() }
        .onChange(of: sortOrder) { _, _ in resort() }
        .onChange(of: sortAscending) { _, _ in resort() }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortOrder) {
                ForEach(Sort.allCases, id: \.self) { order in
                    Text(label(for: order)).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button {
                sortAscending.toggle()
            } label: {
                Label(sortAscending ? "Descending" : "Ascending",
                      systemImage: sortAscending ? "arrow.down" : "arrow.up")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .help("Sort By")
    }

    /// "Default" said nothing about what order it was; each list names its own.
    private func label(for order: Sort) -> LocalizedStringKey {
        guard order == .none else { return LocalizedStringKey(order.rawValue) }
        switch kind {
        case .all, .genre: return "Server Order"
        case .favorites: return "Date Liked"
        case .recentlyPlayed: return "Last Played"
        case .frequentlyPlayed: return "Most Played"
        case .random: return "Shuffled"
        }
    }

    /// The phone's sort. While the library is still paging in, rows keep their arrival order
    /// so they stay put; the chosen sort applies once it's all in.
    private func resort() {
        if isLoading { sorted = songs; return }
        let ordered: [Song]
        switch sortOrder {
        case .none:
            // Favourites' own order is when each was liked, newest first.
            ordered = kind == .favorites ? songs.sorted { ($0.starred ?? "") > ($1.starred ?? "") } : songs
        case .recentlyAdded:
            // Newest first when ascending, the way the phone's list opens.
            ordered = songs.sorted { ($0.created ?? "") > ($1.created ?? "") }
        case .title:
            ordered = songs.sorted { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
        case .artist:
            ordered = songs.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .album:
            ordered = songs.sorted { ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending }
        case .year:
            ordered = songs.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        case .duration:
            ordered = songs.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        sorted = sortAscending ? ordered : ordered.reversed()
    }

    private func load() async {
        guard let server = serverManager.currentServer, songs.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        switch kind {
        case .all:
            await loadPaged { try await SubsonicClient.shared.search3(
                server: server, query: "", artistCount: 0, albumCount: 0,
                songCount: pageSize, songOffset: $0
            ).song ?? [] }
        case .genre(let name):
            await loadPaged { try await SubsonicClient.shared.getSongsByGenre(
                server: server, genre: name, count: pageSize, offset: $0) }
        case .favorites:
            songs = (try? await SubsonicClient.shared.getStarred2(server: server).song) ?? []
        case .recentlyPlayed:
            songs = await Self.songs(ids: PlayHistory.shared.recentSongIds(limit: 100), server: server)
        case .frequentlyPlayed:
            songs = (try? await Self.frequentSongs(server: server)) ?? []
        case .random:
            songs = (try? await SubsonicClient.shared.getRandomSongs(server: server, size: 50)) ?? []
        }
    }

    /// The phone's Frequently Played: the songs of the albums the server lists as frequent,
    /// narrowed to the ones played, most played first — the server has no list of songs by
    /// plays. Falls back to the albums' songs when the server sends no counts.
    private static func frequentSongs(server: ServerConfig) async throws -> [Song] {
        let albums = try await SubsonicClient.shared.getAlbumList2(server: server, type: "frequent", size: 20)
        var all: [Song] = []
        for album in albums {
            all += try await SubsonicClient.shared.getAlbum(server: server, id: album.id).song ?? []
        }
        let played = all.filter { ($0.playCount ?? 0) > 0 }.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        return played.isEmpty ? all : Array(played.prefix(100))
    }

    /// Pages of `pageSize` from the offset, until a short page or the ceiling.
    private func loadPaged(_ page: (Int) async throws -> [Song]) async {
        var collected: [Song] = []
        var seen = Set<String>()
        while collected.count < ceiling {
            guard let batch = try? await page(collected.count), !batch.isEmpty else { break }

            // Deduplicated, and stopped as soon as a page adds nothing new. Not every
            // server honours songOffset on an empty query — some hand back the same page
            // every time, which used to run this straight into the ceiling and report a
            // library of exactly 20,000 songs that didn't exist.
            let fresh = batch.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            collected += fresh
            songs = collected
            if batch.count < pageSize { break }
        }
        songs = collected
    }

    /// Songs by id, in the ids' order, ten requests at a time. The play history keeps ids,
    /// and the server has no call for many songs at once.
    static func songs(ids: [String], server: ServerConfig) async -> [Song] {
        var found: [String: Song] = [:]
        for start in stride(from: 0, to: ids.count, by: 10) {
            await withTaskGroup(of: Song?.self) { group in
                for id in ids[start..<min(start + 10, ids.count)] {
                    group.addTask { try? await SubsonicClient.shared.getSong(server: server, id: id) }
                }
                for await song in group { if let song { found[song.id] = song } }
            }
        }
        return ids.compactMap { found[$0] }
    }
}

/// The phone's Album Artists: the artists with an album of their own, not only guest credits.
struct MacAlbumArtistsView: View {
    @State private var serverManager = ServerManager.shared
    @State private var artists: [Artist] = []
    @State private var isLoading = false

    var body: some View {
        MacGrid(title: "Album Artists", items: artists, isLoading: isLoading, emptyMessage: "No artists") { artist in
            NavigationLink(value: artist) {
                MacCoverTile(coverArt: artist.coverArt, title: artist.name,
                             subtitle: artist.albumCount.map { String(localized: "\($0) albums") },
                             placeholderName: artist.name, circular: true)
            }
            .buttonStyle(MacPressStyle())
        }
        .navigationTitle("Album Artists")
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer, artists.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        artists = ((try? await SubsonicClient.shared.getArtists(server: server)) ?? []).filter { ($0.albumCount ?? 0) > 0 }
    }
}

/// A genre, as a value a page can be pushed for.
struct MacGenre: Hashable { let name: String }

/// The library's genres, the largest first, each opening its songs.
struct MacGenresView: View {
    @State private var serverManager = ServerManager.shared
    @State private var genres: [GenreEntry] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Genres").auraDisplay(52)
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 4)
            if isLoading && genres.isEmpty {
                MacLoadingState()
            } else if genres.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "guitars")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(genres, id: \.value) { genre in
                            NavigationLink(value: MacGenre(name: genre.value)) { tile(genre) }
                                .buttonStyle(MacPressStyle())
                                .macHoverLift(scale: 1.015)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Genres")
        .task { await load() }
    }

    /// The Home's quick-pick tile, without the cover: a name and its count, one glance.
    private func tile(_ genre: GenreEntry) -> some View {
        HStack {
            Text(genre.value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if let count = genre.songCount {
                Text("\(count) songs").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        defer { isLoading = false }
        do {
            genres = try await SubsonicClient.shared.getGenres(server: server)
                .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        } catch {
            AppLogger.shared.log("❌ genres failed: \(error.localizedDescription)")
        }
    }
}
