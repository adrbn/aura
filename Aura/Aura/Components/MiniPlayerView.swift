import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        if let song = player.currentSong {
            Button {
                player.isShowingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    // The list thumbnails' corner: ten cut into square frames near the
                    // artwork's edges, the hero's proportion (1.5) read as a sharp square.
                    CoverArtImage(coverArt: song.coverArt, size: 44, cornerRadius: 6,
                                  placeholderName: song.title, placeholderKind: .song)
                        .id("mini-\(song.id)-\(song.coverArt ?? "")")

                    VStack(alignment: .leading, spacing: 2) {
                        // Held at its start while Now Playing covers it, so closing the
                        // player finds the title's first word, not the middle of a slide.
                        MarqueeText(text: song.title,
                                    font: .subheadline.weight(.semibold),
                                    color: .primary,
                                    alignment: .leading,
                                    isActive: !player.isShowingNowPlaying)
                        Text(song.artist ?? String(localized: "Unknown Artist"))
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
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // While the phone controls a Mac, the band in the accent says where it plays.
                    if let mac = RemoteLink.shared.connected {
                        Label(String(localized: "Playing on \(mac.displayName)"), systemImage: "macbook")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(accentColor)
                    }
                }
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
                            player.previous(restartsFirst: false)
                        }
                    }
            )
        }
    }
}
