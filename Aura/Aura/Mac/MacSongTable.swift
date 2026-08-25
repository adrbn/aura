import SwiftUI

/// The song list, everywhere a song list is needed — an album, a playlist, a mix, the whole
/// library. A real `Table`, not a stack of rows: on the Mac the columns are the point, and
/// they bring keyboard navigation, type-select and multi-selection for free.
struct MacSongTable: View {
    let songs: [Song]
    var source: PlaybackSource = .unknown
    /// Album and playlist detail already say what album you are in.
    var showsAlbum = true
    var showsTrackNumber = false

    @State private var selection = Set<Song.ID>()
    @State private var player = AudioPlayer.shared

    var body: some View {
        Table(songs, selection: $selection) {
            TableColumn(showsTrackNumber ? "#" : "") { song in
                leading(song)
            }
            .width(showsTrackNumber ? 30 : 34)

            TableColumn("Title") { song in
                Text(song.title)
                    .foregroundStyle(song.id == player.currentSong?.id ? Color.appAccent : .primary)
                    .lineLimit(1)
            }

            TableColumn("Artist") { song in
                Text(song.artist ?? "Unknown Artist").foregroundStyle(.secondary).lineLimit(1)
            }

            TableColumn("Album") { song in
                Text(showsAlbum ? (song.album ?? "") : "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(showsAlbum ? nil : 0)

            TableColumn("Time") { song in
                Text(MacFormat.duration(song.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(52)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Song.ID.self) { ids in
            Button("Play") { play(ids) }
            Button("Play Next") { chosen(ids).reversed().forEach { player.playNext($0) } }
            Button("Add to Queue") { player.addToQueue(chosen(ids)) }
        } primaryAction: { ids in
            // Double-click, the only gesture anyone tries first on a Mac list.
            play(ids)
        }
    }

    @ViewBuilder
    private func leading(_ song: Song) -> some View {
        if song.id == player.currentSong?.id {
            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.appAccent)
        } else if showsTrackNumber {
            Text(song.track.map(String.init) ?? "")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            CoverArtImage(coverArt: song.coverArt, size: 24, cornerRadius: 3)
        }
    }

    private func chosen(_ ids: Set<Song.ID>) -> [Song] {
        songs.filter { ids.contains($0.id) }
    }

    /// Plays the first of the selection, with the *whole* list behind it — picking a track
    /// out of an album should still queue the album, not strand you on one song.
    private func play(_ ids: Set<Song.ID>) {
        guard let first = ids.first, let index = songs.firstIndex(where: { $0.id == first }) else { return }
        player.playSong(songs[index], fromQueue: songs, startIndex: index, source: source)
    }
}

/// The header every detail screen shares: big artwork, a title, and the two buttons that
/// actually start music.
struct MacDetailHeader<Actions: View>: View {
    let coverArt: String?
    let title: String
    let subtitle: String
    var placeholderName: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: 22) {
            CoverArtImage(coverArt: coverArt, size: 210, cornerRadius: 12,
                          placeholderName: placeholderName)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).auraDisplay(52).lineLimit(2)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) { actions }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }
}
