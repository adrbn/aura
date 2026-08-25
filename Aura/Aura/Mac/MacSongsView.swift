import SwiftUI

/// Every song in the library, in one table.
///
/// Subsonic has no "all songs" call, so this is `search3` with an empty query, paged — the
/// same trick the iOS app's bulk operations use. The whole library is pulled once per
/// launch rather than paged in on scroll: a `Table` that grows underneath you loses the
/// selection and the scroll position, and a personal library fits in memory comfortably.
struct MacSongsView: View {
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var songs: [Song] = []
    @State private var isLoading = false

    private let pageSize = 500
    /// A stop, so a mis-configured server can't spin forever.
    private let ceiling = 20_000

    var body: some View {
        Group {
            if songs.isEmpty && isLoading {
                MacLoadingState()
            } else if songs.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
            } else {
                MacSongTable(songs: songs, source: .songs)
            }
        }
        .navigationTitle("Songs")
        .toolbar {
            if !songs.isEmpty {
                Text("\(songs.count) songs").foregroundStyle(.secondary)
                Button { player.playShuffled(songs, source: .songs) } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer, songs.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        var collected: [Song] = []
        while collected.count < ceiling {
            guard let batch = try? await SubsonicClient.shared.search3(
                server: server, query: "", artistCount: 0, albumCount: 0,
                songCount: pageSize, songOffset: collected.count
            ).song else { break }
            collected.append(contentsOf: batch)
            // Show the first page immediately; the rest fills in behind it.
            if collected.count == batch.count { songs = collected }
            if batch.count < pageSize { break }
        }
        songs = collected
    }
}
