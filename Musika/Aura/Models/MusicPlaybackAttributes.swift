import ActivityKit
import Foundation

struct MusicPlaybackAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isPlaying: Bool
        var songTitle: String
        var artist: String
        var album: String
        var elapsed: Double
        var duration: Double
        var coverArtURL: String?
    }

    var songId: String
}
