import Foundation

/// What the radar holds for one server: the releases Deezer lists, and which of them the
/// server already has.
struct Radar: Codable {
    let serverId: UUID
    /// Newest first.
    let releases: [RadarRelease]
    let fetched: Date
    /// Release id → the tracks it lends the playlist, for each release the server has.
    let inLibrary: [String: [Song]]
    let matched: Date

    var missing: [RadarRelease] { releases.filter { inLibrary[$0.id] == nil } }

    /// The playlist: a few tracks from each release on the server, newest release first.
    var songs: [Song] {
        RadarRules.playlist(releases.compactMap { release in inLibrary[release.id].map { (release: release, songs: $0) } })
    }

    var mix: Mix {
        var seen = Set<String>()
        let artists = releases.map(\.artist).filter { seen.insert($0.id).inserted }
        return Mix(id: "radar", title: String(localized: "Radar"),
                   subtitle: String(localized: "New releases from your artists"),
                   songs: songs, kind: .radar, coverArtists: artists)
    }
}

/// Release radar: what came out this month from the artists played most on this server.
///
/// Deezer's catalogue says what was released; the server says what is already here. The
/// catalogue part is the heavy one — a discography per artist — so it runs at most once a
/// day. Matching against the server is a handful of calls and reruns hourly, so a release
/// fetched in the meantime moves from "missing" into the playlist.
@MainActor
@Observable
final class RadarService {
    static let shared = RadarService()

    private(set) var radar: Radar?
    /// Owned here rather than by the screen that asked: a first run takes the best part of a
    /// minute, and leaving Home must not throw it away.
    private var refreshTask: Task<Void, Never>?

    private static let catalogueAge: TimeInterval = 20 * 3600
    private static let libraryAge: TimeInterval = 3600

    private init() {
        radar = ServerManager.shared.currentServer.flatMap { RadarStore.load(for: $0.id) }
    }

    /// The radar for the server on screen, or nil while it is someone else's.
    var current: Radar? {
        guard let radar, radar.serverId == ServerManager.shared.currentServer?.id else { return nil }
        return radar
    }

    func refreshIfNeeded() async {
        // One refresh at a time; once it lands, check again — it may have been another
        // server's, the active one having changed meanwhile.
        if let refreshTask { await refreshTask.value }
        guard refreshTask == nil, AppSettings.shared.radarEnabled, !AppSettings.shared.offlineMode,
              let server = ServerManager.shared.currentServer else { return }
        if radar?.serverId != server.id { radar = RadarStore.load(for: server.id) }
        let now = Date()
        let staleCatalogue = radar.map { now.timeIntervalSince($0.fetched) > Self.catalogueAge } ?? true
        let staleLibrary = radar.map { now.timeIntervalSince($0.matched) > Self.libraryAge } ?? true
        guard staleCatalogue || staleLibrary else { return }

        // Clears itself before anyone waiting on it resumes, so they see the way clear.
        let task = Task {
            await refresh(server: server, catalogue: staleCatalogue)
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func refresh(server: ServerConfig, catalogue staleCatalogue: Bool) async {
        let now = Date()
        let releases: [RadarRelease]
        let fetched: Date
        if staleCatalogue {
            guard let found = await Self.findReleases(server: server, previous: radar?.releases ?? [])
            else { return }
            (releases, fetched) = (found, now)
        } else {
            (releases, fetched) = (radar?.releases ?? [], radar?.fetched ?? now)
        }
        // Once a day everything is checked again; in between, only what was still missing.
        let known = staleCatalogue ? [:] : radar?.inLibrary ?? [:]
        let inLibrary = await Self.match(releases, known: known, server: server)
        let built = Radar(serverId: server.id, releases: releases, fetched: fetched,
                          inLibrary: inLibrary, matched: Date())
        RadarStore.save(built)
        AppLogger.shared.log("📡 Radar: \(releases.count) releases, \(inLibrary.count) on the server")
        if ServerManager.shared.currentServer?.id == server.id { radar = built }
    }

    // MARK: Catalogue

    /// Nil when the server couldn't say who the artists are, or Deezer answered for none of
    /// them — the old radar stays up. An artist Deezer fails on keeps yesterday's releases.
    private static func findReleases(server: ServerConfig, previous: [RadarRelease]) async -> [RadarRelease]? {
        let client = SubsonicClient.shared
        guard let frequent = try? await client.getAlbumList2(server: server, type: "frequent", size: 500) else {
            return nil
        }
        let starred = (try? await client.getStarred2(server: server))?.artist ?? []
        let artists = RadarRules.artists(frequent: frequent, starred: starred)
        let window = RadarWindow.range()

        var releases: [RadarRelease] = []
        var seen = Set<Int>()
        var answered = 0
        for artist in artists {
            guard let albums = await discography(of: artist) else {
                for release in previous where release.artist.id == artist.id && window.contains(release.released)
                    && seen.insert(Int(release.id) ?? 0).inserted {
                    releases.append(release)
                }
                continue
            }
            answered += 1
            // A collaboration lists under each of its artists; the more-played one keeps it.
            for album in RadarRules.fresh(albums, in: window) where seen.insert(album.id).inserted {
                releases.append(RadarRelease(id: String(album.id), title: album.title, artist: artist,
                                             released: album.release_date ?? "", type: album.record_type ?? "album",
                                             cover: album.cover_medium, link: album.link))
            }
        }
        // Deezer down or out of reach: an empty radar would say "nothing new" for a day.
        guard answered > 0 || artists.isEmpty else { return nil }
        return releases.sorted { $0.released > $1.released }
    }

    /// Nil when Deezer couldn't be asked; empty when it doesn't know the artist.
    private static func discography(of artist: ArtistRef) async -> [DeezerAlbum]? {
        switch await RadarCatalog.artistId(for: artist.name) {
        case .found(let id): return await RadarCatalog.albums(artistId: id)
        case .none: return []
        case .failed: return nil
        }
    }

    // MARK: Library

    private static func match(_ releases: [RadarRelease], known: [String: [Song]],
                              server: ServerConfig) async -> [String: [Song]] {
        var discographies: [String: [Album]] = [:]
        var inLibrary: [String: [Song]] = [:]
        for release in releases {
            if let songs = known[release.id] {
                inLibrary[release.id] = songs
                continue
            }
            if discographies[release.artist.id] == nil {
                discographies[release.artist.id] =
                    (try? await SubsonicClient.shared.getArtist(server: server, id: release.artist.id))?.album ?? []
            }
            guard let found = await find(release, among: discographies[release.artist.id] ?? [], server: server)
            else { continue }
            inLibrary[release.id] = Array(found.prefix(RadarRules.perRelease))
        }
        return inLibrary
    }

    /// The release on the server: an album of the same name by the artist, else one filed
    /// under another credit, else — for a single — the song itself on some other album.
    private static func find(_ release: RadarRelease, among albums: [Album],
                             server: ServerConfig) async -> [Song]? {
        let client = SubsonicClient.shared
        var album = albums.first { RadarRules.sameTitle($0.name, release.title) }
        if album == nil,
           let hits = try? await client.search3(server: server, query: release.title,
                                                artistCount: 0, albumCount: 20, songCount: 0) {
            album = hits.album?.first {
                RadarRules.sameTitle($0.name, release.title) && RadarRules.credits($0.artist, release.artist.name)
            }
        }
        if let album, let full = try? await client.getAlbum(server: server, id: album.id) {
            return full.song ?? []
        }
        guard release.type == "single",
              let hits = try? await client.search3(server: server, query: release.title,
                                                   artistCount: 0, albumCount: 0, songCount: 20) else { return nil }
        let songs = (hits.song ?? []).filter {
            RadarRules.sameTitle($0.title, release.title) && RadarRules.credits($0.artist, release.artist.name)
        }
        return songs.first.map { [$0] }
    }

}

/// Where each server's radar lives between launches. Not tied to the main actor, so removing
/// a server can clear it from wherever that happens.
enum RadarStore {
    private static func key(_ serverId: UUID) -> String { "radar_v1_\(serverId.uuidString)" }

    static func load(for serverId: UUID) -> Radar? {
        guard let data = UserDefaults.standard.data(forKey: key(serverId)) else { return nil }
        return try? JSONDecoder().decode(Radar.self, from: data)
    }

    static func save(_ radar: Radar) {
        guard let data = try? JSONEncoder().encode(radar) else { return }
        UserDefaults.standard.set(data, forKey: key(radar.serverId))
    }

    static func removeAll(for serverId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(serverId))
    }
}
