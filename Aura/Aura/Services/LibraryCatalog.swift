#if os(iOS)
import Foundation
import UIKit

/// The library as the watch and the car browse it: what the phone's Home makes for you, the
/// playlists, search, and what's in each — answered from what the phone already has where it
/// can, from the server where it must — and played as the phone plays it.
@MainActor
enum LibraryCatalog {
    /// A long list stays a small message: the watch shows this many songs of a collection.
    private static let listed = 100
    /// Pixels a side: a 36 pt row's cover and a 60 pt header's, at the watch's scale.
    private static let coverSide: CGFloat = 120

    /// Songs the watch has been shown, so one it plays on its own — a search result — is the
    /// phone's own song, not a copy rebuilt from a name.
    private static var shown: [String: Song] = [:]

    private static let player = AudioPlayer.shared

    static func answer(_ request: WatchRequest) async -> [String: Any] {
        switch request {
        case .shelf: return reply(await shelf())
        case .open(let item): return reply(await listing(of: item))
        case .search(let query): return reply(await search(query))
        case .covers(let ids): return [WatchLinkKey.covers: await covers(ids)]
        }
    }

    static func play(_ item: WatchItem, index: Int, shuffled: Bool) async {
        if item.kind == .song {
            guard let song = await song(item.id) else { return }
            player.playSong(song, source: .search(query: ""))
            return
        }
        await play(await songs(of: item), of: item, at: index, shuffled: shuffled)
    }

    /// Plays songs already fetched for `item` — the car's list holds them — as the phone
    /// would play that item.
    static func play(_ songs: [Song], of item: WatchItem, at index: Int, shuffled: Bool) async {
        var songs = songs
        if item.kind == .mix, item.id == "radar" {
            // A preview's address lasts a quarter of an hour: fetch what has gone stale.
            await RadarService.shared.loadTrackLists()
            songs = RadarService.shared.queue
        }
        guard !songs.isEmpty else { return }
        let source = source(of: item)
        if shuffled {
            player.playShuffled(songs, source: source)
        } else {
            let start = songs.indices.contains(index) ? index : 0
            player.playSong(songs[start], fromQueue: songs, startIndex: start, source: source)
        }
    }

    /// Plays a song from Up Next: one queued by hand leaves the queue as it plays, one from
    /// the rest plays from where it stands. Checked first, in case the queue moved on.
    static func playUpcoming(_ songId: String, slot: Int, queued: Bool) {
        if queued {
            guard player.userQueue.indices.contains(slot), player.userQueue[slot].id == songId else { return }
            let song = player.userQueue.remove(at: slot)
            player.playSong(song, fromQueue: player.queue, startIndex: player.queueIndex, source: .queue)
        } else {
            guard player.queue.indices.contains(slot), player.queue[slot].id == songId else { return }
            player.playSong(player.queue[slot], fromQueue: player.queue, startIndex: slot, source: .autoplay)
        }
    }

    // MARK: - Answers

    private static func reply<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return [WatchLinkKey.reply: data]
    }

    /// The Home's Made For You, the radar leading once it has found something, then the
    /// favourites and the playlists.
    private static func shelf() async -> WatchShelf {
        await MixGenerator.shared.generateIfNeeded()
        var mixes = MixGenerator.shared.mixes.map { Self.item($0) }
        if AppSettings.shared.radarEnabled, let radar = RadarService.shared.current, !radar.releases.isEmpty {
            let cover = radar.releases.lazy.compactMap(\.cover).first
            mixes.insert(WatchItem(kind: .mix, id: "radar", title: radar.mix.title,
                                   subtitle: radar.mix.subtitle, coverArt: cover), at: 0)
        }
        let favourites = WatchItem(kind: .favorites, id: "favorites", title: String(localized: "Favorites"),
                                   subtitle: String(localized: "Your starred songs"), coverArt: nil)
        var playlists = [favourites]
        if let server = ServerManager.shared.currentServer {
            do {
                playlists += try await SubsonicClient.shared.getPlaylists(server: server).map { Self.item($0) }
            } catch {
                AppLogger.shared.log("📚 Playlists not loaded: \(error.localizedDescription)")
            }
        }
        return WatchShelf(mixes: mixes, playlists: playlists)
    }

    private static func listing(of item: WatchItem) async -> WatchListing {
        let songs = await songs(of: item)
        var listing = WatchListing(songs: songs.prefix(listed).map { Self.item($0) })
        if item.kind == .artist, let server = ServerManager.shared.currentServer {
            do {
                let artist = try await SubsonicClient.shared.getArtist(server: server, id: item.id)
                listing.albums = (artist.album ?? []).map { Self.item($0) }
            } catch {
                AppLogger.shared.log("📚 Artist not loaded: \(error.localizedDescription)")
            }
        }
        return listing
    }

    private static func search(_ query: String) async -> WatchSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let server = ServerManager.shared.currentServer else { return WatchSearchResults() }
        do {
            let found = try await SubsonicClient.shared.search3(server: server, query: trimmed,
                                                                artistCount: 5, albumCount: 8, songCount: 20)
            let songs = found.song ?? []
            remember(songs)
            return WatchSearchResults(songs: songs.map { Self.item($0) }, albums: (found.album ?? []).map { Self.item($0) },
                                      artists: (found.artist ?? []).map { Self.item($0) })
        } catch {
            AppLogger.shared.log("📚 Search failed: \(error.localizedDescription)")
            return WatchSearchResults()
        }
    }

    /// Each cover small, fetched side by side; one that fails is left out, not the rest.
    private static func covers(_ ids: [String]) async -> [String: Data] {
        guard let server = ServerManager.shared.currentServer else { return [:] }
        let side = coverSide
        let urls = ids.prefix(8).compactMap { id in
            SubsonicClient.shared.coverArtURL(server: server, id: id, size: Int(side)).map { (id, $0) }
        }
        return await withTaskGroup(of: (String, Data?).self) { group in
            for (id, url) in urls {
                group.addTask { (id, await thumbnail(url, side: side)) }
            }
            var found: [String: Data] = [:]
            for await (id, data) in group {
                if let data { found[id] = data }
            }
            return found
        }
    }

    private nonisolated static func thumbnail(_ url: URL, side: CGFloat) async -> Data? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        // At one pixel a point, as the Now Playing cover is sent.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return small.jpegData(compressionQuality: 0.7)
    }

    // MARK: - Songs

    static func songs(of item: WatchItem) async -> [Song] {
        guard let server = ServerManager.shared.currentServer else { return [] }
        let songs: [Song]
        do {
            switch item.kind {
            case .mix:
                if item.id == "radar" {
                    songs = RadarService.shared.queue
                } else {
                    songs = MixGenerator.shared.mixes.first { $0.id == item.id }?.songs ?? []
                }
            case .playlist:
                songs = try await SubsonicClient.shared.getPlaylist(server: server, id: item.id).entry ?? []
            case .favorites:
                songs = try await SubsonicClient.shared.getStarred2(server: server).song ?? []
            case .album:
                songs = try await SubsonicClient.shared.getAlbum(server: server, id: item.id).song ?? []
            case .artist:
                songs = try await SubsonicClient.shared.getTopSongs(server: server, artistName: item.title, count: 50)
            case .song:
                songs = await song(item.id).map { [$0] } ?? []
            }
        } catch {
            AppLogger.shared.log("📚 \(item.kind.rawValue) not loaded: \(error.localizedDescription)")
            return []
        }
        remember(songs)
        return songs
    }

    private static func song(_ id: String) async -> Song? {
        if let song = shown[id] { return song }
        guard let server = ServerManager.shared.currentServer else { return nil }
        return try? await SubsonicClient.shared.getSong(server: server, id: id)
    }

    private static func remember(_ songs: [Song]) {
        // Only the latest few hundred: enough for what's on the watch's screen.
        if shown.count > 600 { shown.removeAll(keepingCapacity: true) }
        for song in songs { shown[song.id] = song }
    }

    private static func source(of item: WatchItem) -> PlaybackSource {
        switch item.kind {
        case .mix: return .mix(id: item.id, name: item.title)
        case .playlist: return .playlist(id: item.id, name: item.title)
        case .favorites: return .favorites
        case .album: return .album(id: item.id, name: item.title)
        case .artist: return .artist(id: item.id, name: item.title)
        case .song: return .search(query: "")
        }
    }

    // MARK: - Items

    static func item(_ mix: Mix) -> WatchItem {
        WatchItem(kind: .mix, id: mix.id, title: mix.title, subtitle: mix.subtitle, coverArt: mix.coverArt)
    }

    static func item(_ playlist: Playlist) -> WatchItem {
        let count = playlist.songCount.map { String(localized: "\($0) songs") } ?? ""
        return WatchItem(kind: .playlist, id: playlist.id, title: playlist.name, subtitle: count,
                         coverArt: playlist.coverArt)
    }

    static func item(_ album: Album) -> WatchItem {
        WatchItem(kind: .album, id: album.id, title: album.name, subtitle: album.artist ?? "",
                  coverArt: album.coverArt)
    }

    static func item(_ artist: Artist) -> WatchItem {
        WatchItem(kind: .artist, id: artist.id, title: artist.name, subtitle: String(localized: "Artist"),
                  coverArt: artist.coverArt)
    }

    static func item(_ song: Song) -> WatchItem {
        WatchItem(kind: .song, id: song.id, title: song.title, subtitle: song.artist ?? String(localized: "Unknown Artist"),
                  coverArt: song.coverArt)
    }
}
#endif
