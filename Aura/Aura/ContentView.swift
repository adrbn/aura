import SwiftUI
import StoreKit

struct ContentView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @State private var selectedTab = 0
    @State private var showAddServer = false
    @State private var isOpeningDemo = false
    @State private var demoError: String?
    @Environment(\.requestReview) private var requestReview
    /// Songs started since the last rating prompt, and the version that prompt was for.
    @AppStorage("review_songs") private var reviewSongs = 0
    @AppStorage("review_version") private var reviewVersion = ""
    @State private var appSettings = AppSettings.shared
    @Environment(\.appAccentColor) private var accentColor
    @State private var showDownloadManager = false
    @State private var keyboardVisible = false
    /// The fetch card's height, measured, for the room the pages leave under them.
    @State private var fetchCardHeight: CGFloat = 0

    var body: some View {
        if serverManager.hasServer {
            if appSettings.offlineMode {
                offlineContent
            } else {
                mainContent
            }
        } else {
            welcomeView
        }
    }

    /// Whether a keyboard about to show really covers the foot of the screen. With a
    /// hardware keyboard only the shortcuts bar shows, a strip that may never send its
    /// hide, and the mini player hidden for it stayed hidden.
    private static func coversContent(_ note: Notification) -> Bool {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return true }
        return frame.height > 120
    }

    /// Room left above the tab bar for what floats over the tabs. On an iPhone Duo the tab
    /// bar sits in the side column, by the status bar, so there is none to clear there: the
    /// mini player dips into the bottom inset to end level with the side tab bar's foot.
    private var tabBarGap: CGFloat { tabBarBeside ? -10 : 57 }
    /// Read from the layout, not the window: at launch the window has no insets yet, and a
    /// value read once then kept the phone's gap until something else redrew the bars.
    @State private var tabBarBeside = false

    /// A tap on the tab already open sets it again: on Search that empties the field, as
    /// the other tabs go back to their first page.
    private var tabSelection: Binding<Int> {
        Binding(get: { selectedTab }, set: { tab in
            if tab == selectedTab, appSettings.tabOrder.indices.contains(tab), appSettings.tabOrder[tab] == .search {
                NotificationCenter.default.post(name: .searchTabReselected, object: nil)
            }
            selectedTab = tab
        })
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: tabSelection) {
                ForEach(Array(appSettings.tabOrder.enumerated()), id: \.element.id) { index, tab in
                    Tab(tab.title, systemImage: tab.icon, value: index) {
                        tabContent(for: tab)
                            .overlay(alignment: .bottom) {
                                BottomEdgeVeil(coversMiniPlayer: audioPlayer.hasQueue)
                            }
                    }
                }
            }
            .tint(appSettings.activeTheme.accentColor)
            .onChange(of: fetchCardInset, initial: true) { BottomChrome.shared.cardInset = $1 }
            .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.leading > 0 || $0.safeAreaInsets.trailing > 0 } action: {
                tabBarBeside = $0
            }

            VStack(spacing: 0) {
                Spacer()

                // Download indicator
                if DownloadManager.shared.isDownloading {
                    DownloadIndicatorView()
                        .padding(.bottom, audioPlayer.hasQueue ? 0 : tabBarGap - 8)
                        .onTapGesture { showDownloadManager = true }
                }

                #if !APPSTORE_BUILD
                FetchProgressBanner(bottomGap: audioPlayer.hasQueue ? 6 : tabBarGap, height: $fetchCardHeight)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: ReleaseFetcher.shared.fetches.map(\.id))
                #endif

                PlayingElsewhereRow()
                    .padding(.bottom, audioPlayer.hasQueue || RemoteLink.shared.connected != nil ? 0 : tabBarGap)
                    .animation(.smooth(duration: 0.35), value: RemoteLink.shared.playingElsewhere?.playing)

                // Above the fetch card, which a stack otherwise draws on top while it leaves.
                if audioPlayer.hasQueue || RemoteLink.shared.connected != nil {
                    MiniPlayerView()
                        .padding(.bottom, tabBarGap)
                        .zIndex(1)
                }
            }
            // The keyboard doesn't carry them up over what's being typed for: they stay put
            // behind it, faded so they don't show through its glass.
            .ignoresSafeArea(.keyboard)
            .opacity(keyboardVisible ? 0 : 1)
            .allowsHitTesting(!keyboardVisible)

            ToastOverlay()
        }
        // Floats, and tab roots reserve its height via TabChrome.contentTop — they ignore
        // the top safe area, so an inset here would do nothing.
        .overlay(alignment: .top) {
            ConnectionBanner()
        }
        .fullScreenCover(isPresented: Binding(
            get: { audioPlayer.isShowingNowPlaying },
            set: { audioPlayer.isShowingNowPlaying = $0 }
        ), onDismiss: {
            handlePostDismissNavigation()
        }) {
            NowPlayingView()
                .duoPreview()
        }
        .sheet(isPresented: $showDownloadManager) {
            NavigationStack {
                DownloadManagerView()
            }
        }
        .onChange(of: audioPlayer.currentSong?.id) { _, id in
            askForRatingIfDue(songID: id)
        }
        .onChange(of: audioPlayer.pendingArtistId) { _, newId in
            guard newId != nil else { return }
            switchToLibraryTab()
        }
        #if DEBUG
        .task { await shoot() }
        #endif
        .onChange(of: audioPlayer.pendingAlbumId) { _, newId in
            guard newId != nil else { return }
            switchToLibraryTab()
        }
        .onChange(of: audioPlayer.pendingPlaylistId) { _, newId in
            guard newId != nil else { return }
            switchToPlaylistsTab()
        }
        .onChange(of: audioPlayer.pendingRadioOpen) { _, newValue in
            if newValue {
                handlePostDismissNavigation()
            }
        }
        .onChange(of: audioPlayer.pendingFavoritesOpen) { _, newValue in
            if newValue && !audioPlayer.isShowingNowPlaying {
                // Only switch immediately if NowPlaying is already dismissed.
                // Otherwise handlePostDismissNavigation will handle it.
                switchToLibraryTab()
            }
        }
        .onChange(of: audioPlayer.pendingGenreName) { _, newName in
            guard newName != nil else { return }
            switchToLibraryTab()
        }
        .onChange(of: audioPlayer.pendingRecentlyPlayedOpen) { _, newValue in
            if newValue { switchToLibraryTab() }
        }
        .onChange(of: audioPlayer.pendingFrequentlyPlayedOpen) { _, newValue in
            if newValue { switchToLibraryTab() }
        }
        .onChange(of: audioPlayer.pendingMixId) { _, newId in
            guard newId != nil else { return }
            switchToHomeTab()
        }
        .onChange(of: audioPlayer.pendingWrappedPeriod) { _, period in
            guard period != nil else { return }
            switchToHomeTab()
        }
        .task {
            await serverManager.testConnection()
            serverManager.startMonitoring()
            // Backfill permanent artwork for existing downloads while we have a connection.
            await DownloadManager.shared.ensureOfflineArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            withAnimation(.easeOut(duration: 0.25)) { keyboardVisible = Self.coversContent(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardVisible = false }
        }
    }

    /// Offline, the same app: the same tabs in the same order, each showing what this
    /// iPhone holds, with the mini player and Now Playing where they always are.
    private var offlineContent: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: tabSelection) {
                ForEach(Array(appSettings.tabOrder.enumerated()), id: \.element.id) { index, tab in
                    Tab(tab.title, systemImage: tab.icon, value: index) {
                        offlineTabContent(for: tab)
                            .overlay(alignment: .bottom) {
                                BottomEdgeVeil(coversMiniPlayer: audioPlayer.hasQueue)
                            }
                    }
                }
            }
            .tint(appSettings.activeTheme.accentColor)

            VStack(spacing: 0) {
                Spacer()
                if audioPlayer.hasQueue || RemoteLink.shared.connected != nil {
                    MiniPlayerView()
                        .padding(.bottom, tabBarGap)
                }
            }
            .ignoresSafeArea(.keyboard)
            .opacity(keyboardVisible ? 0 : 1)
            .allowsHitTesting(!keyboardVisible)

            ToastOverlay()
        }
        .fullScreenCover(isPresented: Binding(
            get: { audioPlayer.isShowingNowPlaying },
            set: { audioPlayer.isShowingNowPlaying = $0 }
        ), onDismiss: {
            handlePostDismissNavigation()
        }) {
            NowPlayingView()
                .duoPreview()
        }
        // Now Playing's links open in the tab that holds them, as online.
        .onChange(of: audioPlayer.pendingArtistId) { _, newId in
            if newId != nil { switchToLibraryTab() }
        }
        .onChange(of: audioPlayer.pendingAlbumId) { _, newId in
            if newId != nil { switchToLibraryTab() }
        }
        .onChange(of: audioPlayer.pendingGenreName) { _, newName in
            if newName != nil { switchToLibraryTab() }
        }
        .onChange(of: audioPlayer.pendingFavoritesOpen) { _, open in
            if open && !audioPlayer.isShowingNowPlaying { switchToLibraryTab() }
        }
        .onChange(of: audioPlayer.pendingPlaylistId) { _, newId in
            if newId != nil { switchToPlaylistsTab() }
        }
        .onChange(of: audioPlayer.pendingMixId) { _, newId in
            if newId != nil { switchToHomeTab() }
        }
        .task {
            OfflineLibrary.shared.refresh()
            await serverManager.testConnection()
            serverManager.startMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            withAnimation(.easeOut(duration: 0.25)) { keyboardVisible = Self.coversContent(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardVisible = false }
        }
    }

    @ViewBuilder
    private func offlineTabContent(for tab: TabItem) -> some View {
        switch tab {
        case .home: OfflineHomeView()
        case .library: OfflineLibraryView()
        case .playlists: OfflinePlaylistsView()
        case .settings: SettingsView()
        case .search: OfflineSearchView()
        }
    }

    /// Room the fetch card takes above the mini player, so the pages behind it end above it
    /// (`ListEndSpacer`).
    private var fetchCardInset: CGFloat {
        #if APPSTORE_BUILD
        return 0
        #else
        return ReleaseFetcher.shared.visible.isEmpty ? 0 : fetchCardHeight + 6
        #endif
    }

    @ViewBuilder
    private func tabContent(for tab: TabItem) -> some View {
        switch tab {
        case .home: HomeView()
        case .library: LibraryView()
        case .playlists: PlaylistsView()
        case .settings: SettingsView()
        case .search: SearchView()
        }
    }

    #if DEBUG
    /// Puts the app on an App Store screenshot's screen: tools/app-store-shots/shoot.sh
    /// launches it with `-shot`, `-shotQuery` and `-shotAt`.
    private func shoot() async {
        guard let shot = Shot.name else { return }
        try? FileManager.default.removeItem(at: Shot.ready)
        guard let server = serverManager.currentServer else { return Shot.note("no server") }
        let query = UserDefaults.standard.string(forKey: "shotQuery") ?? ""
        switch shot {
        case "library", "downloads":
            switchToLibraryTab()
        case "artist":
            let artists = (try? await SubsonicClient.shared.search3(server: server, query: query, artistCount: 20).artist) ?? []
            // The search can put "Avicii, CAZZETTE" and four others before "Avicii".
            guard let artist = artists.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) ?? artists.first
            else { return }
            audioPlayer.pendingArtistId = artist.id
        case "album":
            guard let album = try? await SubsonicClient.shared.search3(server: server, query: query).album?.first else { return }
            audioPlayer.pendingAlbumId = album.id
        case "radio":
            guard let song = try? await SubsonicClient.shared.search3(server: server, query: query).song?.first
            else { return }
            // Playing it keeps the mini player on a short title, not mid-scroll through the last.
            audioPlayer.playSong(song, fromQueue: [song], startIndex: 0)
            audioPlayer.startRadioFromSong(song)
        case "nowPlaying", "lyrics":
            guard let songs = try? await SubsonicClient.shared.search3(server: server, query: query).song,
                  let song = songs.first else { return }
            audioPlayer.playSong(song, fromQueue: songs, startIndex: 0)
            audioPlayer.isShowingNowPlaying = true
            try? await Task.sleep(for: .seconds(2))
            audioPlayer.seek(to: UserDefaults.standard.double(forKey: "shotAt"))
            // A layout check, not a listening session: the phone may be in a pocket.
            if DuoPreview.size != nil {
                for _ in 0..<20 where !audioPlayer.isPlaying { try? await Task.sleep(for: .milliseconds(250)) }
                // `-duoPlaying YES` keeps it playing, silent, to see the cover at its playing size.
                if UserDefaults.standard.bool(forKey: "duoPlaying") { audioPlayer.volume = 0 } else { audioPlayer.pause() }
            }
        default:
            break
        }
        // The script captures the screen only once this says "active": never another app.
        try? await Task.sleep(for: .seconds(3))
        #if os(iOS)
        Shot.note(UIApplication.shared.applicationState == .active ? "active" : "background")
        #endif
    }
    #endif

    private func switchToLibraryTab() {
        if let idx = appSettings.tabOrder.firstIndex(of: .library) {
            selectedTab = idx
        }
    }

    private func switchToPlaylistsTab() {
        if let idx = appSettings.tabOrder.firstIndex(of: .playlists) {
            selectedTab = idx
        }
    }

    private func switchToHomeTab() {
        if let idx = appSettings.tabOrder.firstIndex(of: .home) {
            selectedTab = idx
        }
    }

    private func handlePostDismissNavigation() {
        if audioPlayer.pendingRadioOpen {
            audioPlayer.pendingRadioOpen = false
            switchToPlaylistsTab()
            // Delay so the new PlaylistsView instance has time to mount
            // before we trigger the navigation via isShowingRadioPlaylist
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                audioPlayer.isShowingRadioPlaylist = true
            }
        }
        if audioPlayer.pendingFavoritesOpen {
            switchToLibraryTab()
            // Delay so LibraryView mounts before it reads the flag
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                // LibraryView .onAppear / .onChange will pick up the flag
            }
        }
        if audioPlayer.pendingArtistId != nil {
            switchToLibraryTab()
        }
        if audioPlayer.pendingGenreName != nil {
            switchToLibraryTab()
        }
        if audioPlayer.pendingRecentlyPlayedOpen {
            switchToLibraryTab()
        }
        if audioPlayer.pendingFrequentlyPlayedOpen {
            switchToLibraryTab()
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 80)).foregroundStyle(accentColor)
            Text("Aura").font(.largeTitle.bold())
            Text("Connect to your Navidrome server\nto start listening")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { showAddServer = true } label: {
                Label("Add Server", systemImage: "plus")
                    .font(.headline).frame(maxWidth: .infinity).padding()
                    .background(accentColor).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 40)
            Button { Task { await tryDemo() } } label: {
                if isOpeningDemo { ProgressView() } else { Text("No server? Try the Navidrome demo") }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(isOpeningDemo)
            if let demoError {
                Text(demoError).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Spacer()
        }
        .sheet(isPresented: $showAddServer) { AddServerView() }
    }

    /// Asks for an App Store rating once per version, after 40 songs, never on the demo
    /// server: someone listening that much to their own library has an opinion worth giving.
    private func askForRatingIfDue(songID: String?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard songID != nil, reviewVersion != version,
              serverManager.currentServer?.url.contains("demo.navidrome.org") == false else { return }
        reviewSongs += 1
        guard reviewSongs >= 10 else { return }
        reviewSongs = 0
        reviewVersion = version
        requestReview()
    }

    /// The public Navidrome demo, so someone without a server of their own sees what Aura does.
    private func tryDemo() async {
        isOpeningDemo = true
        demoError = nil
        let demo = ServerConfig(url: "https://demo.navidrome.org", username: "demo",
                                password: "demo", friendlyName: "Navidrome Demo")
        if (try? await SubsonicClient.shared.ping(server: demo)) == true {
            serverManager.addServer(demo)
        } else {
            demoError = String(localized: "The demo server didn't answer. Try again in a moment.")
        }
        isOpeningDemo = false
    }
}

// MARK: - Download Indicator

struct DownloadIndicatorView: View {
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        let dm = DownloadManager.shared
        if dm.isDownloading {
            let songProgress = dm.currentDownloadId.flatMap { dm.downloadProgress[$0] } ?? 0

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
                        .frame(width: 30, height: 30)
                    Circle()
                        .trim(from: 0, to: CGFloat(songProgress))
                        .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 30, height: 30)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.2), value: songProgress)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(dm.currentDownloadTitle ?? String(localized: "Downloading…"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let album = dm.currentDownloadAlbum {
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if dm.totalQueueCount > 1 {
                            Text("• \(min(dm.completedQueueCount + 1, dm.totalQueueCount))/\(dm.totalQueueCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .foregroundStyle(.primary)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut, value: dm.isDownloading)
        }
    }
}

// MARK: - Connection Banner

/// Slim pill shown while online mode can't reach the server — makes the outage
/// visible outside Settings and offers a way out (retry, or switch to the offline
/// library when downloads exist). Disappears on its own once the ping succeeds.
struct ConnectionBanner: View {
    @Environment(ServerManager.self) private var serverManager
    @State private var appSettings = AppSettings.shared
    @State private var isRetrying = false

    /// Only meaningful once a connection attempt has actually failed —
    /// `connectionError` stays nil during the initial ping, avoiding a launch flash.
    /// Static so `TabChrome.bannerInset` reserves space from the SAME rule the banner
    /// renders from — two copies would drift and the title would get covered again.
    static var isVisible: Bool {
        !AppSettings.shared.offlineMode
            && !ServerManager.shared.isConnected
            && ServerManager.shared.connectionError != nil
    }

    private var isVisible: Bool { Self.isVisible }

    var body: some View {
        if isVisible {
            HStack(spacing: 8) {
                Image(systemName: serverManager.hasNetwork ? "exclamationmark.icloud" : "wifi.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                Text(serverManager.hasNetwork ? "Server unreachable" : "No connection")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if serverManager.hasNetwork {
                    Button {
                        guard !isRetrying else { return }
                        isRetrying = true
                        Task {
                            await serverManager.testConnection()
                            isRetrying = false
                        }
                    } label: {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Text("Retry")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.2))
                    .clipShape(Capsule())
                }

                if !DownloadManager.shared.downloadedSongs.isEmpty {
                    Button {
                        ServerManager.shared.goOfflineManually()
                    } label: {
                        Text("Go Offline")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.2))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: isVisible)
        }
    }
}

// MARK: - Load Error View

/// Standard "couldn't load" state for list/grid screens. Distinguishes a device
/// with no connectivity from a reachable network where the user's self-hosted
/// server isn't responding, and always offers a retry.
struct LoadErrorView: View {
    let retry: () -> Void

    @Environment(ServerManager.self) private var serverManager

    var body: some View {
        ContentUnavailableView {
            Label(
                serverManager.hasNetwork ? "Server Unreachable" : "No Internet Connection",
                systemImage: serverManager.hasNetwork ? "exclamationmark.icloud" : "wifi.slash"
            )
        } description: {
            Text("Check your connection or server, then try again.")
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}


#if DEBUG
/// The screen an App Store screenshot is taken of, from the launch arguments; nil otherwise.
/// `-duoPreview 951x669` draws Now Playing at an iPhone Duo screen's size, shrunk to fit the
/// phone, so the wide layout can be seen and captured without a Duo or a simulator.
/// Sizes in points: inner 669x951 upright, 951x669 on its side; outer 466x678.
enum DuoPreview {
    static let size: CGSize? = UserDefaults.standard.string(forKey: "duoPreview").flatMap { text in
        let parts = text.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }
}

enum Shot {
    static let name = UserDefaults.standard.string(forKey: "shot")
    static let ready = URL.documentsDirectory.appending(path: "shot-ready")
    static func note(_ state: String) { try? Data(state.utf8).write(to: ready) }
}
#endif

extension View {
    /// See `DuoPreview`. Release builds, and debug builds launched without it, are unchanged.
    @ViewBuilder func duoPreview() -> some View {
        #if DEBUG
        if let size = DuoPreview.size {
            GeometryReader { geo in
                let scale = min(geo.size.width / size.width, geo.size.height / size.height)
                self.frame(width: size.width, height: size.height)
                    .environment(\.horizontalSizeClass, size.width >= 600 ? .regular : .compact)
                    .clipped()
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(.black)
            .ignoresSafeArea()
        } else {
            self
        }
        #else
        self
        #endif
    }
}
