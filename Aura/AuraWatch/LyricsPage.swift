import SwiftUI

/// The song's lyrics, following the phone's playback: the line being sung is bright and
/// kept in view. Tapping a line jumps the song to it.
struct LyricsPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if let state = model.state, !state.lyrics.isEmpty {
            let isSynced = state.lyrics.contains { $0.time != nil }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                lines(state, current: isSynced ? current(in: state, at: context.date) : nil)
            }
        } else {
            Text(model.state?.songId == nil ? "Nothing playing" : "No lyrics")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func lines(_ state: WatchNowPlaying, current: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.lyrics.indices, id: \.self) { index in
                        let line = state.lyrics[index]
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(current == nil || index == current ? .white : .white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            .onTapGesture {
                                if let time = line.time { model.send(.seek(time)) }
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: current) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    /// The last line whose time has come.
    private func current(in state: WatchNowPlaying, at date: Date) -> Int? {
        let elapsed = state.elapsed(at: date)
        return state.lyrics.lastIndex { ($0.time ?? .infinity) <= elapsed }
    }
}
