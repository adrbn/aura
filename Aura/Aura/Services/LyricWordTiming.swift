import Foundation

/// One word of a lyric line, with the slice of that line's duration it is assumed to occupy.
struct LyricWord: Identifiable {
    let id: Int
    /// Includes its trailing whitespace, so concatenating every `text` rebuilds the line
    /// exactly — punctuation, double spaces and all.
    let text: String
    let start: TimeInterval
    /// Set on the words of a line marked as sung several times ("… x4"): `start` is within
    /// the first pass, and the highlight starts over at each pass.
    var cycle: LyricRepeat? = nil
    /// The "x4" itself, drawn small after the phrase.
    var marker = false

    /// Seconds since this word was reached in the pass being sung at `time`.
    func elapsed(at time: TimeInterval) -> TimeInterval {
        guard let cycle else { return time - start }
        if let heard = cycle.starts, let first = heard.first {
            // The passes as heard: each word counts from the start of the one being sung.
            let pass = heard.last(where: { $0 <= time }) ?? first
            return time - (pass - first) - start
        }
        let pass = min(max(floor((time - cycle.lineStart) / cycle.period), 0), Double(cycle.passes - 1))
        return time - pass * cycle.period - start
    }
}

/// A line sung `passes` times in a row, each pass `period` seconds long.
struct LyricRepeat {
    let lineStart: TimeInterval
    let period: TimeInterval
    let passes: Int
    /// Where each pass starts, when they were heard: then the passes needn't be even.
    var starts: [TimeInterval]? = nil
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
    static func words(in line: String, start: TimeInterval, end: TimeInterval,
                      phraseLength: TimeInterval? = nil) -> [LyricWord] {
        // "… x4": the phrase is sung four times, so its words light four times over, and the
        // marker itself lights when the last pass begins.
        if let marked = repeated(line), end > start {
            let period = (end - start) / Double(marked.passes)
            let cycle = LyricRepeat(lineStart: start, period: period, passes: marked.passes)
            // Each pass sings the phrase at its own pace at the top of its share of the time.
            var words = Self.words(in: marked.phrase, start: start, end: start + min(period, phraseLength ?? period))
                .map { LyricWord(id: $0.id, text: $0.text, start: $0.start, cycle: cycle) }
            if let last = words.popLast() {
                words.append(LyricWord(id: last.id, text: last.text + " ", start: last.start, cycle: cycle))
            }
            words.append(LyricWord(id: words.count, text: marked.marker,
                                   start: start + period * Double(marked.passes - 1), marker: true))
            return words
        }
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

    /// A line ending in a repeat marker — "x4", "(x4)", "[4x]", "×4" — split into the phrase
    /// and the marker, with the number of times the phrase is sung (2 to 9).
    static func repeated(_ line: String) -> (phrase: String, marker: String, passes: Int)? {
        let pattern = #"\s+([(\[]?\s*(?:[x×]\s?([2-9])|([2-9])\s?[x×])\s*[)\]]?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let whole = Range(match.range, in: line), let marker = Range(match.range(at: 1), in: line)
        else { return nil }
        let digit = [2, 3].compactMap { Range(match.range(at: $0), in: line) }.first.flatMap { Int(line[$0]) }
        let phrase = String(line[..<whole.lowerBound])
        guard let passes = digit, !phrase.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (phrase, String(line[marker]), passes)
    }

    /// Words timed by ear or by hand on a "x4" line: they time the first pass, the next
    /// passes share what's left until the next line, and the marker stays small.
    private static func repeatedPasses(of real: [LyricWord], lines: [LyricsLine], index: Int) -> [LyricWord]? {
        guard let marked = repeated(lines[index].text), let start = lines[index].time,
              let end = lineEnd(lines: lines, index: index), end > start else { return nil }
        let markerText = marked.marker.trimmingCharacters(in: .whitespaces)
        // Empty words after the marker carry the later passes' starts, as listening heard them.
        let heard = real.filter { $0.text.isEmpty }.map(\.start)
        var sung = real.filter { !$0.text.isEmpty }
        if sung.last?.text.trimmingCharacters(in: .whitespaces) == markerText { sung.removeLast() }
        guard let first = sung.first, let last = sung.last else { return nil }
        let period = max((end - first.start) / Double(marked.passes), last.start - first.start + 0.6)
        let starts = heard.isEmpty ? nil : [first.start] + heard.sorted()
        let cycle = LyricRepeat(lineStart: first.start, period: period, passes: marked.passes, starts: starts)
        var words = sung.map { LyricWord(id: $0.id, text: $0.text, start: $0.start, cycle: cycle) }
        if let tail = words.popLast() {
            words.append(LyricWord(id: tail.id, text: tail.text.hasSuffix(" ") ? tail.text : tail.text + " ",
                                   start: tail.start, cycle: cycle))
        }
        words.append(LyricWord(id: (real.last?.id ?? 0) + 1, text: marked.marker,
                               start: starts?.last ?? first.start + period * Double(marked.passes - 1), marker: true))
        return words
    }

    /// Characters actually sung in a line: a repeated phrase counts once per pass.
    private static func sungLength(_ line: String) -> Int {
        guard let marked = repeated(line) else { return line.count }
        return marked.phrase.count * marked.passes
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
            // A "x4" line says nothing reliable about pace: files time it as one pass or as all four.
            guard let start = lines[index].time, lines[index].text.count >= 8, repeated(lines[index].text) == nil,
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
        // A "x4" line holds until the next one: its passes fill the time between.
        if repeated(lines[index].text) != nil, let next = nextStart(after: index, in: lines), next > start {
            return next
        }
        let sung = start + max(1.5, Double(sungLength(lines[index].text)) * pace(of: lines) * 1.2)
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
        if let real = line.words, !real.isEmpty {
            return repeatedPasses(of: real, lines: lines, index: index) ?? real
        }
        guard let start = line.time, let end = lineEnd(lines: lines, index: index) else { return nil }
        let phrase = repeated(line.text).map { max(1.5, Double($0.phrase.count) * pace(of: lines) * 1.2) }
        let interpolated = Self.words(in: line.text, start: start, end: end, phraseLength: phrase)
        return interpolated.isEmpty ? nil : interpolated
    }

    /// When the line at `index` has been sung: its last measured word plus a beat when the
    /// server timed its words, the end of its interpolated words otherwise.
    static func lineFinish(lines: [LyricsLine], index: Int) -> TimeInterval? {
        guard lines.indices.contains(index) else { return nil }
        if let lastCue = lines[index].words?.last, repeated(lines[index].text) == nil { return lastCue.start + 0.6 }
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
