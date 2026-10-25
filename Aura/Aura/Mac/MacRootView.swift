import SwiftUI

/// Top-level places in the Mac window. Deliberately fewer than the iPhone's tabs: a window
/// has room to show a section and its detail at once, so several of the phone's screens
/// become columns here rather than destinations of their own.
enum MacSection: String, Hashable, CaseIterable, Identifiable {
    case home, mixes, radar, wrapped, songs, playlists, albums, artists, downloads

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return String(localized: "Home")
        case .mixes: return String(localized: "Made For You")
        case .radar: return String(localized: "Radar")
        case .wrapped: return String(localized: "Wrapped")
        case .downloads: return String(localized: "Downloads")
        case .albums: return String(localized: "Albums")
        case .artists: return String(localized: "Artists")
        case .songs: return String(localized: "Songs")
        case .playlists: return String(localized: "Playlists")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .mixes: return "sparkles"
        case .radar: return "dot.radiowaves.left.and.right"
        case .wrapped: return "chart.bar.fill"
        case .downloads: return "arrow.down.circle"
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
    /// Owned here rather than left to the split view. With the toolbar gone there is no
    /// system button to restore a collapsed sidebar, so its state has to be ours to set.
    @State private var preferences = MacPreferences.shared
    @State private var windowState = MacWindowState.shared
    /// The title bar's row, which holds the search field and which every section's top is
    /// laid out below — in full screen too, where the field still sits there.
    static let topRoom: CGFloat = 52
    /// The pages sit lower than the sidebar: the search pill takes the band above them.
    static let pageRoom: CGFloat = 66
    @State private var swipe = MacSwipeBack.shared

    var body: some View {
        let panel = MacSettingsPanel.shared
        Group {
            if serverManager.hasServer {
                browser
            } else {
                MacServerSetupView()
            }
        }
        .blur(radius: panel.isShown || Self.fetchPanelShown ? 10 : 0)
        .overlay {
            if panel.isShown {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { panel.isShown = false }
                    MacSettingsView()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: panel.isShown)
        #if !APPSTORE_BUILD
        .overlay {
            if MacFetchPanel.shared.isShown {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { MacFetchPanel.shared.isShown = false }
                    MacFetchPanelView()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: MacFetchPanel.shared.isShown)
        #endif
        // No scroll bars anywhere: trackpad and wheel scroll, and the bars only drew over covers.
        .scrollIndicators(.hidden)
        .preferredColorScheme(AppSettings.shared.appearanceMode.colorScheme)
    }

    private static var fetchPanelShown: Bool {
        #if APPSTORE_BUILD
        false
        #else
        MacFetchPanel.shared.isShown
        #endif
    }

    private var browser: some View {
        // The bar under the split view rather than a safe-area inset: a Table ignores the
        // inset, and its last rows sat under the bar out of reach.
        VStack(spacing: 0) {
        HStack(spacing: 0) {
        NavigationSplitView(columnVisibility: columnVisibility) {
            MacSidebar(section: $section) { path = NavigationPath() }
        } detail: {
            // A plain VStack, not a safe-area inset. As an inset the bar was handed the
            // whole height and centred itself in it, landing halfway down the window. Here
            // its position is simply the top, and it cannot be anywhere else.
            //
            // Outside the NavigationStack on purpose, so it stays put while album and
            // artist screens push and pop beneath it.
            Group {
                NavigationStack(path: $path) {
                    // Typing anywhere takes over the detail area, and clearing it hands the
                    // section back — search is a lens over the library, not a place in it.
                    Group {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            // Each section arrives with a short fade and rise rather than a cut.
                            detail
                                .id(section)
                                .transition(.opacity.combined(with: .offset(y: 10)))
                        } else {
                            MacSearchView(query: $query)
                        }
                    }
                    // A fixed room above the titles. Left to the window it came and went: SwiftUI
                    // puts a toolbar back on every section change and `MacWindowChrome` takes it
                    // off a moment later, so each title landed low, then jumped up.
                    .safeAreaPadding(.top, Self.pageRoom)
                    .ignoresSafeArea(.container, edges: .top)
                    .navigationDestination(for: Album.self) { pushed(MacAlbumDetailView(album: $0)) }
                    .navigationDestination(for: Artist.self) { pushed(MacArtistDetailView(artist: $0)) }
                    .navigationDestination(for: Playlist.self) { pushed(MacPlaylistDetailView(playlist: $0)) }
                    .navigationDestination(for: Mix.self) { pushed(MacMixDetailView(mix: $0)) }
                    .animation(.smooth(duration: 0.28), value: section)
                    .macPendingNavigation(path: $path)
                }
            }
            // In the title bar's row, centred over the page, as a fixture of the window
            // rather than of the sidebar: it stays put while sections change beneath it.
            .overlay(alignment: .top) {
                MacSearchBar(query: $query)
                    .padding(.top, 16)
                    .ignoresSafeArea(.container, edges: .top)
            }
            // Picking a section leaves the search, as it hands the page back.
            .onChange(of: section) { _, _ in query = "" }
        }
        // Spans the full width, under the sidebar as well — the transport belongs to the
        // window, not to whichever section happens to be showing.
        .overlay {
            if player.isShowingNowPlaying {
                MacNowPlayingView { withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying = false } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Get It's progress, top-right as the system's notifications are: a card that folds
        // into a ring once read.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                PlayingElsewhereRow()
                MacDownloadNotice()
                #if !APPSTORE_BUILD
                MacFetchNotices()
                #endif
            }
            .animation(.smooth(duration: 0.35), value: RemoteLink.shared.playingElsewhere?.playing)
            .animation(.smooth(duration: 0.35), value: DownloadManager.shared.isDownloading)
            // From the window's top, in the title bar's row, where the system's own land.
            .padding(.top, 24)
            .padding(.trailing, 16)
            .ignoresSafeArea()
        }
        if MacQueuePanel.shared.isShown {
            // Up Next as a pane on the right, as the sidebar is on the left: it slides in
            // from the queue button, and the library narrows beside it rather than under it.
            MacQueueView()
                .transition(.move(edge: .trailing))
        }
        }
        .animation(.smooth(duration: 0.35), value: MacQueuePanel.shared.isShown)
        MacPlayerBar()
        }
        // With the sidebar folded, its button waits beside the window's own three.
        .overlay(alignment: .topLeading) {
            if !preferences.sidebarVisible {
                MacSidebarButton(floating: true).padding(.leading, windowState.isFullScreen ? 18 : 80).padding(.top, 11).ignoresSafeArea().transition(.opacity)
            }
        }
        // What an action did ("Getting …", "Added to queue"), at the top of the window.
        .overlay(alignment: .top) { ToastOverlay().padding(.top, 20) }
        // Behind everything, including the sidebar. The lists and grids above are made
        // transparent so it shows through rather than being covered by their own material.
        .background(MacBackground())
        .background(MacWindowChrome(sidebarVisible: preferences.sidebarVisible).frame(width: 0, height: 0))
        // Safe to hide now: the buttons no longer depend on it. With the title bar itself
        // made transparent rather than removed, there is nothing left for a toolbar to do
        // but paint a strip. The sidebar toggles from the View menu.
        .toolbar(.hidden, for: .windowToolbar)
        // The section's name no longer turns up grey in the title bar.
        .toolbar(removing: .title)
        // Changing section starts a fresh trail. Keeping the old one would leave you on an
        // album you reached from Search after clicking Artists.
        .onChange(of: section) { _, _ in path = NavigationPath() }
        .task {
            MacSpaceKey.install()
            swipe.canGoBack = { !path.isEmpty }
            swipe.goBack = { if !path.isEmpty { path.removeLast() } }
            swipe.install()
            if !serverManager.isConnected { await serverManager.testConnection() }
        }
    }

    /// A pushed page, laid out from the window's top whatever the window's safe area says
    /// (it came and went with the toolbar SwiftUI keeps putting back, and the page jumped):
    /// its header keeps the same fixed room as the sections, and the way back sits in it.
    /// The button rides on the page: laid over the stack, it sat under the stack's own
    /// AppKit view and never showed.
    private func pushed(_ page: some View) -> some View {
        page
            // The full room even in full screen, where the sections need less: the way back
            // sits in it, above the cover.
            .environment(\.macTopRoom, Self.pageRoom)
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .topLeading) { backButton }
            .macPageEntrance()
    }

    /// SwiftUI's own back button is a toolbar item, and this window has no toolbar, so a
    /// pushed page carries this one in its top-left corner, clear of the window buttons.
    /// `⌘[` as well as the button, because that is the shortcut every other Mac app answers to.
    /// Not gated on the path: the page is built from the render before the push, whose path
    /// was still empty, so the button never showed. A pushed page always has a way back.
    private var backButton: some View {
        Button {
            if !path.isEmpty { path.removeLast() }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        // In the room above the cover, level with the window's buttons and clear of
        // them, and of the sidebar's while the sidebar is folded.
        .padding(.leading, preferences.sidebarVisible ? 18 : windowState.isFullScreen ? 56 : 118)
        .padding(.top, 18)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Kept in a preference so the View menu can reach it: with no toolbar there is no
    /// system button left to bring a collapsed sidebar back.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { preferences.sidebarVisible ? .all : .detailOnly },
            // Only ever opened from here. Folding is the button's and the View menu's: the split
            // view folded it by itself when a page was pushed, and the preference followed.
            set: { if $0 != .detailOnly { preferences.sidebarVisible = true } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .home {
        case .home: MacHomeView()
        case .mixes: MacMixesView()
        case .radar: MacRadarView()
        case .wrapped: WrappedView()
        case .downloads: MacDownloadsView()
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

/// The window's one search field, a pill in the title bar's row. `⌘F` reaches it from
/// anywhere; Escape leaves it.
struct MacSearchBar: View {
    @Binding var query: String
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(searching ? Color.appAccent : .secondary)
            TextField("", text: $query, prompt: Text("Search").font(.system(size: 13)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .onExitCommand { searching = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .frame(maxWidth: 440)
        .background(Capsule().fill(.primary.opacity(searching ? 0.14 : 0.08)))
        .overlay(
            Capsule().strokeBorder(searching ? Color.appAccent.opacity(0.85) : .primary.opacity(0.07),
                                   lineWidth: searching ? 1.5 : 1)
        )
        .contentShape(Capsule())
        .onTapGesture { searching = true }
        // A hidden button carries the shortcut, so it works whatever has focus.
        .background(Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0))
        .padding(.horizontal, 120)
        .animation(.easeOut(duration: 0.15), value: searching)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
    }
}
