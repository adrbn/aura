import SwiftUI

/// What is coming up. A popover rather than a pane: it is consulted, not lived in.
struct MacQueueView: View {
    @State private var player = AudioPlayer.shared

    private var upcoming: [(offset: Int, song: Song)] {
        guard player.queueIndex + 1 < player.queue.count else { return [] }
        return Array(player.queue.enumerated())
            .filter { $0.offset > player.queueIndex }
            .map { (offset: $0.offset, song: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").auraDisplay(22)
                Spacer()
                Text(player.playbackSource.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if upcoming.isEmpty {
                Text("Nothing queued")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(upcoming, id: \.offset) { item in
                        HStack(spacing: 10) {
                            CoverArtImage(coverArt: item.song.coverArt, size: 32, cornerRadius: 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.song.title).font(.system(size: 12)).lineLimit(1)
                                Text(item.song.artist ?? "").font(.system(size: 10))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(MacFormat.duration(item.song.duration))
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.playSong(item.song, fromQueue: player.queue,
                                            startIndex: item.offset, source: player.playbackSource)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 340, height: 420)
    }
}
