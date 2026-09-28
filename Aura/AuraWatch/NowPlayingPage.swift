import SwiftUI
import WatchKit

/// What's playing on the phone, and the buttons to steer it. The Digital Crown sets the
/// phone's volume, as it does in the watch's own Now Playing.
struct NowPlayingPage: View {
    /// The Crown goes to the volume only while this page is the one showing: the lyrics
    /// and the queue need it to scroll.
    let isCurrent: Bool
    @Environment(WatchModel.self) private var model

    var body: some View {
        ZStack {
            backdrop
            if let state = model.state, state.songId != nil {
                player(state)
            } else {
                idle
            }
        }
    }

    /// The cover, blurred and darkened to the app's #121212 — the page tint of the phone.
    private var backdrop: some View {
        ZStack {
            Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
            if let artwork = model.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .opacity(0.45)
            }
        }
        .ignoresSafeArea()
    }

    private func player(_ state: WatchNowPlaying) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cover
                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: state.title, font: .headline, color: .white, alignment: .leading)
                    MarqueeText(text: state.artist, font: .footnote, color: .white.opacity(0.6),
                                alignment: .leading)
                }
            }
            progress(state)
            controls(state)
            HStack {
                favorite(state)
                Spacer()
                CompanionVolume(tint: model.accent, isFocused: isCurrent)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 4)
    }

    private var cover: some View {
        Group {
            if let artwork = model.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08))
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func progress(_ state: WatchNowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = state.elapsed(at: context.date)
            let fraction = state.duration > 0 ? min(1, elapsed / state.duration) : 0
            VStack(spacing: 2) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 3)
                HStack {
                    Text(Self.clock(elapsed))
                    Spacer()
                    Text("-" + Self.clock(max(0, state.duration - elapsed)))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func controls(_ state: WatchNowPlaying) -> some View {
        HStack {
            button("backward.fill", label: "Previous", size: 20) { model.send(.previous) }
            Spacer()
            button(state.isPlaying ? "pause.fill" : "play.fill",
                   label: state.isPlaying ? "Pause" : "Play", size: 30) { model.send(.playPause) }
            Spacer()
            button("forward.fill", label: "Next", size: 20) { model.send(.next) }
        }
        .padding(.horizontal, 6)
    }

    private func button(_ symbol: String, label: LocalizedStringKey, size: CGFloat,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func favorite(_ state: WatchNowPlaying) -> some View {
        if state.canFavorite {
            Button { model.send(.favorite) } label: {
                Group {
                    if state.isSavingFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.white.opacity(0.75))
                            .symbolEffect(.pulse, options: .repeating)
                    } else {
                        Image(systemName: state.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(state.isFavorite ? model.accent : .white.opacity(0.7))
                    }
                }
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isSavingFavorite)
            .accessibilityLabel(state.isFavorite ? "Remove from favourites" : "Add to favourites")
        } else {
            Color.clear.frame(width: 32, height: 32)
        }
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.5))
            if model.isReachable {
                Text("Nothing playing")
                    .font(.headline)
                Button("Play Something") { model.send(.playSomething) }
                    .tint(model.accent)
            } else {
                Text("Open Aura on your iPhone")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding()
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The watch's volume control, turned towards the phone: the Crown sets the iPhone's volume.
private struct CompanionVolume: WKInterfaceObjectRepresentable {
    let tint: Color
    let isFocused: Bool

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .companion)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.setTintColor(UIColor(tint))
        if isFocused { control.focus() } else { control.resignFocus() }
    }
}
