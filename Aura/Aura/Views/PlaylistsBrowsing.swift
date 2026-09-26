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

    private static let spacing: CGFloat = 6

    var body: some View {
        if !chips.isEmpty {
            // Sized to their labels, a few chips stopped short and left the right of the row
            // empty, which read as unfinished. When they all fit on one line they now span
            // it, margin to margin; when they don't, the row scrolls instead — out under the
            // screen's edge rather than cut off short of it. `ViewThatFits` measures each
            // at its natural width, so the choice follows the labels, their language and
            // how many filters there are.
            ViewThatFits(in: .horizontal) {
                FillingRow(spacing: Self.spacing) {
                    ForEach(chips) { filter in chip(filter) }
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal) {
                    HStack(spacing: Self.spacing) {
                        ForEach(chips) { filter in chip(filter) }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
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

/// One line of views that spans the width it's given: each keeps its natural width and
/// takes an equal share of what's left, so a longer label still makes a longer chip and
/// every chip gains the same room around its label. A lone chip keeps its own width at the
/// start of the line: stretched across the row it would read as a button, not a filter.
///
/// Asked for its ideal size it answers with the natural widths alone, which is how
/// `ViewThatFits` learns whether the line fits at all.
struct FillingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + gaps(subviews.count)
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        return CGSize(width: max(natural, offered), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let spare = max(0, bounds.width - widths.reduce(0, +) - gaps(subviews.count))
        let share = subviews.count > 1 ? spare / CGFloat(subviews.count) : 0
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width + share, height: bounds.height))
            x += width + share + spacing
        }
    }

    private func gaps(_ count: Int) -> CGFloat {
        spacing * CGFloat(max(count - 1, 0))
    }
}

/// A small capsule in a row of filters or modes: quiet until chosen, then in the accent.
///
/// It takes whatever width it's offered past its label's, so `FillingRow` can widen it; in
/// a scrolling row, which offers no width, it keeps to its label.
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
            .frame(maxWidth: .infinity)
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
                // A quiet mark, as on the grid's covers: in the accent it was the brightest
                // thing in the row, louder than the name it belongs to.
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
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
