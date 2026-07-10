import SwiftUI

// MARK: - Artist Parsing

struct ArtistPart {
    let name: String
    let separator: String // "feat.", "&", etc. — empty for the first artist
}

/// Splits an artist string on common featuring/collaboration separators.
/// Returns an array of `ArtistPart` where the first element has an empty separator.
func parseArtists(from artistString: String) -> [ArtistPart] {
    // Order matters: check longer patterns first to avoid partial matches.
    let separators = [" featuring ", " feat. ", " ft. ", " & ", " • ", " · ", "; ", ", "]

    var parts: [ArtistPart] = []
    var remaining = artistString
    var pendingSeparator = ""

    while !remaining.isEmpty {
        // Find the earliest separator in the remaining string
        var earliestRange: Range<String.Index>?
        var earliestSep = ""

        for sep in separators {
            if let range = remaining.range(of: sep, options: .caseInsensitive) {
                if earliestRange == nil || range.lowerBound < earliestRange!.lowerBound {
                    earliestRange = range
                    earliestSep = sep
                }
            }
        }

        if let range = earliestRange {
            let name = String(remaining[remaining.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                parts.append(ArtistPart(name: name, separator: pendingSeparator))
            }
            pendingSeparator = earliestSep.trimmingCharacters(in: .whitespaces)
            remaining = String(remaining[range.upperBound...])
        } else {
            // No more separators — take the rest as the final artist
            let name = remaining.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                parts.append(ArtistPart(name: name, separator: pendingSeparator))
            }
            break
        }
    }

    // If nothing was parsed, return the original string as a single part
    if parts.isEmpty {
        return [ArtistPart(name: artistString.trimmingCharacters(in: .whitespaces), separator: "")]
    }

    return parts
}

// MARK: - TappableArtistText View

struct TappableArtistText: View {
    let artistString: String
    let primaryArtistId: String?
    var font: Font = .caption
    var foregroundStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    var tappableStyle: AnyShapeStyle = AnyShapeStyle(.secondary)
    /// If true, dismiss the NowPlaying sheet before navigating (used in NowPlayingView)
    var dismissNowPlaying: Bool = false
    /// Optional closure for in-view navigation (e.g. within NowPlayingView's NavigationStack)
    var onNavigate: ((String) -> Void)? = nil

    @Environment(AudioPlayer.self) private var player

    var body: some View {
        let parts = parseArtists(from: artistString)

        if parts.count <= 1 {
            // Single artist — behave exactly as before
            if let artistId = primaryArtistId {
                Button {
                    if let onNavigate {
                        onNavigate(artistId)
                    } else {
                        if dismissNowPlaying {
                            player.isShowingNowPlaying = false
                        }
                        player.pendingArtistId = artistId
                    }
                } label: {
                    Text(artistString)
                        .font(font)
                        .foregroundStyle(tappableStyle)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
            } else {
                Text(artistString)
                    .font(font)
                    .foregroundStyle(foregroundStyle)
                    .lineLimit(1)
            }
        } else {
            // Multiple artists — each individually tappable
            multiArtistView(parts: parts)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func multiArtistView(parts: [ArtistPart]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if !part.separator.isEmpty {
                    Text(" · ")
                        .font(font)
                        .foregroundStyle(foregroundStyle)
                }
                ArtistNameButton(
                    name: part.name,
                    artistId: index == 0 ? primaryArtistId : nil,
                    font: font,
                    style: tappableStyle,
                    dismissNowPlaying: dismissNowPlaying,
                    onNavigate: onNavigate
                )
            }
        }
    }
}

// MARK: - ArtistNameButton

/// A button that navigates to an artist. If `artistId` is provided, uses it directly.
/// Otherwise, searches for the artist by name via the Subsonic API.
private struct ArtistNameButton: View {
    let name: String
    let artistId: String?
    let font: Font
    let style: AnyShapeStyle
    let dismissNowPlaying: Bool
    var onNavigate: ((String) -> Void)? = nil

    @Environment(AudioPlayer.self) private var player
    @State private var isSearching = false

    var body: some View {
        Button {
            if let artistId {
                navigateToArtist(artistId)
            } else {
                searchAndNavigate()
            }
        } label: {
            Text(name)
                .font(font)
                .foregroundStyle(style)
                .opacity(isSearching ? 0.5 : 1.0)
        }
        .buttonStyle(.borderless)
        .disabled(isSearching)
    }

    private func navigateToArtist(_ id: String) {
        if let onNavigate {
            onNavigate(id)
        } else {
            if dismissNowPlaying {
                player.isShowingNowPlaying = false
            }
            player.pendingArtistId = id
        }
    }

    private func searchAndNavigate() {
        guard let server = ServerManager.shared.currentServer else { return }
        isSearching = true
        Task {
            defer { isSearching = false }
            do {
                let result = try await SubsonicClient.shared.search3(
                    server: server,
                    query: name,
                    artistCount: 10,
                    albumCount: 0,
                    songCount: 0
                )
                // Try to find an exact (case-insensitive) match first, fall back to first result
                if let artists = result.artist {
                    let match = artists.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                        ?? artists.first
                    if let match {
                        await MainActor.run {
                            navigateToArtist(match.id)
                        }
                    }
                }
            } catch {
                // Silently fail — the button just does nothing
            }
        }
    }
}
