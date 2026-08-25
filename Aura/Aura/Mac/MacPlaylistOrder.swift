import SwiftUI

/// Pinned playlists lead, in the order they were pinned; everything else follows unchanged.
///
/// The pins themselves live in `AppSettings`, which is shared with the phone — so the
/// concept, the storage and the ordering rules are the iOS app's, and only the presentation
/// is written twice. Note that the *contents* do not travel: the Mac app is a separate
/// application with its own defaults, so pinning here does not pin there.
enum MacPlaylistOrder {
    static func pinnedFirst(_ playlists: [Playlist]) -> [Playlist] {
        let settings = AppSettings.shared
        let pinned = settings.pinnedPlaylistOrder.compactMap { id in
            playlists.first { $0.id == id }
        }
        let rest = playlists.filter { !settings.isPinned($0.id) }
        return pinned + rest
    }
}

/// Pin / unpin, offered wherever a playlist is shown.
struct MacPinButton: View {
    let playlistId: String
    var asLabel = false
    @State private var settings = AppSettings.shared

    private var pinned: Bool { settings.isPinned(playlistId) }

    var body: some View {
        Button {
            settings.togglePin(playlistId: playlistId)
        } label: {
            if asLabel {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            } else {
                Image(systemName: pinned ? "pin.fill" : "pin")
            }
        }
    }
}
