import SwiftUI

/// Search, over the same ranked index the phone uses — including its offline fallback and
/// its "did you mean" correction.
struct MacSearchView: View {
    @Binding var query: String
    @State private var results = SearchResults()
    @State private var isSearching = false
    @State private var preferences = MacPreferences.shared
    /// What Deezer has for the query that the library doesn't.
    @State private var finds = MacDeezerFinds()
    @Environment(\.macOpenRelease) private var openRelease
    @State private var history = SearchHistory.shared

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var findsShown: Bool { finds.query == trimmed && !finds.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            MacSearchChips(query: $query)
                .padding(.top, 12)
            if isSearching {
                // Replaces the results rather than sitting above them: a query in flight
                // should not leave the previous query's hits on screen looking like answers.
                MacLoadingState()
            } else if results.isEmpty && matchingMixes.isEmpty && !findsShown {
                // Only an operator typed so far: its chips are the answer.
                if LocalSearch.parse(trimmed).isEmpty {
                    Spacer()
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                found
            }
        }
        .navigationTitle("Search")
        .task(id: query) { await run() }
        .task(id: query) { await runDeezer() }
    }

    private var found: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let correction = results.suggestedCorrection {
                    Button { query = correction } label: {
                        HStack(spacing: 4) {
                            Text("Did you mean:").foregroundStyle(.secondary)
                            Text(correction).bold().foregroundStyle(Color.appAccent)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(MacPressStyle())
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                }

                // The generated mixes the query names, as on the phone.
                if !matchingMixes.isEmpty {
                    header("Made For You")
                    row(matchingMixes) { mix in
                        NavigationLink(value: mix) {
                            MacPlayableCard(coverArt: nil, title: mix.title, subtitle: mix.subtitle,
                                            artwork: AnyView(EditorialMixCover(mix: mix, size: preferences.coverSize.shelfWidth,
                                                                               cornerRadius: 8)))
                        }
                        .buttonStyle(MacPressStyle())
                        .simultaneousGesture(TapGesture().onEnded { history.arm(.mix(mix)) })
                    }
                }

                if !results.artists.isEmpty {
                    header("Artists")
                    row(results.artists) { artist in
                        NavigationLink(value: artist) {
                            MacCoverTile(coverArt: artist.coverArt, title: artist.name,
                                         placeholderName: artist.name, circular: true)
                                .frame(width: preferences.coverSize.shelfWidth)
                        }
                        .buttonStyle(MacPressStyle())
                        // Armed, not recorded: opening an artist is not listening to one.
                        .simultaneousGesture(TapGesture().onEnded { history.arm(.artist(artist)) })
                    }
                }

                if !results.albums.isEmpty {
                    header("Albums")
                    row(results.albums) { album in
                        NavigationLink(value: album) {
                            MacCoverTile(coverArt: album.coverArt, title: album.name,
                                         subtitle: album.artist, placeholderName: album.name)
                                .frame(width: preferences.coverSize.shelfWidth)
                        }
                        .buttonStyle(MacPressStyle())
                        .simultaneousGesture(TapGesture().onEnded { history.arm(.album(album)) })
                    }
                }

                if !results.playlists.isEmpty {
                    header("Playlists")
                    row(results.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            MacCoverTile(coverArt: playlist.coverArt, title: playlist.name,
                                         subtitle: playlist.songCount.map { String(localized: "\($0) songs") },
                                         placeholderName: playlist.name)
                                .frame(width: preferences.coverSize.shelfWidth)
                        }
                        .buttonStyle(MacPressStyle())
                        .simultaneousGesture(TapGesture().onEnded { history.arm(.playlist(playlist)) })
                    }
                }

                if !results.songs.isEmpty {
                    header("Songs")
                    // Columns of a set width, as many as fit, from the left: a full-screen
                    // window adds columns rather than stretching a title and its album apart.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 440, maximum: 500), spacing: 32, alignment: .leading)],
                              alignment: .leading, spacing: 2) {
                        ForEach(results.songs) { song in
                            // One song and the music around it, as on the phone: the other
                            // hits share a word with it, not a sound.
                            MacSongRow(song: song, source: .search(query: query))
                                .simultaneousGesture(TapGesture().onEnded { history.record(.song(song)) })
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }

                // Under the library's own, as on the phone: Deezer's songs play their
                // previews and, in the sideload build, can be had; its releases open their page.
                if findsShown {
                    if !finds.songs.isEmpty {
                        header("Songs on Deezer")
                        songColumns {
                            ForEach(finds.songs) { find in
                                MacDeezerSongRow(find: find) { playPreview(find) }
                            }
                        }
                    }
                    if !finds.releases.isEmpty {
                        header("Albums on Deezer")
                        songColumns {
                            ForEach(finds.releases) { release in
                                RadarReleaseRow(release: release) { openRelease(release) }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The songs' set-width columns, for Deezer's rows as for the library's.
    private func songColumns<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 440, maximum: 500), spacing: 32, alignment: .leading)],
                  alignment: .leading, spacing: 2, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
    }

    /// A song found on Deezer, on into the others found.
    private func playPreview(_ find: MacDeezerFind) {
        let queue = finds.songs.compactMap(\.preview)
        guard let song = find.preview, let index = queue.firstIndex(where: { $0.id == song.id }) else {
            ToastManager.shared.show(String(localized: "No preview for this song"), icon: "speaker.slash")
            return
        }
        AudioPlayer.shared.playSong(song, fromQueue: queue, startIndex: index, source: .search(query: finds.query))
    }

    private func header(_ text: LocalizedStringKey) -> some View {
        Text(text).auraDisplay(34)
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 8)
    }

    private func row<T: Identifiable, V: View>(_ items: [T],
                                               @ViewBuilder tile: @escaping (T) -> V) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) { ForEach(items) { tile($0) } }
                .padding(.horizontal, 28)
                .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Only an operator typed so far ("genre:"): no search for the word itself.
        guard !q.isEmpty, !LocalSearch.parse(q).isEmpty else {
            results = SearchResults(); isSearching = false; return
        }
        isSearching = true
        // Debounced by `.task(id:)`, which cancels the previous run on every keystroke.
        try? await Task.sleep(for: .milliseconds(LibraryIndex.shared.isReady ? 120 : 300))
        guard !Task.isCancelled else { return }
        let found = await SearchIndex.shared.search(query: q)
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }

    /// The generated mixes a query names — a word of the title starting with it. The radar
    /// answers to what it is as well as to its name. The phone's, word for word.
    private var matchingMixes: [Mix] {
        let typed = SongQuery.fold(trimmed)
        guard typed.count >= 2 else { return [] }
        var mixes = MixGenerator.shared.mixes
        if AppSettings.shared.radarEnabled {
            mixes.insert(RadarService.shared.current?.mix ?? Radar.emptyMix, at: 0)
        }
        return CoverArtists.distinctLeads(mixes).filter { mix in
            var names = [mix.title]
            if mix.kind == .radar {
                names += [String(localized: "New releases"), "release radar", "nouveautés", "sorties"]
            }
            return names.contains { name in
                let folded = SongQuery.fold(name)
                return folded.hasPrefix(typed) || folded.split(separator: " ").contains { $0.hasPrefix(typed) }
            }
        }
    }

    /// Asks Deezer too, as the phone does — with the radar on, since it's Deezer's catalogue —
    /// and leaves out what the library's own answer already holds, so it waits for that.
    private func runDeezer() async {
        let q = trimmed
        guard AppSettings.shared.radarEnabled, q.count >= 2, !LocalSearch.parse(q).isEmpty else {
            finds = MacDeezerFinds(); return
        }
        if finds.query == q { return }
        try? await Task.sleep(for: .milliseconds(500))
        let deezerQuery = LocalSearch.deezerQuery(q)
        guard !Task.isCancelled, !deezerQuery.isEmpty,
              let found = await RadarCatalog.search(deezerQuery), !Task.isCancelled else { return }
        for _ in 0..<100 where isSearching {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        let made = MacDeezerFinds(query: q, songs: found.songs, albums: found.albums, library: results)
        RadarService.shared.remember(made.releases + made.songs.map(\.release))
        finds = made
    }
}

/// The search operators one click away, and the library's names while one is typed — the
/// phone's chips, over the same index.
struct MacSearchChips: View {
    @Binding var query: String
    var inset: CGFloat = 28

    var body: some View {
        let chips = LibraryIndex.shared.chips(for: query)
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button { query = chip.query } label: {
                            Text(chip.label)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.primary.opacity(0.1), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(MacPressStyle())
                    }
                }
                .padding(.horizontal, inset)
            }
            .scrollClipDisabled()
        }
    }
}

/// A song Deezer's search turned up, with the release it's from as the radar would hold it.
struct MacDeezerFind: Identifiable {
    let hit: DeezerHit
    let release: RadarRelease

    var id: Int { hit.id }
    var preview: Song? { hit.track.previewSong(of: release) }
}

/// What Deezer has for a search that the library's results don't — the phone's `DeezerFinds`,
/// which lives in a file the Mac doesn't build, beside the phone's rows.
struct MacDeezerFinds {
    var query = ""
    var songs: [MacDeezerFind] = []
    var releases: [RadarRelease] = []

    var isEmpty: Bool { songs.isEmpty && releases.isEmpty }

    init() {}

    /// Deezer's answer, less what the library's results already hold. An artist the library
    /// knows keeps their id, so their page is a click away.
    init(query: String, songs: [DeezerHit], albums: [DeezerAlbumHit], library: SearchResults) {
        func artist(_ credit: DeezerHit.Artist) -> ArtistRef {
            let folded = SongQuery.fold(credit.name)
            let known = library.artists.first { SongQuery.fold($0.name) == folded }
            return ArtistRef(id: known?.id ?? "", name: credit.name)
        }
        var seen = Set<Int>()
        self.query = query
        self.songs = songs
            .filter { hit in
                seen.insert(hit.id).inserted && !library.songs.contains {
                    RadarRules.sameTitle($0.title, hit.title) && RadarRules.credits($0.artist, hit.artist.name)
                }
            }
            .map { hit in
                MacDeezerFind(hit: hit, release: RadarRelease(
                    id: String(hit.album.id), title: hit.album.title, artist: artist(hit.artist),
                    released: "", type: "album", cover: hit.album.cover_medium, link: nil))
            }
        self.releases = albums
            .filter { hit in
                !library.albums.contains {
                    RadarRules.sameTitle($0.name, hit.title) && RadarRules.credits($0.artist, hit.artist.name)
                }
            }
            .map { hit in
                RadarRelease(id: String(hit.id), title: hit.title, artist: artist(hit.artist), released: "",
                             type: hit.record_type ?? "album", cover: hit.cover_medium, link: hit.link)
            }
    }
}

/// A song on Deezer, drawn as the library's song rows are: its preview on a click, and in the
/// sideload build, its own Get.
private struct MacDeezerSongRow: View {
    let find: MacDeezerFind
    let play: () -> Void

    @State private var player = AudioPlayer.shared
    @State private var hovering = false
    @Environment(\.appAccentColor) private var accentColor

    private var isCurrent: Bool { player.currentSong?.id == "deezer-\(find.hit.id)" }

    private var canFetch: Bool {
        #if APPSTORE_BUILD
        return false
        #else
        return ReleaseFetcher.shared.isAvailable
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: find.release.cover, size: 52, cornerRadius: 6, placeholderName: find.hit.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(find.hit.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.appAccent : .primary)
                    .lineLimit(1)
                Text("\(find.hit.artist.name) · \(find.release.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            trailing.frame(width: 32)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .opacity(find.preview == nil ? 0.5 : 1)
        .onHover { hovering = $0 }
        .onTapGesture(perform: play)
        .contextMenu {
            Button(action: play) { Label("Play Preview", systemImage: "play.circle") }
            #if !APPSTORE_BUILD
            if canFetch {
                Button { ReleaseFetcher.shared.get(find.release, track: SoulseekPick.Track(find.hit.track)) } label: {
                    Label("Get This Song", systemImage: "arrow.down.circle")
                }
            }
            #endif
        }
    }

    /// The phone's Get control: a ring while it comes in, a check once it's in.
    @ViewBuilder
    private var trailing: some View {
        #if !APPSTORE_BUILD
        if canFetch {
            let fetcher = ReleaseFetcher.shared
            let track = SoulseekPick.Track(find.hit.track)
            let own = fetcher.fetch(for: ReleaseFetch.id(find.release.id, track: track.id))
            let whole = fetcher.fetch(for: find.release.id)
            let shown = whole.flatMap { $0.stage != .failed ? $0 : nil } ?? own
            switch shown?.stage {
            case .searching?, .downloading?, .importing?:
                FetchRing(fetch: shown!)
            case .ready?:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(accentColor)
                    .help("In your library")
            default:
                Button { fetcher.get(find.release, track: track) } label: {
                    Image(systemName: own?.stage == .failed ? "arrow.clockwise.circle" : "arrow.down.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(own?.stage == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 32, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Get This Song")
            }
        } else {
            previewGlyph
        }
        #else
        previewGlyph
        #endif
    }

    private var previewGlyph: some View {
        Image(systemName: "play.circle")
            .font(.system(size: 15))
            .foregroundStyle(.tertiary)
    }
}
