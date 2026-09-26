import SwiftUI

// MARK: - Offline grouping models

/// An album reconstructed purely from locally-available songs (downloads + cache).
struct OfflineAlbum: Identifiable {
    let id: String
    let name: String
    let artist: String
    let coverArt: String?
    let songs: [Song]

    static func group(_ songs: [Song]) -> [OfflineAlbum] {
        var order: [String] = []
        var map: [String: [Song]] = [:]
        for song in songs {
            let key = song.albumId ?? song.album ?? "unknown"
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

    var albumCount: Int { Set(songs.map { $0.albumId ?? $0.album ?? "" }).count }

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

// MARK: - Offline Library

/// What this device can play without the server: downloads first, then whatever the
/// stream cache still holds. Laid out like the online tabs — the big title, a search field,
/// a row of quiet chips — so going offline doesn't feel like a different app.
struct OfflineLibraryView: View {
    @State private var downloadManager = DownloadManager.shared
    @State private var cachedSongs: [Song] = []
    @State private var searchText = ""
    @State private var mode: BrowseMode = .songs
    @State private var scrollY: CGFloat = 0
    @Environment(AudioPlayer.self) private var player
    @Environment(\.scenePhase) private var scenePhase

    enum BrowseMode: String, CaseIterable, Identifiable {
        case songs = "Songs", albums = "Albums", artists = "Artists", playlists = "Playlists"
        var id: String { rawValue }
    }

    /// Unified, de-duplicated offline song pool (downloads first, then stream cache).
    private var allOfflineSongs: [Song] {
        var seen = Set<String>()
        var result: [Song] = []
        for song in downloadManager.downloadedSongs.map(\.song) + cachedSongs {
            if seen.insert(song.id).inserted { result.append(song) }
        }
        return result
    }

    private var filteredSongs: [Song] {
        guard !searchText.isEmpty else { return allOfflineSongs }
        let q = searchText.lowercased()
        return allOfflineSongs.filter {
            $0.title.lowercased().contains(q) ||
            ($0.artist ?? "").lowercased().contains(q) ||
            ($0.album ?? "").lowercased().contains(q)
        }
    }

    private var albums: [OfflineAlbum] { OfflineAlbum.group(filteredSongs) }
    private var artists: [OfflineArtist] { OfflineArtist.group(filteredSongs) }

    /// Snapshotted playlists with at least one song available offline, reduced to
    /// their locally-playable subset. Carries the original total for "x of y".
    private var offlinePlaylists: [(snapshot: OfflinePlaylistSnapshot, available: [Song])] {
        let offlineIds = Set(allOfflineSongs.map(\.id))
        let q = searchText.lowercased()
        return OfflinePlaylistsStore.shared.playlists.compactMap { snapshot in
            if !q.isEmpty && !snapshot.name.lowercased().contains(q) { return nil }
            let available = snapshot.songs.filter { offlineIds.contains($0.id) }
            guard !available.isEmpty else { return nil }
            return (snapshot, available)
        }
    }

    var body: some View {
        List {
            TabTitleRow("offline").clearRow()

            // Why we're offline, and the way back when there is one.
            OfflineStatusBar()
                .padding(.bottom, 12)
                .clearRow()

            if allOfflineSongs.isEmpty {
                ContentUnavailableView(
                    "Nothing Offline Yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Download songs, albums or playlists while you're online, and they'll be here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .clearRow()
            } else {
                summary.clearRow()

                SearchFieldBar(text: $searchText, prompt: "Search Offline")
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                    .clearRow()

                modeChips
                    .padding(.bottom, 12)
                    .clearRow()

                switch mode {
                case .songs: songRows
                case .albums: albumGrid
                case .artists: artistRows
                case .playlists: playlistRows
                }

                Text("Downloads stay until you remove them. Streamed songs are kept too, but iOS may clear them when storage runs low.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .clearRow()

                ListEndSpacer(height: 100).clearRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .tabRootGlass(scrollY: $scrollY)
        .onAppear { refreshCachedSongs() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refreshCachedSongs() }
        }
    }

    /// Re-fetch on every appearance and app activation — getCachedSongs only returns
    /// entries whose file is still on disk, so evicted songs drop out and newly
    /// cached ones show up.
    private func refreshCachedSongs() {
        cachedSongs = AudioCacheManager.shared.getCachedSongs()
    }

    // MARK: Header

    /// How much is here, and Shuffle / Play for all of it — or for what the search kept.
    private var summary: some View {
        let songs = filteredSongs
        return VStack(alignment: .leading, spacing: 10) {
            Text(Self.count(allOfflineSongs.count, "song") + " · "
                 + Self.count(OfflineAlbum.group(allOfflineSongs).count, "album"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            OfflinePlayButtons(songs: songs)
        }
        .padding(.horizontal, 16)
    }

    private var modeChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(BrowseMode.allCases) { choice in
                    QuietChip(title: choice.rawValue, isOn: mode == choice) {
                        withAnimation(.easeInOut(duration: 0.2)) { mode = choice }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: Songs

    @ViewBuilder private var songRows: some View {
        let songs = filteredSongs
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            SongRowView(song: song) {
                player.playSong(song, fromQueue: songs, startIndex: index)
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

    // MARK: Albums

    private var albumGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
            ForEach(albums) { album in OfflineAlbumCard(album: album) }
        }
        .padding(.horizontal, 16)
        .clearRow()
    }

    // MARK: Artists

    private var artistRows: some View {
        ForEach(artists) { artist in
            NavigationLink {
                OfflineArtistDetailView(artist: artist)
            } label: {
                OfflineRow(title: artist.name,
                           detail: Self.count(artist.albumCount, "album") + " · " + Self.count(artist.songs.count, "song")) {
                    CoverArtImage(coverArt: artist.coverArt, size: 56, cornerRadius: 28,
                                  placeholderName: artist.name, placeholderKind: .artist)
                }
            }
            .offlineRowStyle()
        }
    }

    // MARK: Playlists

    @ViewBuilder
    private var playlistRows: some View {
        let items = offlinePlaylists
        if items.isEmpty {
            Text("Playlists show up here once some of their songs are on this iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .clearRow()
        } else {
            ForEach(items, id: \.snapshot.id) { item in
                NavigationLink {
                    OfflinePlaylistDetailView(snapshot: item.snapshot, availableSongs: item.available)
                } label: {
                    OfflineRow(title: item.snapshot.name,
                               detail: "\(item.available.count) of \(Self.count(item.snapshot.songCount, "song"))") {
                        CoverArtImage(coverArt: item.snapshot.coverArt, size: 56, cornerRadius: 8,
                                      placeholderName: item.snapshot.name, placeholderKind: .playlist)
                    }
                }
                .offlineRowStyle()
            }
        }
    }
}

// MARK: - Shared pieces

/// Shuffle beside a wide Play, as on the online album pages.
struct OfflinePlayButtons: View {
    let songs: [Song]
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        HStack(spacing: 12) {
            Button { player.playShuffled(songs) } label: {
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
                player.playSong(first, fromQueue: songs, startIndex: 0)
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
private struct OfflineRow<Cover: View>: View {
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

private extension View {
    func offlineRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// An album as the Library's grid draws it, opening its offline page.
private struct OfflineAlbumCard: View {
    let album: OfflineAlbum
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        NavigationLink {
            OfflineAlbumDetailView(album: album)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                CoverArtImage(coverArt: album.coverArt, size: 160, cornerRadius: 10,
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
            .frame(width: 160)
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

/// The head of an offline album, playlist or artist page, in the online pages' layout:
/// the cover, the name, Shuffle and Play, then what's held.
private struct OfflinePageHeader<Cover: View>: View {
    let title: String
    var subtitle: String?
    let detail: String
    let songs: [Song]
    @ViewBuilder var cover: () -> Cover

    var body: some View {
        VStack(spacing: 12) {
            cover()
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .padding(.top, 16)
            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            OfflinePlayButtons(songs: songs)
                .padding(.horizontal, 16)
                .padding(.top, 8)
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
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }
}

/// A page's songs, as rows the way the online pages list them.
private struct OfflineSongRows: View {
    let songs: [Song]
    var showArt = true
    var showTrackNumber = false
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
            SongRowView(song: song, showArt: showArt, showTrackNumber: showTrackNumber) {
                player.playSong(song, fromQueue: songs, startIndex: index)
            }
            .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                      leading: 16,
                                      bottom: AppSettings.shared.listDensity.verticalPadding,
                                      trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

private extension View {
    /// An offline page: a plain list on its cover's colour, with an inline title.
    func offlinePage(title: String, coverArt: String?) -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .background(ArtworkCanvas(coverArt: coverArt))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Offline Album Detail

struct OfflineAlbumDetailView: View {
    let album: OfflineAlbum

    var body: some View {
        List {
            OfflinePageHeader(title: album.name, subtitle: album.artist,
                              detail: OfflineLibraryView.count(album.songs.count, "song") + " on this iPhone",
                              songs: album.songs) {
                CoverArtAsyncImage(coverArt: album.coverArt, size: 260)
            }
            .clearRow()
            OfflineSongRows(songs: album.songs, showArt: false, showTrackNumber: true)
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
                              detail: "\(availableSongs.count) of \(OfflineLibraryView.count(snapshot.songCount, "song")) on this iPhone",
                              songs: availableSongs) {
                CoverArtAsyncImage(coverArt: snapshot.coverArt, size: 260)
            }
            .clearRow()
            OfflineSongRows(songs: availableSongs)
            ListEndSpacer().clearRow()
        }
        .offlinePage(title: snapshot.name, coverArt: snapshot.coverArt)
    }
}

// MARK: - Offline Artist Detail

struct OfflineArtistDetailView: View {
    let artist: OfflineArtist

    private var albums: [OfflineAlbum] { OfflineAlbum.group(artist.songs) }

    var body: some View {
        List {
            OfflinePageHeader(title: artist.name,
                              detail: OfflineLibraryView.count(albums.count, "album") + " · "
                                  + OfflineLibraryView.count(artist.songs.count, "song") + " on this iPhone",
                              songs: artist.songs) {
                CoverArtImage(coverArt: artist.coverArt, size: 180, cornerRadius: 90,
                              placeholderName: artist.name, placeholderKind: .artist)
            }
            .clearRow()
            Text("Albums")
                .font(.title3.bold())
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .clearRow()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(albums) { album in OfflineAlbumCard(album: album) }
            }
            .padding(.horizontal, 16)
            .clearRow()
            ListEndSpacer().clearRow()
        }
        .offlinePage(title: artist.name, coverArt: artist.coverArt)
    }
}
