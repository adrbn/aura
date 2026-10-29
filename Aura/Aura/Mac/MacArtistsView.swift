import SwiftUI

struct MacArtistsView: View {
    @State private var serverManager = ServerManager.shared
    @State private var artists: [Artist] = []
    @State private var isLoading = false
    @State private var filter = ""
    /// The phone's key and values, so both sort the same way.
    @AppStorage("artists_sort") private var order = "Name"

    private let orders = ["Name", "Most Played", "Album Count"]

    private var shown: [Artist] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? artists : artists.filter { $0.name.lowercased().contains(q) }
        switch order {
        case "Most Played": return base.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case "Album Count": return base.sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }
        default: return base.sorted { $0.sortKey.localizedCompare($1.sortKey) == .orderedAscending }
        }
    }

    var body: some View {
        MacGrid(title: "Artists", trailing: AnyView(sortPicker),
                items: shown, isLoading: isLoading, emptyMessage: "No artists") { artist in
            NavigationLink(value: artist) {
                MacCoverTile(coverArt: artist.coverArt, title: artist.name,
                             subtitle: subtitle(artist),
                             placeholderName: artist.name, circular: true)
            }
            .buttonStyle(MacPressStyle())
            .contextMenu { MacArtistMenuItems(artist: artist) }
        }
        .navigationTitle("Artists")
        // A plain filter over an already-loaded list, not a server search: the artist list
        // is small enough to hold, and filtering it is instant where a round trip is not.
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter artists")
        .task { await load() }
    }

    private var sortPicker: some View {
        Picker("", selection: $order) {
            ForEach(orders, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// The album count, and the plays when they're asked for or are what the list is sorted by.
    private func subtitle(_ artist: Artist) -> String? {
        let albums = artist.albumCount.map { String(localized: "\($0) albums") }
        guard AppSettings.shared.showPlayCounts || order == "Most Played",
              let plays = artist.playCount, plays > 0 else { return albums }
        return [albums, String(localized: "· \(plays) plays")].compactMap { $0 }.joined(separator: " ")
    }

    private func load() async {
        guard let server = serverManager.currentServer, artists.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        artists = (try? await SubsonicClient.shared.getArtists(server: server)) ?? []
    }
}

struct MacArtistDetailView: View {
    let artist: Artist
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var albums: [Album] = []
    @State private var topSongs: [Song] = []
    @State private var preferences = MacPreferences.shared
    @State private var loaded = false
    @State private var isStarred = false
    @State private var showsAllSongs = false
    /// The portrait the artist's info points to, shown when the server has none of its own.
    @State private var photo: String?
    @State private var showsPhoto = false
    @State private var isDownloadingAll = false
    @State private var downloadedAlbumIds: Set<String> = []

    private static let rowHeight: CGFloat = 33, headHeight: CGFloat = 30

    private var allAlbumsDownloaded: Bool {
        !albums.isEmpty && albums.allSatisfy { downloadedAlbumIds.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MacDetailHeader(
                    coverArt: photo ?? artist.coverArt,
                    title: artist.name,
                    subtitle: String(localized: "\(albums.count) albums"),
                    placeholderName: artist.name,
                    onCoverTap: { showsPhoto = true }
                ) {
                    Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    Button { player.playShuffled(topSongs, source: source) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .disabled(topSongs.isEmpty)
                    Button { mix() } label: { Label("Instant Mix", systemImage: "sparkles") }
                        .disabled(topSongs.isEmpty)
                    Button { toggleStar() } label: { Image(systemName: isStarred ? "heart.fill" : "heart") }
                        .help(isStarred ? "Unfavourite" : "Favourite")
                        .disabled(!loaded)
                    Button { if !allAlbumsDownloaded { downloadAllAlbums() } } label: {
                        if isDownloadingAll {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: allAlbumsDownloaded ? "checkmark" : "arrow.down")
                        }
                    }
                    .help("Download")
                    .disabled(albums.isEmpty || isDownloadingAll)
                }

                if !loaded {
                    MacLoadingState().frame(height: 240)
                }
                if !topSongs.isEmpty {
                    let shown = showsAllSongs ? topSongs : Array(topSongs.prefix(10))
                    sectionTitle("Top Songs")
                    MacSongTable(songs: shown, source: source)
                        .frame(height: Self.headHeight + Self.rowHeight * CGFloat(shown.count) + 6)
                        .scrollDisabled(true)
                    if topSongs.count > 10 {
                        Button(showsAllSongs ? "Show Less" : "See All Songs") { showsAllSongs.toggle() }
                            .buttonStyle(.link)
                            .padding(.horizontal, 28)
                            .padding(.top, 6)
                    }
                }

                if loaded {
                    // Full albums first, then the singles and EPs under their own heading.
                    let longPlays = albums.filter { !$0.isSingleOrEP }
                    let shortPlays = albums.filter(\.isSingleOrEP)
                    if !longPlays.isEmpty { albumGrid("Albums", longPlays) }
                    if !shortPlays.isEmpty { albumGrid("Singles & EPs", shortPlays) }
                }
            }
        }
        .navigationTitle(artist.name)
        .task { await load() }
        .sheet(isPresented: $showsPhoto) {
            // Full size, as the phone's viewer: a click or Escape puts it away.
            CoverArtImage(coverArt: photo ?? artist.coverArt, size: 600, cornerRadius: 0,
                          placeholderName: artist.name)
                .onTapGesture { showsPhoto = false }
                .onExitCommand { showsPhoto = false }
        }
    }

    private var source: PlaybackSource { .artist(id: artist.id, name: artist.name) }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text).auraDisplay(34).padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 8)
    }

    private func albumGrid(_ title: LocalizedStringKey, _ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: preferences.coverSize.gridMinimum,
                                               maximum: preferences.coverSize.gridMaximum), spacing: 20)],
                      spacing: 22) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        MacCoverTile(coverArt: album.coverArt, title: album.name,
                                     subtitle: album.year.map(String.init),
                                     placeholderName: album.name)
                    }
                    .buttonStyle(MacPressStyle())
                    .contextMenu { MacAlbumMenuItems(album: album) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    /// The phone's load: the artist's albums and songs gathered by name as well as by id, so
    /// collaborations filed under a combined artist join them, the songs ranked by plays.
    private func load() async {
        guard let server = serverManager.currentServer else { return }
        let result = try? await SubsonicClient.shared.getArtist(server: server, id: artist.id)
        var allAlbums = result?.album ?? []
        albums = allAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        loaded = true
        async let starredFetch = try? SubsonicClient.shared.getStarred2(server: server)
        async let infoFetch = try? SubsonicClient.shared.getArtistInfo2(server: server, id: artist.id)
        var songs = (try? await SubsonicClient.shared.getTopSongs(server: server, artistName: artist.name)) ?? []
        if let more = try? await SubsonicClient.shared.search3(
            server: server, query: artist.name, artistCount: 0, albumCount: 100, songCount: 200) {
            let songIds = Set(songs.map(\.id))
            songs += (more.song ?? []).filter {
                !songIds.contains($0.id)
                    && ($0.artistId == artist.id || $0.artist?.localizedCaseInsensitiveContains(artist.name) == true)
            }
            var albumIds = Set(allAlbums.map(\.id))
            for album in more.album ?? [] where !albumIds.contains(album.id)
                && album.artist?.localizedCaseInsensitiveContains(artist.name) == true {
                allAlbums.append(album)
                albumIds.insert(album.id)
            }
        }
        // Stable on ties, so the server's own ranking from getTopSongs stays in front.
        topSongs = songs.enumerated().sorted { a, b in
            let pa = a.element.playCount ?? 0, pb = b.element.playCount ?? 0
            return pa == pb ? a.offset < b.offset : pa > pb
        }.map(\.element)
        albums = allAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        isStarred = await starredFetch?.artist?.contains { $0.id == artist.id } ?? false
        // The info's portrait only when the server has none of its own.
        let info = await infoFetch
        if let url = [info?.largeImageUrl, info?.mediumImageUrl, result?.artistImageUrl]
            .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            let size = ArtworkCache.thumbSize
            var own: PlatformImage?
            if let coverArt = artist.coverArt {
                own = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: size, key: "\(coverArt)_\(size)")
            }
            if own == nil { photo = url }
        }
    }

    private func play() {
        guard let first = topSongs.first else { return }
        player.playSong(first, fromQueue: topSongs, startIndex: 0, source: source)
    }

    private func mix() {
        player.startArtistInstantMix(artistId: artist.id, artistName: artist.name, topSongs: topSongs)
    }

    private func toggleStar() {
        guard let server = serverManager.currentServer else { return }
        Task {
            if isStarred {
                try? await SubsonicClient.shared.unstar(server: server, id: artist.id)
            } else {
                try? await SubsonicClient.shared.star(server: server, id: artist.id)
            }
            isStarred.toggle()
        }
    }

    private func downloadAllAlbums() {
        guard let server = serverManager.currentServer else { return }
        isDownloadingAll = true
        // Fresh batch: clear any prior Pause/Stop All before starting.
        DownloadManager.shared.isHalted = false
        Task {
            for album in albums {
                if DownloadManager.shared.isHalted { break }
                guard let songs = try? await SubsonicClient.shared.getAlbum(server: server, id: album.id).song,
                      !songs.isEmpty else { continue }
                await DownloadManager.shared.downloadAlbum(songs, groupId: album.id, isBatchStart: false)
                downloadedAlbumIds.insert(album.id)
            }
            isDownloadingAll = false
        }
    }
}
