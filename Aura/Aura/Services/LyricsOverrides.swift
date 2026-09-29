import Foundation

/// Lyrics timed by hand on this device, one `.lrc` per song. They come before every other
/// source, so a song synced once stays synced; going back to the original is removing it.
enum LyricsOverrides {
    struct Line {
        let time: TimeInterval
        let text: String
        /// Each word's start, when the lyrics had them: kept, moved with their line.
        var words: [LyricWord]? = nil
    }

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = base.appendingPathComponent("LyricsOverrides", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(_ songId: String) -> URL? {
        // An id can hold characters a file name can't.
        let name = songId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? songId
        return folder?.appendingPathComponent(name).appendingPathExtension("lrc")
    }

    static func lrc(for songId: String) -> String? {
        file(songId).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static func has(_ songId: String) -> Bool {
        file(songId).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static func save(_ lines: [Line], for songId: String) throws {
        guard let url = file(songId) else { throw CocoaError(.fileNoSuchFile) }
        try lrc(lines).write(to: url, atomically: true, encoding: .utf8)
    }

    static func remove(_ songId: String) {
        guard let url = file(songId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// "[01:23.45]words", a line each — Enhanced LRC, "<01:23.45>word", where the words are
    /// timed, which Navidrome reads as well.
    static func lrc(_ lines: [Line]) -> String {
        lines.map { line in
            guard let words = line.words, !words.isEmpty else { return "[\(stamp(line.time))]\(line.text)" }
            return "[\(stamp(line.time))]" + words.map { "<\(stamp($0.start))>\($0.text)" }.joined()
        }
        .joined(separator: "\n")
    }

    /// Reads back what `lrc(_:)` writes.
    static func parse(_ lrc: String) -> [LyricsLine] {
        lrc.components(separatedBy: .newlines).compactMap { row -> LyricsLine? in
            guard let tag = row.firstMatch(of: lineTag), let time = seconds(tag.1, tag.2) else { return nil }
            let body = row[tag.range.upperBound...]
            let marks = body.matches(of: wordTag)
            guard !marks.isEmpty else {
                let text = body.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : LyricsLine(time: time, text: text)
            }
            let words = marks.enumerated().compactMap { index, mark -> LyricWord? in
                let end = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
                guard let start = seconds(mark.1, mark.2) else { return nil }
                return LyricWord(id: index, text: String(body[mark.range.upperBound..<end]), start: start)
            }
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : LyricsLine(time: time, text: text, words: words)
        }
    }

    private nonisolated(unsafe) static let lineTag = /^\[(\d+):(\d+(?:\.\d+)?)\]/
    private nonisolated(unsafe) static let wordTag = /<(\d+):(\d+(?:\.\d+)?)>/

    private static func seconds(_ minutes: Substring, _ seconds: Substring) -> TimeInterval? {
        guard let minutes = Double(minutes), let seconds = Double(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    static func stamp(_ time: TimeInterval) -> String {
        let hundredths = Int((max(0, time) * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }
}

/// Where each line starts once some have been tapped. Lyrics already timed keep their own
/// rhythm in sections: a tapped line moves by what it measured, and so does every line after
/// it up to the next tap — a pause the lyrics didn't know about is one more tap, after it,
/// and what came before stays put. Lines above the first tap follow it too, unless they were
/// timed by hand already. Lyrics with no timing get it from the taps alone, the lines between
/// two taps spread evenly.
struct LyricsRetiming {
    let found: [TimeInterval?]
    /// Lines above the first tap keep their time: they were put right by hand before.
    var keepsLinesAbove = false
    var anchors: [Int: TimeInterval] = [:]
    /// Moves the lines no tap moves — all of them before the first — and, with no timing, the
    /// taps along with them.
    var offset: TimeInterval = 0

    var isTimed: Bool { !found.isEmpty && found.allSatisfy { $0 != nil } }

    var times: [TimeInterval?] {
        let marks = anchors.keys.sorted()
        var floor: TimeInterval = 0
        return found.indices.map { index -> TimeInterval? in
            guard let time = isTimed ? moved(index) : spread(index, marks: marks) else { return nil }
            // Never a line starting before the one above it.
            floor = max(floor, time)
            return floor
        }
    }

    var isComplete: Bool { !anchors.isEmpty && !times.contains { $0 == nil } }

    /// Whether there's anything to save.
    var hasChanges: Bool { isTimed ? !anchors.isEmpty || offset != 0 : isComplete }

    /// The tap a line moves with: the last one at or above it, or the first below.
    func section(of index: Int) -> Int? {
        let marks = anchors.keys.sorted()
        if let above = marks.last(where: { $0 <= index }) { return above }
        return keepsLinesAbove ? nil : marks.first
    }

    /// Moves the line's section — every line, before any tap or with no timing — by `step`.
    mutating func nudge(by step: TimeInterval, at index: Int) {
        if isTimed, let mark = section(of: index), let time = anchors[mark] {
            anchors[mark] = max(0, time + step)
        } else {
            offset += step
        }
    }

    private func moved(_ index: Int) -> TimeInterval? {
        guard let time = found[index] else { return nil }
        if let tapped = anchors[index] { return tapped }
        if let mark = section(of: index), let tapped = anchors[mark], let start = found[mark] {
            return time + tapped - start
        }
        return time + offset
    }

    private func spread(_ index: Int, marks: [Int]) -> TimeInterval? {
        if let tapped = anchors[index] { return tapped + offset }
        guard let after = marks.firstIndex(where: { $0 > index }), after > 0 else { return nil }
        let (a, b) = (marks[after - 1], marks[after])
        let (start, end) = (anchors[a] ?? 0, anchors[b] ?? 0)
        return start + (end - start) * Double(index - a) / Double(b - a) + offset
    }
}
