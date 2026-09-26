import SwiftUI

/// What the Playlists page can narrow itself to. Each kind reads what the server already
/// says of a playlist — its name, its owner — or what this device holds of it.
enum PlaylistFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case pinned = "Pinned"
    case radios = "Radios"
    case mixes = "Mixes"
    case mine = "Mine"
    case shared = "Shared"
    case downloaded = "Downloaded"

    var id: Self { self }
}

/// Grid of covers, or one row per playlist.
enum PlaylistLayout: String {
    case grid, list

    var toggled: PlaylistLayout { self == .grid ? .list : .grid }
    /// The icon of the layout a tap switches to.
    var toggleIcon: String { self == .grid ? "list.bullet" : "square.grid.2x2" }
}

/// Everything a filter needs to know beyond the playlist itself.
struct PlaylistFilterContext {
    let username: String?
    let pinned: Set<String>
    /// Playlists whose every song is on this device.
    let downloaded: Set<String>

    /// A saved radio is named after its seed; a saved mix or Wrapped after its title and
    /// when, around the bullet Aura puts between them.
    private static let radioPrefix = "Radio: "
    private static let savedSeparator = " • "

    func matches(_ playlist: Playlist, _ filter: PlaylistFilter) -> Bool {
        switch filter {
        case .all: return true
        case .pinned: return pinned.contains(playlist.id)
        case .radios: return playlist.name.hasPrefix(Self.radioPrefix)
        case .mixes:
            return !playlist.name.hasPrefix(Self.radioPrefix) && playlist.name.contains(Self.savedSeparator)
        case .mine: return isMine(playlist)
        case .shared: return !isMine(playlist)
        case .downloaded: return downloaded.contains(playlist.id)
        }
    }

    /// The filters worth offering: those that leave some playlists out, but not all of them.
    /// The one in use stays, so it can always be seen and undone.
    func offered(for playlists: [Playlist], keeping current: PlaylistFilter) -> [PlaylistFilter] {
        PlaylistFilter.allCases.filter { filter in
            if filter == .all || filter == current { return true }
            let count = playlists.lazy.filter { matches($0, filter) }.count
            return count > 0 && count < playlists.count
        }
    }

    private func isMine(_ playlist: Playlist) -> Bool {
        guard let owner = playlist.owner, let username else { return true }
        return owner.caseInsensitiveCompare(username) == .orderedSame
    }

    /// Read from the offline snapshots, which hold each playlist's songs.
    @MainActor
    static func downloadedPlaylistIds() -> Set<String> {
        let held = Set(DownloadManager.shared.downloadedSongs.map(\.id))
        guard !held.isEmpty else { return [] }
        return Set(OfflinePlaylistsStore.shared.playlists
            .filter { !$0.songs.isEmpty && $0.songs.allSatisfy { held.contains($0.id) } }
            .map(\.id))
    }
}

/// The filters as a row of small capsules, quiet until one is chosen. There is no "All":
/// tapping the chosen filter again clears it, and it carries a cross to say so.
struct PlaylistFilterBar: View {
    let filters: [PlaylistFilter]
    @Binding var selection: PlaylistFilter

    private var chips: [PlaylistFilter] { filters.filter { $0 != .all } }

    var body: some View {
        if !chips.isEmpty {
            // The full width, so the row scrolls out under the screen's edge rather than
            // being cut off short of it.
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(chips) { filter in chip(filter) }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(_ filter: PlaylistFilter) -> some View {
        let isOn = filter == selection
        return QuietChip(title: filter.rawValue, isOn: isOn, showsClear: true) {
            withAnimation(.easeInOut(duration: 0.2)) { selection = isOn ? .all : filter }
        }
        .accessibilityHint(isOn ? "Shows every playlist" : "Shows only these playlists")
    }
}

/// A small capsule in a row of filters or modes: quiet until chosen, then in the accent.
struct QuietChip: View {
    let title: String
    let isOn: Bool
    /// A cross on the chosen chip, for a filter that tapping again clears.
    var showsClear = false
    let action: () -> Void
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if isOn && showsClear {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .font(.footnote.weight(isOn ? .semibold : .medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(isOn ? AnyShapeStyle(accentColor) : AnyShapeStyle(.secondary))
            .background(isOn ? AnyShapeStyle(accentColor.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.06)),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A playlist as one row of the list layout: cover, name, what's in it.
struct PlaylistRowView: View {
    let playlist: Playlist
    var isPinned: Bool = false
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        HStack(spacing: 12) {
            PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt,
                              cacheToken: playlist.changed, size: 56, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let count = playlist.songCount {
            parts.append(count == 1 ? "1 song" : "\(count) songs")
        }
        if let seconds = playlist.duration, seconds > 0 {
            parts.append(Self.length(seconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func length(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(max(minutes, 1)) min"
    }
}
