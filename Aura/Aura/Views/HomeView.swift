import SwiftUI

// MARK: - Home Data Cache

private struct HomeDataCache: Codable {
    let recentSongs: [Song]
    let frequentAlbums: [Album]
    let newestAlbums: [Album]
    let randomAlbums: [Album]
    let starredSongs: [Song]
    let starredArtists: [Artist]
    let songCount: Int
    let albumCount: Int
    let playlistCount: Int
    let timestamp: Date

    /// Cache is keyed per server so switching never surfaces another server's data.
    private static func cacheKey(for serverId: String?) -> String {
        "musika_home_data_cache_\(serverId ?? "none")"
    }

    static func load(serverId: String?) -> HomeDataCache? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: serverId)),
              let cache = try? JSONDecoder().decode(HomeDataCache.self, from: data) else { return nil }
        return cache
    }

    func save(serverId: String?) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey(for: serverId))
        }
    }
}

// MARK: - Home Navigation Routes

enum HomeRoute: Hashable {
    case albumList(title: String, listType: String)
    case starredSongs
    case favouriteArtists
    case recentlyPlayedSongs
    case wrapped(WrappedPeriod)
}

struct HomeView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    @State private var recentSongs: [Song] = []
    @State private var frequentAlbums: [Album] = []
    @State private var newestAlbums: [Album] = []
    @State private var randomAlbums: [Album] = []
    @State private var starredSongs: [Song] = []
    @State private var starredArtists: [Artist] = []
    @State private var isLoading = true
    @State private var appSettings = AppSettings.shared
    @State private var mixGenerator = MixGenerator.shared
    @State private var navPath = NavigationPath()
    @State private var songCount: Int = 0
    @State private var albumCount: Int = 0
    @State private var playlistCount: Int = 0
    @State private var hasLoadedOnce = false
    @State private var lastLoadedAt: Date?
    @State private var recentSongsShowGrid = false
    @State private var loadError: String?
    /// Live vertical scroll offset — drives the top glass fade's opacity (off at rest).
    @State private var scrollY: CGFloat = 0
    /// Measured content width (replaces UIScreen.main.bounds for layout math).
    @State private var layoutWidth: CGFloat = 0

    /// Top safe-area inset (status bar / Dynamic Island height) so content rests below it
    /// while still scrolling up underneath the top glass.
    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top) ?? 59
    }

    private var hasHomeContent: Bool {
        !recentSongs.isEmpty || !frequentAlbums.isEmpty || !newestAlbums.isEmpty
            || !randomAlbums.isEmpty || songCount > 0
    }

    private var homeTitle: String {
        switch appSettings.homeTitleStyle {
        case .none:
            return ""
        case .server:
            let name = serverManager.currentServer?.friendlyName ?? ""
            if !name.isEmpty && name != serverManager.currentServer?.username {
                return name
            }
            return "Home"
        case .home:
            return "Home"
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            Group {
                    if let loadError, !hasHomeContent, !isLoading {
                        ContentUnavailableView {
                            Label(loadError, systemImage: serverManager.hasNetwork ? "exclamationmark.icloud" : "wifi.slash")
                        } description: {
                            Text("Check your connection or server, then try again.")
                        } actions: {
                            Button("Retry") {
                                Task { await loadData(force: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            homeContent
                        }
                        .scrollIndicators(.hidden)
                        .refreshable { await refreshTabContent { await loadData(force: true) } }
                        // Content scrolls UNDER the status bar / island; the inset keeps it
                        // resting below them at the top.
                        .ignoresSafeArea(.container, edges: .top)
                        .contentMargins(.top, TabChrome.contentTop, for: .scrollContent)
                        .overlay(alignment: .top) {
                            // Liquid Glass band pinned at the very top (covers the status bar
                            // area), so scrolled content dissolves under it — like the bottom
                            // bar. Off at rest so resting content stays sharp.
                            Color.clear
                                .frame(height: safeTop + 26)
                                .glassEffect(.regular, in: Rectangle())
                                .mask(LinearGradient(colors: [Color.black, Color.black, Color.black.opacity(0)],
                                                     startPoint: .top, endPoint: .bottom))
                                .opacity(min(max(scrollY / 16, 0), 1))
                                .allowsHitTesting(false)
                                .ignoresSafeArea(.container, edges: .top)
                        }
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                            scrollY = y
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            layoutWidth = width
                        }
                    }
                }
            .background(Color.themeBg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Album.self) { AlbumDetailView(albumId: $0.id) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistId: $0.id, artistName: $0.name, coverArt: $0.coverArt) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id) }
            .navigationDestination(for: Mix.self) { MixDetailView(mix: $0) }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .albumList(let title, let listType):
                    AlbumsFullListView(title: title, listType: listType)
                case .starredSongs:
                    SongsListView(title: "Favorite Songs", fetchType: .starred)
                case .recentlyPlayedSongs:
                    RecentlyPlayedSongsView()
                case .favouriteArtists:
                    ArtistsListView()
                case .wrapped(let period):
                    WrappedView(initialPeriod: period)
                }
            }
            .sheet(isPresented: Binding(
                get: { player.isShowingQueue && !player.isShowingNowPlaying },
                set: { player.isShowingQueue = $0 }
            )) {
                QueueView()
            }
        }
        .onChange(of: player.pendingMixId) { _, newId in
            // Tapping a "mix" source on Now Playing brings us here — open that mix.
            guard let id = newId else { return }
            player.pendingMixId = nil
            guard let mix = mixGenerator.mixes.first(where: { $0.id == id }) else { return }
            // Pop to root first so we don't stack a SECOND copy when the mix is already
            // open in the background (the source was launched from its own detail view).
            if !navPath.isEmpty { navPath = NavigationPath() }
            Task { @MainActor in
                // Push while Now Playing is still dismissing → no root flash, no duplicate.
                try? await Task.sleep(for: .milliseconds(250))
                navPath.append(mix)
            }
        }
        .task {
            // Load THIS server's cache instantly (no animation — avoids zoom on launch)
            if let cache = HomeDataCache.load(serverId: serverManager.currentServer?.id.uuidString) {
                applyCache(cache)
            }
            // Generate / refresh "Made For You" mixes (cheap no-op when fresh)
            // concurrently with the main data load.
            async let mixRefresh: Void = mixGenerator.generateIfNeeded()
            await loadData()
            await mixRefresh
        }
        .onChange(of: serverManager.currentServer?.id) { _, newId in
            // Server switched: clear the previous server's content immediately, then show
            // the NEW server's own cached home if we have it, otherwise a loading skeleton
            // — never the old server's data, never a black screen.
            recentSongs = []; frequentAlbums = []; newestAlbums = []; randomAlbums = []
            starredSongs = []; starredArtists = []
            songCount = 0; albumCount = 0; playlistCount = 0
            loadError = nil
            if let cache = HomeDataCache.load(serverId: newId?.uuidString) {
                applyCache(cache)
            } else {
                isLoading = true
            }
            Task {
                await loadData(force: true)
                await mixGenerator.generateIfNeeded()
            }
        }
    }


    // MARK: - Home Content

    /// The big Home title. With more than one server configured it becomes a
    /// tappable menu to switch between servers (checkmark = active); with a single
    /// server it's the plain title, unchanged.
    @ViewBuilder private var homeTitleLabel: some View {
        if serverManager.servers.count > 1 {
            // The Menu is left-anchored by the trailing Spacer (NOT a full-width label
            // frame — that would make the popover open centred). The content-sized label
            // keeps the dropdown anchored under the title, and `animation(nil)` stops the
            // title from jumping while its text changes on a switch.
            HStack(spacing: 0) {
                Menu {
                    ForEach(serverManager.servers) { server in
                        Button {
                            guard server.id != serverManager.currentServer?.id else { return }
                            serverManager.selectServer(server)
                            Task { await serverManager.testConnection() }
                        } label: {
                            if server.id == serverManager.currentServer?.id {
                                Label(server.friendlyName, systemImage: "checkmark")
                            } else {
                                Text(server.friendlyName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(homeTitle)
                            .auraDisplay(40)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .animation(nil, value: homeTitle)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        } else {
            Text(homeTitle)
                .auraDisplay(40)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // The stats line sits evenly between the title and whatever follows: 24pt above
            // and 24pt below, matching the section spacing. It used to be 6pt above, which
            // pinned it under the title and left it visibly crowded on one side.
            VStack(alignment: .leading, spacing: 24) {
                // Big, left-aligned title — scrolls away with the content and returns at the
                // top on bounce, so it doesn't keep a fixed black bar that breaks the top glass fade.
                if !homeTitle.isEmpty {
                    ZStack(alignment: .trailing) {
                        homeTitleLabel
                        #if !APPSTORE_BUILD
                        if appSettings.betaFeaturesEnabled {
                            NavigationLink {
                                DevLogsView()
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        #endif
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }

                // Server stats bar (configurable) — stays at the very top.
                if appSettings.showStatsOnHome, songCount > 0 || albumCount > 0 || playlistCount > 0 {
                    HStack(spacing: 16) {
                        if songCount > 0 {
                            Label("\(songCount) songs", systemImage: "music.note")
                        }
                        if albumCount > 0 {
                            Label("\(albumCount) albums", systemImage: "square.stack")
                        }
                        if playlistCount > 0 {
                            Label("\(playlistCount) playlists", systemImage: "music.note.list")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.3), value: songCount)
                }
            }

            if isLoading && !hasHomeContent {
                // First load / server switch with no cached content → show a skeleton,
                // never a blank/black screen or the previous server's data.
                homeSkeleton
            } else {
                // Retrospective entry — opt-in (Settings ▸ Wrapped ▸ Show on Home) and,
                // when on, only during a seasonal window. No longer force-shown just
                // because Last.fm is configured. Always reachable from Settings regardless.
                if appSettings.wrappedShowOnHome,
                   let period = WrappedAvailability.offeredPeriods().first {
                    retrospectiveCard(period: period)
                }

                // Made For You — auto-generated mixes
                if !mixGenerator.mixes.isEmpty {
                    madeForYouSection
                }

                ForEach(appSettings.homeSectionOrder) { section in
                    homeSection(for: section)
                }
            }

            Color.clear.frame(height: 80)
        }
        .padding(.top, 2)
    }

    // MARK: - Retrospective ("Wrapped") entry

    private func retrospectiveCard(period: WrappedPeriod) -> some View {
        NavigationLink(value: HomeRoute.wrapped(period)) {
            HStack(spacing: 14) {
                GeneratedCoverView(nature: .retrospective(period.coverLabel), size: 60, cornerRadius: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your \(period.title) Wrapped")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Your top songs, artists & genres")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Made For You (auto-mixes)

    private var madeForYouSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Made For You").font(.title3.bold())
                Spacer()
                if mixGenerator.isGenerating {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(mixGenerator.mixes) { mix in
                        NavigationLink(value: mix) {
                            VStack(alignment: .leading, spacing: 6) {
                                MixCoverView(mix: mix, size: 150, cornerRadius: 12)
                                Text(mix.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(mix.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(height: 28, alignment: .top)
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

    @ViewBuilder
    private func homeSection(for section: HomeSection) -> some View {
        switch section {
        case .upNext:
            if !player.upNextSongs.isEmpty && appSettings.showUpNext {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        player.isShowingQueue = true
                    } label: {
                        sectionHeader("Up Next")
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(player.upNextSongs.prefix(15).enumerated()), id: \.element.id) { index, song in
                                Button {
                                    if let idx = player.queue.firstIndex(where: { $0.id == song.id }) {
                                        player.playSong(song, fromQueue: player.queue, startIndex: idx, source: .queue)
                                    }
                                } label: {
                                    VStack(spacing: 6) {
                                        CoverArtImage(coverArt: song.coverArt, size: 120, cornerRadius: 10)
                                        Text(song.title)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        Text(song.artist ?? "Unknown")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 120)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    songContextMenu(song)
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity
                                ))
                                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.03), value: player.upNextSongs.count)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.3), value: player.upNextSongs.count)
            }
        case .recentlyPlayed:
            if !recentSongs.isEmpty {
                recentlyPlayedSection
            }
        case .recentlyAdded:
            if !newestAlbums.isEmpty {
                albumSection("Recently Added", albums: newestAlbums, listType: "newest")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.3), value: newestAlbums.count)
            }
        case .frequentlyPlayed:
            if !frequentAlbums.isEmpty {
                albumSection("Frequently Played", albums: frequentAlbums, listType: "frequent")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.3), value: frequentAlbums.count)
            }
        case .randomAlbums:
            if !randomAlbums.isEmpty {
                albumSection("Random Albums", albums: randomAlbums, listType: "random")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.3), value: randomAlbums.count)
            }
        case .favoriteSongs:
            if !starredSongs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: HomeRoute.starredSongs) {
                        sectionHeader("Favorite Songs")
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(Array(starredSongs.prefix(50).enumerated()), id: \.element.id) { index, song in
                                songCard(song)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.03), value: starredSongs.count)
                            }
                        }.padding(.horizontal)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.3), value: starredSongs.count)
            }
        case .favoriteArtists:
            if !starredArtists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: HomeRoute.favouriteArtists) {
                        sectionHeader("Favorite Artists")
                    }
                    .buttonStyle(.plain)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(Array(starredArtists.prefix(25).enumerated()), id: \.element.id) { index, artist in
                                ArtistCardView(artist: artist)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.03), value: starredArtists.count)
                            }
                        }.padding(.horizontal)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.3), value: starredArtists.count)
            }
        }
    }

    private func albumSection(_ title: String, albums: [Album], listType: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: HomeRoute.albumList(title: title, listType: listType)) {
                sectionHeader(title)
            }
            .buttonStyle(.plain)
            GeometryReader { geo in
                let spacing: CGFloat = 12
                let horizontalPadding: CGFloat = 16
                let cardSize = (geo.size.width - horizontalPadding - spacing) / 2
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                            AlbumCardView(album: album, size: cardSize)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity
                                ))
                                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(index) * 0.03), value: albums.count)
                        }
                    }.padding(.horizontal, horizontalPadding)
                }
            }
            .frame(height: albumRowHeight)
        }
    }

    /// Height for album row: card image + text labels + spacing
    private var albumRowHeight: CGFloat {
        let cardSize = (layoutWidth - 16 - 12) / 2  // leading padding + spacing
        return max(cardSize, 0) + 36  // image + two text lines
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.title2.bold())
            Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.secondary)
            Spacer()
        }.padding(.horizontal)
    }

    private func songCard(_ song: Song, fromQueue queue: [Song]? = nil, index: Int? = nil, source: PlaybackSource? = nil) -> some View {
        Button {
            let q = queue ?? starredSongs
            let idx = index ?? starredSongs.firstIndex(where: { $0.id == song.id }) ?? 0
            let playSource = source ?? .favorites
            player.playSong(song, fromQueue: q, startIndex: idx, source: playSource)
        } label: {
            HStack(spacing: 12) {
                CoverArtImage(coverArt: song.coverArt, size: 50, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(song.artist ?? "Unknown Artist").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if song.isStarred {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(accentColor)
                }
            }
            .frame(width: 220, alignment: .leading)
            .padding(.trailing, 12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            songContextMenu(song)
        }
    }

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NavigationLink(value: HomeRoute.recentlyPlayedSongs) {
                    sectionHeader("Recently Played")
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        recentSongsShowGrid.toggle()
                    }
                } label: {
                    Image(systemName: recentSongsShowGrid ? "list.bullet" : "square.grid.2x2")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing)
            }

            if recentSongsShowGrid {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(recentSongs.prefix(30).enumerated()), id: \.element.id) { index, song in
                            songCard(song, fromQueue: recentSongs, index: index, source: .recentlyPlayed)
                        }
                    }.padding(.horizontal)
                }
            } else {
                let songsToShow = Array(recentSongs.prefix(8))
                let rowHeight = 50 + appSettings.listDensity.verticalPadding * 2 + 2
                List {
                    ForEach(Array(songsToShow.enumerated()), id: \.element.id) { index, song in
                        SongRowView(song: song) {
                            player.playSong(song, fromQueue: recentSongs, startIndex: index, source: .recentlyPlayed)
                        }
                        .listRowInsets(EdgeInsets(
                            top: appSettings.listDensity.verticalPadding,
                            leading: 16,
                            bottom: appSettings.listDensity.verticalPadding,
                            trailing: 16
                        ))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(songsToShow.count) * rowHeight)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut(duration: 0.3), value: recentSongs.count)
    }

    // MARK: - Data Loading

    /// Warm artwork caches for the home sections as soon as their data lands, so
    /// covers are already in memory before their (lazy) rows scroll into view.
    /// `prefetch` dedupes and skips already-cached entries, so repeat calls are cheap.
    /// Populate the home @State from a cached snapshot and mark loading done.
    private func applyCache(_ cache: HomeDataCache) {
        recentSongs = cache.recentSongs
        frequentAlbums = cache.frequentAlbums
        newestAlbums = cache.newestAlbums
        randomAlbums = cache.randomAlbums
        starredSongs = cache.starredSongs
        starredArtists = cache.starredArtists
        songCount = cache.songCount
        albumCount = cache.albumCount
        playlistCount = cache.playlistCount
        isLoading = false
        prefetchHomeCovers()
    }

    /// Shimmering placeholder shown on first load / server switch instead of a black
    /// screen or the previous server's content.
    private var homeSkeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Inside a horizontal ScrollView like the real "Made For You" row. As a bare
            // HStack its 3×176 + gaps = 560pt intrinsic width forced the whole VStack —
            // page title included — wider than the screen, shifting everything left.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.themeSecondaryBg)
                            .frame(width: 176, height: 176)
                    }
                }
                .padding(.horizontal, 16)
                .shimmering()
            }
            .scrollDisabled(true)

            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.themeSecondaryBg)
                        .frame(width: 150, height: 22)
                        .padding(.horizontal, 16)
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8).fill(Color.themeSecondaryBg)
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.themeSecondaryBg)
                                    .frame(width: 180, height: 13)
                                RoundedRectangle(cornerRadius: 4).fill(Color.themeSecondaryBg)
                                    .frame(width: 120, height: 11)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .shimmering()
            }
        }
    }

    private func prefetchHomeCovers() {
        let cardSize = layoutWidth > 0 ? (layoutWidth - 16 - 12) / 2 : 180
        let albumArt = (newestAlbums + frequentAlbums + randomAlbums).compactMap(\.coverArt)
        ArtworkCache.shared.prefetch(coverArtIds: albumArt, pointSize: cardSize)
        ArtworkCache.shared.prefetch(coverArtIds: starredSongs.compactMap(\.coverArt), pointSize: 50)
        ArtworkCache.shared.prefetch(coverArtIds: starredArtists.compactMap(\.coverArt), pointSize: 44)
        ArtworkCache.shared.prefetch(coverArtIds: recentSongs.compactMap(\.coverArt), pointSize: 50)
    }

    private func loadData(force: Bool = false) async {
        guard let server = serverManager.currentServer else { return }
        // Skip if loaded recently (within 60s) unless forced (pull-to-refresh)
        if !force, let last = lastLoadedAt, Date().timeIntervalSince(last) < 60 { return }
        isLoading = true
        loadError = nil
        async let frequent = SubsonicClient.shared.getAlbumList2(server: server, type: "frequent", size: 25)
        async let newest = SubsonicClient.shared.getAlbumList2(server: server, type: "newest", size: 25)
        async let random = SubsonicClient.shared.getAlbumList2(server: server, type: "random", size: 25)
        async let starred = SubsonicClient.shared.getStarred2(server: server)
        async let playlists = SubsonicClient.shared.getPlaylists(server: server)
        async let scanStatus = SubsonicClient.shared.getScanStatus(server: server)
        async let albumTotal = SubsonicClient.shared.getAlbumCount(server: server)
        do {
            let (f, n, rand, s, pl, scan, totalAlbums) = try await (frequent, newest, random, starred, playlists, scanStatus, albumTotal)
            await MainActor.run {
                let update = {
                    frequentAlbums = f; newestAlbums = n
                    randomAlbums = rand; starredSongs = s.song ?? []; starredArtists = s.artist ?? []
                    songCount = scan.count ?? 0
                    albumCount = totalAlbums
                    playlistCount = pl.count
                    isLoading = false
                }
                if hasLoadedOnce {
                    withAnimation(.easeInOut(duration: 0.4)) { update() }
                } else {
                    update()
                    hasLoadedOnce = true
                }
                // Warm album/favorite covers now so they're ready before the
                // horizontal rows scroll into view (no grey-placeholder flash).
                prefetchHomeCovers()
            }

            // Fetch recently played songs in parallel (doesn't block home content)
            let recentIds = PlayHistory.shared.recentSongIds(limit: 30)
            let fetchedRecent = await Self.fetchSongs(ids: recentIds, server: server)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    recentSongs = fetchedRecent
                }
                ArtworkCache.shared.prefetch(coverArtIds: fetchedRecent.compactMap(\.coverArt), pointSize: 50)
            }

            lastLoadedAt = Date()

            // Persist to cache
            let cache = HomeDataCache(
                recentSongs: fetchedRecent, frequentAlbums: f, newestAlbums: n,
                randomAlbums: rand, starredSongs: s.song ?? [],
                starredArtists: s.artist ?? [],
                songCount: scan.count ?? 0, albumCount: totalAlbums,
                playlistCount: pl.count, timestamp: Date()
            )
            cache.save(serverId: serverManager.currentServer?.id.uuidString)
        } catch {
            AppLogger.shared.log("❌ Home load error: \(error.localizedDescription)")
            await MainActor.run {
                isLoading = false
                // Cached content on screen → silent; blank Home → explain + offer retry.
                if !hasHomeContent {
                    loadError = serverManager.hasNetwork ? "Server Unreachable" : "No Internet Connection"
                }
            }
        }
    }

    /// Fetches songs by id, keeping input order, with at most 5 requests in flight.
    static func fetchSongs(ids: [String], server: ServerConfig, maxConcurrent: Int = 10) async -> [Song] {
        await withTaskGroup(of: (Int, Song?).self) { group in
            var iterator = ids.enumerated().makeIterator()
            for _ in 0..<maxConcurrent {
                guard let (index, id) = iterator.next() else { break }
                group.addTask {
                    let song = try? await SubsonicClient.shared.getSong(server: server, id: id)
                    return (index, song)
                }
            }
            var results = [(Int, Song)]()
            for await (index, song) in group {
                if let song { results.append((index, song)) }
                if let (nextIndex, nextId) = iterator.next() {
                    group.addTask {
                        let song = try? await SubsonicClient.shared.getSong(server: server, id: nextId)
                        return (nextIndex, song)
                    }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    @ViewBuilder
    private func songContextMenu(_ song: Song) -> some View {
        Button { player.playNext(song) } label: {
            Label("Play Next", systemImage: "text.insert")
        }
        Button { player.addToQueue(song) } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
        Divider()
        Button { toggleStar(song) } label: {
            Label(song.isStarred ? "Unfavorite" : "Favorite",
                  systemImage: song.isStarred ? "heart.slash" : "heart")
        }
        if let albumId = song.albumId {
            Button { player.pendingAlbumId = albumId } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
        if let artistId = song.artistId {
            Button { player.pendingArtistId = artistId } label: {
                Label("Go to Artist", systemImage: "person")
            }
        }
    }

    private func toggleStar(_ song: Song) {
        guard let server = serverManager.currentServer else { return }
        Task {
            if song.isStarred {
                try? await SubsonicClient.shared.unstar(server: server, id: song.id)
            } else {
                try? await SubsonicClient.shared.star(server: server, id: song.id)
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}


/// Applies `.searchable` only when the Home search bar is enabled in settings.
