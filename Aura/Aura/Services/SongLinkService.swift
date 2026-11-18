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

    private let session: URLSession

    /// The session used in production. Kept as a factory so tests can build the
    /// service with a stubbed session and exercise the catalogue paths offline,
    /// while `shared` keeps exactly the behaviour it had.
    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    init(session: URLSession = SongLinkService.defaultSession()) {
        self.session = session
    }

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
                url: SongQuery.spotifySearchUrl(title: title, artist: artist),
                isSearch: true,
                appURL: SongQuery.spotifyAppSearchUrl(title: title, artist: artist)
            ),
            appleMusic: itunes.map { PlatformLink(url: $0.url, isSearch: false) },
            youtubeMusic: PlatformLink(url: SongQuery.youtubeMusicSearchUrl(title: title, artist: artist), isSearch: true),
            deezer: deezer.map { PlatformLink(url: $0.url, isSearch: false) },
            yandex: PlatformLink(url: SongQuery.yandexSearchUrl(title: title, artist: artist), isSearch: true)
        )
    }

    // MARK: - iTunes catalogue

    private func searchITunes(title: String, artist: String, country: String) async -> CatalogueMatch? {
        // Search with the LEAD artist + cleaned title — the full multi-artist credit
        // string ("A • B • C") rarely matches Apple's catalogue.
        let searchQuery = "\(SongQuery.primaryArtist(artist)) \(SongQuery.cleanTitle(title))"
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
            let target = SongQuery.cleanTitle(title)
            // A score of 0 means the title does not correspond at all. Without this
            // filter `max` still returns something, and the sheet presents it as a
            // resolved link — the exact "real but wrong" outcome we must avoid.
            let scored = decoded.results
                .filter { SongQuery.artistMatches($0.artistName, query: artist) }
                .map { (track: $0, score: SongQuery.titleScore($0.trackName, target: target)) }
                .filter { $0.score > 0 }
            let best = scored.max { a, b in
                // Ties are routine (a single and its album share a title) and
                // `max` keeps the first, i.e. whatever order the API replied in.
                a.score != b.score
                    ? a.score < b.score
                    : (!SongQuery.isExactArtist(a.track.artistName, query: artist)
                       && SongQuery.isExactArtist(b.track.artistName, query: artist))
            }

            guard let track = best?.track, let trackId = track.trackId, let viewUrl = track.trackViewUrl else {
                AppLogger.shared.log("SongLink: no iTunes match for '\(searchQuery)'")
                return nil
            }

            AppLogger.shared.log("SongLink: iTunes match '\(track.trackName ?? "?")' by \(track.artistName ?? "?") (id \(trackId))")
            return CatalogueMatch(url: SongQuery.cleanStoreUrl(viewUrl), trackId: trackId)
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
        let safeArtist = SongQuery.primaryArtist(artist).replacingOccurrences(of: "\"", with: "\\\"")
        let safeTitle = SongQuery.cleanTitle(title).replacingOccurrences(of: "\"", with: "\\\"")
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
            let target = SongQuery.cleanTitle(title)
            let scored = (decoded.data ?? [])
                .filter { SongQuery.artistMatches($0.artist?.name, query: artist) }
                .map { (track: $0, score: SongQuery.titleScore($0.title, target: target)) }
                .filter { $0.score > 0 }
            let best = scored.max { a, b in
                a.score != b.score
                    ? a.score < b.score
                    : (!SongQuery.isExactArtist(a.track.artist?.name, query: artist)
                       && SongQuery.isExactArtist(b.track.artist?.name, query: artist))
            }

            guard let track = best?.track, let link = track.link else {
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

// MARK: - A pasted link, back to a title and an artist

/// What a link from another service plays: a title and an artist to search for. Deezer and
/// Apple Music through their key-less lookups, YouTube through oEmbed, anything else
/// (Spotify, SoundCloud, song.link…) from the page's own og: tags.
enum PastedLink {
    struct Track: Equatable { let title: String; let artist: String }

    /// The link a whole query is, if it is one.
    static func url(in query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(" "), text.hasPrefix("http"),
              let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    static func identify(_ url: URL) async -> Track? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        // Short links (link.deezer.com, spotify.link…) land on the real page first.
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let final = response.url ?? url
        let host = final.host ?? ""
        if host.hasSuffix("deezer.com"), let id = id(after: "track", in: final) {
            return await json("https://api.deezer.com/track/\(id)") { obj in
                (obj["title"] as? String, (obj["artist"] as? [String: Any])?["name"] as? String)
            }
        }
        if host.hasSuffix("music.apple.com") {
            let comps = URLComponents(url: final, resolvingAgainstBaseURL: false)
            if let id = comps?.queryItems?.first(where: { $0.name == "i" })?.value ?? (final.path.contains("/song/") && Int(final.lastPathComponent) != nil ? final.lastPathComponent : nil) {
                return await json("https://itunes.apple.com/lookup?id=\(id)") { obj in
                    let first = (obj["results"] as? [[String: Any]])?.first
                    return (first?["trackName"] as? String, first?["artistName"] as? String)
                }
            }
        }
        if host.contains("youtube.com") || host.contains("youtu.be"),
           let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            return await json("https://www.youtube.com/oembed?format=json&url=\(encoded)") { obj in
                let artist = (obj["author_name"] as? String)?.replacingOccurrences(of: " - Topic", with: "") ?? ""
                var title = obj["title"] as? String ?? ""
                if title.hasPrefix(artist + " - ") { title.removeFirst(artist.count + 3) }
                // "(Official Video) [4K]" and the like are the video's, not the song's.
                title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
                return (title.trimmingCharacters(in: .whitespaces), artist)
            }
        }
        guard let html = String(data: data, encoding: .utf8),
              let title = meta("og:title", in: html), !title.isEmpty else { return nil }
        // Spotify: "Artist · Album · Song · 1987".
        let artist = meta("og:description", in: html)?.components(separatedBy: " · ").first ?? ""
        return Track(title: title, artist: artist.count < 80 ? artist : "")
    }

    /// The path component after `marker` ("/track/123" → "123").
    private static func id(after marker: String, in url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.lastIndex(of: marker), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    private static func json(_ address: String, _ read: ([String: Any]) -> (String?, String?)) async -> Track? {
        guard let url = URL(string: address),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let (title, artist) = read(obj)
        guard let title, !title.isEmpty else { return nil }
        return Track(title: title, artist: artist ?? "")
    }

    private static func meta(_ property: String, in html: String) -> String? {
        guard let start = html.range(of: "property=\"\(property)\" content=\""),
              let end = html[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(html[start.upperBound..<end])
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }
}
