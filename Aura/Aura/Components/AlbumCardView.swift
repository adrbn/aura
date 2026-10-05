import SwiftUI

struct AlbumCardView: View {
    let album: Album
    var size: CGFloat = 160

    @Environment(AudioPlayer.self) private var player
    @State private var cachedSongs: [Song]?

    /// Fetches the album's songs once (cached across context-menu actions) and
    /// runs the given action with them on the main actor.
    private func performWithAlbumSongs(_ perform: @escaping ([Song]) -> Void) {
        Task { @MainActor in
            if cachedSongs == nil {
                guard let server = ServerManager.shared.currentServer else { return }
                let detail = try? await SubsonicClient.shared.getAlbum(server: server, id: album.id)
                cachedSongs = detail?.song
            }
            guard let songs = cachedSongs, !songs.isEmpty else { return }
            perform(songs)
        }
    }

    var body: some View {
        NavigationLink(value: album) {
            VStack(alignment: .leading, spacing: 4) {
                CoverArtImage(coverArt: album.coverArt, size: size, cornerRadius: 10,
                              placeholderName: album.name, placeholderKind: .album)
                Text(album.name).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                Text(album.artist ?? String(localized: "Unknown Artist")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name), \(album.artist ?? String(localized: "Unknown Artist"))")
        .accessibilityHint("Double tap to view album")
        .contextMenu {
            Button {
                performWithAlbumSongs { songs in
                    player.playSong(songs[0], fromQueue: songs)
                }
            } label: { Label("Play", systemImage: "play.fill") }

            Button {
                performWithAlbumSongs { songs in
                    player.playShuffled(songs, source: .album(id: album.id, name: album.name))
                }
            } label: { Label("Shuffle", systemImage: "shuffle") }

            Button {
                performWithAlbumSongs { songs in
                    player.addToQueue(songs)
                }
            } label: { Label("Add to Queue", systemImage: "text.append") }

            Divider()
            Button {
                guard let server = ServerManager.shared.currentServer else { return }
                Task {
                    if album.isStarred {
                        try? await SubsonicClient.shared.unstar(server: server, id: album.id, type: .album)
                    } else {
                        try? await SubsonicClient.shared.star(server: server, id: album.id, type: .album)
                    }
                }
            } label: {
                Label(album.isStarred ? "Unfavorite" : "Favorite",
                      systemImage: album.isStarred ? "heart.slash" : "heart")
            }

            Button {
                performWithAlbumSongs { songs in
                    Task { await DownloadManager.shared.downloadAlbum(songs) }
                }
            } label: {
                Label("Download Album", systemImage: "arrow.down.circle")
            }
        }
    }
}

struct SongCardView: View {
    let song: Song
    var size: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverArtImage(coverArt: song.coverArt, size: size, cornerRadius: 10,
                          placeholderName: song.title, placeholderKind: .song)
            Text(song.title).font(.caption.weight(.medium)).lineLimit(1)
            Text(song.artist ?? String(localized: "Unknown Artist")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: size)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.title), \(song.artist ?? String(localized: "Unknown Artist"))")
    }
}

struct ArtistCardView: View {
    let artist: Artist
    var size: CGFloat = 140

    var body: some View {
        NavigationLink(value: artist) {
            VStack(spacing: 8) {
                CoverArtImage(coverArt: artist.coverArt, size: size, cornerRadius: size / 2,
                              placeholderName: artist.name, placeholderKind: .artist)
                Text(artist.name).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(artist.name)
        .accessibilityHint("Double tap to view artist")
        .contextMenu {
            Button {
                Task {
                    guard let server = ServerManager.shared.currentServer else { return }
                    let topSongs = (try? await SubsonicClient.shared.getTopSongs(server: server, artistName: artist.name, count: 20)) ?? []
                    if !topSongs.isEmpty {
                        await MainActor.run {
                            AudioPlayer.shared.startArtistInstantMix(
                                artistId: artist.id,
                                artistName: artist.name,
                                topSongs: topSongs
                            )
                        }
                    }
                }
            } label: {
                Label("Instant Mix", systemImage: "wand.and.stars")
            }
            Divider()
            Button {
                guard let server = ServerManager.shared.currentServer else { return }
                Task {
                    if artist.isStarred {
                        try? await SubsonicClient.shared.unstar(server: server, id: artist.id, type: .artist)
                    } else {
                        try? await SubsonicClient.shared.star(server: server, id: artist.id, type: .artist)
                    }
                }
            } label: {
                Label(artist.isStarred ? "Unfavorite" : "Favorite",
                      systemImage: artist.isStarred ? "heart.slash" : "heart")
            }
        }
    }
}
