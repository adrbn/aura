import Foundation

/// The real cover of an album the server has none for.
///
/// Files that arrive without artwork — a download whose picture sat beside it in a folder,
/// a rip that never had one — leave their album bare, and the server fills the gap with a
/// generic picture of its own. Rather than show that, or Aura's drawn stand-in, the album is
/// looked up in Deezer's public catalogue by its artist and title, and the catalogue's
/// cover is shown in its place. Only an album the server has no picture for is ever looked
/// up, and each once: what was found — or that nothing was — is kept, and a miss is asked
/// again after a week, in case the catalogue has it by then.
///
/// Nothing is written back to the server: the day the files get artwork of their own, the
/// cover's id changes with the album, and the server's picture takes over.
actor CoverFinder {
    static let shared = CoverFinder()

    private struct Entry: Codable {
        /// The catalogue's largest cover, or nil when nothing matched.
        let url: String?
        let checked: Date
    }

    private var entries: [String: Entry]
    private var searches: [String: Task<String?, Never>] = [:]

    private static let retryAfter: TimeInterval = 7 * 24 * 3600
    private static let file: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("found_covers_v1.json")

    private init() {
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: Self.file))) ?? [:]
    }

    /// Where the cover for `coverArt` can be downloaded, at about `pixels` wide.
    func coverURL(for coverArt: String, server: ServerConfig, pixels: Int) async -> URL? {
        guard let largest = await largestCover(for: coverArt, server: server) else { return nil }
        // The catalogue keeps each cover at fixed sizes, named in the address; the smaller
        // one is plenty for a list row.
        let address = pixels <= 500 ? largest.replacingOccurrences(of: "1000x1000", with: "500x500") : largest
        return URL(string: address)
    }

    private func largestCover(for coverArt: String, server: ServerConfig) async -> String? {
        if let entry = entries[coverArt],
           entry.url != nil || Date().timeIntervalSince(entry.checked) < Self.retryAfter {
            return entry.url
        }
        if let running = searches[coverArt] { return await running.value }
        let search = Task { await Self.search(coverArt: coverArt, server: server) }
        searches[coverArt] = search
        let found = await search.value
        searches[coverArt] = nil
        entries[coverArt] = Entry(url: found, checked: Date())
        save()
        if let found {
            AppLogger.shared.log("🖼 Cover art id=\(coverArt): found in the catalogue — \(found)")
        }
        return found
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: Self.file, options: .atomic)
        } catch {
            AppLogger.shared.log("❌ Couldn't keep the found covers: \(error.localizedDescription)")
        }
    }

    // MARK: Looking

    private static func search(coverArt: String, server: ServerConfig) async -> String? {
        guard let (artist, album) = await subject(of: coverArt, server: server) else { return nil }
        // Fielded first, which finds the exact release; then loose, which forgives a title
        // the catalogue spells a little differently.
        for query in ["artist:\"\(artist)\" album:\"\(album)\"", "\(artist) \(album)"] {
            if let hit = await albums(matching: query).first(where: { matches($0, artist: artist, album: album) }) {
                return hit.cover_xl
            }
        }
        return nil
    }

    /// The album a cover belongs to, as its artist and title. Navidrome names covers after
    /// what they belong to — "al-" an album, "mf-" a single file — with a date after an
    /// underscore; other servers use the album's id as it is.
    private static func subject(of coverArt: String, server: ServerConfig) async -> (String, String)? {
        let id = coverArt.components(separatedBy: "_").first ?? coverArt
        if id.hasPrefix("mf-"),
           let song = try? await SubsonicClient.shared.getSong(server: server, id: String(id.dropFirst(3))),
           let artist = song.artist {
            return (artist, song.album ?? song.title)
        }
        let albumId = id.hasPrefix("al-") ? String(id.dropFirst(3)) : id
        guard let album = try? await SubsonicClient.shared.getAlbum(server: server, id: albumId),
              let artist = album.artist
        else { return nil }
        return (artist, album.name)
    }

    private struct Hit: Decodable {
        struct Artist: Decodable { let name: String }
        let title: String
        let artist: Artist?
        let cover_xl: String?
    }

    private struct Page: Decodable { let data: [Hit]? }

    private static func albums(matching query: String) async -> [Hit] {
        var components = URLComponents(string: "https://api.deezer.com/search/album")
        components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "10")]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let page = try? JSONDecoder().decode(Page.self, from: data)
        else { return [] }
        return page.data ?? []
    }

    /// The same release: the same title, give or take a bracketed edition, by an artist the
    /// album credits. A near miss is worse than Aura's own stand-in, so both must agree.
    private static func matches(_ hit: Hit, artist: String, album: String) -> Bool {
        guard hit.cover_xl?.isEmpty == false, let name = hit.artist?.name else { return false }
        let sameArtist = RadarRules.credits(artist, name) || RadarRules.credits(name, artist)
        let sameTitle = RadarRules.sameTitle(hit.title, album)
            || RadarRules.sameTitle(unbracketed(hit.title), unbracketed(album))
        return sameArtist && sameTitle
    }

    private static func unbracketed(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
    }
}
