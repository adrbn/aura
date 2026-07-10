import ActivityKit
import SwiftUI
import WidgetKit
import AppIntents

struct MusicLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MusicPlaybackAttributes.self) { context in
            // Lock Screen / StandBy banner
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    coverArtView(urlString: context.state.coverArtURL, size: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.songTitle)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 12) {
                        Button(intent: PreviousTrackIntent()) {
                            Image(systemName: "backward.fill")
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        Button(intent: NextTrackIntent()) {
                            Image(systemName: "forward.fill")
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: progressValue(context.state), total: 1.0)
                        .tint(Color.pink)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            } compactLeading: {
                coverArtView(urlString: context.state.coverArtURL, size: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<MusicPlaybackAttributes>) -> some View {
        HStack(spacing: 12) {
            coverArtView(urlString: context.state.coverArtURL, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.songTitle)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(context.state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: progressValue(context.state), total: 1.0)
                    .tint(Color.pink)
            }

            Spacer()

            HStack(spacing: 16) {
                Button(intent: PreviousTrackIntent()) {
                    Image(systemName: "backward.fill")
                        .font(.body)
                }
                .buttonStyle(.plain)
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                Button(intent: NextTrackIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func coverArtView(urlString: String?, size: CGFloat) -> some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 8 : 4))
        } else {
            Image(systemName: "music.note")
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }

    private func progressValue(_ state: MusicPlaybackAttributes.ContentState) -> Double {
        guard state.duration > 0 else { return 0 }
        return min(state.elapsed / state.duration, 1.0)
    }
}
