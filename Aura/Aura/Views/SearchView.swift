import SwiftUI

// MARK: - Search tab

/// The Search tab is now a thin host around the shared `SearchResultsContainer`,
/// so Home and the Search tab use the exact same search behaviour.
struct SearchView: View {
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var scrollY: CGFloat = 0

    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top) ?? 59
    }
    private let titleHeight: CGFloat = 52
    private let searchBarHeight: CGFloat = 56

    private var titleOpacity: Double {
        Double(1 - min(max(scrollY / titleHeight, CGFloat(0)), CGFloat(1)))
    }
    /// Header slides up by the title's height as you scroll, so the title disappears and
    /// the search field comes to rest pinned just under the top glass strip.
    private var headerOffset: CGFloat {
        -min(max(scrollY, CGFloat(0)), titleHeight)
    }

    var body: some View {
        NavigationStack(path: $path) {
            SearchResultsContainer(query: $query, navPath: $path)
                // Results scroll UNDER the status bar; reserve room for title + search field.
                .ignoresSafeArea(.container, edges: .top)
                .contentMargins(.top, safeTop + titleHeight + 8 + searchBarHeight, for: .scrollContent)
                // Liquid Glass strip at the very top, fading in on scroll.
                .overlay(alignment: .top) {
                    Color.clear
                        .frame(height: safeTop + 26)
                        .glassEffect(.regular, in: Rectangle())
                        .mask(LinearGradient(colors: [Color.black, Color.black, Color.black.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        .opacity(min(max(scrollY / 16, CGFloat(0)), CGFloat(1)))
                        .allowsHitTesting(false)
                        .ignoresSafeArea(.container, edges: .top)
                }
                // Big-left title (fades + slides away) above the search field (stays, pinning
                // under the glass) — drawn on top of the glass so the field stays sharp.
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        Text("search")
                            .font(.custom("TuafTrial-Bold", size: 40, relativeTo: .largeTitle))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: titleHeight)
                            .padding(.horizontal, 16)
                            .opacity(titleOpacity)
                        SearchFieldBar(text: $query, prompt: "Search library or lyrics…")
                            .frame(height: searchBarHeight)
                    }
                    .padding(.top, safeTop)
                    .offset(y: headerOffset)
                    .ignoresSafeArea(.container, edges: .top)
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                    scrollY = y
                }
                .background(Color.themeBg)
                .toolbar(.hidden, for: .navigationBar)
                .searchDestinations()
        }
    }
}

// MARK: - Shared navigation destinations

extension View {
    /// Registers the navigation destinations every search host needs.
    func searchDestinations() -> some View {
        self
            .navigationDestination(for: Album.self) { AlbumDetailView(albumId: $0.id) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artistId: $0.id, artistName: $0.name, coverArt: $0.coverArt) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id) }
    }
}

// MARK: - Reusable search experience

/// The full search experience — recents-with-thumbnails when the query is empty,
/// ranked results otherwise. Owns its own session state, drives the shared
/// `SearchIndex` engine, and navigates via value-based links so it works inside
/// whichever NavigationStack hosts it (Search tab or Home).
struct SearchResultsContainer: View {
    @Binding var query: String
    /// The host's navigation path — taps push programmatically, which (unlike
    /// `NavigationLink`) works reliably while a `.searchable` field is active.
    @Binding var navPath: NavigationPath
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    @State private var appSettings = AppSettings.shared
    @State private var results = SearchResults()
    @State private var lyricsSongs: [Song] = []
    @State private var isSearching = false
    @State private var isSearchingLyrics = false
    @State private var expandedSections: Set<String> = []
    @State private var history = SearchHistory.shared

    private let collapsedLimit = 4
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        // ONE stable List with conditional rows. Previously this switched between two
        // separate List views on the first keystroke (empty → results); that teardown
        // dropped the search field's keyboard focus, closing the keyboard after one letter.
        // A single List keeps the scroll view (and the field's focus) alive.
        List {
            if trimmedQuery.isEmpty {
                recentsRows
            } else {
                resultsRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.never)
        .background(Color.themeBg)
        .task { SearchIndex.shared.prefetchIfNeeded() }
        .task(id: query) { await runSearch() }
    }

    // MARK: Search execution

    private func runSearch() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            results = SearchResults(); lyricsSongs = []
            isSearching = false; isSearchingLyrics = false; expandedSections = []
            return
        }
        expandedSections = []
        // `.task(id:)` cancels the previous run on each keystroke → debounce + cancel.
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }

        isSearching = true
        let found = await SearchIndex.shared.search(query: q)
        if Task.isCancelled { return }
        results = found
        isSearching = false

        isSearchingLyrics = true
        let lyrics = await SearchIndex.shared.searchLyrics(query: q, excluding: Set(found.songs.map { $0.id }))
        if Task.isCancelled { return }
        // LRCLIB's search matches track/artist/album metadata, not lyric content — so an
        // artist/title query just returns more songs by that artist. Drop those, leaving
        // only genuine phrase hits (e.g. searching a remembered lyric line).
        let ql = q.lowercased()
        lyricsSongs = lyrics.filter { !($0.artist ?? "").lowercased().contains(ql) }
        isSearchingLyrics = false
    }

    // MARK: Recently searched (history with thumbnails)

    @ViewBuilder
    private var recentsRows: some View {
        if history.entries.isEmpty {
            ContentUnavailableView(
                "Search Your Library",
                systemImage: "magnifyingglass",
                description: Text("Find artists, albums, songs, playlists — even by lyrics.")
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(history.entries) { entry in
                    recentEntryRow(entry)
                        .listRowInsets(EdgeInsets(top: appSettings.listDensity.verticalPadding + 2,
                                                  leading: 16, bottom: appSettings.listDensity.verticalPadding + 2, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { history.remove(entry) } label: {
                                Image(systemName: "xmark")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recently Searched").foregroundStyle(accentColor)
                    Spacer()
                    Button("Clear") { history.clear() }.foregroundStyle(accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private func recentEntryRow(_ entry: RecentSearchEntry) -> some View {
        switch entry {
        case .song(let song):
            Button {
                player.playSong(song, source: .search(query: ""))
                history.record(entry) // bump to top
            } label: { recentEntryLabel(entry) }
            .buttonStyle(.plain)
        case .artist(let artist):
            Button { history.record(entry); navPath.append(artist) } label: { recentEntryLabel(entry) }.buttonStyle(.plain)
        case .album(let album):
            Button { history.record(entry); navPath.append(album) } label: { recentEntryLabel(entry) }.buttonStyle(.plain)
        case .playlist(let playlist):
            Button { history.record(entry); navPath.append(playlist) } label: { recentEntryLabel(entry) }.buttonStyle(.plain)
        }
    }

    private func recentEntryLabel(_ entry: RecentSearchEntry) -> some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: entry.coverArt, size: 48, cornerRadius: entry.isCircular ? 24 : 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: entry.playableSong != nil ? "play.circle" : "chevron.right")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: Results

    @ViewBuilder
    private var resultsRows: some View {
        // Main search only. The lyrics search is slower and secondary — showing it up here
        // pushed the already-loaded songs/albums down the page. Its spinner lives at the
        // bottom instead, where the lyric matches actually land, so nothing jumps.
        if isSearching {
            HStack(spacing: 10) {
                ProgressView().tint(.secondary)
                Text("Searching…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        if results.isOffline {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.caption2.weight(.semibold))
                Text("Offline results — downloaded and cached songs only")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }

        if let suggestion = results.suggestedCorrection {
            Button { query = suggestion } label: {
                HStack(spacing: 4) {
                    Text("Did you mean:").font(.subheadline).foregroundStyle(.secondary)
                    Text(suggestion).font(.subheadline.bold()).foregroundStyle(accentColor)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        ForEach(orderedSections(), id: \.self) { section in
            sectionContent(section)
        }

        if isSearchingLyrics {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.secondary)
                Text("Searching lyrics…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        if results.isEmpty && lyricsSongs.isEmpty && !isSearching && !isSearchingLyrics {
            ContentUnavailableView.search(text: trimmedQuery)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }

        Color.clear.frame(height: 140)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func sectionContent(_ section: String) -> some View {
        switch section {
        case "artists":
            if !results.artists.isEmpty {
                let isExpanded = expandedSections.contains("artists")
                let visible = isExpanded ? results.artists : Array(results.artists.prefix(collapsedLimit))
                sectionHeader("Artists")
                ForEach(visible) { artist in
                    entityRow(value: artist, coverArt: artist.coverArt, circular: true,
                              title: artist.name, subtitle: nil) {
                        SearchRanking.shared.recordTap(query: trimmedQuery, resultId: artist.id)
                        history.record(.artist(artist))
                    }
                }
                if !isExpanded && results.artists.count > collapsedLimit {
                    showMoreButton(section: "artists", total: results.artists.count)
                }
            }
        case "songs":
            if !results.songs.isEmpty {
                let isExpanded = expandedSections.contains("songs")
                let visible = isExpanded ? results.songs : Array(results.songs.prefix(collapsedLimit))
                sectionHeader("Songs")
                ForEach(visible) { song in songRow(song) }
                if !isExpanded && results.songs.count > collapsedLimit {
                    showMoreButton(section: "songs", total: results.songs.count)
                }
            }
        case "albums":
            if !results.albums.isEmpty {
                let isExpanded = expandedSections.contains("albums")
                let visible = isExpanded ? results.albums : Array(results.albums.prefix(collapsedLimit))
                sectionHeader("Albums")
                ForEach(visible) { album in
                    entityRow(value: album, coverArt: album.coverArt, circular: false,
                              title: album.name, subtitle: album.artist ?? "Unknown") {
                        SearchRanking.shared.recordTap(query: trimmedQuery, resultId: album.id)
                        history.record(.album(album))
                    }
                }
                if !isExpanded && results.albums.count > collapsedLimit {
                    showMoreButton(section: "albums", total: results.albums.count)
                }
            }
        case "playlists":
            if !results.playlists.isEmpty {
                let isExpanded = expandedSections.contains("playlists")
                let visible = isExpanded ? results.playlists : Array(results.playlists.prefix(collapsedLimit))
                sectionHeader("Playlists")
                ForEach(visible) { playlist in
                    entityRow(value: playlist, coverArt: playlist.coverArt, circular: false,
                              title: playlist.name, subtitle: playlist.songCount.map { "\($0) songs" }) {
                        SearchRanking.shared.recordTap(query: trimmedQuery, resultId: playlist.id)
                        history.record(.playlist(playlist))
                    }
                }
                if !isExpanded && results.playlists.count > collapsedLimit {
                    showMoreButton(section: "playlists", total: results.playlists.count)
                }
            }
        case "lyrics":
            if !lyricsSongs.isEmpty {
                let isExpanded = expandedSections.contains("lyrics")
                let visible = isExpanded ? lyricsSongs : Array(lyricsSongs.prefix(collapsedLimit))
                sectionHeader("Lyrics Match", systemImage: "text.quote", tint: accentColor)
                ForEach(visible) { song in songRow(song) }
                if !isExpanded && lyricsSongs.count > collapsedLimit {
                    showMoreButton(section: "lyrics", total: lyricsSongs.count)
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Row builders

    private func entityRow<V: Hashable>(value: V, coverArt: String?, circular: Bool,
                                        title: String, subtitle: String?, onTap: @escaping () -> Void) -> some View {
        Button {
            onTap()
            navPath.append(value)
        } label: {
            HStack(spacing: 12) {
                CoverArtImage(coverArt: coverArt, size: 44, cornerRadius: circular ? 22 : 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: appSettings.listDensity.verticalPadding + 2,
                                  leading: 16, bottom: appSettings.listDensity.verticalPadding + 2, trailing: 16))
    }

    private func songRow(_ song: Song) -> some View {
        SongRowView(song: song, tappableArtist: false, disableSwipeActions: true) {
            SearchRanking.shared.recordTap(query: trimmedQuery, resultId: song.id)
            player.playSong(song, source: .search(query: trimmedQuery))
            history.record(.song(song))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.addToQueue(song) } label: { Image(systemName: "text.append") }
                .accessibilityLabel("Add to Queue").tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { player.playNext(song) } label: { Image(systemName: "text.insert") }
                .accessibilityLabel("Play Next").tint(.blue)
        }
        .listRowInsets(EdgeInsets(top: appSettings.listDensity.verticalPadding,
                                  leading: 16, bottom: appSettings.listDensity.verticalPadding, trailing: 16))
    }

    private func sectionHeader(_ title: String, systemImage: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.subheadline.weight(.bold)) }
            Text(title).font(.title3.bold())
        }
        .foregroundStyle(tint ?? Color.primary)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private func showMoreButton(section: String, total: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { _ = expandedSections.insert(section) }
        } label: {
            Text("Show more (\(total - collapsedLimit) more)")
                .font(.subheadline).foregroundStyle(accentColor)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 6)
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: Section ordering

    private func orderedSections() -> [String] {
        let q = trimmedQuery.lowercased()
        let hasArtistMatch = results.artists.contains { $0.name.lowercased() == q || $0.name.lowercased().contains(q) }
        let hasAlbumMatch = results.albums.contains { $0.name.lowercased() == q || $0.name.lowercased().hasPrefix(q) }

        // Songs always come first; the most relevant secondary type follows.
        if hasArtistMatch {
            return ["songs", "artists", "albums", "playlists", "lyrics"]
        } else if hasAlbumMatch {
            return ["songs", "albums", "artists", "playlists", "lyrics"]
        } else {
            return ["songs", "albums", "artists", "playlists", "lyrics"]
        }
    }
}
