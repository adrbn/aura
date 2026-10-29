import AppKit
import SwiftUI

/// Top-level places in the Mac window. Deliberately fewer than the iPhone's tabs: a window
/// has room to show a section and its detail at once, so several of the phone's screens
/// become columns here rather than destinations of their own.
enum MacSection: String, Hashable, CaseIterable, Identifiable {
    case home, mixes, radar, wrapped, songs, favorites, recentlyPlayed, frequentlyPlayed, random, genres, playlists, albums, artists, albumArtists, downloads

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
        case .favorites: return String(localized: "Favorites")
        case .recentlyPlayed: return String(localized: "Recently Played")
        case .frequentlyPlayed: return String(localized: "Frequently Played")
        case .random: return String(localized: "Random")
        case .albumArtists: return String(localized: "Album Artists")
        case .genres: return String(localized: "Genres")
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
        case .favorites: return "heart"
        case .recentlyPlayed: return "clock"
        case .frequentlyPlayed: return "star"
        case .random: return "shuffle"
        case .albumArtists: return "person.2"
        case .genres: return "guitars"
        case .playlists: return "music.note.list"
        }
    }
}

struct MacRootView: View {
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var section: MacSection? = .home
    @State private var path = NavigationPath()
    /// Bumped when a section showing at its root is clicked again, to rebuild it at its top.
    @State private var rootReset = 0
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
        .overlay {
            if MacSupportPrompt.shared.isShown {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    MacSupportCard()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: MacSupportPrompt.shared.isShown)
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

    /// A section clicked again, as a tab tapped again on the iPhone: out of search and back
    /// to the section's root, or, already there, back to its top.
    private func reselect() {
        if !query.isEmpty || !path.isEmpty {
            query = ""
            path = NavigationPath()
        } else {
            rootReset += 1
        }
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
            MacSidebar(section: $section) { reselect() }
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
                                .id("\(String(describing: section))-\(rootReset)")
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
                    .navigationDestination(for: MacGenre.self) { pushed(MacSongsView(kind: .genre($0.name))) }
                    .navigationDestination(for: WrappedPeriod.self) { pushed(WrappedView(initialPeriod: $0)) }
                    .navigationDestination(for: RadarRelease.self) { pushed(MacReleaseView(release: $0)) }
                    .animation(.smooth(duration: 0.28), value: section)
                    .macPendingNavigation(path: $path)
                }
                .environment(\.macOpenRelease, MacReleaseOpener { path.append($0) })
            }
            // In the title bar's row, centred over the page, as a fixture of the window
            // rather than of the sidebar: it stays put while sections change beneath it.
            .overlay(alignment: .top) {
                MacSearchBar(query: $query) { entry in
                    // A recent search reopened: armed again, as when it was first found.
                    SearchHistory.shared.arm(entry)
                    switch entry {
                    case .artist(let artist): path.append(artist)
                    case .album(let album): path.append(album)
                    case .playlist(let playlist): path.append(playlist)
                    case .mix(let mix):
                        // Today's mix of that id when there is one; the saved copy once it's gone.
                        let current = MixGenerator.shared.mixes.first { $0.id == mix.id } ?? mix
                        SearchHistory.shared.arm(.mix(current))
                        path.append(current)
                    case .song: break
                    }
                }
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
        // Recently Searched holds what was played, not looked at: a page opened from search
        // is kept once something plays from it, and forgotten on the way back empty-handed.
        .onChange(of: player.playbackSource) { _, source in
            if !path.isEmpty { SearchHistory.shared.commitIfPlaying(source: source) }
        }
        .onChange(of: path.count) { _, depth in
            if depth == 0 { SearchHistory.shared.disarm() }
        }
        .task {
            MacSpaceKey.install()
            swipe.canGoBack = { !path.isEmpty }
            swipe.goBack = { if !path.isEmpty { path.removeLast() } }
            swipe.install()
            // As the phone opens: online if the server answers, offline (with downloads) if
            // not, then the periodic check that switches between them.
            await serverManager.settleModeOnOpen()
            serverManager.startMonitoring()
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
        // Through the swipe's handler, set up once the window is live: this closure is built
        // with the page, from a copy of the view whose path was still empty, so testing the
        // path here found nothing to remove and the button did nothing.
        Button { swipe.goBack() } label: {
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
        if AppSettings.shared.offlineMode && section != .downloads {
            MacOfflineView(section: section ?? .home)
        } else {
        switch section ?? .home {
        case .home: MacHomeView()
        case .mixes: MacMixesView()
        case .radar: MacRadarView()
        case .wrapped: WrappedView()
        case .downloads: MacDownloadsView()
        case .albums: MacAlbumsView()
        case .artists: MacArtistsView()
        case .songs: MacSongsView()
        case .favorites: MacSongsView(kind: .favorites)
        case .recentlyPlayed: MacSongsView(kind: .recentlyPlayed)
        case .frequentlyPlayed: MacSongsView(kind: .frequentlyPlayed)
        case .random: MacSongsView(kind: .random)
        case .albumArtists: MacAlbumArtistsView()
        case .genres: MacGenresView()
        case .playlists: MacPlaylistsView()
        }
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
/// anywhere; Escape leaves it. Focused and empty, it drops down the operators and what was
/// played from search, as the phone's empty search shows them.
struct MacSearchBar: View {
    @Binding var query: String
    /// A recent artist, album, playlist or mix, to open.
    var open: (RecentSearchEntry) -> Void = { _ in }
    @FocusState private var searching: Bool
    @State private var history = SearchHistory.shared

    private var showsHistory: Bool {
        searching && query.isEmpty && (!history.entries.isEmpty || !LibraryIndex.shared.chips(for: "").isEmpty)
    }

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
        // Hangs under the pill, the same width, growing down from it.
        .overlay(alignment: .top) {
            if showsHistory {
                MacSearchHistoryList(history: history, query: $query) { entry in
                    if let song = entry.playableSong {
                        // Left where it is: moved to the top under the pointer, it looked deleted.
                        AudioPlayer.shared.playSong(song, source: .search(query: ""))
                    } else {
                        searching = false
                        open(entry)
                    }
                }
                .frame(maxWidth: 440)
                .offset(y: 42)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        // A hidden button carries the shortcut, so it works whatever has focus.
        .background(Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0))
        .padding(.horizontal, 120)
        .animation(.easeOut(duration: 0.15), value: searching)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: showsHistory)
    }
}

/// The dropdown: the operators, then what was played from search with its artwork, each
/// with its own cross, and Clear.
private struct MacSearchHistoryList: View {
    let history: SearchHistory
    @Binding var query: String
    let pick: (RecentSearchEntry) -> Void
    @State private var hovered: String?
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacSearchChips(query: $query, inset: 14)
                .padding(.top, 10)
            if !history.entries.isEmpty {
                HStack {
                    Text("Recently Searched").font(.system(size: 11, weight: .semibold)).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { withAnimation(.easeOut(duration: 0.2)) { history.clear() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appAccent)
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            }

            ForEach(Array(history.entries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 10) {
                    thumbnail(entry)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.system(size: 13)).lineLimit(1)
                            .foregroundStyle(entry.playableSong.map { $0.id == AudioPlayer.shared.currentSong?.id } == true
                                             ? Color.appAccent : .primary)
                        if let subtitle = entry.subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { history.remove(entry) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(hovered == entry.id ? 1 : 0.45)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(hovered == entry.id ? 0.08 : 0)).padding(.horizontal, 6))
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
                .onTapGesture { pick(entry) }
                // Rows fall in one after another as the list opens.
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : -6)
                .animation(.easeOut(duration: 0.22).delay(Double(index) * 0.03), value: shown)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onAppear { shown = true }
    }

    @ViewBuilder
    private func thumbnail(_ entry: RecentSearchEntry) -> some View {
        if case .mix(let mix) = entry {
            EditorialMixCover(mix: mix, size: 32, cornerRadius: 4)
        } else {
            CoverArtImage(coverArt: entry.coverArt, size: 32, cornerRadius: entry.isCircular ? 16 : 4,
                          placeholderName: entry.title)
        }
    }
}

/// Asked once per version after ten songs: a coffee on Ko-fi first, a star on GitHub (where
/// the Mac app is published) beside it, and only a small cross to say no.
@MainActor @Observable final class MacSupportPrompt {
    static let shared = MacSupportPrompt()
    var isShown = false

    static func show() { shared.isShown = true }
}

struct MacSupportCard: View {
    private static let kofi = URL(string: "https://ko-fi.com/adrbn")!
    private static let github = URL(string: "https://github.com/adrbn/aura")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enjoying Aura on the Mac?")
                .font(.system(size: 20, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 30)
            Text("Aura is free, with no ads and no subscription, and made by one person. A coffee on Ko-fi pays for the time it takes, and a star on GitHub helps other people find it.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side when both labels fit on one line, stacked full width when a
            // language makes them longer, never a label broken over two lines.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { kofiButton(); githubButton() }
                VStack(spacing: 8) { kofiButton(fill: true); githubButton(fill: true) }
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 470, alignment: .leading)
        .background(MacBackground(grid: false))
        .overlay(alignment: .topTrailing) {
            Button { MacSupportPrompt.shared.isShown = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
    }

    private func kofiButton(fill: Bool = false) -> some View {
        Button { open(Self.kofi) } label: {
            Label("Buy a Coffee on Ko-fi", systemImage: "cup.and.saucer.fill")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: 36)
                .background(Color.appAccent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func githubButton(fill: Bool = false) -> some View {
        Button { open(Self.github) } label: {
            Label("Star on GitHub", systemImage: "star")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(height: 36)
                .background(.primary.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        MacSupportPrompt.shared.isShown = false
    }
}
