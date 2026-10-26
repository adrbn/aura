import Foundation
import CryptoKit

/// The whole library held on the phone — every song, album and artist — so a search is
/// answered here as fast as it is typed, typos and operators included (`LocalSearch`),
/// instead of one trip to the server per keystroke. Built once per server, kept on disk,
/// and rebuilt in the background when the server's last scan changes.
@MainActor
final class LibraryIndex {
    static let shared = LibraryIndex()

    private struct Stored: Codable {
        var stamp: String
        var songs: [Song]
        var albums: [Album]
        var artists: [Artist]
    }

    /// The library, with what search needs worked out once.
    private struct Corpus: Sendable {
        let key: String
        let songs: [Song], albums: [Album], artists: [Artist]
        let songDocs: [LocalSearch.Doc], albumDocs: [LocalSearch.Doc], artistDocs: [LocalSearch.Doc]
        let vocabulary: LocalSearch.Vocabulary
        /// Most used first, for the operator suggestions.
        let genres: [String], years: [Int]

        init(key: String, _ stored: Stored) {
            self.key = key
            songs = stored.songs; albums = stored.albums; artists = stored.artists
            songDocs = songs.map {
                LocalSearch.Doc(title: $0.title, artist: $0.artist, album: $0.album, genre: $0.genre,
                                year: $0.year, popularity: $0.playCount ?? 0)
            }
            albumDocs = albums.map {
                LocalSearch.Doc(artist: $0.artist, album: $0.name, genre: $0.genre, year: $0.year,
                                popularity: $0.playCount ?? 0)
            }
            artistDocs = artists.map { LocalSearch.Doc(artist: $0.name, popularity: $0.albumCount ?? 0) }
            vocabulary = LocalSearch.Vocabulary(songDocs + albumDocs + artistDocs)
            var genreCounts: [String: Int] = [:]
            for song in songs { if let g = song.genre, !g.isEmpty { genreCounts[g, default: 0] += 1 } }
            genres = genreCounts.sorted { $0.value > $1.value }.map(\.key)
            years = Set(songs.compactMap(\.year)).filter { $0 > 0 }.sorted(by: >)
        }
    }

    struct Found: Sendable {
        var songs: [Song], albums: [Album], artists: [Artist]
        /// The query with its typos fixed, when any were.
        var corrected: String?
    }

    private var corpus: Corpus?
    private var refreshTask: Task<Void, Never>?
    private static let pageSize = 500
    /// The whole library is tens of megabytes: fetched again at most this often, however
    /// often the server scans. What came in since is still found — see `search`.
    private static let rebuildEvery: TimeInterval = 6 * 3600

    private init() {}

    /// Whether search can be answered on the phone for the server in use.
    var isReady: Bool { corpus != nil && corpus?.key == currentKey }

    private var currentKey: String? {
        guard let server = ServerManager.shared.currentServer else { return nil }
        let folders = AppSettings.shared.selectedMusicFolderIds.map(String.init).joined(separator: ",")
        return "\(server.url)|\(server.username)|\(folders)"
    }

    private static func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).json")
    }

    // MARK: Building

    /// Loads the saved index, then rebuilds it if the server has scanned since. Runs once
    /// at a time; safe to call whenever search is opened.
    func refreshIfNeeded() {
        guard refreshTask == nil, let key = currentKey, let server = ServerManager.shared.currentServer else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            let file = Self.file(for: key)
            let saved: Stored? = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(Stored.self, from: data)
            }.value
            if let saved, corpus?.key != key {
                corpus = await Task.detached(priority: .utility) { Corpus(key: key, saved) }.value
            }

            guard let status = try? await SubsonicClient.shared.getScanStatus(server: server), !status.scanning,
                  // ponytail: past this the index outweighs what a phone should hold in memory;
                  // such a library keeps searching on the server.
                  (status.count ?? 0) <= 150_000 else { return }
            let stamp = "\(status.lastScan ?? "")|\(status.count ?? -1)"
            guard saved?.stamp != stamp else { return }
            if saved != nil, let built = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(built) < Self.rebuildEvery { return }
            guard let built = await Self.download(server: server) else { return }
            let stored = Stored(stamp: stamp, songs: built.songs, albums: built.albums, artists: built.artists)
            corpus = await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(stored) { try? data.write(to: file, options: .atomic) }
                return Corpus(key: key, stored)
            }.value
            AppLogger.shared.log("🔎 Library index: \(stored.songs.count) songs, \(stored.albums.count) albums, \(stored.artists.count) artists")
        }
    }

    /// Every song, album and artist, several pages at a time. nil when the server won't list
    /// them (an empty search lists every song on Navidrome; not every server does).
    private static func download(server: ServerConfig) async -> (songs: [Song], albums: [Album], artists: [Artist])? {
        let client = SubsonicClient.shared
        do {
            async let artists = client.getArtists(server: server)
            let songs = try await pages { offset in
                try await client.search3(server: server, query: "", artistCount: 0, albumCount: 0,
                                         songCount: pageSize, songOffset: offset).song ?? []
            }
            guard !songs.isEmpty else { return nil }
            let albums = try await pages { offset in
                try await client.getAlbumList2(server: server, type: "alphabeticalByName", size: pageSize, offset: offset)
            }
            return (songs, albums, try await artists)
        } catch {
            AppLogger.shared.log("🔎 Library index not built: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetches pages four at a time until one comes back short.
    private static func pages<T: Sendable>(_ fetch: @escaping @Sendable (Int) async throws -> [T]) async throws -> [T] {
        var all: [T] = []
        var offset = 0
        while true {
            let batch = 4
            let results = try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
                for i in 0..<batch { let o = offset + i * pageSize; group.addTask { (o, try await fetch(o)) } }
                var got: [(Int, [T])] = []
                for try await r in group { got.append(r) }
                return got.sorted { $0.0 < $1.0 }.map(\.1)
            }
            for page in results {
                all += page
                if page.count < pageSize { return all }
            }
            offset += batch * pageSize
        }
    }

    // MARK: Operator suggestions

    struct Chip: Hashable { let label: String; let query: String }

    /// Taps that write the query: the operators while nothing is half-typed, and the names
    /// in the library while one is (`artist:lo` → Lost Frequencies). Empty without an index,
    /// since only the index understands them.
    func chips(for query: String) -> [Chip] {
        guard let corpus, corpus.key == currentKey else { return [] }
        let head = query.hasSuffix(" ") || query.isEmpty ? query : String(query[..<(query.lastIndex(of: " ").map { query.index(after: $0) } ?? query.startIndex)])
        let last = String(query.dropFirst(head.count))
        if last.isEmpty {
            var ops = ["artist:", "album:", "genre:", "year:", "\"", "-"]
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { ops.append("OR ") }
            return ops.map { Chip(label: $0 == "\"" ? "\"…\"" : $0.trimmingCharacters(in: .whitespaces), query: query + $0) }
        }
        guard let colon = last.firstIndex(of: ":") else { return [] }
        let field = last[..<colon].lowercased()
        let typed = LocalSearch.fold(String(last[last.index(after: colon)...]).replacingOccurrences(of: "\"", with: ""))
        func starts(_ name: String) -> Bool {
            typed.isEmpty || LocalSearch.words(name).joined(separator: " ").hasPrefix(typed)
                || LocalSearch.words(name).contains { $0.hasPrefix(typed) }
        }
        // What's already typed narrows the offer: after artist:Avicii, album: offers his.
        let context = LocalSearch.parse(head)
        func fits(_ doc: LocalSearch.Doc) -> Bool { context.isEmpty || LocalSearch.score(context, doc) != nil }
        let songs = context.isEmpty ? corpus.songs : corpus.songs.indices.filter { fits(corpus.songDocs[$0]) }.map { corpus.songs[$0] }
        let names: [String]
        switch field {
        case "artist", "by":
            names = corpus.artists.indices.filter { !corpus.artists[$0].name.contains(",") && starts(corpus.artists[$0].name) && fits(corpus.artistDocs[$0]) }
                .map { corpus.artists[$0] }
                .sorted { ($0.albumCount ?? 0) > ($1.albumCount ?? 0) }.map(\.name)
        case "album":
            names = corpus.albums.indices.filter { starts(corpus.albums[$0].name) && fits(corpus.albumDocs[$0]) }
                .map { corpus.albums[$0] }
                .sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.map(\.name)
        case "genre":
            let held = Set(songs.compactMap(\.genre))
            names = corpus.genres.filter { held.contains($0) && starts($0) }
        case "year", "annee", "année":
            let held = Set(songs.compactMap(\.year))
            names = corpus.years.filter { held.contains($0) }.map(String.init).filter { typed.isEmpty || $0.hasPrefix(typed) }
        default:
            return []
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }.prefix(8).map { name in
            let value = name.contains(" ") ? "\"\(name)\"" : name
            return Chip(label: name, query: head + field + ":" + value + " ")
        }
    }

    // MARK: Searching

    /// The library's answer, or nil when there is no index for the server in use yet, or
    /// it holds nothing for the query — a song added since it was built is the server's to find.
    func search(_ raw: String) async -> Found? {
        guard let corpus, corpus.key == currentKey else { return nil }
        let found = await Task.detached(priority: .userInitiated) {
            let (query, changes) = LocalSearch.corrected(LocalSearch.parse(raw), vocabulary: corpus.vocabulary)
            return Found(
                songs: LocalSearch.search(query, in: corpus.songDocs, limit: 100).map { corpus.songs[$0] },
                albums: LocalSearch.search(query, in: corpus.albumDocs, limit: 40).map { corpus.albums[$0] },
                artists: LocalSearch.search(query, in: corpus.artistDocs, limit: 20).map { corpus.artists[$0] },
                corrected: changes.isEmpty ? nil : LocalSearch.rewrite(raw, changes: changes)
            )
        }.value
        // A query with operators is the library's alone to answer: the server would read
        // "genre:Electronic" as words and send back songs of any genre.
        let query = LocalSearch.parse(raw)
        let usesOperators = query.years != nil || query.alternatives.count > 1
            || query.alternatives.joined().contains { $0.field != nil || $0.negated }
        return found.songs.isEmpty && found.albums.isEmpty && found.artists.isEmpty && !usesOperators ? nil : found
    }
}
