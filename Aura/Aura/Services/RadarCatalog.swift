import Foundation

/// A release the radar found: out recently, by an artist in the library.
struct RadarRelease: Codable, Hashable, Identifiable {
    /// Deezer's album id.
    let id: String
    let title: String
    /// The artist as the library knows them, so the release can be matched and the cover can
    /// find their photo.
    let artist: ArtistRef
    /// `yyyy-MM-dd`, as Deezer gives it — sorts as text.
    let released: String
    /// Deezer's `record_type`: album, ep, single or compile.
    let type: String
    let cover: String?
    let link: String?

    var typeLabel: String {
        switch type {
        case "single": return String(localized: "Single")
        case "ep": return String(localized: "EP")
        case "compile": return String(localized: "Compilation")
        default: return String(localized: "Album")
        }
    }

    var releaseDate: Date? { RadarWindow.formatter.date(from: released) }
}

// MARK: - Pure rules

/// Which days count as "new".
enum RadarWindow {
    static let days = 30

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The first and last day of the window ending `now`, as Deezer writes dates. Tomorrow's
    /// pre-release stays out: the radar reports what can be listened to.
    static func range(now: Date = Date(), days: Int = days) -> ClosedRange<String> {
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) ?? now
        return formatter.string(from: start)...formatter.string(from: now)
    }
}

enum RadarRules {
    /// Artists followed, most-played first.
    static let artistLimit = 80
    /// Of which at least this many come from plays, whatever the favourites.
    static let playedFloor = 60
    /// Newest releases kept per artist, so a remix spree doesn't bury everyone else.
    static let perArtist = 3
    /// Tracks each release lends to the playlist.
    static let perRelease = 3

    /// The artists to follow: the most-played album artists, then favourites, then more of
    /// the most-played. Credits that run several artists together, and "Various Artists",
    /// are left out — each real artist has a row of their own.
    static func artists(frequent: [Album], starred: [Artist], limit: Int = artistLimit,
                        playedFloor: Int = playedFloor) -> [ArtistRef] {
        var plays: [String: Int] = [:]
        var names: [String: String] = [:]
        var order: [String] = []
        for album in frequent {
            guard let id = album.artistId, !id.isEmpty, let name = album.artist, isSingleArtist(name) else { continue }
            if plays[id] == nil { order.append(id) }
            plays[id, default: 0] += album.playCount ?? 0
            names[id] = name
        }
        let played = order.enumerated()
            .sorted { a, b in
                let (pa, pb) = (plays[a.element] ?? 0, plays[b.element] ?? 0)
                return pa != pb ? pa > pb : a.offset < b.offset
            }
            .map { ArtistRef(id: $0.element, name: names[$0.element] ?? "") }

        var picked = Array(played.prefix(playedFloor))
        var seen = Set(picked.map(\.id))
        for artist in starred where picked.count < limit && isSingleArtist(artist.name) {
            if seen.insert(artist.id).inserted { picked.append(ArtistRef(id: artist.id, name: artist.name)) }
        }
        for artist in played.dropFirst(playedFloor) where picked.count < limit {
            if seen.insert(artist.id).inserted { picked.append(artist) }
        }
        return picked
    }

    static func isSingleArtist(_ name: String) -> Bool {
        let folded = SongQuery.fold(name).trimmingCharacters(in: .whitespaces)
        guard !folded.isEmpty, !name.contains("•"), !name.contains(", ") else { return false }
        return !["various artists", "[unknown artist]", "unknown artist"].contains(folded)
    }

    /// An artist's releases inside the window, newest first, at most `perArtist`.
    static func fresh(_ albums: [DeezerAlbum], in window: ClosedRange<String>,
                      perArtist: Int = perArtist) -> [DeezerAlbum] {
        Array(albums
            .filter { $0.release_date.map(window.contains) ?? false }
            .sorted { ($0.release_date ?? "") > ($1.release_date ?? "") }
            .prefix(perArtist))
    }

    /// A title reduced to its words: case, accents, ligatures, punctuation and the store's
    /// " - Single" / " - EP" suffixes don't stop a release matching the album on the server.
    static func normalized(_ title: String) -> String {
        var s = SongQuery.fold(title).trimmingCharacters(in: .whitespaces)
        for suffix in [" - single", " - ep"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return SongQuery.plainWords(s)
    }

    static func sameTitle(_ a: String, _ b: String) -> Bool {
        let (na, nb) = (normalized(a), normalized(b))
        return !na.isEmpty && na == nb
    }

    /// Whether a credit names the artist — the whole credit, or one of the artists it runs
    /// together. Names are compared whole: "Air" is not in "Sinclair", nor in "Air Supply".
    static func credits(_ credit: String?, _ artist: String) -> Bool {
        let name = normalized(artist)
        guard let credit, !name.isEmpty else { return false }
        return SongQuery.creditedNames(credit).contains { normalized($0) == name }
    }

    /// Everything each release lends to the playlist, newest release first, no song twice.
    static func playlist(_ tracks: [(release: RadarRelease, songs: [Song])],
                         perRelease: Int = perRelease) -> [Song] {
        var seen = Set<String>()
        return tracks
            .sorted { $0.release.released > $1.release.released }
            .flatMap { $0.songs.prefix(perRelease) }
            .filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Deezer

struct DeezerAlbum: Decodable, Hashable {
    let id: Int
    let title: String
    let release_date: String?
    let record_type: String?
    let cover_medium: String?
    let link: String?
}

/// Deezer's public catalogue, for the artists' discographies. Keyless, and paced by
/// `DeezerPacer` with the covers' artist photos.
enum RadarCatalog {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private struct Search: Decodable {
        struct Hit: Decodable {
            let id: Int
            let name: String
            let nb_fan: Int?
        }
        let data: [Hit]?
    }

    private struct Albums: Decodable {
        let data: [DeezerAlbum]?
    }

    /// Answers kept between launches: a name either has a Deezer id or is known to have none.
    /// A failed call is never written here — it says nothing about the artist.
    private static let idsKey = "radar_deezer_artist_ids_v1"

    enum Lookup: Equatable {
        case found(String)
        case none
        case failed
    }

    static func artistId(for name: String) async -> Lookup {
        let key = SongQuery.fold(name).trimmingCharacters(in: .whitespaces)
        if let known = (UserDefaults.standard.dictionary(forKey: idsKey) as? [String: String])?[key] {
            return known.isEmpty ? .none : .found(known)
        }
        var components = URLComponents(string: "https://api.deezer.com/search/artist")
        components?.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "10")]
        guard let url = components?.url, let search: Search = await fetch(url),
              let hits = search.data else { return .failed }
        // Several artists can share a name; the one with the following is the one people mean.
        let id = hits.filter { SongQuery.fold($0.name) == SongQuery.fold(name) }
            .max { ($0.nb_fan ?? 0) < ($1.nb_fan ?? 0) }
            .map { String($0.id) }
        var ids = (UserDefaults.standard.dictionary(forKey: idsKey) as? [String: String]) ?? [:]
        ids[key] = id ?? ""
        UserDefaults.standard.set(ids, forKey: idsKey)
        return id.map(Lookup.found) ?? .none
    }

    /// The artist's whole discography. Deezer groups it by type rather than date, so there is
    /// no asking for "the latest" — the window is applied by the caller.
    static func albums(artistId: String) async -> [DeezerAlbum]? {
        guard let url = URL(string: "https://api.deezer.com/artist/\(artistId)/albums?limit=300"),
              let albums: Albums = await fetch(url) else { return nil }
        return albums.data
    }

    /// Over quota, Deezer answers 200 with an error object and no `data`; that gets one retry
    /// once the quota window has passed.
    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        for attempt in 0..<2 {
            await DeezerPacer.shared.wait()
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                if let decoded = try? JSONDecoder().decode(T.self, from: data), !isQuotaError(data) {
                    return decoded
                }
                guard attempt == 0, isQuotaError(data) else { return nil }
                try await Task.sleep(for: .seconds(5))
            } catch {
                AppLogger.shared.log("⚠️ Radar: Deezer call failed: \(error.localizedDescription)", level: .debug)
                return nil
            }
        }
        return nil
    }

    private static func isQuotaError(_ data: Data) -> Bool {
        struct Failure: Decodable { struct Body: Decodable { let code: Int? }; let error: Body? }
        return (try? JSONDecoder().decode(Failure.self, from: data))?.error?.code == 4
    }

}

/// Deezer allows 50 API calls per 5 seconds, per client. The radar and the covers' artist
/// photos both call it, so they queue here for one shared budget instead of each assuming
/// it has the whole of it.
actor DeezerPacer {
    static let shared = DeezerPacer()

    /// About 6 calls a second: two thirds of the quota, the rest left for bursts.
    private static let spacing: Duration = .milliseconds(150)
    private var next = ContinuousClock.now

    /// Returns when the caller's slot comes. Slots are handed out in order of asking.
    func wait() async {
        let now = ContinuousClock.now
        let slot = max(now, next)
        next = slot + Self.spacing
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}
