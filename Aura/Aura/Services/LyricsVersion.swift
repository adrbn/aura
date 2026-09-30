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
///
/// A remix keeps the original's words but not its clock, which no vote on words can see: in
/// the sideload build, NetEase is asked for the recording's own timed sheet as well.
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

    // MARK: NetEase

    // Sideload only: the App Store binary carries no trace of NetEase.
    #if !APPSTORE_BUILD

    /// What NetEase's catalogue had for the recording.
    enum RecordingSheet: Equatable {
        /// Its timed lyrics, as LRC, a line per timestamp.
        case found(String)
        case none
        /// NetEase didn't answer: nothing can be concluded.
        case failed
    }

    private struct NetEaseSearch: Decodable {
        struct Result: Decodable {
            let songs: [Track]?
        }

        struct Track: Decodable {
            struct Named: Decodable {
                let name: String?
            }

            let id: Int
            let name: String
            let artists: [Named]?
            let album: Named?
            /// Milliseconds.
            let duration: Int?
        }

        let result: Result?
    }

    private struct NetEaseLyrics: Decodable {
        struct Sheet: Decodable {
            let lyric: String?
        }

        let lrc: Sheet?
    }

    /// The recording's own timed lyrics from NetEase. Its catalogue lists remixes and edits as
    /// released, each with its length, and their sheets follow that recording — the verses a
    /// remix drops, the minute of intro before the first line — where LRCLIB files the
    /// original's timing under the remix: the Kygo remix of *Cut Your Teeth* ran the original's
    /// clock over six and a half minutes. A track counts when it names the song and the
    /// version and lasts as long, to within 3 s.
    static func recordingSheet(title: String, artist: String?, duration: Int?) async -> RecordingSheet {
        let markers = markers(title: title, artist: artist)
        guard !markers.isEmpty, let duration, duration > 0 else { return .none }
        let lead = SongQuery.artistNames(artist ?? "").first ?? ""
        var components = URLComponents(string: "https://music.163.com/api/search/get")
        components?.queryItems = [URLQueryItem(name: "s", value: "\(title) \(lead)"),
                                  URLQueryItem(name: "type", value: "1"),
                                  URLQueryItem(name: "limit", value: "20")]
        guard let url = components?.url, let search: NetEaseSearch = await netEase(url) else { return .failed }
        let tracks = (search.result?.songs ?? []).filter {
            isRecording($0, title: title, markers: markers, duration: duration)
        }
        for track in tracks.prefix(3) {
            guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(track.id)&lv=1"),
                  let lyrics: NetEaseLyrics = await netEase(url) else { return .failed }
            if let sheet = timedSheet(lyrics.lrc?.lyric ?? "", duration: duration) { return .found(sheet) }
        }
        return .none
    }

    private static func isRecording(_ track: NetEaseSearch.Track, title: String, markers: [String],
                                    duration: Int) -> Bool {
        guard let length = track.duration, abs(Double(length) / 1000 - Double(duration)) <= 3 else { return false }
        let name = " " + SongQuery.plainWords(track.name) + " "
        guard name.contains(" " + SongQuery.plainWords(baseTitle(title)) + " ") else { return false }
        let label = " " + SongQuery.plainWords(([track.name, track.album?.name] + (track.artists ?? []).map(\.name))
            .compactMap { $0 }.joined(separator: " ")) + " "
        return markers.contains { label.contains(" \($0) ") }
    }

    /// The sheet's sung lines, one per timestamp, in order — without the credits NetEase puts
    /// first ("作词 : …") — or nil when it isn't timed, stands in for an instrumental, or runs
    /// past the recording's end, the sign of a sheet meant for a longer one.
    static func timedSheet(_ lrc: String, duration: Int) -> String? {
        guard !lrc.contains("纯音乐") else { return nil }
        var lines: [(time: TimeInterval, text: String)] = []
        for row in lrc.components(separatedBy: .newlines) {
            let stamps = row.matches(of: #/\[(\d+):(\d+(?:\.\d+)?)\]/#)
            guard let last = stamps.last else { continue }
            let text = row[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isCredit(text) else { continue }
            for stamp in stamps {
                guard let minutes = Double(stamp.1), let seconds = Double(stamp.2) else { continue }
                lines.append((minutes * 60 + seconds, text))
            }
        }
        lines.sort { $0.time < $1.time }
        guard lines.count >= 4, let end = lines.last?.time, end <= Double(duration) + 2 else { return nil }
        return lines.map { "[\(LyricsOverrides.stamp($0.time))]\($0.text)" }.joined(separator: "\n")
    }

    /// "作词 : Name", "Producer: Name" — a role, then a colon.
    private static func isCredit(_ text: String) -> Bool {
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let role = text[..<colon].trimmingCharacters(in: .whitespaces)
        if role.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return true }
        return role.range(of: #"^(lyrics|lyricist|written|writer|composer|composed|music|producer|produced|arranger|arranged|mix(ed|ing)?|master(ed|ing)?)( by)?$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether the lyrics found already keep the recording's time: most of the sheet's lines
    /// are among them, starting within 2.5 s of it. Lines are told apart by their first words,
    /// since transcriptions of one recording break the same verse in different places.
    static func agrees(_ sheet: String, with current: [LyricsLine]) -> Bool {
        let found = current.compactMap { line in line.time.map { (time: $0, words: opening(line.text)) } }
        let theirs = sheet.components(separatedBy: "\n").compactMap { row -> (time: TimeInterval, words: [Substring])? in
            guard let stamp = row.firstMatch(of: #/^\[(\d+):(\d+(?:\.\d+)?)\]/#),
                  let minutes = Double(stamp.1), let seconds = Double(stamp.2) else { return nil }
            return (minutes * 60 + seconds, opening(String(row[stamp.range.upperBound...])))
        }
        guard !found.isEmpty, !theirs.isEmpty else { return false }
        let kept = theirs.filter { line in
            found.contains { abs($0.time - line.time) <= 2.5 && sameOpening($0.words, line.words) }
        }
        return Double(kept.count) >= 0.6 * Double(theirs.count)
    }

    private static func opening(_ text: String) -> [Substring] {
        Array(SongQuery.plainWords(text).split(separator: " ").prefix(4))
    }

    private static func sameOpening(_ a: [Substring], _ b: [Substring]) -> Bool {
        let count = min(a.count, b.count)
        return count > 0 && a.prefix(count) == b.prefix(count)
    }

    /// Without cookies: once a request sends back the one NetEase sets, it answers every
    /// search with unrelated songs.
    private static let netEaseSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private static func netEase<Answer: Decodable>(_ url: URL) async -> Answer? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await netEaseSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            AppLogger.shared.log("⚠️ Lyrics version check: NetEase failed: \(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    #endif

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
        // The second folder since the check asks NetEase as well: every song gets it once.
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("LyricsVersions", isDirectory: true))
        let directory = caches.appendingPathComponent("LyricsVersions2", isDirectory: true)
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
