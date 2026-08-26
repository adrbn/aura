import Testing
import Foundation
@testable import Aura

// MARK: - Network stub

/// Answers every request from a handler instead of the network, so the catalogue
/// paths can be exercised offline and deterministically.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, Data))?

    static func set(_ h: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        handler = h
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    private static func current() -> ((URLRequest) -> (Int, Data))? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    /// A session that routes everything through this protocol.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.current(), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

private enum Fixture {
    static func itunes(_ tracks: String) -> Data {
        Data("""
        {"resultCount": 1, "results": [\(tracks)]}
        """.utf8)
    }

    static let itunesDestinations = """
    {"trackId": 1440859023, "trackName": "Destinations", "artistName": "Alesso",
     "trackViewUrl": "https://music.apple.com/fr/album/destinations/1440859007?i=1440859023&uo=4"}
    """

    /// Right artist, unrelated song — must be refused, not returned as a match.
    static let itunesWrongTitle = """
    {"trackId": 1, "trackName": "Heroes", "artistName": "Alesso",
     "trackViewUrl": "https://music.apple.com/fr/album/heroes/1?i=1&uo=4"}
    """

    /// Right title, different artist — must be refused.
    static let itunesWrongArtist = """
    {"trackId": 2, "trackName": "Destinations", "artistName": "Sacred Reich",
     "trackViewUrl": "https://music.apple.com/fr/album/destinations/2?i=2&uo=4"}
    """

    static let itunesEmpty = Data(#"{"resultCount": 0, "results": []}"#.utf8)

    static func deezer(_ tracks: String) -> Data {
        Data("""
        {"data": [\(tracks)]}
        """.utf8)
    }

    static let deezerDestinations = """
    {"id": 100068948, "title": "Destinations",
     "link": "https://www.deezer.com/track/100068948", "artist": {"name": "Alesso"}}
    """

    static let deezerEmpty = Data(#"{"data": []}"#.utf8)
}

/// Route by host so one handler can serve both catalogue calls.
private func route(itunes: Data, deezer: Data, status: Int = 200) {
    StubURLProtocol.set { request in
        let host = request.url?.host ?? ""
        if host.contains("itunes") { return (status, itunes) }
        if host.contains("deezer") { return (status, deezer) }
        return (404, Data())
    }
}

// MARK: - Tests

/// These drive the whole resolution path through `fetchLinks`, which is what the
/// share sheet calls — behaviour, not internals. The suite is serialised because
/// the stub handler is process-wide.
@Suite("SongLinkService", .serialized)
struct SongLinkServiceTests {

    private func service() -> SongLinkService {
        SongLinkService(session: StubURLProtocol.session())
    }

    @Test("a verified match yields real links and a universal link built from the iTunes id")
    func verifiedMatch() async {
        route(itunes: Fixture.itunes(Fixture.itunesDestinations),
              deezer: Fixture.deezer(Fixture.deezerDestinations))
        defer { StubURLProtocol.reset() }

        let links = await service().fetchLinks(title: "Destinations", artist: "Alesso")

        #expect(links?.appleMusic?.url == "https://music.apple.com/fr/album/destinations/1440859007?i=1440859023")
        #expect(links?.appleMusic?.isSearch == false)
        #expect(links?.deezer?.url == "https://www.deezer.com/track/100068948")
        #expect(links?.deezer?.isSearch == false)
        // iTunes wins the universal link when both catalogues matched.
        #expect(links?.pageUrl == "https://song.link/i/1440859023")
    }

    @Test("Apple's tracking parameter never reaches the shared link")
    func trackingStripped() async {
        route(itunes: Fixture.itunes(Fixture.itunesDestinations), deezer: Fixture.deezerEmpty)
        defer { StubURLProtocol.reset() }

        let links = await service().fetchLinks(title: "Destinations", artist: "Alesso")
        #expect(links?.appleMusic?.url.contains("uo=") == false)
    }

    @Test("a result by the wrong artist is refused rather than presented as resolved")
    func wrongArtistRefused() async {
        route(itunes: Fixture.itunes(Fixture.itunesWrongArtist), deezer: Fixture.deezerEmpty)
        defer { StubURLProtocol.reset() }

        let links = await service().fetchLinks(title: "Destinations", artist: "Alesso")
        #expect(links?.appleMusic == nil)
        #expect(links?.pageUrl == nil)
    }

    @Test("a result whose title does not correspond is refused")
    func wrongTitleRefused() async {
        // The artist matches, so only the score gate can reject this. Before that
        // gate existed, `max` returned it and the sheet showed it as a real link.
        route(itunes: Fixture.itunes(Fixture.itunesWrongTitle), deezer: Fixture.deezerEmpty)
        defer { StubURLProtocol.reset() }

        let links = await service().fetchLinks(title: "Destinations", artist: "Alesso")
        #expect(links?.appleMusic == nil)
        #expect(links?.pageUrl == nil)
    }

    @Test("Deezer carries the universal link when iTunes has nothing")
    func deezerFallback() async {
        StubURLProtocol.set { request in
            let host = request.url?.host ?? ""
            if host.contains("itunes") { return (200, Fixture.itunesEmpty) }
            return (200, Fixture.deezer(Fixture.deezerDestinations))
        }
        defer { StubURLProtocol.reset() }

        let links = await service().fetchLinks(title: "Destinations", artist: "Alesso")
        #expect(links?.appleMusic == nil)
        #expect(links?.deezer?.url == "https://www.deezer.com/track/100068948")
        #expect(links?.pageUrl == "https://song.link/d/100068948")
    }

    @Test("a failing catalogue degrades to search links, never to a dead universal link")
    func serverErrorDegradesToSearch() async {
        route(itunes: Data(), deezer: Data(), status: 500)
        defer { StubURLProtocol.reset() }

        let links = await service().fetchLinks(title: "Destinations", artist: "Alesso")
        #expect(links?.appleMusic == nil)
        #expect(links?.deezer == nil)
        // A bare "https://song.link" is what the old Odesli failure path produced;
        // nil makes the row read "Not available" instead of offering a dead link.
        #expect(links?.pageUrl == nil)
        #expect(links?.spotify?.isSearch == true)
        #expect(links?.youtubeMusic?.isSearch == true)
        #expect(links?.spotify?.appURL?.hasPrefix("spotify:search:") == true)
    }

    @Test("malformed JSON is treated as no result, not as a crash")
    func malformedResponse() async {
        StubURLProtocol.set { _ in (200, Data("not json at all".utf8)) }
        defer { StubURLProtocol.reset() }

        let links = await service().fetchLinks(title: "Destinations", artist: "Alesso")
        #expect(links != nil)
        #expect(links?.appleMusic == nil)
        #expect(links?.pageUrl == nil)
    }

    @Test("a second lookup for the same song is served from cache")
    func cacheServesRepeatLookups() async {
        var calls = 0
        StubURLProtocol.set { request in
            let host = request.url?.host ?? ""
            calls += 1
            if host.contains("itunes") { return (200, Fixture.itunes(Fixture.itunesDestinations)) }
            return (200, Fixture.deezer(Fixture.deezerDestinations))
        }
        defer { StubURLProtocol.reset() }

        let svc = service()
        _ = await svc.fetchLinks(title: "Destinations", artist: "Alesso")
        let after = calls
        _ = await svc.fetchLinks(title: "Destinations", artist: "Alesso")
        #expect(calls == after, "the cached lookup should not hit the network again")
    }

    @Test("a multi-artist credit string still resolves")
    func multiArtistCredit() async {
        route(itunes: Fixture.itunes(Fixture.itunesDestinations), deezer: Fixture.deezerEmpty)
        defer { StubURLProtocol.reset() }

        // The tag names every collaborator; only the lead is searched, and the
        // result is verified against the full credit.
        let links = await service().fetchLinks(title: "Destinations",
                                               artist: "Alesso • Zara Larsson • MNEK")
        #expect(links?.appleMusic != nil)
    }
}
