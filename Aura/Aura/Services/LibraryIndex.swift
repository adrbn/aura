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

            guard let status = try? await SubsonicClient.shared.getScanStatus(server: server), !status.scanning else { return }
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

    /// Every song, album and artist, page by page. nil when the server won't list them
    /// (an empty search lists every song on Navidrome; not every server does).
    private static func download(server: ServerConfig) async -> (songs: [Song], albums: [Album], artists: [Artist])? {
        let client = SubsonicClient.shared
        do {
            var songs: [Song] = []
            while true {
                let page = try await client.search3(server: server, query: "", artistCount: 0, albumCount: 0,
                                                    songCount: pageSize, songOffset: songs.count).song ?? []
                songs += page
                if page.count < pageSize { break }
            }
            guard !songs.isEmpty else { return nil }
            var albums: [Album] = []
            while true {
                let page = try await client.getAlbumList2(server: server, type: "alphabeticalByName",
                                                          size: pageSize, offset: albums.count)
                albums += page
                if page.count < pageSize { break }
            }
            let artists = try await client.getArtists(server: server)
            return (songs, albums, artists)
        } catch {
            AppLogger.shared.log("🔎 Library index not built: \(error.localizedDescription)")
            return nil
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
        return found.songs.isEmpty && found.albums.isEmpty && found.artists.isEmpty ? nil : found
    }
}
