import Foundation

/// The result of a library search, independent of any view state.
struct SearchResults: Equatable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []
    var playlists: [Playlist] = []
    var suggestedCorrection: String?
    /// True when these results came from the local offline index (downloads + cache)
    /// because the server couldn't be reached.
    var isOffline: Bool = false

    var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && songs.isEmpty && playlists.isEmpty
    }
}

/// Shared search engine: holds the prefetched library index (playlists, artists,
/// playlist→song maps) built once, and performs ranked fuzzy search. Used by every
/// search entry point (Search tab, Home) so behaviour is identical everywhere.
@MainActor
@Observable
final class SearchIndex {
    static let shared = SearchIndex()

    private var cachedAllPlaylists: [Playlist]?
    private var cachedAllArtists: [Artist]?
    /// lowercase song title → playlist ids containing it
    private var playlistSongIndex: [String: Set<String>] = [:]
    /// song id → playlist ids containing it
    private var playlistSongIdIndex: [String: Set<String>] = [:]
    private var didPrefetch = false
    private var prefetchTask: Task<Void, Never>?

    private init() {}

    // MARK: Prefetch

    /// Fetch playlists + artists once for fuzzy matching, and build the playlist→song
    /// index in the background. Safe to call from multiple entry points; runs once.
    func prefetchIfNeeded() {
        guard !didPrefetch, prefetchTask == nil else { return }
        prefetchTask = Task { await prefetch() }
    }

    private func prefetch() async {
        defer { prefetchTask = nil }
        guard let server = ServerManager.shared.currentServer else { return }
        async let pls = try? SubsonicClient.shared.getPlaylists(server: server)
        async let arts = try? SubsonicClient.shared.getArtists(server: server)
        let (fetchedPls, fetchedArts) = await (pls, arts)
        cachedAllPlaylists = fetchedPls
        cachedAllArtists = fetchedArts
        didPrefetch = true

        guard let allPlaylists = fetchedPls, !allPlaylists.isEmpty else { return }
        // Build the "playlists containing this song" index off the main actor.
        let built: ([String: Set<String>], [String: Set<String>]) = await Task.detached(priority: .utility) {
            var titleIndex: [String: Set<String>] = [:]
            var idIndex: [String: Set<String>] = [:]
            await withTaskGroup(of: (String, [Song])?.self) { group in
                for playlist in allPlaylists {
                    group.addTask {
                        guard let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id) else { return nil }
                        return (playlist.id, detail.entry ?? [])
                    }
                }
                for await result in group {
                    guard let (playlistId, songs) = result else { continue }
                    for song in songs {
                        titleIndex[song.title.lowercased(), default: []].insert(playlistId)
                        idIndex[song.id, default: []].insert(playlistId)
                    }
                }
            }
            return (titleIndex, idIndex)
        }.value
        playlistSongIndex = built.0
        playlistSongIdIndex = built.1
    }

    // MARK: Search

    func search(query: String) async -> SearchResults {
        guard let server = ServerManager.shared.currentServer else { return SearchResults() }
        do {
            let result = try await SubsonicClient.shared.search3(server: server, query: query, songCount: 30)
            try Task.checkCancellation()

            let allPls = cachedAllPlaylists ?? []
            let libraryArtists = cachedAllArtists ?? []
            var matchingPlaylists = Fuzzy.matchPlaylists(allPls, query: query)

            // Playlists that *contain* a matching song (via the prebuilt index).
            let foundSongs = result.song ?? []
            if !foundSongs.isEmpty {
                let alreadyMatched = Set(matchingPlaylists.map { $0.id })
                var additional = Set<String>()
                for song in foundSongs {
                    if let ids = playlistSongIdIndex[song.id] { additional.formUnion(ids) }
                    if let ids = playlistSongIndex[song.title.lowercased()] { additional.formUnion(ids) }
                }
                additional.subtract(alreadyMatched)
                let playlistMap = Dictionary(uniqueKeysWithValues: allPls.map { ($0.id, $0) })
                for plId in additional {
                    if let pl = playlistMap[plId] { matchingPlaylists.append(pl) }
                }
            }

            var finalSongs = result.song ?? []
            var finalAlbums = result.album ?? []
            var finalArtists = result.artist ?? []

            // Fuzzy-match artists from the full library to catch typos.
            let fuzzyArtists = Fuzzy.matchArtists(libraryArtists, query: query)
            let existingArtistIds = Set(finalArtists.map { $0.id })
            let newFuzzyArtists = fuzzyArtists.filter { !existingArtistIds.contains($0.id) }
            finalArtists.append(contentsOf: newFuzzyArtists)

            if !newFuzzyArtists.isEmpty {
                try Task.checkCancellation()
                let existingSongIds = Set(finalSongs.map { $0.id })
                let existingAlbumIds = Set(finalAlbums.map { $0.id })
                for artist in newFuzzyArtists.prefix(3) {
                    try Task.checkCancellation()
                    if let corrected = try? await SubsonicClient.shared.search3(
                        server: server, query: artist.name, artistCount: 0, albumCount: 5, songCount: 10
                    ) {
                        for song in corrected.song ?? [] where !existingSongIds.contains(song.id) {
                            finalSongs.append(song)
                        }
                        for album in corrected.album ?? [] where !existingAlbumIds.contains(album.id) {
                            finalAlbums.append(album)
                        }
                    }
                }
            }

            try Task.checkCancellation()

            let fuzzyAlbums = Fuzzy.matchAlbums(finalAlbums, query: query)
            let suggestion = Fuzzy.bestMatch(query: query, candidates: libraryArtists.map { $0.name })

            // If an artist name matches >90%, focus songs on that artist.
            let filteredSongs: [Song]
            if let matchedArtist = Self.principalArtist(for: query, among: finalArtists) {
                let artistName = matchedArtist.name.lowercased()
                let artistSongs = finalSongs.filter {
                    ($0.artist ?? "").lowercased().contains(artistName) ||
                    artistName.contains(($0.artist ?? "").lowercased())
                }
                filteredSongs = artistSongs.isEmpty ? finalSongs : artistSongs
            } else {
                filteredSongs = finalSongs
            }

            let ranker = SearchRanking.shared
            let sortedAlbums = fuzzyAlbums.isEmpty ? finalAlbums : fuzzyAlbums
            return SearchResults(
                artists: ranker.ranked(collapseCollaborationArtists(finalArtists), query: query) { $0.id },
                albums: ranker.ranked(sortedAlbums, query: query) { $0.id },
                songs: ranker.ranked(filteredSongs, query: query) { $0.id },
                playlists: ranker.ranked(matchingPlaylists, query: query) { $0.id },
                suggestedCorrection: suggestion
            )
        } catch is CancellationError {
            return SearchResults()
        } catch {
            // Offline fallback: search downloaded + cached songs locally.
            return await searchOffline(query: query)
        }
    }

    /// The artist a query is actually about.
    ///
    /// `Fuzzy.score` returns 1.0 for any name that merely *contains* the query, so on a
    /// server that lists every credit as its own artist — "Avicii", "Avicii, CAZZETTE",
    /// "Avicii, Nicky Romero" — all of them tie at a perfect score. Taking the *first* of
    /// those meant whichever the server happened to return first won, and the song list
    /// was then narrowed to that one collaboration: searching "Avicii" returned nothing
    /// but "Avicii, someone else".
    ///
    /// An exact name wins outright; failing that the shortest, which is the standalone
    /// credit rather than a collaboration built on top of it. Narrowing to "Avicii" still
    /// keeps the collaborations, because their credit strings contain it.
    nonisolated static func principalArtist(for query: String, among artists: [Artist]) -> Artist? {
        // Trimmed once, and used for the scoring too: `Fuzzy.score` asks whether the name
        // *contains* the query, and a query carrying the spaces a keyboard left on it is
        // contained by nothing at all.
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let candidates = artists.filter { Fuzzy.score(query: q, target: $0.name) >= 0.9 }
        if let exact = candidates.first(where: { $0.name.lowercased() == q }) { return exact }
        return candidates.min { $0.name.count < $1.name.count }
    }

    /// Collapse collaboration-string artists into the standalone artist.
    /// Servers like Navidrome expose each multi-artist credit as its own "artist"
    /// (e.g. "Avicii", "Avicii, CAZZETTE", "Avicii, Nicky Romero"…). When the
    /// standalone artist is already present, drop the comma-joined variants so the
    /// results aren't cluttered with near-duplicate rows.
    private func collapseCollaborationArtists(_ artists: [Artist]) -> [Artist] {
        let standalone = Set(artists
            .filter { !$0.name.contains(",") }
            .map { $0.name.lowercased() })
        return artists.filter { artist in
            guard artist.name.contains(",") else { return true }
            let primary = artist.name
                .split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            return !standalone.contains(primary)
        }
    }

    func searchOffline(query: String) async -> SearchResults {
        let q = query.lowercased()
        let downloaded = DownloadManager.shared.downloadedSongs.map(\.song)
        let cached = AudioCacheManager.shared.getCachedSongs()
        var seen = Set<String>()
        var allOffline: [Song] = []
        for song in downloaded + cached where seen.insert(song.id).inserted {
            allOffline.append(song)
        }
        let matchingSongs = allOffline.filter {
            $0.title.lowercased().contains(q) ||
            ($0.artist ?? "").lowercased().contains(q) ||
            ($0.album ?? "").lowercased().contains(q)
        }
        var albumSet = Set<String>(); var matchingAlbums: [Album] = []
        var artistSet = Set<String>(); var matchingArtists: [Artist] = []
        for song in matchingSongs {
            if let albumId = song.albumId, let albumName = song.album, albumSet.insert(albumId).inserted {
                matchingAlbums.append(Album(id: albumId, name: albumName, artist: song.artist, artistId: song.artistId,
                                            coverArt: song.coverArt, songCount: nil, duration: nil, year: song.year,
                                            genre: song.genre, starred: nil, created: nil, playCount: nil))
            }
            if let artistId = song.artistId, let artistName = song.artist, artistSet.insert(artistId).inserted {
                matchingArtists.append(Artist(id: artistId, name: artistName, coverArt: nil, albumCount: nil, starred: nil, artistImageUrl: nil, playCount: nil))
            }
        }
        return SearchResults(artists: matchingArtists, albums: matchingAlbums, songs: matchingSongs, playlists: [], suggestedCorrection: nil, isOffline: true)
    }

    /// Search lrclib.net for lyrics matches and resolve them to library songs.
}

// MARK: - Fuzzy matching

/// Pure fuzzy-matching helpers shared across search (Levenshtein-based).
enum Fuzzy {
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased()); let b = Array(b.lowercased())
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }

    static func score(query: String, target: String) -> Double {
        let q = query.lowercased(); let t = target.lowercased()
        if t.contains(q) { return 1.0 }
        let words = t.split(separator: " ").map(String.init)
        for word in words where word.hasPrefix(q) { return 0.9 }
        let dist = levenshtein(q, t)
        let maxLen = max(q.count, t.count)
        guard maxLen > 0 else { return 0 }
        let similarity = 1.0 - (Double(dist) / Double(maxLen))
        let wordDistances = words.map { levenshtein(q, $0) }
        let bestWordDist = wordDistances.min() ?? dist
        let bestWordLen = max(q.count, words.min(by: { $0.count < $1.count })?.count ?? q.count)
        let wordSimilarity = bestWordLen > 0 ? 1.0 - (Double(bestWordDist) / Double(bestWordLen)) : 0
        return max(similarity, wordSimilarity)
    }

    static func matchPlaylists(_ all: [Playlist], query: String) -> [Playlist] {
        all.map { ($0, score(query: query, target: $0.name)) }
            .filter { $0.1 >= 0.4 }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    static func matchArtists(_ all: [Artist], query: String) -> [Artist] {
        all.map { ($0, score(query: query, target: $0.name)) }
            .filter { $0.1 >= 0.7 }.sorted { $0.1 > $1.1 }.prefix(5).map { $0.0 }
    }

    static func matchAlbums(_ albums: [Album], query: String) -> [Album] {
        var combined: [(Album, Double)] = []
        for album in albums {
            let best = max(score(query: query, target: album.name), score(query: query, target: album.artist ?? ""))
            combined.append((album, best))
        }
        return combined.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    static func bestMatch(query: String, candidates: [String]) -> String? {
        let q = query.lowercased()
        var best: String?; var bestDistance = Int.max
        for candidate in candidates {
            let c = candidate.lowercased()
            if c == q { return nil }
            let dist = levenshtein(q, c)
            let threshold = max(1, q.count / 3)
            if dist <= threshold && dist < bestDistance { bestDistance = dist; best = candidate }
        }
        return best
    }
}
