import ActivityKit
import Foundation

/// A release on its way from Soulseek into the library, on the Lock Screen and in the Dynamic
/// Island. Shared by the app, which runs the fetch, and the widget, which draws it.
struct ReleaseFetchAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 0 looking, 1 downloading, 2 joining the library, 3 in it; -1 when it failed.
        var step: Int
        var headline: String
        var detail: String
        /// The download's share done, while there is one.
        var progress: Double?
        /// While the server imports: when the wait began and when it should be over, so the
        /// bar keeps moving with the app asleep.
        var waitStart: Date?
        var waitEnd: Date?
    }

    var releaseId: String
    var title: String
    var artist: String

    static let steps = 4
}
