import Foundation

/// Lyrics timed by hand, written beside the song on the listener's own server as an `.lrc`,
/// so every device and app gets them — Navidrome reads it, word timings included, once `.lrc`
/// comes first in its lyrics order. Navidrome can't write it; File Browser, pointed at the
/// music, can. Only the sideload build offers it, with its beta features on.
enum LyricsOnServer {
    static let enabledKey = "lyrics_on_server"
    static let addressKey = "filebrowser_address"
    static let userKey = "filebrowser_user"
    static let passwordAccount = "filebrowser"
    /// Where the library turned out to be in File Browser: "folder|leading parts dropped".
    private static let rootKey = "filebrowser_library_root"

    enum Failure: LocalizedError {
        case notSignedIn, refusedSignIn, songUnknown, songNotFound, refused(Int)

        // Never shown in the App Store build, which doesn't write to the server: kept out of it.
        var errorDescription: String? {
            #if APPSTORE_BUILD
            return nil
            #else
            return switch self {
            case .notSignedIn: String(localized: "Add the File Browser sign-in in Settings.")
            case .refusedSignIn: String(localized: "File Browser didn't accept the sign-in.")
            case .songUnknown: String(localized: "The server didn't say where the song is.")
            case .songNotFound: String(localized: "The song's file wasn't found through File Browser.")
            case .refused(let status): String(localized: "File Browser refused the lyrics (HTTP \(status)).")
            }
            #endif
        }
    }

    static var isEnabled: Bool {
        #if APPSTORE_BUILD
        return false
        #else
        return AppSettings.shared.betaFeaturesEnabled && UserDefaults.standard.bool(forKey: enabledKey)
        #endif
    }

    /// File Browser on the music server's own host, as it's usually run.
    static var suggestedAddress: String {
        let host = ServerManager.shared.currentServer.flatMap { URL(string: $0.baseURL)?.host } ?? "server"
        return "http://\(host):8080"
    }

    static func save(_ lrc: String, for song: Song) async throws {
        let session = try await signIn()
        let path = try await lyricsPath(for: song, session: session)
        var request = session.request("resources" + path + "?override=true")
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(lrc.utf8)
        let status = await send(request)
        guard (200...299).contains(status) else { throw Failure.refused(status) }
        AppLogger.shared.log("🎵 Lyrics timing written to the server: \(path)")
    }

    static func remove(for song: Song) async throws {
        let session = try await signIn()
        let path = try await lyricsPath(for: song, session: session)
        var request = session.request("resources" + path)
        request.httpMethod = "DELETE"
        let status = await send(request)
        // Never written, or already gone: nothing to take back.
        guard (200...299).contains(status) || status == 404 else { throw Failure.refused(status) }
    }

    // MARK: File Browser

    private struct Session {
        let base: URL
        let token: String

        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: URL(string: base.absoluteString + "/api/" + path) ?? base)
            request.setValue(token, forHTTPHeaderField: "X-Auth")
            request.timeoutInterval = 20
            return request
        }
    }

    private static func signIn() async throws -> Session {
        let defaults = UserDefaults.standard
        let typed = (defaults.string(forKey: addressKey) ?? "").trimmingCharacters(in: .whitespaces)
        let address = typed.isEmpty ? suggestedAddress : typed
        let user = defaults.string(forKey: userKey) ?? ""
        guard !user.isEmpty, let password = KeychainHelper.loadPassword(for: passwordAccount),
              let base = URL(string: address.contains("://") ? address : "http://\(address)")
        else { throw Failure.notSignedIn }
        var request = URLRequest(url: base.appendingPathComponent("api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": user, "password": password,
                                                                       "recaptcha": ""])
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { throw Failure.refusedSignIn }
        let trimmed = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return Session(base: URL(string: trimmed) ?? base, token: token)
    }

    private static func send(_ request: URLRequest) async -> Int {
        (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
    }

    private static func exists(_ path: String, session: Session) async -> Bool {
        await send(session.request("resources" + encoded(path))) == 200
    }

    // MARK: Finding the song

    /// The `.lrc` beside the song's file, as File Browser names it: the library's folder
    /// there, found once and remembered, then the song's own path inside it.
    private static func lyricsPath(for song: Song, session: Session) async throws -> String {
        let parts = try await songPath(for: song)
        let audio: String
        if let root = rememberedRoot(), root.dropped < parts.count,
           await exists(joined(root.folder, parts[root.dropped...]), session: session) {
            audio = joined(root.folder, parts[root.dropped...])
        } else if let root = await findRoot(for: parts, session: session) {
            UserDefaults.standard.set("\(root.folder)|\(root.dropped)", forKey: rootKey)
            audio = joined(root.folder, parts[root.dropped...])
        } else {
            throw Failure.songNotFound
        }
        let stem = (audio as NSString).deletingPathExtension
        return encoded(stem + ".lrc")
    }

    /// The song's path in its Navidrome library, a part per folder.
    private static func songPath(for song: Song) async throws -> [String] {
        guard let server = ServerManager.shared.currentServer,
              let token = await PlaylistCovers.token(server: server),
              let url = URL(string: "\(server.baseURL)/api/song/\(song.id)") else { throw Failure.songUnknown }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String, !path.isEmpty
        else { throw Failure.songUnknown }
        return path.split(separator: "/").map(String.init)
    }

    /// Looks for the song under File Browser's folders, two levels down — the song's path
    /// whole, or without its first folder or two, since Navidrome mounts the music under
    /// names of its own. Folders that sound like music go first; "_" ones (quarantines,
    /// tools) last.
    private static func findRoot(for parts: [String], session: Session) async -> (folder: String, dropped: Int)? {
        let drops = Array(0..<min(3, parts.count))
        var queue: [(folder: String, depth: Int)] = [("", 0)]
        var tried = 0
        while !queue.isEmpty, tried < 80 {
            let (folder, depth) = queue.removeFirst()
            for dropped in drops {
                tried += 1
                if await exists(joined(folder, parts[dropped...]), session: session) { return (folder, dropped) }
            }
            guard depth < 2 else { continue }
            queue += await subfolders(of: folder, session: session).map { ($0, depth + 1) }
        }
        return nil
    }

    private static func subfolders(of folder: String, session: Session) async -> [String] {
        guard let (data, response) = try? await URLSession.shared.data(for: session.request("resources" + encoded(folder + "/"))),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        let names = items.compactMap { $0["isDir"] as? Bool == true ? $0["name"] as? String : nil }
            .filter { !$0.hasPrefix(".") }
        func rank(_ name: String) -> Int {
            name.localizedCaseInsensitiveContains("music") ? 0 : name.hasPrefix("_") ? 2 : 1
        }
        return names.sorted { rank($0) < rank($1) }.map { folder + "/" + $0 }
    }

    private static func rememberedRoot() -> (folder: String, dropped: Int)? {
        guard let saved = UserDefaults.standard.string(forKey: rootKey),
              let bar = saved.lastIndex(of: "|"), let dropped = Int(saved[saved.index(after: bar)...])
        else { return nil }
        return (String(saved[..<bar]), dropped)
    }

    private static func joined(_ folder: String, _ parts: ArraySlice<String>) -> String {
        folder + "/" + parts.joined(separator: "/")
    }

    /// Percent-encoded for a URL, the slashes kept.
    private static func encoded(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ";?#%")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
