import Foundation

/// Makes sure the lyrics on screen are this recording's, not the original's.
///
/// A duet, a remix or a translated version keeps the original's title, and a lyrics source
/// matching on title and lead artist hands back the original's words: *These Walls* with
/// Pierre de Maere came back without his French verse, whatever was tried. When a song names
/// such a version — a second artist, a tag in brackets — LRCLIB is asked for that version,
/// and its sheets vote: when most of them carry words the lyrics found don't have, the
/// lyrics found were for another version, and the best of those sheets replaces them.
///
/// The vote is what makes this safe. LRCLIB has mislabelled entries — the original's words
/// filed under the duet — and a single match would sometimes pick one of them.
enum LyricsVersion {

    /// One sheet from LRCLIB, as its search returns it.
    struct Candidate: Decodable, Hashable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let plainLyrics: String?
        let syncedLyrics: String?

        var lines: [String] {
            let text = [syncedLyrics, plainLyrics].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            return text.components(separatedBy: "\n").map { line in
                line.replacingOccurrences(of: #"^\s*(\[[^\]]*\])+"#, with: "", options: .regularExpression)
            }
        }

        var isSynced: Bool { syncedLyrics?.isEmpty == false }
    }

    // MARK: Rules

    /// Tags that name a pressing rather than a version: the words are the original's.
    private static let neutralTag = #"^(\d{4} )?(remaster(ed)?|explicit|clean|mono|stereo|radio edit|deluxe( edition)?|bonus track|single version|album version|original mix)( \d{4})?( version)?$"#

    /// What names this song's version: every artist after the first, whether credited or
    /// featured in the title, and the title's other tags — "Remix", "Version française".
    /// Empty for a plain song, which then needs no checking.
    static func markers(title: String, artist: String?) -> [String] {
        var names = Array(SongQuery.artistNames(artist ?? "").dropFirst())
        var tags: [String] = []
        for tag in brackets(in: title) + dashTag(in: title) {
            if let featured = tag.firstMatch(of: #/(?i)^\s*(feat\.?|ft\.?|featuring|with)\s+(.+)$/#) {
                names += SongQuery.artistNames(String(featured.2))
            } else {
                tags.append(tag)
            }
        }
        var seen = Set<String>()
        return (names + tags).map(SongQuery.plainWords)
            .filter { !$0.isEmpty && $0.range(of: neutralTag, options: .regularExpression) == nil }
            .filter { seen.insert($0).inserted }
    }

    /// The title without its tags: "These Walls (feat. Pierre de Maere)" is "These Walls".
    static func baseTitle(_ title: String) -> String {
        let bare = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return (bare.range(of: " - ").map { String(bare[..<$0.lowerBound]) } ?? bare)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func brackets(in title: String) -> [String] {
        title.matches(of: #/[\(\[]([^\)\]]+)[\)\]]/#).map { String($0.1) }
    }

    private static func dashTag(in title: String) -> [String] {
        guard let range = title.range(of: " - ") else { return [] }
        let tag = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? [] : [tag]
    }

    /// Whether a sheet is for the version the markers name, and the same song and length.
    static func isCandidate(_ candidate: Candidate, title: String, markers: [String], duration: Int?) -> Bool {
        guard !candidate.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        if let duration, duration > 0 {
            guard let length = candidate.duration, abs(length - Double(duration)) <= 5 else { return false }
        }
        // Whole words, as for the markers: "On" is not in "Song for Us".
        let track = " " + SongQuery.plainWords(candidate.trackName ?? "") + " "
        guard track.contains(" " + SongQuery.plainWords(baseTitle(title)) + " ") else { return false }
        let label = " " + SongQuery.plainWords([candidate.artistName, candidate.trackName, candidate.albumName]
            .compactMap { $0 }.joined(separator: " ")) + " "
        return markers.contains { label.contains(" \($0) ") }
    }

    /// Words of three letters or more — short ones are the ad-libs and articles every
    /// transcription spells its own way.
    static func vocabulary(_ lines: [String]) -> Set<String> {
        Set(lines.flatMap { SongQuery.plainWords($0).split(separator: " ").map(String.init) }
            .filter { $0.count >= 3 })
    }

    /// Whether a sheet has words the current lyrics lack — a verse of its own, not the same
    /// verse split into other lines, which is how transcriptions of one recording differ.
    static func differs(_ candidate: [String], from current: [String]) -> Bool {
        let theirs = vocabulary(candidate)
        let new = theirs.subtracting(vocabulary(current))
        return new.count >= 10 && Double(new.count) >= 0.15 * Double(theirs.count)
    }

    /// The sheet to show instead of `current`, or nil when the lyrics found are the version's
    /// own. Replaced only when most of the version's sheets disagree with them.
    static func replacement(among candidates: [Candidate], for current: [String],
                            duration: Int?) -> Candidate? {
        let disagreeing = candidates.filter { differs($0.lines, from: current) }
        guard disagreeing.count >= 2, disagreeing.count * 2 > candidates.count else { return nil }
        let target = Double(duration ?? 0)
        return disagreeing.min { a, b in
            if a.isSynced != b.isSynced { return a.isSynced }
            return abs((a.duration ?? 0) - target) < abs((b.duration ?? 0) - target)
        }
    }

    // MARK: LRCLIB

    /// The version's sheets on LRCLIB; nil when either search failed — LRCLIB answers 503
    /// under load — so that nothing is concluded, and kept, from half the sheets.
    static func candidates(title: String, artist: String?, duration: Int?) async -> [Candidate]? {
        let markers = markers(title: title, artist: artist)
        guard !markers.isEmpty else { return [] }
        let lead = SongQuery.artistNames(artist ?? "").first ?? ""
        async let titled = search([URLQueryItem(name: "track_name", value: title),
                                   URLQueryItem(name: "artist_name", value: lead)])
        async let versioned = search([URLQueryItem(name: "q",
                                                   value: ([baseTitle(title)] + markers).joined(separator: " "))])
        guard let byTitle = await titled, let byVersion = await versioned else { return nil }
        var seen = Set<Int>()
        return (byTitle + byVersion)
            .filter { seen.insert($0.id).inserted }
            .filter { isCandidate($0, title: title, markers: markers, duration: duration) }
    }

    private static func search(_ query: [URLQueryItem]) async -> [Candidate]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = query
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Aura/1.0.0 (https://github.com/adrbn)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode([Candidate].self, from: data)
        } catch {
            AppLogger.shared.log("⚠️ Lyrics version check: LRCLIB search failed: \(error.localizedDescription)",
                                 level: .debug)
            return nil
        }
    }

    // MARK: Verdicts

    /// What the check concluded for a song, kept so it runs once per song.
    enum Verdict: Codable, Equatable {
        /// The lyrics the usual sources find are the version's own.
        case kept
        /// They weren't; these are.
        case replaced(synced: String?, plain: String?)
    }

    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("LyricsVersions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func file(for songId: String) -> URL? {
        // The id comes from the server: nothing in it may reach the path unescaped.
        guard let safe = songId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return directory?.appendingPathComponent("\(safe).json")
    }

    static func verdict(for songId: String) -> Verdict? {
        guard let file = file(for: songId), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Verdict.self, from: data)
    }

    static func forget(_ songId: String) {
        guard let file = file(for: songId) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    static func store(_ verdict: Verdict, for songId: String) {
        guard let file = file(for: songId), let data = try? JSONEncoder().encode(verdict) else { return }
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            AppLogger.shared.log("⚠️ Lyrics version check: couldn't save the verdict: \(error.localizedDescription)",
                                 level: .debug)
        }
    }
}
