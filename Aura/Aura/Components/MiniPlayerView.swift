import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayer.self) private var player
    /// Namespace for the expansion into Now Playing. Optional so the bar can still be
    /// used somewhere that has no such transition to offer.
    var transitionNamespace: Namespace.ID?

    var body: some View {
        if let song = player.currentSong {
            Button {
                player.isShowingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    // The cover the full player grows out of. Anchoring the expansion to
                    // the artwork — rather than sliding a new screen up over everything —
                    // is what makes opening the player read as *this song* opening, and
                    // closing it as the same song folding back where it came from.
                    CoverArtImage(coverArt: song.coverArt, size: 44, cornerRadius: 10,
                                  placeholderName: song.title, placeholderKind: .song)
                        .id("mini-\(song.id)-\(song.coverArt ?? "")")
                        .matchedTransitionSourceIfAvailable(id: Self.transitionID, in: transitionNamespace)

                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(text: song.title,
                                    font: .subheadline.weight(.semibold),
                                    color: .primary,
                                    alignment: .leading)
                        Text(song.artist ?? "Unknown Artist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Next track")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 16)
            .highPriorityGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.width < -50 || value.predictedEndTranslation.width < -100 {
                            player.next()
                        } else if value.translation.width > 50 || value.predictedEndTranslation.width > 100 {
                            player.previous()
                        }
                    }
            )
        }
    }
}

extension MiniPlayerView {
    /// One id, because there is only ever one mini player on screen.
    static let transitionID = "aura.nowPlaying"
}

extension View {
    /// `matchedTransitionSource` only when a namespace was handed down, so the mini
    /// player stays usable on its own.
    @ViewBuilder
    func matchedTransitionSourceIfAvailable(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
