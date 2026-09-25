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
    /// What the hero needs from scrolling, and nothing more: the value only changes while
    /// the list is pulled past its top or when the title crosses its threshold, so an
    /// ordinary scroll does not re-render the whole page on every frame.
    @State private var heroScroll = HeroScroll()

    private struct HeroScroll: Equatable {
        var stretch: CGFloat = 0
        var showsTitle = false
    }

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
            VStack(spacing: 6) {
                ArtistHero(
                    coverArt: artist?.coverArt ?? coverArt,
                    artistImageURL: artistImageURL,
                    name: displayName,
                    albumCount: albums.count,
                    isLoading: isLoading,
                    stretch: heroScroll.stretch
                )

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
            }
            .frame(maxWidth: .infinity)
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
                    .listRowBackground(Color.clear)
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
        // The hero runs up under the status bar and the floating buttons, so the list opts
        // out of the top safe area and starts at the very top of the screen — the move the
        // tab roots already make, with no margin put back because the photograph is meant
        // to be there.
        .ignoresSafeArea(.container, edges: .top)
        .contentMargins(.top, 0, for: .scrollContent)
        .onScrollGeometryChange(for: HeroScroll.self) { geo in
            let y = geo.contentOffset.y + geo.contentInsets.top
            return HeroScroll(stretch: max(0, -y), showsTitle: y > ArtistHero.height - 90)
        } action: { _, new in
            heroScroll = new
        }
        .background(Color.themeBg)
        // Once the portrait has scrolled away, the bar says whose page this is.
        .navigationTitle(heroScroll.showsTitle ? displayName : "")
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

// MARK: - Artist hero

/// The artist's portrait as the top of the page, the way Apple Music opens an artist.
///
/// It runs edge to edge and up under the status bar and the floating buttons. A photograph
/// that starts below the bar reads as a picture placed on a screen; one that starts at the
/// glass reads as the screen itself. Pulled down, it stretches instead of opening a gap
/// above it; at the bottom it dissolves into the page instead of stopping on a line.
///
/// Every layer is a sibling in one `ZStack` with the geometry set here, so what is drawn
/// is exactly what is listed — nothing hangs off a modifier chain inside the image view.
struct ArtistHero: View {
    let coverArt: String?
    let artistImageURL: URL?
    let name: String
    let albumCount: Int
    let isLoading: Bool
    /// How far the list is pulled past its top, in points. Zero at rest.
    let stretch: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    /// Whether the page the picture dissolves into is dark. Follows `Color.themeBg`,
    /// which is black under the pure-black theme whatever the system appearance.
    private var pageIsDark: Bool {
        colorScheme == .dark || AppSettings.shared.activeTheme.usePureBlack
    }

    /// Height at rest: the status bar, then a portrait close to square — what a face
    /// needs — while still leaving the actions and the first songs on screen.
    static var height: CGFloat { TabChrome.windowSafeTop + 330 }

    /// Where a face belongs: below the clock and the floating buttons, clear of the name.
    /// Press shots put the face in the top fifth; centred, it sat right behind the buttons.
    private static var faceCenterY: CGFloat { TabChrome.windowSafeTop + 135 }

    /// Band at the bottom where the picture fades into the page.
    private static let dissolve: CGFloat = 56

    var body: some View {
        let height = Self.height
        ZStack(alignment: .bottomLeading) {
            // The pull grows the header upward, so the face target moves down with it: the
            // photo zooms in as it is pulled, the face riding down with the page.
            ArtistImageView(coverArt: coverArt, artistImageURL: artistImageURL, fillsFrame: true,
                            faceTarget: .init(faceCenterY: stretch + Self.faceCenterY))
                .frame(maxWidth: .infinity)
                .frame(height: height + stretch)
                .clipped()

            // Darkens the lower half so the name reads over any photograph — a white
            // press shot as much as a dark one. Not optional: without it, white type on a
            // bright portrait simply disappears.
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: .black.opacity(0.6), location: 0.8),
            ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            // The dissolve itself: the last band of the picture fades into the page, so
            // there is no bottom edge to see.
            LinearGradient(colors: [.clear, Color.themeBg],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.dissolve)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                if albumCount > 0 {
                    Text("\(albumCount) Albums")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                } else if isLoading {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            // 16, the same column as Top Songs and the rows below, so the name lines up
            // with everything under it rather than sitting a few points off.
            .padding(.horizontal, 16)
            // Low in the picture, where a name belongs and where it reads as one block with
            // the actions just beneath. Over a dark page the dissolve fades to black and
            // white type stays legible across it. Over a light page it fades to white, so
            // there the name is held clear of the band instead.
            .padding(.bottom, pageIsDark ? 20 : Self.dissolve)
        }
        .frame(height: height + stretch)
        // Laid out at the resting height, with the stretch growing upward into the space
        // the pull opens above the list — so pulling never pushes the page down.
        .frame(height: height, alignment: .bottom)
    }
}

// MARK: - Artist Image View (with external URL fallback)

struct ArtistImageView: View {
    let coverArt: String?
    let artistImageURL: URL?
    var size: CGFloat = 160
    /// Draws the picture to fill whatever frame the parent gives it, instead of as a
    /// `size`-point circle. The parent then owns the size, the crop and anything layered
    /// on top — see `ArtistHero`.
    var fillsFrame: Bool = false
    /// With `fillsFrame`, frames the picture on the face instead of on its centre — see
    /// `FaceFraming`. Nil keeps the plain centred fill.
    var faceTarget: FaceFraming.Target? = nil

    @State private var image: UIImage?
    /// The `cacheKey` that `image` was loaded for. The key can change under the same view —
    /// the artist's full record may carry another cover than the summary it was opened from —
    /// and the old picture must then neither stand for the new one nor be analysed as it.
    @State private var imageKey: String?
    @State private var analysis: (key: String, value: FaceFraming.Analysis)?
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

    /// The picture for the current key only.
    private var currentImage: UIImage? {
        guard let key = cacheKey else { return nil }
        if let image, imageKey == key { return image }
        return ArtworkCache.shared.image(for: key)
    }

    /// Keeps showing the previous picture while a changed key loads its own.
    private var resolvedImage: UIImage? {
        currentImage ?? image
    }

    @MainActor private func show(_ img: UIImage, for key: String) {
        image = img
        imageKey = key
    }

    var body: some View {
        shape
            .onTapGesture {
                if resolvedImage != nil { showFullScreen = true }
            }
            .onAppear {
                if image == nil, let key = cacheKey, let cached = ArtworkCache.shared.image(for: key) {
                    show(cached, for: key)
                }
            }
            .task(id: cacheKey) {
                await loadImage()
                await analyseFace()
            }
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

    // MARK: Shapes

    @ViewBuilder private var shape: some View {
        if fillsFrame { fill } else { bubble }
    }

    private var bubble: some View {
        Group {
            if let img = resolvedImage {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Color(.systemGray5))
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
    }

    /// No frame and no crop of its own, on purpose: the parent sizes and clips it.
    @ViewBuilder private var fill: some View {
        if let faceTarget, let img = currentImage {
            if let analysis = currentAnalysis {
                FaceFramedPhoto(image: img, analysis: analysis, target: faceTarget)
                    .overlay(alignment: .top) {
                        // No dark band across the top of every portrait: the floating buttons
                        // carry their own glass. Only a photo whose top is bright enough to
                        // swallow the white clock gets a veil, and just the clock's height.
                        if analysis.topIsBright { ClockVeil() }
                    }
            } else {
                // Vision needs a few milliseconds. Showing the photo centred meanwhile would
                // make it jump down once the face is found.
                wash
            }
        } else if let img = resolvedImage {
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            wash
        }
    }

    /// Just enough shade under the status bar for the clock to read on a bright photo,
    /// eased out so it has no edge.
    private struct ClockVeil: View {
        var body: some View {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.24), location: 0),
                .init(color: .black.opacity(0.12), location: 0.45),
                .init(color: .black.opacity(0.04), location: 0.75),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: TabChrome.windowSafeTop + 12)
                .allowsHitTesting(false)
        }
    }

    /// No portrait: a seeded wash rather than a grey slab, so the page keeps its shape and
    /// nothing jumps when a picture does arrive.
    private var wash: some View {
        LinearGradient(colors: GeneratedCoverView.hashedPalette(coverArt ?? "artist"),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "music.mic")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.2))
            }
    }

    /// Read straight from the cache as well, so a page opened again shows its framed photo
    /// on the first frame instead of the wash.
    private var currentAnalysis: FaceFraming.Analysis? {
        guard let key = cacheKey else { return nil }
        if let analysis, analysis.key == key { return analysis.value }
        return FaceFraming.cached(key)
    }

    private func analyseFace() async {
        guard fillsFrame, faceTarget != nil, let key = cacheKey, let img = currentImage else { return }
        let result = await FaceFraming.analyse(img, key: key)
        await MainActor.run { analysis = (key, result) }
    }

    private func loadImage() async {
        guard let key = cacheKey else { return }
        if image != nil, imageKey == key { return }
        if let cached = ArtworkCache.shared.image(for: key) {
            await MainActor.run { show(cached, for: key) }
            return
        }

        // 1. Try Subsonic coverArt — works for Navidrome with local artist art.
        //
        // Through `ArtworkCache` rather than fetching directly, because that is where the
        // server's own "no artwork" placeholder is recognised. Fetching straight from the
        // URL took Navidrome's generic silhouette for a real portrait and displayed it as
        // one — tolerable in a 160pt bubble, absurd filling a header.
        if let coverArt, !coverArt.isEmpty, ServerManager.shared.currentServer != nil {
            if let img = await ArtworkCache.shared.fetchImage(coverArt: coverArt,
                                                              requestSize: requestSize, key: key) {
                await MainActor.run { show(img, for: key) }
                return
            }
            AppLogger.shared.log("⚠️ Artist coverArt fetch returned no image: \(coverArt)")
        }

        // 2. Fall back to external artist image URL (Last.fm / MusicBrainz)
        if let artistImageURL,
           let img = await fetchImage(from: artistImageURL) {
            let externalKey = "artist_ext_\(Self.stableKey(artistImageURL.absoluteString))_\(requestSize)"
            ArtworkCache.shared.store(img, for: externalKey)
            await MainActor.run { show(img, for: key) }
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
