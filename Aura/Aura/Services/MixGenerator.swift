import Foundation
import CryptoKit

// MARK: - Mix model

/// What a mix is organised around — drives its templated cover art ("cover par
/// nature de contenu"). `nil`/`.generic` falls back to a song-cover collage.
enum MixKind: String, Codable {
    case timeOfDay      // Morning / Afternoon / Evening / Late Night
    case mood           // Chill / Focus / Feel Good / Energy
    case genre          // one mix per top genre
    case discovery      // fresh, unheard songs
    case retrospective  // month / year "wrapped"
    case radar          // new releases from the artists played most
    case generic
}

/// An auto-generated, savable playlist ("mix"). Built on-device by orchestrating
/// Subsonic similarity/genre/top-song endpoints around the user's listening seeds.
struct Mix: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let songs: [Song]
    /// Optional so older cached mixes (which lacked these) still decode.
    let kind: MixKind?
    /// Drives the cover template: a genre name, daypart, mood key, or period label.
    let templateSeed: String?
    /// Who the cover shows, when that isn't simply who plays most in `songs` — the radar's
    /// artists, some of whose releases aren't on the server yet.
    let coverArtists: [ArtistRef]?

    init(id: String, title: String, subtitle: String, songs: [Song],
         kind: MixKind? = nil, templateSeed: String? = nil, coverArtists: [ArtistRef]? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.songs = songs
        self.kind = kind
        self.templateSeed = templateSeed
        self.coverArtists = coverArtists
    }

    var coverArt: String? { songs.first?.coverArt }
    /// Up to four distinct cover art ids for a collage thumbnail.
    var collageCoverArts: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for song in songs {
            guard let art = song.coverArt, seen.insert(art).inserted else { continue }
            result.append(art)
            if result.count == 4 { break }
        }
        return result
    }

    /// Templated cover descriptor when this mix has a distinct "nature"; `nil`
    /// means fall back to the song-cover collage (discovery / generic mixes).
    var generatedCover: GeneratedCoverView.Nature? {
        switch kind ?? .generic {
        case .genre:          return templateSeed.map { .genre($0) }
        case .timeOfDay:      return templateSeed.map { .daypart($0) }
        case .mood:           return templateSeed.map { .mood($0) }
        case .retrospective:  return .retrospective(templateSeed ?? title)
        case .discovery, .radar, .generic: return nil
        }
    }
}

// MARK: - Per-server mix cache

/// Where generated mixes live between launches.
///
/// A mix is built entirely out of ONE server's library — its song ids, stream URLs and
/// cover art only resolve against the server they came from — so every entry is keyed by
/// server id, the same shape `AudioPlayer.lastPlaybackKey` and `HomeDataCache` already
/// use. Keying (rather than clearing on each switch) is what lets the app hold several
/// servers at once: switching away parks a server's mixes, switching back finds them.
struct MixCache {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// `v6` because the `v5` keys carried no server: whatever is cached under them was
    /// generated against a server nobody recorded and can't be attributed to one now, so
    /// they are dropped (see `pruneLegacyKeys`) and the mixes regenerate once.
    private func key(_ name: String, _ serverId: UUID?) -> String {
        "musika_auto_mixes_\(name)_v6_\(serverId?.uuidString ?? "none")"
    }

    func mixes(for serverId: UUID?) -> [Mix] {
        guard let data = defaults.data(forKey: key("contents", serverId)),
              let decoded = try? JSONDecoder().decode([Mix].self, from: data) else { return [] }
        return decoded
    }

    func save(_ mixes: [Mix], for serverId: UUID?, bucket: String, at date: Date = Date()) {
        if let data = try? JSONEncoder().encode(mixes) {
            defaults.set(data, forKey: key("contents", serverId))
        }
        defaults.set(date, forKey: key("date", serverId))
        defaults.set(bucket, forKey: key("bucket", serverId))
    }

    /// When this server last generated — `nil` means never, so it must generate now.
    func lastGenerated(for serverId: UUID?) -> Date? {
        defaults.object(forKey: key("date", serverId)) as? Date
    }

    /// The time-of-day bucket this server's mixes were built for.
    func bucket(for serverId: UUID?) -> String? {
        defaults.string(forKey: key("bucket", serverId))
    }

    /// Whether `serverId` needs its mixes rebuilt: it has never generated, its mixes are
    /// older than eight hours, the part of the day moved on, or the shelf is empty.
    ///
    /// Pure, and takes the server explicitly, because this is the gate the bug walked
    /// through: it used to read one global date and bucket, so a server that had just
    /// generated answered "still fresh" on behalf of every other server too.
    func needsRegeneration(for serverId: UUID?, hasMixes: Bool, bucket: String, now: Date = Date()) -> Bool {
        guard hasMixes,
              self.bucket(for: serverId) == bucket,
              let last = lastGenerated(for: serverId) else { return true }
        return now.timeIntervalSince(last) > 8 * 3600
    }

    // MARK: Saved-as-playlist signatures

    private func signatures(for serverId: UUID?) -> [String: String] {
        (defaults.dictionary(forKey: key("signatures", serverId)) as? [String: String]) ?? [:]
    }

    func savedSignature(mixId: String, for serverId: UUID?) -> String? {
        signatures(for: serverId)[mixId]
    }

    /// Scoped per server too: mix ids repeat across servers ("now", "chill", "genre_rock"),
    /// so one global dictionary let saving a mix on one server un-mark it on another.
    func setSavedSignature(_ signature: String, mixId: String, for serverId: UUID?) {
        var sigs = signatures(for: serverId)
        sigs[mixId] = signature
        defaults.set(sigs, forKey: key("signatures", serverId))
    }

    // MARK: Served

    /// The songs of the last two generations, so the next one reaches for others first.
    func served(for serverId: UUID?) -> Set<String> {
        let generations = defaults.array(forKey: key("served", serverId)) as? [[String]] ?? []
        return Set(generations.joined())
    }

    func recordServed(_ ids: [String], for serverId: UUID?) {
        let generations = defaults.array(forKey: key("served", serverId)) as? [[String]] ?? []
        defaults.set(Array((generations + [ids]).suffix(2)), forKey: key("served", serverId))
    }

    // MARK: Housekeeping

    /// Drop everything held for one server. Called when that server is removed, so its
    /// mixes don't outlive it — the same tidy-up `removeServer` already does for the
    /// server's Keychain password.
    func removeAll(for serverId: UUID?) {
        for name in ["contents", "date", "bucket", "signatures", "served"] {
            defaults.removeObject(forKey: key(name, serverId))
        }
    }

    /// Clear the pre-`v6` global keys. Nothing can read them any more — they held one
    /// server's mixes under no server at all — and a full shelf is a few hundred KB of
    /// JSON, so they're deleted once rather than left to sit in every user's defaults.
    func pruneLegacyKeys() {
        for key in ["musika_auto_mixes_v5", "musika_auto_mixes_date_v5",
                    "musika_auto_mixes_bucket_v5", "musika_saved_mix_signatures_v1"] {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Mix generator

@MainActor
@Observable
final class MixGenerator {
    static let shared = MixGenerator()

    private(set) var mixes: [Mix] = []
    var isGenerating = false
    /// When the mixes on screen were made — shown by Made For You, so a shelf that looks
    /// the same can be told apart from one that hasn't changed.
    private(set) var generatedAt: Date?

    private let cache: MixCache
    /// Which server the mixes currently in memory belong to. Tracked explicitly so any
    /// path into a refresh can notice the active server moved on, not just `selectServer`.
    private(set) var loadedServerId: UUID?

    private init() {
        cache = MixCache()
        cache.pruneLegacyKeys()
        restoreForServer(ServerManager.shared.currentServer?.id)
    }

    /// Test seam — an isolated defaults suite with no `ServerManager` involved.
    init(defaults: UserDefaults) {
        cache = MixCache(defaults: defaults)
    }

    /// Swap the in-memory mixes for the ones cached against `serverId`. Called on launch,
    /// by `ServerManager.selectServer` the moment the active server changes, and defensively
    /// from `generateIfNeeded()`. Mirrors `AudioPlayer.restoreForCurrentServer()`.
    ///
    /// Empty is the correct outcome for a server that has never generated: it drops the
    /// previous server's songs off screen straight away and makes `generateIfNeeded()`
    /// rebuild, instead of showing a library the app is no longer pointed at.
    func restoreForServer(_ serverId: UUID?) {
        loadedServerId = serverId
        mixes = cache.mixes(for: serverId)
        generatedAt = cache.lastGenerated(for: serverId)
    }

    // MARK: Time of day

    enum TimeBucket: String {
        case morning, afternoon, evening, night

        var title: String {
            switch self {
            case .morning: return "Morning Mix"
            case .afternoon: return "Afternoon Mix"
            case .evening: return "Evening Mix"
            case .night: return "Late Night Mix"
            }
        }

        var mood: String {
            switch self {
            case .morning: return "An easy start to your day"
            case .afternoon: return "Keep the momentum going"
            case .evening: return "Wind down your evening"
            case .night: return "Mellow songs for late hours"
            }
        }

        static var current: TimeBucket {
            switch Calendar.current.component(.hour, from: Date()) {
            case 5..<12: return .morning
            case 12..<17: return .afternoon
            case 17..<22: return .evening
            default: return .night
            }
        }

        /// Target energy band (0 = calm, 1 = high-energy) for this part of the day.
        var energyBand: ClosedRange<Double> {
            switch self {
            case .morning: return 0.30...0.70   // gentle but awake
            case .afternoon: return 0.55...1.0  // energetic
            case .evening: return 0.20...0.60   // winding down
            case .night: return 0.0...0.40      // mellow
            }
        }
    }

    // MARK: Moods

    /// Mood-based mixes (organised by feel, not by artist). Each defines an energy
    /// band and the genres used to seed the candidate pool.
    enum Mood: String, CaseIterable {
        case chill, focus
        case feelGood = "feel_good"
        case energy

        var title: String {
            switch self {
            case .chill: return "Chill Mix"
            case .focus: return "Focus Mix"
            case .feelGood: return "Feel Good Mix"
            case .energy: return "Energy Mix"
            }
        }

        var subtitle: String {
            switch self {
            case .chill: return "Calm, laid-back songs"
            case .focus: return "Steady songs to concentrate"
            case .feelGood: return "Upbeat songs to lift your mood"
            case .energy: return "High-energy songs to get moving"
            }
        }

        var band: ClosedRange<Double> {
            switch self {
            case .chill: return 0.0...0.35
            case .focus: return 0.15...0.45
            case .feelGood: return 0.45...0.72
            case .energy: return 0.70...1.0
            }
        }

        var genres: [String] {
            switch self {
            case .chill: return ["Acoustic", "Chill", "Ambient", "Jazz", "Lo-Fi", "Soul", "Folk"]
            case .focus: return ["Classical", "Ambient", "Piano", "Lo-Fi", "Electronic", "Instrumental"]
            case .feelGood: return ["Pop", "Indie", "Funk", "Disco", "Soul", "Reggae"]
            case .energy: return ["Dance", "House", "Hip-Hop", "Electro", "Rock", "Techno"]
            }
        }
    }

    // MARK: Public API

    /// Regenerate when there are no mixes, the cache is stale (>8h), or the
    /// time-of-day bucket changed (so the "Now" mix stays fresh). Cheap no-op otherwise.
    func generateIfNeeded() async {
        // Catch a server change that didn't come through `selectServer` — `removeServer`
        // also reassigns `currentServer`. Without this the freshness check below would be
        // asked about the wrong server and happily keep the old one's mixes on screen.
        let serverId = ServerManager.shared.currentServer?.id
        if serverId != loadedServerId { restoreForServer(serverId) }

        if cache.needsRegeneration(for: serverId, hasMixes: !mixes.isEmpty,
                                   bucket: TimeBucket.current.rawValue) {
            await generate()
        }
    }

    func generate() async {
        guard !isGenerating, let server = ServerManager.shared.currentServer else { return }
        isGenerating = true
        defer { isGenerating = false }
        AppLogger.shared.log("🎚 Generating auto-mixes…")

        // Seeds — recent plays + favourites.
        let recentIds = PlayHistory.shared.recentSongIds(limit: 40)
        let recentSongs = await resolveSongs(ids: recentIds, server: server)
        let starred = try? await SubsonicClient.shared.getStarred2(server: server)
        let starredSongs = starred?.song ?? []

        // Build ONE broad candidate pool from mood + favourite genres, favourites and
        // random, then carve out time/mood mixes by energy band. No artist-centred mixes —
        // mixes are organised purely by time of day and mood.
        let userGenres = topGenres(recentSongs + starredSongs, limit: 4)
        let genres = Array(Set(Mood.allCases.flatMap { $0.genres }).union(userGenres))
        let served = cache.served(for: server.id)
        let sizes = await genreSizes(server: server)
        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for genre in genres {
                let offset = Self.offset(in: sizes[genre.lowercased()], taking: 40)
                group.addTask { (try? await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre, count: 40, offset: offset)) ?? [] }
            }
            for await songs in group { pool += songs }
        }
        pool += starredSongs
        if let random = try? await SubsonicClient.shared.getRandomSongs(server: server, size: 100) {
            pool += random
        }
        pool = dedupe(pool)

        var built: [Mix] = []
        var used = Set<String>()   // keep mixes distinct — no song appears in two

        // 1. Time-of-day mix first (context for "right now").
        let bucket = TimeBucket.current
        let nowSongs = rested(pool.filter { !used.contains($0.id) }, served: served, limit: 50) {
            energyOrdered($0, band: bucket.energyBand, limit: $1)
        }
        if nowSongs.count >= 8 {
            built.append(Mix(id: "now", title: bucket.title, subtitle: bucket.mood, songs: nowSongs,
                             kind: .timeOfDay, templateSeed: bucket.rawValue))
            used.formUnion(nowSongs.map { $0.id })
        }

        // 2. Mood mixes.
        for mood in Mood.allCases {
            let songs = rested(pool.filter { !used.contains($0.id) }, served: served, limit: 50) {
                energyOrdered($0, band: mood.band, limit: $1)
            }
            guard songs.count >= 8 else { continue }
            built.append(Mix(id: mood.rawValue, title: mood.title, subtitle: mood.subtitle, songs: songs,
                             kind: .mood, templateSeed: mood.rawValue))
            used.formUnion(songs.map { $0.id })
        }

        // 3. Genre mixes — one per the user's top genres (organised by genre, not energy).
        built.append(contentsOf: await genreMixes(userGenres: userGenres, used: &used, served: served,
                                                  sizes: sizes, server: server))

        // 4. Discovery mix (separate source — songs you haven't heard).
        if let discover = await discoverMix(recentSongs: recentSongs, starredSongs: starredSongs, served: served,
                                            server: server) {
            built.append(discover)
        }

        // 5. Fallback for empty / brand-new libraries.
        if built.isEmpty, let fallback = await fallbackMix(server: server) {
            built.append(fallback)
        }

        // Generating takes many round-trips, and the user can switch servers while it runs.
        // The result belongs to the server it was built from, so file it there either way —
        // but only put it on screen if that server is still the active one.
        let now = Date()
        cache.save(built, for: server.id, bucket: bucket.rawValue, at: now)
        cache.recordServed(built.flatMap { $0.songs.map(\.id) }, for: server.id)
        AppLogger.shared.log("🎚 Auto-mixes ready: \(built.count) (\(built.map { $0.title }.joined(separator: ", ")))")
        guard ServerManager.shared.currentServer?.id == server.id else {
            AppLogger.shared.log("🎚 Server switched mid-generation — mixes cached, not shown")
            return
        }
        mixes = built
        loadedServerId = server.id
        generatedAt = now
    }

    /// What the last two generations didn't serve first, what they did only to fill up — so
    /// a mix changes from one generation to the next without running dry on a small library.
    private func rested(_ songs: [Song], served: Set<String>, limit: Int,
                        pick: ([Song], Int) -> [Song]) -> [Song] {
        let fresh = pick(songs.filter { !served.contains($0.id) }, limit)
        guard fresh.count < limit else { return fresh }
        let taken = Set(fresh.map(\.id))
        return fresh + pick(songs.filter { served.contains($0.id) && !taken.contains($0.id) }, limit - fresh.count)
    }

    /// Songs per genre, lowercased, to know how far into a genre a page can start.
    private func genreSizes(server: ServerConfig) async -> [String: Int] {
        let genres = (try? await SubsonicClient.shared.getGenres(server: server)) ?? []
        return Dictionary(genres.map { ($0.value.lowercased(), $0.songCount ?? 0) }, uniquingKeysWith: max)
    }

    /// Somewhere in the genre, not always at its start: the server lists a genre in the same
    /// order every time, so asking from the top gave each generation the same songs again.
    private static func offset(in total: Int?, taking count: Int) -> Int {
        guard let total, total > count else { return 0 }
        return Int.random(in: 0...(total - count))
    }

    // MARK: Mix builders

    /// Returns up to `limit` songs, preferring those whose energy falls inside `band`
    /// (shuffled), then back-filling with the nearest-to-band remainder.
    private func energyOrdered(_ songs: [Song], band: ClosedRange<Double>, limit: Int) -> [Song] {
        let center = (band.lowerBound + band.upperBound) / 2
        let inBand = songs.filter { band.contains(Energy.score($0)) }.shuffled()
        if inBand.count >= limit { return Array(inBand.prefix(limit)) }
        let rest = songs
            .filter { !band.contains(Energy.score($0)) }
            .sorted { abs(Energy.score($0) - center) < abs(Energy.score($1) - center) }
        return Array((inBand + rest).prefix(limit))
    }

    private func discoverMix(recentSongs: [Song], starredSongs: [Song], served: Set<String>,
                             server: ServerConfig) async -> Mix? {
        // Seed from recent plays first; fall back to favorites so discovery still
        // works on a fresh connect (before any local play history exists).
        var seeds = Array(recentSongs.prefix(5))
        if seeds.count < 5 {
            seeds += starredSongs.shuffled().prefix(5 - seeds.count)
        }
        guard !seeds.isEmpty else { return nil }
        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for song in seeds {
                group.addTask { (try? await SubsonicClient.shared.getSimilarSongs2(server: server, id: song.id, count: 30)) ?? [] }
            }
            for await songs in group { pool += songs }
        }
        // Exclude what the user already knows (recent + favorites) so it's genuinely new.
        let known = Set((recentSongs + starredSongs).map { $0.id })
        pool = dedupe(pool).filter { !known.contains($0.id) }.shuffled()
        guard pool.count >= 6 else { return nil }
        let subtitle = recentSongs.isEmpty ? "Fresh songs based on your favorites" : "Fresh songs based on your recent plays"
        return Mix(id: "discover", title: "New Discoveries", subtitle: subtitle,
                   songs: rested(pool, served: served, limit: 50) { Array($0.prefix($1)) }, kind: .discovery)
    }

    /// One mix per the user's top genres. Pulled directly from `getSongsByGenre`
    /// so each mix is genuinely that genre (not energy-bucketed). `used` keeps the
    /// genre mixes from overlapping with the time-of-day / mood mixes above.
    private func genreMixes(userGenres: [String], used: inout Set<String>, served: Set<String>,
                            sizes: [String: Int], server: ServerConfig) async -> [Mix] {
        guard !userGenres.isEmpty else { return [] }
        // Fetch all genre pools concurrently, preserving the top-genre order.
        let pools: [(genre: String, songs: [Song])] = await withTaskGroup(of: (Int, String, [Song]).self) { group in
            for (i, genre) in userGenres.enumerated() {
                let offset = Self.offset(in: sizes[genre.lowercased()], taking: 60)
                group.addTask {
                    let songs = (try? await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre, count: 60, offset: offset)) ?? []
                    return (i, genre, songs)
                }
            }
            var out: [(Int, String, [Song])] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }

        var mixes: [Mix] = []
        for (genre, songs) in pools {
            let final = rested(dedupe(songs).filter { !used.contains($0.id) }, served: served, limit: 50) {
                Array($0.shuffled().prefix($1))
            }
            guard final.count >= 8 else { continue }
            mixes.append(Mix(id: "genre_\(genre.lowercased())", title: "\(genre) Mix",
                             subtitle: "Your \(genre.lowercased()) favorites", songs: final,
                             kind: .genre, templateSeed: genre))
            used.formUnion(final.map { $0.id })
        }
        return mixes
    }

    private func fallbackMix(server: ServerConfig) async -> Mix? {
        guard let random = try? await SubsonicClient.shared.getRandomSongs(server: server, size: 50), random.count >= 8 else { return nil }
        return Mix(id: "fallback", title: "Your Mix", subtitle: "A fresh shuffle from your library", songs: random)
    }

    // MARK: Seed helpers

    private func topGenres(_ songs: [Song], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for song in songs {
            guard let genre = song.genre, !genre.isEmpty else { continue }
            if counts[genre] == nil { order.append(genre) }
            counts[genre, default: 0] += 1
        }
        return Array(order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }.prefix(limit))
    }

    private func resolveSongs(ids: [String], server: ServerConfig) async -> [Song] {
        await withTaskGroup(of: (Int, Song?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, try? await SubsonicClient.shared.getSong(server: server, id: id)) }
            }
            var pairs: [(Int, Song)] = []
            for await (index, song) in group {
                if let song { pairs.append((index, song)) }
            }
            return pairs.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private func dedupe(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    // MARK: Saved-as-playlist tracking

    /// Stable, launch-independent fingerprint of a mix's exact contents (ordered song ids).
    private func signature(for mix: Mix) -> String {
        let joined = mix.songs.map(\.id).joined(separator: ",")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// True only when *this exact version* of the mix was already saved. Once the mix
    /// is regenerated (different songs), its signature changes and this returns false
    /// again, so the refreshed version can be saved.
    func isSavedAsPlaylist(_ mix: Mix) -> Bool {
        cache.savedSignature(mixId: mix.id, for: loadedServerId) == signature(for: mix)
    }

    /// Record that the current version of this mix has been saved as a playlist.
    func markSavedAsPlaylist(_ mix: Mix) {
        cache.setSavedSignature(signature(for: mix), mixId: mix.id, for: loadedServerId)
    }
}

// MARK: - Energy heuristic

/// Estimates a song's perceived energy (0 = calm, 1 = high-energy) from the only
/// signals Subsonic exposes — genre and title — since it provides no acoustic
/// features (BPM / energy / valence). Intentionally simple and tunable; a real
/// mood source (e.g. Last.fm top-tags) can later override this.
enum Energy {
    /// Base energy per genre keyword (substring match, lowercased).
    private static let genreEnergy: [(keyword: String, value: Double)] = [
        // calm
        ("ambient", 0.10), ("classical", 0.15), ("acoustic", 0.20), ("folk", 0.25),
        ("singer-songwriter", 0.25), ("lo-fi", 0.20), ("lofi", 0.20), ("chill", 0.20),
        ("downtempo", 0.25), ("new age", 0.15), ("piano", 0.18), ("ballad", 0.20),
        ("jazz", 0.30), ("blues", 0.30), ("bossa", 0.25), ("soul", 0.35), ("gospel", 0.35),
        ("shoegaze", 0.35), ("slowcore", 0.20), ("r&b", 0.40), ("rnb", 0.40),
        // mid
        ("pop", 0.55), ("indie", 0.50), ("rock", 0.60), ("alternative", 0.55),
        ("country", 0.45), ("reggae", 0.45), ("funk", 0.60), ("disco", 0.65),
        ("soundtrack", 0.40), ("world", 0.45),
        // high
        ("edm", 0.85), ("house", 0.80), ("techno", 0.85), ("trance", 0.85),
        ("dance", 0.80), ("electro", 0.75), ("dubstep", 0.90), ("drum and bass", 0.90),
        ("dnb", 0.90), ("hip hop", 0.70), ("hip-hop", 0.70), ("rap", 0.70),
        ("trap", 0.75), ("hardstyle", 0.95), ("hardcore", 0.95), ("metal", 0.85),
        ("punk", 0.80), ("grime", 0.75), ("breakbeat", 0.80), ("garage", 0.75),
    ]

    private static let highEnergyTitleMarkers = ["remix", "club mix", "club edit", "extended", "vip mix", "bootleg", "rework", "(club", "mashup"]
    private static let lowEnergyTitleMarkers = ["acoustic", "live", "unplugged", "instrumental", "stripped", "piano version", "slowed", "lullaby", "demo", "reprise"]

    /// Genre-only energy estimate (0 = calm, 1 = high-energy), independent of a song.
    static func score(genre: String?) -> Double {
        guard let genre = genre?.lowercased(), !genre.isEmpty,
              let match = genreEnergy.first(where: { genre.contains($0.keyword) }) else { return 0.5 }
        return match.value
    }

    static func score(_ song: Song) -> Double {
        var value = 0.5 // neutral default for unknown genres
        if let genre = song.genre?.lowercased(), !genre.isEmpty {
            if let match = genreEnergy.first(where: { genre.contains($0.keyword) }) {
                value = match.value
            }
        }
        let title = song.title.lowercased()
        if highEnergyTitleMarkers.contains(where: { title.contains($0) }) { value += 0.20 }
        if lowEnergyTitleMarkers.contains(where: { title.contains($0) }) { value -= 0.25 }
        return min(1.0, max(0.0, value))
    }
}
