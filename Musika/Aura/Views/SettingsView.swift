import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ServerManager.self) private var serverManager
    @State private var showAddServer = false
    @State private var appSettings = AppSettings.shared
    @State private var downloadManager = DownloadManager.shared
    @State private var scanStatus: ScanStatus?
    @State private var isScanning = false
    @State private var serverStats: ServerStats?
    @State private var showDeleteConfirmation = false
    @State private var musicFolders: [MusicFolder] = []

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    struct ServerStats {
        var songCount: Int = 0
        var albumCount: Int = 0
        var artistCount: Int = 0
        var playlistCount: Int = 0
    }

    @State private var showDownloadManager = false
    @State private var showDownloadAllConfirmation = false
    @State private var isClearingCache = false
    @State private var isDownloadingLibrary = false
    @State private var libraryDownloadProgress: String?
    @State private var showFolderPicker = false

    /// Accent color read through the tracked @State appSettings so SwiftUI
    /// observes changes and re-renders immediately (accentColor goes
    /// through AppSettings.shared which isn't tracked by this view).
    private var accentColor: Color { appSettings.activeTheme.accentColor }

    var body: some View {
        NavigationStack {
            settingsList
                .tabRootGlass(scrollY: $scrollY)
                .sheet(isPresented: $showAddServer) { AddServerView() }
                .sheet(isPresented: $showDownloadManager) {
                    NavigationStack { DownloadManagerView() }
                }
                .task {
                    await loadServerStats()
                    await loadMusicFolders()
                }
        }
        .tint(accentColor)
    }

    private var settingsList: some View {
        settingsListContent
            .onChangeSettings()
    }

    @State private var scrollToEqualizer = false
    @State private var scrollToDownloads = false
    @State private var scrollY: CGFloat = 0
    @State private var scrollToScan = false

    private var quickAccessGrid: some View {
        Section {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
            LazyVGrid(columns: columns, spacing: 12) {
                // Row 1: Server Status | Equalizer | Downloads
                quickTile(
                    icon: serverManager.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill",
                    label: serverManager.isConnected ? "Online" : "Offline",
                    color: serverManager.isConnected ? .green : .red
                ) {
                    // Disable offline mode if active, then try reconnecting
                    if appSettings.offlineMode {
                        appSettings.offlineMode = false
                        appSettings.save()
                    }
                    Task { await serverManager.testConnection() }
                }

                quickTile(icon: "slider.vertical.3", label: "Equalizer", color: .purple) {
                    showEqualizer = true
                }

                quickTile(icon: "arrow.down.circle.fill", label: "Downloads", color: .blue) {
                    showDownloadManager = true
                }

                // Row 2: Offline Mode | Scan | Clear Cache
                quickTile(
                    icon: appSettings.offlineMode ? "wifi.slash" : "wifi",
                    label: "Offline Mode",
                    color: appSettings.offlineMode ? .red : .teal
                ) {
                    appSettings.offlineMode.toggle()
                    appSettings.save()
                }

                quickTile(icon: "arrow.triangle.2.circlepath", label: "Scan", color: .mint) {
                    Task { await quickScan() }
                }

                quickTile(icon: "xmark.bin.fill", label: "Clear Cache", color: .red) {
                    isClearingCache = true
                    Task {
                        // Measure size before clearing
                        let audioBytes = AudioCacheManager.shared.currentCacheSizeBytes
                        let artworkBytes = ArtworkCache.shared.currentCacheSizeBytes
                        let totalBytes = audioBytes + artworkBytes

                        AudioCacheManager.shared.clearCache()
                        ArtworkCache.shared.clearAll()
                        URLCache.shared.removeAllCachedResponses()
                        try? await Task.sleep(for: .milliseconds(500))
                        isClearingCache = false

                        let freed = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                        ToastManager.shared.show("Cache cleared — \(freed) freed", icon: "trash")
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private func quickTile(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var settingsListContent: some View {
        List {
            // Title aligned to the grouped content inset (no extra padding) so it lines up
            // with the cards/tiles below and matches the other tabs' left edge.
            Text("settings")
                .font(.custom("TuafTrial-Bold", size: 40, relativeTo: .largeTitle))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            quickAccessGrid
            Group {
                customiseSection
                homeCustomiseSection
                playbackSection
                equalizerSection
                lastfmSection
            }
            Group {
                downloadsSection
                offlineModeSection
                storageCacheSection
            }
            Group {
                serverSection
                musicFolderSection
                libraryScanSection
                manageServersSection
            }
            Group {
                #if !APPSTORE_BUILD
                betaFeaturesSection
                if appSettings.betaFeaturesEnabled {
                    externalServiceSection
                }
                #endif
                serverStatsSection
                aboutSection
                logOutSection
            }
        }
        .listSectionSpacing(.compact)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .id("\(appSettings.appAccentColor.rawValue)-\(appSettings.activeTheme.rawValue)") // Force full re-render on accent/theme change
        .sheet(isPresented: $showEqualizer) {
            EqualizerView()
                .presentationDetents([.large])
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section("Subsonic Server") {
            HStack {
                Text("Status")
                Spacer()
                Text(serverManager.isConnected ? "Online" : "Offline")
                    .foregroundStyle(serverManager.isConnected ? .green : .red)
            }
            if let server = serverManager.currentServer {
                NavigationLink {
                    ServerDetailView(server: server)
                } label: {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(server.friendlyName).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var musicFolderSection: some View {
        if !musicFolders.isEmpty {
            Section {
                Menu {
                    ForEach(musicFolders) { folder in
                        Button {
                            if appSettings.selectedMusicFolderIds.contains(folder.id) {
                                appSettings.selectedMusicFolderIds.remove(folder.id)
                            } else {
                                appSettings.selectedMusicFolderIds.insert(folder.id)
                            }
                            appSettings.save()
                        } label: {
                            HStack {
                                Text(folder.name ?? "Folder \(folder.id)")
                                if appSettings.selectedMusicFolderIds.contains(folder.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Music Folders")
                        Spacer()
                        Text(musicFolderSummary)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Music Folders")
            } footer: {
                if appSettings.selectedMusicFolderIds.isEmpty {
                    Text("All folders are shown. Select folders to filter content.")
                } else {
                    Text("\(appSettings.selectedMusicFolderIds.count) folder(s) selected.")
                }
            }
        }
    }

    private var musicFolderSummary: String {
        if appSettings.selectedMusicFolderIds.isEmpty {
            return "All"
        }
        let selected = musicFolders.filter { appSettings.selectedMusicFolderIds.contains($0.id) }
        if selected.count == 1, let first = selected.first {
            return first.name ?? "1 folder"
        }
        return "\(selected.count) folders"
    }

    private var libraryScanSection: some View {
        Section {
            if isScanning {
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanning…")
                        if let count = scanStatus?.count {
                            Text("\(count) items scanned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Button {
                    Task { await quickScan() }
                } label: {
                    Label("Quick Scan", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await fullScan() }
                } label: {
                    Label("Full Scan", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text("Library Scan")
        } footer: {
            Text("Quick scan checks for new/changed files. Full scan re-reads all metadata.")
        }
    }

    private var manageServersSection: some View {
        Section("Manage Servers") {
            ForEach(serverManager.servers) { server in
                HStack {
                    VStack(alignment: .leading) {
                        Text(server.friendlyName).font(.subheadline)
                        Text(server.url).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if server.id == serverManager.currentServer?.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    serverManager.selectServer(server)
                    Task { await serverManager.testConnection() }
                }
            }
            .onDelete { idx in
                for i in idx { serverManager.removeServer(serverManager.servers[i]) }
            }
            Button { showAddServer = true } label: {
                Label("Add Server", systemImage: "plus").foregroundStyle(accentColor)
            }
        }
    }

    private var playbackSection: some View {
        Section {
            Picker("Transcode Quality", selection: $appSettings.streamingQuality) {
                ForEach(StreamingQuality.allCases, id: \.self) { q in
                    Text(q.rawValue).tag(q)
                }
            }

            Toggle("Scrobble", isOn: $appSettings.scrobbleEnabled)

            if appSettings.scrobbleEnabled {
                HStack {
                    Text("Scrobble After")
                    Spacer()
                    Text("\(Int(appSettings.scrobbleThreshold * 100))%")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("ReplayGain", isOn: $appSettings.replayGain)
            Toggle("Gapless Playback", isOn: $appSettings.gaplessPlayback)

            Stepper("Crossfade: \(appSettings.crossfadeSeconds)s",
                    value: $appSettings.crossfadeSeconds, in: 0...12)

            Toggle("Landscape Clock", isOn: $appSettings.landscapeClockEnabled)

        } header: {
            Text("Playback")
        } footer: {
            if appSettings.streamingQuality == .lossless {
                Text("Streams original files (FLAC/ALAC). Uses more data. Incompatible formats (OGG/Opus) are auto-transcoded.")
            } else {
                Text("Lossless files will be transcoded to MP3 at \(appSettings.streamingQuality.bitRate ?? 320) kbps. Incompatible formats (OGG/Opus) are auto-transcoded.")
            }
        }
    }

    private var lastfmSection: some View {
        Section {
            HStack {
                Text("Username")
                Spacer()
                TextField("Last.fm username", text: $appSettings.lastfmUsername)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            HStack {
                Text("API Key")
                Spacer()
                // Plain TextField (not SecureField) so an already-saved key stays visible
                // — SecureField renders empty for a pre-filled value, which looked like the
                // key had vanished. It's the user's own read-only key, safe to display.
                TextField("API key", text: $appSettings.lastfmApiKey)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if appSettings.lastfmConfigured {
                Label("Connected — powers your Wrapped", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Last.fm")
        } footer: {
            Text("Builds your Wrapped retrospective from your real listening history. Create a free API key at last.fm/api/account/create.")
        }
    }

    @State private var showEqualizer = false

    private var equalizerSection: some View {
        Section("Equalizer") {
            Button {
                showEqualizer = true
            } label: {
                HStack {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                    Spacer()
                    Text(appSettings.eqPreset.rawValue)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private var downloadsSection: some View {
        Section("Downloads") {
            NavigationLink {
                DownloadManagerView()
            } label: {
                Label("Download Manager", systemImage: "arrow.down.circle")
            }

            Picker("Download Quality", selection: $appSettings.downloadQuality) {
                ForEach(DownloadQuality.allCases, id: \.self) { q in
                    Text(q.rawValue).tag(q)
                }
            }

            HStack {
                Text("Downloaded Songs")
                Spacer()
                Text("\(downloadManager.downloadedSongs.count)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Storage Used")
                Spacer()
                Text(downloadManager.totalDownloadSize)
                    .foregroundStyle(.secondary)
            }

            if isDownloadingLibrary {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloading Library...")
                            .font(.subheadline.weight(.medium))
                        if let progress = libraryDownloadProgress {
                            Text(progress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
            } else {
                Button {
                    showDownloadAllConfirmation = true
                } label: {
                    Label("Download Entire Library", systemImage: "arrow.down.to.line")
                }
                .confirmationDialog("Download Entire Library?", isPresented: $showDownloadAllConfirmation, titleVisibility: .visible) {
                    Button("Download to App Storage") {
                        Task { await downloadEntireLibrary() }
                    }
                    Button("Export to External Location...") {
                        showFolderPicker = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Download every song from your server. Choose \"Export to External Location\" to save to an external drive or custom folder.")
                }
                .sheet(isPresented: $showFolderPicker) {
                    FolderPicker { url in
                        showFolderPicker = false
                        Task { await exportEntireLibrary(to: url) }
                    }
                }
            }

            if !downloadManager.downloadedSongs.isEmpty {
                Button("Delete All Downloads", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .confirmationDialog("Delete All Downloads?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                    Button("Delete All", role: .destructive) {
                        downloadManager.deleteAll()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently remove all \(downloadManager.downloadedSongs.count) downloaded songs from your device.")
                }
            }
        }
    }

    private var offlineModeSection: some View {
        Section("Offline Mode") {
            Toggle("Offline Mode", isOn: $appSettings.offlineMode)
            Text("When enabled, only downloaded content will be shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageCacheSection: some View {
        Section("Storage & Cache") {
            Toggle("Cache Enabled", isOn: $appSettings.cacheEnabled)

            if appSettings.cacheEnabled {
                Stepper("Max Cache: \(String(format: "%.1f", Double(appSettings.cacheMaxSize) / 1024.0)) GB",
                        value: $appSettings.cacheMaxSize, in: 512...8192, step: 512)

                HStack {
                    Text("Audio Cache")
                    Spacer()
                    Text(AudioCacheManager.shared.currentCacheSizeFormatted)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    isClearingCache = true
                    Task {
                        let audioBytes = AudioCacheManager.shared.currentCacheSizeBytes
                        let artworkBytes = ArtworkCache.shared.currentCacheSizeBytes
                        let totalBytes = audioBytes + artworkBytes

                        AudioCacheManager.shared.clearCache()
                        ArtworkCache.shared.clearAll()
                        URLCache.shared.removeAllCachedResponses()
                        try? await Task.sleep(for: .milliseconds(500))
                        isClearingCache = false

                        let freed = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                        ToastManager.shared.show("Cache cleared — \(freed) freed", icon: "trash")
                    }
                } label: {
                    HStack {
                        Text("Clear Cache")
                        if isClearingCache {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isClearingCache)
            }

            Picker("Artwork Quality", selection: $appSettings.artworkQuality) {
                ForEach(ArtworkQuality.allCases, id: \.self) { q in
                    Text(q.rawValue).tag(q)
                }
            }
        }
    }

    private var customiseSection: some View {
        Section("Appearance") {
            NavigationLink("Tab Bar Order") {
                TabOrderView()
            }

            HStack {
                Text("Accent Colour")
                Spacer()
                HStack(spacing: 6) {
                    ForEach(AppAccentColor.allCases, id: \.self) { accent in
                        Circle()
                            .fill(accent.color)
                            .frame(width: 20, height: 20)
                            .overlay {
                                if appSettings.appAccentColor == accent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .onTapGesture { appSettings.appAccentColor = accent }
                    }
                }
            }
        }
    }

    private var homeCustomiseSection: some View {
        Section("Home Screen") {
            Picker("Title", selection: $appSettings.homeTitleStyle) {
                ForEach(HomeTitleStyle.allCases, id: \.self) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            Toggle("Library Stats", isOn: $appSettings.showStatsOnHome)
            Toggle("Play Counts", isOn: $appSettings.showPlayCounts)
            NavigationLink("Section Order") {
                HomeSectionOrderView()
            }
        }
    }

    @State private var showOnboarding = false

    #if !APPSTORE_BUILD
    private var betaFeaturesSection: some View {
        Section {
            Toggle("Enable Beta Features", isOn: $appSettings.betaFeaturesEnabled)
            if appSettings.betaFeaturesEnabled {
                NavigationLink {
                    DevLogsView()
                } label: {
                    Label("View Logs", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    showOnboarding = true
                } label: {
                    Label("Replay Onboarding", systemImage: "arrow.counterclockwise")
                }
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView()
                        .environment(serverManager)
                }
            }
        } header: {
            Label("Dev / Beta Features", systemImage: "hammer.fill")
        } footer: {
            Text("Experimental features that may not be fully stable.")
        }
    }

    private var externalServiceSection: some View {
        Section("Soulseek (slskd)") {
            HStack {
                Text("Host")
                Spacer()
                TextField("IP address", text: $appSettings.externalServiceURL)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            HStack {
                Text("Port")
                Spacer()
                TextField("Port", value: $appSettings.externalServicePort, format: .number)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .keyboardType(.numberPad)
            }

            HStack {
                Text("Username")
                Spacer()
                TextField("slskd", text: $appSettings.slskdUsername)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            HStack {
                Text("Password")
                Spacer()
                SecureField("slskd", text: $appSettings.slskdPassword)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                ExternalServiceView()
            } label: {
                Label("Search Soulseek", systemImage: "magnifyingglass")
            }
        }
    }
    #endif

    @ViewBuilder
    private var serverStatsSection: some View {
        if let stats = serverStats {
            Section("Server Statistics") {
                HStack {
                    Label("Songs", systemImage: "music.note")
                    Spacer()
                    Text("\(stats.songCount)").foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Label("Albums", systemImage: "square.stack")
                    Spacer()
                    Text("\(stats.albumCount)").foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Label("Artists", systemImage: "music.mic")
                    Spacer()
                    Text("\(stats.artistCount)").foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Label("Playlists", systemImage: "music.note.list")
                    Spacer()
                    Text("\(stats.playlistCount)").foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("App Version")
                Spacer()
                Text(Self.appVersion).foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://github.com/adrbn")!) {
                HStack {
                    Text("View on GitHub")
                    Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(accentColor)

            NavigationLink("About Aura") {
                AboutView()
            }
        }
    }

    private var logOutSection: some View {
        Group {
            Section {
                Button("Log Out", role: .destructive) {
                    serverManager.currentServer = nil
                    serverManager.servers.removeAll()
                    serverManager.saveServers()
                    serverManager.saveCurrentServer()
                }
            }
            Section {
                Color.clear.frame(height: 80)
            }
            .listRowBackground(Color.clear)
        }
    }

    private func loadServerStats() async {
        guard let server = serverManager.currentServer else { return }
        do {
            async let artists = SubsonicClient.shared.getArtists(server: server)
            async let playlists = SubsonicClient.shared.getPlaylists(server: server)
            async let scanResult = SubsonicClient.shared.getScanStatus(server: server)
            async let albumCount = SubsonicClient.shared.getAlbumCount(server: server)

            let (a, p, scan, albums) = try await (artists, playlists, scanResult, albumCount)
            await MainActor.run {
                serverStats = ServerStats(
                    songCount: scan.count ?? 0,
                    albumCount: albums,
                    artistCount: a.count,
                    playlistCount: p.count
                )
                scanStatus = scan
                isScanning = scan.scanning
            }
        } catch {
            AppLogger.shared.log("❌ Failed to load server stats: \(error.localizedDescription)")
        }
    }

    private func loadMusicFolders() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let folders = try await SubsonicClient.shared.getMusicFolders(server: server)
            await MainActor.run { musicFolders = folders }
        } catch {
            AppLogger.shared.log("❌ Failed to load music folders: \(error.localizedDescription)")
        }
    }

    private func downloadEntireLibrary() async {
        guard let server = serverManager.currentServer else { return }
        await MainActor.run {
            isDownloadingLibrary = true
            libraryDownloadProgress = "Scanning library..."
        }
        do {
            // Fetch all songs in batches
            var allSongs: [Song] = []
            var offset = 0
            let batchSize = 500
            while true {
                let batch = try await SubsonicClient.shared.search3(server: server, query: "", songCount: batchSize, songOffset: offset)
                let songs = batch.song ?? []
                if songs.isEmpty { break }
                allSongs.append(contentsOf: songs)
                offset += songs.count
                await MainActor.run {
                    libraryDownloadProgress = "Found \(allSongs.count) songs..."
                }
                if songs.count < batchSize { break }
            }
            // Filter out already-downloaded songs
            let downloaded = downloadManager.downloadedSongs
            let downloadedIds = Set(downloaded.map { $0.id })
            let toDownload = allSongs.filter { !downloadedIds.contains($0.id) }
            AppLogger.shared.log("Download All: \(toDownload.count) songs to download (\(allSongs.count) total, \(downloadedIds.count) already downloaded)")
            if toDownload.isEmpty {
                await MainActor.run {
                    isDownloadingLibrary = false
                    libraryDownloadProgress = nil
                    ToastManager.shared.show("All songs already downloaded!", icon: "checkmark.circle.fill")
                }
                return
            }
            await MainActor.run {
                libraryDownloadProgress = "Downloading \(toDownload.count) songs..."
            }
            await downloadManager.downloadAlbum(toDownload, groupId: "library-all")
            await MainActor.run {
                isDownloadingLibrary = false
                libraryDownloadProgress = nil
                ToastManager.shared.show("Download complete!", icon: "checkmark.circle.fill")
            }
        } catch {
            AppLogger.shared.log("Download All failed: \(error.localizedDescription)")
            await MainActor.run {
                isDownloadingLibrary = false
                libraryDownloadProgress = nil
                ToastManager.shared.show("Download failed", icon: "xmark.circle")
            }
        }
    }

    private func exportEntireLibrary(to folderURL: URL) async {
        guard let server = serverManager.currentServer else { return }
        guard folderURL.startAccessingSecurityScopedResource() else {
            ToastManager.shared.show("Cannot access selected folder", icon: "xmark.circle")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        await MainActor.run {
            isDownloadingLibrary = true
            libraryDownloadProgress = "Scanning library..."
        }
        do {
            // Fetch all songs in batches
            var allSongs: [Song] = []
            var offset = 0
            let batchSize = 500
            while true {
                let batch = try await SubsonicClient.shared.search3(server: server, query: "", songCount: batchSize, songOffset: offset)
                let songs = batch.song ?? []
                if songs.isEmpty { break }
                allSongs.append(contentsOf: songs)
                offset += songs.count
                await MainActor.run {
                    libraryDownloadProgress = "Found \(allSongs.count) songs..."
                }
                if songs.count < batchSize { break }
            }

            if allSongs.isEmpty {
                await MainActor.run {
                    isDownloadingLibrary = false
                    libraryDownloadProgress = nil
                    ToastManager.shared.show("No songs found", icon: "xmark.circle")
                }
                return
            }

            var exported = 0
            var failed = 0
            for song in allSongs {
                await MainActor.run {
                    libraryDownloadProgress = "Exporting \(exported + 1)/\(allSongs.count): \(song.title)"
                }
                do {
                    guard let url = DownloadManager.shared.buildExportURL(server: server, id: song.id) else { continue }
                    let (data, _) = try await URLSession.shared.data(from: url)
                    let ext = song.suffix ?? "mp3"
                    let artist = song.artist ?? "Unknown Artist"
                    // Sanitize filename
                    let safeName = "\(artist) - \(song.title)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    let fileName = "\(safeName).\(ext)"
                    let destURL = folderURL.appendingPathComponent(fileName)
                    try data.write(to: destURL)
                    exported += 1
                } catch {
                    failed += 1
                    AppLogger.shared.log("❌ Export failed for \(song.title): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                isDownloadingLibrary = false
                libraryDownloadProgress = nil
                if failed == 0 {
                    ToastManager.shared.show("Exported \(exported) songs!", icon: "checkmark.circle.fill")
                } else {
                    ToastManager.shared.show("Exported \(exported), \(failed) failed", icon: "exclamationmark.triangle")
                }
            }
        } catch {
            AppLogger.shared.log("Export All failed: \(error.localizedDescription)")
            await MainActor.run {
                isDownloadingLibrary = false
                libraryDownloadProgress = nil
                ToastManager.shared.show("Export failed", icon: "xmark.circle")
            }
        }
    }

    private func quickScan() async {
        guard let server = serverManager.currentServer else { return }
        isScanning = true
        do {
            let status = try await SubsonicClient.shared.startScan(server: server)
            await MainActor.run { scanStatus = status }
            await pollScanStatus()
        } catch {
            AppLogger.shared.log("❌ Quick scan failed: \(error.localizedDescription)")
            await MainActor.run { isScanning = false }
        }
    }

    private func fullScan() async {
        guard let server = serverManager.currentServer else { return }
        isScanning = true
        do {
            try await SubsonicClient.shared.startFullScan(server: server)
            await pollScanStatus()
        } catch {
            AppLogger.shared.log("❌ Full scan failed: \(error.localizedDescription)")
            await MainActor.run { isScanning = false }
        }
    }

    private func pollScanStatus() async {
        guard let server = serverManager.currentServer else { return }
        for _ in 0..<120 { // Poll up to 2 minutes
            try? await Task.sleep(for: .seconds(1))
            do {
                let status = try await SubsonicClient.shared.getScanStatus(server: server)
                await MainActor.run {
                    scanStatus = status
                    isScanning = status.scanning
                }
                if !status.scanning {
                    // Refresh stats after scan
                    await loadServerStats()
                    return
                }
            } catch {
                AppLogger.shared.log("❌ Scan status poll failed: \(error.localizedDescription)")
                break
            }
        }
        await MainActor.run { isScanning = false }
    }
}

