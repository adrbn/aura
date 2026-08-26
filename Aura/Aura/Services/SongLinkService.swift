import Foundation

/// Resolves streaming-platform links for a song, with caching so the links are
/// ready by the time the user opens the share sheet.
///
/// This used to resolve every platform in one call through the odesli.co
/// (song.link) API. That API now rejects unauthenticated callers with
/// `401 PUBLIC_API_ACCESS_DEPRECATED`, so we resolve what we can from the free,
/// key-less search APIs instead:
///   - iTunes Search → a real Apple Music link, plus the track id
///   - Deezer Search → a real Deezer link, plus the track id
///   - song.link/i/<id> (or /d/<id>) → a real universal link, built from either id
///
/// Spotify, YouTube Music and Yandex have no key-less lookup, so they keep a
/// search-URL fallback — a search that lands on the right song beats a dead link.
@Observable
final class SongLinkService {
    static let shared = SongLinkService()

    /// A resolved destination. `isSearch` marks the key-less fallbacks (Spotify,
    /// YouTube Music, Yandex) so the share sheet can label them honestly instead of
    /// passing a search page off as a direct link.
    struct PlatformLink {
        let url: String
        let isSearch: Bool
        /// A platform-native URI that opens its app straight to this destination.
        /// Universal links to *search* pages are unreliable — Spotify's app swallows
        /// `open.spotify.com/search/…` and lands on "recent searches" instead of the
        /// query. `nil` when the plain URL already behaves.
        var appURL: String? = nil
    }

    struct SongLinks {
        /// song.link universal URL. `nil` when neither catalogue matched, so the
        /// share sheet shows "Not available" instead of a bare, useless domain.
        let pageUrl: String?
        let spotify: PlatformLink?
        let appleMusic: PlatformLink?
        let youtubeMusic: PlatformLink?
        let deezer: PlatformLink?
        let yandex: PlatformLink?
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Cache: songKey → SongLinks
    private(set) var cache: [String: SongLinks] = [:]
    private(set) var loadingKey: String?
    private var currentTask: Task<Void, Never>?

    // MARK: - API response shapes

    private struct ITunesSearchResponse: Decodable {
        let resultCount: Int
        let results: [ITunesTrack]
    }

    private struct ITunesTrack: Decodable {
        let trackId: Int?
        let trackViewUrl: String?
        let trackName: String?
        let artistName: String?
    }

    private struct DeezerSearchResponse: Decodable {
        let data: [DeezerTrack]?
    }

    private struct DeezerTrack: Decodable {
        let id: Int
        let title: String?
        let link: String?
        let artist: DeezerArtist?
    }

    private struct DeezerArtist: Decodable {
        let name: String?
    }

    /// A verified catalogue hit: the shareable URL plus the id used to build the
    /// song.link universal URL.
    private struct CatalogueMatch {
        let url: String
        let trackId: Int
    }

    // MARK: - Cache

    private func cacheKey(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }

    /// Pre-fetch links in the background. Call this when a song starts playing.
    func preloadLinks(title: String, artist: String) {
        let key = cacheKey(title: title, artist: artist)
        if cache[key] != nil || loadingKey == key { return }

        currentTask?.cancel()
        loadingKey = key
        currentTask = Task { [weak self] in
            let links = await self?.fetchLinksInternal(title: title, artist: artist)
            if !Task.isCancelled {
                await MainActor.run {
                    if let links {
                        self?.cache[key] = links
                    }
                    self?.loadingKey = nil
                }
            }
        }
    }

    /// Get cached links (instant) or fetch if not cached.
    func fetchLinks(title: String, artist: String) async -> SongLinks? {
        let key = cacheKey(title: title, artist: artist)
        if let cached = cache[key] { return cached }

        let links = await fetchLinksInternal(title: title, artist: artist)
        if let links {
            await MainActor.run { cache[key] = links }
        }
        return links
    }

    /// Clear old entries, keeping only the most recent.
    func trimCache(keeping title: String, artist: String) {
        let keepKey = cacheKey(title: title, artist: artist)
        if cache.count > 10 {
            let toRemove = cache.keys.filter { $0 != keepKey }.prefix(cache.count - 5)
            for k in toRemove { cache.removeValue(forKey: k) }
        }
    }

    // MARK: - Query normalization

    /// The primary artist for matching. Streaming search APIs match poorly on
    /// multi-artist credit strings ("Armand van Helden • KAREN HARDING", "A feat. B"),
    /// so we search with just the lead artist and verify the result.
    private func primaryArtist(_ artist: String) -> String {
        let separators = [" • ", " •", "• ", "•", " feat.", " feat ", " featuring",
                          " ft.", " ft ", " & ", ", ", " x ", " X ", " vs. ", " vs ",
                          " with ", " / ", "/", ";"]
        var result = artist
        for sep in separators {
            if let range = result.range(of: sep, options: [.caseInsensitive]) {
                result = String(result[..<range.lowerBound])
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? artist : trimmed
    }

    /// Strip "(feat. …)" / "(with …)" clutter that blocks exact matches, while keeping
    /// meaningful parentheticals (remix names, "(I Won't Let You Down)", etc.).
    private func cleanTitle(_ title: String) -> String {
        var t = title
        for p in ["\\s*\\(feat\\.?.*?\\)", "\\s*\\(ft\\.?.*?\\)",
                  "\\s*\\(featuring.*?\\)", "\\s*\\(with .*?\\)"] {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loose check that a search result actually corresponds to the song we asked for
    /// (so we never hand back a real-but-wrong link, which is worse than a search link).
    private func artistMatches(_ candidate: String?, query: String) -> Bool {
        guard let c = candidate?.lowercased() else { return false }
        let q = primaryArtist(query).lowercased()
        guard !q.isEmpty else { return false }
        return c.contains(q) || q.contains(c)
    }

    /// Rank a candidate track title against the target — exact match wins, then the
    /// shortest bracket-stripped match (so the ORIGINAL beats "[… Remix]"/"[Mixed]"
    /// variants, which often aren't on every platform).
    private func titleScore(_ trackName: String?, target: String) -> Int {
        guard let n = trackName?.lowercased() else { return 0 }
        if n == target { return 1000 }
        let stripped = n.replacingOccurrences(of: "\\s*\\[.*?\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if stripped == target { return 600 - n.count }
        if n.contains(target) || target.contains(n) { return 300 - n.count }
        return 0
    }

    // MARK: - Search-URL fallbacks

    /// De-bulleted free-text query for the search-URL fallbacks.
    private func fallbackQuery(title: String, artist: String) -> String {
        let cleanedArtist = artist
            .replacingOccurrences(of: "•", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        return "\(cleanedArtist) \(title)"
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Percent-encode free text for use in a path segment OR a query value.
    /// `.urlQueryAllowed` leaves `&`, `+` and `?` intact, which silently truncates
    /// the query for artists like "Simon & Garfunkel".
    private func encodeQuery(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func spotifySearchUrl(title: String, artist: String) -> String {
        "https://open.spotify.com/search/\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
    }

    private func youtubeMusicSearchUrl(title: String, artist: String) -> String {
        "https://music.youtube.com/search?q=\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
    }

    private func yandexSearchUrl(title: String, artist: String) -> String {
        "https://music.yandex.com/search?text=\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
    }

    // MARK: - Resolution

    private func fetchLinksInternal(title: String, artist: String) async -> SongLinks? {
        let country = Locale.current.region?.identifier ?? "US"

        // Both catalogue searches are independent and key-less — run them together.
        async let itunesSearch = searchITunes(title: title, artist: artist, country: country)
        async let deezerSearch = searchDeezer(title: title, artist: artist)
        let (itunes, deezer) = await (itunesSearch, deezerSearch)

        // The universal link is built from whichever track id we found; song.link's
        // own page then resolves the remaining platforms.
        let pageUrl: String?
        if let itunes {
            pageUrl = "https://song.link/i/\(itunes.trackId)"
        } else if let deezer {
            pageUrl = "https://song.link/d/\(deezer.trackId)"
        } else {
            pageUrl = nil
            AppLogger.shared.log("SongLink: no catalogue match for '\(title)' by '\(artist)' — search links only")
        }

        return SongLinks(
            pageUrl: pageUrl,
            spotify: PlatformLink(
                url: spotifySearchUrl(title: title, artist: artist),
                isSearch: true,
                appURL: "spotify:search:\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
            ),
            appleMusic: itunes.map { PlatformLink(url: $0.url, isSearch: false) },
            youtubeMusic: PlatformLink(url: youtubeMusicSearchUrl(title: title, artist: artist), isSearch: true),
            deezer: deezer.map { PlatformLink(url: $0.url, isSearch: false) },
            yandex: PlatformLink(url: yandexSearchUrl(title: title, artist: artist), isSearch: true)
        )
    }

    // MARK: - iTunes catalogue

    /// Strip Apple's `uo` analytics parameter so the shared link stays clean.
    private func cleanStoreUrl(_ url: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        let kept = (comps.queryItems ?? []).filter { $0.name != "uo" }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url?.absoluteString ?? url
    }

    private func searchITunes(title: String, artist: String, country: String) async -> CatalogueMatch? {
        // Search with the LEAD artist + cleaned title — the full multi-artist credit
        // string ("A • B • C") rarely matches Apple's catalogue.
        let searchQuery = "\(primaryArtist(artist)) \(cleanTitle(title))"
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: searchQuery),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                AppLogger.shared.log("SongLink: iTunes HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            // Only consider artist-matching results, then pick the closest title
            // (original over remix). An unverified first hit is worse than no link.
            let target = cleanTitle(title).lowercased()
            let candidates = decoded.results.filter { artistMatches($0.artistName, query: artist) }
            let best = candidates.max { titleScore($0.trackName, target: target) < titleScore($1.trackName, target: target) }

            guard let track = best, let trackId = track.trackId, let viewUrl = track.trackViewUrl else {
                AppLogger.shared.log("SongLink: no iTunes match for '\(searchQuery)'")
                return nil
            }

            AppLogger.shared.log("SongLink: iTunes match '\(track.trackName ?? "?")' by \(track.artistName ?? "?") (id \(trackId))")
            return CatalogueMatch(url: cleanStoreUrl(viewUrl), trackId: trackId)
        } catch {
            AppLogger.shared.log("SongLink: iTunes search failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Deezer catalogue

    private func searchDeezer(title: String, artist: String) async -> CatalogueMatch? {
        // Deezer's search API is free and key-less. Use the lead artist + cleaned
        // title so the structured query matches (a "A • B • C" string won't).
        // Escape double quotes so a name like 'AC"DC' can't break the query.
        let safeArtist = primaryArtist(artist).replacingOccurrences(of: "\"", with: "\\\"")
        let safeTitle = cleanTitle(title).replacingOccurrences(of: "\"", with: "\\\"")
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "artist:\"\(safeArtist)\" track:\"\(safeTitle)\""),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                AppLogger.shared.log("SongLink: Deezer HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            let decoded = try JSONDecoder().decode(DeezerSearchResponse.self, from: data)
            // Same verification as the iTunes path — the structured query can still
            // return a loose match, and a wrong link is worse than a search link.
            let target = cleanTitle(title).lowercased()
            let candidates = (decoded.data ?? []).filter { artistMatches($0.artist?.name, query: artist) }
            let best = candidates.max { titleScore($0.title, target: target) < titleScore($1.title, target: target) }

            guard let track = best, let link = track.link else {
                AppLogger.shared.log("SongLink: no Deezer match for '\(title)' by '\(artist)'")
                return nil
            }

            AppLogger.shared.log("SongLink: Deezer match '\(track.title ?? "?")' by \(track.artist?.name ?? "?") (id \(track.id))")
            return CatalogueMatch(url: link, trackId: track.id)
        } catch {
            AppLogger.shared.log("SongLink: Deezer search failed: \(error.localizedDescription)")
            return nil
        }
    }
}
