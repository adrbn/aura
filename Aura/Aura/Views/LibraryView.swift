import SwiftUI

struct LibraryView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var appSettings = AppSettings.shared
    @State private var navPath = NavigationPath()
    @State private var scrollY: CGFloat = 0
    @State private var showCategoriesEditor = false

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                TabTitleRow("library") {
                    Button {
                        showCategoriesEditor = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                // A menu of destinations, so it reads as one card rather than a run of
                // full-bleed rows: inset and rounded, the shape iOS gives this exact
                // pattern everywhere else — Settings included, two screens away.
                //
                // Left alone a `List` paints each row with `systemBackground`, which is
                // pure black: a slab below the canvas rather than rows on it.
                ForEach(appSettings.enabledLibraryCategories) { category in
                    NavigationLink(value: category) {
                        // The icon carries the accent, the label stays white. Colouring
                        // both meant every row was accent-coloured, and a colour that
                        // applies to everything ranks nothing — it stops reading as
                        // emphasis and starts reading as the text colour.
                        Label {
                            Text(category.rawValue).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: category.icon).foregroundStyle(accentColor)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.themeBg)
            .scrollIndicators(.hidden)
            .tabRootGlass(scrollY: $scrollY)
            .sheet(isPresented: $showCategoriesEditor) {
                NavigationStack { LibraryCategoriesEditor() }
            }
            .navigationDestination(for: LibraryCategory.self) { category in
                switch category {
                case .songs: SongsListView(title: "Songs", fetchType: .all)
                case .recentlyPlayed: SongsListView(title: "Recently Played", fetchType: .recentSongs)
                case .albums: AlbumsGridView()
                case .favourites: SongsListView(title: "Favorite Songs", fetchType: .starred)
                case .frequentlyPlayed: SongsListView(title: "Frequently Played", fetchType: .frequentSongs)
                case .random: SongsListView(title: "Random", fetchType: .random)
                case .genres: GenresListView()
                case .artists: ArtistsFullListView()
                case .albumArtists: ArtistsFullListView(albumArtistsOnly: true)
                case .downloaded: DownloadManagerView()
                case .radar: MixDetailView(mix: RadarService.shared.current?.mix ?? Radar.emptyMix)
                }
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(albumId: album.id)
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(artistId: artist.id, artistName: artist.name, coverArt: artist.coverArt)
            }
            .navigationDestination(for: DeepLinkArtist.self) { link in
                ArtistDetailView(artistId: link.id)
            }
            .navigationDestination(for: DeepLinkAlbum.self) { link in
                AlbumDetailView(albumId: link.id)
            }
            .navigationDestination(for: DeepLinkFavorites.self) { _ in
                SongsListView(title: "Favorite Songs", fetchType: .starred)
            }
            .navigationDestination(for: DeepLinkGenre.self) { link in
                GenreSongsView(genre: GenreEntry(songCount: nil, albumCount: nil, value: link.name))
            }
            .navigationDestination(for: DeepLinkRecentlyPlayed.self) { _ in
                RecentlyPlayedSongsView()
            }
            .navigationDestination(for: DeepLinkFrequentlyPlayed.self) { _ in
                SongsListView(title: "Frequently Played", fetchType: .frequentSongs)
            }
        }
        .onAppear { consumeAllPending() }
        .onChange(of: player.pendingArtistId) { _, _ in consumePendingArtist() }
        .onChange(of: player.pendingAlbumId) { _, _ in consumePendingAlbum() }
        .onChange(of: player.pendingFavoritesOpen) { _, _ in consumePendingFavorites() }
        .onChange(of: player.pendingGenreName) { _, _ in consumePendingGenre() }
        .onChange(of: player.pendingRecentlyPlayedOpen) { _, _ in consumePendingRecentlyPlayed() }
        .onChange(of: player.pendingFrequentlyPlayedOpen) { _, _ in consumePendingFrequentlyPlayed() }
    }

    // MARK: - Pending deep-link consumption
    // Each flag is consumed at most once: handlers read the LIVE value and clear it
    // before pushing, so onAppear and onChange can never both push for one flag.

    private func consumeAllPending() {
        consumePendingArtist()
        consumePendingAlbum()
        consumePendingFavorites()
        consumePendingGenre()
        consumePendingRecentlyPlayed()
        consumePendingFrequentlyPlayed()
    }

    private func consumePendingArtist() {
        guard let id = player.pendingArtistId else { return }
        player.pendingArtistId = nil
        // Pop back to root then push the artist
        if !navPath.isEmpty {
            navPath = NavigationPath()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                navPath.append(DeepLinkArtist(id: id))
            }
        } else {
            navPath.append(DeepLinkArtist(id: id))
        }
    }

    private func consumePendingAlbum() {
        guard let id = player.pendingAlbumId else { return }
        player.pendingAlbumId = nil
        navPath.append(DeepLinkAlbum(id: id))
    }

    private func consumePendingFavorites() {
        guard player.pendingFavoritesOpen else { return }
        player.pendingFavoritesOpen = false
        navPath.append(DeepLinkFavorites())
    }

    private func consumePendingGenre() {
        guard let name = player.pendingGenreName else { return }
        player.pendingGenreName = nil
        navPath.append(DeepLinkGenre(name: name))
    }

    private func consumePendingRecentlyPlayed() {
        guard player.pendingRecentlyPlayedOpen else { return }
        player.pendingRecentlyPlayedOpen = false
        navPath.append(DeepLinkRecentlyPlayed())
    }

    private func consumePendingFrequentlyPlayed() {
        guard player.pendingFrequentlyPlayedOpen else { return }
        player.pendingFrequentlyPlayedOpen = false
        navPath.append(DeepLinkFrequentlyPlayed())
    }
}

struct DeepLinkArtist: Hashable { let id: String }
struct DeepLinkAlbum: Hashable { let id: String }
struct DeepLinkFavorites: Hashable { let id = UUID() }
struct DeepLinkGenre: Hashable { let name: String }
struct DeepLinkRecentlyPlayed: Hashable { let id = UUID() }
struct DeepLinkFrequentlyPlayed: Hashable { let id = UUID() }

// MARK: - Library Categories Editor

struct LibraryCategoriesEditor: View {
    @Environment(\.appAccentColor) private var accentColor
    @State private var appSettings = AppSettings.shared

    var disabledCategories: [LibraryCategory] {
        LibraryCategory.allCases.filter { !appSettings.enabledLibraryCategories.contains($0) }
    }

    var body: some View {
        List {
            Section("Enabled") {
                ForEach(appSettings.enabledLibraryCategories) { category in
                    HStack {
                        Image(systemName: category.icon)
                            .foregroundStyle(accentColor)
                            .frame(width: 28)
                        Text(category.rawValue)
                        Spacer()
                        Button {
                            appSettings.enabledLibraryCategories.removeAll { $0 == category }
                            appSettings.save()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .onMove { source, dest in
                    appSettings.enabledLibraryCategories.move(fromOffsets: source, toOffset: dest)
                    appSettings.save()
                }
            }

            if !disabledCategories.isEmpty {
                Section("Available") {
                    ForEach(disabledCategories) { category in
                        HStack {
                            Image(systemName: category.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            Text(category.rawValue)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                appSettings.enabledLibraryCategories.append(category)
                                appSettings.save()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(accentColor)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
        .navigationTitle("library categories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Albums Grid

struct AlbumsGridView: View {
    @Environment(ServerManager.self) private var serverManager
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var sortType = "alphabeticalByName"

    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            if isLoading {
                SkeletonAlbumGrid(count: 8)
                    .padding(.top, 16)
            } else if loadFailed && albums.isEmpty {
                LoadErrorView {
                    isLoading = true
                    loadFailed = false
                    Task { await loadAlbums() }
                }
                .padding(.top, 100)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(albums) { album in
                        AlbumCardView(album: album)
                    }
                }
                .padding()
            }

            Color.clear.frame(height: 80)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("albums")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAlbums() }
    }

    private func loadAlbums() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let result = try await SubsonicClient.shared.getAlbumList2(
                server: server, type: sortType, size: 500
            )
            await MainActor.run {
                albums = result
                isLoading = false
            }
        } catch {
            AppLogger.shared.log("❌ Albums load error: \(error.localizedDescription)")
            await MainActor.run {
                isLoading = false
                loadFailed = true
            }
        }
    }
}

// MARK: - Genres List

struct GenresListView: View {
    @Environment(ServerManager.self) private var serverManager
    @State private var genres: [GenreEntry] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        Group {
            if isLoading {
                List {
                    ForEach(0..<12, id: \.self) { _ in
                        SkeletonGenreRow()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            } else if loadFailed && genres.isEmpty {
                LoadErrorView {
                    isLoading = true
                    loadFailed = false
                    Task { await loadGenres() }
                }
            } else {
                List(genres, id: \.value) { genre in
                    NavigationLink {
                        GenreSongsView(genre: genre)
                    } label: {
                        HStack {
                            Text(genre.value)
                            Spacer()
                            if let count = genre.songCount {
                                Text("\(count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadGenres() }
    }

    private func loadGenres() async {
        guard let server = serverManager.currentServer else { return }
        if let result = try? await SubsonicClient.shared.getGenres(server: server) {
            await MainActor.run {
                genres = result.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
                loadFailed = true
            }
        }
    }
}

// MARK: - Genre Songs View

struct GenreSongsView: View {
    let genre: GenreEntry
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var offset = 0
    @State private var hasMore = true
    private let pageSize = 50

    var body: some View {
        Group {
            if isLoading && songs.isEmpty {
                List {
                    SkeletonSongList(count: 12)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            } else {
                List {
                    ForEach(songs) { song in
                        SongRowView(song: song) {
                            if let idx = songs.firstIndex(where: { $0.id == song.id }) {
                                player.playSong(song, fromQueue: songs, startIndex: idx, source: .genre(name: genre.value))
                            }
                        }
                        .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                                  leading: 16,
                                                  bottom: AppSettings.shared.listDensity.verticalPadding,
                                                  trailing: 16))
                        .onAppear {
                            if song.id == songs.last?.id && hasMore {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(genre.value)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard !songs.isEmpty else { return }
                    player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: .genre(name: genre.value))
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(songs.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard !songs.isEmpty else { return }
                    player.playShuffled(songs, source: .genre(name: genre.value))
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(songs.isEmpty)
            }
        }
        .task { await loadSongs() }
    }

    private func loadSongs() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let result = try await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre.value, count: pageSize, offset: 0)
            await MainActor.run {
                songs = result
                offset = result.count
                hasMore = result.count >= pageSize
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    private func loadMore() async {
        guard let server = serverManager.currentServer, hasMore else { return }
        do {
            let result = try await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre.value, count: pageSize, offset: offset)
            await MainActor.run {
                songs.append(contentsOf: result)
                offset += result.count
                hasMore = result.count >= pageSize
            }
        } catch {
            AppLogger.shared.log("Failed to load more genre songs: \(error.localizedDescription)")
        }
    }
}

// MARK: - Artists Full List

enum ArtistSortOrder: String, CaseIterable {
    case name = "Name"
    case mostPlayed = "Most Played"
    case albumCount = "Album Count"

    var icon: String {
        switch self {
        case .name: return "textformat.abc"
        case .mostPlayed: return "chart.bar.fill"
        case .albumCount: return "square.stack.fill"
        }
    }
}

struct ArtistsFullListView: View {
    @Environment(ServerManager.self) private var serverManager
    @State private var artists: [Artist] = []
    @State private var allArtists: [Artist] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var appSettings = AppSettings.shared
    @State private var sortOrder: ArtistSortOrder = .name
    @State private var searchText = ""
    var albumArtistsOnly: Bool = false

    private var filteredArtists: [Artist] {
        let base = searchText.isEmpty ? allArtists : allArtists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        switch sortOrder {
        case .name:
            return base.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .mostPlayed:
            return base.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .albumCount:
            return base.sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                List {
                    ForEach(0..<15, id: \.self) { _ in
                        SkeletonArtistRow()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            } else if loadFailed && allArtists.isEmpty {
                LoadErrorView {
                    isLoading = true
                    loadFailed = false
                    Task { await loadArtists() }
                }
            } else {
                List(filteredArtists) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 12) {
                            CoverArtImage(coverArt: artist.coverArt, size: 44, cornerRadius: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).font(.subheadline.weight(.medium))
                                HStack(spacing: 4) {
                                    if let count = artist.albumCount {
                                        Text("\(count) albums").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if appSettings.showPlayCounts, let pc = artist.playCount, pc > 0 {
                                        Text("· \(pc) plays").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
                .searchable(text: $searchText, prompt: "Search artists")
            }
        }
        .navigationTitle(albumArtistsOnly ? "Album Artists" : "Artists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ArtistSortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            Label(order.rawValue, systemImage: sortOrder == order ? "checkmark" : order.icon)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task { await loadArtists() }
    }

    private func loadArtists() async {
        guard let server = serverManager.currentServer else { return }
        if let result = try? await SubsonicClient.shared.getArtists(server: server) {
            await MainActor.run {
                var fetched = result
                if albumArtistsOnly {
                    fetched = fetched.filter { ($0.albumCount ?? 0) > 0 }
                }
                allArtists = fetched
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
                loadFailed = true
            }
        }
    }
}
