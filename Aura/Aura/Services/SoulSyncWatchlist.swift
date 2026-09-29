import Foundation

/// SoulSync's watchlist, on the listener's own server: the artists it follows, whose new
/// releases it downloads by itself once a day. When it answers, the radar follows the same
/// artists — one list, so what the radar shows is what is coming — and keeps the list in step
/// with the listening. Only the sideload build asks it, with its beta features on; SoulSync
/// is looked for on the Soulseek host, on its own port.
enum SoulSyncWatchlist {
    struct Artist: Decodable, Hashable {
        let artistName: String
        let deezerArtistId: String?
        let includeAlbums: Bool?
        let includeEps: Bool?
        let includeSingles: Bool?

        /// Whether SoulSync downloads a release of this Deezer type ("album", "ep", "single").
        func fetches(_ type: String) -> Bool {
            switch type {
            case "album": return includeAlbums ?? true
            case "ep": return includeEps ?? true
            case "single": return includeSingles ?? true
            default: return false
            }
        }

        private enum CodingKeys: String, CodingKey {
            case artistName, deezerArtistId, includeAlbums, includeEps, includeSingles
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            artistName = try values.decode(String.self, forKey: .artistName)
            // Written as a string by some versions, a number by others.
            deezerArtistId = (try? values.decodeIfPresent(String.self, forKey: .deezerArtistId))
                ?? (try? values.decodeIfPresent(Int.self, forKey: .deezerArtistId)).map { String($0) }
            includeAlbums = try values.decodeIfPresent(Bool.self, forKey: .includeAlbums)
            includeEps = try values.decodeIfPresent(Bool.self, forKey: .includeEps)
            includeSingles = try values.decodeIfPresent(Bool.self, forKey: .includeSingles)
        }
    }

    private struct Listing: Decodable {
        let artists: [Artist]
    }

    private static let port = 8008

    static var isEnabled: Bool {
        #if APPSTORE_BUILD
        return false
        #else
        return AppSettings.shared.betaFeaturesEnabled
        #endif
    }

    /// SoulSync beside slskd: the same host, without slskd's scheme or port.
    private static var base: URL? {
        let setting = AppSettings.shared.externalServiceURL.trimmingCharacters(in: .whitespaces)
        let host = URLComponents(string: setting.contains("://") ? setting : "http://\(setting)")?.host
        guard let host, !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(port)/api/watchlist")
    }

    /// Nil when SoulSync is off or doesn't answer: the radar then picks its own artists.
    static func artists() async -> [Artist]? {
        guard isEnabled, let url = base?.appendingPathComponent("artists") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Listing.self, from: data).artists
        } catch {
            AppLogger.shared.log("📡 SoulSync watchlist unreadable: \(error.localizedDescription)")
            return nil
        }
    }

    /// SoulSync looks each one up as it adds it, so a batch takes a while.
    @discardableResult
    static func add(_ artists: [(deezerId: String, name: String)]) async -> Bool {
        guard !artists.isEmpty else { return true }
        let body = ["artists": artists.map { ["artist_id": $0.deezerId, "artist_name": $0.name] }]
        return await post("add-batch", body: body, timeout: 300)
    }

    @discardableResult
    static func remove(deezerId: String) async -> Bool {
        await post("remove", body: ["artist_id": deezerId], timeout: 30)
    }

    private static func post(_ path: String, body: some Encodable, timeout: TimeInterval) async -> Bool {
        guard isEnabled, let url = base?.appendingPathComponent(path),
              let payload = try? JSONEncoder().encode(body) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = timeout
        let status = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        guard status == 200 else {
            AppLogger.shared.log("📡 SoulSync \(path) failed: \(status.map(String.init) ?? "no answer")")
            return false
        }
        return true
    }

    // MARK: Following

    /// Artists already put to SoulSync, or found on its list: never put again, so one taken
    /// off by hand in SoulSync stays off.
    private static let offeredKey = "soulsync_offered_v1"

    /// The artists the radar follows through SoulSync, each with their Deezer id: its list,
    /// with the radar's own picks it lacks added to it first — the favourites and the most
    /// played, as the radar has always followed. Those unfollowed in the app stay off both.
    static func following(watched: [Artist], picks: [ArtistRef], library: [String: String],
                          unfollowed: Set<String>) async -> [(artist: ArtistRef, deezerId: String)] {
        var offered = Set(UserDefaults.standard.stringArray(forKey: offeredKey) ?? [])
        var list = watched.compactMap { artist in
            artist.deezerArtistId.map { (name: artist.artistName, deezerId: $0) }
        }
        var listed = Set(list.map { key($0.name) })
        offered.formUnion(listed)

        var added: [(deezerId: String, name: String)] = []
        for pick in picks where !listed.contains(key(pick.name)) && !offered.contains(key(pick.name))
            && !unfollowed.contains(key(pick.name)) {
            guard case .found(let id) = await RadarCatalog.artistId(for: pick.name) else { continue }
            added.append((id, pick.name))
            listed.insert(key(pick.name))
            offered.insert(key(pick.name))
        }
        UserDefaults.standard.set(Array(offered), forKey: offeredKey)
        if !added.isEmpty {
            AppLogger.shared.log("📡 SoulSync: following \(added.count) more — \(added.map(\.name).joined(separator: ", "))")
            // Not waited for: the radar asks Deezer with the ids already in hand.
            let batch = added
            Task.detached { await add(batch) }
            list += added.map { (name: $0.name, deezerId: $0.deezerId) }
        }

        // The radar's picks first, in its order: a collaboration shows under the more played.
        let rank = Dictionary(picks.enumerated().map { (key($0.element.name), $0.offset) },
                              uniquingKeysWith: { first, _ in first })
        return list
            .filter { !unfollowed.contains(key($0.name)) }
            .sorted { (rank[key($0.name)] ?? .max) < (rank[key($1.name)] ?? .max) }
            .map { entry -> (artist: ArtistRef, deezerId: String) in
                let id = library[key(entry.name)] ?? ArtistRef.deezerPrefix + entry.deezerId
                return (ArtistRef(id: id, name: entry.name), entry.deezerId)
            }
    }

    static func key(_ name: String) -> String {
        SongQuery.fold(name).trimmingCharacters(in: .whitespaces)
    }
}
