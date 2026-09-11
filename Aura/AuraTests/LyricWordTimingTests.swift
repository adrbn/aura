import Testing
import Foundation
@testable import Aura

/// Word timing for lyrics that only say when each line starts.
///
/// A line followed by an instrumental break used to be treated as lasting until the next
/// line: its words were spread across the break, lighting slower than the voice sang them,
/// while the focus judged the line finished at a reading pace and moved on with its last
/// words still dark. These pin the one end the words and the focus now agree on.
@Suite("Lyric word timing")
struct LyricWordTimingTests {

    /// A lyric line of roughly `length` characters.
    private func text(_ length: Int) -> String {
        String(String(repeating: "lala ", count: length / 5 + 1).prefix(length))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lines at the given start times, all the same length.
    private func lines(at times: [TimeInterval], length: Int = 40) -> [LyricsLine] {
        times.map { LyricsLine(time: $0, text: text(length)) }
    }

    /// A line every three seconds, except the fourth (index 3), which is followed by a
    /// thirteen-second break.
    private var songWithABreak: [LyricsLine] { lines(at: [0, 3, 6, 9, 22, 25, 28, 31]) }

    // MARK: Pace

    @Test("a ballad is read as slow and a rap as quick")
    func paceFollowsTheSong() {
        let ballad = lines(at: (0..<8).map { Double($0) * 6 })
        let rap = lines(at: (0..<8).map { Double($0) * 2 })
        #expect(LyricWordTiming.pace(of: ballad) > LyricWordTiming.pace(of: rap) * 2)
    }

    @Test("a break does not change the song's pace")
    func breakIsAnOutlier() {
        let steady = lines(at: [0, 3, 6, 9, 12, 15, 18, 21])
        #expect(LyricWordTiming.pace(of: songWithABreak) == LyricWordTiming.pace(of: steady))
    }

    @Test("too little to read falls back to the default pace")
    func defaultPace() {
        #expect(LyricWordTiming.pace(of: lines(at: [0, 3])) == LyricWordTiming.defaultPace)
    }

    // MARK: Line end

    @Test("a line followed by a break ends when it is sung, not when the next begins")
    func breakEndsEarly() throws {
        let end = try #require(LyricWordTiming.lineEnd(lines: songWithABreak, index: 3))
        #expect(end > 9)
        #expect(end < 22 - 2)
    }

    @Test("an ordinary line runs all the way to the next one")
    func ordinaryRunsToNext() {
        #expect(LyricWordTiming.lineEnd(lines: songWithABreak, index: 1) == 6)
    }

    @Test("the last line still ends, rather than lasting to the end of the song")
    func lastLineEnds() throws {
        let end = try #require(LyricWordTiming.lineEnd(lines: songWithABreak, index: 7))
        #expect(end > 31)
        #expect(end < 31 + 10)
    }

    // MARK: Focus

    @Test("the focus never leaves a line before its last word has lit")
    func neverLeavesEarly() throws {
        let words = try #require(LyricWordTiming.timedWords(lines: songWithABreak, index: 3))
        let lastWord = try #require(words.last).start
        for step in 0..<260 {
            let time = 9 + Double(step) * 0.05
            if LyricWordTiming.focusIndex(lines: songWithABreak, after: 3, at: time) == 4 {
                #expect(time >= lastWord)
            }
        }
    }

    @Test("across a break, the focus moves halfway between the line's end and the next")
    func movesHalfway() throws {
        let finished = try #require(LyricWordTiming.lineFinish(lines: songWithABreak, index: 3))
        let halfway = finished + (22 - finished) / 2
        #expect(LyricWordTiming.focusIndex(lines: songWithABreak, after: 3, at: halfway - 0.1) == 3)
        #expect(LyricWordTiming.focusIndex(lines: songWithABreak, after: 3, at: halfway + 0.1) == 4)
    }

    @Test("an ordinary line keeps the focus until the next one starts")
    func ordinaryKeepsFocus() {
        for step in 0..<60 {
            let time = 3 + Double(step) * 0.05
            #expect(LyricWordTiming.focusIndex(lines: songWithABreak, after: 1, at: time) == 1)
        }
    }

    // MARK: Measured words

    @Test("the server's own word timings are used as they are")
    func measuredWordsWin() throws {
        let cues = [LyricWord(id: 0, text: "hold ", start: 9), LyricWord(id: 1, text: "on", start: 10)]
        var song = songWithABreak
        song[3] = LyricsLine(time: 9, text: "hold on", words: cues)
        let words = try #require(LyricWordTiming.timedWords(lines: song, index: 3))
        #expect(words.map(\.start) == [9, 10])
        #expect(LyricWordTiming.lineFinish(lines: song, index: 3) == 10.6)
    }
}
