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

    init(id: String, title: String, subtitle: String, songs: [Song],
         kind: MixKind? = nil, templateSeed: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.songs = songs
        self.kind = kind
        self.templateSeed = templateSeed
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
        case .discovery, .generic: return nil
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

    private let cacheKey = "musika_auto_mixes_v5"
    private let cacheDateKey = "musika_auto_mixes_date_v5"
    private let cacheBucketKey = "musika_auto_mixes_bucket_v5"

    private init() { loadCache() }

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
        let last = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        let savedBucket = UserDefaults.standard.string(forKey: cacheBucketKey)
        let bucketChanged = savedBucket != TimeBucket.current.rawValue
        let stale = last == nil || Date().timeIntervalSince(last!) > 8 * 3600
        if mixes.isEmpty || stale || bucketChanged {
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
        var pool: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for genre in genres {
                group.addTask { (try? await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre, count: 40, offset: 0)) ?? [] }
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
        let nowSongs = energyOrdered(pool.filter { !used.contains($0.id) }, band: bucket.energyBand, limit: 50)
        if nowSongs.count >= 8 {
            built.append(Mix(id: "now", title: bucket.title, subtitle: bucket.mood, songs: nowSongs,
                             kind: .timeOfDay, templateSeed: bucket.rawValue))
            used.formUnion(nowSongs.map { $0.id })
        }

        // 2. Mood mixes.
        for mood in Mood.allCases {
            let songs = energyOrdered(pool.filter { !used.contains($0.id) }, band: mood.band, limit: 50)
            guard songs.count >= 8 else { continue }
            built.append(Mix(id: mood.rawValue, title: mood.title, subtitle: mood.subtitle, songs: songs,
                             kind: .mood, templateSeed: mood.rawValue))
            used.formUnion(songs.map { $0.id })
        }

        // 3. Genre mixes — one per the user's top genres (organised by genre, not energy).
        built.append(contentsOf: await genreMixes(userGenres: userGenres, used: &used, server: server))

        // 4. Discovery mix (separate source — songs you haven't heard).
        if let discover = await discoverMix(recentSongs: recentSongs, starredSongs: starredSongs, server: server) {
            built.append(discover)
        }

        // 5. Fallback for empty / brand-new libraries.
        if built.isEmpty, let fallback = await fallbackMix(server: server) {
            built.append(fallback)
        }

        mixes = built
        saveCache()
        AppLogger.shared.log("🎚 Auto-mixes ready: \(built.count) (\(built.map { $0.title }.joined(separator: ", ")))")
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

    private func discoverMix(recentSongs: [Song], starredSongs: [Song], server: ServerConfig) async -> Mix? {
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
                   songs: Array(pool.prefix(50)), kind: .discovery)
    }

    /// One mix per the user's top genres. Pulled directly from `getSongsByGenre`
    /// so each mix is genuinely that genre (not energy-bucketed). `used` keeps the
    /// genre mixes from overlapping with the time-of-day / mood mixes above.
    private func genreMixes(userGenres: [String], used: inout Set<String>, server: ServerConfig) async -> [Mix] {
        guard !userGenres.isEmpty else { return [] }
        // Fetch all genre pools concurrently, preserving the top-genre order.
        let pools: [(genre: String, songs: [Song])] = await withTaskGroup(of: (Int, String, [Song]).self) { group in
            for (i, genre) in userGenres.enumerated() {
                group.addTask {
                    let songs = (try? await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre, count: 60, offset: 0)) ?? []
                    return (i, genre, songs)
                }
            }
            var out: [(Int, String, [Song])] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }

        var mixes: [Mix] = []
        for (genre, songs) in pools {
            let picked = dedupe(songs).filter { !used.contains($0.id) }.shuffled()
            guard picked.count >= 8 else { continue }
            let final = Array(picked.prefix(50))
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

    // MARK: Persistence

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([Mix].self, from: data) else { return }
        mixes = decoded
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(mixes) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        UserDefaults.standard.set(TimeBucket.current.rawValue, forKey: cacheBucketKey)
    }

    // MARK: Saved-as-playlist tracking

    private let savedSignaturesKey = "musika_saved_mix_signatures_v1"

    /// Stable, launch-independent fingerprint of a mix's exact contents (ordered song ids).
    private func signature(for mix: Mix) -> String {
        let joined = mix.songs.map(\.id).joined(separator: ",")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func savedSignatures() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: savedSignaturesKey) as? [String: String]) ?? [:]
    }

    /// True only when *this exact version* of the mix was already saved. Once the mix
    /// is regenerated (different songs), its signature changes and this returns false
    /// again, so the refreshed version can be saved.
    func isSavedAsPlaylist(_ mix: Mix) -> Bool {
        savedSignatures()[mix.id] == signature(for: mix)
    }

    /// Record that the current version of this mix has been saved as a playlist.
    func markSavedAsPlaylist(_ mix: Mix) {
        var sigs = savedSignatures()
        sigs[mix.id] = signature(for: mix)
        UserDefaults.standard.set(sigs, forKey: savedSignaturesKey)
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
