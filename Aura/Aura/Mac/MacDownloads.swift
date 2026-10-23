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

/// Keeping songs on this Mac, shown as Get It is: a glass card top-right while they come
/// in, which says so once they're all here and then goes.
struct MacDownloadNotice: View {
    @State private var downloads = DownloadManager.shared
    @State private var justFinished = false
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        // Always there, so the end of the downloads is seen once the card is gone.
        ZStack {
            if downloads.isDownloading || justFinished { card }
        }
        .onChange(of: downloads.isDownloading) { _, active in
            guard !active else { return }
            justFinished = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.smooth(duration: 0.35)) { justFinished = false }
            }
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(downloads.isDownloading ? (downloads.currentDownloadTitle ?? String(localized: "Downloading…")) : String(localized: "Downloaded"))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if downloads.isDownloading, downloads.totalQueueCount > 1 {
                    Text("\(min(downloads.completedQueueCount + 1, downloads.totalQueueCount)) / \(downloads.totalQueueCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                if downloads.isDownloading {
                    Circle().stroke(.primary.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: downloads.currentDownloadId.flatMap { downloads.downloadProgress[$0] } ?? 0)
                        .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(accentColor)
                }
            }
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 16)
        .frame(width: 300, height: 46)
        .glassEffect(.regular, in: Capsule())
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
