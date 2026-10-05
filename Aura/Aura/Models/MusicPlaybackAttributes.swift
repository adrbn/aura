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

/// What the Home Screen widget shows: the app writes it, the widget reads it, through the
/// App Group both share (group.<app bundle id>).
struct NowPlayingSnapshot: Codable, Equatable {
    var songId: String
    var title: String
    var artist: String
    var isPlaying: Bool

    static let widgetKind = "NowPlayingWidget"

    private static var groupID: String {
        var id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".widget") { id.removeLast(".widget".count) }
        return "group." + id
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }

    static var coverURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("nowplaying-cover.jpg")
    }

    static func load() -> NowPlayingSnapshot? {
        guard let data = defaults?.data(forKey: "nowPlaying") else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: "nowPlaying")
    }
}
