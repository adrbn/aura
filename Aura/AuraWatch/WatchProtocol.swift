import Foundation

/// What the iPhone tells the watch, and what the watch asks of it, over WatchConnectivity.
///
/// Compiled into both apps, so the two sides can't drift apart. Everything travels as JSON
/// inside the dictionaries WatchConnectivity carries, under these keys.
enum WatchLinkKey {
    static let state = "state"
    static let artwork = "artwork"
    /// How the cover is laid behind the pages (`WatchTone`), measured on the phone with the
    /// same reading its own Now Playing makes. Sent with the artwork.
    static let tone = "tone"
    static let command = "command"
    /// Sent by the watch when it opens: the reply is the current state.
    static let hello = "hello"
    /// A `WatchRequest` from the watch's library; the answer comes back under `reply`, or
    /// for covers under `covers`, as small JPEGs by cover id.
    static let request = "request"
    static let reply = "reply"
    static let covers = "covers"
}

/// Something in the library the watch can list, open or play: a mix, a playlist, an album,
/// an artist or a song, named as the phone names it.
struct WatchItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mix, playlist, favorites, album, artist, song
    }

    let kind: Kind
    let id: String
    let title: String
    let subtitle: String
    /// The cover's id on the server, or an address for a release not on it yet.
    let coverArt: String?
}

/// The library's front page: what the phone's Home makes for you, and the playlists.
struct WatchShelf: Codable, Equatable, Sendable {
    var mixes: [WatchItem] = []
    var playlists: [WatchItem] = []
}

/// What's in a mix, a playlist, an album or an artist: its songs, and an artist's albums.
struct WatchListing: Codable, Equatable, Sendable {
    var songs: [WatchItem] = []
    var albums: [WatchItem] = []
}

struct WatchSearchResults: Codable, Equatable, Sendable {
    var songs: [WatchItem] = []
    var albums: [WatchItem] = []
    var artists: [WatchItem] = []

    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty }
}

/// What the watch's library asks of the phone, answered in the reply.
enum WatchRequest: Codable, Sendable {
    case shelf
    case open(WatchItem)
    case search(String)
    /// At most a handful at a time, so the reply stays well under WatchConnectivity's limit.
    case covers([String])
}

/// The player as the watch shows it.
///
/// The position isn't streamed: the phone sends where it was and when, and the watch
/// counts on from there while it plays. A new snapshot comes when anything else changes,
/// or when the two clocks drift apart — a seek, a stall.
struct WatchNowPlaying: Codable, Equatable {
    struct Line: Codable, Equatable {
        /// Already shifted by the lyrics offset set on the phone: compare to `elapsed`.
        let time: TimeInterval?
        let text: String
    }

    struct Upcoming: Codable, Equatable, Identifiable {
        let songId: String
        let title: String
        let artist: String
        /// Where it sits, so the phone can check it's still the same song before playing it.
        let slot: Int
        /// Added with Play Next, rather than the rest of the queue.
        let isQueued: Bool
        var id: String { "\(isQueued ? "q" : "a")\(slot)-\(songId)" }
    }

    var songId: String?
    var title = ""
    var artist = ""
    var artworkId: String?
    var isPlaying = false
    var position: TimeInterval = 0
    var positionDate = Date()
    var duration: TimeInterval = 0
    var isFavorite = false
    var isSavingFavorite = false
    /// A preview can't be starred: it isn't on the server.
    var canFavorite = false
    var lyrics: [Line] = []
    var upNext: [Upcoming] = []
    /// The app's accent, as red, green and blue.
    var accent: [Double] = [1, 1, 1]
    /// Word-by-word lyrics, as set on the phone (a beta there).
    var karaoke = false

    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let moved = position + date.timeIntervalSince(positionDate)
        return duration > 0 ? min(moved, duration) : moved
    }

    /// The same apart from where it is in the song.
    func matches(_ other: WatchNowPlaying) -> Bool {
        var mine = self, theirs = other
        mine.position = 0; mine.positionDate = .distantPast
        theirs.position = 0; theirs.positionDate = .distantPast
        return mine == theirs
    }
}

/// The blurred cover's treatment: black laid over it so white text reads on a pale cover,
/// and for a very dark one its liveliest colour, screened back in — the phone's
/// `BackdropTone`, carried over.
struct WatchTone: Codable, Equatable {
    var veil = 0.22
    /// Red, green and blue; nil for any cover but a dark one.
    var vibrant: [Double]?

    /// Colour comes back as the veil deepens, so a darkened cover isn't a greyed one.
    var saturation: Double { 1 + max(0, veil - 0.22) * 1.2 }
}

enum WatchCommand: Codable, Equatable {
    case playPause
    case next
    case previous
    case favorite
    case playSomething
    case seek(TimeInterval)
    case play(WatchNowPlaying.Upcoming)
    /// A mix, a playlist, an album or an artist's top songs, from the song at `index`, or
    /// shuffled; a song on its own, as the phone plays a search result.
    case playItem(WatchItem, index: Int, shuffled: Bool)
}
