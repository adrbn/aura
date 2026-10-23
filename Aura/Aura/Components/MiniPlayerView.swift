import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var showMacRemote = false

    var body: some View {
        if let mac = RemoteLink.shared.connected {
            remote(on: mac.displayName, RemoteLink.shared.state ?? RemoteLink.State())
        } else if let song = player.currentSong {
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

    /// While the phone controls a Mac: what the Mac plays, and a band in the accent saying so.
    private func remote(on name: String, _ state: RemoteLink.State) -> some View {
        Button { showMacRemote = true } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    CoverArtImage(coverArt: state.coverArt, size: 44, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title ?? String(localized: "Nothing playing"))
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(state.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { RemoteLink.shared.send(.playPause) } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
                    Button { RemoteLink.shared.send(.next) } label: {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .accessibilityLabel("Next track")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Label(String(localized: "Playing on \(name)"), systemImage: "macbook")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16)
        .sheet(isPresented: $showMacRemote) { MacRemoteView() }
    }
}
