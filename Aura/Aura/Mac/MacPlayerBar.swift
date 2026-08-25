import SwiftUI

/// The window's transport, pinned to the bottom across the whole width.
///
/// The Mac equivalent of the phone's mini player, but it does not open anything: there is
/// room here for the scrubber, the times and the queue controls that the phone has to hide
/// behind a full-screen sheet.
struct MacPlayerBar: View {
    @State private var player = AudioPlayer.shared
    @State private var showQueue = false
    @State private var showEqualizer = false

    /// Where the scrubber sits while it is being dragged.
    ///
    /// Playback keeps reporting its own position throughout, so binding the slider straight
    /// to `currentTime` would let each report yank the knob back out from under the pointer.
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 16) {
            nowPlaying
            Spacer(minLength: 12)
            VStack(spacing: 4) {
                transport
                scrubber
            }
            .frame(maxWidth: 560)
            Spacer(minLength: 12)
            secondaryControls
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(height: 78)
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
        HStack(spacing: 11) {
            // Opens the full Now Playing screen — artwork and lyrics side by side. The
            // artwork is the affordance everyone tries first.
            Button {
                guard player.currentSong != nil else { return }
                withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying = true }
            } label: {
                CoverArtImage(coverArt: player.currentSong?.coverArt, size: 52, cornerRadius: 6)
            }
            .buttonStyle(.plain)
            .help("Now Playing")
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(player.currentSong?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if player.currentSong != nil {
                Button {
                    player.toggleFavorite()
                } label: {
                    Image(systemName: player.currentSong?.starred != nil ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)
                .foregroundStyle(player.currentSong?.starred != nil ? Color.appAccent : .secondary)
                .help("Favourite")
            }
        }
        .frame(width: 280, alignment: .leading)
    }

    // MARK: Centre — transport and scrubber

    private var transport: some View {
        HStack(spacing: 20) {
            Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                .foregroundStyle(player.isShuffled ? Color.appAccent : .secondary)
                .help("Shuffle")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .help("Previous")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 26)
            }
            .help(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .help("Next")
            Button { cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
            }
            .foregroundStyle(player.repeatMode == .off ? .secondary : Color.appAccent)
            .help("Repeat")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .disabled(player.currentSong == nil)
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(MacFormat.time(scrubbing ?? player.currentTime))
                .monospacedDigit()
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
                .monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .disabled(player.currentSong == nil || player.duration <= 0)
    }

    // MARK: Right — queue and EQ

    private var secondaryControls: some View {
        HStack(spacing: 16) {
            Button {
                guard player.currentSong != nil else { return }
                withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying.toggle() }
            } label: { Image(systemName: "quote.bubble") }
                .foregroundStyle(player.isShowingNowPlaying ? Color.appAccent : .secondary)
                .help("Lyrics")
            Button { showEqualizer.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .foregroundStyle(EqualizerManager.shared.isEnabled ? Color.appAccent : .secondary)
                .help("Equaliser")
            Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .foregroundStyle(.secondary)
                .help("Queue")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .frame(width: 280, alignment: .trailing)
    }

    private func cycleRepeat() {
        player.repeatMode = switch player.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}
