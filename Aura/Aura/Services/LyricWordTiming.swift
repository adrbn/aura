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

    /// Seconds per character when the song gives too little to read a pace from.
    static let defaultPace: TimeInterval = 0.09

    /// The pace the song is sung at, in seconds per character, read from its own timings.
    ///
    /// The gap from one line to the next is mostly the time it takes to sing it — except
    /// where a break follows. So the median of gap ÷ length, over lines long enough to be a
    /// fair sample, is the pace this song is actually sung at: slow for a ballad, quick for
    /// rap. Breaks are the outliers, and the median shrugs them off.
    static func pace(of lines: [LyricsLine]) -> TimeInterval {
        var samples: [TimeInterval] = []
        for index in lines.indices {
            guard let start = lines[index].time, lines[index].text.count >= 8,
                  let next = nextStart(after: index, in: lines), next > start
            else { continue }
            samples.append((next - start) / Double(lines[index].text.count))
        }
        guard samples.count >= 3 else { return defaultPace }
        samples.sort()
        return min(max(samples[samples.count / 2], 0.04), 0.3)
    }

    /// When the line at `index` stops being sung.
    ///
    /// Bounded by the next line's start, but no longer defined by it. Stretched all the way
    /// to the next line, a line followed by an instrumental break spread its words across
    /// the break: they lit slower than the voice sang them, and the focus — which judged the
    /// line finished at a reading pace — moved on while its last words were still dark.
    ///
    /// The sung length comes from the song's own pace, with a fifth of slack, so a line sung
    /// a little slower than the song's typical one still runs to the next: only a line
    /// followed by a genuine break ends before it.
    static func lineEnd(lines: [LyricsLine], index: Int) -> TimeInterval? {
        guard lines.indices.contains(index), let start = lines[index].time else { return nil }
        let sung = start + max(1.5, Double(lines[index].text.count) * pace(of: lines) * 1.2)
        if let next = nextStart(after: index, in: lines), next > start {
            return min(next, sung)
        }
        // The last line has no successor to bound it, and a track can end on a long outro:
        // stretched to the end of the song, its final word would stay lit for minutes.
        return sung
    }

    /// The words of the line at `index` with their timings: the server's own when it sent
    /// them (OpenSubsonic songLyrics v2 — measured, not guessed), interpolated across
    /// `lineEnd` otherwise.
    ///
    /// The one source for both the highlight and `focusIndex`, so the focus can never leave
    /// a line on a different idea of its end than the one its words were drawn with.
    static func timedWords(lines: [LyricsLine], index: Int) -> [LyricWord]? {
        guard lines.indices.contains(index) else { return nil }
        let line = lines[index]
        if let real = line.words, !real.isEmpty { return real }
        guard let start = line.time, let end = lineEnd(lines: lines, index: index) else { return nil }
        let interpolated = Self.words(in: line.text, start: start, end: end)
        return interpolated.isEmpty ? nil : interpolated
    }

    /// When the line at `index` has been sung: its last measured word plus a beat when the
    /// server timed its words, the end of its interpolated words otherwise.
    static func lineFinish(lines: [LyricsLine], index: Int) -> TimeInterval? {
        guard lines.indices.contains(index) else { return nil }
        if let lastCue = lines[index].words?.last { return lastCue.start + 0.6 }
        return lineEnd(lines: lines, index: index)
    }

    /// Which line holds the focus at `time`, given `last`, the line that started most
    /// recently.
    ///
    /// Across a real break the focus moves to the coming line early — during an
    /// instrumental there should be something to look at, not a sheet gone dim. It moves
    /// halfway through the break: the line just sung keeps the stage for the first half, the
    /// coming one is introduced for the second. Moving at the very end of the line snatched
    /// it away the instant it was done — and, when that end was misjudged, before its last
    /// words had lit at all.
    ///
    /// On an ordinary line the next one arrives about when this one ends, and an early move
    /// would only look twitchy, so it applies to breaks longer than two seconds.
    static func focusIndex(lines: [LyricsLine], after last: Int?, at time: TimeInterval) -> Int? {
        guard let index = last, index + 1 < lines.count,
              let nextStart = lines[index + 1].time,
              let finished = lineFinish(lines: lines, index: index)
        else { return last }
        let breakLength = nextStart - finished
        guard breakLength > 2.0, time >= finished + breakLength / 2 else { return index }
        return index + 1
    }

    private static func nextStart(after index: Int, in lines: [LyricsLine]) -> TimeInterval? {
        lines[(index + 1)...].first(where: { $0.time != nil })?.time
    }
}
