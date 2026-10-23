import SwiftUI

/// The Settings window (⌘,): what is set once and left — playback, the library, the look.
/// What is judged against the song playing stays in the toolbar's gear menu.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            MacPlaybackSettings().tabItem { Label("Playback", systemImage: "play.circle") }
            MacLibrarySettings().tabItem { Label("Library", systemImage: "music.note.house") }
            MacAppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            LyricsTranslationSettingsView()
                .frame(height: 560)
                .tabItem { Label("Lyrics Translation", systemImage: "translate") }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacPlaybackSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker("Streaming Quality", selection: $settings.streamingQuality) {
                ForEach(StreamingQuality.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Toggle("ReplayGain", isOn: $settings.replayGain)
            Toggle("Scrobble", isOn: $settings.scrobbleEnabled)
            if settings.scrobbleEnabled {
                Picker("Scrobble After", selection: $settings.scrobbleThreshold) {
                    Text("50%").tag(0.5)
                    Text("75%").tag(0.75)
                    Text("90%").tag(0.9)
                }
            }
            Toggle("Word-by-Word Lyrics", isOn: $settings.betaKaraokeLyrics)
        }
        .formStyle(.grouped)
        .onChange(of: [settings.streamingQuality.rawValue, String(settings.replayGain), String(settings.scrobbleEnabled),
                       String(settings.scrobbleThreshold), String(settings.betaKaraokeLyrics)]) { settings.save() }
    }
}

private struct MacLibrarySettings: View {
    @State private var settings = AppSettings.shared
    @State private var folders: [MusicFolder] = []
    @State private var scanning = false
    @State private var scanned: Int?

    var body: some View {
        Form {
            if folders.count > 1 {
                Section("Music Folders") {
                    ForEach(folders) { folder in
                        Toggle(folder.name ?? String(localized: "Folder \(folder.id)"), isOn: Binding(
                            get: { settings.selectedMusicFolderIds.isEmpty || settings.selectedMusicFolderIds.contains(folder.id) },
                            set: { toggle(folder.id, on: $0) }))
                    }
                }
            }
            Section("Library Scan") {
                HStack {
                    Button("Quick Scan") { Task { await scan(full: false) } }
                    Button("Full Scan") { Task { await scan(full: true) } }
                    Spacer()
                    if scanning {
                        ProgressView().controlSize(.small)
                        if let scanned { Text("\(scanned) items scanned").foregroundStyle(.secondary) }
                    }
                }
                .disabled(scanning)
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        Form {
            Picker("Accent", selection: $settings.appAccentColor) {
                ForEach(AppAccentColor.presets, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Picker("Cover Size", selection: Bindable(MacPreferences.shared).coverSize) {
                ForEach(MacCoverSize.allCases) { Text($0.label).tag($0) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.appAccentColor) { settings.save() }
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
