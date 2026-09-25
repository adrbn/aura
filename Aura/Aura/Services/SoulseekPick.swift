import Foundation

#if !APPSTORE_BUILD

/// Picks what to download for a release from a Soulseek search, without asking: the folder
/// that holds the release's tracks, in the best sound, from the peer likeliest to send it now.
///
/// Pure — search results in, a ranked choice out. `ReleaseFetcher` does the talking.
enum SoulseekPick {

    /// A track of the release, as Deezer lists it.
    struct Track: Codable, Hashable {
        let id: Int
        let title: String
        let seconds: Int?
        let position: Int?
    }

    /// How a file sounds, best last.
    enum Quality: Int, Comparable {
        case fair, good, high, lossless

        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    /// One peer's folder, with its file for each track it has.
    struct Candidate: Hashable {
        let username: String
        let directory: String
        /// Track id → the file that is that track.
        let files: [Int: SlskdFile]
        /// The worst of its files: a folder is as good as its weakest track.
        let quality: Quality
        let hasFreeSlot: Bool
        let queueLength: Int
        let score: Double

        var bytes: Int64 { files.values.reduce(0) { $0 + $1.size } }
        /// "FLAC", "MP3 320"… — what the folder was picked in.
        var format: String {
            let file = files.values.first
            let ext = file?.fileExtension ?? "?"
            guard quality != .lossless, let rate = files.values.compactMap(\.bitRate).min() else { return ext }
            return "\(ext) \(rate)"
        }
    }

    /// A file this far from Deezer's length is another cut of the song.
    static let durationTolerance = 5

    /// Words that make a file a different recording from the title that lacks them.
    private static let versionWords: Set<String> = [
        "remix", "rmx", "live", "acoustic", "instrumental", "demo", "karaoke", "extended", "sped",
        "slowed", "acapella", "rework", "vip", "bootleg", "reprise", "unplugged", "cover",
    ]

    // MARK: Search

    /// What to ask Soulseek, broadest useful first. Soulseek wants every word in a file's path,
    /// so bracketed extras ("Deluxe", "feat. …") would only narrow it; accents stay as written
    /// in one query and are dropped in the next, since shared files are named either way.
    static func queries(artist: String, title: String) -> [String] {
        let name = SongQuery.primaryArtist(artist)
        let bare = SongQuery.cleanTitle(title)
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        let asWritten = spaced("\(name) \(bare)")
        let folded = words("\(name) \(bare)").joined(separator: " ")
        let titleOnly = words(bare)
        var list = [asWritten, folded]
        // A title of a single short word would match half of Soulseek on its own.
        if titleOnly.count >= 2 { list.append(titleOnly.joined(separator: " ")) }
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Punctuation to spaces, letters kept exactly as written.
    private static func spaced(_ s: String) -> String {
        s.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    // MARK: Picking

    /// How many of `count` tracks a folder must hold: all of a short release, three in four
    /// of a longer one — a folder missing a bonus track still beats no album.
    static func required(of count: Int) -> Int {
        max(1, Int((Double(count) * 0.75).rounded(.up)))
    }

    /// Every folder that holds enough of the release, best first.
    static func candidates(for tracks: [Track], artist: String, album: String,
                           in responses: [SlskdSearchResponse]) -> [Candidate] {
        guard !tracks.isEmpty else { return [] }
        let needed = required(of: tracks.count)
        let artistWords = Set(words(SongQuery.primaryArtist(artist)).filter { $0.count >= 2 })
        let context = artistWords.union(words(album))
        var found: [Candidate] = []
        for response in responses {
            let open = response.files.filter { $0.isLocked != true }
            for (directory, files) in Dictionary(grouping: open, by: { Self.directory(of: $0.filename) }) {
                // The search matched every word somewhere in the path; the artist must be
                // there too, or a same-titled song by someone else would pass.
                let path = Set(words(directory)).union(files.flatMap { words(stem(of: $0)) })
                guard artistWords.isEmpty || !artistWords.isDisjoint(with: path) else { continue }
                let chosen = assign(tracks, files: files, context: context)
                guard chosen.count >= needed,
                      let quality = chosen.values.compactMap(Self.quality(of:)).min() else { continue }
                let bytes = chosen.values.reduce(Int64(0)) { $0 + $1.size }
                found.append(Candidate(
                    username: response.username, directory: directory, files: chosen, quality: quality,
                    hasFreeSlot: response.hasFreeUploadSlot ?? false, queueLength: response.queueLength ?? 0,
                    score: Self.score(quality: quality, coverage: Double(chosen.count) / Double(tracks.count),
                                 hasFreeSlot: response.hasFreeUploadSlot ?? false,
                                 uploadSpeed: response.uploadSpeed ?? 0,
                                 queueLength: response.queueLength ?? 0, bytes: bytes)))
            }
        }
        return found.sorted { $0.score > $1.score }
    }

    /// Completeness first, then sound, then how soon it arrives: a free slot starts now, and
    /// a FLAC album at a crawl loses to an MP3 320 that lands in a minute.
    static func score(quality: Quality, coverage: Double, hasFreeSlot: Bool, uploadSpeed: Int,
                      queueLength: Int, bytes: Int64) -> Double {
        let seconds = Double(bytes) / Double(max(uploadSpeed, 50_000))
        return coverage * 200
            + Double(quality.rawValue) * 25
            + (hasFreeSlot ? 60 : -Double(min(queueLength, 60)))
            - min(seconds / 6, 60)
    }

    /// Each track's file in a folder: one that carries the title, no version the title lacks,
    /// and the track's length — and, between two such, the one at the track's own number.
    static func assign(_ tracks: [Track], files: [SlskdFile], context: Set<String>) -> [Int: SlskdFile] {
        let audio = files.filter { quality(of: $0) != nil }
        var used = Set<String>()
        var chosen: [Int: SlskdFile] = [:]
        for track in tracks {
            let fitting = audio.filter { !used.contains($0.filename) && fits($0, track, context: context) }
            guard let best = fitting.max(by: { rank($0, for: track) < rank($1, for: track) }) else { continue }
            used.insert(best.filename)
            chosen[track.id] = best
        }
        return chosen
    }

    static func fits(_ file: SlskdFile, _ track: Track, context: Set<String>) -> Bool {
        let named = Set(words(stem(of: file)))
        let core = words(SongQuery.cleanTitle(track.title))
        guard !core.isEmpty, Set(core).isSubset(of: named) else { return false }
        let allowed = Set(words(track.title)).union(context)
        guard named.intersection(versionWords).isSubset(of: allowed) else { return false }
        if let seconds = track.seconds, seconds > 0, let length = file.length, length > 0 {
            return abs(seconds - length) <= durationTolerance
        }
        return true
    }

    private static func rank(_ file: SlskdFile, for track: Track) -> Int {
        let sound = quality(of: file)?.rawValue ?? 0
        let atItsNumber = track.position != nil && leadingNumber(stem(of: file)) == track.position
        return sound + (atItsNumber ? 10 : 0)
    }

    /// Nil for what isn't worth fetching: other formats, and lossy files below 192 kbps.
    static func quality(of file: SlskdFile) -> Quality? {
        let rate = file.bitRate ?? 0
        switch file.fileExtension.lowercased() {
        case "flac":
            return .lossless
        case "mp3":
            if file.bitRate == nil { return .fair }
            return rate >= 315 ? .high : rate >= 240 ? .good : rate >= 192 ? .fair : nil
        case "m4a":
            // ALAC and AAC share the container; only the bitrate tells them apart.
            return rate >= 500 ? .lossless : rate >= 240 ? .good : rate >= 160 ? .fair : nil
        case "aac", "ogg", "opus":
            return rate >= 240 ? .good : rate >= 160 ? .fair : nil
        default:
            return nil
        }
    }

    // MARK: Text

    /// Folded words: case, accents and ligatures gone, apostrophes closed up ("Don't" → "dont").
    static func words(_ s: String) -> [String] {
        SongQuery.fold(s)
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "'", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The file's name without its folder or extension.
    static func stem(of file: SlskdFile) -> String {
        let name = file.displayName
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// The folder a path sits in, whichever separator the peer's system uses.
    static func directory(of path: String) -> String {
        guard let cut = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "" }
        return String(path[..<cut])
    }

    /// The track number a file name leads with: "03 - Title", "1-03 Title", "03. Title".
    static func leadingNumber(_ stem: String) -> Int? {
        guard let match = stem.prefixMatch(of: #/\s*(?:\d{1,2}[-.])?(\d{1,3})(?!\d)/#) else { return nil }
        return Int(match.1)
    }
}

extension SoulseekPick.Track {
    init(_ track: DeezerTrack) {
        self.init(id: track.id, title: track.title, seconds: track.duration, position: track.track_position)
    }
}

#endif
