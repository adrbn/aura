import SwiftUI

/// A song as a row with its artwork, for search results and anywhere else a handful of
/// songs are shown among albums and artists.
///
/// Not `MacSongTable`: a table is right for a thousand rows you scan by column, and wrong
/// for six results sitting under a shelf of album covers. Among covers, a song without one
/// reads as a different kind of thing entirely.
struct MacSongRow: View {
    let song: Song
    var source: PlaybackSource = .unknown
    var queue: [Song] = []

    @State private var player = AudioPlayer.shared
    @State private var hovering = false

    private var isCurrent: Bool { song.id == player.currentSong?.id }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CoverArtImage(coverArt: song.coverArt, size: 46, cornerRadius: 5)
                if hovering {
                    Color.black.opacity(0.45)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.appAccent : .primary)
                    .lineLimit(1)
                Text(song.artist ?? "Unknown Artist")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Text(song.album ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .trailing)

            Text(MacFormat.duration(song.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.white.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { play() }
        .contextMenu {
            Button("Play") { play() }
            Button("Play Next") { player.playNext(song) }
            Button("Add to Queue") { player.addToQueue(song) }
        }
    }

    /// Plays with the whole result set behind it, so picking the third hit still leaves the
    /// other results queued rather than stranding you on one song.
    private func play() {
        let songs = queue.isEmpty ? [song] : queue
        let index = songs.firstIndex { $0.id == song.id } ?? 0
        player.playSong(songs[index], fromQueue: songs, startIndex: index, source: source)
    }
}
