import SwiftUI

struct DownloadManagerView: View {
    @State private var dm = DownloadManager.shared
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var searchText = ""

    private var filteredDownloads: [DownloadedSong] {
        if searchText.isEmpty {
            return dm.downloadedSongs.sorted { $0.downloadDate > $1.downloadDate }
        }
        return dm.downloadedSongs
            .filter {
                $0.song.title.localizedCaseInsensitiveContains(searchText) ||
                ($0.song.artist ?? "").localizedCaseInsensitiveContains(searchText) ||
                ($0.song.album ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.downloadDate > $1.downloadDate }
    }

    var body: some View {
        List {
            // Downloaded header with cover art
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [.green, .green.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 160, height: 160)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.white)
                }
                .shadow(color: .green.opacity(0.4), radius: 12, y: 6)

                Text("\(dm.downloadedSongs.count) songs · \(dm.totalDownloadSize)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Play / Shuffle buttons
                HStack(spacing: 12) {
                    Button {
                        let songs = dm.downloadedSongs.map { $0.song }
                        guard !songs.isEmpty else { return }
                        player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: .songs)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        let songs = dm.downloadedSongs.map { $0.song }
                        guard !songs.isEmpty else { return }
                        player.playShuffled(songs, source: .songs)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            // Active downloads section
            if !activeItems.isEmpty {
                Section {
                    ForEach(activeItems) { item in
                        downloadQueueRow(item)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack {
                        Text("Downloading")
                        Spacer()
                        Button {
                            dm.pauseAllDownloads()
                        } label: {
                            Label("Pause All", systemImage: "pause.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .textCase(nil)
                        Button(role: .destructive) {
                            dm.cancelAllDownloads()
                        } label: {
                            Label("Stop All", systemImage: "stop.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .textCase(nil)
                    }
                }
            }

            if !pausedItems.isEmpty {
                Section {
                    ForEach(pausedItems) { item in
                        downloadQueueRow(item)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack {
                        Text("Paused")
                        Spacer()
                        Button {
                            dm.resumeAllDownloads()
                        } label: {
                            Label("Resume All", systemImage: "play.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .textCase(nil)
                    }
                }
            }

            if !failedItems.isEmpty {
                Section("Failed") {
                    ForEach(failedItems) { item in
                        downloadQueueRow(item)
                            .listRowBackground(Color.clear)
                    }
                }
            }

            // Downloaded songs library (always visible)
            if !filteredDownloads.isEmpty {
                Section("Downloaded (\(dm.downloadedSongs.count) songs, \(dm.totalDownloadSize))") {
                    ForEach(filteredDownloads) { downloaded in
                        downloadedSongRow(downloaded)
                            .listRowBackground(Color.clear)
                    }
                    .onDelete { offsets in
                        let toDelete = offsets.map { filteredDownloads[$0] }
                        for item in toDelete {
                            dm.deleteSong(item.id)
                        }
                    }
                }
            }

            if dm.downloadedSongs.isEmpty && activeItems.isEmpty && failedItems.isEmpty {
                ContentUnavailableView("No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download songs or albums to listen offline."))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .scrollIndicators(.hidden)
        .searchable(text: $searchText, prompt: "Search downloads")
        .navigationTitle("downloaded")
        .toolbar {
            if !dm.downloadedSongs.isEmpty || !dm.queueItems.isEmpty || dm.hasPaused {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if dm.isDownloading {
                            Button {
                                dm.pauseAllDownloads()
                            } label: {
                                Label("Pause All", systemImage: "pause.circle")
                            }
                        }
                        if dm.hasPaused {
                            Button {
                                dm.resumeAllDownloads()
                            } label: {
                                Label("Resume All", systemImage: "play.circle")
                            }
                        }
                        if dm.isDownloading || dm.hasPaused {
                            Button(role: .destructive) {
                                dm.cancelAllDownloads()
                            } label: {
                                Label("Stop All", systemImage: "stop.circle")
                            }
                        }
                        if !dm.queueItems.filter({ $0.state == .completed || $0.state == .cancelled || $0.state == .failed }).isEmpty {
                            Button("Clear Queue History") {
                                dm.clearFinishedFromQueue()
                            }
                        }
                        if !dm.downloadedSongs.isEmpty {
                            Divider()
                            Button("Play All") {
                                let songs = dm.downloadedSongs.map { $0.song }
                                guard !songs.isEmpty else { return }
                                player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: .songs)
                            }
                            Button("Shuffle All") {
                                let songs = dm.downloadedSongs.map { $0.song }
                                guard !songs.isEmpty else { return }
                                player.playShuffled(songs, source: .songs)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var activeItems: [DownloadQueueItem] {
        dm.queueItems.filter { $0.state == .downloading || $0.state == .waiting }
    }

    private var pausedItems: [DownloadQueueItem] {
        dm.queueItems.filter { $0.state == .paused }
    }

    private var failedItems: [DownloadQueueItem] {
        dm.queueItems.filter { $0.state == .failed }
    }

    // MARK: - Downloaded Song Row (clickable, plays the song)

    private func downloadedSongRow(_ downloaded: DownloadedSong) -> some View {
        Button {
            let allSongs = filteredDownloads.map { $0.song }
            if let idx = allSongs.firstIndex(where: { $0.id == downloaded.song.id }) {
                player.playSong(downloaded.song, fromQueue: allSongs, startIndex: idx, source: .songs)
            }
        } label: {
            HStack(spacing: 12) {
                CoverArtImage(coverArt: downloaded.song.coverArt, size: 44, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(downloaded.song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(downloaded.song.artist ?? "Unknown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(downloaded.song.durationFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(DownloadManager.formatBytes(downloaded.fileSize))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { player.playSong(downloaded.song) } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button { player.playNext(downloaded.song) } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button { player.addToQueue(downloaded.song) } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            Divider()
            if let albumId = downloaded.song.albumId {
                Button {
                    player.pendingAlbumId = albumId
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            if let artistId = downloaded.song.artistId {
                Button {
                    player.pendingArtistId = artistId
                } label: {
                    Label("Go to Artist", systemImage: "person")
                }
            }
            Divider()
            Button(role: .destructive) {
                dm.deleteSong(downloaded.id)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                dm.deleteSong(downloaded.id)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete")
        }
    }

    // MARK: - Queue Row (active/failed downloads)

    @ViewBuilder
    private func downloadQueueRow(_ item: DownloadQueueItem) -> some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: item.song.coverArt, size: 44, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.song.artist ?? "Unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.state == .downloading {
                    ProgressView(value: item.progress, total: 1.0)
                        .tint(accentColor)
                } else if item.state == .paused {
                    Text("Paused")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if item.state == .failed, let error = item.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            switch item.state {
            case .downloading, .waiting:
                HStack(spacing: 8) {
                    Button {
                        dm.pauseDownload(item.id)
                    } label: {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pause")
                    Button {
                        dm.cancelDownload(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }
            case .paused:
                HStack(spacing: 8) {
                    Button {
                        dm.resumeDownload(item.id)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(accentColor)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Resume")
                    Button {
                        dm.cancelDownload(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }
            case .failed, .cancelled:
                Button {
                    dm.retryDownload(item.song)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(accentColor)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry")
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
        }
        .padding(.vertical, 2)
    }
}
