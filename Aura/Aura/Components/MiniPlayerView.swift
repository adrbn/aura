import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    /// On an iPad it is the only bar at the foot of the screen, at the scale of the rest.
    private let pad = BottomChrome.isPad

    var body: some View {
        if let song = player.currentSong {
            Button {
                player.isShowingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    // The list thumbnails' corner: ten cut into square frames near the
                    // artwork's edges, the hero's proportion (1.5) read as a sharp square.
                    CoverArtImage(coverArt: song.coverArt, size: pad ? 60 : 44, cornerRadius: pad ? 8 : 6,
                                  placeholderName: song.title, placeholderKind: .song)
                        .id("mini-\(song.id)-\(song.coverArt ?? "")")

                    VStack(alignment: .leading, spacing: pad ? 3 : 2) {
                        // Held at its start while Now Playing covers it, so closing the
                        // player finds the title's first word, not the middle of a slide.
                        MarqueeText(text: song.title,
                                    font: pad ? .body.weight(.semibold) : .subheadline.weight(.semibold),
                                    color: .primary,
                                    alignment: .leading,
                                    isActive: !player.isShowingNowPlaying)
                        // While this plays on another device, or another plays on this one, the line says so.
                        if let band = RemoteLink.shared.bandText {
                            Label(band.text, systemImage: band.symbol)
                                .font((pad ? Font.subheadline : .caption).weight(.semibold))
                                .foregroundStyle(RemoteLink.shared.accent ?? accentColor)
                                .lineLimit(1)
                        } else {
                            Text(song.artist ?? String(localized: "Unknown Artist"))
                                .font(pad ? .subheadline : .caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if pad {
                        Button {
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                                .foregroundStyle(.primary)
                                .frame(width: 48, height: 48)
                        }
                        .accessibilityLabel("Previous track")
                    }

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(pad ? .title : .title2)
                            .foregroundStyle(.primary)
                            .frame(width: pad ? 48 : nil, height: pad ? 48 : nil)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(pad ? .title2 : .title3)
                            .foregroundStyle(.primary)
                            .frame(width: pad ? 48 : nil, height: pad ? 48 : nil)
                    }
                    .accessibilityLabel("Next track")
                }
                .padding(.horizontal, pad ? 20 : 16)
                .padding(.vertical, pad ? 14 : 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: pad ? 28 : 22))
            .clipShape(RoundedRectangle(cornerRadius: pad ? 28 : 22))
            .padding(.horizontal, pad ? 24 : 16)
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
