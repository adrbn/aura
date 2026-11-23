import SwiftUI

/// The shared shape of an album, playlist or mix page: the cover and Play / Shuffle on the
/// left, the songs on the right.
struct TVCollectionPage<Cover: View>: View {
    let title: String
    var subtitle: String?
    var detail: String?
    let songs: [Song]
    let source: PlaybackSource
    var loading = false
    var showsArtwork = false
    @ViewBuilder let cover: () -> Cover

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            VStack(alignment: .leading, spacing: 26) {
                cover()
                    .frame(width: 460, height: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 40, weight: .bold)).lineLimit(2)
                    if let subtitle { Text(subtitle).font(.system(size: 28)).foregroundStyle(.secondary).lineLimit(1) }
                    if let detail { Text(detail).font(.system(size: 22)).foregroundStyle(.tertiary) }
                }
                HStack(spacing: 24) {
                    Button { TVPlayback.shared.play(songs, source: source) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { TVPlayback.shared.play(songs, source: source, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                .disabled(songs.isEmpty)
            }
            .frame(width: 460)

            ScrollView {
                LazyVStack(spacing: 6) {
                    if songs.isEmpty { TVStatus(loading: loading) }
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        TVSongRow(song: song, number: showsArtwork ? nil : (song.track ?? index + 1),
                                  showsArtwork: showsArtwork) {
                            TVPlayback.shared.play(songs, from: index, source: source)
                        }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 80)
        .padding(.top, 30)
    }
}

/// One song in a list: number or cover, title and artist, length.
struct TVSongRow: View {
    let song: Song
    var number: Int?
    var showsArtwork = false
    let action: () -> Void
    @State private var player = AudioPlayer.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                if showsArtwork {
                    CoverArtImage(coverArt: song.displayCoverArt, size: 72, cornerRadius: 6,
                                  placeholderName: song.album ?? song.title)
                } else {
                    Group {
                        if player.currentSong?.id == song.id {
                            Image(systemName: "waveform").foregroundStyle(Color.appAccent)
                        } else {
                            Text(number.map(String.init) ?? "").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 24, weight: .medium).monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 28, weight: .medium)).lineLimit(1)
                    if let artist = song.artist {
                        Text(artist).font(.system(size: 22)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 20)
                Text(song.durationFormatted).font(.system(size: 22).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
        }
        .buttonStyle(TVRowButtonStyle())
    }
}

/// A list row under focus: a soft light band behind it, the text staying white, instead of
/// the system's white platter that turns the row into a bright block.
struct TVRowButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(focused ? 0.16 : 0)))
            .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.02 : 1)
            .animation(.easeOut(duration: 0.2), value: focused)
    }
}

struct TVAlbumView: View {
    let album: Album
    @State private var songs: [Song] = []
    @State private var loading = true

    var body: some View {
        TVCollectionPage(title: album.name, subtitle: album.artist, detail: detail, songs: songs,
                         source: .album(id: album.id, name: album.name), loading: loading) {
            CoverArtImage(coverArt: album.coverArt, size: 460, cornerRadius: 0, placeholderName: album.name)
        }
        .task {
            defer { loading = false }
            guard let server = ServerManager.shared.currentServer else { return }
            songs = (try? await SubsonicClient.shared.getAlbum(server: server, id: album.id).song) ?? []
        }
    }

    private var detail: String? {
        [album.year.map(String.init), album.genre].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

struct TVPlaylistView: View {
    let playlist: Playlist
    @State private var songs: [Song] = []
    @State private var loading = true

    var body: some View {
        TVCollectionPage(title: playlist.name, subtitle: playlist.songCount.map { String(localized: "\($0) songs") },
                         songs: songs, source: .playlist(id: playlist.id, name: playlist.name),
                         loading: loading, showsArtwork: true) {
            CoverArtImage(coverArt: playlist.coverArt, size: 460, cornerRadius: 0, placeholderName: playlist.name)
        }
        .task {
            defer { loading = false }
            guard let server = ServerManager.shared.currentServer else { return }
            songs = (try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id).entry) ?? []
        }
    }
}

struct TVMixView: View {
    let mix: Mix
    var body: some View {
        TVCollectionPage(title: mix.title, subtitle: mix.subtitle, songs: mix.songs,
                         source: .mix(id: mix.id, name: mix.title), showsArtwork: true) {
            EditorialMixCover(mix: mix, size: 460, cornerRadius: 0)
        }
    }
}

struct TVArtistView: View {
    let artist: Artist
    @State private var albums: [Album] = []
    @State private var top: [Song] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                HStack(spacing: 50) {
                    CoverArtImage(coverArt: artist.coverArt, size: 280, cornerRadius: 0, placeholderName: artist.name)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 24) {
                        Text(artist.name).font(.system(size: 56, weight: .bold)).lineLimit(2)
                        HStack(spacing: 24) {
                            Button { TVPlayback.shared.play(top, source: source) } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            Button { Task { await shuffleAll() } } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                        }
                        .disabled(albums.isEmpty)
                    }
                }
                .padding(.horizontal, 80)

                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Top Songs").font(.system(size: 36, weight: .bold))
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 40), GridItem(.flexible())], spacing: 6) {
                            ForEach(Array(top.prefix(10).enumerated()), id: \.offset) { index, song in
                                TVSongRow(song: song, showsArtwork: true) {
                                    TVPlayback.shared.play(top, from: index, source: source)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                }

                TVShelf(title: "Albums", items: albums) { TVAlbumLink(album: $0) }
                if albums.isEmpty { TVStatus(loading: loading) }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    private var source: PlaybackSource { .artist(id: artist.id, name: artist.name) }

    private func load() async {
        defer { loading = false }
        guard let server = ServerManager.shared.currentServer else { return }
        async let detail = try? SubsonicClient.shared.getArtist(server: server, id: artist.id)
        async let songs = try? SubsonicClient.shared.getTopSongs(server: server, artistName: artist.name, count: 20)
        albums = (await detail?.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        top = await songs ?? []
    }

    /// Every song of every album, shuffled: what Shuffle on an artist means.
    private func shuffleAll() async {
        guard let server = ServerManager.shared.currentServer else { return }
        var all: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask { (try? await SubsonicClient.shared.getAlbum(server: server, id: album.id).song) ?? [] }
            }
            for await songs in group { all += songs }
        }
        TVPlayback.shared.play(all, source: source, shuffled: true)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
