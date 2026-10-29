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

    /// The phone's sorts, under the phone's key.
    static func sorted(_ list: [Playlist], by order: PlaylistSortOrder) -> [Playlist] {
        switch order {
        case .name: return list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .songCount: return list.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        case .recentlyChanged: return list.sorted { ($0.changed ?? "") > ($1.changed ?? "") }
        case .created: return list.sorted { ($0.created ?? "") > ($1.created ?? "") }
        }
    }

    /// Splits the playlists under `folder` (a prefix ending in "/", "" at the top) into its
    /// subfolders and the playlists right in it, from names like "Folder/Name", as the phone
    /// does. A folder needs two playlists, so a lone "AC/DC" stays a playlist.
    static func level(_ list: [Playlist], in folder: String) -> (folders: [(name: String, count: Int)], loose: [Playlist]) {
        var groups: [String: [Playlist]] = [:]
        var loose: [Playlist] = []
        for playlist in list where playlist.name.hasPrefix(folder) {
            let rest = playlist.name.dropFirst(folder.count)
            if let slash = rest.firstIndex(of: "/"), slash != rest.startIndex {
                groups[String(rest[..<slash]), default: []].append(playlist)
            } else {
                loose.append(playlist)
            }
        }
        loose += groups.values.filter { $0.count == 1 }.flatMap { $0 }
        let folders = groups.filter { $0.value.count > 1 }
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return (folders, loose)
    }

    /// The copies among playlists of the same name, found as the phone's Select Duplicates
    /// finds them: the fullest (then oldest) of a name is kept, and another is a copy when it
    /// is empty or shares at least 80% of its songs with the kept one.
    static func duplicates(in playlists: [Playlist], server: ServerConfig) async -> [Playlist] {
        let groups = Dictionary(grouping: playlists) { $0.name.lowercased().trimmingCharacters(in: .whitespaces) }
            .values.filter { $0.count > 1 }
        var songIds: [String: Set<String>] = [:]
        for playlist in groups.flatMap({ $0 }) {
            let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
            songIds[playlist.id] = Set((detail?.entry ?? []).map(\.id))
        }
        var copies: [Playlist] = []
        for group in groups {
            let ranked = group.sorted { a, b in
                let ca = songIds[a.id]?.count ?? 0, cb = songIds[b.id]?.count ?? 0
                return ca != cb ? ca > cb : (a.created ?? "") < (b.created ?? "")
            }
            let kept = songIds[ranked[0].id] ?? []
            for candidate in ranked.dropFirst() {
                let ids = songIds[candidate.id] ?? []
                if ids.isEmpty || (!kept.isEmpty && Double(ids.intersection(kept).count) / Double(ids.count) >= 0.8) {
                    copies.append(candidate)
                }
            }
        }
        return copies
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
