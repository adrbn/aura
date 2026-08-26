import Testing
import Foundation
@testable import Aura

/// `SongQuery` is the pure half of share-link resolution: it decides what to ask a
/// streaming catalogue and whether the answer is really the song we meant. It runs
/// against a personal Subsonic library, so the metadata it sees is whatever the
/// user's tags happen to say — messy credit strings, remix suffixes, typographic
/// punctuation. These tests pin the behaviour that keeps a wrong link off screen.
@Suite("SongQuery")
struct SongQueryTests {

    // MARK: - primaryArtist

    @Test("a plain artist is left alone")
    func plainArtist() {
        #expect(SongQuery.primaryArtist("Alesso") == "Alesso")
        #expect(SongQuery.primaryArtist("Armand van Helden") == "Armand van Helden")
    }

    @Test("credit strings are cut down to the lead artist", arguments: [
        ("Armand van Helden • KAREN HARDING", "Armand van Helden"),
        ("Calvin Harris feat. Rihanna", "Calvin Harris"),
        ("Jax Jones ft. Demi Lovato", "Jax Jones"),
        ("Alesso featuring Tove Lo", "Alesso"),
        ("Kygo with Selena Gomez", "Kygo"),
        ("Martin Garrix vs. Tiësto", "Martin Garrix"),
        ("Jax Jones x Martin Solveig", "Jax Jones"),
    ])
    func leadArtistIsExtracted(input: String, expected: String) {
        #expect(SongQuery.primaryArtist(input) == expected)
    }

    @Test("a slash inside a single artist name is not a credit separator")
    func slashInsideArtistName() {
        // "AC/DC" is one band. Truncating it to "AC" sends a query no catalogue
        // can match. A *spaced* slash still separates two credited artists.
        #expect(SongQuery.primaryArtist("AC/DC") == "AC/DC")
        #expect(SongQuery.primaryArtist("Sunday Service / Choir") == "Sunday Service")
    }

    @Test("a blank artist reduces to empty, so verification refuses it")
    func emptyArtist() {
        // Returning "   " would be non-empty and slip past the emptiness guard in
        // artistMatches, letting a blank artist behave as a wildcard.
        #expect(SongQuery.primaryArtist("") == "")
        #expect(SongQuery.primaryArtist("   ") == "")
        #expect(!SongQuery.artistMatches("Anybody", query: "   "))
    }

    @Test("a credit string that starts with a separator keeps the name, not the separator")
    func leadingSeparator() {
        // "• Madonna" used to come back verbatim, bullet and all, and that went
        // straight into the search term — guaranteeing zero results.
        #expect(SongQuery.primaryArtist("\u{2022} Madonna") == "Madonna")
        #expect(SongQuery.primaryArtist("; DJ Snake") == "DJ Snake")
    }

    @Test("a comma inside a stage name still truncates — a known limitation")
    func commaIsAmbiguous() {
        // "Tyler, The Creator" and "Calvin Harris, Dua Lipa" are indistinguishable
        // without a catalogue lookup, so the comma wins. Verification downstream
        // still passes because artistMatches compares both directions.
        #expect(SongQuery.primaryArtist("Tyler, The Creator") == "Tyler")
        #expect(SongQuery.artistMatches("Tyler, The Creator", query: "Tyler, The Creator"))
    }

    // MARK: - cleanTitle

    @Test("featured-artist clutter is stripped", arguments: [
        ("Titanium (feat. Sia)", "Titanium"),
        ("Instruction (ft. Demi Lovato)", "Instruction"),
        ("Wild (featuring Troye Sivan)", "Wild"),
        ("Stay (with Justin Bieber)", "Stay"),
        ("Titanium (Feat. Sia)", "Titanium"),
    ])
    func featuredClutterIsStripped(input: String, expected: String) {
        #expect(SongQuery.cleanTitle(input) == expected)
    }

    @Test("meaningful parentheticals survive")
    func meaningfulParentheticalsSurvive() {
        // Stripping these would change which recording we ask for.
        #expect(SongQuery.cleanTitle("I Won't Let You Down (Extended Mix)") == "I Won't Let You Down (Extended Mix)")
        #expect(SongQuery.cleanTitle("Ce qu'on devient") == "Ce qu'on devient")
        #expect(SongQuery.cleanTitle("Sunrise (Won't Get Lost)") == "Sunrise (Won't Get Lost)")
    }

    // MARK: - artistMatches

    @Test("a result by the same artist matches, in either direction")
    func matchingArtists() {
        #expect(SongQuery.artistMatches("Alesso", query: "Alesso"))
        #expect(SongQuery.artistMatches("Alesso", query: "Alesso • Zara Larsson"))
        #expect(SongQuery.artistMatches("Alesso & Zara Larsson", query: "Alesso"))
        #expect(SongQuery.artistMatches("ALESSO", query: "alesso"))
    }

    @Test("a result by a different artist is rejected")
    func mismatchedArtists() {
        #expect(!SongQuery.artistMatches("Rihanna", query: "Calvin Harris"))
        #expect(!SongQuery.artistMatches(nil, query: "Alesso"))
    }

    @Test("a result with no artist name is not accepted as a match")
    func emptyCandidateIsNotAWildcard() {
        // A blank artistName must never satisfy the check — that is exactly how a
        // real-but-wrong link would reach the share sheet.
        #expect(!SongQuery.artistMatches("", query: "Alesso"))
    }

    @Test("an empty query cannot match anything")
    func emptyQueryMatchesNothing() {
        #expect(!SongQuery.artistMatches("Alesso", query: ""))
    }

    // MARK: - titleScore

    @Test("an exact title outranks every variant")
    func exactTitleWins() {
        let target = "destinations"
        let exact = SongQuery.titleScore("Destinations", target: target)
        let mixed = SongQuery.titleScore("Destinations [Mixed]", target: target)
        let longer = SongQuery.titleScore("Destinations Reprise", target: target)
        #expect(exact == 1000)
        #expect(exact > mixed)
        #expect(mixed > longer)
    }

    @Test("the shortest bracketed variant is preferred among variants")
    func shortestVariantWins() {
        let target = "destinations"
        let short = SongQuery.titleScore("Destinations [Mixed]", target: target)
        let long = SongQuery.titleScore("Destinations [Ultra 2015 Instrumental Edit]", target: target)
        #expect(short > long)
    }

    @Test("an unrelated title scores nothing")
    func unrelatedTitleScoresZero() {
        #expect(SongQuery.titleScore("Hello", target: "destinations") == 0)
        #expect(SongQuery.titleScore(nil, target: "destinations") == 0)
    }

    // MARK: - encodeQuery

    @Test("characters that would truncate a query are escaped")
    func dangerousCharactersAreEscaped() {
        // "&" and "?" left raw would cut the query short in a URL.
        #expect(SongQuery.encodeQuery("Simon & Garfunkel") == "Simon%20%26%20Garfunkel")
        #expect(SongQuery.encodeQuery("Feu! Chatterton") == "Feu%21%20Chatterton")
        #expect(!SongQuery.encodeQuery("Where? When?").contains("?"))
        #expect(!SongQuery.encodeQuery("Rock & Roll").contains("&"))
    }

    @Test("a typographic apostrophe is encoded as UTF-8")
    func typographicApostrophe() {
        #expect(SongQuery.encodeQuery("Ce qu\u{2019}on devient") == "Ce%20qu%E2%80%99on%20devient")
    }

    @Test("non-Latin scripts survive encoding")
    func nonLatinScripts() {
        let encoded = SongQuery.encodeQuery("久石譲")
        #expect(!encoded.isEmpty)
        #expect(encoded.removingPercentEncoding == "久石譲")
    }

    // MARK: - fallbackQuery

    @Test("the fallback query reads as a plain search phrase")
    func fallbackQueryIsPlain() {
        #expect(SongQuery.fallbackQuery(title: "Destinations", artist: "Alesso") == "Alesso Destinations")
    }

    @Test("bullets and slashes do not leave runs of whitespace")
    func fallbackQueryCollapsesWhitespace() {
        // A double space survives into the URL as %20%20, which reads as a typo
        // in a shared link.
        let q = SongQuery.fallbackQuery(title: "Turn It Around", artist: "Alesso • Zara Larsson")
        #expect(!q.contains("  "))
        #expect(q == "Alesso Zara Larsson Turn It Around")
    }

    // MARK: - Search URLs

    @Test("search URLs are well-formed and carry the query")
    func searchUrlsAreWellFormed() {
        let title = "Ce qu\u{2019}on devient"
        let artist = "Feu! Chatterton"
        for url in [SongQuery.spotifySearchUrl(title: title, artist: artist),
                    SongQuery.youtubeMusicSearchUrl(title: title, artist: artist),
                    SongQuery.yandexSearchUrl(title: title, artist: artist)] {
            #expect(URL(string: url) != nil, "\(url) is not a valid URL")
            #expect(url.contains("Chatterton"))
        }
    }

    @Test("Spotify gets its own URI scheme, because its app ignores search links")
    func spotifyAppScheme() {
        let uri = SongQuery.spotifyAppSearchUrl(title: "Destinations", artist: "Alesso")
        #expect(uri.hasPrefix("spotify:search:"))
        #expect(uri.contains("Alesso"))
        #expect(URL(string: uri) != nil)
    }

    // MARK: - cleanStoreUrl

    @Test("Apple's tracking parameter is dropped, the track id is kept")
    func storeUrlLosesTracking() {
        let cleaned = SongQuery.cleanStoreUrl(
            "https://music.apple.com/fr/album/destinations/1440859007?i=1440859023&uo=4")
        #expect(cleaned == "https://music.apple.com/fr/album/destinations/1440859007?i=1440859023")
    }

    @Test("a URL whose only parameter was tracking loses its query entirely")
    func storeUrlWithOnlyTracking() {
        #expect(SongQuery.cleanStoreUrl("https://music.apple.com/fr/album/x/1?uo=4")
                == "https://music.apple.com/fr/album/x/1")
    }

    @Test("a URL with nothing to strip is untouched")
    func storeUrlUntouched() {
        let url = "https://www.deezer.com/track/100068948"
        #expect(SongQuery.cleanStoreUrl(url) == url)
    }

    // MARK: - Unicode folding

    @Test("a typographic apostrophe matches an ASCII one")
    func apostropheFolding() {
        // Apple and Deezer spell with U+2019; hand-written tags usually do not.
        // Unfolded, the correct track scored 0 and a short decoy won.
        #expect(SongQuery.titleScore("Don\u{2019}t Stop Me Now", target: "Don't Stop Me Now") == 1000)
        #expect(SongQuery.titleScore("Ce qu\u{2019}on devient", target: "Ce qu'on devient") == 1000)
    }

    @Test("diacritics do not defeat artist verification")
    func diacriticFolding() {
        #expect(SongQuery.artistMatches("Sinead O'Connor", query: "Sin\u{00E9}ad O\u{2019}Connor"))
        #expect(SongQuery.artistMatches("Beyonc\u{00E9}", query: "Beyonce"))
    }

    // MARK: - Ranking

    @Test("the candidate that overlaps most wins, not the shortest one")
    func overlapBeatsBrevity() {
        // "Free" used to outrank "Everybody's Free (To Feel Good)" because the
        // score subtracted the candidate's length.
        let target = "Everybody's Free (To Feel Good) [Mixed]"
        let real = SongQuery.titleScore("Everybody's Free (To Feel Good)", target: target)
        let decoy = SongQuery.titleScore("Free", target: target)
        #expect(real > decoy)
        #expect(decoy > 0)
    }

    @Test("a title with no relation scores zero so the caller can refuse it")
    func unrelatedScoresZeroForRejection() {
        #expect(SongQuery.titleScore("Surf Nicaragua", target: "Thunderstruck") == 0)
    }

    // MARK: - Artist verification

    @Test("a different artist sharing one word is rejected")
    func sharedWordIsNotAMatch() {
        // Asking for Simon & Garfunkel must not accept Paul Simon's own recording.
        #expect(!SongQuery.artistMatches("Paul Simon", query: "Simon & Garfunkel"))
        #expect(!SongQuery.artistMatches("Sacred Reich", query: "AC/DC"))
        #expect(!SongQuery.artistMatches("Xavier", query: "X"))
    }

    @Test("exact artist identity is recognised for tie-breaking")
    func exactArtistIdentity() {
        #expect(SongQuery.isExactArtist("Simon & Garfunkel", query: "Simon & Garfunkel"))
        #expect(SongQuery.isExactArtist("Alesso", query: "Alesso \u{2022} Zara Larsson"))
        #expect(!SongQuery.isExactArtist("Paul Simon", query: "Simon & Garfunkel"))
    }

    // MARK: - cleanTitle edge cases

    @Test("a parenthetical that merely starts with the letters of feat survives")
    func featPrefixIsNotClutter() {
        #expect(SongQuery.cleanTitle("Icarus (Feathers)") == "Icarus (Feathers)")
        #expect(SongQuery.cleanTitle("Alive (Ftercare)") == "Alive (Ftercare)")
    }

    @Test("unbracketed and square-bracketed credits are stripped too")
    func otherCreditShapes() {
        #expect(SongQuery.cleanTitle("Titanium feat. Sia") == "Titanium")
        #expect(SongQuery.cleanTitle("Titanium [feat. Sia]") == "Titanium")
        #expect(SongQuery.cleanTitle("Wild featuring Troye Sivan") == "Wild")
    }

    @Test("a nested credit does not leave a dangling bracket")
    func nestedCredit() {
        #expect(SongQuery.cleanTitle("Song (feat. A (Live))") == "Song")
    }

    @Test("a title made only of a credit is kept rather than emptied")
    func titleThatIsOnlyACredit() {
        // An empty target scores every candidate 0, which used to mean an
        // arbitrary track was accepted instead.
        #expect(!SongQuery.cleanTitle("(feat. Nobody)").isEmpty)
    }

    @Test("\"(with …)\" is treated as a credit — a known limitation")
    func withIsAmbiguous() {
        // "(with Justin Bieber)" is a credit; "(With Strings)" is a different
        // recording. Nothing in the text distinguishes them, so credits win.
        #expect(SongQuery.cleanTitle("Live (With Strings)") == "Live")
    }
}
