import SwiftUI

/// The right-click menus of everything that isn't a song — albums, artists, playlists, mixes,
/// genres — one per kind, so a cover offers the same things in a grid, a shelf, search and
/// the sidebar. The phone's long-press menus, plus what a Mac menu is expected to hold.

/// Play, Shuffle, Play Next and Add to Queue for anything holding songs, fetched when picked.
struct MacPlayMenuItems: View {
    let source: PlaybackSource
    /// A playlist goes into the queue shuffled, as the phone adds one.
    var shufflesQueue = false
    let songs: () async -> [Song]?

    var body: some View {
        Button { run { $0.playSong($1[0], fromQueue: $1, startIndex: 0, source: source) } } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button { run { $0.playShuffled($1, source: source) } } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        Divider()
        // Play Next one by one would land them in reverse.
        Button { run { player, songs in songs.reversed().forEach(player.playNext) } } label: {
            Label("Play Next", systemImage: "text.insert")
        }
        Button { run { $0.addToQueue(shufflesQueue ? $1.shuffled() : $1) } } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }

    private func run(_ act: @escaping @MainActor (AudioPlayer, [Song]) -> Void) {
        Task { @MainActor in
            guard let found = await songs(), !found.isEmpty else { return }
            act(AudioPlayer.shared, found)
        }
    }
}

/// Where each kind's songs come from when its menu needs them.
enum MacItemSongs {
    private static var server: ServerConfig? { ServerManager.shared.currentServer }

    static func album(_ id: String) async -> [Song]? {
        guard let server else { return nil }
        return try? await SubsonicClient.shared.getAlbum(server: server, id: id).song
    }

    static func playlist(_ id: String) async -> [Song]? {
        guard let server else { return nil }
        return try? await SubsonicClient.shared.getPlaylist(server: server, id: id).entry
    }

    static func artist(_ name: String) async -> [Song]? {
        guard let server else { return nil }
        return try? await SubsonicClient.shared.getTopSongs(server: server, artistName: name)
    }

    static func genre(_ name: String) async -> [Song]? {
        guard let server else { return nil }
        return try? await SubsonicClient.shared.getSongsByGenre(server: server, genre: name, count: 500)
    }

    /// The radar's as its page plays them, previews fetched afresh, as on the phone.
    @MainActor static func mix(_ mix: Mix) async -> [Song]? {
        guard mix.kind == .radar else { return mix.songs }
        await RadarService.shared.loadTrackLists()
        return RadarService.shared.queue
    }
}

/// Albums and artists favourited from a menu. A grid holds copies, so without this the menu
/// would still offer "Favourite" for one just favourited.
@MainActor @Observable final class MacItemStars {
    static let shared = MacItemStars()
    private var starred: [String: Bool] = [:]

    func isStarred(_ id: String, _ fallback: Bool) -> Bool { starred[id] ?? fallback }

    func toggle(_ id: String, type: StarType, was: Bool) {
        guard let server = ServerManager.shared.currentServer else { return }
        starred[id] = !was
        Task {
            do {
                if was {
                    try await SubsonicClient.shared.unstar(server: server, id: id, type: type)
                } else {
                    try await SubsonicClient.shared.star(server: server, id: id, type: type)
                }
            } catch {
                starred[id] = was
                AppLogger.shared.log("Failed to toggle favorite: \(error.localizedDescription)")
            }
        }
    }
}

private struct MacStarItem: View {
    let id: String
    let type: StarType
    let fallback: Bool
    @State private var stars = MacItemStars.shared

    var body: some View {
        let starred = stars.isStarred(id, fallback)
        Button { stars.toggle(id, type: type, was: starred) } label: {
            Label(starred ? "Unfavourite" : "Favourite", systemImage: starred ? "heart.slash" : "heart")
        }
    }
}

struct MacAlbumMenuItems: View {
    let album: Album
    @State private var downloads = DownloadManager.shared

    var body: some View {
        MacPlayMenuItems(source: .album(id: album.id, name: album.name)) { await MacItemSongs.album(album.id) }
        Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
            Task {
                guard let songs = await MacItemSongs.album(album.id), !songs.isEmpty else { return }
                AudioPlayer.shared.startAlbumRadio(songs: songs)
            }
        }
        Divider()
        MacStarItem(id: album.id, type: .album, fallback: album.isStarred)
        let kept = downloads.downloadedSongs.filter { $0.song.albumId == album.id }
        if let count = album.songCount, count > 0, kept.count >= count {
            Button { kept.forEach { downloads.deleteSong($0.id) } } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else {
            Button {
                Task {
                    guard let songs = await MacItemSongs.album(album.id), !songs.isEmpty else { return }
                    await downloads.downloadAlbum(songs, groupId: album.id)
                }
            } label: { Label("Download Album", systemImage: "arrow.down.circle") }
        }
        if let artistId = album.artistId {
            Divider()
            Button("Go to Artist", systemImage: "music.mic") { AudioPlayer.shared.pendingArtistId = artistId }
        }
    }
}

struct MacArtistMenuItems: View {
    let artist: Artist

    var body: some View {
        MacPlayMenuItems(source: .artist(id: artist.id, name: artist.name)) { await MacItemSongs.artist(artist.name) }
        Button("Instant Mix", systemImage: "sparkles") {
            Task {
                guard let songs = await MacItemSongs.artist(artist.name), !songs.isEmpty else { return }
                AudioPlayer.shared.startArtistInstantMix(artistId: artist.id, artistName: artist.name, topSongs: songs)
            }
        }
        Divider()
        MacStarItem(id: artist.id, type: .artist, fallback: artist.isStarred)
    }
}

struct MacPlaylistMenuItems: View {
    let playlist: Playlist
    @State private var downloads = DownloadManager.shared

    var body: some View {
        MacPlayMenuItems(source: .playlist(id: playlist.id, name: playlist.name), shufflesQueue: true) {
            await MacItemSongs.playlist(playlist.id)
        }
        Divider()
        MacPinButton(playlistId: playlist.id, asLabel: true)
        Toggle(isOn: Binding(get: { downloads.keptPlaylistIds.contains(playlist.id) },
                             set: { downloads.setKeepDownloaded(playlist.id, $0) })) {
            Label("Keep Downloaded", systemImage: "arrow.down.circle.dotted")
        }
    }
}

struct MacMixMenuItems: View {
    let mix: Mix

    var body: some View {
        MacPlayMenuItems(source: .mix(id: mix.id, name: mix.title)) { await MacItemSongs.mix(mix) }
    }
}

struct MacGenreMenuItems: View {
    let name: String

    var body: some View {
        MacPlayMenuItems(source: .genre(name: name)) { await MacItemSongs.genre(name) }
    }
}

/// A song shown as a card or an entry rather than a table row: queued, then its own menu.
struct MacSongCardMenuItems: View {
    let song: Song

    var body: some View {
        Button("Play Next", systemImage: "text.insert") { AudioPlayer.shared.playNext(song) }
        Button("Add to Queue", systemImage: "text.append") { AudioPlayer.shared.addToQueue(song) }
        Divider()
        MacSongMenuItems(songs: [song])
    }
}
