import Foundation

/// A retrospective window — a whole year or a single month.
enum WrappedPeriod: Hashable, Codable {
    case year(Int)
    case month(year: Int, month: Int)

    static var currentYear: WrappedPeriod {
        .year(Calendar.current.component(.year, from: Date()))
    }

    static var currentMonth: WrappedPeriod {
        let c = Calendar.current
        let now = Date()
        return .month(year: c.component(.year, from: now), month: c.component(.month, from: now))
    }

    /// Long, human title — "2026" or "June 2026".
    var title: String {
        switch self {
        case .year(let y):
            return String(y)
        case .month(let y, let m):
            let f = DateFormatter()
            // In the interface's language: "Your September 2026 Wrapped", not "Your septembre".
            f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            f.dateFormat = "LLLL yyyy"
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = 1
            if let date = Calendar.current.date(from: comps) { return f.string(from: date) }
            return "\(y)"
        }
    }

    /// Compact cover label — "2026" or "June".
    var coverLabel: String {
        switch self {
        case .year(let y): return String(y)
        case .month(let y, let m):
            let f = DateFormatter()
            f.dateFormat = "LLLL"
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = 1
            if let date = Calendar.current.date(from: comps) { return f.string(from: date) }
            return title
        }
    }

    /// Short label for the segmented period switcher.
    var pickerLabel: String {
        switch self {
        case .year: return "Year"
        case .month: return "Month"
        }
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.year, .month], from: date)
        switch self {
        case .year(let y):
            return comps.year == y
        case .month(let y, let m):
            return comps.year == y && comps.month == m
        }
    }
}

/// Controls which retrospectives ("Wrapped") are surfaced, and when.
///
/// Edit `offeredPeriods` to gate Wrapped behind specific windows later (e.g. the
/// year recap only in December, a month recap at month-end). For now the
/// `alwaysAvailable` override keeps both year and month visible year-round so the
/// feature can be used/tested in June.
enum WrappedAvailability {
    /// While true, retrospectives are always offered regardless of the date.
    /// False → the date-window logic below (Wrapped surfaces only around the end of
    /// each period). The Home card is additionally gated behind a user setting; the
    /// explicit Settings entry point ignores this and is always reachable.
    static let alwaysAvailable = false

    static func offeredPeriods(now: Date = Date()) -> [WrappedPeriod] {
        if alwaysAvailable { return [.currentYear, .currentMonth] }

        var out: [WrappedPeriod] = []
        let cal = Calendar.current
        let month = cal.component(.month, from: now)
        let day = cal.component(.day, from: now)
        let year = cal.component(.year, from: now)
        // Year in review: available in December, plus January for the year just ended.
        if month == 12 { out.append(.year(year)) }
        else if month == 1 { out.append(.year(year - 1)) }
        // Month in review: first week of the following month → the month just ended.
        if day <= 7, let prev = cal.date(byAdding: .month, value: -1, to: now) {
            out.append(.month(year: cal.component(.year, from: prev),
                              month: cal.component(.month, from: prev)))
        }
        return out
    }
}

/// Aggregated listening statistics for a period — the data behind a Wrapped screen.
struct ListeningStats: Codable {
    /// Where the numbers came from. `.lastfm` is real long-term scrobble history;
    /// `.device` is the app's local play log (accurate only since logging began).
    enum Source: String, Codable { case device, lastfm }

    struct RankedSong: Identifiable, Codable {
        let id: String            // stable list identity (device: server id; Last.fm: synthetic)
        let title: String
        let artist: String
        let coverArt: String?     // Subsonic cover id (device source / resolved)
        let imageURL: String?     // remote image (Last.fm source)
        let plays: Int
        var serverId: String? = nil  // resolved server song id → tap plays it
    }
    struct RankedArtist: Identifiable, Codable {
        var id: String { name }
        let name: String
        let plays: Int
        let minutes: Int
        let imageURL: String?
        var serverId: String? = nil       // resolved server artist id → tap opens it
        var serverCoverArt: String? = nil // resolved server cover (Last.fm drops artist images)
    }
    struct RankedAlbum: Identifiable, Codable {
        var id: String { "\(name)|\(artist)" }
        let name: String
        let artist: String
        let coverArt: String?
        let imageURL: String?
        let plays: Int
        var serverId: String? = nil       // resolved server album id → tap opens it
    }
    struct RankedGenre: Identifiable, Codable {
        var id: String { name }
        let name: String
        let plays: Int
    }

    let period: WrappedPeriod
    let source: Source
    let totalPlays: Int
    let totalMinutes: Int
    let uniqueSongs: Int
    let uniqueArtists: Int
    let topSongs: [RankedSong]
    let topArtists: [RankedArtist]
    let topAlbums: [RankedAlbum]
    let topGenres: [RankedGenre]
    /// Last.fm only — all-time scrobbles and the year the account started.
    let allTimeScrobbles: Int?
    let scrobblingSinceYear: Int?

    var hasData: Bool { totalPlays > 0 || !topArtists.isEmpty }
    var totalHours: Double { Double(totalMinutes) / 60.0 }

    /// A light-hearted "listener type" derived from the dominant genre's energy.
    var personality: String {
        guard let top = topGenres.first else { return "The Explorer" }
        let energy = Energy.score(genre: top.name)
        switch energy {
        case ..<0.3: return "The Calm Listener"
        case ..<0.55: return "The Easy Rider"
        case ..<0.75: return "The Groover"
        default: return "The Energizer"
        }
    }

    static func compute(from plays: [PlayHistory.PlayRecord], period: WrappedPeriod) -> ListeningStats {
        let scoped = plays.filter { period.contains($0.playedAt) }

        // Top songs by play count (representative metadata from the first occurrence).
        var songOrder: [String] = []
        var songCount: [String: Int] = [:]
        var songMeta: [String: PlayHistory.PlayRecord] = [:]
        for p in scoped {
            if songCount[p.songId] == nil { songOrder.append(p.songId); songMeta[p.songId] = p }
            songCount[p.songId, default: 0] += 1
        }
        let topSongs = songOrder
            .sorted { (songCount[$0] ?? 0) > (songCount[$1] ?? 0) }
            .prefix(50)
            .compactMap { id -> RankedSong? in
                guard let meta = songMeta[id] else { return nil }
                // Device play records already carry a real Subsonic song id → playable.
                return RankedSong(id: id, title: meta.title, artist: meta.artist,
                                  coverArt: meta.coverArt, imageURL: nil,
                                  plays: songCount[id] ?? 0, serverId: id)
            }

        // Top artists by play count, tie-broken by minutes.
        var artistOrder: [String] = []
        var artistPlays: [String: Int] = [:]
        var artistMinutes: [String: Int] = [:]
        for p in scoped {
            if artistPlays[p.artist] == nil { artistOrder.append(p.artist) }
            artistPlays[p.artist, default: 0] += 1
            artistMinutes[p.artist, default: 0] += p.durationSeconds
        }
        let topArtists = artistOrder
            .sorted {
                let a = artistPlays[$0] ?? 0, b = artistPlays[$1] ?? 0
                return a != b ? a > b : (artistMinutes[$0] ?? 0) > (artistMinutes[$1] ?? 0)
            }
            .prefix(10)
            .map { RankedArtist(name: $0, plays: artistPlays[$0] ?? 0,
                                minutes: (artistMinutes[$0] ?? 0) / 60, imageURL: nil) }

        // Top albums by play count (representative cover/artist from the first play).
        var albumOrder: [String] = []
        var albumCount: [String: Int] = [:]
        var albumMeta: [String: PlayHistory.PlayRecord] = [:]
        for p in scoped {
            guard let album = p.album, !album.isEmpty else { continue }
            let key = "\(album)|\(p.artist)"
            if albumCount[key] == nil { albumOrder.append(key); albumMeta[key] = p }
            albumCount[key, default: 0] += 1
        }
        let topAlbums = albumOrder
            .sorted { (albumCount[$0] ?? 0) > (albumCount[$1] ?? 0) }
            .prefix(10)
            .compactMap { key -> RankedAlbum? in
                guard let meta = albumMeta[key], let album = meta.album else { return nil }
                return RankedAlbum(name: album, artist: meta.artist, coverArt: meta.coverArt,
                                   imageURL: nil, plays: albumCount[key] ?? 0)
            }

        // Top genres by play count.
        var genreOrder: [String] = []
        var genreCount: [String: Int] = [:]
        for p in scoped {
            guard let g = p.genre, !g.isEmpty else { continue }
            if genreCount[g] == nil { genreOrder.append(g) }
            genreCount[g, default: 0] += 1
        }
        let topGenres = genreOrder
            .sorted { (genreCount[$0] ?? 0) > (genreCount[$1] ?? 0) }
            .prefix(6)
            .map { RankedGenre(name: $0, plays: genreCount[$0] ?? 0) }

        return ListeningStats(
            period: period,
            source: .device,
            totalPlays: scoped.count,
            totalMinutes: scoped.reduce(0) { $0 + $1.durationSeconds } / 60,
            uniqueSongs: Set(scoped.map(\.songId)).count,
            uniqueArtists: Set(scoped.map(\.artist)).count,
            topSongs: Array(topSongs),
            topArtists: Array(topArtists),
            topAlbums: Array(topAlbums),
            topGenres: Array(topGenres),
            allTimeScrobbles: nil,
            scrobblingSinceYear: nil
        )
    }

    /// Build stats from real Last.fm scrobble history.
    static func from(lastfm w: LastfmWrapped, period: WrappedPeriod) -> ListeningStats {
        let topSongs = w.topTracks.prefix(50).enumerated().map { idx, t in
            RankedSong(id: "\(t.artist)|\(t.name)|\(idx)", title: t.name, artist: t.artist,
                       coverArt: nil, imageURL: t.imageURL, plays: t.playcount)
        }
        let topArtists = w.topArtists.prefix(10).map {
            // Last.fm doesn't expose per-artist listening minutes; leave at 0.
            RankedArtist(name: $0.name, plays: $0.playcount, minutes: 0, imageURL: $0.imageURL)
        }
        let topAlbums = w.topAlbums.prefix(10).map {
            RankedAlbum(name: $0.name, artist: $0.artist, coverArt: nil,
                        imageURL: $0.imageURL, plays: $0.playcount)
        }
        let topGenres = w.topTags.prefix(6).map { RankedGenre(name: $0.name, plays: $0.count) }

        // Period total ≈ sum of the fetched top tracks' play counts (covers the bulk).
        let periodPlays = w.topTracks.reduce(0) { $0 + $1.playcount }
        // Listening-time estimate from tracks that report a duration.
        let estMinutes = w.topTracks.reduce(0) { acc, t in
            acc + (t.durationSeconds.map { $0 * t.playcount } ?? 0)
        } / 60

        return ListeningStats(
            period: period,
            source: .lastfm,
            totalPlays: periodPlays,
            totalMinutes: estMinutes,
            // True period-wide distinct counts (from @attr total), not the fetch cap.
            uniqueSongs: w.totalTrackCount ?? w.topTracks.count,
            uniqueArtists: w.totalArtistCount ?? w.topArtists.count,
            topSongs: Array(topSongs),
            topArtists: Array(topArtists),
            topAlbums: Array(topAlbums),
            topGenres: Array(topGenres),
            allTimeScrobbles: w.allTimeScrobbles,
            scrobblingSinceYear: w.scrobblingSinceYear
        )
    }

    /// A server entity resolved for one Wrapped row: its id, plus (optionally) a
    /// Subsonic cover-art id to display instead of Last.fm's star placeholder.
    struct Resolved { let serverId: String; let coverArt: String? }

    /// Return a copy with server-resolved ids/cover art merged into the top rows.
    /// Keyed by each ranked item's `id`. Unmatched rows keep their original values.
    func withResolved(songs: [String: Resolved] = [:],
                      albums: [String: Resolved] = [:],
                      artists: [String: Resolved] = [:]) -> ListeningStats {
        let newSongs = topSongs.map { s -> RankedSong in
            guard let r = songs[s.id] else { return s }
            return RankedSong(id: s.id, title: s.title, artist: s.artist,
                              coverArt: r.coverArt ?? s.coverArt, imageURL: s.imageURL,
                              plays: s.plays, serverId: r.serverId)
        }
        let newAlbums = topAlbums.map { a -> RankedAlbum in
            guard let r = albums[a.id] else { return a }
            return RankedAlbum(name: a.name, artist: a.artist,
                               coverArt: r.coverArt ?? a.coverArt, imageURL: a.imageURL,
                               plays: a.plays, serverId: r.serverId)
        }
        let newArtists = topArtists.map { ar -> RankedArtist in
            guard let r = artists[ar.id] else { return ar }
            return RankedArtist(name: ar.name, plays: ar.plays, minutes: ar.minutes,
                                imageURL: ar.imageURL, serverId: r.serverId,
                                serverCoverArt: r.coverArt)
        }
        return ListeningStats(period: period, source: source, totalPlays: totalPlays,
                              totalMinutes: totalMinutes, uniqueSongs: uniqueSongs,
                              uniqueArtists: uniqueArtists, topSongs: newSongs,
                              topArtists: newArtists, topAlbums: newAlbums, topGenres: topGenres,
                              allTimeScrobbles: allTimeScrobbles, scrobblingSinceYear: scrobblingSinceYear)
    }
}

// MARK: - Keeping a retrospective between visits

/// Remembers the last retrospective worked out for each period, so reopening Wrapped
/// shows it at once instead of computing and re-resolving from scratch.
///
/// A retrospective is expensive in a way its appearance hides: the Last.fm source is a
/// network fetch, and either source then resolves its top rows against the server for
/// real cover art. Doing all of that on every visit meant a spinner every time, for
/// numbers that had not meaningfully changed since the last look.
///
/// Kept per server as well as per period — two servers are two libraries and two sets of
/// listening, and the mixes learned that lesson already.
enum WrappedCache {
    private static func key(period: WrappedPeriod, source: ListeningStats.Source) -> String {
        let server = ServerManager.shared.currentServer?.id.uuidString ?? "none"
        return "musika_wrapped_v1_\(server)_\(source.rawValue)_\(period.title)"
    }

    static func load(period: WrappedPeriod, source: ListeningStats.Source) -> ListeningStats? {
        guard let data = UserDefaults.standard.data(forKey: key(period: period, source: source)) else { return nil }
        return try? JSONDecoder().decode(ListeningStats.self, from: data)
    }

    static func save(_ stats: ListeningStats) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        UserDefaults.standard.set(data, forKey: key(period: stats.period, source: stats.source))
    }
}

// MARK: - Retrospectives saved as playlists

/// Which saved playlists are retrospectives, so Aura can draw them with the same cover
/// the Wrapped screen used instead of a collage of whatever landed at track one.
///
/// Client-side, and it has to be: the Subsonic API has no way to set a playlist's
/// artwork. `updatePlaylist` carries a name, a comment and a visibility flag and nothing
/// else, and a server derives the picture from the songs. So the cover is remembered here
/// and drawn here — inside Aura it looks like the retrospective it is; in the web UI or
/// another client it stays whatever the server made of it.
enum WrappedCovers {
    private static let key = "musika_wrapped_playlist_covers_v1"

    private static var map: [String: WrappedPeriod] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
            return (try? JSONDecoder().decode([String: WrappedPeriod].self, from: data)) ?? [:]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func remember(playlistId: String, period: WrappedPeriod) {
        var current = map
        current[playlistId] = period
        map = current
    }

    static func period(for playlistId: String) -> WrappedPeriod? { map[playlistId] }
}
