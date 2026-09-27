import SwiftUI

// MARK: - What this iPhone holds

/// Everything playable without the server — downloads first, then whatever the stream cache
/// still holds — shaped the way the online tabs show a library: albums, artists, genres,
/// favourites, playlists and mixes, each reduced to the songs that are really here.
@MainActor @Observable
final class OfflineLibrary {
    static let shared = OfflineLibrary()

    /// Songs the stream cache still holds. Re-read on every appearance: `getCachedSongs` only
    /// returns entries whose file is still on disk, so evicted songs drop out.
    private(set) var cachedSongs: [Song] = []

    func refresh() {
        cachedSongs = AudioCacheManager.shared.getCachedSongs()
    }

    /// Downloads first, newest first, then the cache — no song twice.
    var songs: [Song] {
        let downloads = DownloadManager.shared.downloadedSongs
            .sorted { $0.downloadDate > $1.downloadDate }
            .map(\.song)
        var seen = Set<String>()
        return (downloads + cachedSongs).filter { seen.insert($0.id).inserted }
    }

    /// A-Z, as the Songs list shows them.
    var songsByTitle: [Song] {
        songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var albums: [OfflineAlbum] { OfflineAlbum.group(songs) }
    var artists: [OfflineArtist] { OfflineArtist.group(songs) }
    var favourites: [Song] { songs.filter { $0.starred != nil } }

    /// Albums in the order their songs arrived, newest first.
    var recentAlbums: [OfflineAlbum] {
        let byName = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        var seen = Set<String>()
        return songs.compactMap { song in
            let key = OfflineAlbum.key(of: song)
            guard seen.insert(key).inserted else { return nil }
            return byName[key]
        }
    }

    var genres: [(name: String, songs: [Song])] {
        Dictionary(grouping: songs.filter { !($0.genre ?? "").isEmpty }, by: { $0.genre! })
            .map { (name: $0.key, songs: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Snapshotted playlists with at least one song here, reduced to those songs.
    var playlists: [(snapshot: OfflinePlaylistSnapshot, available: [Song])] {
        let here = Set(songs.map(\.id))
        return OfflinePlaylistsStore.shared.playlists.compactMap { snapshot in
            let available = snapshot.songs.filter { here.contains($0.id) }
            return available.isEmpty ? nil : (snapshot, available)
        }
    }

    /// Made For You, as far as it can be played here: a mix needs a few of its songs on this
    /// iPhone to be worth a cover on the shelf.
    var mixes: [Mix] {
        let here = Set(songs.map(\.id))
        return MixGenerator.shared.mixes.compactMap { mix in
            let available = mix.songs.filter { here.contains($0.id) }
            guard available.count >= Self.mixMinimum else { return nil }
            return Mix(id: mix.id, title: mix.title, subtitle: mix.subtitle, songs: available,
                       kind: mix.kind, templateSeed: mix.templateSeed, coverArtists: mix.coverArtists)
        }
    }

    private static let mixMinimum = 3

    func album(_ id: String) -> OfflineAlbum? { albums.first { $0.id == id } }
    func artist(_ id: String) -> OfflineArtist? { artists.first { $0.id == id } }
    func playlist(_ id: String) -> (snapshot: OfflinePlaylistSnapshot, available: [Song])? {
        playlists.first { $0.snapshot.id == id }
    }
    func mix(_ id: String) -> Mix? { mixes.first { $0.id == id } }

    func songs(of list: OfflineSongList) -> [Song] {
        switch list {
        case .all: return songsByTitle
        case .favourites: return favourites
        // Shuffled by the ids' hashes: a new order each launch, a steady one while the
        // page is open (a fresh shuffle per redraw would reorder it under the finger).
        case .random: return songs.sorted { $0.id.hashValue < $1.id.hashValue }
        case .genre(let name): return songs.filter { $0.genre == name }
        }
    }
}

// MARK: - Where a tap goes

/// A song list the Library and Home open offline.
enum OfflineSongList: Hashable {
    case all, favourites, random
    case genre(String)

    var title: String {
        switch self {
        case .all: return String(localized: "Songs")
        case .favourites: return String(localized: "Favorite Songs")
        case .random: return String(localized: "Random")
        case .genre(let name): return name
        }
    }

    var source: PlaybackSource {
        switch self {
        case .all, .random: return .songs
        case .favourites: return .favorites
        case .genre(let name): return .genre(name: name)
        }
    }
}

/// Every page an offline tab can push, by id — the pages look their content up in
/// `OfflineLibrary`, so they follow a download added or removed while they're open.
enum OfflineRoute: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case mix(String)
    case songs(OfflineSongList)
    case albums
    case artists
    case genres
    case downloads
}

extension View {
    /// The offline pages, for any offline tab's navigation stack.
    func offlineDestinations() -> some View {
        navigationDestination(for: OfflineRoute.self) { route in
            OfflineRouteView(route: route)
        }
    }
}

private struct OfflineRouteView: View {
    let route: OfflineRoute
    @State private var library = OfflineLibrary.shared

    var body: some View {
        switch route {
        case .album(let id):
            if let album = library.album(id) { OfflineAlbumDetailView(album: album) } else { gone }
        case .artist(let id):
            if let artist = library.artist(id) { OfflineArtistDetailView(artist: artist) } else { gone }
        case .playlist(let id):
            if let item = library.playlist(id) {
                OfflinePlaylistDetailView(snapshot: item.snapshot, availableSongs: item.available)
            } else { gone }
        case .mix(let id):
            if let mix = library.mix(id) { OfflineMixDetailView(mix: mix) } else { gone }
        case .songs(let list):
            OfflineSongsPage(list: list)
        case .albums:
            OfflineAlbumsPage()
        case .artists:
            OfflineArtistsPage()
        case .genres:
            OfflineGenresPage()
        case .downloads:
            DownloadManagerView()
        }
    }

    private var gone: some View {
        ContentUnavailableView("Not on This iPhone", systemImage: "arrow.down.circle",
                               description: Text("Its songs were removed from this iPhone."))
    }
}

// MARK: - Offline, said quietly

/// Why the app is offline and the way back, as one quiet line under a tab's title — in
/// place of the server's stats on Home. The card it replaces was the loudest thing on the
/// page, for a state the tab bar and the content already make plain.
struct OfflineStatusLine: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(\.appAccentColor) private var accentColor
    @State private var isRetrying = false

    private var text: String {
        if !serverManager.hasNetwork { return String(localized: "Offline · No internet connection") }
        if !serverManager.isConnected { return String(localized: "Offline · Server unreachable") }
        return String(localized: "Offline · Server reachable")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: serverManager.hasNetwork ? "icloud.slash" : "wifi.slash")
            Text(text)
            Spacer(minLength: 8)
            if serverManager.isConnected {
                action("Go Online") { serverManager.goBackOnline() }
            } else if serverManager.hasNetwork {
                action(isRetrying ? nil : "Retry") {
                    guard !isRetrying else { return }
                    isRetrying = true
                    Task {
                        await serverManager.settleModeOnOpen()
                        isRetrying = false
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
    }

    /// A small tinted capsule; a spinner while it runs.
    private func action(_ title: String?, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Group {
                if let title {
                    Text(title).font(.caption.weight(.semibold))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(accentColor.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
