import Foundation

// MARK: - MusicBrainz API Models

struct MBRecordingResult: Decodable {
    let recordings: [MBRecording]?
}

struct MBRecording: Decodable {
    let id: String
    let title: String?
    let length: Int?
    let isrcs: [String]?
    let releases: [MBRelease]?
    let tags: [MBTag]?
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title, length, isrcs, releases, tags
        case artistCredit = "artist-credit"
    }
}

struct MBRelease: Decodable {
    let id: String
    let title: String?
    let date: String?
    let country: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, status
    }
}

struct MBTag: Decodable {
    let name: String
    let count: Int
}

struct MBArtistCredit: Decodable {
    let name: String?
    let artist: MBArtist?
    let joinphrase: String?
}

struct MBArtist: Decodable {
    let id: String
    let name: String
    let type: String?
    let country: String?
    let disambiguation: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, country, disambiguation
    }
}

// MARK: - Recording Details (from lookup endpoint with rels)

struct MBRecordingDetail: Decodable {
    let id: String
    let title: String?
    let length: Int?
    let isrcs: [String]?
    let releases: [MBRelease]?
    let relations: [MBRelation]?
    let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title, length, isrcs, releases, relations
        case artistCredit = "artist-credit"
    }
}

// Work detail for composer/writer info
struct MBWorkResult: Decodable {
    let works: [MBWork]?
}

struct MBWork: Decodable {
    let id: String
    let title: String?
    let relations: [MBRelation]?
}

struct MBRelation: Decodable {
    let type: String?
    let targetType: String?
    let direction: String?
    let artist: MBArtist?
    let work: MBWorkRef?
    let attributes: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case targetType = "target-type"
        case direction, artist, work, attributes
    }
}

struct MBWorkRef: Decodable {
    let id: String
    let title: String?
}

// Release detail for label info
struct MBReleaseDetail: Decodable {
    let id: String
    let title: String?
    let date: String?
    let country: String?
    let labelInfo: [MBLabelInfo]?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country
        case labelInfo = "label-info"
    }
}

struct MBLabelInfo: Decodable {
    let catalogNumber: String?
    let label: MBLabel?

    enum CodingKeys: String, CodingKey {
        case catalogNumber = "catalog-number"
        case label
    }
}

struct MBLabel: Decodable {
    let id: String
    let name: String
}

// MARK: - Parsed Credits

struct SongCredits {
    var performers: [(role: String, name: String)] = []
    var writers: [String] = []
    var composers: [String] = []
    var lyricists: [String] = []
    var producers: [String] = []
    var mixers: [String] = []
    var engineers: [String] = []
    var remixers: [String] = []
    var arrangers: [String] = []
    var label: String?
    var catalogNumber: String?
    var releaseDate: String?
    var releaseCountry: String?
    var isrc: String?
    var recordingId: String?
    var tags: [String] = []

    var hasAnyCredits: Bool {
        !writers.isEmpty || !composers.isEmpty || !lyricists.isEmpty ||
        !producers.isEmpty || !mixers.isEmpty || !engineers.isEmpty ||
        !performers.isEmpty || !remixers.isEmpty || !arrangers.isEmpty ||
        label != nil || releaseDate != nil || isrc != nil || !tags.isEmpty
    }
}

// MARK: - MusicBrainz Service

actor MusicBrainzService {
    static let shared = MusicBrainzService()

    private let baseURL = "https://musicbrainz.org/ws/2"
    private let userAgent = "Aura/1.0 (https://aura-music.app)"

    // Cache to avoid redundant lookups, capped with oldest-first eviction
    private let cacheLimit = 200
    private var cache: [String: SongCredits] = [:]
    private var cacheOrder: [String] = []

    private func storeInCache(_ credits: SongCredits, forKey key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
        cache[key] = credits
    }

    func fetchCredits(title: String, artist: String) async -> SongCredits? {
        let cacheKey = "\(artist.lowercased())|\(title.lowercased())"
        if let cached = cache[cacheKey] { return cached }

        do {
            // Step 1: Search for the recording using proper query encoding
            let cleanTitle = title
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .replacingOccurrences(of: "\"", with: "")
            let cleanArtist = artist
                .components(separatedBy: CharacterSet(charactersIn: ",;&·•"))
                .first?.trimmingCharacters(in: .whitespaces) ?? artist

            // Use quoted phrases for better matching
            let query = "\"\(cleanTitle)\" AND artist:\"\(cleanArtist)\""
            guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let searchURL = URL(string: "\(baseURL)/recording?query=\(encodedQuery)&limit=5&fmt=json") else { return nil }

            let recording = try await fetchFirstRecording(from: searchURL)
            guard let recording else { return nil }

            AppLogger.shared.log("🎵 MusicBrainz: Found recording '\(recording.title ?? "?")' id=\(recording.id)")

            // Step 2: Fetch recording details with artist-rels AND work-rels (composers are on works!)
            try await Task.sleep(for: .milliseconds(1100))

            let incParams = "artist-rels+work-rels+recording-rels+isrcs+tags+releases"
            guard let detailURL = URL(string: "\(baseURL)/recording/\(recording.id)?inc=\(incParams)&fmt=json") else { return nil }

            let detail = try await fetchJSON(MBRecordingDetail.self, from: detailURL)

            var credits = SongCredits()
            credits.recordingId = detail.id

            // Parse recording-level relations (performers, producers, engineers, etc.)
            if let relations = detail.relations {
                for rel in relations {
                    if let artist = rel.artist, let type = rel.type {
                        categorizeRelation(type: type, artistName: artist.name, attributes: rel.attributes, into: &credits)
                    }

                    // Work relations — follow the work to get composer/writer info
                    if rel.targetType == "work", let workRef = rel.work {
                        try await Task.sleep(for: .milliseconds(1100))
                        await fetchWorkCredits(workId: workRef.id, into: &credits)
                    }
                }
            }

            // Parse release info + label
            if let release = detail.releases?.first {
                credits.releaseDate = release.date
                credits.releaseCountry = release.country

                // Fetch label info from release
                try await Task.sleep(for: .milliseconds(1100))
                await fetchReleaseLabel(releaseId: release.id, into: &credits)
            }

            // Parse ISRCs
            credits.isrc = detail.isrcs?.first

            // Parse tags from search result (search includes tags)
            if let tags = recording.tags {
                credits.tags = tags.sorted { $0.count > $1.count }.prefix(8).map { $0.name.capitalized }
            }

            storeInCache(credits, forKey: cacheKey)
            AppLogger.shared.log("🎵 MusicBrainz: Found \(credits.writers.count) writers, \(credits.composers.count) composers, \(credits.producers.count) producers, \(credits.performers.count) performers")
            return credits
        } catch {
            AppLogger.shared.log("🎵 MusicBrainz lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Fetch helpers

    private func fetchFirstRecording(from url: URL) async throws -> MBRecording? {
        let result = try await fetchJSON(MBRecordingResult.self, from: url)
        return result.recordings?.first
    }

    private func fetchJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 503 {
            // Rate limited, retry after delay
            try await Task.sleep(for: .seconds(2))
            let (retryData, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(T.self, from: retryData)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Work credits (composers, lyricists, writers)

    private func fetchWorkCredits(workId: String, into credits: inout SongCredits) async {
        do {
            guard let url = URL(string: "\(baseURL)/work/\(workId)?inc=artist-rels&fmt=json") else { return }
            let work = try await fetchJSON(MBWork.self, from: url)

            if let relations = work.relations {
                for rel in relations {
                    guard let artist = rel.artist, let type = rel.type else { continue }
                    let name = artist.name

                    switch type.lowercased() {
                    case "writer":
                        if !credits.writers.contains(name) { credits.writers.append(name) }
                    case "composer":
                        if !credits.composers.contains(name) { credits.composers.append(name) }
                    case "lyricist":
                        if !credits.lyricists.contains(name) { credits.lyricists.append(name) }
                    case "arranger":
                        if !credits.arrangers.contains(name) { credits.arrangers.append(name) }
                    default:
                        // Some works have "writer" as the generic type
                        if !credits.writers.contains(name) && !credits.composers.contains(name) {
                            credits.writers.append(name)
                        }
                    }
                }
            }
            AppLogger.shared.log("🎵 MusicBrainz work \(workId): \(work.relations?.count ?? 0) relations")
        } catch {
            AppLogger.shared.log("🎵 MusicBrainz work lookup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Release label info

    private func fetchReleaseLabel(releaseId: String, into credits: inout SongCredits) async {
        do {
            guard let url = URL(string: "\(baseURL)/release/\(releaseId)?inc=labels&fmt=json") else { return }
            let release = try await fetchJSON(MBReleaseDetail.self, from: url)

            if let labelInfo = release.labelInfo?.first {
                credits.label = labelInfo.label?.name
                credits.catalogNumber = labelInfo.catalogNumber
            }
        } catch {
            AppLogger.shared.log("🎵 MusicBrainz release lookup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Categorize relation types

    private func categorizeRelation(type: String, artistName: String, attributes: [String]?, into credits: inout SongCredits) {
        switch type.lowercased() {
        // Writers/composers (sometimes at recording level too)
        case "writer":
            if !credits.writers.contains(artistName) { credits.writers.append(artistName) }
        case "composer":
            if !credits.composers.contains(artistName) { credits.composers.append(artistName) }
        case "lyricist":
            if !credits.lyricists.contains(artistName) { credits.lyricists.append(artistName) }

        // Production
        case "producer":
            if !credits.producers.contains(artistName) { credits.producers.append(artistName) }
        case "co-producer":
            if !credits.producers.contains(artistName) { credits.producers.append(artistName) }

        // Mixing & Engineering
        case "mix", "mixer", "mixing":
            if !credits.mixers.contains(artistName) { credits.mixers.append(artistName) }
        case "engineer", "recording", "audio", "sound engineer":
            if !credits.engineers.contains(artistName) { credits.engineers.append(artistName) }
        case "mastering":
            credits.engineers.append("\(artistName) (Mastering)")

        // Arrangement
        case "arranger", "orchestrator", "instrument arranger":
            if !credits.arrangers.contains(artistName) { credits.arrangers.append(artistName) }

        // Remix
        case "remixer":
            if !credits.remixers.contains(artistName) { credits.remixers.append(artistName) }

        // Performance
        case "performer", "vocal", "instrument", "performing orchestra", "conductor":
            let role: String
            if let attrs = attributes, !attrs.isEmpty {
                role = attrs.map { $0.capitalized }.joined(separator: ", ")
            } else {
                role = type.capitalized
            }
            // Avoid duplicates
            if !credits.performers.contains(where: { $0.name == artistName && $0.role == role }) {
                credits.performers.append((role: role, name: artistName))
            }

        default:
            // Catch-all: add as performer with the type as role
            if let attrs = attributes, !attrs.isEmpty {
                let role = attrs.map { $0.capitalized }.joined(separator: ", ")
                credits.performers.append((role: role, name: artistName))
            } else if !type.isEmpty {
                credits.performers.append((role: type.capitalized, name: artistName))
            }
        }
    }
}
