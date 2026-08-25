import SwiftUI

/// The window's transport, across the full width at the bottom.
///
/// Three columns of fixed width, not a stack of flexible spacers: the transport has to stay
/// dead centre in the *window* whatever the title is called, and the only way to guarantee
/// that is to give the flanks equal weight rather than letting the content decide.
struct MacPlayerBar: View {
    @State private var player = AudioPlayer.shared
    @State private var showQueue = false
    @State private var showEqualizer = false

    /// Where the scrubber sits while it is being dragged.
    ///
    /// Playback keeps reporting its own position throughout, so binding the slider straight
    /// to `currentTime` would let each report yank the knob out from under the pointer.
    @State private var scrubbing: Double?

    private var song: Song? { player.currentSong }
    private let flank: CGFloat = 320

    var body: some View {
        HStack(spacing: 20) {
            nowPlaying
            centre
            secondary
        }
        .padding(.horizontal, 20)
        .frame(height: 92)
        // A wash rather than a bar. It has to separate itself from the artwork scrolling
        // behind it without becoming a second, opaque surface.
        .background(.black.opacity(0.35))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
        }
        .popover(isPresented: $showQueue, arrowEdge: .top) { MacQueueView() }
        .popover(isPresented: $showEqualizer, arrowEdge: .top) { MacEqualizerView() }
    }

    // MARK: Left — what is playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Button {
                guard song != nil else { return }
                withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying = true }
            } label: {
                CoverArtImage(coverArt: song?.coverArt, size: 60, cornerRadius: 7)
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
            .help("Now Playing")

            VStack(alignment: .leading, spacing: 3) {
                Text(song?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(song?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if song != nil {
                Button { player.toggleFavorite() } label: {
                    Image(systemName: song?.starred != nil ? "heart.fill" : "heart")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(song?.starred != nil ? Color.appAccent : .secondary)
                .help("Favourite")
            }
            Spacer(minLength: 0)
        }
        .frame(width: flank, alignment: .leading)
    }

    // MARK: Centre — transport and scrubber

    private var centre: some View {
        VStack(spacing: 7) {
            HStack(spacing: 24) {
                iconButton("shuffle", active: player.isShuffled, help: "Shuffle") {
                    player.toggleShuffle()
                }
                iconButton("backward.fill", size: 16, help: "Previous") { player.previous() }

                // The one control that has to be found without looking.
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(song == nil)
                .opacity(song == nil ? 0.4 : 1)
                .help(player.isPlaying ? "Pause" : "Play")

                iconButton("forward.fill", size: 16, help: "Next") { player.next() }
                iconButton(player.repeatMode == .one ? "repeat.1" : "repeat",
                           active: player.repeatMode != .off, help: "Repeat") { cycleRepeat() }
            }

            scrubber
        }
        .frame(maxWidth: 620)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(MacFormat.time(scrubbing ?? player.currentTime))
                .frame(width: 38, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.currentTime },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    // Seek on release, not continuously: every intermediate value would be
                    // another seek, and the player would spend the whole drag catching up.
                    guard !editing, let target = scrubbing else { return }
                    player.seek(to: target)
                    scrubbing = nil
                }
            )
            .controlSize(.mini)
            Text("-" + MacFormat.time(max(0, player.duration - (scrubbing ?? player.currentTime))))
                .frame(width: 38, alignment: .leading)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
        .disabled(song == nil || player.duration <= 0)
    }

    // MARK: Right — lyrics, EQ, queue, volume

    private var secondary: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 0)
            iconButton("quote.bubble", active: player.isShowingNowPlaying, help: "Lyrics") {
                guard song != nil else { return }
                withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying.toggle() }
            }
            iconButton("slider.horizontal.3", active: EqualizerManager.shared.isEnabled,
                       help: "Equaliser") { showEqualizer.toggle() }
            iconButton("list.bullet", help: "Queue") { showQueue.toggle() }

            HStack(spacing: 6) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 78)
            }
            .help("Volume")
        }
        .frame(width: flank, alignment: .trailing)
    }

    private var volumeSymbol: String {
        switch player.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func iconButton(_ symbol: String, size: CGFloat = 13, active: Bool = false,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.appAccent : .secondary)
        .help(help)
    }

    private func cycleRepeat() {
        player.repeatMode = switch player.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}
