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

    /// The radar's page before its first run, filled in live once the run lands.
    static var emptyMix: Mix {
        Mix(id: "radar", title: String(localized: "Radar"),
            subtitle: String(localized: "New releases from your artists"), songs: [], kind: .radar)
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
/// day. Matching against the server is a handful of calls and reruns every quarter hour, so
/// a release fetched in the meantime moves from "missing" into the playlist.
@MainActor
@Observable
final class RadarService {
    static let shared = RadarService()

    private(set) var radar: Radar?
    /// Owned here rather than by the screen that asked: a first run takes the best part of a
    /// minute, and leaving Home must not throw it away.
    private var refreshTask: Task<Void, Never>?

    private static let catalogueAge: TimeInterval = 20 * 3600
    /// Only the releases still missing are looked for again, so this can be short: a song
    /// fetched outside the app shows up a quarter of an hour after the server lists it.
    private static let libraryAge: TimeInterval = 15 * 60

    /// Deezer's track lists for the releases the server lacks, for their previews. Held for
    /// the session only: a preview's address stops working after a quarter of an hour.
    private(set) var trackLists: [String: TrackList] = [:]
    private var trackListTask: Task<Void, Never>?
    private static let previewAge: TimeInterval = 10 * 60

    struct TrackList {
        let tracks: [DeezerTrack]
        let fetched: Date
    }

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

    // MARK: Previews

    /// Fetches the track lists of the missing releases that have none yet, or one too old to
    /// play from. Callers arriving meanwhile wait for the same run.
    func loadTrackLists() async {
        if let trackListTask { return await trackListTask.value }
        guard let radar = current else { return }
        let now = Date()
        let due = radar.missing.filter { release in
            trackLists[release.id].map { now.timeIntervalSince($0.fetched) > Self.previewAge } ?? true
        }
        guard !due.isEmpty else { return }
        let task = Task {
            for release in due {
                // Deezer out of reach: the release is left out rather than the whole run.
                guard let tracks = await RadarCatalog.tracks(albumId: release.id) else { continue }
                trackLists[release.id] = TrackList(tracks: tracks, fetched: Date())
            }
            trackListTask = nil
        }
        trackListTask = task
        await task.value
    }

    /// One release's track list: the one at hand while its previews still play, else fetched
    /// again. Nil when Deezer can't be reached.
    func tracks(of release: RadarRelease) async -> [DeezerTrack]? {
        if let list = trackLists[release.id], Date().timeIntervalSince(list.fetched) < Self.previewAge {
            return list.tracks
        }
        guard let tracks = await RadarCatalog.tracks(albumId: release.id) else { return nil }
        trackLists[release.id] = TrackList(tracks: tracks, fetched: Date())
        return tracks
    }

    /// Everything the radar plays: the server's tracks for what it has, Deezer's previews —
    /// the releases' most-played tracks — for the rest, newest release first.
    var queue: [Song] { playlist(of: current?.releases ?? []) }

    /// The radar's queue with one release's songs — all of them, in their own order — where
    /// the release falls among the others, so they run on into the next releases'.
    func queue(playing songs: [Song], of release: RadarRelease) -> [Song] {
        let others = current?.releases.filter { $0.id != release.id } ?? []
        let newer = playlist(of: others.filter { $0.released > release.released })
        let older = playlist(of: others.filter { $0.released <= release.released })
        var seen = Set<String>()
        return (newer + songs + older).filter { seen.insert($0.id).inserted }
    }

    private func playlist(of releases: [RadarRelease]) -> [Song] {
        guard let radar = current else { return [] }
        return RadarRules.playlist(releases.compactMap { release in
            if let songs = radar.inLibrary[release.id] { return (release: release, songs: songs) }
            guard let list = trackLists[release.id] else { return nil }
            let ranked = list.tracks.sorted { ($0.rank ?? 0) > ($1.rank ?? 0) }
            return (release: release, songs: ranked.compactMap { $0.previewSong(of: release) })
        })
    }

    /// The release a preview comes from, if the radar still lists it — or Search turned it up.
    func release(of preview: Song) -> RadarRelease? {
        guard preview.isPreview else { return nil }
        let isIt = { (release: RadarRelease) in
            release.title == preview.album && release.artist.libraryId == preview.artistId
        }
        return current?.releases.first(where: isIt) ?? elsewhere.values.first(where: isIt)
    }

    /// Releases met outside the radar, in Search, so their previews still know where they're
    /// from. Kept for the session.
    @ObservationIgnored private var elsewhere: [String: RadarRelease] = [:]

    func remember(_ releases: [RadarRelease]) {
        for release in releases { elsewhere[release.id] = release }
    }

    /// Looks for one release on the server now, rather than at the next match, and moves it
    /// into the playlist when it's there. Nil while it isn't.
    func lookUp(_ release: RadarRelease) async -> [Song]? {
        guard let server = ServerManager.shared.currentServer else { return nil }
        guard let found = await Self.find(release, among: await Self.albums(of: release, server: server),
                                          server: server) else { return nil }
        let songs = RadarRules.newSongs(found, of: release)
        guard !songs.isEmpty else { return nil }
        take(release, songs: songs)
        return songs
    }

    /// Whether the server has every song of a release now — the album of its name, or its
    /// songs filed under others, as songs fetched one by one are. If so, the release moves
    /// into the playlist rather than waiting for the next match.
    func settle(_ release: RadarRelease) async -> Bool {
        guard let server = ServerManager.shared.currentServer,
              let tracks = await tracks(of: release), !tracks.isEmpty else { return false }
        var held = await Self.find(release, among: await Self.albums(of: release, server: server),
                                   server: server) ?? []
        for track in RadarRules.unheld(tracks, among: held) {
            guard let song = await lookUp(song: track.title, of: release)?.first else { return false }
            held.append(song)
        }
        take(release, songs: RadarRules.newSongs(held, of: release))
        return true
    }

    /// A release the server has, into the playlist — while the radar still lists it.
    private func take(_ release: RadarRelease, songs: [Song]) {
        guard !songs.isEmpty, let radar = current, radar.releases.contains(where: { $0.id == release.id })
        else { return }
        var inLibrary = radar.inLibrary
        inLibrary[release.id] = Array(songs.prefix(RadarRules.perRelease))
        let updated = Radar(serverId: radar.serverId, releases: radar.releases, fetched: radar.fetched,
                            inLibrary: inLibrary, matched: radar.matched)
        RadarStore.save(updated)
        self.radar = updated
    }

    /// The artist's albums on the server — none for an artist it doesn't know, as with a
    /// release Search turned up.
    private static func albums(of release: RadarRelease, server: ServerConfig) async -> [Album] {
        guard let id = release.artist.libraryId else { return [] }
        return (try? await SubsonicClient.shared.getArtist(server: server, id: id))?.album ?? []
    }

    /// One of a release's songs on the server, when only that was fetched. Leaves the radar
    /// as it is: the rest of the release is still to be had.
    func lookUp(song title: String, of release: RadarRelease) async -> [Song]? {
        guard let server = ServerManager.shared.currentServer,
              let hits = try? await SubsonicClient.shared.search3(server: server, query: title, artistCount: 0,
                                                                  albumCount: 0, songCount: 20) else { return nil }
        let song = (hits.song ?? []).first {
            RadarRules.sameTitle($0.title, title) && RadarRules.credits($0.artist, release.artist.name)
        }
        return song.map { [$0] }
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
        let matched = await Self.match(releases, known: known, server: server)
        // A release whose songs were all on the server long before it came out is one the
        // listener already has under another date: nothing new, nothing missing.
        let heard = Set(matched.filter(\.value.isEmpty).keys)
        let inLibrary = matched.filter { !$0.value.isEmpty }
        let built = Radar(serverId: server.id, releases: releases.filter { !heard.contains($0.id) },
                          fetched: fetched, inLibrary: inLibrary, matched: Date())
        RadarStore.save(built)
        AppLogger.shared.log("📡 Radar: \(built.releases.count) releases, \(inLibrary.count) on the server, \(heard.count) already heard")
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
            inLibrary[release.id] = Array(RadarRules.newSongs(found, of: release).prefix(RadarRules.perRelease))
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
    /// v2: re-issues and songs already on the server no longer count as new, so a radar
    /// built before is rebuilt rather than kept for the day.
    private static func key(_ serverId: UUID) -> String { "radar_v2_\(serverId.uuidString)" }
    private static func formerKey(_ serverId: UUID) -> String { "radar_v1_\(serverId.uuidString)" }

    static func load(for serverId: UUID) -> Radar? {
        UserDefaults.standard.removeObject(forKey: formerKey(serverId))
        guard let data = UserDefaults.standard.data(forKey: key(serverId)) else { return nil }
        return try? JSONDecoder().decode(Radar.self, from: data)
    }

    static func save(_ radar: Radar) {
        guard let data = try? JSONEncoder().encode(radar) else { return }
        UserDefaults.standard.set(data, forKey: key(radar.serverId))
    }

    static func removeAll(for serverId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(serverId))
        UserDefaults.standard.removeObject(forKey: formerKey(serverId))
    }
}
