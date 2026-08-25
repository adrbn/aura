import SwiftUI

/// The full-window Now Playing screen: artwork on the left, lyrics on the right.
///
/// The Mac's own answer to the phone's sheet. Where the phone has to swap the artwork *for*
/// the lyrics because there is only one column, a window has room for both at once — which
/// is the whole reason to want this on a desktop.
struct MacNowPlayingView: View {
    @State private var player = AudioPlayer.shared
    let close: () -> Void

    var body: some View {
        ZStack {
            background
            HStack(spacing: 0) {
                artworkPane
                lyricsPane
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.black.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .padding(18)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .ignoresSafeArea()
    }

    /// The artwork itself, blown up and blurred past recognition. It gives the screen the
    /// record's own colours without any palette extraction, and it changes with the song.
    private var background: some View {
        ZStack {
            Color.black
            CoverArtImage(coverArt: player.currentSong?.coverArt, size: 900, cornerRadius: 0)
                .blur(radius: 90)
                .opacity(0.55)
                .scaleEffect(1.4)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }

    private var artworkPane: some View {
        VStack(spacing: 22) {
            Spacer()
            CoverArtImage(coverArt: player.currentSong?.coverArt, size: 380, cornerRadius: 16)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
            VStack(spacing: 6) {
                Text(player.currentSong?.title ?? "Nothing playing")
                    .auraDisplay(30)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(player.currentSong?.artist ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 380)
            Spacer()
        }
        .frame(width: 500)
        .frame(maxHeight: .infinity)
    }

    private var lyricsPane: some View {
        Group {
            if player.isLoadingLyrics {
                MacLoadingState()
            } else if player.lyrics.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(player.lyricsStatus.isEmpty ? "No lyrics for this song" : player.lyricsStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacLyricsSheet()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The scrolling lyric sheet, with the word-by-word highlight.
///
/// Same model as the phone — the server's own word timings when it publishes them
/// (OpenSubsonic `songLyrics` v2), and `LyricWordTiming`'s interpolation when it doesn't —
/// but laid out for a wide pane rather than a phone's column.
struct MacLyricsSheet: View {
    @State private var player = AudioPlayer.shared
    @State private var currentIndex: Int?

    private var synced: Bool { player.lyrics.contains { $0.time != nil } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    Spacer().frame(height: 140)
                    ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { index, line in
                        // Only the line being sung redraws on the display link, and only
                        // while playback is moving. Every other line is paused, so it draws
                        // once and costs nothing.
                        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                                paused: index != currentIndex || !player.isPlaying)) { _ in
                            lineView(line: line, index: index)
                        }
                        .id(index)
                    }
                    Spacer().frame(height: 200)
                }
                .padding(.horizontal, 52)
            }
            // Long eased dissolves at both ends, so the sheet thins out into the background
            // rather than being cut off by the edge of the pane.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(gradient: Self.edgeFade, startPoint: .top, endPoint: .bottom)
                        .frame(height: 110)
                    Color.white
                    LinearGradient(gradient: Self.edgeFade, startPoint: .bottom, endPoint: .top)
                        .frame(height: 110)
                }
            )
            .onChange(of: player.currentTime) { _, _ in track(proxy: proxy) }
            .onChange(of: player.currentSong?.id) { _, _ in currentIndex = nil }
        }
    }

    private func lineView(line: LyricsLine, index: Int) -> some View {
        let distance = currentIndex.map { abs(index - $0) } ?? 0
        let isCurrent = index == currentIndex
        return text(for: line, isCurrent: isCurrent)
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.white.opacity(synced ? opacity(distance) : 0.8))
            .blur(radius: synced ? blur(distance) : 0)
            .scaleEffect(isCurrent || !synced ? 1 : 0.86, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if let time = line.time { player.seek(to: time) } }
            .animation(.easeOut(duration: 0.35), value: distance)
    }

    /// Sung words go solid, the rest stay dim but legible so the eye can read ahead. The
    /// 90ms ramp is what stops a word snapping on; it is drawn per frame by the
    /// `TimelineView` above, so it is smooth rather than sampled at the playback tick.
    private func text(for line: LyricsLine, isCurrent: Bool) -> Text {
        guard isCurrent, synced,
              let words = karaokeWords(line: line),
              !words.isEmpty
        else { return Text(line.text) }
        let time = player.liveLyricsTime
        return words.reduce(Text("")) { partial, word in
            let elapsed = time - word.start
            let lit = elapsed <= 0 ? 0 : min(1, elapsed / 0.09)
            return partial + Text(word.text)
                .foregroundColor(.white.opacity(0.35 + 0.65 * lit))
        }
    }

    private func karaokeWords(line: LyricsLine) -> [LyricWord]? {
        guard AppSettings.shared.betaKaraokeLyrics else { return nil }
        if let real = line.words, !real.isEmpty { return real }
        guard let start = line.time,
              let index = player.lyrics.firstIndex(where: { $0.id == line.id }),
              let end = LyricWordTiming.lineEnd(lines: player.lyrics, index: index)
        else { return nil }
        return LyricWordTiming.words(in: line.text, start: start, end: end)
    }

    private func opacity(_ distance: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1: return 0.28
        default: return 0
        }
    }

    private func blur(_ distance: Int) -> CGFloat {
        switch distance {
        case 0: return 0
        case 1: return 5
        default: return 11
        }
    }

    /// Follows the song, and scrolls only when the line actually changes — not on every
    /// playback tick, which would fight any manual scrolling continuously.
    private func track(proxy: ScrollViewProxy) {
        guard synced else { return }
        let time = player.lyricsTime
        let index = player.lyrics.lastIndex { ($0.time ?? .infinity) <= time }
        guard index != currentIndex else { return }
        currentIndex = index
        guard let index else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private static let edgeFade = Gradient(stops: [
        .init(color: .clear, location: 0.00),
        .init(color: .white.opacity(0.06), location: 0.25),
        .init(color: .white.opacity(0.22), location: 0.50),
        .init(color: .white.opacity(0.55), location: 0.75),
        .init(color: .white, location: 1.00),
    ])
}
