import Foundation
import CryptoKit

actor SubsonicClient {
    static let shared = SubsonicClient()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 10
        self.session = URLSession(configuration: config)
    }

    /// Query-value character set: urlQueryAllowed minus characters that are
    /// structural in query strings ("&=+"), ambiguous ("@"), or refused outright:
    /// Navidrome (Go) fails a whole request whose query holds a bare ";", so a title
    /// like "You and I, Pt. II (Full Version; 2017 Remaster)" could never be searched.
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+@;")
        return set
    }()

    /// Shared Subsonic auth query string (salt + token). Nonisolated so URL
    /// helpers in ImageLoader can call it from nonisolated contexts.
    static func authQuery(for server: ServerConfig) -> String {
        let salt = UUID().uuidString.prefix(8).lowercased()
        let data = Data("\(server.password)\(salt)".utf8)
        let hash = Insecure.MD5.hash(data: data)
        let token = hash.map { String(format: "%02hhx", $0) }.joined()
        let user = server.username.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? server.username
        return "u=\(user)&t=\(token)&s=\(salt)&v=1.16.1&c=Aura&f=json"
    }

    private func buildURL(server: ServerConfig, endpoint: String, params: [String: String] = [:]) -> URL? {
        var urlString = "\(server.baseURL)/rest/\(endpoint)?\(Self.authQuery(for: server))"
        for (key, value) in params {
            urlString += "&\(key)=\(value.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? value)"
        }
        return URL(string: urlString)
    }

    /// `timeout` shortens the session's 30 s wait, for checks the app is waiting on.
    func ping(server: ServerConfig, timeout: TimeInterval? = nil) async throws -> Bool {
        guard let url = buildURL(server: server, endpoint: "ping") else {
            throw SubsonicClientError.invalidURL
        }
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(SubsonicResponse<EmptyContent>.self, from: data)
        return response.subsonicResponse.status == "ok"
    }

    func getAlbumList2(server: ServerConfig, type: String, size: Int = 20, offset: Int = 0, musicFolderId: Int? = nil) async throws -> [Album] {
        var params = ["type": type, "size": String(size), "offset": String(offset)]
        if let folderId = musicFolderId ?? AppSettings.shared.selectedMusicFolderId {
            params["musicFolderId"] = String(folderId)
        }
        guard let url = buildURL(server: server, endpoint: "getAlbumList2", params: params) else {
            throw SubsonicClientError.invalidURL
        }

        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "albumList2", as: AlbumList2.self)
        return wrapper.album ?? []
    }

    func getAlbum(server: ServerConfig, id: String) async throws -> AlbumWithSongs {
        guard let url = buildURL(server: server, endpoint: "getAlbum", params: ["id": id]) else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "album", as: AlbumWithSongs.self)
        return wrapper
    }

    func getArtists(server: ServerConfig, musicFolderId: Int? = nil) async throws -> [Artist] {
        var params: [String: String] = [:]
        if let folderId = musicFolderId ?? AppSettings.shared.selectedMusicFolderId {
            params["musicFolderId"] = String(folderId)
        }
        guard let url = buildURL(server: server, endpoint: "getArtists", params: params.isEmpty ? [:] : params) else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "artists", as: ArtistsContainer.self)
        return wrapper.index?.flatMap(\.artist) ?? []
    }

    func getArtist(server: ServerConfig, id: String) async throws -> ArtistWithAlbums {
        guard let url = buildURL(server: server, endpoint: "getArtist", params: ["id": id]) else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "artist", as: ArtistWithAlbums.self)
    }

    func getPlaylists(server: ServerConfig) async throws -> [Playlist] {
        guard let url = buildURL(server: server, endpoint: "getPlaylists") else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "playlists", as: PlaylistsContainer.self)
        return wrapper.playlist ?? []
    }

    func getPlaylist(server: ServerConfig, id: String) async throws -> PlaylistWithSongs {
        guard let url = buildURL(server: server, endpoint: "getPlaylist", params: ["id": id]) else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "playlist", as: PlaylistWithSongs.self)
    }

    @discardableResult
    func createPlaylist(server: ServerConfig, name: String, songIds: [String], playlistId: String? = nil) async throws -> Playlist {
        var params: [String: String] = [:]
        if let playlistId {
            params["playlistId"] = playlistId
        }
        params["name"] = name
        // Subsonic API expects multiple songId params
        guard var components = buildURL(server: server, endpoint: "createPlaylist", params: params).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw SubsonicClientError.invalidURL
        }
        var items = components.queryItems ?? []
        for id in songIds {
            items.append(URLQueryItem(name: "songId", value: id))
        }
        components.queryItems = items
        guard let url = components.url else { throw SubsonicClientError.invalidURL }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "playlist", as: Playlist.self)
    }

    func search3(server: ServerConfig, query: String, artistCount: Int = 5, albumCount: Int = 10, songCount: Int = 20, songOffset: Int = 0) async throws -> SearchResult3 {
        var params: [String: String] = [
            "query": query,
            "artistCount": String(artistCount),
            "albumCount": String(albumCount),
            "songCount": String(songCount)
        ]
        if songOffset > 0 { params["songOffset"] = String(songOffset) }
        guard let url = buildURL(server: server, endpoint: "search3", params: params) else { throw SubsonicClientError.invalidURL }

        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "searchResult3", as: SearchResult3.self)
    }

    func getRandomSongs(server: ServerConfig, size: Int = 20, musicFolderId: Int? = nil) async throws -> [Song] {
        var params = ["size": String(size)]
        if let folderId = musicFolderId ?? AppSettings.shared.selectedMusicFolderId {
            params["musicFolderId"] = String(folderId)
        }
        guard let url = buildURL(server: server, endpoint: "getRandomSongs", params: params) else {
            throw SubsonicClientError.invalidURL
        }

        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "randomSongs", as: RandomSongsContainer.self)
        return wrapper.song ?? []
    }

    func getStarred2(server: ServerConfig) async throws -> Starred2 {
        guard let url = buildURL(server: server, endpoint: "getStarred2") else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "starred2", as: Starred2.self)
    }

    func star(server: ServerConfig, id: String, type: StarType = .song) async throws {
        var params: [String: String] = [:]
        switch type {
        case .song: params["id"] = id
        case .album: params["albumId"] = id
        case .artist: params["artistId"] = id
        }
        guard let url = buildURL(server: server, endpoint: "star", params: params) else {
            throw SubsonicClientError.invalidURL
        }
        _ = try await fetchData(from: url)
    }

    func unstar(server: ServerConfig, id: String, type: StarType = .song) async throws {
        var params: [String: String] = [:]
        switch type {
        case .song: params["id"] = id
        case .album: params["albumId"] = id
        case .artist: params["artistId"] = id
        }
        guard let url = buildURL(server: server, endpoint: "unstar", params: params) else {
            throw SubsonicClientError.invalidURL
        }
        _ = try await fetchData(from: url)
    }

    /// Saves the queue on the server, so another client can pick it up where Aura left it.
    /// `position` is in milliseconds.
    func savePlayQueue(server: ServerConfig, ids: [String], current: String, position: Int) async throws {
        var urlString = "\(server.baseURL)/rest/savePlayQueue?\(Self.authQuery(for: server))"
        for id in ids {
            urlString += "&id=\(id.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? id)"
        }
        urlString += "&current=\(current.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? current)&position=\(position)"
        guard let url = URL(string: urlString) else { throw SubsonicClientError.invalidURL }
        _ = try await fetchData(from: url)
    }

    /// `rating` is 1–5, or 0 to clear it.
    func setRating(server: ServerConfig, id: String, rating: Int) async throws {
        guard let url = buildURL(server: server, endpoint: "setRating",
                                 params: ["id": id, "rating": String(rating)]) else {
            throw SubsonicClientError.invalidURL
        }
        _ = try await fetchData(from: url)
    }

    func scrobble(server: ServerConfig, id: String) async throws {
        guard let url = buildURL(server: server, endpoint: "scrobble", params: ["id": id]) else {
            throw SubsonicClientError.invalidURL
        }
        _ = try await fetchData(from: url)
    }

    func getTopSongs(server: ServerConfig, artistName: String, count: Int = 50) async throws -> [Song] {
        guard let url = buildURL(server: server, endpoint: "getTopSongs", params: [
            "artist": artistName, "count": String(count)
        ]) else { throw SubsonicClientError.invalidURL }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "topSongs", as: TopSongsContainer.self)
        return wrapper.song ?? []
    }

    func getSimilarSongs2(server: ServerConfig, id: String, count: Int = 20) async throws -> [Song] {
        guard let url = buildURL(server: server, endpoint: "getSimilarSongs2", params: [
            "id": id, "count": String(count)
        ]) else { throw SubsonicClientError.invalidURL }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "similarSongs2", as: SimilarSongsContainer.self)
        return wrapper.song ?? []
    }

    func getArtistInfo2(server: ServerConfig, id: String, count: Int = 15, includeNotPresent: Bool = false) async throws -> ArtistInfo2Container {
        guard let url = buildURL(server: server, endpoint: "getArtistInfo2", params: [
            "id": id, "count": String(count),
            "includeNotPresent": includeNotPresent ? "true" : "false"
        ]) else { throw SubsonicClientError.invalidURL }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "artistInfo2", as: ArtistInfo2Container.self)
    }

    func getGenres(server: ServerConfig) async throws -> [GenreEntry] {
        guard let url = buildURL(server: server, endpoint: "getGenres") else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "genres", as: GenresContainer.self)
        return wrapper.genre ?? []
    }

    func getSongsByGenre(server: ServerConfig, genre: String, count: Int = 20, offset: Int = 0) async throws -> [Song] {
        guard let url = buildURL(server: server, endpoint: "getSongsByGenre", params: [
            "genre": genre, "count": String(count), "offset": String(offset)
        ]) else { throw SubsonicClientError.invalidURL }
        let data = try await fetchData(from: url)
        struct Container: Decodable { let song: [Song]? }
        let wrapper = try decodeSubsonic(data: data, key: "songsByGenre", as: Container.self)
        return wrapper.song ?? []
    }

    func getLyrics(server: ServerConfig, artist: String, title: String) async throws -> String {
        guard let url = buildURL(server: server, endpoint: "getLyrics", params: [
            "artist": artist, "title": title
        ]) else { throw SubsonicClientError.invalidURL }
        let data = try await fetchData(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["subsonic-response"] as? [String: Any] else {
            AppLogger.shared.log("[Lyrics] getLyrics: invalid response structure")
            return ""
        }
        // Check for API error
        if let error = body["error"] as? [String: Any], let msg = error["message"] as? String {
            AppLogger.shared.log("[Lyrics] getLyrics API error: \(msg)")
            return ""
        }
        guard let lyrics = body["lyrics"] as? [String: Any],
              let value = lyrics["value"] as? String else {
            AppLogger.shared.log("[Lyrics] getLyrics: no lyrics value in response")
            return ""
        }
        return value
    }

    /// `enhanced=true` asks for OpenSubsonic `songLyrics` **v2**: word/syllable cues and
    /// vocal agents alongside the plain lines. Servers that only implement v1 ignore the
    /// parameter and answer exactly as before, so this is safe to send unconditionally.
    func getLyricsBySongId(server: ServerConfig, id: String) async throws -> [StructuredLyrics] {
        guard let url = buildURL(server: server, endpoint: "getLyricsBySongId", params: [
            "id": id,
            "enhanced": "true"
        ]) else { throw SubsonicClientError.invalidURL }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "lyricsList", as: LyricsListContainer.self)
        return wrapper.structuredLyrics ?? []
    }

    func getSong(server: ServerConfig, id: String) async throws -> Song {
        guard let url = buildURL(server: server, endpoint: "getSong", params: ["id": id]) else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "song", as: Song.self)
    }

    // MARK: - Scan & Stats

    func getScanStatus(server: ServerConfig) async throws -> ScanStatus {
        guard let url = buildURL(server: server, endpoint: "getScanStatus") else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "scanStatus", as: ScanStatus.self)
    }

    func startScan(server: ServerConfig) async throws -> ScanStatus {
        guard let url = buildURL(server: server, endpoint: "startScan") else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        return try decodeSubsonic(data: data, key: "scanStatus", as: ScanStatus.self)
    }

    /// Cached album count to avoid paginating all albums on every Home load.
    /// Persisted to UserDefaults so it survives app relaunches.
    private var _cachedAlbumCount: Int?
    private var _albumCountDate: Date?

    private func loadPersistedAlbumCount(server: ServerConfig) -> (Int, Date)? {
        let folderId = AppSettings.shared.selectedMusicFolderId ?? -1
        let key = "albumCount_\(server.id)_\(folderId)"
        let count = UserDefaults.standard.integer(forKey: key)
        let ts = UserDefaults.standard.double(forKey: key + "_ts")
        guard count > 0, ts > 0 else { return nil }
        return (count, Date(timeIntervalSince1970: ts))
    }

    private func persistAlbumCount(_ count: Int, server: ServerConfig) {
        let folderId = AppSettings.shared.selectedMusicFolderId ?? -1
        let key = "albumCount_\(server.id)_\(folderId)"
        UserDefaults.standard.set(count, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key + "_ts")
    }

    func getAlbumCount(server: ServerConfig) async throws -> Int {
        // Return in-memory cache if recent
        if let cached = _cachedAlbumCount, let d = _albumCountDate,
           Date().timeIntervalSince(d) < 3600 {
            return cached
        }
        // Fall back to persisted cache (survives app restart, 6hr TTL)
        if let (count, date) = loadPersistedAlbumCount(server: server),
           Date().timeIntervalSince(date) < 21600 {
            _cachedAlbumCount = count
            _albumCountDate = date
            return count
        }
        // Binary search: find the highest offset that still returns data.
        // Each call fetches size=1, so bandwidth is minimal.
        var low = 0
        var high = 200_000
        // Quick sanity probe at 100
        let probe = try await getAlbumList2(server: server, type: "alphabeticalByName", size: 1, offset: 100)
        if probe.isEmpty {
            // Fewer than 100 albums — just count directly
            let all = try await getAlbumList2(server: server, type: "alphabeticalByName", size: 500, offset: 0)
            _cachedAlbumCount = all.count
            _albumCountDate = Date()
            persistAlbumCount(all.count, server: server)
            return all.count
        }
        // Binary search with ~17 iterations max (log2(200000))
        while high - low > 1 {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            let check = try await getAlbumList2(server: server, type: "alphabeticalByName", size: 1, offset: mid)
            if check.isEmpty {
                high = mid
            } else {
                low = mid
            }
        }
        // low is the last offset that returned data → count = low + 1
        let total = low + 1
        _cachedAlbumCount = total
        _albumCountDate = Date()
        persistAlbumCount(total, server: server)
        return total
    }

    /// Navidrome native full scan (POST /api/scan?full=true)
    func startFullScan(server: ServerConfig) async throws {
        guard let url = URL(string: "\(server.baseURL)/rest/startScan?\(Self.authQuery(for: server))") else {
            throw SubsonicClientError.invalidURL
        }
        _ = try await fetchData(from: url)
    }

    func getMusicFolders(server: ServerConfig) async throws -> [MusicFolder] {
        guard let url = buildURL(server: server, endpoint: "getMusicFolders") else {
            throw SubsonicClientError.invalidURL
        }
        let data = try await fetchData(from: url)
        let wrapper = try decodeSubsonic(data: data, key: "musicFolders", as: MusicFoldersContainer.self)
        return wrapper.musicFolder ?? []
    }

    func updatePlaylist(server: ServerConfig, id: String, name: String? = nil, comment: String? = nil, isPublic: Bool? = nil) async throws {
        var params: [String: String] = ["playlistId": id]
        if let n = name { params["name"] = n }
        if let c = comment { params["comment"] = c }
        if let p = isPublic { params["public"] = p ? "true" : "false" }
        guard let url = buildURL(server: server, endpoint: "updatePlaylist", params: params) else {
            throw SubsonicClientError.invalidURL
        }
        _ = try await fetchData(from: url)
    }

    func addSongToPlaylist(server: ServerConfig, playlistId: String, songId: String) async throws {
        guard var components = buildURL(server: server, endpoint: "updatePlaylist", params: ["playlistId": playlistId])
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw SubsonicClientError.invalidURL
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "songIdToAdd", value: songId))
        components.queryItems = items
        guard let url = components.url else { throw SubsonicClientError.invalidURL }
        _ = try await fetchData(from: url)
    }

    func removeSongFromPlaylist(server: ServerConfig, playlistId: String, songIndex: Int) async throws {
        guard var components = buildURL(server: server, endpoint: "updatePlaylist", params: ["playlistId": playlistId])
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw SubsonicClientError.invalidURL
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "songIndexToRemove", value: String(songIndex)))
        components.queryItems = items
        guard let url = components.url else { throw SubsonicClientError.invalidURL }
        _ = try await fetchData(from: url)
    }

    func deletePlaylist(server: ServerConfig, id: String) async throws {
        guard let url = buildURL(server: server, endpoint: "deletePlaylist", params: ["id": id]) else {
            throw SubsonicClientError.invalidURL
        }
        _ = try await fetchData(from: url)
    }

    // MARK: - Helpers

    private func fetchData(from url: URL) async throws -> Data {
        let endpoint = url.path.components(separatedBy: "/rest/").last?.components(separatedBy: "?").first ?? url.path
        AppLogger.shared.log("🌐 API → \(endpoint)")
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.shared.log("❌ API \(endpoint) HTTP \(code)")
                throw SubsonicClientError.serverError
            }
            AppLogger.shared.log("✅ API \(endpoint) → \(data.count) bytes")
            return data
        } catch let error as SubsonicClientError {
            throw error
        } catch {
            AppLogger.shared.log("❌ API \(endpoint) error: \(error.localizedDescription)")
            throw error
        }
    }

    private func decodeSubsonic<T: Decodable>(data: Data, key: String, as type: T.Type) throws -> T {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseBody = json["subsonic-response"] as? [String: Any] else {
            AppLogger.shared.log("❌ Decode \(key): invalid response structure")
            throw SubsonicClientError.decodingError
        }

        if let error = responseBody["error"] as? [String: Any],
           let message = error["message"] as? String {
            AppLogger.shared.log("❌ API error for \(key): \(message)")
            throw SubsonicClientError.apiError(message)
        }

        guard let content = responseBody[key] else {
            AppLogger.shared.log("❌ Decode \(key): key not found in response")
            throw SubsonicClientError.decodingError
        }

        let contentData = try JSONSerialization.data(withJSONObject: content)
        return try JSONDecoder().decode(T.self, from: contentData)
    }
}

enum StarType {
    case song, album, artist
}

enum SubsonicClientError: LocalizedError {
    case invalidURL
    case serverError
    case decodingError
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .serverError: return "Server returned an error"
        case .decodingError: return "Failed to decode response"
        case .apiError(let msg): return msg
        }
    }
}

struct EmptyContent: Decodable {}

// MARK: - Media URLs

/// The URLs for a song's audio and a cover's image. They lived at the bottom of
/// `ImageLoader.swift`, which is why looking for where a stream URL is built led to the
/// image cache; they are API calls, and belong with the rest of the client.
extension SubsonicClient {
    nonisolated func coverArtURL(server: ServerConfig, id: String, size: Int = 300) -> URL? {
        // A song from outside the server — a release's preview — names its cover by address.
        if id.hasPrefix("https://") { return URL(string: id) }
        let urlString = "\(server.baseURL)/rest/getCoverArt?\(SubsonicClient.authQuery(for: server))&id=\(id)&size=\(size)"
        return URL(string: urlString)
    }

    nonisolated func streamURL(server: ServerConfig, id: String, maxBitRate: Int? = nil, songSuffix: String? = nil, songContentType: String? = nil) -> URL? {
        var urlString = "\(server.baseURL)/rest/stream?\(SubsonicClient.authQuery(for: server))&id=\(id)"

        let suffix = songSuffix?.lowercased() ?? ""
        let contentType = songContentType?.lowercased() ?? ""
        let quality = AppSettings.shared.effectiveStreamingQuality

        let lossySuffixes: Set<String> = ["mp3", "m4a", "aac", "mp4", "m4b", "opus", "ogg"]
        let lossyContentTypes = ["audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/opus", "audio/ogg"]

        var isLossy = false
        if !suffix.isEmpty {
            isLossy = lossySuffixes.contains(suffix)
        } else if !contentType.isEmpty {
            isLossy = lossyContentTypes.contains { contentType.contains($0) }
        }

        AppLogger.shared.log("🎚 streamURL id=\(id) suffix=\(suffix.isEmpty ? "n/a" : suffix) isLossy=\(isLossy) quality=\(quality.rawValue)")

        if isLossy {
            // Opus/OGG are lossy but iOS can't play them — must transcode
            let unsupportedLossySuffixes: Set<String> = ["ogg", "opus"]
            if unsupportedLossySuffixes.contains(suffix) {
                let br = quality.bitRate ?? 320
                urlString += "&format=mp3&maxBitRate=\(br)"
            }
            // Other lossy formats (mp3, m4a, aac) — never downsample
        } else {
            // Lossless file (FLAC, ALAC, etc.)
            if quality == .lossless {
                // Stream original — format=raw avoids server's default OGG transcoding
                urlString += "&format=raw"
            } else {
                // Transcode to MP3 at the selected quality
                let br = quality.bitRate ?? 320
                urlString += "&format=mp3&maxBitRate=\(br)"
            }
        }

        return URL(string: urlString)
    }

    nonisolated func downloadURL(server: ServerConfig, id: String) -> URL? {
        let urlString = "\(server.baseURL)/rest/download?\(SubsonicClient.authQuery(for: server))&id=\(id)"
        return URL(string: urlString)
    }
}
