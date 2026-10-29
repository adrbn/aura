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
    @State private var showDownloadAllConfirmation = false
    /// The line of a whole-library download or export while it runs.
    @State private var libraryProgress: String?

    private var songs: [Song] { downloads.downloadedSongs.map(\.song) }

    var body: some View {
        Group {
            if songs.isEmpty && downloads.queueItems.isEmpty {
                ContentUnavailableView {
                    Label("No downloads yet", systemImage: "arrow.down.circle")
                } description: {
                    Text(libraryProgress ?? String(localized: "Download songs or albums to listen offline."))
                } actions: {
                    downloadAllButton
                }
            } else {
                VStack(spacing: 0) {
                    MacDetailHeader(coverArt: songs.first?.coverArt, title: String(localized: "Downloads"),
                                    subtitle: libraryProgress ?? String(localized: "\(songs.count) songs")) {
                        Button { player.playShuffled(songs, source: .songs) } label: {
                            Label("Shuffle Downloaded", systemImage: "shuffle")
                        }
                        downloadAllButton
                        Button(role: .destructive) { downloads.deleteAll() } label: {
                            Label("Delete All Downloads", systemImage: "trash")
                        }
                        .disabled(songs.isEmpty)
                        queueMenu
                    }
                    MacDownloadQueue()
                    Divider()
                    MacSongTable(songs: songs, source: .songs)
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Download Entire Library?", isPresented: $showDownloadAllConfirmation, titleVisibility: .visible) {
            Button("Download to App Storage") {
                guard let server = ServerManager.shared.currentServer else { return }
                Task { await downloads.downloadEntireLibrary(server: server) { libraryProgress = $0 } }
            }
            Button("Export to External Location...") { export() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download every song from your server. Choose \"Export to External Location\" to save to an external drive or custom folder.")
        }
    }

    private var downloadAllButton: some View {
        Button { showDownloadAllConfirmation = true } label: {
            Label("Download Entire Library", systemImage: "arrow.down.to.line")
        }
        .disabled(libraryProgress != nil)
    }

    /// The phone's queue menu: pause, resume or stop everything, and clear what finished.
    @ViewBuilder
    private var queueMenu: some View {
        let finished = downloads.queueItems.contains { $0.state == .completed || $0.state == .cancelled || $0.state == .failed }
        if downloads.isDownloading || downloads.hasPaused || finished {
            Menu {
                if downloads.isDownloading {
                    Button { downloads.pauseAllDownloads() } label: { Label("Pause All", systemImage: "pause.circle") }
                }
                if downloads.hasPaused {
                    Button { downloads.resumeAllDownloads() } label: { Label("Resume All", systemImage: "play.circle") }
                }
                if downloads.isDownloading || downloads.hasPaused {
                    Button(role: .destructive) { downloads.cancelAllDownloads() } label: { Label("Stop All", systemImage: "stop.circle") }
                }
                if finished {
                    Button("Clear Queue History") { downloads.clearFinishedFromQueue() }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// The phone's export, into a folder picked here.
    private func export() {
        guard let server = ServerManager.shared.currentServer else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await downloads.exportEntireLibrary(server: server, to: folder) { libraryProgress = $0 } }
    }
}

/// The songs still coming, paused or failed, as the phone lists them above its downloads:
/// each with its own pause, resume, cancel or retry.
private struct MacDownloadQueue: View {
    @State private var downloads = DownloadManager.shared

    private var items: [DownloadQueueItem] {
        downloads.queueItems.filter { $0.state != .completed && $0.state != .cancelled }
    }

    var body: some View {
        if !items.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { row($0) }
                }
                .padding(.horizontal, 28)
            }
            .frame(maxHeight: min(CGFloat(items.count) * 46, 184))
            .padding(.bottom, 8)
        }
    }

    private func row(_ item: DownloadQueueItem) -> some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: item.song.coverArt, size: 34, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                switch item.state {
                case .downloading:
                    ProgressView(value: item.progress, total: 1.0).tint(Color.appAccent).frame(maxWidth: 240)
                case .paused:
                    Text("Paused").font(.caption).foregroundStyle(.orange)
                case .failed:
                    Text(item.error ?? String(localized: "Failed")).font(.caption).foregroundStyle(.red).lineLimit(1)
                default:
                    Text(item.song.artist ?? String(localized: "Unknown")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            switch item.state {
            case .downloading, .waiting:
                button("pause.circle.fill", "Pause", .orange) { downloads.pauseDownload(item.id) }
                button("xmark.circle.fill", "Cancel", .secondary) { downloads.cancelDownload(item.id) }
            case .paused:
                button("play.circle.fill", "Resume", Color.appAccent) { downloads.resumeDownload(item.id) }
                button("xmark.circle.fill", "Cancel", .secondary) { downloads.cancelDownload(item.id) }
            default:
                button("arrow.clockwise.circle.fill", "Retry", Color.appAccent) { downloads.retryDownload(item.song) }
            }
        }
        .frame(height: 46)
        .contextMenu {
            switch item.state {
            case .downloading, .waiting:
                Button("Pause", systemImage: "pause.circle") { downloads.pauseDownload(item.id) }
                Button("Cancel", systemImage: "xmark.circle") { downloads.cancelDownload(item.id) }
            case .paused:
                Button("Resume", systemImage: "play.circle") { downloads.resumeDownload(item.id) }
                Button("Cancel", systemImage: "xmark.circle") { downloads.cancelDownload(item.id) }
            default:
                Button("Retry", systemImage: "arrow.clockwise.circle") { downloads.retryDownload(item.song) }
            }
        }
    }

    private func button(_ symbol: String, _ help: LocalizedStringKey, _ tint: Color,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
