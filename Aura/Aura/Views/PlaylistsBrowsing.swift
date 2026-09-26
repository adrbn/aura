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

    var icon: String {
        switch self {
        case .all: return "square.stack"
        case .pinned: return "pin.fill"
        case .radios: return "dot.radiowaves.left.and.right"
        case .mixes: return "wand.and.stars"
        case .mine: return "person.fill"
        case .shared: return "person.2.fill"
        case .downloaded: return "arrow.down.circle.fill"
        }
    }
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

/// The filters as a row of capsules, and the grid/list switch at its end.
struct PlaylistFilterBar: View {
    let filters: [PlaylistFilter]
    @Binding var selection: PlaylistFilter
    @Binding var layout: PlaylistLayout
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(filters) { filter in chip(filter) }
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
            }
            .scrollIndicators(.hidden)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { layout = layout.toggled }
            } label: {
                Image(systemName: layout.toggleIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 36, height: 32)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layout == .grid ? "Show as List" : "Show as Grid")
            .padding(.trailing, 16)
        }
    }

    private func chip(_ filter: PlaylistFilter) -> some View {
        let isOn = filter == selection
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selection = isOn ? .all : filter }
        } label: {
            Label(filter.rawValue, systemImage: filter.icon)
                .labelStyle(ChipLabelStyle(showsIcon: filter != .all))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? AnyShapeStyle(accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Icon then title, tight — the system label spaces them for a list row, not a capsule.
private struct ChipLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            if showsIcon { configuration.icon.font(.caption.weight(.semibold)) }
            configuration.title
        }
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
