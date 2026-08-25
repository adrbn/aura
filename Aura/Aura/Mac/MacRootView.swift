import SwiftUI

/// Top-level places in the Mac window. Deliberately fewer than the iPhone's tabs: a window
/// has room to show a section and its detail at once, so several of the phone's screens
/// become columns here rather than destinations of their own.
enum MacSection: String, Hashable, CaseIterable, Identifiable {
    case home, mixes, songs, playlists, albums, artists

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .mixes: return "Made For You"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .playlists: return "Playlists"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .mixes: return "sparkles"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .songs: return "music.note"
        case .playlists: return "music.note.list"
        }
    }
}

struct MacRootView: View {
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var section: MacSection? = .home
    @State private var path = NavigationPath()
    /// One search field for the whole window, rather than a section you have to go to.
    @State private var query = ""

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
                // Typing anywhere takes over the detail area, and clearing it hands the
                // section back — search is a lens over the library, not a place in it.
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        detail
                    } else {
                        MacSearchView(query: $query)
                    }
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Search your library")
                .toolbar { MacOptionsMenu() }
                    .navigationDestination(for: Album.self) { MacAlbumDetailView(album: $0) }
                    .navigationDestination(for: Artist.self) { MacArtistDetailView(artist: $0) }
                    .navigationDestination(for: Playlist.self) { MacPlaylistDetailView(playlist: $0) }
                    .navigationDestination(for: Mix.self) { MacMixDetailView(mix: $0) }
            }
        }
        // Spans the full width, under the sidebar as well — the transport belongs to the
        // window, not to whichever section happens to be showing.
        .overlay {
            if player.isShowingNowPlaying {
                MacNowPlayingView { withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying = false } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MacPlayerBar() }
        // Behind everything, including the sidebar. The lists and grids above are made
        // transparent so it shows through rather than being covered by their own material.
        .background(MacBackground())
        // Nothing draws a bar of its own: the toolbar strip was the last opaque grey band
        // separating the window's top from its content.
        .toolbarBackground(.hidden, for: .windowToolbar)
        // Changing section starts a fresh trail. Keeping the old one would leave you on an
        // album you reached from Search after clicking Artists.
        .onChange(of: section) { _, _ in path = NavigationPath() }
        .task {
            if !serverManager.isConnected { await serverManager.testConnection() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .home {
        case .home: MacHomeView()
        case .mixes: MacMixesView()
        case .albums: MacAlbumsView()
        case .artists: MacArtistsView()
        case .songs: MacSongsView()
        case .playlists: MacPlaylistsView()
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
