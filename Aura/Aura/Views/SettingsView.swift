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

    // Last.fm config drafts — edits stay local until the Save button validates them.
    @State private var lfUser = ""
    @State private var lfKey = ""
    @State private var lfDraftLoaded = false
    @State private var lfValidating = false
    @State private var lfResult: LastfmValidation?

    enum LastfmValidation: Equatable {
        case ok(username: String, scrobbles: Int?)
        case failed(String)
    }

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
            // Same card colour as the grouped sections below (white in light), not a
            // material — a material over the grey page just reads as more grey.
            .background(Color.themeGroupedBg)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var settingsListContent: some View {
        List {
            // Title aligned to the grouped content inset (no extra padding) so it lines up
            // with the cards/tiles below and matches the other tabs' left edge.
            Text("settings")
                .auraDisplay(40)
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
                serversSection
                homeCustomiseSection
                lyricsSection
                playbackSection
                equalizerSection
                lastfmSection
                wrappedSection
            }
            Group {
                downloadsSection
                storageCacheSection
            }
            Group {
                musicFolderSection
                libraryScanSection
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
                versionFooter
            }
        }
        .listSectionSpacing(.compact)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        // Reserve room for the floating mini-player so the bottom version footer isn't
        // hidden behind it (matches LibraryView's convention).
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 80) }
        // Grouped-list page: grey in light so the white section cards stand out.
        .background(Color.themeGroupedPageBg)
        .id("\(appSettings.appAccentColor.rawValue)-\(appSettings.activeTheme.rawValue)") // Force full re-render on accent/theme change
        .sheet(isPresented: $showEqualizer) {
            EqualizerView()
                .presentationDetents([.large])
        }
    }

    // MARK: - Sections

    /// One consolidated section: every server, the active one clearly marked with
    /// its live status (and tappable to open its details), the others tappable to
    /// switch. Swipe to remove, and an "Add Server" button.
    private var serversSection: some View {
        Section {
            ForEach(serverManager.servers) { server in
                if server.id == serverManager.currentServer?.id {
                    NavigationLink { ServerDetailView(server: server) } label: {
                        serverRow(server, isActive: true)
                    }
                } else {
                    Button {
                        serverManager.selectServer(server)
                        Task { await serverManager.testConnection() }
                    } label: {
                        serverRow(server, isActive: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDelete { idx in
                for i in idx.sorted().reversed() {
                    serverManager.removeServer(serverManager.servers[i])
                }
            }

            Button { showAddServer = true } label: {
                Label("Add Server", systemImage: "plus.circle.fill")
                    .foregroundStyle(accentColor)
            }
        } header: {
            Text("Servers")
        } footer: {
            Text(serverManager.servers.count > 1
                 ? "Tap another server to switch to it. Swipe left to remove."
                 : "Add another server to switch between libraries — you can also switch straight from the Home title.")
        }
    }

    private func serverRow(_ server: ServerConfig, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            // Unselected rows read as an empty radio button, not a server glyph: these
            // rows are a single-choice list, so the control should say "pick me".
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isActive ? accentColor : .secondary.opacity(0.5))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.friendlyName).font(.subheadline.weight(.medium))
                Text(server.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isActive {
                Text(serverManager.isConnected ? "Online" : "Offline")
                    .font(.subheadline)
                    .foregroundStyle(serverManager.isConnected ? .green : .red)
            }
        }
        .contentShape(Rectangle())
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

    // Both fields are needed: the API key identifies the app to Last.fm, the username
    // says whose scrobbles to read. Neither substitutes for the other.
    private var lastfmDirty: Bool {
        lfUser.trimmingCharacters(in: .whitespaces) != appSettings.lastfmUsername.trimmingCharacters(in: .whitespaces)
        || lfKey != appSettings.lastfmApiKey
    }
    private var lastfmCanSave: Bool {
        !lfUser.trimmingCharacters(in: .whitespaces).isEmpty && !lfKey.isEmpty && lastfmDirty && !lfValidating
    }

    private var lastfmSection: some View {
        Section {
            HStack {
                Text("Username")
                Spacer()
                TextField("Last.fm username", text: $lfUser)
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
                TextField("API key", text: $lfKey)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            // Save = validate against Last.fm, then persist only on success.
            Button {
                Task { await saveLastfm() }
            } label: {
                HStack {
                    if lfValidating {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else {
                        Image(systemName: "checkmark.circle")
                        Text(appSettings.lastfmConfigured && !lastfmDirty ? "Saved" : "Save & Connect")
                    }
                    Spacer()
                }
                .foregroundStyle(lastfmCanSave ? accentColor : .secondary)
            }
            .disabled(!lastfmCanSave)

            // Result of the last Save attempt / current connection state.
            switch lfResult {
            case .ok(let name, let scrobbles):
                Label {
                    if let scrobbles {
                        Text("Connected as \(name) · \(scrobbles) scrobbles")
                    } else {
                        Text("Connected as \(name)")
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                }
                .font(.caption)
                .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                if appSettings.lastfmConfigured {
                    Label("Connected — powers your Wrapped", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Last.fm")
        } footer: {
            Text("Both fields are required: the API key identifies the app, the username says whose scrobbles to read. Create a free API key at last.fm/api/account/create, then tap Save & Connect.")
        }
        .onAppear {
            // Seed the drafts from the saved values once, when the section first appears.
            guard !lfDraftLoaded else { return }
            lfUser = appSettings.lastfmUsername
            lfKey = appSettings.lastfmApiKey
            lfDraftLoaded = true
        }
    }

    // Wrapped's permanent home: reachable any time from here, independent of the Home
    // card. The card itself is opt-in (toggle) and, when on, only surfaces seasonally.
    private var wrappedSection: some View {
        Section {
            NavigationLink {
                WrappedView()
            } label: {
                Label("Open your Wrapped", systemImage: "sparkles")
            }
            Toggle(isOn: $appSettings.wrappedShowOnHome) {
                Label("Show on Home", systemImage: "house")
            }
        } header: {
            Text("Wrapped")
        } footer: {
            Text(appSettings.lastfmConfigured
                 ? "Your year & month in music, from your Last.fm scrobbles. When shown on Home, it appears around the end of each period."
                 : "Your year & month in music. Connect Last.fm above for full history, or it uses this device's play log. When shown on Home, it appears around the end of each period.")
        }
    }

    private func saveLastfm() async {
        lfValidating = true
        lfResult = nil
        defer { lfValidating = false }
        do {
            let account = try await LastfmService.shared.validate(username: lfUser, apiKey: lfKey)
            // Persist only after Last.fm confirms the pair works.
            appSettings.lastfmUsername = account.username
            appSettings.lastfmApiKey = lfKey
            appSettings.save()
            lfUser = account.username
            lfResult = .ok(username: account.username, scrobbles: account.scrobbles)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lfResult = .failed(message)
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
            Picker(selection: $appSettings.appearanceMode) {
                // Text, not Label: a Label renders its icon in the collapsed row too,
                // which crowds the value and squeezes the rows below.
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            } label: {
                Text("Theme")
            }

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

    /// Lyrics behaviour. Out of Dev/Beta: word highlighting and the fuller lyrics layout
    /// both ship, so their controls belong where everyone can reach them.
    private var lyricsSection: some View {
        Section {
            Toggle("Word-by-Word Highlight", isOn: $appSettings.betaKaraokeLyrics)
            Picker("Font", selection: $appSettings.lyricsFont) {
                // Each row set in the face it selects. A list of names would make the
                // choice blind, and these differ in ways no name conveys.
                ForEach(LyricsFont.selectable) { face in
                    Text(face.label).font(face.font(size: 17)).tag(face)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Timing")
                    Spacer()
                    Text(String(format: "%+.0f ms", appSettings.lyricsOffset * 1000))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $appSettings.lyricsOffset, in: -0.6...0.6, step: 0.025)
                Text("Positive shows the words earlier. Bluetooth headphones usually need a nudge.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Lyrics")
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
                    // Must close the cover itself: the default `onComplete` is a no-op, so
                    // replaying the onboarding used to trap the user inside it with no way
                    // out — even after a successful connection.
                    OnboardingView { showOnboarding = false }
                        .environment(serverManager)
                }
                // Hidden from the UI on purpose — the feature and its stored setting are
                // intact, it just isn't offered yet. Uncomment to bring it back.
                // Toggle("Hide Player Options", isOn: $appSettings.alphaAutoHideToolbar)
                Picker("Display Font", selection: $appSettings.displayFont) {
                    // Each row is drawn in the face it selects — a list of names would
                    // make the choice blind.
                    ForEach(DisplayFont.selectable) { face in
                        Text(face.label)
                            .font(face.postScriptName.map { .custom($0, size: 17) } ?? .body)
                            .tag(face)
                    }
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
            NavigationLink("About Aura") {
                AboutView()
            }
        }
    }

    /// Bottom-of-page version footer — the app's "signature" line, replacing the old
    /// App Version row and GitHub link (both moved into / removed from the About page).
    private var versionFooter: some View {
        Section {
            VStack(spacing: 4) {
                Text("aura")
                    .font(AppTypography.display(20, relativeTo: .headline))
                    .foregroundStyle(.secondary)
                Text("Version \(Self.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("© 2026 · Crafted with care in Italy")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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
            // (Removed the old 80pt clear spacer section — the List's bottom
            // safeAreaInset now reserves the mini-player room, and that spacer was
            // shoving the version footer far below Log Out.)
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

