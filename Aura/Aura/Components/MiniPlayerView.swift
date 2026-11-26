import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    /// On an iPad it is the only bar at the foot of the screen, at the scale of the rest.
    private let pad = BottomChrome.isPad
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the cover and title follow a sideways swipe before the song changes.
    @State private var dragX: CGFloat = 0

    var body: some View {
        if let song = player.currentSong {
            Button {
                player.isShowingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: 12) {
                    // The list thumbnails' corner: ten cut into square frames near the
                    // artwork's edges, the hero's proportion (1.5) read as a sharp square.
                    CoverArtImage(coverArt: song.coverArt ?? song.albumId, size: pad ? 60 : 44, cornerRadius: pad ? 8 : 6,
                                  fallbackCoverArt: song.albumId,
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
                    }
                    .offset(x: dragX)
                    .opacity(1 - min(abs(dragX) / 160, 0.8))

                    Spacer()

                    if pad {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred(); player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                                .foregroundStyle(.primary)
                                .frame(width: 48, height: 48)
                        }
                        .accessibilityLabel("Previous track")
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(); player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(pad ? .title : .title2)
                            .foregroundStyle(.primary)
                            .frame(width: pad ? 48 : nil, height: pad ? 48 : nil)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(); player.next()
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
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // The cover and title follow the finger, sideways only.
                        guard !reduceMotion, abs(value.translation.width) > abs(value.translation.height) else { return }
                        // A tick where letting go starts to skip.
                        if (abs(dragX) < 50) != (abs(value.translation.width) < 50) {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        dragX = value.translation.width
                    }
                    .onEnded { value in
                        let forward = value.translation.width < -50 || value.predictedEndTranslation.width < -100
                        let back = value.translation.width > 50 || value.predictedEndTranslation.width > 100
                        guard forward || back else {
                            withAnimation(.spring(duration: 0.3, bounce: 0)) { dragX = 0 }
                            return
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let skip = { forward ? player.next() : player.previous(restartsFirst: false) }
                        guard !reduceMotion else { skip(); return }
                        // Out the side it was pushed, then the new song comes in from the other.
                        let out: CGFloat = forward ? -220 : 220
                        withAnimation(.easeIn(duration: 0.15)) { dragX = out } completion: {
                            skip()
                            dragX = -out
                            withAnimation(.spring(duration: 0.35, bounce: 0)) { dragX = 0 }
                        }
                    }
            )
        }
    }
}
