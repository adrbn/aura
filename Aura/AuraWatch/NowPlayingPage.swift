import SwiftUI

/// Aura's screen on the wrist, and the only one at the root: the song playing, laid out as
/// the phone lays it out — the cover over its own blurred colours, the title under it — with
/// the controls in one row along the display's foot and the Crown on the phone's volume.
///
/// The lyrics are a mode of this same screen, as on the phone: the cover draws into the top
/// corner where the heart was and the words take its place, the Crown walking the lines. The
/// row at the foot never moves: lyrics, previous, play, next, and what comes next — pushed
/// from the far corner. A double tap plays and pauses in either mode.
struct NowPlayingPage: View {
    @Environment(WatchModel.self) private var model
    @State private var showsLyrics: Bool
    @State private var showsQueue = false

    /// Settles as the phone's cover does when it moves: quick, without a bounce.
    static let modeChange = Animation.spring(response: 0.5, dampingFraction: 0.86)

    init(showsLyrics: Bool = false) {
        _showsLyrics = State(initialValue: showsLyrics)
    }

    var body: some View {
        Group {
            if let state = model.state, state.songId != nil {
                player(state)
            } else {
                IdlePage()
            }
        }
        .screenBackdrop()
        .navigationDestination(isPresented: $showsQueue) { UpNextPage() }
    }

    private func player(_ state: WatchNowPlaying) -> some View {
        // A song without words falls back to the cover; the mode returns with the next one
        // that has them, as the phone's does.
        let lyrics = showsLyrics && !state.lyrics.isEmpty
        return GeometryReader { proxy in
            let layout = PlayerLayout(size: proxy.size)
            ZStack {
                if lyrics {
                    LyricsMode(state: state)
                        .frame(width: proxy.size.width, height: layout.lyricsHeight)
                        .position(x: proxy.size.width / 2, y: layout.lyricsCentre)
                        .transition(.materialize)
                } else {
                    SongTitle(state: state, direction: model.songDirection)
                        .frame(width: proxy.size.width - 32)
                        .position(x: proxy.size.width / 2, y: layout.titleCentre)
                        .transition(.sink)
                    FavoriteButton(state: state)
                        .position(PlayerLayout.corner)
                        .transition(.opacity)
                }
                SongCover(isLyrics: lyrics, isPlaying: state.isPlaying, toggle: toggleLyrics)
                    .frame(width: lyrics ? PlayerLayout.thumbnail : layout.coverSide,
                           height: lyrics ? PlayerLayout.thumbnail : layout.coverSide)
                    .position(lyrics ? PlayerLayout.corner : layout.coverCentre)
                ControlRow(state: state, showsLyrics: lyrics, toggleLyrics: toggleLyrics) {
                    showsQueue = true
                }
                .frame(width: proxy.size.width)
                .position(x: proxy.size.width / 2, y: layout.rowCentre)
            }
        }
        .ignoresSafeArea()
        .animation(Self.modeChange, value: lyrics)
        .volumeCorner(!lyrics, tint: model.accent)
    }

    private func toggleLyrics() {
        withAnimation(Self.modeChange) { showsLyrics.toggle() }
    }
}

/// Where things sit, worked out from the display's size so a smaller watch keeps the
/// proportions: the clock's band at the top, the row of controls at the foot, and the cover
/// and the title sharing what lies between.
private struct PlayerLayout {
    let size: CGSize

    /// Below the clock's band.
    static let top: CGFloat = 42
    /// A toolbar item's place beside the clock, set in from the display's curve: the heart's,
    /// then the small cover's.
    static let corner = CGPoint(x: 29, y: 24)
    static let thumbnail: CGFloat = 30
    private static let rowHeight: CGFloat = 46
    private static let titleHeight: CGFloat = 36
    private static let gap: CGFloat = 6

    var rowCentre: CGFloat { size.height - 29 }
    private var rowTop: CGFloat { rowCentre - Self.rowHeight / 2 }
    var titleCentre: CGFloat { rowTop - Self.gap - Self.titleHeight / 2 }
    var coverSide: CGFloat {
        min(size.width * 0.56, titleCentre - Self.titleHeight / 2 - Self.gap - Self.top)
    }
    var coverCentre: CGPoint { CGPoint(x: size.width / 2, y: Self.top + coverSide / 2) }
    var lyricsHeight: CGFloat { rowTop - 4 - Self.top }
    var lyricsCentre: CGFloat { Self.top + lyricsHeight / 2 }
}

/// The cover, as a card over its own blurred colours, the phone's Now Playing at the
/// watch's scale. In the lyrics it is the small square in the corner, as the phone shrinks its
/// cover beside its lyrics; while paused it draws back, as the phone's does.
private struct SongCover: View {
    let isLyrics: Bool
    let isPlaying: Bool
    let toggle: () -> Void
    @Environment(WatchModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isDimmed

    var body: some View {
        ZStack {
            if let artwork = model.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.state?.artworkId)
        .animation(.easeOut(duration: 0.3), value: model.artwork == nil)
        .clipShape(RoundedRectangle(cornerRadius: isLyrics ? 7 : 12, style: .continuous))
        .shadow(color: .black.opacity(isLyrics ? 0.2 : 0.4), radius: isLyrics ? 4 : 12, y: isLyrics ? 2 : 6)
        .scaleEffect(isPlaying || isLyrics ? 1 : 0.85)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isPlaying)
        // Always On: a rich image is dimmed, as the system asks.
        .opacity(isDimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement()
        .accessibilityLabel(isLyrics ? "Hide Lyrics" : "Show Lyrics")
        .accessibilityAddTraits(.isButton)
    }
}

/// A new song slides in from the side it came from — forward from the right, back from the
/// left — and the old one fades where it stood, the phone's own song change.
private struct SongTitle: View {
    let state: WatchNowPlaying
    let direction: Int

    private static let change = Animation.spring(response: 0.45, dampingFraction: 0.85)

    var body: some View {
        VStack(spacing: 0) {
            MarqueeText(text: state.title, font: .system(size: 16, weight: .bold), color: .white)
            MarqueeText(text: state.artist, font: .system(size: 14), color: .white.opacity(0.7))
        }
        .id(state.songId)
        .transition(.asymmetric(
            insertion: .offset(x: CGFloat(direction) * 60).combined(with: .opacity),
            removal: .opacity))
        .animation(Self.change, value: state.songId)
    }
}

/// The one row along the display's foot, the same in both modes: the lyrics and the queue
/// in the corners, the transport between them.
private struct ControlRow: View {
    let state: WatchNowPlaying
    let showsLyrics: Bool
    let toggleLyrics: () -> Void
    let openQueue: () -> Void
    @Environment(WatchModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isDimmed

    var body: some View {
        HStack(spacing: 0) {
            CornerButton(symbol: showsLyrics ? "quote.bubble.fill" : "quote.bubble",
                         label: showsLyrics ? "Hide Lyrics" : "Show Lyrics",
                         isEnabled: !state.lyrics.isEmpty, action: toggleLyrics)
            Spacer(minLength: 0)
            skip("backward.fill", label: "Previous") { model.send(.previous) }
            Spacer(minLength: 0)
            PlayButton(state: state, side: 46)
            Spacer(minLength: 0)
            skip("forward.fill", label: "Next") { model.send(.next) }
            Spacer(minLength: 0)
            CornerButton(symbol: "list.bullet", label: "Up Next", action: openQueue)
        }
        .padding(.horizontal, 12)
        .opacity(isDimmed ? 0.5 : 1)
    }

    private func skip(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.82))
        .accessibilityLabel(label)
    }
}

/// Play and pause, in glass, carrying the song's progress as a ring — the watch's own idiom
/// for it, and the one button a double tap presses.
private struct PlayButton: View {
    let state: WatchNowPlaying
    let side: CGFloat
    @Environment(WatchModel.self) private var model

    var body: some View {
        let glyph = side * 0.4
        Button { model.send(.playPause) } label: {
            ZStack {
                ProgressRing(state: state, lineWidth: 3)
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: glyph))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: side, height: side)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(Pressable(scale: 0.9))
        .primaryAction()
        .sensoryFeedback(.selection, trigger: state.isPlaying)
        .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
    }
}

/// How far into the song: a faint track and the elapsed part in white, as the phone's
/// progress bar is.
private struct ProgressRing: View {
    let state: WatchNowPlaying
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = state.elapsed(at: context.date)
            let fraction = state.duration > 0 ? min(1, elapsed / state.duration) : 0
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
            }
            .padding(lineWidth / 2)
        }
        .accessibilityHidden(true)
    }
}

/// A button in one of the display's bottom corners, in glass, set in far enough that the
/// corner's curve never cuts it.
private struct CornerButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(Pressable(scale: 0.88))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// The heart, in the corner beside the clock: outlined, the accent once the song is starred,
/// pulsing while the server is asked, and popping when the star lands, as on the phone.
private struct FavoriteButton: View {
    let state: WatchNowPlaying
    @Environment(WatchModel.self) private var model

    var body: some View {
        Button { model.send(.favorite) } label: {
            Group {
                if state.isSavingFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.white.opacity(0.75))
                        .symbolEffect(.pulse, options: .repeating)
                } else {
                    Image(systemName: state.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(state.isFavorite ? model.accent : .white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .keyframeAnimator(initialValue: 1.0, trigger: state.isFavorite) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(state.isFavorite ? 1.35 : 1, duration: 0.2, spring: .init(response: 0.28, dampingRatio: 0.45))
                SpringKeyframe(1, duration: 0.3, spring: .init(response: 0.3, dampingRatio: 0.7))
            }
            .frame(width: 30, height: 30)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(Pressable(scale: 0.88))
        .disabled(!state.canFavorite || state.isSavingFavorite)
        .opacity(state.canFavorite ? 1 : 0.35)
        .sensoryFeedback(.success, trigger: state.isFavorite) { was, now in !was && now }
        .accessibilityLabel(state.isFavorite ? "Remove from favourites" : "Add to favourites")
    }
}

/// Nothing playing: the phone's time-of-day glow, and one thing to do about it.
private struct IdlePage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("aura")
                .font(.custom("VavinCondensed-Bold", size: 46))
                .foregroundStyle(.white)
            Text(model.isReachable ? "Nothing playing" : "Open Aura on your iPhone")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 10)
            if model.isReachable {
                Button { model.send(.playSomething) } label: {
                    Label("Play Something", systemImage: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(model.accent)
                // Clear of the display's rounded foot.
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 14)
    }
}

private extension AnyTransition {
    /// The controls sink as the lyrics come up, and rise back after them.
    static var sink: AnyTransition { .offset(y: 30).combined(with: .opacity) }

    /// The lyrics arrive out of focus and sharpen, as a material arrives rather than fades.
    static var materialize: AnyTransition {
        .modifier(active: Focus(amount: 0), identity: Focus(amount: 1)).combined(with: .offset(y: 18))
    }
}

private struct Focus: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - amount) * 8)
            .opacity(amount)
    }
}

/// Answers the press itself, before the tap lands: a quick give under the finger.
struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: configuration.isPressed)
    }
}
