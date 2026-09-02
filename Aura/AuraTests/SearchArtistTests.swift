import Testing
import Foundation
@testable import Aura

/// Navidrome publishes every multi-artist credit as an artist of its own, so a library
/// with one Avicii record and three collaborations holds four "artists" whose names all
/// begin with the same word. `Fuzzy.score` gives a perfect 1.0 to any name that merely
/// *contains* the query, so all four tie — and picking the first of them narrowed the
/// song results to one duo. Searching "Avicii" returned nothing but "Avicii, someone".
@Suite("Search — principal artist")
struct SearchArtistTests {

    private func artist(_ name: String) throws -> Artist {
        try JSONDecoder().decode(
            Artist.self,
            from: Data(#"{"id":"\#(name)","name":"\#(name)"}"#.utf8))
    }

    @Test("the standalone artist wins over its collaborations")
    func standaloneBeatsCollaborations() throws {
        // Deliberately listed with the collaborations first — that ordering is the bug.
        let artists = try ["Avicii, CAZZETTE", "Avicii, Nicky Romero", "Avicii"].map(artist)
        #expect(SearchIndex.principalArtist(for: "Avicii", among: artists)?.name == "Avicii")
    }

    @Test("an exact name wins even when a shorter one also matches")
    func exactNameWins() throws {
        let artists = try ["Air", "Airbourne"].map(artist)
        #expect(SearchIndex.principalArtist(for: "Airbourne", among: artists)?.name == "Airbourne")
    }

    @Test("with no standalone entry the shortest credit is used")
    func fallsBackToShortestCredit() throws {
        let artists = try ["Avicii, Nicky Romero", "Avicii, CAZZETTE"].map(artist)
        #expect(SearchIndex.principalArtist(for: "Avicii", among: artists)?.name == "Avicii, CAZZETTE")
    }

    @Test("a query matching nothing well enough selects no one")
    func noWeakMatches() throws {
        let artists = try ["Daft Punk", "Justice"].map(artist)
        #expect(SearchIndex.principalArtist(for: "Avicii", among: artists) == nil)
    }

    @Test("case and surrounding spaces do not change the answer")
    func caseAndSpacingIgnored() throws {
        let artists = try ["Avicii, CAZZETTE", "avicii"].map(artist)
        #expect(SearchIndex.principalArtist(for: "  AVICII  ", among: artists)?.name == "avicii")
    }

    /// The premise the fix rests on: every collaboration really does score a perfect 1.0,
    /// so ordering — not scoring — was the only thing deciding the winner.
    @Test("collaborations score exactly as high as the standalone name")
    func collaborationsTieOnScore() {
        #expect(Fuzzy.score(query: "Avicii", target: "Avicii") == 1.0)
        #expect(Fuzzy.score(query: "Avicii", target: "Avicii, CAZZETTE") == 1.0)
    }
}
