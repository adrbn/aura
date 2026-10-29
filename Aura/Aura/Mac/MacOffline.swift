import SwiftUI

/// Offline, the same window: each library section shows what this Mac holds — downloads,
/// then whatever the stream cache still has — from the phone's own `OfflineLibrary`.
/// Sections that need the server (Radar, Wrapped, Recently Played) show every song here.
struct MacOfflineView: View {
    let section: MacSection
    @State private var library = OfflineLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OfflineStatusLine().padding(.horizontal, 12).padding(.bottom, 4)
            content
        }
        .onAppear { library.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .albums:
            MacOfflineGroups(title: section.label, groups: library.albums.map {
                MacOfflineGroup(id: $0.id, title: $0.name, subtitle: $0.artist, coverArt: $0.coverArt,
                                songs: $0.songs, source: .album(id: $0.id, name: $0.name))
            })
        case .artists:
            MacOfflineGroups(title: section.label, groups: library.artists.map {
                MacOfflineGroup(id: $0.id, title: $0.name, subtitle: nil, coverArt: $0.coverArt,
                                songs: $0.songs, source: .artist(id: $0.id, name: $0.name), circular: true)
            })
        case .genres:
            MacOfflineGroups(title: section.label, groups: library.genres.map {
                MacOfflineGroup(id: $0.name, title: $0.name, subtitle: String(localized: "\($0.songs.count) songs"),
                                coverArt: $0.songs.first?.coverArt, songs: $0.songs, source: .genre(name: $0.name))
            })
        case .playlists:
            MacOfflineGroups(title: section.label, groups: library.playlists.map {
                MacOfflineGroup(id: $0.snapshot.id, title: $0.snapshot.name,
                                subtitle: String(localized: "\($0.available.count) songs"), coverArt: $0.snapshot.coverArt,
                                songs: $0.available, source: .playlist(id: $0.snapshot.id, name: $0.snapshot.name))
            })
        case .mixes:
            MacOfflineGroups(title: section.label, groups: library.mixes.map {
                MacOfflineGroup(id: $0.id, title: $0.title, subtitle: $0.subtitle, coverArt: nil,
                                songs: $0.songs, source: .mix(id: $0.id, name: $0.title), mix: $0)
            })
        case .favorites:
            MacOfflineSongs(title: section.label, songs: library.favourites, source: .favorites)
        case .home:
            MacOfflineSongs(title: section.label, songs: library.songs, source: .songs)
        default:
            MacOfflineSongs(title: String(localized: "Songs"), songs: library.songsByTitle, source: .songs)
        }
    }
}

/// An album, artist, genre, playlist or mix, reduced to the songs that are here.
struct MacOfflineGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let coverArt: String?
    let songs: [Song]
    let source: PlaybackSource
    var circular = false
    var mix: Mix?
}

/// A grid of groups; a click opens one in place, with a way back to the grid.
private struct MacOfflineGroups: View {
    let title: String
    let groups: [MacOfflineGroup]
    @State private var openId: String?

    var body: some View {
        if let group = groups.first(where: { $0.id == openId }) {
            VStack(alignment: .leading, spacing: 0) {
                Button { openId = nil } label: {
                    Label(title, systemImage: "chevron.left").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .padding(.horizontal, 28)
                MacOfflineSongs(title: group.title, songs: group.songs, source: group.source,
                                coverArt: group.coverArt, mix: group.mix)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).auraDisplay(52).padding(.horizontal, 28).padding(.top, 10)
                MacGrid(items: groups, emptyMessage: "Nothing here") { group in
                    Button { openId = group.id } label: { tile(group) }
                        .buttonStyle(MacPressStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ group: MacOfflineGroup) -> some View {
        if let mix = group.mix {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geo in
                    EditorialMixCover(mix: mix, size: geo.size.width, cornerRadius: 8)
                }
                .aspectRatio(1, contentMode: .fit)
                .macHoverLift()
                Text(group.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
        } else {
            MacCoverTile(coverArt: group.coverArt, title: group.title, subtitle: group.subtitle,
                         placeholderName: group.title, circular: group.circular)
        }
    }
}

/// A song list offline: the header with Play and Shuffle, then the table.
private struct MacOfflineSongs: View {
    let title: String
    let songs: [Song]
    let source: PlaybackSource
    var coverArt: String?
    var mix: Mix?
    @State private var player = AudioPlayer.shared

    var body: some View {
        if songs.isEmpty {
            ContentUnavailableView {
                Label("No downloads yet", systemImage: "arrow.down.circle")
            } description: {
                Text("Download songs or albums to listen offline.")
            }
        } else {
            VStack(spacing: 0) {
                MacDetailHeader(coverArt: coverArt ?? songs.first?.coverArt, title: title,
                                subtitle: String(localized: "\(songs.count) songs"), placeholderName: title, mix: mix) {
                    Button { player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: source) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { player.playShuffled(songs, source: source) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                Divider()
                MacSongTable(songs: songs, source: source)
            }
        }
    }
}
