import Foundation

/// Fetches streaming platform links via the odesli.co (song.link) API
/// with built-in caching so links are ready when the user opens the share sheet.
@Observable
final class SongLinkService {
    static let shared = SongLinkService()

    struct SongLinks {
        let pageUrl: String // song.link universal URL
        let spotify: String?
        let appleMusic: String?
        let youtubeMusic: String?
        let deezer: String?
        let yandex: String?
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Cache: songKey → SongLinks (or nil if not found)
    private(set) var cache: [String: SongLinks] = [:]
    private(set) var loadingKey: String?
    private var currentTask: Task<Void, Never>?

    private struct OdesliResponse: Decodable {
        let pageUrl: String?
        let linksByPlatform: [String: PlatformLink]?

        struct PlatformLink: Decodable {
            let url: String?
        }
    }

    // iTunes Search API response
    private struct ITunesSearchResponse: Decodable {
        let resultCount: Int
        let results: [ITunesTrack]
    }

    private struct ITunesTrack: Decodable {
        let trackViewUrl: String?
        let trackName: String?
        let artistName: String?
    }

    // Deezer Search API response
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

    /// Build a cache key from title + artist
    private func cacheKey(title: String, artist: String) -> String {
        "\(title.lowercased())|\(artist.lowercased())"
    }

    /// Pre-fetch links for a song in the background. Call this when song starts playing.
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

    /// Get cached links (instant) or fetch if not cached
    func fetchLinks(title: String, artist: String) async -> SongLinks? {
        let key = cacheKey(title: title, artist: artist)
        if let cached = cache[key] { return cached }

        let links = await fetchLinksInternal(title: title, artist: artist)
        if let links {
            await MainActor.run { cache[key] = links }
        }
        return links
    }

    /// Clear old entries, keeping only the most recent
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

    // MARK: - Internal

    /// De-bulleted free-text query for the last-resort search-URL fallbacks.
    private func fallbackQuery(title: String, artist: String) -> String {
        let cleanedArtist = artist
            .replacingOccurrences(of: "•", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        return "\(cleanedArtist) \(title)"
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Build a Spotify search URL as last-resort fallback when Odesli has no direct match
    private func spotifySearchUrl(title: String, artist: String) -> String {
        let query = fallbackQuery(title: title, artist: artist)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "https://open.spotify.com/search/\(query)"
    }

    /// Build a YouTube Music search URL as fallback when Odesli has no direct match
    private func youtubeMusicSearchUrl(title: String, artist: String) -> String {
        let query = fallbackQuery(title: title, artist: artist)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "https://music.youtube.com/search?q=\(query)"
    }

    /// Fill in missing platform links with search URL fallbacks
    private func applyFallbacks(_ links: SongLinks, title: String, artist: String) -> SongLinks {
        SongLinks(
            pageUrl: links.pageUrl,
            spotify: links.spotify ?? spotifySearchUrl(title: title, artist: artist),
            appleMusic: links.appleMusic,
            youtubeMusic: links.youtubeMusic ?? youtubeMusicSearchUrl(title: title, artist: artist),
            deezer: links.deezer,
            yandex: links.yandex
        )
    }

    private func fetchLinksInternal(title: String, artist: String) async -> SongLinks? {
        let country = Locale.current.region?.identifier ?? "US"

        // Strategy: Try iTunes → odesli first.
        // If any major platform is missing, try Deezer search → odesli for better cross-platform matching.
        // Finally, inject search URL fallbacks for any still-missing platforms.

        // Step 1: Search iTunes to get a platform URL
        let itunesLinks = await fetchViaITunes(title: title, artist: artist, country: country)

        // If we got all major platforms from iTunes path, we're done
        if let links = itunesLinks, links.spotify != nil && links.youtubeMusic != nil {
            return applyFallbacks(links, title: title, artist: artist)
        }

        // Step 2: Try Deezer search → odesli for better cross-platform matching
        let missingPlatforms = [
            itunesLinks?.spotify == nil ? "Spotify" : nil,
            itunesLinks?.youtubeMusic == nil ? "YouTube Music" : nil
        ].compactMap { $0 }.joined(separator: ", ")
        AppLogger.shared.log("SongLink: \(missingPlatforms) missing from iTunes path, trying Deezer search...")

        if let deezerLinks = await fetchViaDeezer(title: title, artist: artist, country: country) {
            let merged = SongLinks(
                pageUrl: deezerLinks.pageUrl,
                spotify: deezerLinks.spotify ?? itunesLinks?.spotify,
                appleMusic: deezerLinks.appleMusic ?? itunesLinks?.appleMusic,
                youtubeMusic: deezerLinks.youtubeMusic ?? itunesLinks?.youtubeMusic,
                deezer: deezerLinks.deezer ?? itunesLinks?.deezer,
                yandex: deezerLinks.yandex ?? itunesLinks?.yandex
            )
            return applyFallbacks(merged, title: title, artist: artist)
        }

        // Step 3: Return iTunes results with fallbacks
        if let links = itunesLinks {
            return applyFallbacks(links, title: title, artist: artist)
        }

        // Nothing from any API — build minimal result with search fallbacks
        AppLogger.shared.log("SongLink: All APIs failed, using search URL fallbacks")
        return SongLinks(
            pageUrl: "https://song.link",
            spotify: spotifySearchUrl(title: title, artist: artist),
            appleMusic: nil,
            youtubeMusic: youtubeMusicSearchUrl(title: title, artist: artist),
            deezer: nil,
            yandex: nil
        )
    }

    // MARK: - iTunes → Odesli path

    private func fetchViaITunes(title: String, artist: String, country: String) async -> SongLinks? {
        // Search with the LEAD artist + cleaned title — the full multi-artist credit
        // string ("A • B • C") rarely matches Apple's catalogue.
        let searchQuery = "\(primaryArtist(artist)) \(cleanTitle(title))"
        var searchComponents = URLComponents(string: "https://itunes.apple.com/search")!
        searchComponents.queryItems = [
            URLQueryItem(name: "term", value: searchQuery),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let searchUrl = searchComponents.url else { return nil }

        AppLogger.shared.log("SongLink: Searching iTunes for '\(searchQuery)'")

        do {
            let (searchData, searchResponse) = try await session.data(from: searchUrl)
            guard let http = searchResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

            let searchResult = try JSONDecoder().decode(ITunesSearchResponse.self, from: searchData)
            // Among artist-matching results, pick the closest title (original over remix);
            // never blindly take the first hit (which is often a remix not on every platform).
            let target = cleanTitle(title).lowercased()
            let candidates = searchResult.results.filter { artistMatches($0.artistName, query: artist) }
            let match = candidates.max { titleScore($0.trackName, target: target) < titleScore($1.trackName, target: target) }
                ?? candidates.first
                ?? searchResult.results.first
            guard let track = match, let trackUrl = track.trackViewUrl else {
                AppLogger.shared.log("SongLink: No iTunes results for '\(searchQuery)'")
                return nil
            }

            AppLogger.shared.log("SongLink: Found iTunes match: \(track.trackName ?? "?") by \(track.artistName ?? "?")")
            return await queryOdesli(url: trackUrl, country: country)
        } catch {
            AppLogger.shared.log("SongLink: iTunes search failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Deezer → Odesli path

    private func fetchViaDeezer(title: String, artist: String, country: String) async -> SongLinks? {
        // Deezer search API is free, no auth required. Use the lead artist + cleaned
        // title so the structured query matches (a "A • B • C" artist string won't).
        // Escape double quotes so a name like 'AC"DC' can't break the structured query.
        let safeArtist = primaryArtist(artist).replacingOccurrences(of: "\"", with: "\\\"")
        let safeTitle = cleanTitle(title).replacingOccurrences(of: "\"", with: "\\\"")
        let query = "artist:\"\(safeArtist)\" track:\"\(safeTitle)\""
        var searchComponents = URLComponents(string: "https://api.deezer.com/search")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "3")
        ]
        guard let searchUrl = searchComponents.url else { return nil }

        AppLogger.shared.log("SongLink: Searching Deezer for '\(title)' by '\(artist)'")

        do {
            let (searchData, searchResponse) = try await session.data(from: searchUrl)
            guard let http = searchResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }

            let searchResult = try JSONDecoder().decode(DeezerSearchResponse.self, from: searchData)
            guard let firstTrack = searchResult.data?.first else {
                AppLogger.shared.log("SongLink: No Deezer results for '\(title)' by '\(artist)'")
                return nil
            }

            AppLogger.shared.log("SongLink: Found Deezer match: \(firstTrack.title ?? "?") by \(firstTrack.artist?.name ?? "?") (id: \(firstTrack.id))")

            // Query odesli with the Deezer track ID directly
            var components = URLComponents(string: "https://api.song.link/v1-alpha.1/links")!
            components.queryItems = [
                URLQueryItem(name: "platform", value: "deezer"),
                URLQueryItem(name: "type", value: "song"),
                URLQueryItem(name: "id", value: String(firstTrack.id)),
                URLQueryItem(name: "userCountry", value: country)
            ]
            guard let url = components.url else { return nil }

            let (data, response) = try await session.data(from: url)
            guard let odesliHttp = response as? HTTPURLResponse, (200...299).contains(odesliHttp.statusCode) else {
                AppLogger.shared.log("SongLink: Odesli via Deezer HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            let decoded = try JSONDecoder().decode(OdesliResponse.self, from: data)
            let pageUrl = decoded.pageUrl ?? "https://song.link"
            let links = decoded.linksByPlatform
            AppLogger.shared.log("SongLink (Deezer path): Spotify: \(links?["spotify"]?.url != nil), Apple Music: \(links?["appleMusic"]?.url != nil), YouTube Music: \(links?["youtubeMusic"]?.url != nil), Deezer: \(links?["deezer"]?.url != nil), Yandex: \(links?["yandex"]?.url != nil)")
            return SongLinks(
                pageUrl: pageUrl,
                spotify: links?["spotify"]?.url,
                appleMusic: links?["appleMusic"]?.url,
                youtubeMusic: links?["youtubeMusic"]?.url,
                deezer: links?["deezer"]?.url,
                yandex: links?["yandex"]?.url
            )
        } catch {
            AppLogger.shared.log("SongLink: Deezer search failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Odesli query by URL

    private func queryOdesli(url inputUrl: String, country: String) async -> SongLinks? {
        var components = URLComponents(string: "https://api.song.link/v1-alpha.1/links")!
        components.queryItems = [
            URLQueryItem(name: "url", value: inputUrl),
            URLQueryItem(name: "userCountry", value: country)
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let odesliHttp = response as? HTTPURLResponse, (200...299).contains(odesliHttp.statusCode) else {
                AppLogger.shared.log("SongLink API: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            let decoded = try JSONDecoder().decode(OdesliResponse.self, from: data)
            let pageUrl = decoded.pageUrl ?? "https://song.link"
            let links = decoded.linksByPlatform
            AppLogger.shared.log("SongLink (iTunes path): Spotify: \(links?["spotify"]?.url != nil), Apple Music: \(links?["appleMusic"]?.url != nil), YouTube Music: \(links?["youtubeMusic"]?.url != nil), Deezer: \(links?["deezer"]?.url != nil), Yandex: \(links?["yandex"]?.url != nil)")
            return SongLinks(
                pageUrl: pageUrl,
                spotify: links?["spotify"]?.url,
                appleMusic: links?["appleMusic"]?.url,
                youtubeMusic: links?["youtubeMusic"]?.url,
                deezer: links?["deezer"]?.url,
                yandex: links?["yandex"]?.url
            )
        } catch {
            AppLogger.shared.log("SongLink: Odesli query failed: \(error.localizedDescription)")
            return nil
        }
    }
}
