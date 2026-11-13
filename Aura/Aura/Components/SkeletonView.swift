import SwiftUI

// MARK: - Skeleton Pulse + Shimmer

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.5
    @State private var pulse: CGFloat = 0.4

    func body(content: Content) -> some View {
        content
            .opacity(pulse)
            .overlay(
                // `.primary` (not white): the skeleton shapes are filled with systemGray5/6,
                // which is near-white in light mode — a white sheen would be invisible there.
                // .primary sweeps dark-on-pale in light, white-on-dark in dark.
                LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.2), .clear],
                    startPoint: .init(x: phase - 0.3, y: 0.5),
                    endPoint: .init(x: phase + 0.3, y: 0.5)
                )
                .blendMode(BlendMode.sourceAtop)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = 1.0
                }
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

/// An iPad's placeholders at the scale of the rows and covers that replace them.
private let s = Pad.scale

// MARK: - Reusable Skeleton Rows

/// A single song-row shaped skeleton placeholder
struct SkeletonSongRow: View {
    /// Off for a release's own list, which numbers its songs instead of showing covers.
    var showsArt = true

    var body: some View {
        HStack(spacing: 12) {
            if showsArt {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.systemGray5))
                    .frame(width: 50 * s, height: 50 * s)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray6))
                    .frame(width: 14 * s, height: 14 * s)
                    .frame(minWidth: 22)
            }
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray5))
                    .frame(width: CGFloat.random(in: 100...180) * s, height: 14)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray6))
                    .frame(width: CGFloat.random(in: 60...120) * s, height: 12)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .shimmering()
        // In a plain List an unstyled row is painted pure black, under the canvas.
        .listRowBackground(Color.clear)
    }
}

/// Multiple song-row skeletons
struct SkeletonSongList: View {
    var count: Int = 8
    var showsArt = true

    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            SkeletonSongRow(showsArt: showsArt)
        }
    }
}

/// Album card skeleton for grids
struct SkeletonAlbumCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .aspectRatio(1, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray5))
                .frame(height: 14 * s)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray6))
                .frame(width: 60 * s, height: 12 * s)
        }
        .redacted(reason: .placeholder)
        .shimmering()
    }
}

/// Album grid skeleton
struct SkeletonAlbumGrid: View {
    var count: Int = 6

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160 * Pad.scale), spacing: 16)], spacing: 16) {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonAlbumCard()
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Playlist card skeleton
struct SkeletonPlaylistCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .aspectRatio(1, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray5))
                .frame(height: 14 * s)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray6))
                .frame(width: 50 * s, height: 11 * s)
        }
        .redacted(reason: .placeholder)
        .shimmering()
    }
}

/// Artist row skeleton for lists
struct SkeletonArtistRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: 48 * s, height: 48 * s)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray5))
                    .frame(width: CGFloat.random(in: 80...160) * s, height: 15)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray6))
                    .frame(width: 60 * s, height: 12 * s)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .shimmering()
        // In a plain List an unstyled row is painted pure black, under the canvas.
        .listRowBackground(Color.clear)
    }
}

/// Genre row skeleton
struct SkeletonGenreRow: View {
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray5))
                .frame(width: CGFloat.random(in: 80...180) * s, height: 16)
            Spacer()
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray6))
                .frame(width: 30 * s, height: 14 * s)
        }
        .padding(.vertical, 8)
        .redacted(reason: .placeholder)
        .shimmering()
        // In a plain List an unstyled row is painted pure black, under the canvas.
        .listRowBackground(Color.clear)
    }
}

/// Playlist row skeleton (for AddToPlaylist sheet)
struct SkeletonPlaylistRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemGray5))
                .frame(width: 50 * s, height: 50 * s)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray5))
                    .frame(width: CGFloat.random(in: 100...180) * s, height: 14)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray6))
                    .frame(width: 50 * s, height: 12 * s)
            }
            Spacer()
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: 24 * s, height: 24 * s)
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .shimmering()
        // In a plain List an unstyled row is painted pure black, under the canvas.
        .listRowBackground(Color.clear)
    }
}

/// Album detail header skeleton
struct SkeletonAlbumHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray5))
                .frame(width: 240 * s, height: 240 * s)
                .shimmering()

            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray5))
                .frame(width: 180 * s, height: 22 * s)
                .shimmering()

            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray6))
                .frame(width: 120 * s, height: 16 * s)
                .shimmering()

            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 36 * s, height: 36 * s)
                }
            }
            .shimmering()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

/// Playlist detail header skeleton
struct SkeletonPlaylistHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray5))
                .frame(width: 200 * s, height: 200 * s)
                .shimmering()

            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray5))
                .frame(width: 160 * s, height: 20 * s)
                .shimmering()

            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray6))
                .frame(width: 80 * s, height: 14 * s)
                .shimmering()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
