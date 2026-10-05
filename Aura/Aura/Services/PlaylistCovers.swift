import Foundation

/// A playlist's own picture on the server, through Navidrome's native API — Subsonic has no
/// call for it. Signs in for a token on each change: changes are rare, tokens short-lived.
enum PlaylistCovers {
    /// Shares cookies between the sign-in and the upload.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    /// Sets the playlist's picture. True once the server took it.
    @discardableResult
    static func upload(_ jpeg: Data, playlistId: String, server: ServerConfig) async -> Bool {
        guard let token = await token(server: server),
              let url = URL(string: "\(server.baseURL)/api/playlist/\(playlistId)/image") else {
            AppLogger.shared.log("❌ Playlist cover upload: no token or invalid URL")
            return false
        }
        let boundary = UUID().uuidString
        var request = authorized(URLRequest(url: url), token: token)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image\"; filename=\"cover.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        AppLogger.shared.log("📤 Uploading playlist cover: \(url.absoluteString) (\(jpeg.count) bytes)")
        return await send(request, what: "Playlist cover upload")
    }

    /// Drops the playlist's picture; the server goes back to one made from its songs.
    @discardableResult
    static func remove(playlistId: String, server: ServerConfig) async -> Bool {
        guard let token = await token(server: server),
              let url = URL(string: "\(server.baseURL)/api/playlist/\(playlistId)/image") else {
            AppLogger.shared.log("❌ Remove playlist cover: no token or invalid URL")
            return false
        }
        var request = authorized(URLRequest(url: url), token: token)
        request.httpMethod = "DELETE"
        AppLogger.shared.log("🗑 Removing playlist cover: \(url.absoluteString)")
        return await send(request, what: "Remove playlist cover")
    }

    // MARK: Plumbing

    /// Both headers: Navidrome versions differ on which one they read.
    private static func authorized(_ request: URLRequest, token: String) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        return request
    }

    private static func send(_ request: URLRequest, what: String) async -> Bool {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            AppLogger.shared.log("\(what): HTTP \(http.statusCode) — \(body)")
            return (200...299).contains(http.statusCode)
        } catch {
            AppLogger.shared.log("❌ \(what) error: \(error.localizedDescription)")
            return false
        }
    }

    /// A native-API token; the lyrics written to the server look songs up with it too.
    static func token(server: ServerConfig) async -> String? {
        guard let url = URL(string: "\(server.baseURL)/auth/login") else {
            AppLogger.shared.log("❌ Navidrome auth: invalid login URL")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["username": server.username,
                                                                      "password": server.password]) else {
            AppLogger.shared.log("❌ Navidrome auth: failed to build request body")
            return nil
        }
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            AppLogger.shared.log("🔐 Navidrome auth: HTTP \(http.statusCode)")
            guard (200...299).contains(http.statusCode) else {
                AppLogger.shared.log("❌ Navidrome auth failed: \(String(data: data, encoding: .utf8) ?? "(no body)")")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["token"] as? String, !token.isEmpty {
                return token
            }
            AppLogger.shared.log("❌ Navidrome auth: no token in response")
        } catch {
            AppLogger.shared.log("❌ Navidrome auth error: \(error.localizedDescription)")
        }
        return nil
    }
}
