import Foundation

/// One word of a lyric line, with the slice of that line's duration it is assumed to occupy.
struct LyricWord: Identifiable {
    let id: Int
    /// Includes its trailing whitespace, so concatenating every `text` rebuilds the line
    /// exactly — punctuation, double spaces and all.
    let text: String
    let start: TimeInterval
}

enum LyricWordTiming {
    /// Spread a line's duration across its words in proportion to their length.
    ///
    /// This is **interpolation, not measurement**. Line-level LRC says when a line starts,
    /// never when each word does, so this assumes an even reading pace and gives longer
    /// words proportionally more time. On ordinary sung phrasing it tracks well enough to
    /// read as karaoke; it drifts on held notes, ad-libs and long instrumental tails. That
    /// inexactness is why the feature is opt-in rather than the default.
    ///
    /// Weight is `count + 1` per word: the +1 pays for the space that follows, so a line of
    /// short words doesn't race ahead of one with the same character count in fewer words.
    static func words(in line: String, start: TimeInterval, end: TimeInterval) -> [LyricWord] {
        let pieces = line.split(separator: " ", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return [] }

        let weights = pieces.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        // A zero- or negative-length line can't be divided; light the whole thing at once.
        guard total > 0, end > start else {
            return [LyricWord(id: 0, text: line, start: start)]
        }

        let duration = end - start
        var elapsed: TimeInterval = 0
        var words: [LyricWord] = []
        words.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() {
            // Keep the separator on every word but the last, so joining is lossless.
            let text = index == pieces.count - 1 ? String(piece) : String(piece) + " "
            words.append(LyricWord(id: index, text: text, start: start + elapsed))
            elapsed += duration * (weights[index] / total)
        }
        return words
    }

    /// When the line at `index` gives way to the next one.
    ///
    /// The last line has no successor to bound it, and a track can end on a long outro, so
    /// it falls back to a plain reading time rather than stretching to the end of the song —
    /// which would leave its final word highlighted for minutes.
    static func lineEnd(lines: [LyricsLine], index: Int, fallbackPace: TimeInterval = 0.28) -> TimeInterval? {
        guard lines.indices.contains(index), let start = lines[index].time else { return nil }
        if let next = lines[(index + 1)...].first(where: { $0.time != nil })?.time, next > start {
            return next
        }
        return start + max(1.5, Double(lines[index].text.count) * fallbackPace)
    }
}
