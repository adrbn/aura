import SwiftUI

/// A song as a row with its artwork, for search results and anywhere else a handful of
/// songs are shown among albums and artists.
///
/// Not `MacSongTable`: a table is right for a thousand rows you scan by column, and wrong
/// for six results sitting under a shelf of album covers. Among covers, a song without one
/// reads as a different kind of thing entirely.
struct MacSongRow: View {
    let song: Song
    var source: PlaybackSource = .unknown
    var queue: [Song] = []

    @State private var player = AudioPlayer.shared
    @State private var hovering = false

    private var isCurrent: Bool { song.id == player.currentSong?.id }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CoverArtImage(coverArt: song.coverArt, size: 52, cornerRadius: 6)
                if hovering {
                    Color.black.opacity(0.45)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.appAccent : .primary)
                    .lineLimit(1)
                Text(song.artist ?? String(localized: "Unknown Artist"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Text(song.album ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .trailing)

            Text(MacFormat.duration(song.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.white.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { play() }
        .contextMenu {
            Button("Play") { play() }
            Button("Play Next") { player.playNext(song) }
            Button("Add to Queue") { player.addToQueue(song) }
            Divider()
            MacSongMenuItems(songs: [song])
        }
    }

    /// Plays with the whole result set behind it, so picking the third hit still leaves the
    /// other results queued rather than stranding you on one song.
    private func play() {
        let songs = queue.isEmpty ? [song] : queue
        let index = songs.firstIndex { $0.id == song.id } ?? 0
        player.playSong(songs[index], fromQueue: songs, startIndex: index, source: source)
    }
}

/// What a song's menu does beyond queueing it, shared by the song table, the rows, the
/// queue and the player bar so every list offers the same things.
///
/// The sheets these open are presented once, by the player bar, which is always on screen:
/// a menu item only has to set `infoSong` or `newPlaylistSongs`.
@Observable
final class MacSongActions {
    static let shared = MacSongActions()

    /// The user's playlists, for Add to Playlist. A menu can't wait on the server, so it
    /// shows this list and asks for a fresh one for next time.
    private(set) var playlists: [Playlist] = []
    /// The song whose info sheet is open.
    var infoSong: Song?
    /// The songs waiting for a name for the playlist they will start.
    var newPlaylistSongs: [Song]?
    /// Favourites set from a menu. A list holds copies of its songs, so without this the
    /// menu would still offer "Favourite" for a song just favourited.
    private var starred: [String: Bool] = [:]

    private var player: AudioPlayer { .shared }

    func isStarred(_ song: Song) -> Bool {
        if let current = player.currentSong, current.id == song.id { return current.isStarred }
        return starred[song.id] ?? song.isStarred
    }

    /// Favourites them all, or unfavourites them all when every one already is.
    func toggleFavorite(_ songs: [Song]) {
        guard let server = ServerManager.shared.currentServer else { return }
        let star = !songs.allSatisfy(isStarred)
        for song in songs where isStarred(song) != star {
            // The playing song goes through the player, which updates the bar and the queue.
            if song.id == player.currentSong?.id { player.toggleFavorite(); continue }
            starred[song.id] = star
            Task {
                do {
                    if star {
                        try await SubsonicClient.shared.star(server: server, id: song.id)
                    } else {
                        try await SubsonicClient.shared.unstar(server: server, id: song.id)
                    }
                } catch {
                    await MainActor.run { self.starred[song.id] = !star }
                    AppLogger.shared.log("Failed to toggle favorite: \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshPlaylists() {
        guard let server = ServerManager.shared.currentServer else { return }
        Task {
            guard let found = try? await SubsonicClient.shared.getPlaylists(server: server) else { return }
            await MainActor.run { self.playlists = found }
        }
    }

    func add(_ songs: [Song], to playlist: Playlist) {
        guard let server = ServerManager.shared.currentServer else { return }
        Task {
            do {
                for song in songs {
                    try await SubsonicClient.shared.addSongToPlaylist(server: server, playlistId: playlist.id, songId: song.id)
                }
                await MainActor.run {
                    songs.forEach { PlaylistMembershipCache.shared.markSongInPlaylist(songId: $0.id, playlistId: playlist.id) }
                    ToastManager.shared.show(String(localized: "Added to \(playlist.name)"), icon: "text.badge.plus")
                }
                refreshPlaylists()
            } catch {
                AppLogger.shared.log("Failed to add to playlist: \(error.localizedDescription)")
            }
        }
    }

    func createPlaylist(named name: String, with songs: [Song]) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let server = ServerManager.shared.currentServer else { return }
        Task {
            do {
                try await SubsonicClient.shared.createPlaylist(server: server, name: name, songIds: songs.map(\.id))
                await MainActor.run { ToastManager.shared.show(String(localized: "Created \(name)"), icon: "plus.circle.fill") }
                refreshPlaylists()
            } catch {
                AppLogger.shared.log("Failed to create playlist: \(error.localizedDescription)")
            }
        }
    }

    /// The song's song.link page, found the way the phone's Share sheet finds it.
    func copyLink(_ song: Song) {
        Task {
            let links = await SongLinkService.shared.fetchLinks(title: song.title, artist: song.artist ?? "")
            await MainActor.run {
                guard let url = links?.pageUrl else {
                    ToastManager.shared.show(String(localized: "No link found for this song"), icon: "link")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                ToastManager.shared.show(String(localized: "Link copied"), icon: "link")
            }
        }
    }
}

/// The song menu's own items, after whatever Play items the list it sits in needs.
struct MacSongMenuItems: View {
    let songs: [Song]
    @State private var actions = MacSongActions.shared
    @State private var player = AudioPlayer.shared
    @State private var downloads = DownloadManager.shared

    private var song: Song? { songs.count == 1 ? songs[0] : nil }

    var body: some View {
        let starred = !songs.isEmpty && songs.allSatisfy(actions.isStarred)
        Button { actions.toggleFavorite(songs) } label: {
            Label(starred ? "Unfavourite" : "Favourite", systemImage: starred ? "heart.slash" : "heart")
        }
        .disabled(songs.isEmpty)
        MacRatingMenu(songs: songs)
        Menu {
            Button("New Playlist…") { actions.newPlaylistSongs = songs }
            if !actions.playlists.isEmpty { Divider() }
            ForEach(actions.playlists) { playlist in
                // Already there: said, and not added a second time.
                if let song, PlaylistMembershipCache.shared.cache[song.id]?.contains(playlist.id) == true {
                    Button {} label: { Label(playlist.name, systemImage: "checkmark") }.disabled(true)
                } else {
                    Button(playlist.name) { actions.add(songs, to: playlist) }
                }
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .disabled(songs.isEmpty)
        .onAppear { actions.refreshPlaylists() }
        if let song {
            Divider()
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadioFromSong(song) }
            if let albumId = song.albumId {
                Button("Go to Album", systemImage: "square.stack") { player.pendingAlbumId = albumId }
            }
            if let artistId = song.artistId {
                Button("Go to Artist", systemImage: "music.mic") { player.pendingArtistId = artistId }
            }
            Divider()
            Button("Copy Song Link", systemImage: "link") { actions.copyLink(song) }
            Button("Song Info…", systemImage: "info.circle") { actions.infoSong = song }
        }
        Divider()
        // Kept once downloaded, as a statement, as on the phone; removing stays beside it.
        if !songs.isEmpty, songs.allSatisfy({ downloads.isDownloaded($0.id) }) {
            Button {} label: { Label("Downloaded", systemImage: "checkmark.circle.fill") }.disabled(true)
        }
        MacDownloadMenuItem(songs: songs)
    }
}

/// Everything known about a song: the phone's File Info and Credits sheets in one.
struct MacSongInfoSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @State private var credits: SongCredits?
    @State private var loadingCredits = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        CoverArtImage(coverArt: song.coverArt, size: 72, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title).font(.headline)
                            Text(song.artist ?? String(localized: "Unknown Artist")).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Track Info") {
                    row("Title", song.title)
                    row("Artist", song.artist)
                    row("Album", song.album)
                    row("Track #", song.track.map(String.init))
                    row("Year", song.year.map(String.init))
                    row("Genre", song.genre)
                    row("Duration", song.durationFormatted)
                    row("Play Count", song.playCount.map(String.init))
                }
                Section("Original File") {
                    row("Format", song.suffix?.uppercased())
                    row("Content Type", song.contentType)
                    row("Bitrate", song.bitRate.map { "\($0) kbps" })
                    row("File Size", song.fileSizeFormatted)
                    row("Path", song.path)
                }
                // MusicBrainz's credits, when it knows the song; nothing at all when it doesn't.
                if loadingCredits {
                    Section("Credits") {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Looking up credits…").foregroundStyle(.secondary)
                        }
                    }
                } else if let credits, credits.hasAnyCredits {
                    Section("Credits") {
                        people("Written By", credits.writers)
                        people("Composed By", credits.composers)
                        people("Lyrics By", credits.lyricists)
                        people("Produced By", credits.producers)
                        ForEach(Array(credits.performers.enumerated()), id: \.offset) { _, performer in
                            LabeledContent(performer.role, value: performer.name)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
        .task {
            if let artist = song.artist {
                credits = await MusicBrainzService.shared.fetchCredits(title: song.title, artist: artist)
            }
            loadingCredits = false
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) { Text(value).textSelection(.enabled) }
        }
    }

    private func people(_ label: LocalizedStringKey, _ names: [String]) -> some View {
        row(label, names.isEmpty ? nil : names.joined(separator: ", "))
    }
}
