import SwiftUI

/// Now Playing, full screen: the cover blurred across the whole screen as on the iPhone, the
/// cover and controls on the left, the lyrics following the song on the right.
struct TVNowPlayingView: View {
    @State private var player = AudioPlayer.shared
    @FocusState private var focus: Control?

    private enum Control: Hashable { case previous, playPause, next }

    var body: some View {
        ZStack {
            TVArtworkBackdrop(coverArt: player.currentSong?.displayCoverArt)
            HStack(alignment: .center, spacing: 90) {
                controls
                if hasLyrics {
                    TVLyricsView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 110)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hasLyrics ? .leading : .center)
        }
        .onPlayPauseCommand { player.togglePlayPause() }
        .onAppear { focus = .playPause }
        .animation(.easeInOut(duration: 0.4), value: hasLyrics)
    }

    private var hasLyrics: Bool { !player.lyrics.isEmpty && !player.lyricsAreInstrumental }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 34) {
            CoverArtImage(coverArt: player.currentSong?.displayCoverArt, size: 600, cornerRadius: 16,
                          placeholderName: player.currentSong?.album ?? player.currentSong?.title)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                .id(player.currentSong?.id)
                .transition(.opacity)

            VStack(alignment: .leading, spacing: 6) {
                Text(player.currentSong?.title ?? "").font(.system(size: 40, weight: .bold))
                Text(player.currentSong?.artist ?? "").font(.system(size: 30)).foregroundStyle(.white.opacity(0.7))
            }
            .lineLimit(1)
            .frame(width: 600, alignment: .leading)

            TVProgress(time: player.currentTime, duration: player.duration).frame(width: 600)

            HStack(spacing: 40) {
                transport("backward.fill", .previous) { player.previous() }
                transport(player.isPlaying ? "pause.fill" : "play.fill", .playPause) { player.togglePlayPause() }
                transport("forward.fill", .next) { player.next() }
            }
            .frame(width: 600)
        }
    }

    private func transport(_ symbol: String, _ control: Control, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: control == .playPause ? 44 : 34, weight: .semibold))
                .frame(width: control == .playPause ? 110 : 90, height: control == .playPause ? 110 : 90)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .focused($focus, equals: control)
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
                VStack(alignment: .leading, spacing: 34) {
                    Spacer().frame(height: 420)
                    ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { index, line in
                        lineView(line, index: index).id(index)
                    }
                    Spacer().frame(height: 520)
                }
            }
            .scrollDisabled(true)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 160)
                    Color.white
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 160)
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
            .font(.system(size: 58, weight: .bold))
            .foregroundStyle(.white.opacity(synced ? (distance == 0 ? 1 : distance == 1 ? 0.35 : 0.14) : 0.85))
            .scaleEffect(!synced || distance == 0 ? 1 : 0.8, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Self.lineChange, value: distance)
    }

    private func track(_ proxy: ScrollViewProxy) {
        guard synced else { return }
        let time = player.lyricsTime
        let index = player.lyrics.lastIndex { ($0.time ?? .infinity) <= time }
        guard index != currentIndex else { return }
        currentIndex = index
        guard let index else { return }
        withAnimation(Self.lineChange) { proxy.scrollTo(index, anchor: .center) }
    }

    private static let lineChange = Animation.spring(response: 0.45, dampingFraction: 0.92)
}
