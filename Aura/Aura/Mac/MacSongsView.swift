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
        VStack(alignment: .leading, spacing: 0) {
            if songs.isEmpty && isLoading {
                MacLoadingState()
            } else if songs.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
            } else {
                HStack(spacing: 10) {
                    Text("^[\(songs.count) song](inflect: true)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { player.playShuffled(songs, source: .songs) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                MacSongTable(songs: songs, source: .songs)
            }
        }
        .navigationTitle("Songs")
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer, songs.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        var collected: [Song] = []
        var seen = Set<String>()
        while collected.count < ceiling {
            guard let batch = try? await SubsonicClient.shared.search3(
                server: server, query: "", artistCount: 0, albumCount: 0,
                songCount: pageSize, songOffset: collected.count
            ).song, !batch.isEmpty else { break }

            // Deduplicated, and stopped as soon as a page adds nothing new. Not every
            // server honours songOffset on an empty query — some hand back the same page
            // every time, which used to run this straight into the ceiling and report a
            // library of exactly 20,000 songs that didn't exist.
            let fresh = batch.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            collected += fresh
            songs = collected
            if batch.count < pageSize { break }
        }
        songs = collected
    }
}
