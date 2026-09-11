import SwiftUI
import CryptoKit

struct ArtistDetailView: View {
    let artistId: String
    var artistName: String? = nil   // Optional pre-known name to show immediately
    var coverArt: String? = nil     // Optional pre-known coverArt

    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var artist: ArtistWithAlbums?
    @State private var topSongs: [Song] = []
    /// Albums credited to this artist by NAME (merges collaboration albums the server
    /// files under separate combined-artist entries). See `loadArtist()`.
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var isStarred = false
    @State private var artistImageURL: URL?
    @State private var selectedAlbumId: String?
    @State private var isDownloadingAll = false
    @State private var downloadedAlbumIds: Set<String> = []

    private var allAlbumsDownloaded: Bool {
        guard !albums.isEmpty else { return false }
        return albums.allSatisfy { downloadedAlbumIds.contains($0.id) }
    }

    /// Name to display — use fetched artist name, fall back to pre-known name
    private var displayName: String {
        artist?.name ?? artistName ?? ""
    }

    var body: some View {
        List {
            // Artist header — always visible
            VStack(spacing: 12) {
                ArtistImageView(
                    coverArt: artist?.coverArt ?? coverArt,
                    artistImageURL: artistImageURL,
                    size: 160
                )
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

                if !displayName.isEmpty {
                    Text(displayName)
                        .font(.title.bold())
                }

                if !albums.isEmpty {
                    Text("\(albums.count) Albums")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if isLoading {
                    // Visible spinner instead of a stray grey placeholder rectangle.
                    ProgressView()
                        .controlSize(.small)
                        .tint(accentColor)
                        .frame(height: 20)
                }

                HStack(spacing: 10) {
                    Button {
                        if let name = artist?.name {
                            player.startArtistInstantMix(artistId: artistId, artistName: name, topSongs: topSongs)
                        }
                    } label: {
                        Label("Instant Mix", systemImage: "wand.and.stars")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(accentColor)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .disabled(topSongs.isEmpty)
                    .opacity(topSongs.isEmpty ? 0.5 : 1)

                    Button {
                        player.playShuffled(topSongs, source: .artist(id: artistId, name: displayName))
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08))
                            .foregroundStyle(accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .disabled(topSongs.isEmpty)
                    .opacity(topSongs.isEmpty ? 0.5 : 1)

                    // Favourite sits inline with the actions — on its own row it ate a
                    // full line and pushed Top Songs down the page.
                    Button {
                        toggleArtistStar()
                    } label: {
                        Image(systemName: isStarred ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .frame(width: 38, height: 36)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .opacity(isLoading ? 0.4 : 1)
                    .disabled(isLoading)
                }
                .padding(.top, 14) // air between the info block (image/name/count) and the actions
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10) // was 20 — header sat low, crushed against the buttons
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // Top songs section
            if isLoading && topSongs.isEmpty {
                // Skeleton placeholder rows
                Text("Top Songs")
                    .font(.title2.bold())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray5))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(.systemGray5))
                                .frame(width: 140, height: 14)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(.systemGray6))
                                .frame(width: 90, height: 12)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .redacted(reason: .placeholder)
                    .shimmering()
                    .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                              leading: 16,
                                              bottom: AppSettings.shared.listDensity.verticalPadding,
                                              trailing: 16))
                }
            } else if !topSongs.isEmpty {
                Text("Top Songs")
                    .font(.title2.bold())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

                ForEach(Array(topSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                    SongRowView(song: song, showArtist: false) {
                        player.playSong(song, fromQueue: topSongs, startIndex: index, source: .artist(id: artistId, name: displayName))
                    }
                    .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                              leading: 16,
                                              bottom: AppSettings.shared.listDensity.verticalPadding,
                                              trailing: 16))
                }

                if topSongs.count > 5 {
                    NavigationLink {
                        ArtistAllSongsView(artistName: displayName, songs: topSongs)
                    } label: {
                        Text("See All Songs")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accentColor)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }

            // Albums section
            if isLoading && artist == nil {
                // Skeleton album grid
                Text("Albums")
                    .font(.title2.bold())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.systemGray5))
                                .aspectRatio(1, contentMode: .fit)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(.systemGray5))
                                .frame(height: 14)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(.systemGray6))
                                .frame(width: 60, height: 12)
                        }
                        .redacted(reason: .placeholder)
                        .shimmering()
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            } else if !albums.isEmpty {
                Text("Albums")
                    .font(.title2.bold())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                    ForEach(albums) { album in
                        Button {
                            selectedAlbumId = album.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                CoverArtImage(coverArt: album.coverArt, size: 180, cornerRadius: 12)
                                Text(album.name).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                Text(album.year != nil ? String(album.year!) : " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 180)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }

            Color.clear.frame(height: 80)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Download all albums
                Button {
                    downloadAllAlbums()
                } label: {
                    if isDownloadingAll {
                        ProgressView()
                    } else {
                        Image(systemName: allAlbumsDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(allAlbumsDownloaded ? .green : accentColor)
                    }
                }
                .disabled(albums.isEmpty || isDownloadingAll || allAlbumsDownloaded)
            }
        }
        .navigationDestination(item: $selectedAlbumId) { albumId in
            AlbumDetailView(albumId: albumId)
        }
        .task { await loadArtist() }
    }

    private func loadArtist() async {
        guard let server = serverManager.currentServer else { return }
        do {
            // Fetch artist first — immediately show basic info
            let result = try await SubsonicClient.shared.getArtist(server: server, id: artistId)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                artist = result
            }

            // Fetch starred status, top songs, and image in parallel
            async let starredFetch = SubsonicClient.shared.getStarred2(server: server)
            async let songsFetch = SubsonicClient.shared.getTopSongs(server: server, artistName: result.name)

            let starred = try await starredFetch
            let artistStarred = starred.artist?.contains(where: { $0.id == artistId }) ?? false
            let songs = try await songsFetch

            // Fetch artist info for the image URL
            var imageURL: URL? = nil
            if let info = try? await SubsonicClient.shared.getArtistInfo2(server: server, id: artistId) {
                if let urlStr = info.largeImageUrl ?? info.mediumImageUrl, !urlStr.isEmpty {
                    imageURL = URL(string: urlStr)
                }
            }
            if imageURL == nil, let urlStr = result.artistImageUrl, !urlStr.isEmpty {
                imageURL = URL(string: urlStr)
            }

            // Load ALL of this artist's songs AND albums by NAME. The server files
            // multi-artist credits ("Avicii, CAZZETTE") under a separate combined-artist
            // entry, so getArtist(id) alone misses those collaboration albums/songs.
            // Aggregating by name re-unites everything under the canonical artist.
            var allArtistSongs: [Song] = songs
            var allAlbums = result.album ?? []
            let existingIds = Set(songs.map { $0.id })
            var existingAlbumIds = Set(allAlbums.map { $0.id })
            if let moreResults = try? await SubsonicClient.shared.search3(
                server: server, query: result.name, artistCount: 0, albumCount: 100, songCount: 200
            ) {
                for song in moreResults.song ?? [] {
                    if !existingIds.contains(song.id) && (song.artistId == artistId || song.artist?.localizedCaseInsensitiveContains(result.name) == true) {
                        allArtistSongs.append(song)
                    }
                }
                for album in moreResults.album ?? [] {
                    if !existingAlbumIds.contains(album.id),
                       album.artist?.localizedCaseInsensitiveContains(result.name) == true {
                        allAlbums.append(album)
                        existingAlbumIds.insert(album.id)
                    }
                }
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                isStarred = artistStarred
                // getTopSongs is Last.fm-backed and often returns only a handful (2 for
                // some artists), so most of this list is filler appended from search3 in
                // arbitrary order — under a "Top Songs" heading. Rank by play count so the
                // heading is honest. Sorting on (playCount, original index) keeps it stable:
                // Swift's sort isn't, and ties must preserve the server's own ranking,
                // which getTopSongs already put at the front.
                topSongs = allArtistSongs.enumerated()
                    .sorted { a, b in
                        let pa = a.element.playCount ?? 0, pb = b.element.playCount ?? 0
                        return pa == pb ? a.offset < b.offset : pa > pb
                    }
                    .map(\.element)
                // Newest → oldest (albums without a year sink to the bottom).
                albums = allAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                artistImageURL = imageURL
                isLoading = false
            }
        } catch {
            AppLogger.shared.log("❌ Artist load error: \(error.localizedDescription)")
            await MainActor.run { isLoading = false }
        }
    }

    private func downloadAllAlbums() {
        guard !albums.isEmpty, let server = serverManager.currentServer else { return }
        isDownloadingAll = true
        // Fresh batch — clear any prior Pause/Stop All before starting.
        DownloadManager.shared.isHalted = false
        Task {
            for album in albums {
                // Stop All / Pause All halts the whole multi-album batch, not just one album.
                if DownloadManager.shared.isHalted { break }
                guard let detail = try? await SubsonicClient.shared.getAlbum(server: server, id: album.id),
                      let songs = detail.song, !songs.isEmpty else { continue }
                // isBatchStart: false — this batch is already managed here, so individual
                // albums must not clear an in-progress halt.
                await DownloadManager.shared.downloadAlbum(songs, groupId: album.id, isBatchStart: false)
                await MainActor.run { downloadedAlbumIds.insert(album.id) }
            }
            await MainActor.run { isDownloadingAll = false }
        }
    }

    private func toggleArtistStar() {
        guard let server = serverManager.currentServer else { return }
        Task {
            if isStarred {
                try? await SubsonicClient.shared.unstar(server: server, id: artistId)
            } else {
                try? await SubsonicClient.shared.star(server: server, id: artistId)
            }
            await MainActor.run { isStarred.toggle() }
        }
    }
}

struct ArtistAllSongsView: View {
    let artistName: String
    let songs: [Song]
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SongRowView(song: song, showArtist: false) {
                    player.playSong(song, fromQueue: songs, startIndex: index, source: .artist(id: "", name: artistName))
                }
                .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                          leading: 16,
                                          bottom: AppSettings.shared.listDensity.verticalPadding,
                                          trailing: 16))
            }
            Color.clear.frame(height: 80)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .scrollIndicators(.hidden)
        .navigationTitle("Songs by \(artistName)")
    }
}

// MARK: - Artist Image View (with external URL fallback)

struct ArtistImageView: View {
    let coverArt: String?
    let artistImageURL: URL?
    var size: CGFloat = 160

    @State private var image: UIImage?
    @State private var showFullScreen = false

    private var requestSize: Int {
        ArtworkCache.normalizedSize(Int(size * UIScreen.main.scale))
    }

    /// Stable, launch-independent hash (String.hashValue is randomized per process,
    /// which would break the on-disk artwork cache across launches).
    static func stableKey(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Cache key combines coverArt id (if any) or external URL with the bucket size
    private var cacheKey: String? {
        if let coverArt, !coverArt.isEmpty {
            return "\(coverArt)_\(requestSize)"
        } else if let urlString = artistImageURL?.absoluteString {
            return "artist_ext_\(Self.stableKey(urlString))_\(requestSize)"
        }
        return nil
    }

    private var resolvedImage: UIImage? {
        if let image { return image }
        guard let key = cacheKey else { return nil }
        return ArtworkCache.shared.image(for: key)
    }

    var body: some View {
        Group {
            if let img = resolvedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(Color(.systemGray5))
                    .overlay {
                        Image(systemName: "music.mic")
                            .foregroundStyle(.secondary)
                            .font(.system(size: size * 0.3))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        .onTapGesture {
            if resolvedImage != nil { showFullScreen = true }
        }
        .onAppear {
            if image == nil, let key = cacheKey, let cached = ArtworkCache.shared.image(for: key) {
                image = cached
            }
        }
        .task(id: cacheKey) { await loadImage() }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let img = resolvedImage {
                FullScreenImageViewer(
                    initialImage: img,
                    coverArt: coverArt,
                    fallbackURL: artistImageURL,
                    isPresented: $showFullScreen
                )
            }
        }
    }

    private func loadImage() async {
        if image != nil { return }
        if let key = cacheKey, let cached = ArtworkCache.shared.image(for: key) {
            await MainActor.run { self.image = cached }
            return
        }

        // 1. Try Subsonic coverArt — works for Navidrome with local artist art.
        //
        // Through `ArtworkCache` rather than fetching directly, because that is where the
        // server's own "no artwork" placeholder is recognised. Fetching straight from the
        // URL took Navidrome's generic silhouette for a real portrait and displayed it as
        // one — tolerable in a 160pt bubble, absurd filling a header.
        if let coverArt, !coverArt.isEmpty, ServerManager.shared.currentServer != nil {
            let key = "\(coverArt)_\(requestSize)"
            if let img = await ArtworkCache.shared.fetchImage(coverArt: coverArt,
                                                              requestSize: requestSize, key: key) {
                await MainActor.run { self.image = img }
                return
            }
            AppLogger.shared.log("⚠️ Artist coverArt fetch returned no image: \(coverArt)")
        }


        // 2. Fall back to external artist image URL (Last.fm / MusicBrainz)
        if let artistImageURL,
           let img = await fetchImage(from: artistImageURL) {
            let key = "artist_ext_\(Self.stableKey(artistImageURL.absoluteString))_\(requestSize)"
            ArtworkCache.shared.store(img, for: key)
            await MainActor.run { self.image = img }
            return
        }

        AppLogger.shared.log("❌ Artist image unavailable — coverArt: \(coverArt ?? "nil"), externalURL: \(artistImageURL?.absoluteString ?? "nil")")
    }

    /// Fetch and validate that the response is actually an image.
    /// Subsonic servers sometimes return a JSON error with HTTP 200 — `UIImage(data:)` would return nil.
    private func fetchImage(from url: URL) async -> UIImage? {
        do {
            let (data, response) = try await ArtworkCache.shared.imageSession.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
