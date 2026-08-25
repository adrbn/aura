import SwiftUI

/// Top-level places in the Mac window. Deliberately fewer than the iPhone's tabs: a window
/// has room to show a section and its detail at once, so several of the phone's screens
/// become columns here rather than destinations of their own.
enum MacSection: String, Hashable, CaseIterable, Identifiable {
    case mixes, albums, artists, songs, playlists, search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mixes: return "Made For You"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .playlists: return "Playlists"
        case .search: return "Search"
        }
    }

    var symbol: String {
        switch self {
        case .mixes: return "sparkles"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .songs: return "music.note"
        case .playlists: return "music.note.list"
        case .search: return "magnifyingglass"
        }
    }
}

struct MacRootView: View {
    @State private var serverManager = ServerManager.shared
    @State private var section: MacSection? = .mixes
    @State private var path = NavigationPath()

    var body: some View {
        Group {
            if serverManager.hasServer {
                browser
            } else {
                MacServerSetupView()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var browser: some View {
        NavigationSplitView {
            MacSidebar(section: $section)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: Album.self) { MacAlbumDetailView(album: $0) }
                    .navigationDestination(for: Artist.self) { MacArtistDetailView(artist: $0) }
                    .navigationDestination(for: Playlist.self) { MacPlaylistDetailView(playlist: $0) }
                    .navigationDestination(for: Mix.self) { MacMixDetailView(mix: $0) }
            }
        }
        // Spans the full width, under the sidebar as well — the transport belongs to the
        // window, not to whichever section happens to be showing.
        .safeAreaInset(edge: .bottom, spacing: 0) { MacPlayerBar() }
        // Changing section starts a fresh trail. Keeping the old one would leave you on an
        // album you reached from Search after clicking Artists.
        .onChange(of: section) { _, _ in path = NavigationPath() }
        .task {
            if !serverManager.isConnected { await serverManager.testConnection() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .mixes {
        case .mixes: MacMixesView()
        case .albums: MacAlbumsView()
        case .artists: MacArtistsView()
        case .songs: MacSongsView()
        case .playlists: MacPlaylistsView()
        case .search: MacSearchView()
        }
    }
}

// MARK: - Formatting

enum MacFormat {
    /// `3:07`, or `1:02:44` once an hour is involved.
    static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "--:--" }
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func time(_ interval: TimeInterval) -> String {
        duration(interval.isFinite && interval > 0 ? Int(interval) : 0)
    }
}
