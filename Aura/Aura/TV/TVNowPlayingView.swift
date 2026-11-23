import SwiftUI

/// Now Playing, full screen: the cover blurred across the whole screen as on the iPhone, the
/// cover and controls on the left, the lyrics following the song on the right.
struct TVNowPlayingView: View {
    /// Shown as the Now Playing tab: focus stays in the tab bar until the remote moves down,
    /// so passing over the tab on the way to another doesn't pull focus into the player.
    var inTab = false
    @State private var player = AudioPlayer.shared
    @FocusState private var focus: Control?
    @AppStorage(RemoteLink.tvLyricsKey) private var showLyrics = true
    /// Left alone, the screen keeps only the cover, the song and the lyrics: a picture for the room.
    @State private var idle = false
    @State private var lastInput = Date()
    @State private var showQueue = false
    private static let idleDelay: TimeInterval = 5
    private static let queueWidth: CGFloat = 760

    private enum Control: Hashable { case like, shuffle, previous, playPause, next, repeatMode, lyrics, queue
        /// The whole screen, focused while the controls are away so a press brings them back.
        case surface }

    var body: some View {
        ZStack {
            TVArtworkBackdrop(coverArt: player.currentSong?.displayCoverArt)
            // Cover and lyrics as one centred group, the same room on either side of the screen.
            HStack(alignment: .center, spacing: 120) {
                controls
                if hasLyrics && !showQueue {
                    TVLyricsView().frame(width: 820, height: 640)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The queue pushes the cover aside instead of covering it.
            .padding(.trailing, showQueue ? Self.queueWidth : 0)
            .disabled(showQueue)

            // Up Next slides in from the right edge, over the lyrics, as on the Mac.
            if showQueue {
                TVUpNextView { showQueue = false }
                    .frame(width: Self.queueWidth)
                    .frame(maxHeight: .infinity)
                    .background(.black.opacity(0.6))
                    .background(.ultraThinMaterial)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
                    .focusSection()
                    .onExitCommand { showQueue = false }
            }
        }
        .focusable(idle)
        .focused($focus, equals: .surface)
        .focusEffectDisabled()
        .onTapGesture { poke() }
        .onMoveCommand { _ in poke() }
        .onPlayPauseCommand { poke(); player.togglePlayPause() }
        .onAppear {
            if !inTab { focus = .playPause }
            #if DEBUG
            // `-tvQueue` opens Up Next, for screenshots in the simulator.
            if CommandLine.arguments.contains("-tvQueue") { showQueue = true }
            #endif
        }
        .onChange(of: focus) { _, new in if new != .surface { poke() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !idle, !showQueue, Date().timeIntervalSince(lastInput) > Self.idleDelay {
                    idle = true
                    focus = .surface
                }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: idle)
        .animation(.easeInOut(duration: 0.4), value: hasLyrics)
        .animation(.easeInOut(duration: 0.35), value: showQueue)
        .onChange(of: showQueue) { _, open in if !open { lastInput = Date(); focus = .queue } }
    }

    private var lyricsAvailable: Bool { !player.lyrics.isEmpty && !player.lyricsAreInstrumental }
    private var hasLyrics: Bool { showLyrics && lyricsAvailable }

    private func poke() {
        lastInput = Date()
        guard idle else { return }
        idle = false
        focus = .playPause
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 34) {
            CoverArtImage(coverArt: player.currentSong?.displayCoverArt, size: 560, cornerRadius: 16,
                          placeholderName: player.currentSong?.album ?? player.currentSong?.title)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                .id(player.currentSong?.id)
                .transition(.opacity)

            VStack(spacing: 6) {
                Text(player.currentSong?.title ?? "").font(.system(size: 40, weight: .bold))
                Text(player.currentSong?.artist ?? "").font(.system(size: 30)).foregroundStyle(.white.opacity(0.7))
            }
            .lineLimit(1)
            .frame(width: 560)

            if !idle {
                TVProgress(time: player.currentTime, duration: player.duration).frame(width: 560)
                    .transition(.opacity)

                // Three either side of play/pause, so it stands at the centre. The heart is a
                // long press on play/pause, as the TV's own music app keeps it off the row.
                HStack(spacing: 6) {
                    transport("quote.bubble", .lyrics, on: showLyrics && lyricsAvailable) { showLyrics.toggle() }
                    transport("shuffle", .shuffle, on: player.isShuffled) { player.toggleShuffle() }
                    transport("backward.fill", .previous) { player.previous() }
                    transport(player.isPlaying ? "pause.fill" : "play.fill", .playPause) { player.togglePlayPause() }
                        .contextMenu {
                            Button(player.currentSong?.isStarred == true ? "Unfavorite" : "Favorite",
                                   systemImage: player.currentSong?.isStarred == true ? "heart.slash" : "heart") {
                                player.toggleFavorite()
                            }
                        }
                    transport("forward.fill", .next) { player.next() }
                    transport(player.repeatMode.systemImage, .repeatMode, on: player.repeatMode != .off) { player.cycleRepeat() }
                    transport("list.bullet", .queue) { showQueue = true }
                }
                .transition(.opacity)
            }
        }
    }

    private func transport(_ symbol: String, _ control: Control, on: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button {
            poke(); action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: control == .playPause ? 34 : 24, weight: .semibold))
                .frame(width: control == .playPause ? 80 : 60, height: control == .playPause ? 80 : 60)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(TVQuietButtonStyle(dimmed: on == false))
        .focused($focus, equals: control)
    }
}

/// What plays next: tap a song to jump to it, hold it to take it out of the queue.
private struct TVUpNextView: View {
    let close: () -> Void
    @State private var player = AudioPlayer.shared
    @FocusState private var focused: Int?

    private var upcoming: [(index: Int, song: Song)] {
        let start = player.queueIndex + 1
        guard start < player.queue.count else { return [] }
        return (start..<player.queue.count).map { ($0, player.queue[$0]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack {
                Text("Up Next").font(.system(size: 48, weight: .bold))
                Spacer()
                if !upcoming.isEmpty { Button("Clear") { player.clearUpNext() } }
            }
            if upcoming.isEmpty {
                Text("Nothing queued").font(.system(size: 30)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(upcoming, id: \.index) { item in
                            TVSongRow(song: item.song, showsArtwork: true) {
                                player.playSong(item.song, fromQueue: player.queue, startIndex: item.index, source: .queue)
                                close()
                            }
                            .focused($focused, equals: item.index)
                            .contextMenu {
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    player.removeFromQueue(at: item.index)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
                // Songs fade out at the bottom edge, where the list carries on.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 70)
        // Opens on the next song rather than on Clear.
        .onAppear { focused = upcoming.first?.index }
    }
}

/// A transport button that stays out of the picture: a bare glyph, its circle only showing under focus,
/// so the screen reads as the cover and the lyrics when no one is holding the remote.
private struct TVQuietButtonStyle: ButtonStyle {
    var dimmed = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(focused ? 1 : dimmed ? 0.3 : 0.6))
            .background(Circle().fill(.white.opacity(focused ? 0.18 : 0)))
            .scaleEffect(configuration.isPressed ? 0.94 : focused ? 1.1 : 1)
            .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// The song's position: a thin bar with the time gone and the time left under it.
struct TVProgress: View {
    let time: TimeInterval
    let duration: TimeInterval

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
            HStack {
                Text(Self.format(time))
                Spacer()
                Text("-" + Self.format(max(0, duration - time)))
            }
            .font(.system(size: 22, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / duration)))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? seconds : 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The phone's Now Playing ground: the cover, enlarged past the screen's edges and blurred, under
/// a dark veil so white text reads on any picture.
struct TVArtworkBackdrop: View {
    let coverArt: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.canvas
                CoverArtImage(coverArt: coverArt, size: 600, cornerRadius: 0)
                    .scaleEffect(max(geo.size.width, geo.size.height) / 600 * 1.3)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 90)
                    .saturation(1.3)
                    .id(coverArt)
                    .transition(.opacity)
                Color.black.opacity(0.42)
            }
            .animation(.easeInOut(duration: 0.8), value: coverArt)
        }
        .clipped()
        .ignoresSafeArea()
    }
}

/// The lyrics, the sung line large and white, the next one dim, scrolling with the song.
struct TVLyricsView: View {
    @State private var player = AudioPlayer.shared
    @State private var currentIndex: Int?

    private var synced: Bool { player.lyrics.contains { $0.time != nil } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    Spacer().frame(height: 320)
                    ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { index, line in
                        lineView(line, index: index).id(index)
                    }
                    Spacer().frame(height: 360)
                }
            }
            .scrollDisabled(true)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 120)
                    Color.white
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
                }
            )
            .onChange(of: player.currentTime) { _, _ in track(proxy) }
            .onChange(of: player.currentSong?.id) { _, _ in
                currentIndex = nil
                proxy.scrollTo(0, anchor: .top)
            }
        }
    }

    private func lineView(_ line: LyricsLine, index: Int) -> some View {
        let focus = currentIndex ?? 0
        let distance = abs(index - focus)
        return Text(line.text)
            .font(.system(size: 64, weight: .bold))
            // The line sung large and white, two either side of it, the rest gone.
            .foregroundStyle(.white.opacity(synced ? (distance == 0 ? 1 : distance == 1 ? 0.32 : distance == 2 ? 0.12 : 0) : 0.85))
            .scaleEffect(!synced || distance == 0 ? 1 : 0.7, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Self.lineChange, value: distance)
    }

    private func track(_ proxy: ScrollViewProxy) {
        let index: Int?
        if synced {
            let time = player.lyricsTime
            index = player.lyrics.lastIndex { ($0.time ?? .infinity) <= time }
        } else {
            // No timing: the sheet moves through at the song's pace, so the words stay roughly
            // where the singer is instead of sitting on the first lines all song long.
            guard player.duration > 0, !player.lyrics.isEmpty else { return }
            let progress = min(max(player.currentTime / player.duration, 0), 1)
            index = min(player.lyrics.count - 1, Int(progress * Double(player.lyrics.count)))
        }
        guard index != currentIndex else { return }
        currentIndex = index
        guard let index else { return }
        withAnimation(Self.lineChange) { proxy.scrollTo(index, anchor: .center) }
    }

    private static let lineChange = Animation.spring(response: 0.45, dampingFraction: 0.92)
}
