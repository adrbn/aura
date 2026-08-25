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
        MacGrid(items: albums, isLoading: isLoading, emptyMessage: "No albums") { album in
            NavigationLink(value: album) {
                MacCoverTile(coverArt: album.coverArt, title: album.name,
                             subtitle: album.artist ?? "Unknown Artist", placeholderName: album.name)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Albums")
        .toolbar {
            Picker("Sort", selection: $order) {
                ForEach(orders, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu)
        }
        .task(id: order) { await load() }
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

    var body: some View {
        VStack(spacing: 0) {
            MacDetailHeader(
                coverArt: album.coverArt,
                title: album.name,
                subtitle: [album.artist, album.year.map(String.init),
                           songs.isEmpty ? nil : "\(songs.count) songs"]
                    .compactMap { $0 }.joined(separator: " · "),
                placeholderName: album.name
            ) {
                Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            }
            Divider()
            MacSongTable(songs: songs,
                         source: .album(id: album.id, name: album.name),
                         showsAlbum: false, showsTrackNumber: true)
        }
        .navigationTitle(album.name)
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        songs = (try? await SubsonicClient.shared.getAlbum(server: server, id: album.id))?.song ?? []
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
