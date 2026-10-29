import SwiftUI

/// Whether the settings panel is up, over the window.
@MainActor @Observable final class MacSettingsPanel {
    static let shared = MacSettingsPanel()
    var isShown = false
}

/// Settings (⌘, or the sidebar's gear): a panel over the window, which dims and blurs
/// behind it, rather than a second window to find and close. Sections down the side, the
/// way the window keeps its library.
struct MacSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    enum Pane: String, CaseIterable, Identifiable {
        case playback, lyrics, library, home, downloads, madeForYou, lastfm, radar, appearance, translation, developer, about
        var id: String { rawValue }
        /// Developer is the sideload build's: Get It, Soulseek and the logs.
        static var shown: [Pane] {
            #if APPSTORE_BUILD
            allCases.filter { $0 != .developer }
            #else
            allCases
            #endif
        }
        var title: LocalizedStringKey {
            switch self {
            case .playback: "Playback"
            case .lyrics: "Lyrics"
            case .library: "Library"
            case .home: "Home"
            case .downloads: "Downloads"
            case .madeForYou: "Made For You"
            case .lastfm: "Last.fm"
            case .radar: "Release Radar"
            case .appearance: "Appearance"
            case .translation: "Lyrics Translation"
            case .developer: "Developer"
            case .about: "About"
            }
        }
        var symbol: String {
            switch self {
            case .playback: "play.fill"
            case .lyrics: "quote.bubble.fill"
            case .library: "music.note.house.fill"
            case .home: "house.fill"
            case .downloads: "arrow.down.circle.fill"
            case .madeForYou: "sparkles"
            case .lastfm: "waveform"
            case .radar: "dot.radiowaves.left.and.right"
            case .appearance: "paintpalette.fill"
            case .translation: "translate"
            case .developer: "hammer.fill"
            case .about: "info.circle.fill"
            }
        }
    }

    @State private var pane: Pane = .playback
    @State private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.primary.opacity(0.06)).frame(width: 1)
            content
        }
        .frame(width: 760, height: 560)
        .background(MacBackground(grid: false))
        .overlay(alignment: .topTrailing) {
            Button { MacSettingsPanel.shared.isShown = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        .tint(Color.appAccent)
        .onChange(of: fingerprint) { settings.save() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").auraDisplay(30)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            ForEach(Pane.shown) { item in
                Button { pane = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(pane == item ? .black : Color.appAccent)
                            .frame(width: 24, height: 24)
                            .background(pane == item ? Color.appAccent : Color.appAccent.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 6))
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(pane == item ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/adrbn")!) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Color.appAccent, in: RoundedRectangle(cornerRadius: 6))
                    Text("Support Aura").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ko-fi")
            .padding(.bottom, 16)
        }
        .padding(.top, 24)
        .padding(.horizontal, 12)
        .frame(width: 230)
        // A shade darker than the pane beside it, so the two read as sidebar and page.
        .background(.primary.opacity(scheme == .dark ? 0.22 : 0.04))
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .translation:
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title).auraDisplay(40)
                    .padding(.horizontal, 32)
                    .padding(.top, 34)
                LyricsTranslationSettingsView()
                    .scrollContentBackground(.hidden)
            }
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(pane.title).auraDisplay(40)
                    switch pane {
                    case .playback: MacPlaybackSettings()
                    case .lyrics: MacLyricsSettings()
                    case .library: MacLibrarySettings()
                    case .home: MacHomeSettings()
                    case .downloads: MacDownloadsSettings()
                    case .madeForYou: MacMadeForYouSettings()
                    case .lastfm: MacLastfmSettings()
                    case .radar: MacRadarSettings()
                    case .about: MacAboutSettings()
                    case .developer: MacDeveloperSettings()
                    default: MacAppearanceSettings()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 34)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(pane)
        }
    }

    /// Any setting changed, so one `onChange` saves them all.
    private var fingerprint: String {
        [settings.streamingQuality.rawValue, String(settings.replayGain), String(settings.scrobbleEnabled),
         String(settings.scrobbleThreshold), String(settings.betaKaraokeLyrics), String(settings.lyricsOffset),
         settings.appAccentColor.rawValue, settings.appearanceMode.rawValue, String(settings.betaFeaturesEnabled),
         settings.externalServiceURL, String(settings.externalServicePort), settings.slskdUsername,
         settings.slskdPassword, settings.downloadQuality.rawValue, String(settings.cacheEnabled),
         String(settings.cacheMaxSize), String(settings.radarEnabled), settings.homeTitleStyle.rawValue,
         settings.homeCustomTitle, String(settings.showStatsOnHome),
         settings.homeSectionOrder.map(\.rawValue).joined(separator: ",")].joined(separator: "|")
    }
}

// MARK: Pieces

/// A group of rows on a faint card, like the phone's grouped settings but in the window's dark.
private struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var last = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !last { Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).padding(.leading, 14) }
        }
    }
}

/// A choice among a few, as chips: the picked one filled with the accent.
private struct Chips<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .black : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(on ? Color.appAccent : Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

// MARK: Panes

private struct MacPlaybackSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard(title: "Streaming Quality") {
            ForEach(StreamingQuality.allCases, id: \.self) { quality in
                Button { settings.streamingQuality = quality } label: {
                    SettingsRow(title: LocalizedStringKey(quality.rawValue), last: quality == StreamingQuality.allCases.last) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.appAccent)
                            .opacity(settings.streamingQuality == quality ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        SettingsCard(title: "Sound") {
            SettingsRow(title: "ReplayGain", detail: "Every song at the same loudness", last: true) {
                Toggle("", isOn: $settings.replayGain).toggleStyle(.switch).labelsHidden()
            }
        }
        SettingsCard(title: "Scrobble") {
            SettingsRow(title: "Scrobble", last: !settings.scrobbleEnabled) {
                Toggle("", isOn: $settings.scrobbleEnabled).toggleStyle(.switch).labelsHidden()
            }
            if settings.scrobbleEnabled {
                SettingsRow(title: "Scrobble After", last: true) {
                    Chips(options: [0.5, 0.75, 0.9], selection: $settings.scrobbleThreshold) { "\(Int($0 * 100))%" }
                }
            }
        }
    }
}

private struct MacLyricsSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Word-by-Word Lyrics") {
                Toggle("", isOn: $settings.betaKaraokeLyrics).toggleStyle(.switch).labelsHidden()
            }
            SettingsRow(title: "Lyrics Timing", last: true) {
                HStack(spacing: 10) {
                    step(-0.1, "minus")
                    Text(settings.lyricsOffset == 0 ? String(localized: "In sync") : String(format: "%+.1f s", settings.lyricsOffset))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(minWidth: 64)
                    step(0.1, "plus")
                }
            }
        }
        #if !APPSTORE_BUILD
        if settings.betaFeaturesEnabled { MacLyricsOnServerSettings() }
        #endif
    }

    private func step(_ by: Double, _ symbol: String) -> some View {
        Button {
            settings.lyricsOffset = min(2, max(-2, ((settings.lyricsOffset + by) * 10).rounded() / 10))
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(.primary.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct MacLibrarySettings: View {
    @State private var settings = AppSettings.shared
    @State private var folders: [MusicFolder] = []
    @State private var scanning = false
    @State private var scanned: Int?

    var body: some View {
        Group {
            if folders.count > 1 {
                SettingsCard(title: "Music Folders") {
                    ForEach(folders) { folder in
                        SettingsRow(title: LocalizedStringKey(folder.name ?? String(localized: "Folder \(folder.id)")),
                                    last: folder.id == folders.last?.id) {
                            Toggle("", isOn: Binding(
                                get: { settings.selectedMusicFolderIds.isEmpty || settings.selectedMusicFolderIds.contains(folder.id) },
                                set: { toggle(folder.id, on: $0) }))
                            .toggleStyle(.switch).labelsHidden()
                        }
                    }
                }
            }
            SettingsCard(title: "Wrapped", footer: settings.lastfmConfigured
                         ? "Your year & month in music, from your Last.fm scrobbles. When shown on Home, it appears around the end of each period."
                         : "Your year & month in music. Connect Last.fm above for full history, or it uses this device's play log. When shown on Home, it appears around the end of each period.") {
                SettingsRow(title: "Show on Home", last: true) {
                    Toggle("", isOn: $settings.wrappedShowOnHome).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsCard(title: "Library Scan") {
                SettingsRow(title: scanning ? "Scanning…" : "Library Scan",
                            detail: scanned.map { "\($0) items scanned" }, last: true) {
                    HStack(spacing: 8) {
                        if scanning { ProgressView().controlSize(.small) }
                        Button("Quick Scan") { Task { await scan(full: false) } }
                        Button("Full Scan") { Task { await scan(full: true) } }
                    }
                    .disabled(scanning)
                }
            }
        }
        .task {
            guard let server = ServerManager.shared.currentServer else { return }
            folders = (try? await SubsonicClient.shared.getMusicFolders(server: server)) ?? []
        }
    }

    private func toggle(_ id: Int, on: Bool) {
        var ids = settings.selectedMusicFolderIds.isEmpty ? folders.map(\.id) : settings.selectedMusicFolderIds
        if on { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        guard !ids.isEmpty else { return }
        // Every folder ticked is no filter at all.
        settings.selectedMusicFolderIds = ids.count == folders.count ? [] : ids
        settings.save()
        // Another set of folders is another library to search.
        LibraryIndex.shared.refreshIfNeeded()
    }

    private func scan(full: Bool) async {
        guard let server = ServerManager.shared.currentServer else { return }
        scanning = true
        defer { scanning = false; scanned = nil }
        do {
            if full { try await SubsonicClient.shared.startFullScan(server: server) }
            else { _ = try await SubsonicClient.shared.startScan(server: server) }
            for _ in 0..<600 {
                try await Task.sleep(for: .seconds(1))
                let status = try await SubsonicClient.shared.getScanStatus(server: server)
                scanned = status.count
                if !status.scanning { break }
            }
            LibraryIndex.shared.refreshIfNeeded()
        } catch {
            AppLogger.shared.log("❌ Scan failed: \(error.localizedDescription)")
        }
    }
}

/// The phone's Home Screen settings, the same fields, so Home reads alike on both.
private struct MacHomeSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard(title: "Home Screen") {
            SettingsRow(title: "Title") {
                Chips(options: HomeTitleStyle.allCases, selection: $settings.homeTitleStyle) {
                    String(localized: String.LocalizationValue($0.rawValue))
                }
            }
            if settings.homeTitleStyle == .custom {
                SettingsRow(title: "Your title") {
                    TextField("Your title", text: $settings.homeCustomTitle)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            SettingsRow(title: "Library Stats", last: true) {
                Toggle("", isOn: $settings.showStatsOnHome).toggleStyle(.switch).labelsHidden()
            }
        }
        SettingsCard(title: "Section Order", footer: "Drag to reorder home sections") {
            List {
                ForEach(settings.homeSectionOrder) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.icon).foregroundStyle(Color.appAccent).frame(width: 20)
                        Text(LocalizedStringKey(section.rawValue)).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
                .onMove { settings.homeSectionOrder.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(settings.homeSectionOrder.count) * 32 + 8)
            .padding(.horizontal, 4)
            Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
            Button("Reset to Default") { settings.homeSectionOrder = HomeSection.defaultOrder }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }
}

private struct MacAppearanceSettings: View {
    @State private var settings = AppSettings.shared
    @State private var preferences = MacPreferences.shared

    var body: some View {
        SettingsCard(title: "Accent") {
            HStack(spacing: 10) {
                ForEach(AppAccentColor.presets, id: \.self) { colour in
                    let on = settings.appAccentColor == colour
                    Button { settings.appAccentColor = colour } label: {
                        Circle().fill(colour.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: on ? 2.5 : 0).padding(-4))
                            .padding(4)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey(colour.rawValue))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .animation(.snappy(duration: 0.2), value: settings.appAccentColor)
        }
        SettingsCard(title: "Appearance") {
            SettingsRow(title: "Theme") {
                Chips(options: AppearanceMode.allCases, selection: $settings.appearanceMode) {
                    String(localized: String.LocalizationValue($0.rawValue))
                }
            }
            SettingsRow(title: "Cover Size", last: true) {
                Chips(options: MacCoverSize.allCases, selection: $preferences.coverSize) { $0.label }
            }
        }
    }
}

/// Get It and Soulseek: the switch, and where slskd runs. The sign-in is slskd's own.
private struct MacDeveloperSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Developer Options", detail: "Get It on the radar, Soulseek and lyrics saved to the server",
                        last: true) {
                Toggle("", isOn: $settings.betaFeaturesEnabled).toggleStyle(.switch).labelsHidden()
            }
        }
        SettingsCard(title: "slskd Connection") {
            SettingsRow(title: "Host") {
                TextField("IP address", text: $settings.externalServiceURL)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            SettingsRow(title: "Port") {
                TextField("Port", value: $settings.externalServicePort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 90)
            }
            SettingsRow(title: "Username") {
                TextField("slskd", text: $settings.slskdUsername)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            SettingsRow(title: "Password", detail: "slskd's own web sign-in, not your Soulseek account.", last: true) {
                SecureField("Password", text: $settings.slskdPassword)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
        }
        if settings.betaFeaturesEnabled { MacLogsCard() }
    }
}

/// The app's log, newest first, to copy into a bug report.
private struct MacLogsCard: View {
    @State private var logger = AppLogger.shared

    var body: some View {
        SettingsCard(title: "View Logs") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if logger.entries.isEmpty {
                        Text("No logs yet").foregroundStyle(.secondary)
                    }
                    ForEach(logger.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(entry.message).font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(height: 240)
            Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
            HStack {
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logger.exportText(), forType: .string)
                    ToastManager.shared.show(String(localized: "Logs copied"), icon: "doc.on.doc")
                }
                Spacer()
                Button("Clear Logs", role: .destructive) { logger.clear() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

#if !APPSTORE_BUILD
/// Lyrics timed by hand, written to the server through File Browser as well — the phone's
/// rows, laid out as the panel's cards.
private struct MacLyricsOnServerSettings: View {
    @AppStorage(LyricsOnServer.enabledKey) private var isOn = false
    @AppStorage(LyricsOnServer.addressKey) private var address = ""
    @AppStorage(LyricsOnServer.userKey) private var user = ""
    @State private var password = KeychainHelper.loadPassword(for: LyricsOnServer.passwordAccount) ?? ""
    /// The last Test Sign-In: nil while untested or under way, then whether it worked.
    @State private var testResult: Result<Void, Error>?
    @State private var isTesting = false

    var body: some View {
        SettingsCard(footer: isOn ? "Navidrome can't write files, so the lyrics go through File Browser on the same machine. Aura uses your server's address and sign-in unless you set others." : nil) {
            SettingsRow(title: "Save Synced Lyrics to the Server", last: true) {
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
            }
        }
        if isOn {
            SettingsCard(title: "File Browser Sign-In") {
                SettingsRow(title: "File Browser") {
                    TextField("File Browser", text: $address, prompt: Text(LyricsOnServer.suggestedAddress))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                SettingsRow(title: "Username") {
                    TextField("Username", text: $user,
                              prompt: Text(ServerManager.shared.currentServer?.username ?? String(localized: "Username")))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                SettingsRow(title: "Password") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                        .onChange(of: password) { _, value in
                            if value.isEmpty {
                                KeychainHelper.delete(for: LyricsOnServer.passwordAccount)
                            } else {
                                KeychainHelper.save(password: value, for: LyricsOnServer.passwordAccount)
                            }
                        }
                }
                SettingsRow(title: "Test Sign-In", last: true) {
                    HStack(spacing: 8) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Button("Test Sign-In") {
                            isTesting = true
                            testResult = nil
                            Task {
                                do { try await LyricsOnServer.testSignIn(); testResult = .success(()) }
                                catch { testResult = .failure(error) }
                                isTesting = false
                            }
                        }
                        .disabled(isTesting)
                    }
                }
            }
            switch testResult {
            case .success:
                Label("File Browser accepted the sign-in.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        }
    }
}
#endif

/// Songs kept on this Mac, and the cache of the ones only streamed.
private struct MacDownloadsSettings: View {
    @State private var settings = AppSettings.shared
    @State private var downloads = DownloadManager.shared
    @State private var confirmsDelete = false
    @State private var cacheSize = AudioCacheManager.shared.currentCacheSizeFormatted
    /// What clearing would free and what that is, counted when the button is pressed.
    @State private var clearCost: (total: String, summary: String)?

    var body: some View {
        SettingsCard(title: "Downloads") {
            SettingsRow(title: "Download Quality") {
                Picker("", selection: $settings.downloadQuality) {
                    ForEach(DownloadQuality.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(title: "Downloaded Songs") {
                Text("\(downloads.downloadedSongs.count)").foregroundStyle(.secondary)
            }
            SettingsRow(title: "Storage Used", last: downloads.downloadedSongs.isEmpty) {
                Text(downloads.totalDownloadSize).foregroundStyle(.secondary)
            }
            if !downloads.downloadedSongs.isEmpty {
                SettingsRow(title: "Delete All Downloads", last: true) {
                    Button("Delete All", role: .destructive) { confirmsDelete = true }
                }
            }
        }
        .confirmationDialog("Delete All Downloads?", isPresented: $confirmsDelete) {
            Button("Delete All", role: .destructive) { downloads.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all \(downloads.downloadedSongs.count) downloaded songs from your device.")
        }
        SettingsCard(title: "Storage & Cache") {
            SettingsRow(title: "Cache Enabled", last: !settings.cacheEnabled) {
                Toggle("", isOn: $settings.cacheEnabled).toggleStyle(.switch).labelsHidden()
            }
            if settings.cacheEnabled {
                SettingsRow(title: "Max Cache: \(String(format: "%.1f", Double(settings.cacheMaxSize) / 1024.0)) GB") {
                    Stepper("", value: $settings.cacheMaxSize, in: 512...8192, step: 512).labelsHidden()
                }
                SettingsRow(title: "Audio Cache") {
                    Text(cacheSize).foregroundStyle(.secondary)
                }
                SettingsRow(title: "Clear Cache", last: true) {
                    Button("Clear", role: .destructive) { clearCost = measure() }
                }
            }
        }
        .alert("Clear cache?", isPresented: Binding(get: { clearCost != nil }, set: { if !$0 { clearCost = nil } }),
               presenting: clearCost) { cost in
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                AudioCacheManager.shared.clearCache()
                ArtworkCache.shared.clearAll()
                URLCache.shared.removeAllCachedResponses()
                cacheSize = AudioCacheManager.shared.currentCacheSizeFormatted
                ToastManager.shared.show(String(localized: "Cache cleared — \(cost.total) freed"), icon: "trash")
            }
        } message: { cost in
            Text("This frees \(cost.total):\n\n\(cost.summary)")
        }
    }

    /// The phone's wording, line for line: what goes, then what doesn't.
    private func measure() -> (total: String, summary: String) {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let songs = AudioCacheManager.shared.getCachedSongs().count
        let audio = AudioCacheManager.shared.currentCacheSizeBytes
        let artwork = ArtworkCache.shared.currentCacheSizeBytes
        let lines = [
            songs == 1 ? String(localized: "1 recently played song (\(size(audio)))")
                       : String(localized: "\(songs) recently played songs (\(size(audio)))"),
            String(localized: "Cover art (\(size(artwork)))"),
            "",
            String(localized: "Your downloads are not touched, and anything cleared is fetched again next time you play it.")
        ]
        return (size(audio + artwork), lines.joined(separator: "\n"))
    }
}

/// Which mixes Home makes, from which genres, and how long they run. Leaving the pane
/// rebuilds them if anything changed.
private struct MacMadeForYouSettings: View {
    @AppStorage(MixPreferences.timeOfDayKey) private var timeOfDay = true
    @AppStorage(MixPreferences.genreMixesKey) private var genreMixes = true
    @AppStorage(MixPreferences.discoverKey) private var discover = true
    @AppStorage(MixPreferences.genresKey) private var genresRaw = ""
    @AppStorage(MixPreferences.lengthKey) private var length = 50
    @AppStorage(MixPreferences.moodKey(.chill)) private var chill = true
    @AppStorage(MixPreferences.moodKey(.focus)) private var focus = true
    @AppStorage(MixPreferences.moodKey(.feelGood)) private var feelGood = true
    @AppStorage(MixPreferences.moodKey(.energy)) private var energy = true
    @State private var serverGenres: [GenreEntry] = []
    @State private var signatureOnAppear = ""
    @State private var generator = MixGenerator.shared

    private var pickedGenres: [String] { genresRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        SettingsCard(title: "Mixes", footer: "The time of day mix follows the hour: morning, afternoon, evening or late night.") {
            SettingsRow(title: "Time of Day Mix") { toggle($timeOfDay) }
            ForEach(MixGenerator.Mood.allCases, id: \.self) { mood in
                SettingsRow(title: LocalizedStringKey(mood.title)) { toggle(moodBinding(mood)) }
            }
            SettingsRow(title: "Genre Mixes") { toggle($genreMixes) }
            SettingsRow(title: "New Discoveries", last: true) { toggle($discover) }
        }
        if genreMixes {
            SettingsCard(title: "Genres", footer: "Automatic makes a mix for each of the four genres you play and like most. Tick genres to choose them yourself.") {
                genreRow(String(localized: "Automatic"), selected: pickedGenres.isEmpty, last: serverGenres.isEmpty) { genresRaw = "" }
                ForEach(serverGenres, id: \.value) { genre in
                    genreRow(genre.value, selected: pickedGenres.contains(genre.value),
                             last: genre.value == serverGenres.last?.value) { pick(genre.value) }
                }
            }
        }
        SettingsCard(footer: "Mixes are made again every eight hours, and when the time of day changes.") {
            SettingsRow(title: "Songs per Mix") {
                Chips(options: [25, 50, 100], selection: $length) { "\($0)" }
            }
            SettingsRow(title: "Make New Mixes Now", last: true) {
                HStack(spacing: 8) {
                    if generator.isGenerating { ProgressView().controlSize(.small) }
                    Button { Task { await generator.generate() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(generator.isGenerating)
                }
            }
        }
        .task { await loadGenres() }
        .onAppear { signatureOnAppear = MixPreferences.signature }
        .onDisappear {
            guard MixPreferences.signature != signatureOnAppear else { return }
            Task { await MixGenerator.shared.generate() }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
    }

    private func moodBinding(_ mood: MixGenerator.Mood) -> Binding<Bool> {
        switch mood {
        case .chill: return $chill
        case .focus: return $focus
        case .feelGood: return $feelGood
        case .energy: return $energy
        }
    }

    private func genreRow(_ name: String, selected: Bool, last: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsRow(title: LocalizedStringKey(name), last: last) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ genre: String) {
        var picked = pickedGenres
        if let i = picked.firstIndex(of: genre) { picked.remove(at: i) } else { picked.append(genre) }
        genresRaw = picked.joined(separator: "\n")
    }

    /// The server's genres, biggest first, so the ones worth a mix are at the top.
    private func loadGenres() async {
        guard let server = ServerManager.shared.currentServer,
              let genres = try? await SubsonicClient.shared.getGenres(server: server) else { return }
        serverGenres = genres
            .filter { ($0.songCount ?? 0) >= 8 && !$0.value.isEmpty }
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
    }
}

/// Last.fm, as the phone connects it: both fields checked with Last.fm before anything is
/// kept, then one line saying who is connected.
private struct MacLastfmSettings: View {
    @State private var settings = AppSettings.shared
    @State private var user = AppSettings.shared.lastfmUsername
    @State private var key = ""
    @State private var editing = false
    @State private var validating = false
    @State private var scrobbles: Int?
    @State private var failure: String?

    /// Editing an account keeps its saved key unless a new one is pasted.
    private var keyToSave: String { key.isEmpty ? settings.lastfmApiKey : key }
    private var canSave: Bool {
        !user.trimmingCharacters(in: .whitespaces).isEmpty && !keyToSave.isEmpty && !validating
    }

    var body: some View {
        if settings.lastfmConfigured && !editing {
            SettingsCard {
                SettingsRow(title: LocalizedStringKey(settings.lastfmUsername),
                            detail: scrobbles.map { "\($0) scrobbles" } ?? "Connected — powers your Wrapped",
                            last: true) {
                    HStack(spacing: 8) {
                        Button("Change") {
                            user = settings.lastfmUsername
                            key = ""
                            failure = nil
                            editing = true
                        }
                        Button("Disconnect", role: .destructive) {
                            settings.lastfmUsername = ""
                            settings.lastfmApiKey = ""
                            settings.save()
                            user = ""
                            key = ""
                            scrobbles = nil
                        }
                    }
                }
            }
        } else {
            SettingsCard(footer: "Both fields are required: the API key identifies the app, the username says whose scrobbles to read. Create a free API key at last.fm/api/account/create.") {
                SettingsRow(title: "Username") {
                    TextField("Username", text: $user)
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                        .autocorrectionDisabled()
                }
                SettingsRow(title: "API Key") {
                    SecureField("API Key", text: $key,
                                prompt: Text(settings.lastfmConfigured ? "Keep the saved key" : "API Key"))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                SettingsRow(title: validating ? "Checking…" : "Connect", last: true) {
                    HStack(spacing: 8) {
                        if validating { ProgressView().controlSize(.small) }
                        if editing { Button("Cancel") { editing = false; failure = nil } }
                        Button("Connect") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private func save() async {
        validating = true
        failure = nil
        defer { validating = false }
        do {
            let key = keyToSave
            let account = try await LastfmService.shared.validate(username: user, apiKey: key)
            // Kept only once Last.fm confirms the pair works.
            settings.lastfmUsername = account.username
            settings.lastfmApiKey = key
            settings.save()
            user = account.username
            self.key = ""
            editing = false
            scrobbles = account.scrobbles
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// The radar's switch, and the artists taken off it, each a click from coming back.
private struct MacRadarSettings: View {
    @State private var settings = AppSettings.shared
    private var radar: RadarService { .shared }

    var body: some View {
        SettingsCard(footer: radar.watched != nil
                     ? "The radar follows SoulSync's watchlist, and adds your favourite and most-played artists to it. SoulSync downloads their new releases by itself once a day; Get It fetches one at once."
                     : "New releases from the artists you play most, found in Deezer's public catalogue. Only artist names are sent.") {
            SettingsRow(title: "Show Radar on Home", last: radar.watched == nil) {
                Toggle("", isOn: $settings.radarEnabled).toggleStyle(.switch).labelsHidden()
            }
            if let watched = radar.watched {
                SettingsRow(title: "Followed with SoulSync", last: true) {
                    Text("\(watched.count)").foregroundStyle(.secondary)
                }
            }
        }
        if !radar.unfollowed.isEmpty {
            SettingsCard(title: "Unfollowed Artists", footer: "Their new releases come back to the radar at its next daily pass.") {
                ForEach(radar.unfollowed) { artist in
                    SettingsRow(title: LocalizedStringKey(artist.name), last: artist.id == radar.unfollowed.last?.id) {
                        Button("Follow") { withAnimation { radar.follow(artist) } }
                    }
                }
            }
        }
    }
}

/// The version, the server's counts, the links, and logging out.
private struct MacAboutSettings: View {
    @State private var stats: [(title: LocalizedStringKey, count: Int)] = []
    @State private var confirmsLogOut = false

    /// "1.4 · build 447": the version, then the build.
    private var version: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return version }
        return String(localized: "\(version) · build \(build)")
    }

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Your music. Your server.", detail: "Version \(version)", last: true) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Aura \(version)", forType: .string)
                    ToastManager.shared.show(String(localized: "Version copied"), icon: "doc.on.doc")
                } label: { Image(systemName: "doc.on.doc") }
            }
        }
        if !stats.isEmpty {
            SettingsCard(title: "Server Statistics") {
                ForEach(stats.indices, id: \.self) { i in
                    SettingsRow(title: stats[i].title, last: i == stats.count - 1) {
                        Text("\(stats[i].count)").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        SettingsCard(footer: "Crafted with care in Italy") {
            link("Source & updates", "https://github.com/adrbn/aura")
            link("Website", "https://aura.adrbn.dev")
            link("Privacy Policy", "https://aura.adrbn.dev/privacy", last: true)
        }
        SettingsCard {
            SettingsRow(title: "Log Out", last: true) {
                Button("Log Out", role: .destructive) { confirmsLogOut = true }
            }
        }
        .confirmationDialog("Log Out", isPresented: $confirmsLogOut) {
            Button("Log Out", role: .destructive) {
                let servers = ServerManager.shared
                servers.currentServer = nil
                servers.servers.removeAll()
                servers.saveServers()
                servers.saveCurrentServer()
                MacSettingsPanel.shared.isShown = false
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await loadStats() }
    }

    private func link(_ title: LocalizedStringKey, _ address: String, last: Bool = false) -> some View {
        Button { NSWorkspace.shared.open(URL(string: address)!) } label: {
            SettingsRow(title: title, last: last) {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadStats() async {
        guard let server = ServerManager.shared.currentServer else { return }
        do {
            async let artists = SubsonicClient.shared.getArtists(server: server)
            async let playlists = SubsonicClient.shared.getPlaylists(server: server)
            async let scan = SubsonicClient.shared.getScanStatus(server: server)
            async let albums = SubsonicClient.shared.getAlbumCount(server: server)
            let (a, p, s, al) = try await (artists, playlists, scan, albums)
            stats = [("Songs", s.count ?? 0), ("Albums", al), ("Artists", a.count), ("Playlists", p.count)]
        } catch {
            AppLogger.shared.log("❌ Failed to load server stats: \(error.localizedDescription)")
        }
    }
}

/// Stars for one or several songs, in any song's context menu.
struct MacRatingMenu: View {
    let songs: [Song]

    var body: some View {
        let ratings = SongRatings.shared
        let current = songs.count == 1 ? ratings.rating(for: songs[0]) : -1
        Menu("Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button {
                    songs.forEach { ratings.set(stars, for: $0) }
                } label: {
                    let label = stars == 0 ? String(localized: "No Rating") : String(repeating: "★", count: stars)
                    if stars == current { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        }
        .disabled(songs.isEmpty)
    }
}
