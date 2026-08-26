import AppIntents
import Foundation

#if !WIDGET_EXTENSION

/// What went wrong, in words Siri can say out loud.
///
/// A thrown `Error` alone gives the user "something went wrong"; conforming to
/// `CustomLocalizedStringResourceConvertible` is what lets the reason be spoken instead. It
/// matters more here than in most apps, because the usual failure is not a bug — it is a
/// self-hosted server that happens to be unreachable, and that is worth saying plainly.
enum AuraIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noServer
    case unreachable
    case empty(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer: "No server is set up in Aura yet."
        case .unreachable: "Aura can't reach your server right now."
        case .empty(let name): "\(name) is empty."
        }
    }
}

// MARK: - Playlists

/// A playlist, as something Siri and the Shortcuts app can hold and pass around.
struct PlaylistEntity: AppEntity {
    let id: String
    let name: String
    let songCount: Int?

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static var defaultQuery = PlaylistQuery()

    var displayRepresentation: DisplayRepresentation {
        guard let songCount else { return DisplayRepresentation(title: "\(name)") }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(songCount) songs")
    }
}

/// `EntityStringQuery` rather than plain `EntityQuery` because that is what adds
/// `entities(matching:)` — the hook the system uses to turn a name someone *said* into an
/// entity. Without it a parameter can only be picked from a list by hand.
struct PlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        let wanted = Set(identifiers)
        return try await all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let all = try await all()
        // Exact first: with playlists called "2019 - A" and "2019 - B", a contains-match
        // alone hands Siri two candidates and forces a disambiguation nobody wanted.
        if let exact = all.first(where: { $0.name.localizedCaseInsensitiveCompare(string) == .orderedSame }) {
            return [exact]
        }
        return all.filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    /// What a spoken phrase can resolve against. App Shortcut phrases only match values
    /// supplied here in advance, so this list *is* the vocabulary — which is precisely why
    /// playlists work by voice and a fifty-thousand-song library does not.
    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await all()
    }

    private func all() async throws -> [PlaylistEntity] {
        guard let server = ServerManager.shared.currentServer else { throw AuraIntentError.noServer }
        guard let playlists = try? await SubsonicClient.shared.getPlaylists(server: server) else {
            throw AuraIntentError.unreachable
        }
        return playlists.map { PlaylistEntity(id: $0.id, name: $0.name, songCount: $0.songCount) }
    }
}

struct PlayPlaylistIntent: AudioStartingIntent {
    static var title: LocalizedStringResource = "Play Playlist"
    static var description = IntentDescription("Plays one of your playlists in Aura.")
    static var openAppWhenRun = false

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffled
        }
    }

    func perform() async throws -> some IntentResult {
        guard let server = ServerManager.shared.currentServer else { throw AuraIntentError.noServer }
        guard let found = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id) else {
            throw AuraIntentError.unreachable
        }
        let songs = found.entry ?? []
        guard !songs.isEmpty else { throw AuraIntentError.empty(playlist.name) }

        let source = PlaybackSource.playlist(id: playlist.id, name: playlist.name)
        let shuffle = shuffled
        await MainActor.run {
            if shuffle {
                AudioPlayer.shared.playShuffled(songs, source: source)
            } else {
                AudioPlayer.shared.playSong(songs[0], fromQueue: songs, startIndex: 0, source: source)
            }
        }
        return .result()
    }
}

// MARK: - Albums

struct AlbumEntity: AppEntity {
    let id: String
    let name: String
    let artist: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static var defaultQuery = AlbumQuery()

    var displayRepresentation: DisplayRepresentation {
        guard let artist else { return DisplayRepresentation(title: "\(name)") }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(artist)")
    }
}

struct AlbumQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        guard let server = ServerManager.shared.currentServer else { throw AuraIntentError.noServer }
        // One request per id rather than trawling the library: identifiers arrive when a
        // saved shortcut is re-run, so there are only ever a handful.
        var found: [AlbumEntity] = []
        for id in identifiers {
            if let album = try? await SubsonicClient.shared.getAlbum(server: server, id: id) {
                found.append(AlbumEntity(id: album.id, name: album.name, artist: album.artist))
            }
        }
        return found
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        guard let server = ServerManager.shared.currentServer else { throw AuraIntentError.noServer }
        guard let results = try? await SubsonicClient.shared.search3(
            server: server, query: string, artistCount: 0, albumCount: 12, songCount: 0
        ) else { throw AuraIntentError.unreachable }
        return (results.album ?? []).map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
    }

    /// Deliberately the recently-added shelf and not the whole library: this list is offered
    /// as a menu, and a menu of every album anyone owns is not a menu.
    func suggestedEntities() async throws -> [AlbumEntity] {
        guard let server = ServerManager.shared.currentServer else { return [] }
        let albums = (try? await SubsonicClient.shared.getAlbumList2(
            server: server, type: "newest", size: 25)) ?? []
        return albums.map { AlbumEntity(id: $0.id, name: $0.name, artist: $0.artist) }
    }
}

struct PlayAlbumIntent: AudioStartingIntent {
    static var title: LocalizedStringResource = "Play Album"
    static var description = IntentDescription("Plays an album in Aura.")
    static var openAppWhenRun = false

    @Parameter(title: "Album")
    var album: AlbumEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)") {
            \.$shuffled
        }
    }

    func perform() async throws -> some IntentResult {
        guard let server = ServerManager.shared.currentServer else { throw AuraIntentError.noServer }
        guard let found = try? await SubsonicClient.shared.getAlbum(server: server, id: album.id) else {
            throw AuraIntentError.unreachable
        }
        let songs = found.song ?? []
        guard !songs.isEmpty else { throw AuraIntentError.empty(album.name) }

        let source = PlaybackSource.album(id: album.id, name: album.name)
        let shuffle = shuffled
        await MainActor.run {
            if shuffle {
                AudioPlayer.shared.playShuffled(songs, source: source)
            } else {
                AudioPlayer.shared.playSong(songs[0], fromQueue: songs, startIndex: 0, source: source)
            }
        }
        return .result()
    }
}

#endif
