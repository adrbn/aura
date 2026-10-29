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

    /// "1.0.0 · build 181": the version the App Store shows, then the build — the number of
    /// commits it was made from (scripts/set-build-number.sh), so it grows with the work.
    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return version }
        return String(localized: "\(version) · build \(build)")
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
    /// What clearing the cache would actually cost, measured when the button is pressed
    /// rather than guessed at in the warning's wording.
    @State private var pendingCacheClear: CacheAudit?
    @State private var isDownloadingLibrary = false
    @State private var libraryDownloadProgress: String?
    @State private var showFolderPicker = false

    // Last.fm config drafts — edits stay local until the Save button validates them.
    @State private var lfUser = ""
    @State private var lfKey = ""
    @State private var lfDraftLoaded = false
    @State private var lfEditing = false
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
                // Grouped-list page: grey in light so the white section cards stand out.
                .tabRootGlass(scrollY: $scrollY, page: .themeGroupedPageBg)
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
                    if appSettings.offlineMode {
                        serverManager.goBackOnline()
                    } else {
                        serverManager.goOfflineManually()
                    }
                }

                quickTile(icon: "arrow.triangle.2.circlepath", label: "Scan", color: .mint) {
                    Task { await quickScan() }
                }

                quickTile(icon: "xmark.bin.fill", label: "Clear Cache", color: .red) {
                    pendingCacheClear = CacheAudit.measure()
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private func quickTile(icon: String, label: LocalizedStringKey, color: Color, action: @escaping () -> Void) -> some View {
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
                madeForYouSection
                wrappedSection
                radarSection
            }
            // The system's grouped rows are the canvas's own shade in dark mode; lift them.
            .listRowBackground(Color.themeGroupedBg)
            Group {
                downloadsSection
                storageCacheSection
            }
            .listRowBackground(Color.themeGroupedBg)
            Group {
                musicFolderSection
                libraryScanSection
            }
            .listRowBackground(Color.themeGroupedBg)
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
            .listRowBackground(Color.themeGroupedBg)
            versionFooter
        }
        .listSectionSpacing(.compact)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        // Reserve room for the floating mini-player so the bottom version footer isn't
        // hidden behind it (matches LibraryView's convention).
        .safeAreaInset(edge: .bottom) { ListEndSpacer() }
        // The page is painted by `tabRootGlass`, under its glow — see `body`.
        // Rebuilt on a theme change. Not on an accent change: the accent reaches every row
        // through the environment, and a rebuild would close the colour picker the moment
        // it first sets a custom colour.
        .id(appSettings.activeTheme.rawValue)
        .sheet(isPresented: $showEqualizer) {
            EqualizerView()
                .presentationDetents([.large])
        }
        .confirmsCacheClear($pendingCacheClear, isClearing: $isClearingCache)
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
                // Navidrome takes `musicFolderId` several times, so any subset of folders
                // can be shown at once. No tick, or every tick, means no filter at all.
                folderRow(String(localized: "All Folders"), selected: appSettings.selectedMusicFolderIds.isEmpty) {
                    appSettings.selectedMusicFolderIds = []
                }
                ForEach(musicFolders) { folder in
                    folderRow(folder.name ?? String(localized: "Folder \(folder.id)"),
                              selected: appSettings.selectedMusicFolderIds.contains(folder.id)) {
                        toggleMusicFolder(folder.id)
                    }
                }
            } header: {
                Text("Music Folders")
            } footer: {
                if appSettings.selectedMusicFolderIds.isEmpty {
                    Text("Every folder on the server is shown.")
                } else {
                    Text("Only the ticked folders are shown across the app.")
                }
            }
        }
    }

    private func folderRow(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleMusicFolder(_ id: Int) {
        var ids = appSettings.selectedMusicFolderIds
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        // Every folder ticked is the same as no filter, and reads as "All Folders".
        appSettings.selectedMusicFolderIds = ids.count == musicFolders.count ? [] : ids
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
            if let made = MixGenerator.shared.generatedAt {
                LabeledContent {
                    Text("Updated \(made, format: Calendar.current.isDateInToday(made) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())")
                } label: {
                    Label("Made For You", systemImage: "sparkles")
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
                    Text(LocalizedStringKey(q.rawValue)).tag(q)
                }
            }

            Picker("On Cellular", selection: $appSettings.cellularQuality) {
                Text("Same as Wi-Fi").tag(StreamingQuality?.none)
                ForEach(StreamingQuality.allCases, id: \.self) { q in
                    Text(LocalizedStringKey(q.rawValue)).tag(StreamingQuality?.some(q))
                }
            }

            Toggle("Scrobble", isOn: $appSettings.scrobbleEnabled)

            if appSettings.scrobbleEnabled {
                // A choice, where there used to be a line of text: the share was displayed
                // but could not be changed, and songs were scrobbled after 30 seconds
                // whatever it said. It is measured on the playback position now, so a
                // pause does not count as listening.
                Picker("Scrobble After", selection: $appSettings.scrobbleThreshold) {
                    Text("50%").tag(0.5)
                    Text("75%").tag(0.75)
                    Text("90%").tag(0.9)
                }
            }

            Toggle("ReplayGain", isOn: $appSettings.replayGain)

            // No Gapless switch: the player always lines the next song up behind the
            // current one. Crossfade has no switch until it exists.

            Toggle("Landscape Clock", isOn: $appSettings.landscapeClockEnabled)

        } header: {
            Text("Playback")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if appSettings.streamingQuality == .lossless {
                    Text("Streams original files (FLAC/ALAC). Uses more data. Incompatible formats (OGG/Opus) are auto-transcoded.")
                } else {
                    Text("Lossless files will be transcoded to MP3 at \(appSettings.streamingQuality.bitRate ?? 320) kbps. Incompatible formats (OGG/Opus) are auto-transcoded.")
                }
                if appSettings.replayGain {
                    Text("ReplayGain turns loud tracks down to a common level, using the tags on your server. Quiet tracks are not boosted.")
                }
            }
        }
    }

    // Both are needed: the API key identifies the app to Last.fm, the username says whose
    // scrobbles to read. Editing an account keeps its saved key unless a new one is pasted.
    private var lfKeyToSave: String { lfKey.isEmpty ? appSettings.lastfmApiKey : lfKey }
    private var lastfmCanSave: Bool {
        !lfUser.trimmingCharacters(in: .whitespaces).isEmpty && !lfKeyToSave.isEmpty && !lfValidating
    }

    /// Connected and not being changed: one line saying so, instead of the form.
    private var lastfmShowsAccount: Bool { appSettings.lastfmConfigured && !lfEditing }

    private var lastfmSection: some View {
        Section {
            if lastfmShowsAccount {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appSettings.lastfmUsername)
                        if case .ok(_, let scrobbles?) = lfResult {
                            Text("\(scrobbles) scrobbles").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Connected — powers your Wrapped").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change") {
                        lfUser = appSettings.lastfmUsername
                        lfKey = ""
                        lfResult = nil
                        lfEditing = true
                    }
                    .foregroundStyle(accentColor)
                    .buttonStyle(.borderless)
                }
                Button("Disconnect", role: .destructive) {
                    appSettings.lastfmUsername = ""
                    appSettings.lastfmApiKey = ""
                    appSettings.save()
                    lfUser = ""
                    lfKey = ""
                    lfResult = nil
                }
            } else {
                TextField("Username", text: $lfUser)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                // Hidden as it's typed, like any key. Changing an account leaves it empty, and
                // the saved key is kept unless another is pasted.
                SecureField("API Key", text: $lfKey,
                            prompt: Text(appSettings.lastfmConfigured ? "Keep the saved key" : "API Key"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    Task { await saveLastfm() }
                } label: {
                    HStack {
                        if lfValidating {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        } else {
                            Text("Connect")
                        }
                        Spacer()
                    }
                    .foregroundStyle(lastfmCanSave ? accentColor : .secondary)
                }
                .disabled(!lastfmCanSave)

                if case .failed(let message) = lfResult {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if lfEditing {
                    Button("Cancel") { lfEditing = false; lfResult = nil }
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Last.fm")
        } footer: {
            if !lastfmShowsAccount {
                Text("Both fields are required: the API key identifies the app, the username says whose scrobbles to read. Create a free API key at last.fm/api/account/create.")
            }
        }
        .onAppear {
            guard !lfDraftLoaded else { return }
            lfUser = appSettings.lastfmUsername
            lfDraftLoaded = true
        }
    }

    private var madeForYouSection: some View {
        Section {
            NavigationLink {
                MadeForYouSettingsView()
            } label: {
                Label("Choose Your Mixes", systemImage: "sparkles")
            }
        } header: {
            Text("Made For You")
        } footer: {
            Text("Which mixes Home makes, from which genres, and how many songs each.")
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

    private var radarSection: some View {
        Section {
            Toggle(isOn: $appSettings.radarEnabled) {
                Label("Show Radar on Home", systemImage: "dot.radiowaves.left.and.right")
            }
            if let watched = RadarService.shared.watched {
                LabeledContent {
                    Text("\(watched.count)")
                } label: {
                    Label("Followed with SoulSync", systemImage: "arrow.down.circle")
                }
            }
            if !RadarService.shared.unfollowed.isEmpty {
                NavigationLink { UnfollowedArtistsView() } label: {
                    LabeledContent {
                        Text("\(RadarService.shared.unfollowed.count)")
                    } label: {
                        Label("Unfollowed Artists", systemImage: "person.crop.circle.badge.minus")
                    }
                }
            }
        } header: {
            Text("Release Radar")
        } footer: {
            if RadarService.shared.watched != nil {
                Text("The radar follows SoulSync's watchlist, and adds your favourite and most-played artists to it. SoulSync downloads their new releases by itself once a day; Get It fetches one at once.")
            } else {
                Text("New releases from the artists you play most, found in Deezer's public catalogue. Only artist names are sent.")
            }
        }
    }

    private func saveLastfm() async {
        lfValidating = true
        lfResult = nil
        defer { lfValidating = false }
        do {
            let key = lfKeyToSave
            let account = try await LastfmService.shared.validate(username: lfUser, apiKey: key)
            // Persist only after Last.fm confirms the pair works.
            appSettings.lastfmUsername = account.username
            appSettings.lastfmApiKey = key
            appSettings.save()
            lfUser = account.username
            lfKey = ""
            lfEditing = false
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
                    Text(LocalizedStringKey(appSettings.eqPreset.rawValue))
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
                    Text(LocalizedStringKey(q.rawValue)).tag(q)
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
                    pendingCacheClear = CacheAudit.measure()
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

        }
    }

    private var customiseSection: some View {
        Section("Appearance") {
            Picker(selection: $appSettings.appearanceMode) {
                // Text, not Label: a Label renders its icon in the collapsed row too,
                // which crowds the value and squeezes the rows below.
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                }
            } label: {
                Text("Theme")
            }

            // iOS owns the per-app language: its page switches every string at once,
            // where a locale forced from inside reached SwiftUI text and nothing else.
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                LabeledContent("Language",
                               value: Bundle.main.preferredLocalizations.first
                                   .flatMap { Locale.current.localizedString(forLanguageCode: $0) }?
                                   .localizedCapitalized ?? "")
            }
            .foregroundStyle(.primary)

            NavigationLink("Tab Bar Order") {
                TabOrderView()
            }

            AccentColourPicker(accent: $appSettings.appAccentColor,
                               customRGB: $appSettings.customAccentRGB)
        }
    }

    /// Lyrics behaviour. Out of Dev/Beta: word highlighting and the fuller lyrics layout
    /// both ship, so their controls belong where everyone can reach them.
    private var lyricsSection: some View {
        Section {
            NavigationLink {
                LyricsTranslationSettingsView()
            } label: {
                LabeledContent("Translation", value: GeminiLyricsTranslator.isConfigured ? "Gemini" : String(localized: "Off"))
            }
            Toggle("Word-by-Word Highlight", isOn: $appSettings.betaKaraokeLyrics)
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
            #if !APPSTORE_BUILD
            if appSettings.betaFeaturesEnabled {
                LyricsOnServerRows()
            }
            #endif
        } header: {
            Text("Lyrics")
        }
    }

    private var homeCustomiseSection: some View {
        Section("Home Screen") {
            Picker("Title", selection: $appSettings.homeTitleStyle) {
                ForEach(HomeTitleStyle.allCases, id: \.self) { style in
                    Text(LocalizedStringKey(style.rawValue)).tag(style)
                }
            }
            if appSettings.homeTitleStyle == .custom {
                TextField("Your title", text: $appSettings.homeCustomTitle)
                    .autocorrectionDisabled()
            }
            Toggle("Library Stats", isOn: $appSettings.showStatsOnHome)
            Toggle("Play Counts", isOn: $appSettings.showPlayCounts)
            NavigationLink("Section Order") {
                HomeSectionOrderView()
            }
        }
    }

    #if !APPSTORE_BUILD
    private var betaFeaturesSection: some View {
        Section {
            Toggle("Developer Options", isOn: $appSettings.betaFeaturesEnabled)
            if appSettings.betaFeaturesEnabled {
                NavigationLink {
                    DevLogsView()
                } label: {
                    Label("View Logs", systemImage: "doc.text.magnifyingglass")
                }
            }
        } header: {
            Label("Developer", systemImage: "hammer.fill")
        } footer: {
            Text("The logs, and what only this build has: Soulseek, Get It and lyrics saved to the server.")
        }
    }

    /// Searching comes first; where slskd runs and how to sign in to it sit one level down,
    /// set once and rarely seen again.
    private var externalServiceSection: some View {
        Section("Soulseek") {
            NavigationLink {
                ExternalServiceView()
            } label: {
                Label("Search Soulseek", systemImage: "magnifyingglass")
            }
            NavigationLink {
                slskdConnectionForm
            } label: {
                HStack {
                    Label("slskd Connection", systemImage: "server.rack")
                    Spacer()
                    Text(appSettings.externalServiceURL.isEmpty
                         ? String(localized: "Not set")
                         : "\(appSettings.externalServiceURL):\(appSettings.externalServicePort)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var slskdConnectionForm: some View {
        Form {
            Section {
                LabeledContent("Host") {
                    TextField("IP address", text: $appSettings.externalServiceURL)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Port") {
                    TextField("Port", value: $appSettings.externalServicePort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
            } header: {
                Text("Address")
            }
            Section {
                LabeledContent("Username") {
                    TextField("slskd", text: $appSettings.slskdUsername)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $appSettings.slskdPassword)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Sign-In")
            } footer: {
                Text("slskd's own web sign-in, not your Soulseek account.")
            }
        }
        .navigationTitle("slskd Connection")
        .navigationBarTitleDisplayMode(.inline)
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
            await MainActor.run {
                musicFolders = folders
                // A folder removed on the server would make Navidrome refuse every request.
                let known = Set(folders.map(\.id))
                let kept = appSettings.selectedMusicFolderIds.filter(known.contains)
                if kept != appSettings.selectedMusicFolderIds { appSettings.selectedMusicFolderIds = kept }
            }
        } catch {
            AppLogger.shared.log("❌ Failed to load music folders: \(error.localizedDescription)")
        }
    }

    private func downloadEntireLibrary() async {
        guard let server = serverManager.currentServer else { return }
        await downloadManager.downloadEntireLibrary(server: server, progress: showLibraryProgress)
    }

    private func exportEntireLibrary(to folderURL: URL) async {
        guard let server = serverManager.currentServer else { return }
        guard folderURL.startAccessingSecurityScopedResource() else {
            ToastManager.shared.show(String(localized: "Cannot access selected folder"), icon: "xmark.circle")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        await downloadManager.exportEntireLibrary(server: server, to: folderURL, progress: showLibraryProgress)
    }

    private func showLibraryProgress(_ progress: String?) {
        isDownloadingLibrary = progress != nil
        libraryDownloadProgress = progress
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

// MARK: - Clearing the cache

/// What clearing the cache would cost, counted rather than described.
///
/// Cache and downloads live in different folders and only one of them is being emptied,
/// but nothing on screen said so — "Clear Cache" next to a library someone spent a night
/// downloading is an alarming button with no way to find out what it does except press it.
struct CacheAudit: Equatable {
    let songs: Int
    let audioBytes: Int64
    let artworkBytes: Int64

    var totalBytes: Int64 { audioBytes + artworkBytes }

    static func measure() -> CacheAudit {
        CacheAudit(
            songs: AudioCacheManager.shared.getCachedSongs().count,
            audioBytes: AudioCacheManager.shared.currentCacheSizeBytes,
            artworkBytes: ArtworkCache.shared.currentCacheSizeBytes
        )
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var total: String { size(totalBytes) }

    /// Spelled out line by line, and ending on what is *not* at stake — which is the
    /// thing anyone pressing this button actually wants to know.
    var summary: String {
        var lines: [String] = []
        lines.append(songs == 1
            ? String(localized: "1 recently played song (\(size(audioBytes)))")
            : String(localized: "\(songs) recently played songs (\(size(audioBytes)))"))
        lines.append(String(localized: "Cover art (\(size(artworkBytes)))"))
        lines.append("")
        lines.append(String(localized: "Your downloads are not touched, and anything cleared is fetched again next time you play it."))
        return lines.joined(separator: "\n")
    }
}

extension View {
    /// Asks before emptying the cache, and says what that costs.
    func confirmsCacheClear(_ audit: Binding<CacheAudit?>, isClearing: Binding<Bool>) -> some View {
        alert("Clear cache?",
              isPresented: Binding(get: { audit.wrappedValue != nil },
                                   set: { if !$0 { audit.wrappedValue = nil } }),
              presenting: audit.wrappedValue) { _ in
            Button("Cancel", role: .cancel) { audit.wrappedValue = nil }
            Button("Clear", role: .destructive) {
                let freed = audit.wrappedValue?.total ?? ""
                audit.wrappedValue = nil
                isClearing.wrappedValue = true
                Task {
                    AudioCacheManager.shared.clearCache()
                    ArtworkCache.shared.clearAll()
                    URLCache.shared.removeAllCachedResponses()
                    try? await Task.sleep(for: .milliseconds(500))
                    isClearing.wrappedValue = false
                    ToastManager.shared.show(String(localized: "Cache cleared — \(freed) freed"), icon: "trash")
                }
            }
        } message: { audit in
            Text("This frees \(audit.total):\n\n\(audit.summary)")
        }
    }
}

#if !APPSTORE_BUILD
/// Lyrics timed by hand, written to the server through File Browser as well.
private struct LyricsOnServerRows: View {
    @AppStorage(LyricsOnServer.enabledKey) private var isOn = false
    @AppStorage(LyricsOnServer.addressKey) private var address = ""
    @AppStorage(LyricsOnServer.userKey) private var user = ""
    @State private var password = KeychainHelper.loadPassword(for: LyricsOnServer.passwordAccount) ?? ""

    @State private var showsSignIn = false
    /// The last Test Sign-In: nil while untested or under way, then whether it worked.
    @State private var testResult: Result<Void, Error>?
    @State private var isTesting = false

    var body: some View {
        Toggle("Save Synced Lyrics to the Server", isOn: $isOn)
        if isOn {
            // Navidrome only reads the music: the .lrc is written by File Browser, which runs
            // beside it. Its address and sign-in default to the server's, so there's nothing to
            // type when they match; the fields stay one tap away for when they don't.
            Text("Navidrome can't write files, so the lyrics go through File Browser on the same machine. Aura uses your server's address and sign-in unless you set others.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("File Browser Sign-In", isExpanded: $showsSignIn) {
                fields
            }
            .onAppear { showsSignIn = !address.isEmpty || !user.isEmpty }
        }
    }

    @ViewBuilder
    private var fields: some View {
        TextField("File Browser", text: $address, prompt: Text(LyricsOnServer.suggestedAddress))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        TextField("Username", text: $user, prompt: Text(ServerManager.shared.currentServer?.username ?? "Username"))
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField("Password", text: $password)
            .textContentType(.password)
            .onChange(of: password) { _, value in
                if value.isEmpty {
                    KeychainHelper.delete(for: LyricsOnServer.passwordAccount)
                } else {
                    KeychainHelper.save(password: value, for: LyricsOnServer.passwordAccount)
                }
            }
        Button {
            isTesting = true
            testResult = nil
            Task {
                do { try await LyricsOnServer.testSignIn(); testResult = .success(()) }
                catch { testResult = .failure(error) }
                isTesting = false
            }
        } label: {
            HStack {
                Text("Test Sign-In")
                Spacer()
                if isTesting { ProgressView() }
            }
        }
        .disabled(isTesting)
        switch testResult {
        case .success:
            Label("File Browser accepted the sign-in.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }
}
#endif
