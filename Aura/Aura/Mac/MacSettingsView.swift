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
    enum Pane: String, CaseIterable, Identifiable {
        case playback, lyrics, library, appearance, translation, developer
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
            case .appearance: "Appearance"
            case .translation: "Lyrics Translation"
            case .developer: "Developer"
            }
        }
        var symbol: String {
            switch self {
            case .playback: "play.fill"
            case .lyrics: "quote.bubble.fill"
            case .library: "music.note.house.fill"
            case .appearance: "paintpalette.fill"
            case .translation: "translate"
            case .developer: "hammer.fill"
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
        }
        .padding(.top, 24)
        .padding(.horizontal, 12)
        .frame(width: 230)
        // A shade darker than the pane beside it, so the two read as sidebar and page.
        .background(.black.opacity(0.22))
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
         settings.slskdPassword].joined(separator: "|")
    }
}

// MARK: Pieces

/// A group of rows on a faint card, like the phone's grouped settings but in the window's dark.
private struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey?
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
                SecureField("slskd", text: $settings.slskdPassword)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
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
