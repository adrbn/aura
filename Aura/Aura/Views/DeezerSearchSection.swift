import SwiftUI

/// A song Deezer's search turned up, with the release it's from as the radar would hold it.
struct DeezerFind: Identifiable, Hashable {
    let hit: DeezerHit
    let release: RadarRelease

    var id: Int { hit.id }
    var preview: Song? { hit.track.previewSong(of: release) }
}

/// What Deezer has for a search that the library's own results don't: songs to preview and
/// get, and releases to open like the radar's.
struct DeezerFinds: Equatable {
    var query = ""
    var songs: [DeezerFind] = []
    var releases: [RadarRelease] = []

    var isEmpty: Bool { songs.isEmpty && releases.isEmpty }

    init() {}

    /// Deezer's answer, less what the library's results already hold. An artist the library
    /// knows keeps their id, so their page is a tap away.
    init(query: String, songs: [DeezerHit], albums: [DeezerAlbumHit], library: SearchResults) {
        func artist(_ credit: DeezerHit.Artist) -> ArtistRef {
            let folded = SongQuery.fold(credit.name)
            let known = library.artists.first { SongQuery.fold($0.name) == folded }
            return ArtistRef(id: known?.id ?? "", name: credit.name)
        }
        var seen = Set<Int>()
        self.query = query
        self.songs = songs
            .filter { hit in
                seen.insert(hit.id).inserted && !library.songs.contains {
                    RadarRules.sameTitle($0.title, hit.title) && RadarRules.credits($0.artist, hit.artist.name)
                }
            }
            .map { hit in
                DeezerFind(hit: hit, release: RadarRelease(
                    id: String(hit.album.id), title: hit.album.title, artist: artist(hit.artist),
                    released: "", type: "album", cover: hit.album.cover_medium, link: nil))
            }
        self.releases = albums
            .filter { hit in
                !library.albums.contains {
                    RadarRules.sameTitle($0.name, hit.title) && RadarRules.credits($0.artist, hit.artist.name)
                }
            }
            .map { hit in
                RadarRelease(id: String(hit.id), title: hit.title, artist: artist(hit.artist), released: "",
                             type: hit.record_type ?? "album", cover: hit.cover_medium, link: hit.link)
            }
    }
}

/// Search's "On Deezer" rows, under the library's: a song plays its preview, on into the
/// others found; a release opens its page, to preview and get its songs.
struct DeezerSearchRows: View {
    let finds: DeezerFinds
    @Binding var navPath: NavigationPath

    @Environment(AudioPlayer.self) private var player
    @State private var showsAllSongs = false
    @State private var showsAllReleases = false

    private let collapsedLimit = 4
    private var density: CGFloat { AppSettings.shared.listDensity.verticalPadding }

    var body: some View {
        header("On Deezer")
        ForEach(showsAllSongs ? finds.songs : Array(finds.songs.prefix(collapsedLimit))) { find in
            DeezerSongRow(find: find) { play(find) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: density, leading: 16, bottom: density, trailing: 16))
        }
        if !showsAllSongs && finds.songs.count > collapsedLimit {
            showMore(finds.songs.count) { showsAllSongs = true }
        }
        ForEach(showsAllReleases ? finds.releases : Array(finds.releases.prefix(collapsedLimit))) { release in
            Button { navPath.append(release) } label: { DeezerReleaseRow(release: release) }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: density + 2, leading: 16, bottom: density + 2, trailing: 16))
        }
        if !showsAllReleases && finds.releases.count > collapsedLimit {
            showMore(finds.releases.count) { showsAllReleases = true }
        }
    }

    private func play(_ find: DeezerFind) {
        let queue = finds.songs.compactMap(\.preview)
        guard let song = find.preview, let index = queue.firstIndex(where: { $0.id == song.id }) else {
            ToastManager.shared.show(String(localized: "No preview for this song"), icon: "speaker.slash")
            return
        }
        player.playSong(song, fromQueue: queue, startIndex: index, source: .search(query: finds.query))
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.bold())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private func showMore(_ total: Int, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { action() }
        } label: {
            Text("Show more (\(total - collapsedLimit) more)")
                .font(.subheadline).foregroundStyle(.tint)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 16))
    }
}

/// A song on Deezer: its cover, title and release — its preview on a tap, and in the sideload
/// build, a button to get it.
private struct DeezerSongRow: View {
    let find: DeezerFind
    let play: () -> Void

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    private var isCurrent: Bool { player.currentSong?.id == "deezer-\(find.hit.id)" }

    private var canFetch: Bool {
        #if APPSTORE_BUILD
        return false
        #else
        return ReleaseFetcher.shared.isAvailable
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: find.release.cover, size: 44, cornerRadius: 6, placeholderName: find.hit.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(find.hit.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accentColor) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text("\(find.hit.artist.name) · \(find.release.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
                .frame(width: 32)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .opacity(find.preview == nil ? 0.5 : 1)
        .contextMenu {
            Button(action: play) { Label("Play Preview", systemImage: "play.circle") }
            #if !APPSTORE_BUILD
            if canFetch {
                Button { ReleaseFetcher.shared.get(find.release, track: SoulseekPick.Track(find.hit.track)) } label: {
                    Label("Get This Song", systemImage: "arrow.down.circle")
                }
            }
            #endif
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(find.hit.title), \(find.hit.artist.name)")
        .accessibilityHint("Plays its preview")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        if canFetch {
            #if !APPSTORE_BUILD
            SongGetControl(release: find.release, track: SoulseekPick.Track(find.hit.track))
            #endif
        } else {
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A release on Deezer, opening its page.
private struct DeezerReleaseRow: View {
    let release: RadarRelease

    var body: some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: release.cover, size: 44, cornerRadius: 6, placeholderName: release.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(release.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(release.artist.name) · \(release.typeLabel)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
