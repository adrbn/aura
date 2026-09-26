import SwiftUI

struct ContentView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var audioPlayer
    @State private var selectedTab = 0
    @State private var showAddServer = false
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

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
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

            VStack(spacing: 0) {
                Spacer()

                // Download indicator
                if DownloadManager.shared.isDownloading {
                    DownloadIndicatorView()
                        .padding(.bottom, audioPlayer.hasQueue ? 0 : 49)
                        .onTapGesture { showDownloadManager = true }
                }

                #if !APPSTORE_BUILD
                FetchProgressBanner(bottomGap: audioPlayer.hasQueue ? 6 : 57, height: $fetchCardHeight)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: ReleaseFetcher.shared.visible.first?.id)
                #endif

                // Above the fetch card, which a stack otherwise draws on top while it leaves.
                if audioPlayer.hasQueue {
                    MiniPlayerView()
                        .padding(.bottom, 57)
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
        }
        .sheet(isPresented: $showDownloadManager) {
            NavigationStack {
                DownloadManagerView()
            }
        }
        .onChange(of: audioPlayer.pendingArtistId) { _, newId in
            guard newId != nil else { return }
            switchToLibraryTab()
        }
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardVisible = false }
        }
    }

    private var offlineContent: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                OfflineLibraryView()
                if audioPlayer.hasQueue {
                    VStack(spacing: 0) {
                        Spacer()
                        MiniPlayerView()
                    }
                }
                ToastOverlay()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { audioPlayer.isShowingNowPlaying },
            set: { audioPlayer.isShowingNowPlaying = $0 }
        )) {
            NowPlayingView()
        }
        .task {
            await serverManager.testConnection()
            serverManager.startMonitoring()
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
            Spacer()
        }
        .sheet(isPresented: $showAddServer) { AddServerView() }
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
                    Text(dm.currentDownloadTitle ?? "Downloading…")
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
                        appSettings.offlineMode = true
                        appSettings.save()
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

// MARK: - Offline Status Bar

/// Compact strip at the top of the offline library explaining WHY the app is
/// offline — "no internet" and "server unreachable" are very different problems
/// for a self-hosted server (e.g. Navidrome on a home LAN / Tailscale).
struct OfflineStatusBar: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(\.appAccentColor) private var accentColor
    @State private var isRetrying = false

    private var statusText: String {
        if !serverManager.hasNetwork { return "No internet connection" }
        if !serverManager.isConnected { return "Server unreachable" }
        return "Offline mode"
    }

    private var statusDetail: String {
        if !serverManager.hasNetwork { return "Playing downloaded music" }
        if !serverManager.isConnected { return "You're connected, but the server isn't responding" }
        return "Server is reachable — go online anytime"
    }

    private var statusIcon: String {
        if !serverManager.hasNetwork { return "wifi.slash" }
        if !serverManager.isConnected { return "exclamationmark.icloud" }
        return "icloud.slash"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(serverManager.isConnected ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))

            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.caption.weight(.semibold))
                Text(statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !serverManager.isConnected && serverManager.hasNetwork {
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
                            .controlSize(.small)
                    } else {
                        Text("Retry")
                            .font(.caption.weight(.bold))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.2))
                .clipShape(Capsule())
            } else if serverManager.isConnected {
                // Server answers while we're offline — offer the way out right here.
                // Previously this state had NO action at all: the bar said "go online
                // anytime" but the only actual switch lived in Settings.
                Button {
                    serverManager.goBackOnline()
                } label: {
                    Text("Go Online")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.2))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Rounded card instead of a full-bleed grey slab flush against the screen edges.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}
