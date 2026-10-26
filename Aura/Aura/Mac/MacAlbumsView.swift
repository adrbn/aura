import SwiftUI

/// Every album, as a grid of covers. The one place the Mac's extra width pays off most
/// obviously: where the phone shows two columns, a window shows eight.
struct MacAlbumsView: View {
    @State private var serverManager = ServerManager.shared
    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var order = "alphabeticalByName"

    private let orders: [(String, String)] = [
        ("alphabeticalByName", "Name"),
        ("newest", "Recently Added"),
        ("frequent", "Most Played"),
        ("recent", "Recently Played"),
        ("random", "Random"),
    ]

    var body: some View {
        MacGrid(title: "Albums",
                trailing: AnyView(sortPicker),
                items: albums, isLoading: isLoading, emptyMessage: "No albums") { album in
            NavigationLink(value: album) {
                MacCoverTile(coverArt: album.coverArt, title: album.name,
                             subtitle: album.artist ?? String(localized: "Unknown Artist"), placeholderName: album.name)
            }
            .buttonStyle(MacPressStyle())
        }
        .task(id: order) { await load() }
    }

    private var sortPicker: some View {
        Picker("", selection: $order) {
            ForEach(orders, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        isLoading = true
        defer { isLoading = false }
        // 500 covers is a couple of screens of scrolling and one request; paging in on
        // scroll would be a lot of machinery for a library one person owns.
        albums = (try? await SubsonicClient.shared.getAlbumList2(
            server: server, type: order, size: 500)) ?? []
    }
}

struct MacAlbumDetailView: View {
    let album: Album
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var songs: [Song] = []
    @State private var full: AlbumWithSongs?
    /// The artist's other albums, under the songs.
    @State private var others: [Album] = []
    @State private var loaded = false
    #if !APPSTORE_BUILD
    @State private var edition: AlbumCompletion.Edition?
    #endif

    /// The table's rows and head, so it can be laid out whole and the page scroll as one:
    /// left to fill the window, a short album left the rest of it empty.
    private static let rowHeight: CGFloat = 33, headHeight: CGFloat = 30

    var body: some View {
        ScrollView {
        VStack(spacing: 0) {
            MacDetailHeader(
                coverArt: album.coverArt,
                title: album.name,
                subtitle: [album.artist, album.year.map(String.init),
                           songs.isEmpty ? nil : String(localized: "\(songs.count) songs")]
                    .compactMap { $0 }.joined(separator: " · "),
                placeholderName: album.name
            ) {
                Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                Button { Task { await DownloadManager.shared.downloadAlbum(songs, groupId: album.id) } } label: {
                    Label("Download Album", systemImage: "arrow.down.circle")
                }
                .disabled(songs.isEmpty || songs.allSatisfy { DownloadManager.shared.isDownloaded($0.id) })
            }
            Divider()
            if loaded {
                MacSongTable(songs: songs,
                             source: .album(id: album.id, name: album.name),
                             showsAlbum: false, showsTrackNumber: true)
                    .frame(height: Self.headHeight + Self.rowHeight * CGFloat(max(songs.count, 1)) + 6)
                    .scrollDisabled(true)
            } else {
                MacLoadingState().frame(height: 240)
            }
            #if !APPSTORE_BUILD
            if let full, let edition {
                MacMissingSongs(album: full, edition: edition)
            }
            #endif
            if !others.isEmpty {
                MacShelf(title: "More by \(album.artist ?? "")", items: others) { other in
                    NavigationLink(value: other) {
                        MacPlayableCard(coverArt: other.coverArt, title: other.name,
                                        subtitle: other.year.map(String.init), placeholderName: other.name,
                                        play: { Task { await play(other) } })
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 30)
            }
        }
        }
        // The page opens in the light of its cover, as on the iPhone.
        .background { ZStack { ArtworkCanvas(coverArt: album.coverArt, height: 640); MacFadingGrid() } }
        .navigationTitle(album.name)
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        full = try? await SubsonicClient.shared.getAlbum(server: server, id: album.id)
        songs = full?.song ?? []
        loaded = true
        if let artistId = album.artistId,
           let artist = try? await SubsonicClient.shared.getArtist(server: server, id: artistId) {
            others = (artist.album ?? []).filter { $0.id != album.id }
                .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
        #if !APPSTORE_BUILD
        if let full { edition = await AlbumCompletion.edition(of: full) }
        #endif
    }

    private func play(_ other: Album) async {
        guard let server = serverManager.currentServer,
              let songs = try? await SubsonicClient.shared.getAlbum(server: server, id: other.id).song,
              !songs.isEmpty else { return }
        player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: .album(id: other.id, name: other.name))
    }

    private func play(shuffled: Bool) {
        guard !songs.isEmpty else { return }
        let source = PlaybackSource.album(id: album.id, name: album.name)
        if shuffled {
            player.playShuffled(songs, source: source)
        } else {
            player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: source)
        }
    }
}

#if !APPSTORE_BUILD
/// Under an album, the songs of its release the library doesn't have, each to be had on its
/// own or all at once — the Mac's take on the iPhone's Missing section. A click plays a preview.
private struct MacMissingSongs: View {
    let album: AlbumWithSongs
    let edition: AlbumCompletion.Edition
    @Environment(\.appAccentColor) private var accentColor

    private var release: RadarRelease { edition.release }

    var body: some View {
        let missing = edition.missing(from: album.song ?? [])
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Missing").auraDisplay(28)
                    Spacer()
                    getAll(missing)
                }
                .padding(.bottom, 8)
                ForEach(missing, id: \.id) { track in
                    HStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Text(track.track_position.map(String.init) ?? "")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .leading)
                            Text(track.title).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(track.artist?.name ?? release.artist.name)
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            Text(track.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "")
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .opacity(0.5)
                        .contentShape(Rectangle())
                        .onTapGesture { preview(track) }
                        getOne(track)
                            .frame(width: 32, height: 30)
                    }
                    .frame(height: 30)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
        }
    }

    /// One song's own Get: its ring while it comes in, a check once it's in.
    @ViewBuilder private func getOne(_ track: DeezerTrack) -> some View {
        let fetcher = ReleaseFetcher.shared
        let pick = SoulseekPick.Track(track)
        let own = fetcher.fetch(for: ReleaseFetch.id(release.id, track: pick.id))
        let rest = fetcher.fetch(for: ReleaseFetch.restId(release.id)).flatMap { $0.missing?.contains(pick) == true ? $0 : nil }
        let shown = [rest].compactMap { $0 }.first { $0.stage != .failed } ?? own
        switch shown?.stage {
        case .ready?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accentColor)
        case let stage? where stage != .failed:
            FetchStepsRing(fetch: shown!, tint: accentColor).frame(width: 18, height: 18)
        default:
            Button { fetcher.get(release, track: pick) } label: {
                Image(systemName: own?.stage == .failed ? "arrow.clockwise.circle" : "arrow.down.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(own?.stage == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Get It")
        }
    }

    private func getAll(_ missing: [DeezerTrack]) -> some View {
        let fetch = ReleaseFetcher.shared.fetch(for: ReleaseFetch.restId(release.id))
        let failed = fetch?.stage == .failed
        return Button {
            ReleaseFetcher.shared.complete(release, missing: missing.map(SoulseekPick.Track.init), album: album.id)
        } label: {
            Label(title(of: fetch, count: missing.count), systemImage: failed ? "arrow.clockwise" : "arrow.down.circle")
                .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(accentColor))
        }
        .disabled(fetch?.isActive ?? false)
    }

    private func title(of fetch: ReleaseFetch?, count: Int) -> String {
        if let fetch, fetch.isActive { return fetch.headline }
        if fetch?.stage == .failed { return String(localized: "Try Again") }
        return count == 1 ? String(localized: "Get It") : String(localized: "Get All")
    }

    private func preview(_ track: DeezerTrack) {
        guard let song = track.previewSong(of: release) else {
            ToastManager.shared.show(String(localized: "No preview for this song"), icon: "speaker.slash")
            return
        }
        AudioPlayer.shared.playSong(song, fromQueue: [song], startIndex: 0, source: .album(id: album.id, name: album.name))
    }
}
#endif
