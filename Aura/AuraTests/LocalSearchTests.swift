import Testing
@testable import Aura

/// The search field's rules: operators, typo correction, accents and apostrophes.
struct LocalSearchTests {
    let docs = [
        LocalSearch.Doc(title: "Wake Me Up", artist: "Avicii", album: "True", genre: "House", year: 2013, popularity: 50),
        LocalSearch.Doc(title: "Levels", artist: "Avicii", album: "Levels", genre: "House", year: 2011),
        LocalSearch.Doc(title: "One More Time", artist: "Daft Punk", album: "Discovery", year: 2001),
        LocalSearch.Doc(title: "Levitating", artist: "Dua Lipa", album: "Future Nostalgia", year: 2020),
        LocalSearch.Doc(title: "Don\u{2019}t Start Now", artist: "Dua Lipa", album: "Future Nostalgia", year: 2019),
        LocalSearch.Doc(title: "Été indien", artist: "Joe Dassin", year: 1975),
    ]

    func titles(_ q: String) -> [String] {
        let fixed = LocalSearch.corrected(LocalSearch.parse(q), vocabulary: LocalSearch.Vocabulary(docs)).query
        return LocalSearch.search(fixed, in: docs, limit: 10).map { docs[$0].text[.title]! }
    }

    @Test func operators() {
        #expect(titles("dua lipa -levitating") == ["dont start now"])
        #expect(titles("artist:avicii year:2013") == ["wake me up"])
        #expect(titles("\"one more\"") == ["one more time"])
        #expect(Set(titles("levels OR daft")) == ["levels", "one more time"])
    }

    @Test func typosAccentsApostrophes() {
        #expect(titles("levitatng") == ["levitating"])
        #expect(titles("avicci levles") == ["levels"])
        #expect(titles("ete indien") == ["ete indien"])
        #expect(titles("dont start") == ["dont start now"])
        #expect(titles("xyzq").isEmpty)
    }
}
