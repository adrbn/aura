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
                    // Air between rows, as on the phone, rather than a spreadsheet's 20pt.
                    .padding(.vertical, 5)
            }
            // The title takes whatever width is spare; artist and album stop at what a name
            // needs, instead of three equal thirds with a gulf in each.
            .width(min: 180, ideal: 380)

            TableColumn("Artist") { song in
                Text(song.artist ?? String(localized: "Unknown Artist")).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 110, ideal: 200, max: 280)

            if showsAlbum {
                TableColumn("Album") { song in
                    Text(song.album ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 110, ideal: 220, max: 300)
            }

            TableColumn("Rating") { song in
                MacStars(song: song)
            }
            .width(78)

            TableColumn("Time") { song in
                Text(MacFormat.duration(song.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(52)
        }
        .scrollContentBackground(.hidden)
        // No striped rows running on past the last song: a five-song album ended in a wall
        // of empty stripes.
        .alternatingRowBackgrounds(.disabled)
        // Rows start on the header's left edge, the cover's, rather than a step inside it.
        .padding(.horizontal, 12)
        .contextMenu(forSelectionType: Song.ID.self) { ids in
            Button("Play") { play(ids) }
            Button("Play Next") { chosen(ids).reversed().forEach { player.playNext($0) } }
            Button("Add to Queue") { player.addToQueue(chosen(ids)) }
            Divider()
            MacRatingMenu(songs: chosen(ids))
            MacDownloadMenuItem(songs: chosen(ids))
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
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
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
    /// A mix's own cover, drawn instead of the server's artwork.
    var mix: Mix?
    @ViewBuilder var actions: Actions
    @Environment(\.macTopRoom) private var topRoom
    @State private var width: CGFloat = 900

    /// The artwork grows with the window instead of staying a 260 pt stamp on a big screen.
    private var coverSide: CGFloat { min(360, max(220, width * 0.26)) }

    var body: some View {
        // Beside the cover while the window is wide enough for the buttons whole; under it
        // otherwise, rather than cutting the title and buttons down to "…".
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 22) {
                cover
                text
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 18) {
                cover
                text
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26 + topRoom)
        .padding(.bottom, 18)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private extension MacDetailHeader {
    @ViewBuilder var cover: some View {
        if let mix {
            EditorialMixCover(mix: mix, size: coverSide, cornerRadius: 12)
        } else {
            CoverArtImage(coverArt: coverArt, size: coverSide, cornerRadius: 12,
                          placeholderName: placeholderName)
        }
    }

    var text: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A long title wraps and, past three lines, shrinks, instead of ending in "…".
            Text(title).auraDisplay(64).lineLimit(3).minimumScaleFactor(0.55)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) { actions }.font(.system(size: 14, weight: .medium)).controlSize(.extraLarge).fixedSize().padding(.top, 4)
        }
        .frame(minWidth: 340, alignment: .leading)
    }
}

/// A song's stars, set by clicking one; clicking the one already set clears it.
struct MacStars: View {
    let song: Song
    @State private var hovering = false

    var body: some View {
        let rating = SongRatings.shared.rating(for: song)
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 9))
                    .foregroundStyle(star <= rating ? Color.appAccent : .secondary)
                    .opacity(star <= rating || hovering ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { SongRatings.shared.set(star == rating ? 0 : star, for: song) }
            }
        }
        .onHover { hovering = $0 }
    }
}
