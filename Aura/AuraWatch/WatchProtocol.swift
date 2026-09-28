import Foundation

/// What the iPhone tells the watch, and what the watch asks of it, over WatchConnectivity.
///
/// Compiled into both apps, so the two sides can't drift apart. Everything travels as JSON
/// inside the dictionaries WatchConnectivity carries, under these keys.
enum WatchLinkKey {
    static let state = "state"
    static let artwork = "artwork"
    static let command = "command"
    /// Sent by the watch when it opens: the reply is the current state.
    static let hello = "hello"
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

enum WatchCommand: Codable, Equatable {
    case playPause
    case next
    case previous
    case favorite
    case playSomething
    case seek(TimeInterval)
    case play(WatchNowPlaying.Upcoming)
}
