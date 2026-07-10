import Foundation

// MARK: - Normalized Last.fm models (only the fields we use)

struct LastfmTrack: Hashable { let name: String; let artist: String; let playcount: Int; let imageURL: String?; let durationSeconds: Int? }
struct LastfmArtist: Hashable { let name: String; let playcount: Int; let imageURL: String? }
struct LastfmAlbum: Hashable { let name: String; let artist: String; let playcount: Int; let imageURL: String? }
struct LastfmTag: Hashable { let name: String; let count: Int }

/// Everything needed to render a Wrapped from real Last.fm scrobble history.
struct LastfmWrapped {
    let topTracks: [LastfmTrack]
    let topArtists: [LastfmArtist]
    let topAlbums: [LastfmAlbum]
    let topTags: [LastfmTag]
    let allTimeScrobbles: Int?
    let scrobblingSinceYear: Int?
}

enum LastfmError: LocalizedError {
    case notConfigured
    case http(Int)
    case api(Int, String)
    case decode

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Last.fm username and API key in Settings."
        case .http(let c): return "Last.fm request failed (HTTP \(c))."
        case .api(_, let m): return m.isEmpty ? "Last.fm rejected the request." : m
        case .decode: return "Couldn't read the Last.fm response."
        }
    }
}

/// Read-only Last.fm API client. Uses the public `user.getTop*` / `user.getInfo`
/// methods (api_key + username only — no auth needed for public profile data).
final class LastfmService: @unchecked Sendable {
    static let shared = LastfmService()

    private let base = "https://ws.audioscrobbler.com/2.0/"
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private init() {}

    var isConfigured: Bool { AppSettings.shared.lastfmConfigured }

    /// Map a retrospective window to a Last.fm `period` value.
    static func period(for period: WrappedPeriod) -> String {
        switch period {
        case .year: return "12month"
        case .month: return "1month"
        }
    }

    // MARK: - Public: build a full Wrapped

    func fetchWrapped(period: WrappedPeriod, limit: Int = 200) async throws -> LastfmWrapped {
        guard isConfigured else { throw LastfmError.notConfigured }
        let p = Self.period(for: period)

        async let tracksT = topTracks(period: p, limit: limit)
        async let artistsT = topArtists(period: p, limit: limit)
        async let albumsT = topAlbums(period: p, limit: limit)
        let info = try? await userInfo()

        let tracks = try await tracksT
        let artists = try await artistsT
        let albums = try await albumsT
        // Genre breakdown derived from the top artists' tags (best-effort).
        let tags = await aggregateTags(from: Array(artists.prefix(6)))

        return LastfmWrapped(
            topTracks: tracks,
            topArtists: artists,
            topAlbums: albums,
            topTags: tags,
            allTimeScrobbles: info?.playcount,
            scrobblingSinceYear: info?.sinceYear
        )
    }

    // MARK: - Endpoints

    func topTracks(period: String, limit: Int) async throws -> [LastfmTrack] {
        let r: TopTracksResponse = try await get(method: "user.gettoptracks",
                                                 items: ["user": username, "period": period, "limit": "\(limit)"])
        return (r.toptracks?.track ?? []).map {
            LastfmTrack(name: $0.name, artist: $0.artist?.name ?? "Unknown Artist",
                        playcount: $0.playcount?.value ?? 0,
                        imageURL: bestImage($0.image),
                        durationSeconds: $0.duration?.value)
        }
    }

    func topArtists(period: String, limit: Int) async throws -> [LastfmArtist] {
        let r: TopArtistsResponse = try await get(method: "user.gettopartists",
                                                  items: ["user": username, "period": period, "limit": "\(limit)"])
        return (r.topartists?.artist ?? []).map {
            LastfmArtist(name: $0.name, playcount: $0.playcount?.value ?? 0, imageURL: bestImage($0.image))
        }
    }

    func topAlbums(period: String, limit: Int) async throws -> [LastfmAlbum] {
        let r: TopAlbumsResponse = try await get(method: "user.gettopalbums",
                                                 items: ["user": username, "period": period, "limit": "\(limit)"])
        return (r.topalbums?.album ?? []).map {
            LastfmAlbum(name: $0.name, artist: $0.artist?.name ?? "Unknown Artist",
                        playcount: $0.playcount?.value ?? 0, imageURL: bestImage($0.image))
        }
    }

    struct UserInfo { let playcount: Int?; let sinceYear: Int? }

    func userInfo() async throws -> UserInfo {
        let r: UserInfoResponse = try await get(method: "user.getinfo", items: ["user": username])
        let year: Int?
        if let unix = r.user?.registered?.unixtime?.value {
            year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(unix)))
        } else {
            year = nil
        }
        return UserInfo(playcount: r.user?.playcount?.value, sinceYear: year)
    }

    /// Aggregate genre tags across the given artists, weighted by play count.
    /// Lookups run serially with a small delay to stay under Last.fm's rate limit.
    private func aggregateTags(from artists: [LastfmArtist]) async -> [LastfmTag] {
        var perArtist: [[(String, Int)]] = []
        for (index, artist) in artists.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            guard let tags = try? await topTags(artist: artist.name) else { continue }
            // Top 3 tags for this artist, weighted by the artist's own play count.
            perArtist.append(tags.prefix(3).map { ($0.name.capitalized, max(1, artist.playcount)) })
        }
        var totals: [String: Int] = [:]
        var order: [String] = []
        for list in perArtist {
            for (name, weight) in list {
                if totals[name] == nil { order.append(name) }
                totals[name, default: 0] += weight
            }
        }
        return order
            .sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }
            .prefix(6)
            .map { LastfmTag(name: $0, count: totals[$0] ?? 0) }
    }

    private func topTags(artist: String) async throws -> [LastfmTag] {
        let r: TopTagsResponse = try await get(method: "artist.gettoptags",
                                               items: ["artist": artist, "autocorrect": "1"])
        return (r.toptags?.tag ?? []).map { LastfmTag(name: $0.name, count: $0.count?.value ?? 0) }
    }

    // MARK: - Networking

    private var username: String { AppSettings.shared.lastfmUsername.trimmingCharacters(in: .whitespaces) }

    private func get<T: Decodable>(method: String, items: [String: String]) async throws -> T {
        guard isConfigured, var comps = URLComponents(string: base) else { throw LastfmError.notConfigured }
        var q = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: AppSettings.shared.lastfmApiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        for (k, v) in items { q.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = q
        guard let url = comps.url else { throw LastfmError.notConfigured }

        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Last.fm returns its own error body even on non-2xx; surface it if present.
            if let apiErr = try? JSONDecoder().decode(APIErrorBody.self, from: data), let code = apiErr.error {
                throw LastfmError.api(code, apiErr.message ?? "")
            }
            throw LastfmError.http(http.statusCode)
        }
        if let apiErr = try? JSONDecoder().decode(APIErrorBody.self, from: data), let code = apiErr.error {
            throw LastfmError.api(code, apiErr.message ?? "")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LastfmError.decode }
    }

    private func bestImage(_ images: [Image]?) -> String? {
        guard let images else { return nil }
        let order = ["mega", "extralarge", "large", "medium", "small"]
        for size in order {
            if let match = images.first(where: { $0.size == size }), let t = match.text, !t.isEmpty {
                return t
            }
        }
        return images.last(where: { !($0.text ?? "").isEmpty })?.text
    }
}

// MARK: - Raw decodables

/// Accepts numbers that Last.fm sometimes returns as strings (playcount, etc.).
private struct LFInt: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i }
        else if let s = try? c.decode(String.self), let i = Int(s) { value = i }
        else { value = 0 }
    }
}

private struct Image: Decodable {
    let text: String?
    let size: String?
    enum CodingKeys: String, CodingKey { case text = "#text"; case size }
}

private struct NamedRef: Decodable { let name: String }

private struct APIErrorBody: Decodable { let error: Int?; let message: String? }

private struct TopTracksResponse: Decodable {
    struct Container: Decodable { let track: [Track]? }
    struct Track: Decodable {
        let name: String
        let playcount: LFInt?
        let duration: LFInt?
        let artist: NamedRef?
        let image: [Image]?
    }
    let toptracks: Container?
}

private struct TopArtistsResponse: Decodable {
    struct Container: Decodable { let artist: [Artist]? }
    struct Artist: Decodable {
        let name: String
        let playcount: LFInt?
        let image: [Image]?
    }
    let topartists: Container?
}

private struct TopAlbumsResponse: Decodable {
    struct Container: Decodable { let album: [Album]? }
    struct Album: Decodable {
        let name: String
        let playcount: LFInt?
        let artist: NamedRef?
        let image: [Image]?
    }
    let topalbums: Container?
}

private struct UserInfoResponse: Decodable {
    struct User: Decodable {
        let playcount: LFInt?
        let registered: Registered?
    }
    struct Registered: Decodable { let unixtime: LFInt? }
    let user: User?
}

private struct TopTagsResponse: Decodable {
    struct Container: Decodable { let tag: [Tag]? }
    struct Tag: Decodable { let name: String; let count: LFInt? }
    let toptags: Container?
}
