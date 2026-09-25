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

struct OfflineLibraryView: View {
    @State private var downloadManager = DownloadManager.shared
    @State private var cachedSongs: [Song] = []
    @State private var searchText = ""
    @State private var mode: BrowseMode = .songs
    @State private var scrollY: CGFloat = 0
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.scenePhase) private var scenePhase

    enum BrowseMode: String, CaseIterable, Identifiable {
        case songs = "Songs", playlists = "Playlists", artists = "Artists", albums = "Albums"
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
            // Big left title as the first scrolling row — same chrome as the online tabs.
            TabTitleRow("offline") {
                Button { serverManager.goBackOnline() } label: {
                    Image(systemName: "wifi").font(.headline).foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go Online")
            }
            .clearRow()

            // Why we're offline — now part of the flow (was a top safe-area inset).
            OfflineStatusBar()
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if allOfflineSongs.isEmpty {
                ContentUnavailableView(
                    "No Offline Content",
                    systemImage: "arrow.down.circle",
                    description: Text("Download or stream songs to have them available offline")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .clearRow()
            } else {
                SearchFieldBar(text: $searchText, prompt: "Search offline…")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                Picker("Browse", selection: $mode) {
                    ForEach(BrowseMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                switch mode {
                case .songs: songRows
                case .playlists: playlistRows
                case .artists: artistRows
                case .albums: albumRows
                }

                Text("Streamed songs are cached automatically and may be cleared by iOS when storage is low. Downloads are permanent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .clearRow()

                ListEndSpacer(height: 100).clearRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
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

    // MARK: Albums

    private var albumRows: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 20) {
            ForEach(albums) { album in
                NavigationLink {
                    OfflineAlbumDetailView(album: album)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
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
        .padding(.horizontal, 16)
        .clearRow()
    }

    // MARK: Songs

    @ViewBuilder private var songRows: some View {
        ForEach(Array(filteredSongs.enumerated()), id: \.element.id) { index, song in
            SongRowView(song: song) {
                player.playSong(song, fromQueue: filteredSongs, startIndex: index)
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

    // MARK: Playlists

    @ViewBuilder
    private var playlistRows: some View {
        let items = offlinePlaylists
        if items.isEmpty {
            ContentUnavailableView(
                "No Offline Playlists",
                systemImage: "music.note.list",
                description: Text("Playlists appear here once some of their songs are downloaded or cached")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .clearRow()
        } else {
            ForEach(items, id: \.snapshot.id) { item in
                NavigationLink {
                    OfflinePlaylistDetailView(snapshot: item.snapshot, availableSongs: item.available)
                } label: {
                    HStack(spacing: 12) {
                        CoverArtImage(coverArt: item.snapshot.coverArt, size: 50, cornerRadius: 8,
                                      placeholderName: item.snapshot.name, placeholderKind: .playlist)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.snapshot.name).font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary).lineLimit(1)
                            Text("\(item.available.count) of \(item.snapshot.songCount) available")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: Artists

    private var artistRows: some View {
        ForEach(artists) { artist in
            NavigationLink {
                OfflineArtistDetailView(artist: artist)
            } label: {
                HStack(spacing: 12) {
                    CoverArtImage(coverArt: artist.coverArt, size: 50, cornerRadius: 25,
                                  placeholderName: artist.name, placeholderKind: .artist)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary).lineLimit(1)
                        Text("\(artist.songs.count) song\(artist.songs.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

// MARK: - Offline Album Detail

struct OfflineAlbumDetailView: View {
    let album: OfflineAlbum
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CoverArtAsyncImage(coverArt: album.coverArt, size: 220)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(album.name).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                    Text("\(album.songs.count) song\(album.songs.count == 1 ? "" : "s") • offline")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                HStack(spacing: 12) {
                    Button {
                        guard let first = album.songs.first else { return }
                        player.playSong(first, fromQueue: album.songs, startIndex: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(accentColor).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        player.playShuffled(album.songs)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                LazyVStack(spacing: 0) {
                    ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                        SongRowView(song: song) {
                            player.playSong(song, fromQueue: album.songs, startIndex: index)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, AppSettings.shared.listDensity.verticalPadding)
                    }
                }
                ListEndSpacer(height: 100)
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .background(Color.themeBg)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Offline Playlist Detail

/// The locally-playable subset of a snapshotted playlist — same layout as the
/// offline album detail so the offline library feels uniform.
struct OfflinePlaylistDetailView: View {
    let snapshot: OfflinePlaylistSnapshot
    let availableSongs: [Song]
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CoverArtAsyncImage(coverArt: snapshot.coverArt, size: 220)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(snapshot.name).font(.title3.bold()).multilineTextAlignment(.center)
                    Text("\(availableSongs.count) of \(snapshot.songCount) song\(snapshot.songCount == 1 ? "" : "s") available offline")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        guard let first = availableSongs.first else { return }
                        player.playSong(first, fromQueue: availableSongs, startIndex: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(accentColor).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        player.playShuffled(availableSongs)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                LazyVStack(spacing: 0) {
                    ForEach(Array(availableSongs.enumerated()), id: \.element.id) { index, song in
                        SongRowView(song: song) {
                            player.playSong(song, fromQueue: availableSongs, startIndex: index)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, AppSettings.shared.listDensity.verticalPadding)
                    }
                }
                ListEndSpacer(height: 100)
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .background(Color.themeBg)
        .navigationTitle(snapshot.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Offline Artist Detail

struct OfflineArtistDetailView: View {
    let artist: OfflineArtist
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    private var albums: [OfflineAlbum] { OfflineAlbum.group(artist.songs) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    CoverArtImage(coverArt: artist.coverArt, size: 80, cornerRadius: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name).font(.title3.bold())
                        Text("\(artist.songs.count) song\(artist.songs.count == 1 ? "" : "s") • offline")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                Button {
                    player.playShuffled(artist.songs)
                } label: {
                    Label("Shuffle All", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            OfflineAlbumDetailView(album: album)
                        } label: {
                            HStack(spacing: 12) {
                                CoverArtImage(coverArt: album.coverArt, size: 56, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.name).font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary).lineLimit(1)
                                    Text("\(album.songs.count) song\(album.songs.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                ListEndSpacer(height: 100)
            }
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
        .background(Color.themeBg)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
