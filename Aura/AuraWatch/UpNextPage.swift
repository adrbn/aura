import SwiftUI

/// What plays after this song, pushed from Now Playing's corner, under a title set as the
/// phone sets its page titles. The song playing leads, with its cover; then Play Next, marked
/// in the accent, then the rest of the queue. Rows are plain on the blurred cover, as the
/// phone's lists are, and run on under the display's foot. A tap plays one and goes back to
/// watch it start.
struct UpNextPage: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next")
                    .font(.custom("VavinCondensed-Bold", size: 30))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                if let state = model.state, state.songId != nil {
                    playing(state)
                    if state.upNext.isEmpty {
                        Text("Nothing after this song")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                    ForEach(state.upNext) { song in row(song) }
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 28)
        }
        .screenBackdrop()
    }

    private func playing(_ state: WatchNowPlaying) -> some View {
        HStack(spacing: 9) {
            Group {
                if let artwork = model.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.accent)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.accent)
                .symbolEffect(.variableColor.iterative, isActive: state.isPlaying)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing: \(state.title), \(state.artist)")
    }

    private func row(_ song: WatchNowPlaying.Upcoming) -> some View {
        Button {
            model.send(.play(song))
            dismiss()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if song.isQueued {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.accent)
                        .accessibilityLabel("Play Next")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
    }
}
