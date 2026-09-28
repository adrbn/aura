import SwiftUI

/// Aura's screen on the wrist, and the only one at the root: the song playing, as large as
/// the watch can make it.
///
/// The cover fills the display, its corners the display's own, with the title and the
/// transport over its foot and the Crown on the phone's volume. The lyrics are a mode of this
/// same screen, as they are on the phone: the cover draws into the top corner, its blurred
/// field staying behind, and the words rise where the controls stood — the Crown walking the
/// lines now, the play button waiting at the foot. What comes next is pushed from the other
/// corner, and a double tap plays and pauses whichever mode is showing.
struct NowPlayingPage: View {
    @Environment(WatchModel.self) private var model
    @State private var showsLyrics: Bool
    @State private var showsQueue = false
    @Namespace private var morph

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
        return ZStack {
            Hero(isLyrics: lyrics, isPlaying: state.isPlaying, toggle: toggleLyrics)
            if lyrics {
                LyricsMode(state: state)
                    .padding(.top, 42)
                    .padding(.bottom, 46)
                    .transition(.materialize)
            } else {
                Controls(state: state, morph: morph)
                    .transition(.sink)
            }
            footer(state, lyrics: lyrics)
        }
        .ignoresSafeArea()
        .animation(Self.modeChange, value: lyrics)
        .volumeCorner(!lyrics, tint: model.accent)
    }

    /// The display's two bottom corners, and between them — in the lyrics — the play button.
    private func footer(_ state: WatchNowPlaying, lyrics: Bool) -> some View {
        HStack(spacing: 0) {
            CornerButton(symbol: lyrics ? "quote.bubble.fill" : "quote.bubble",
                         label: lyrics ? "Hide Lyrics" : "Show Lyrics",
                         isEnabled: !state.lyrics.isEmpty, action: toggleLyrics)
            Spacer(minLength: 0)
            if lyrics {
                PlayButton(state: state, side: 36)
                    .matchedGeometryEffect(id: "play", in: morph)
            }
            Spacer(minLength: 0)
            CornerButton(symbol: "list.bullet", label: "Up Next") { showsQueue = true }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func toggleLyrics() {
        withAnimation(Self.modeChange) { showsLyrics.toggle() }
    }
}

/// The cover. Full screen, it wears a veil at the top for the clock and one at the foot for
/// the title; in the lyrics it is the small square in the corner, as the phone shrinks its
/// cover beside its lyrics. While paused it draws back, the display's shape and all.
private struct Hero: View {
    let isLyrics: Bool
    let isPlaying: Bool
    let toggle: () -> Void
    @Environment(WatchModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isDimmed

    /// Where the small cover sits: a toolbar button's place beside the clock.
    static let thumbnail: CGFloat = 30
    static let thumbnailCentre = CGPoint(x: 29, y: 24)
    /// The display's own corner, so the full cover and the screen are one shape.
    static let displayCorner: CGFloat = 42

    var body: some View {
        GeometryReader { proxy in
            let full = proxy.size
            let side = Self.thumbnail
            art
                .frame(width: isLyrics ? side : full.width, height: isLyrics ? side : full.height)
                .overlay { veils.opacity(isLyrics ? 0 : 1) }
                .clipShape(RoundedRectangle(cornerRadius: isLyrics ? 7 : Self.displayCorner, style: .continuous))
                .shadow(color: .black.opacity(isPlaying ? 0 : 0.5), radius: 16, y: 6)
                .scaleEffect(isPlaying || isLyrics ? 1 : 0.86)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isPlaying)
                // Always On: a rich image is dimmed, as the system asks.
                .opacity(isDimmed ? 0.45 : 1)
                .position(isLyrics ? Self.thumbnailCentre : CGPoint(x: full.width / 2, y: full.height / 2))
                .onTapGesture(perform: toggle)
                .accessibilityElement()
                .accessibilityLabel(isLyrics ? "Hide Lyrics" : "Show Lyrics")
                .accessibilityAddTraits(.isButton)
        }
    }

    private var art: some View {
        ZStack {
            if let artwork = model.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.state?.artworkId)
        .animation(.easeOut(duration: 0.3), value: model.artwork == nil)
    }

    /// Eased, so neither veil ends in a line.
    private var veils: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.5), location: 0),
                .init(color: .black.opacity(0.18), location: 0.55),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 64)
            Spacer(minLength: 0)
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.35), location: 0.3),
                .init(color: .black.opacity(0.72), location: 0.65),
                .init(color: .black.opacity(0.86), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 160)
        }
        .allowsHitTesting(false)
    }
}

/// The title with the heart beside it, as the phone sets them, over the transport.
private struct Controls: View {
    let state: WatchNowPlaying
    let morph: Namespace.ID
    @Environment(WatchModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isDimmed

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                SongTitle(state: state, direction: model.songDirection)
                FavoriteButton(state: state)
            }
            Transport(state: state, morph: morph)
                .opacity(isDimmed ? 0.5 : 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        // Clear of the corner buttons beneath.
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// A new song slides in from the side it came from — forward from the right, back from the
/// left — and the old one fades where it stood, the phone's own song change.
private struct SongTitle: View {
    let state: WatchNowPlaying
    let direction: Int

    private static let change = Animation.spring(response: 0.45, dampingFraction: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(text: state.title, font: .system(size: 17, weight: .bold), color: .white,
                        alignment: .leading)
            MarqueeText(text: state.artist, font: .system(size: 14), color: .white.opacity(0.72),
                        alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(state.songId)
        .transition(.asymmetric(
            insertion: .offset(x: CGFloat(direction) * 60).combined(with: .opacity),
            removal: .opacity))
        .animation(Self.change, value: state.songId)
    }
}

private struct Transport: View {
    let state: WatchNowPlaying
    let morph: Namespace.ID
    @Environment(WatchModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            skip("backward.fill", label: "Previous") { model.send(.previous) }
            Spacer(minLength: 0)
            PlayButton(state: state, side: 50)
                .matchedGeometryEffect(id: "play", in: morph)
            Spacer(minLength: 0)
            skip("forward.fill", label: "Next") { model.send(.next) }
        }
        .padding(.trailing, 8)
    }

    private func skip(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.82))
        .accessibilityLabel(label)
    }
}

/// Play and pause, in glass, carrying the song's progress as a ring — the watch's own idiom
/// for it. The one a double tap presses: there is only ever one on screen.
private struct PlayButton: View {
    let state: WatchNowPlaying
    let side: CGFloat
    @Environment(WatchModel.self) private var model

    var body: some View {
        let glyph = side * 0.42
        Button { model.send(.playPause) } label: {
            ZStack {
                ProgressRing(state: state, lineWidth: side > 40 ? 3 : 2.5)
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

/// The heart, as on the phone: outlined, the accent once the song is starred, pulsing while
/// the server is asked, and popping when the star lands.
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
            .font(.system(size: 17, weight: .semibold))
            .keyframeAnimator(initialValue: 1.0, trigger: state.isFavorite) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(state.isFavorite ? 1.35 : 1, duration: 0.2, spring: .init(response: 0.28, dampingRatio: 0.45))
                SpringKeyframe(1, duration: 0.3, spring: .init(response: 0.3, dampingRatio: 0.7))
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.85))
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
