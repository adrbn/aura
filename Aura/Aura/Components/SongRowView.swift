import SwiftUI

struct SongRowView: View {
    let song: Song
    var showArt: Bool = true
    var showArtist: Bool = true
    var tappableArtist: Bool = false
    var showTrackNumber: Bool = false
    var disableSwipeActions: Bool = false
    var onTap: (() -> Void)?

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var downloadManager = DownloadManager.shared
    @State private var showFileInfo = false
    @State private var showAddToPlaylist = false
    @State private var showShareSheet = false
    @State private var showRadioExistsDialog = false
    @State private var existingRadioPlaylistId: String?
    @State private var existingRadioPlaylistName: String = ""

    var body: some View {
        HStack(spacing: 12) {
            if showTrackNumber {
                Text("\(song.track ?? 0)")
                    .font(.subheadline).foregroundStyle(.secondary).frame(width: 24)
            }
            if showArt {
                CoverArtImage(coverArt: song.displayCoverArt, size: 50, cornerRadius: 6,
                              fallbackCoverArt: song.albumId,
                              placeholderName: song.title, placeholderKind: .song)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(player.currentSong?.id == song.id ? accentColor : .primary)
                        .lineLimit(1)
                    if song.isExplicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                if showArtist {
                    if tappableArtist {
                        TappableArtistText(
                            artistString: song.artist ?? String(localized: "Unknown Artist"),
                            primaryArtistId: song.artistId,
                            font: .caption,
                            foregroundStyle: AnyShapeStyle(.secondary),
                            tappableStyle: AnyShapeStyle(.secondary)
                        )
                    } else {
                        Text(song.artist ?? String(localized: "Unknown Artist"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if downloadManager.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(accentColor.opacity(0.6))
            }
            Text(song.durationFormatted).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.title), \(song.artist ?? String(localized: "Unknown Artist")), \(song.durationFormatted)")
        .accessibilityHint("Double tap to play")
        // A plain List paints its rows `systemBackground`, pure black, below the page's
        // own canvas; clear, the row sits on whatever the page is.
        .listRowBackground(Color.clear)
        .modifier(SongRowSwipeModifier(song: song, player: player, disabled: disableSwipeActions))
        .contextMenu {
            Button { player.playNext(song) } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button { player.addToQueue(song) } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            Divider()
            Button { toggleStar() } label: {
                Label(song.isStarred ? "Unfavorite" : "Favorite",
                      systemImage: song.isStarred ? "heart.slash" : "heart")
            }
            Button { showAddToPlaylist = true } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            Button {
                Task { await downloadManager.downloadSong(song) }
            } label: {
                if downloadManager.isDownloaded(song.id) {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .disabled(downloadManager.isDownloaded(song.id))
            Divider()
            Button { showShareSheet = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button { showFileInfo = true } label: {
                Label("File Info", systemImage: "info.circle")
            }
            Button {
                startRadioWithCheck()
            } label: {
                Label("Start Radio", systemImage: "antenna.radiowaves.left.and.right")
            }
            if let albumId = song.albumId {
                Divider()
                Button {
                    player.pendingAlbumId = albumId
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
            if let artistId = song.artistId {
                Button {
                    player.pendingArtistId = artistId
                } label: {
                    Label("Go to Artist", systemImage: "person")
                }
            }
        }
        .confirmationDialog("Radio already exists", isPresented: $showRadioExistsDialog) {
            if let savedId = existingRadioPlaylistId {
                Button("View Saved Playlist") {
                    player.pendingPlaylistId = savedId
                }
            } else {
                Button("View Existing Radio") {
                    player.pendingRadioOpen = true
                }
            }
            Button("Generate New Radio") {
                player.startRadioFromSong(song)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\"\(existingRadioPlaylistName)\" already exists. View it or generate a new one?")
        }
        .sheet(isPresented: $showFileInfo) {
            SongInfoSheet(song: song)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistView(song: song)
        }
        .sheet(isPresented: $showShareSheet) {
            SongShareSheet(song: song)
        }
    }

    private func startRadioWithCheck() {
        let radioName = "Radio: \(song.title)"

        // Check in-memory radio first
        if player.radioPlaylistName == radioName && !player.radioPlaylistSongs.isEmpty {
            existingRadioPlaylistId = nil
            existingRadioPlaylistName = player.radioPlaylistName
            showRadioExistsDialog = true
            return
        }

        // Check server-side saved playlists
        Task {
            guard let server = ServerManager.shared.currentServer else {
                player.startRadioFromSong(song)
                return
            }
            do {
                let playlists = try await SubsonicClient.shared.getPlaylists(server: server)
                if let existing = playlists.first(where: { $0.name == radioName }) {
                    await MainActor.run {
                        existingRadioPlaylistId = existing.id
                        existingRadioPlaylistName = existing.name
                        showRadioExistsDialog = true
                    }
                } else {
                    await MainActor.run {
                        player.startRadioFromSong(song)
                    }
                }
            } catch {
                await MainActor.run {
                    player.startRadioFromSong(song)
                }
            }
        }
    }

    private func toggleStar() {
        guard let server = ServerManager.shared.currentServer else { return }
        Task {
            if song.isStarred {
                try? await SubsonicClient.shared.unstar(server: server, id: song.id)
            } else {
                try? await SubsonicClient.shared.star(server: server, id: song.id)
            }
        }
    }
}

private struct SongRowSwipeModifier: ViewModifier {
    let song: Song
    let player: AudioPlayer
    let disabled: Bool

    func body(content: Content) -> some View {
        if disabled {
            content
        } else {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button { player.playNext(song) } label: {
                        Image(systemName: "text.insert")
                    }
                    .accessibilityLabel("Play Next")
                    .tint(.blue)
                    Button { toggleStar() } label: {
                        Image(systemName: song.isStarred ? "heart.slash" : "heart")
                    }
                    .accessibilityLabel(song.isStarred ? "Unfavorite" : "Favorite")
                    .tint(.green)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { player.addToQueue(song) } label: {
                        Image(systemName: "text.append")
                    }
                    .accessibilityLabel("Add to Queue")
                    .tint(.orange)
                }
        }
    }

    private func toggleStar() {
        guard let server = ServerManager.shared.currentServer else { return }
        Task {
            if song.isStarred {
                try? await SubsonicClient.shared.unstar(server: server, id: song.id)
            } else {
                try? await SubsonicClient.shared.star(server: server, id: song.id)
            }
        }
    }
}
