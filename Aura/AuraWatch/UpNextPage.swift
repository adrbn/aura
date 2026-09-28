import SwiftUI

/// What plays after this song — Play Next first, then the rest of the queue. Tapping one
/// plays it, as tapping it in the phone's queue does.
struct UpNextPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        if let upNext = model.state?.upNext, !upNext.isEmpty {
            List(upNext) { song in
                Button { model.send(.play(song)) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Text("Nothing up next")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
