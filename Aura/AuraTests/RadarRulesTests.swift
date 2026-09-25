import Testing
import Foundation
@testable import Aura

/// The release radar's pure rules: who it follows, which releases count as new, and when a
/// catalogue release is the album already on the server.
@Suite("Radar rules")
struct RadarRulesTests {

    // MARK: Fixtures

    private func album(_ id: String, artist: String, artistId: String, plays: Int) -> Album {
        Album(id: id, name: id, artist: artist, artistId: artistId, coverArt: nil, songCount: nil,
              duration: nil, year: nil, genre: nil, starred: nil, created: nil, playCount: plays)
    }

    private func starred(_ id: String, _ name: String) -> Artist {
        Artist(id: id, name: name, coverArt: nil, albumCount: nil, starred: "2026-01-01",
               artistImageUrl: nil, playCount: nil)
    }

    private func deezer(_ id: Int, _ date: String?, title: String? = nil, type: String = "single") -> DeezerAlbum {
        DeezerAlbum(id: id, title: title ?? "R\(id)", release_date: date, record_type: type,
                    cover_medium: nil, link: nil)
    }

    private func song(_ id: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: Data(#"{"id":"\#(id)","title":"Track \#(id)"}"#.utf8))
    }

    private func song(_ id: String, added: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: Data(#"{"id":"\#(id)","title":"Track \#(id)","created":"\#(added)"}"#.utf8))
    }

    private func release(_ id: String, _ date: String) -> RadarRelease {
        RadarRelease(id: id, title: id, artist: ArtistRef(id: "a", name: "A"), released: date,
                     type: "album", cover: nil, link: nil)
    }

    // MARK: Artists

    @Test("Plays add up across an artist's albums, most-played first")
    func artistsRankByTotalPlays() {
        let frequent = [album("x1", artist: "X", artistId: "x", plays: 5),
                        album("y1", artist: "Y", artistId: "y", plays: 8),
                        album("x2", artist: "X", artistId: "x", plays: 6)]
        let picked = RadarRules.artists(frequent: frequent, starred: [])
        #expect(picked.map(\.id) == ["x", "y"])
    }

    @Test("Combined credits and Various Artists are not followed")
    func artistsSkipCombinedCredits() {
        let frequent = [album("a", artist: "Kygo • Ava Max", artistId: "k", plays: 9),
                        album("b", artist: "Various Artists", artistId: "v", plays: 9),
                        album("c", artist: "Dua Lipa, Elton John", artistId: "d", plays: 9),
                        album("d", artist: "M83", artistId: "m", plays: 1)]
        #expect(RadarRules.artists(frequent: frequent, starred: []).map(\.id) == ["m"])
    }

    @Test("Favourites fill the list after the played floor, without duplicates")
    func artistsMixInFavourites() {
        let frequent = (0..<5).map { album("al\($0)", artist: "P\($0)", artistId: "p\($0)", plays: 10 - $0) }
        let picked = RadarRules.artists(frequent: frequent, starred: [starred("p0", "P0"), starred("s", "S")],
                                        limit: 4, playedFloor: 2)
        #expect(picked.map(\.id) == ["p0", "p1", "s", "p2"])
    }

    // MARK: Window

    @Test("The window runs from thirty days back to today")
    func windowSpansThirtyDays() throws {
        let now = try #require(RadarWindow.formatter.date(from: "2026-09-25"))
        #expect(RadarWindow.range(now: now) == "2026-08-26"..."2026-09-25")
    }

    @Test("Only releases inside the window count, newest first, a few per artist")
    func freshKeepsTheNewestInWindow() {
        let window = "2026-08-26"..."2026-09-25"
        let albums = [deezer(1, "2026-09-01"), deezer(2, "2026-10-21"), deezer(3, "2026-09-20"),
                      deezer(4, "2025-01-01"), deezer(5, nil), deezer(6, "2026-09-10"), deezer(7, "2026-08-30")]
        #expect(RadarRules.fresh(albums, in: window, perArtist: 3).map(\.id) == [3, 6, 1])
    }

    @Test("An album out again under the same title is not new")
    func freshSkipsReissues() {
        let window = "2026-08-26"..."2026-09-25"
        // Ernia's album, dated anew by a re-issue months after the original.
        let albums = [deezer(1, "2026-09-03", title: "PER SOLDI E PER AMORE", type: "album"),
                      deezer(2, "2026-05-11", title: "PER SOLDI E PER AMORE", type: "album"),
                      deezer(3, "2026-09-03", title: "DEDICA")]
        #expect(RadarRules.fresh(albums, in: window).map(\.id) == [3])
    }

    @Test("An album named after the single that announced it is new")
    func freshKeepsTheAlbumAfterItsSingle() {
        let window = "2026-08-26"..."2026-09-25"
        let albums = [deezer(1, "2026-09-10", title: "Roses", type: "album"), deezer(2, "2026-08-01", title: "Roses")]
        #expect(RadarRules.fresh(albums, in: window).map(\.id) == [1])
        // The title track put out as a single after the album is the album's song.
        let late = [deezer(3, "2026-09-12", title: "Roses"), deezer(4, "2026-06-01", title: "Roses", type: "album")]
        #expect(RadarRules.fresh(late, in: window).isEmpty)
    }

    @Test("Two copies out the same day count once")
    func freshKeepsOneCopyPerDay() {
        let window = "2026-08-26"..."2026-09-25"
        let albums = [deezer(9, "2026-09-05", title: "Karaté Cœur", type: "album"),
                      deezer(8, "2026-09-05", title: "Karaté Cœur", type: "album")]
        #expect(RadarRules.fresh(albums, in: window).map(\.id) == [8])
    }

    // MARK: Matching

    @Test("Titles match across case, accents, punctuation and store suffixes",
          arguments: [("Karaté Cœur", "karate coeur"), ("Roses - Single", "Roses"),
                      ("DNA (Reimagined) - EP", "DNA [Reimagined]"), ("Don’t Feel Right", "Don't Feel Right")])
    func titlesMatch(_ pair: (String, String)) {
        #expect(RadarRules.sameTitle(pair.0, pair.1))
    }

    @Test("Different titles, or an empty one, don't match")
    func titlesDiffer() {
        #expect(!RadarRules.sameTitle("Roses", "Roses (Remix)"))
        #expect(!RadarRules.sameTitle("", ""))
        #expect(!RadarRules.sameTitle("!!!", "???"))
    }

    @Test("A credit names the artist whole, alone or among others",
          arguments: [("Kygo • Ava Max", "Ava Max"), ("M83 feat. Susanne Sundfør", "M83"),
                      ("Tyler, The Creator feat. Kali Uchis", "Tyler, The Creator"),
                      ("Dua Lipa, Elton John & PNAU", "Elton John"), ("Simon & Garfunkel", "Simon & Garfunkel"),
                      ("AC/DC", "AC/DC"), ("Beyoncé", "Beyonce")])
    func creditsName(_ pair: (String, String)) {
        #expect(RadarRules.credits(pair.0, pair.1))
    }

    @Test("A name inside another artist's name is not a credit",
          arguments: [("Sinclair", "Air"), ("Air Supply", "Air"), ("Alesso", "Ale"), ("Paul Simon", "Simon & Garfunkel")])
    func creditsRejectPartialNames(_ pair: (String, String)) {
        #expect(!RadarRules.credits(pair.0, pair.1))
    }

    @Test("No credit, or no name, is no match")
    func creditsNeedBothSides() {
        #expect(!RadarRules.credits(nil, "Air"))
        #expect(!RadarRules.credits("Air", ""))
    }

    @Test("Songs on the server long before the release are not new; a leak a week early is")
    func newSongsDropWhatWasAlreadyThere() throws {
        let album = release("per-soldi", "2026-09-03")
        let songs = [try song("old", added: "2026-03-01T10:12:00.000Z"),
                     try song("leak", added: "2026-08-25T21:00:00Z"),
                     try song("new", added: "2026-09-04T08:00:00Z"), try song("undated")]
        #expect(RadarRules.newSongs(songs, of: album).map(\.id) == ["leak", "new", "undated"])
    }

    // MARK: Playlist

    @Test("The playlist takes a few tracks per release, newest release first, no song twice")
    func playlistOrdersAndCaps() throws {
        let old = release("old", "2026-09-01")
        let new = release("new", "2026-09-20")
        let tracks = [(release: old, songs: try ["3", "2"].map(song)),
                      (release: new, songs: try ["3", "4", "5", "1"].map(song))]
        #expect(RadarRules.playlist(tracks, perRelease: 3).map(\.id) == ["3", "4", "5", "2"])
    }
}
