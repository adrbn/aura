import Testing
import Foundation
@testable import Aura

/// When a song names a version, the lyrics shown must be that version's: what marks a
/// version, when a sheet has words of its own, and when the version's sheets outvote the
/// lyrics found.
@Suite("Lyrics version")
struct LyricsVersionTests {

    // MARK: Fixtures

    private let english = [
        "Things are getting hard to ignore", "Every conversation ends in a war",
        "If these walls could talk they'd tell us to break up", "They'd say you're making a big mistake",
        "Everybody here knows that we've been going under", "Lost in the silence of another night",
    ]

    /// The duet: the English chorus, and a French verse the original doesn't have.
    private var duet: [String] {
        english + [
            "J'ai tout gâché bien sûr, je le sais depuis longtemps",
            "À croire à tes histoires, va et viens chorégraphier",
            "À croire que ça me charme de nous voir déchirer",
            "Ces murs pourraient parler, ils diraient qu'on se trompe",
            "Quand la lumière s'éteint, je reste seul avec nos ombres",
        ]
    }

    private func sheet(_ id: Int, _ lines: [String], synced: Bool = true, duration: Double = 217,
                       artist: String = "Dua Lipa, Pierre de Maere",
                       track: String = "These Walls (feat. Pierre de Maere)") -> LyricsVersion.Candidate {
        let text = lines.enumerated().map { synced ? "[00:\(String(format: "%02d", $0.offset)).00] \($0.element)" : $0.element }
            .joined(separator: "\n")
        return LyricsVersion.Candidate(id: id, trackName: track, artistName: artist,
                                       albumName: nil, duration: duration,
                                       plainLyrics: synced ? nil : text, syncedLyrics: synced ? text : nil)
    }

    // MARK: Markers

    @Test("A second artist, credited or featured, marks a version")
    func artistsMarkVersions() {
        #expect(LyricsVersion.markers(title: "These Walls (feat. Pierre de Maere)",
                                      artist: "Dua Lipa • Pierre de Maere") == ["pierre de maere"])
        #expect(LyricsVersion.markers(title: "Despacito (Remix)",
                                      artist: "Luis Fonsi, Daddy Yankee feat. Justin Bieber")
                == ["daddy yankee", "justin bieber", "remix"])
    }

    @Test("A tag after a dash marks a version, a remaster doesn't",
          arguments: [("Roses - Imanbek Remix", ["imanbek remix"]), ("Hey Jude - 2015 Remaster", []),
                      ("Under Pressure (Remastered 2011)", []), ("Bohemian Rhapsody", []),
                      ("Creep (Radio Edit)", []), ("Tous les mêmes (Version acoustique)", ["version acoustique"])])
    func tagsMarkVersions(_ pair: (String, [String])) {
        #expect(LyricsVersion.markers(title: pair.0, artist: "Solo") == pair.1)
    }

    @Test("The base title drops the tags")
    func baseTitleDropsTags() {
        #expect(LyricsVersion.baseTitle("These Walls (feat. Pierre de Maere)") == "These Walls")
        #expect(LyricsVersion.baseTitle("Roses - Imanbek Remix") == "Roses")
    }

    // MARK: Candidates

    @Test("A sheet counts when it names the version, has the title and the length")
    func candidatesNameTheVersion() {
        let markers = ["pierre de maere"]
        let title = "These Walls (feat. Pierre de Maere)"
        #expect(LyricsVersion.isCandidate(sheet(1, duet), title: title, markers: markers, duration: 217))
        #expect(!LyricsVersion.isCandidate(sheet(2, duet, artist: "Dua Lipa", track: "These Walls"),
                                           title: title, markers: markers, duration: 217))
        #expect(!LyricsVersion.isCandidate(sheet(5, duet, track: "Houdini"), title: title, markers: markers, duration: 217))
        #expect(!LyricsVersion.isCandidate(sheet(3, duet, duration: 230), title: title, markers: markers, duration: 217))
        #expect(!LyricsVersion.isCandidate(sheet(4, []), title: title, markers: markers, duration: 217))
        // The title as whole words: "On" is not in "Song".
        #expect(!LyricsVersion.isCandidate(sheet(6, duet, track: "Song (feat. Pierre de Maere)"),
                                           title: "On (feat. Pierre de Maere)", markers: markers, duration: 217))
    }

    // MARK: Differences

    @Test("A verse of its own differs; the same words in other lines don't")
    func differsOnNewWordsOnly() {
        #expect(LyricsVersion.differs(duet, from: english))
        #expect(!LyricsVersion.differs(english, from: duet))
        let resplit = [english.prefix(3).joined(separator: " "), english.suffix(3).joined(separator: " ")]
        #expect(!LyricsVersion.differs(resplit, from: english))
    }

    // MARK: Vote

    @Test("Most of the version's sheets disagreeing replaces the lyrics, with a synced sheet")
    func majorityReplaces() {
        let candidates = [sheet(1, duet, synced: false), sheet(2, duet, duration: 219), sheet(3, duet), sheet(4, english)]
        #expect(LyricsVersion.replacement(among: candidates, for: english, duration: 217)?.id == 3)
    }

    @Test("A mislabelled sheet or two doesn't outvote the version's own lyrics")
    func minorityKeeps() {
        let candidates = [sheet(1, english), sheet(2, duet), sheet(3, duet), sheet(4, duet)]
        #expect(LyricsVersion.replacement(among: candidates, for: duet, duration: 217) == nil)
        #expect(LyricsVersion.replacement(among: [sheet(5, duet)], for: english, duration: 217) == nil)
        #expect(LyricsVersion.replacement(among: [sheet(6, duet), sheet(7, duet), sheet(8, english), sheet(9, english)],
                                          for: english, duration: 217) == nil)
    }
}
