import Foundation

#if !APPSTORE_BUILD

/// The Deezer release a library album is a copy of — found so the songs the copy is missing
/// can be listed and fetched as that release, the way the radar gets a new one.
@MainActor
enum AlbumCompletion {
    struct Edition {
        let release: RadarRelease
        let tracks: [DeezerTrack]

        /// The release's songs no song of the album is titled after.
        func missing(from songs: [Song]) -> [DeezerTrack] {
            RadarRules.unheld(tracks, among: songs)
        }
    }

    private enum Lookup {
        case found(Edition)
        case none
        case failed
    }

    /// Answers kept for the session, so an album is looked up once rather than at every
    /// visit. A failed look-up is never kept: it says nothing about the album.
    private static var known: [String: Edition?] = [:]
    /// Editions compared at most: the search's best few carry the album's title.
    private static let editionLimit = 3

    static func edition(of album: AlbumWithSongs) async -> Edition? {
        if let answer = known[album.id] { return answer }
        switch await lookUp(album) {
        case .found(let edition):
            known[album.id] = .some(edition)
            return edition
        case .none:
            known[album.id] = .some(nil)
            return nil
        case .failed:
            return nil
        }
    }

    /// Of the releases by the album's artist and under its title, the one holding every song
    /// the library has with the fewest others: the standard edition over the deluxe one when
    /// the library's songs are on both, the deluxe when a bonus track is among them.
    private static func lookUp(_ album: AlbumWithSongs) async -> Lookup {
        guard let songs = album.song, !songs.isEmpty, let artist = album.artist, !artist.isEmpty else { return .none }
        guard let found = await RadarCatalog.search("\(artist) \(album.name)") else { return .failed }
        let title = baseTitle(album.name)
        let hits = found.albums.filter { hit in
            baseTitle(hit.title) == title
                && (RadarRules.credits(hit.artist.name, artist) || RadarRules.credits(artist, hit.artist.name))
        }
        var best: (score: Int, edition: Edition)?
        for hit in hits.prefix(editionLimit) {
            guard let tracks = await RadarCatalog.tracks(albumId: String(hit.id)), !tracks.isEmpty else { continue }
            let held = songs.filter { song in tracks.contains { RadarRules.sameTitle($0.title, song.title) } }.count
            // Fewer than half the library's songs on it: another record under the same name.
            guard held * 2 >= songs.count else { continue }
            let exact = RadarRules.normalized(hit.title) == RadarRules.normalized(album.name)
            let score = held * 1000 + (exact ? 100 : 0) - tracks.count
            if score > best?.score ?? .min {
                best = (score, Edition(release: release(hit, of: album, by: artist), tracks: tracks))
            }
        }
        return best.map { .found($0.edition) } ?? .none
    }

    /// A title without what it says of its edition: "AM (Deluxe) [Explicit]" is "am".
    private static func baseTitle(_ title: String) -> String {
        let bare = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return RadarRules.normalized(bare.isEmpty ? title : bare)
    }

    private static func release(_ hit: DeezerAlbumHit, of album: AlbumWithSongs, by artist: String) -> RadarRelease {
        RadarRelease(id: String(hit.id), title: hit.title,
                     artist: ArtistRef(id: album.artistId ?? "", name: artist),
                     released: album.year.map { "\($0)-01-01" } ?? "",
                     type: hit.record_type ?? "album", cover: hit.cover_medium, link: hit.link)
    }
}

#endif
