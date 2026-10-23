import SwiftUI

/// "Download" or "Remove Download" for one or several songs, in any song's context menu.
/// The same `DownloadManager` as the phone: a downloaded song plays from the Mac's disk.
struct MacDownloadMenuItem: View {
    let songs: [Song]
    @State private var downloads = DownloadManager.shared

    var body: some View {
        if !songs.isEmpty, songs.allSatisfy({ downloads.isDownloaded($0.id) }) {
            Button { songs.forEach { downloads.deleteSong($0.id) } } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else {
            Button { Task { await downloads.downloadAlbum(songs) } } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(songs.isEmpty)
        }
    }
}

/// The songs kept on this Mac, played from its disk whether the server answers or not.
struct MacDownloadsView: View {
    @State private var downloads = DownloadManager.shared
    @State private var player = AudioPlayer.shared

    private var songs: [Song] { downloads.downloadedSongs.map(\.song) }

    var body: some View {
        Group {
            if songs.isEmpty {
                ContentUnavailableView("No downloads yet", systemImage: "arrow.down.circle",
                                       description: Text("Download songs or albums to listen offline."))
            } else {
                VStack(spacing: 0) {
                    MacDetailHeader(coverArt: songs.first?.coverArt, title: String(localized: "Downloads"),
                                    subtitle: String(localized: "\(songs.count) songs")) {
                        Button { player.playShuffled(songs, source: .songs) } label: {
                            Label("Shuffle Downloaded", systemImage: "shuffle")
                        }
                        Button(role: .destructive) { downloads.deleteAll() } label: {
                            Label("Delete All Downloads", systemImage: "trash")
                        }
                    }
                    Divider()
                    MacSongTable(songs: songs, source: .songs)
                }
            }
        }
        .navigationTitle("Downloads")
    }
}
