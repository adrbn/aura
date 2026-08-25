import Foundation
import SwiftUI

// MARK: - Server Config

struct ServerConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var url: String
    var username: String
    var password: String
    var friendlyName: String

    var baseURL: String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    enum CodingKeys: String, CodingKey {
        case id, url, username, friendlyName
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case password
    }

    init(id: UUID = UUID(), url: String, username: String, password: String, friendlyName: String) {
        self.id = id
        self.url = url
        self.username = username
        self.password = password
        self.friendlyName = friendlyName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        username = try c.decode(String.self, forKey: .username)
        friendlyName = try c.decode(String.self, forKey: .friendlyName)
        // Load from Keychain; fall back to legacy JSON field for migration
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if let keychainPw = KeychainHelper.loadPassword(for: id.uuidString), !keychainPw.isEmpty {
            password = keychainPw
        } else if let legacyPw = try legacy.decodeIfPresent(String.self, forKey: .password), !legacyPw.isEmpty {
            password = legacyPw
            // Migrate to Keychain
            KeychainHelper.save(password: legacyPw, for: id.uuidString)
        } else {
            password = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(username, forKey: .username)
        try c.encode(friendlyName, forKey: .friendlyName)
        // Don't encode password to JSON — it's in Keychain
        KeychainHelper.save(password: password, for: id.uuidString)
    }
}

// MARK: - App Settings

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var tabOrder: [TabItem] = TabItem.defaultOrder
    var pinnedPlaylistIds: Set<String> = []
    var pinnedPlaylistOrder: [String] = []
    var streamingQuality: StreamingQuality = .high
    var maxBitRate: Int = 320
    var cacheEnabled: Bool = true
    var cacheMaxSize: Int = 2048 // MB
    var artworkQuality: ArtworkQuality = .high
    var scrobbleEnabled: Bool = true
    var scrobbleThreshold: Double = 0.5
    var replayGain: Bool = false
    var crossfadeSeconds: Int = 0
    var gaplessPlayback: Bool = true
    var downloadQuality: DownloadQuality = .high
    var offlineMode: Bool = false
    var betaFeaturesEnabled: Bool = false
    var externalServiceProvider: ExternalServiceProvider = .slskd
    var externalServiceURL: String = "127.0.0.1"
    var externalServicePort: Int = 5030
    var slskdUsername: String = "slskd"
    /// Kept in the Keychain, never in UserDefaults — `save()`/`load()` handle the sync.
    var slskdPassword: String = ""
    var showStatsOnHome: Bool = true
    var upNextLayout: UpNextLayout = .grid
    var homeTitleStyle: HomeTitleStyle = .server
    var showServerStatus: Bool = true
    var listDensity: ListDensity = .normal
    var appLanguage: AppLanguage = .english
    var showHomeSearchBar: Bool = true
    var showUpNext: Bool = true
    var appAccentColor: AppAccentColor = .pink
    var activeTheme: AppTheme = .standard
    /// Dark by default. Aura is a dark-first app — the artwork canvas, Now Playing and
    /// the landscape clock are always dark — so following a light system appearance made
    /// the app disagree with itself. Users who prefer Light or System still get their
    /// stored choice back; this only changes what a fresh install starts on.
    var appearanceMode: AppearanceMode = .dark
    var eqPreset: EQPreset = .flat
    var eqCustomBands: [Float] = [0, 0, 0, 0, 0]
    var forceMP3Transcoding: Bool = false
    var losslessTranscodeMode: LosslessTranscodeMode = .mp3_320
    var selectedMusicFolderId: Int? = nil
    var selectedMusicFolderIds: Set<Int> = []
    var enabledLibraryCategories: [LibraryCategory] = LibraryCategory.defaultEnabled
    var showPlayCounts: Bool = false
    var homeSectionOrder: [HomeSection] = HomeSection.defaultOrder
    /// Display typeface for the wordmark and big titles. Vavin Condensed is the app's
    /// face; `resolved` falls back to it when a stored choice isn't bundled in this build —
    /// which is what happens to the dev-only faces in a shipping one.
    var displayFont: DisplayFont = .vavinCondensed

    /// Manual lyrics timing correction, in seconds. Negative shows words earlier.
    ///
    /// The automatic output-latency compensation gets the route right but not the last
    /// tenth of a second: AVPlayer already absorbs part of that delay, and the sources
    /// themselves vary. One knob, set once.
    var lyricsOffset: Double = 0

    /// Highlight lyrics word by word inside the current line. Uses the server's own cue
    /// timings when it publishes them, and interpolates from the line duration otherwise —
    /// see `LyricWordTiming`. On by default; the toggle exists because the interpolated
    /// case is inferred rather than measured.
    var betaKaraokeLyrics: Bool = true

    /// ALPHA — Now Playing hides its options bar behind a small glass handle, so the
    /// screen stays on the artwork. Tapping the handle reveals the bar for a few seconds.
    var alphaAutoHideToolbar: Bool = false

    /// Opt-in: when off, rotating the device while Now Playing is open does nothing.
    /// When on, landscape reveals the full-screen clock/lyrics view.
    var landscapeClockEnabled: Bool = false

    /// Last.fm — powers the "Wrapped" retrospective from real long-term scrobble
    /// history. Username is public; the API key lives in the Keychain.
    var lastfmUsername: String = ""
    var lastfmApiKey: String = ""
    var lastfmConfigured: Bool {
        !lastfmUsername.trimmingCharacters(in: .whitespaces).isEmpty && !lastfmApiKey.isEmpty
    }
    /// Whether the Wrapped retrospective surfaces on the Home tab. Off by default —
    /// Wrapped is reached from its explicit entry in Settings, and (when this is on)
    /// only during its seasonal windows. Configuring Last.fm no longer force-shows it.
    var wrappedShowOnHome: Bool = false

    private let settingsKey = "musika_app_settings"
    private static let slskdKeychainAccount = "slskd-external-service"
    private static let lastfmKeychainAccount = "lastfm-api-key"

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: data) {
            tabOrder = decoded.tabOrder
            pinnedPlaylistIds = decoded.pinnedPlaylistIds
            streamingQuality = decoded.streamingQuality
            maxBitRate = decoded.maxBitRate
            cacheEnabled = decoded.cacheEnabled
            cacheMaxSize = decoded.cacheMaxSize
            artworkQuality = decoded.artworkQuality
            scrobbleEnabled = decoded.scrobbleEnabled
            scrobbleThreshold = decoded.scrobbleThreshold
            replayGain = decoded.replayGain
            crossfadeSeconds = decoded.crossfadeSeconds
            gaplessPlayback = decoded.gaplessPlayback
            downloadQuality = decoded.downloadQuality ?? .high
            offlineMode = decoded.offlineMode ?? false
            betaFeaturesEnabled = decoded.betaFeaturesEnabled ?? false
            externalServiceProvider = decoded.externalServiceProvider ?? .slskd
            externalServiceURL = decoded.externalServiceURL ?? "127.0.0.1"
            externalServicePort = decoded.externalServicePort ?? 5030
            slskdUsername = decoded.slskdUsername ?? "slskd"
            // Migrate a password previously stored in UserDefaults into the Keychain
            // (one-time; the next save() scrubs it from UserDefaults).
            if KeychainHelper.loadPassword(for: Self.slskdKeychainAccount) == nil,
               let legacy = decoded.slskdPassword, !legacy.isEmpty {
                KeychainHelper.save(password: legacy, for: Self.slskdKeychainAccount)
            }
            slskdPassword = KeychainHelper.loadPassword(for: Self.slskdKeychainAccount) ?? ""
            // Migrate: if provider is slskd but port is the old SoulSync default, fix it
            if externalServiceProvider == .slskd && externalServicePort == 8008 {
                externalServicePort = 5030
            }
            showStatsOnHome = decoded.showStatsOnHome ?? true
            upNextLayout = decoded.upNextLayout ?? .grid
            homeTitleStyle = decoded.homeTitleStyle ?? (decoded.hideHomeTitle == true ? .none : (decoded.showServerName == false ? .home : .server))
            showServerStatus = decoded.showServerStatus ?? true
            listDensity = decoded.listDensity ?? .normal
            pinnedPlaylistOrder = decoded.pinnedPlaylistOrder ?? Array(pinnedPlaylistIds)
            appLanguage = decoded.appLanguage ?? .english
            showHomeSearchBar = decoded.showHomeSearchBar ?? true
            showUpNext = decoded.showUpNext ?? true
            appAccentColor = decoded.appAccentColor ?? .pink
            activeTheme = decoded.activeTheme ?? .standard
            appearanceMode = decoded.appearanceMode ?? .dark
            eqPreset = decoded.eqPreset ?? .flat
            eqCustomBands = decoded.eqCustomBands ?? [0, 0, 0, 0, 0]
            forceMP3Transcoding = decoded.forceMP3Transcoding ?? false
            losslessTranscodeMode = decoded.losslessTranscodeMode ?? .mp3_320
            selectedMusicFolderId = decoded.selectedMusicFolderId
            if let ids = decoded.selectedMusicFolderIds {
                selectedMusicFolderIds = ids
            } else if let singleId = decoded.selectedMusicFolderId, singleId != -1 {
                selectedMusicFolderIds = [singleId]
            }
            enabledLibraryCategories = decoded.enabledLibraryCategories ?? LibraryCategory.defaultEnabled
            showPlayCounts = decoded.showPlayCounts ?? false
            let loadedOrder = decoded.homeSectionOrder ?? HomeSection.defaultOrder
            // Migrate: if user has the old CaseIterable default order, switch to new preferred default
            let oldCaseIterableOrder: [HomeSection] = [.upNext, .recentlyPlayed, .recentlyAdded, .frequentlyPlayed, .randomAlbums, .favoriteSongs, .favoriteArtists]
            if loadedOrder == oldCaseIterableOrder {
                homeSectionOrder = HomeSection.defaultOrder
                // Persist the migration
                DispatchQueue.main.async { [self] in self.save() }
            } else {
                homeSectionOrder = loadedOrder
            }
            landscapeClockEnabled = decoded.landscapeClockEnabled ?? false
            displayFont = decoded.displayFont ?? .vavinCondensed
            betaKaraokeLyrics = decoded.betaKaraokeLyrics ?? true
            lyricsOffset = decoded.lyricsOffset ?? 0
            alphaAutoHideToolbar = decoded.alphaAutoHideToolbar ?? false
            lastfmUsername = decoded.lastfmUsername ?? ""
            lastfmApiKey = KeychainHelper.loadPassword(for: Self.lastfmKeychainAccount) ?? ""
            wrappedShowOnHome = decoded.wrappedShowOnHome ?? false
        }
    }

    func save() {
        let data = SettingsData(
            tabOrder: tabOrder, pinnedPlaylistIds: pinnedPlaylistIds,
            streamingQuality: streamingQuality, maxBitRate: maxBitRate,
            cacheEnabled: cacheEnabled, cacheMaxSize: cacheMaxSize,
            artworkQuality: artworkQuality, scrobbleEnabled: scrobbleEnabled,
            scrobbleThreshold: scrobbleThreshold, replayGain: replayGain,
            crossfadeSeconds: crossfadeSeconds, gaplessPlayback: gaplessPlayback,
            downloadQuality: downloadQuality, offlineMode: offlineMode,
            betaFeaturesEnabled: betaFeaturesEnabled,
            externalServiceProvider: externalServiceProvider,
            externalServiceURL: externalServiceURL,
            externalServicePort: externalServicePort,
            slskdUsername: slskdUsername,
            slskdPassword: "", // never persisted to UserDefaults — lives in the Keychain
            showStatsOnHome: showStatsOnHome,
            upNextLayout: upNextLayout,
            homeTitleStyle: homeTitleStyle,
            showServerStatus: showServerStatus,
            listDensity: listDensity,
            pinnedPlaylistOrder: pinnedPlaylistOrder,
            appLanguage: appLanguage,
            showHomeSearchBar: showHomeSearchBar,
            showUpNext: showUpNext,
            appAccentColor: appAccentColor,
            activeTheme: activeTheme,
            appearanceMode: appearanceMode,
            eqPreset: eqPreset,
            eqCustomBands: eqCustomBands,
            forceMP3Transcoding: forceMP3Transcoding,
            losslessTranscodeMode: losslessTranscodeMode,
            selectedMusicFolderId: selectedMusicFolderId,
            selectedMusicFolderIds: selectedMusicFolderIds,
            enabledLibraryCategories: enabledLibraryCategories,
            showPlayCounts: showPlayCounts,
            homeSectionOrder: homeSectionOrder,
            landscapeClockEnabled: landscapeClockEnabled,
            displayFont: displayFont,
            betaKaraokeLyrics: betaKaraokeLyrics,
            lyricsOffset: lyricsOffset,
            alphaAutoHideToolbar: alphaAutoHideToolbar,
            lastfmUsername: lastfmUsername,
            wrappedShowOnHome: wrappedShowOnHome
        )
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
        // Password is kept out of the snapshot above — sync it to the Keychain.
        if slskdPassword.isEmpty {
            KeychainHelper.delete(for: Self.slskdKeychainAccount)
        } else {
            KeychainHelper.save(password: slskdPassword, for: Self.slskdKeychainAccount)
        }
        // Last.fm API key likewise lives only in the Keychain.
        if lastfmApiKey.isEmpty {
            KeychainHelper.delete(for: Self.lastfmKeychainAccount)
        } else {
            KeychainHelper.save(password: lastfmApiKey, for: Self.lastfmKeychainAccount)
        }
    }

    func togglePin(playlistId: String) {
        if pinnedPlaylistIds.contains(playlistId) {
            pinnedPlaylistIds.remove(playlistId)
            pinnedPlaylistOrder.removeAll { $0 == playlistId }
        } else {
            pinnedPlaylistIds.insert(playlistId)
            pinnedPlaylistOrder.append(playlistId)
        }
        save()
        // Pins travel between devices; everything else in here is per-device. Hopped onto
        // the main actor because AppSettings itself is not isolated to one.
        Task { @MainActor in PinSync.shared.push() }
    }

    func movePinnedPlaylist(from source: IndexSet, to destination: Int) {
        pinnedPlaylistOrder.move(fromOffsets: source, toOffset: destination)
        save()
        Task { @MainActor in PinSync.shared.push() }
    }

    func isPinned(_ playlistId: String) -> Bool {
        pinnedPlaylistIds.contains(playlistId)
    }
}

struct SettingsData: Codable {
    var tabOrder: [TabItem]
    var pinnedPlaylistIds: Set<String>
    var streamingQuality: StreamingQuality
    var maxBitRate: Int
    var cacheEnabled: Bool
    var cacheMaxSize: Int
    var artworkQuality: ArtworkQuality
    var scrobbleEnabled: Bool
    var scrobbleThreshold: Double
    var replayGain: Bool
    var crossfadeSeconds: Int
    var gaplessPlayback: Bool
    var downloadQuality: DownloadQuality?
    var offlineMode: Bool?
    var betaFeaturesEnabled: Bool?
    var externalServiceProvider: ExternalServiceProvider?
    var externalServiceURL: String?
    var externalServicePort: Int?
    var slskdUsername: String?
    var slskdPassword: String?
    var showStatsOnHome: Bool?
    var upNextLayout: UpNextLayout?
    var showServerName: Bool?
    var hideHomeTitle: Bool?
    var homeTitleStyle: HomeTitleStyle?
    var showServerStatus: Bool?
    var listDensity: ListDensity?
    var pinnedPlaylistOrder: [String]?
    var appLanguage: AppLanguage?
    var showHomeSearchBar: Bool?
    var showUpNext: Bool?
    var appAccentColor: AppAccentColor?
    var activeTheme: AppTheme?
    var appearanceMode: AppearanceMode?
    var eqPreset: EQPreset?
    var eqCustomBands: [Float]?
    var forceMP3Transcoding: Bool?
    var losslessTranscodeMode: LosslessTranscodeMode?
    var selectedMusicFolderId: Int?
    var selectedMusicFolderIds: Set<Int>?
    var enabledLibraryCategories: [LibraryCategory]?
    var showPlayCounts: Bool?
    var homeSectionOrder: [HomeSection]?
    var landscapeClockEnabled: Bool?
    var displayFont: DisplayFont?
    var betaKaraokeLyrics: Bool?
    var lyricsOffset: Double?
    var alphaAutoHideToolbar: Bool?
    var lastfmUsername: String?
    var wrappedShowOnHome: Bool?
}

enum AppAccentColor: String, Codable, CaseIterable {
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case teal = "Teal"
    case blue = "Blue"
    case indigo = "Indigo"
    case purple = "Purple"

    var color: Color {
        switch self {
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        }
    }
}

/// Light/dark preference. `.system` follows iOS; the other two pin the whole app.
/// Surfaces that live on top of album artwork (Now Playing, the nightstand clock,
/// the photo viewer) stay dark regardless — they pin their own subtree.
enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    /// `nil` hands control back to iOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

enum AppTheme: String, Codable, CaseIterable {
    case standard = "Standard"

    var accentColor: Color {
        return AppSettings.shared.appAccentColor.color
    }

    var usePureBlack: Bool {
        return false
    }
}

// MARK: - Accent Color Environment Key

private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = .pink
}

extension EnvironmentValues {
    var appAccentColor: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}

extension Color {
    static var appAccent: Color { AppSettings.shared.activeTheme.accentColor }
    /// Default page background: WHITE in light, black in dark. Content tabs (Home,
    /// Library, Search, Playlists) use this — they are not grouped lists.
    static var themeBg: Color {
        AppSettings.shared.activeTheme.usePureBlack ? .black : .platformBackground
    }
    static var themeSecondaryBg: Color {
        AppSettings.shared.activeTheme.usePureBlack ? Color(white: 0.07) : .platformSecondaryBackground
    }
    static var themeGroupedBg: Color {
        AppSettings.shared.activeTheme.usePureBlack ? Color(white: 0.07) : .platformGroupedBackground
    }
    /// Page background for GROUPED list screens ONLY (Settings). Grey in light, so the
    /// white `themeGroupedBg` rows read as distinct cards — the iOS Settings convention.
    /// Identical to `themeBg` in dark (both black), so dark mode is untouched.
    static var themeGroupedPageBg: Color {
        AppSettings.shared.activeTheme.usePureBlack ? .black : .platformGroupedPageBackground
    }

    // MARK: Platform system colours
    //
    // The semantic greys are named after UIKit and have no counterpart of the same name on
    // macOS. AppKit's equivalents are named for what they sit behind — a window, a control,
    // a page — rather than for how they are nested, so the mapping is by role: the plain
    // page background becomes the window's, and the "grouped" backgrounds, which exist on
    // iOS to make list rows read as cards on grey, become AppKit's control and
    // under-page colours.

    static var platformBackground: Color {
        #if canImport(UIKit)
        Color(.systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var platformSecondaryBackground: Color {
        #if canImport(UIKit)
        Color(.secondarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    static var platformGroupedBackground: Color {
        #if canImport(UIKit)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var platformGroupedPageBackground: Color {
        #if canImport(UIKit)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

enum EQPreset: String, Codable, CaseIterable {
    case flat = "Flat"
    case bass = "Bass Boost"
    case treble = "Treble Boost"
    case vocal = "Vocal"
    case rock = "Rock"
    case pop = "Pop"
    case jazz = "Jazz"
    case electronic = "Electronic"
    case classical = "Classical"
    case hiphop = "Hip-Hop"
    case rnb = "R&B"
    case acoustic = "Acoustic"
    case lateNight = "Late Night"
    case loudness = "Loudness"
    case smallSpeakers = "Small Speakers"
    case custom = "Custom"

    var bands: [Float] {
        // [60Hz, 230Hz, 910Hz, 3.6kHz, 14kHz]
        switch self {
        case .flat:          return [0, 0, 0, 0, 0]
        case .bass:          return [10, 7, 0, -1, -2]
        case .treble:        return [-2, -1, 0, 7, 10]
        case .vocal:         return [-4, 0, 8, 6, 2]
        case .rock:          return [8, 4, -2, 6, 8]
        case .pop:           return [-2, 4, 8, 4, -2]
        case .jazz:          return [6, 2, -2, 2, 6]
        case .electronic:    return [10, 6, 0, 4, 8]
        case .classical:     return [6, 2, 0, 2, 6]
        case .hiphop:        return [10, 8, 2, 0, 4]
        case .rnb:           return [6, 10, 4, -2, 2]
        case .acoustic:      return [4, 2, 0, 4, 4]
        case .lateNight:     return [6, 4, 2, 0, -2]
        case .loudness:      return [8, 4, -4, 4, 2]
        case .smallSpeakers: return [10, 8, 4, 2, 4]
        case .custom:        return AppSettings.shared.eqCustomBands
        }
    }

    static let bandFrequencies: [Float] = [60, 230, 910, 3600, 14000]
    static let bandLabels = ["60", "230", "910", "3.6k", "14k"]
}

enum UpNextLayout: String, Codable, CaseIterable {
    case grid = "Grid"
    case list = "List"
}

enum HomeTitleStyle: String, Codable, CaseIterable {
    case server = "Server"
    case home = "Home"
    case none = "None"
}

enum TabItem: String, Codable, Identifiable, CaseIterable {
    case home, library, playlists, settings, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .playlists: return "Playlists"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.stack.fill"
        case .playlists: return "music.note.list"
        case .settings: return "gearshape.fill"
        case .search: return "magnifyingglass"
        }
    }

    static var defaultOrder: [TabItem] { [.home, .library, .playlists, .settings, .search] }
}

enum StreamingQuality: String, Codable, CaseIterable {
    case low = "Low (128kbps)"
    case medium = "Medium (192kbps)"
    case high = "High (320kbps)"
    case lossless = "Lossless (Original)"

    var bitRate: Int? {
        switch self {
        case .low: return 128
        case .medium: return 192
        case .high: return 320
        case .lossless: return nil
        }
    }
}

enum ArtworkQuality: String, Codable, CaseIterable {
    case low = "Low (150px)"
    case medium = "Medium (300px)"
    case high = "High (600px)"
    case original = "Original"

    var size: Int {
        switch self {
        case .low: return 150
        case .medium: return 300
        case .high: return 600
        case .original: return 1200
        }
    }
}

// MARK: - Subsonic Response Types

struct SubsonicResponse<T: Decodable>: Decodable {
    let subsonicResponse: SubsonicResponseBody<T>
    enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" }
}

struct SubsonicResponseBody<T: Decodable>: Decodable {
    let status: String
    let version: String
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: SubsonicError?
    enum CodingKeys: String, CodingKey { case status, version, type, serverVersion, openSubsonic, error }
}

struct SubsonicError: Decodable {
    let code: Int
    let message: String
}

// MARK: - Music Models

/// One credited artist, with the id needed to actually go there.
struct ArtistRef: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct Song: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let album: String?
    let artist: String?
    let albumId: String?
    let artistId: String?
    /// OpenSubsonic's per-artist credits. `artist` is one string with every name run
    /// together and `artistId` points at only the first of them, so a collaboration cannot
    /// be navigated from those two alone. Servers below the extension omit this, hence the
    /// default — see `creditedArtists` for the fallback.
    var artists: [ArtistRef]?
    let track: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let duration: Int?
    let bitRate: Int?
    let suffix: String?
    let contentType: String?
    let isDir: Bool?
    var starred: String?
    let size: Int?
    let path: String?
    let playCount: Int?
    let mediaType: String?  // OpenSubsonic extension
    let explicit: Bool?     // OpenSubsonic: explicit content flag (proposed)
    let created: String?    // ISO 8601 date when song was added to server

    var isExplicit: Bool { explicit == true }

    /// Cover art to display for this song. Songs without embedded art get
    /// `coverArt: nil` from the server — fall back to the album's art
    /// (getCoverArt accepts album ids) instead of showing a placeholder.
    var displayCoverArt: String? { coverArt ?? albumId }

    var durationFormatted: String {
        guard let d = duration else { return "--:--" }
        let minutes = d / 60
        let seconds = d % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var isStarred: Bool { starred != nil }

    var fileSizeFormatted: String {
        guard let s = size else { return "Unknown" }
        if s > 1_000_000 { return String(format: "%.1f MB", Double(s) / 1_000_000) }
        return String(format: "%.0f KB", Double(s) / 1_000)
    }
}

struct Album: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let starred: String?
    let created: String?
    let playCount: Int?

    var isStarred: Bool { starred != nil }
}

struct Artist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let artistImageUrl: String?
    let playCount: Int?

    var isStarred: Bool { starred != nil }
}

struct ArtistIndex: Codable {
    let name: String
    let artist: [Artist]
}

struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let songCount: Int?
    let duration: Int?
    let coverArt: String?
    let owner: String?
    let created: String?
    let changed: String?
    let comment: String?
    let `public`: Bool?
}

struct PlaylistWithSongs: Codable {
    let id: String
    let name: String
    var songCount: Int?
    let duration: Int?
    let coverArt: String?
    let owner: String?
    var entry: [Song]?
    let comment: String?
    let `public`: Bool?
}

enum PlaybackSource: Equatable, Codable {
    case album(id: String, name: String)
    case playlist(id: String, name: String)
    case mix(id: String, name: String)
    case radio(name: String)
    case artist(id: String, name: String)
    case genre(name: String)
    case favorites
    case search(query: String)
    case songs
    case recentlyPlayed
    case frequentlyPlayed
    case queue
    case autoplay
    case unknown

    var displayName: String {
        switch self {
        case .album(_, let name): return name
        case .playlist(_, let name): return name
        case .mix(_, let name): return name
        case .radio(let name): return name
        case .artist(_, let name): return name
        case .genre(let name): return name
        case .favorites: return "Favorites"
        case .search(let query): return "Search: \(query)"
        case .songs: return "Songs"
        case .recentlyPlayed: return "Recently Played"
        case .frequentlyPlayed: return "Frequently Played"
        case .queue: return "Queue"
        case .autoplay: return "Autoplay"
        case .unknown: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .mix: return "square.stack.3d.up.fill"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .artist: return "music.mic"
        case .genre: return "guitars"
        case .favorites: return "heart.fill"
        case .search: return "magnifyingglass"
        case .songs: return "music.note"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .frequentlyPlayed: return "arrow.counterclockwise"
        case .queue: return "list.bullet"
        case .autoplay: return "sparkles"
        case .unknown: return ""
        }
    }

    var isNavigable: Bool {
        switch self {
        case .album, .playlist, .mix, .artist, .radio, .favorites, .genre, .recentlyPlayed, .frequentlyPlayed, .queue, .autoplay: return true
        case .search, .songs, .unknown: return false
        }
    }
}

struct SearchResult3: Codable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

struct AlbumList2: Decodable { let album: [Album]? }
struct AlbumWithSongs: Codable {
    let id: String; let name: String; let artist: String?; let artistId: String?
    let coverArt: String?; let songCount: Int?; let duration: Int?
    let year: Int?; let genre: String?; let song: [Song]?
}
struct ArtistsContainer: Decodable { let index: [ArtistIndex]? }
struct ArtistWithAlbums: Codable {
    let id: String; let name: String; let coverArt: String?
    let albumCount: Int?; let artistImageUrl: String?; let album: [Album]?
}
struct PlaylistsContainer: Decodable { let playlist: [Playlist]? }
struct RandomSongsContainer: Decodable { let song: [Song]? }
struct Starred2: Decodable { let artist: [Artist]?; let album: [Album]?; let song: [Song]? }
struct TopSongsContainer: Decodable { let song: [Song]? }
struct SimilarSongsContainer: Decodable { let song: [Song]? }
struct GenresContainer: Decodable { let genre: [GenreEntry]? }
struct GenreEntry: Codable { let songCount: Int?; let albumCount: Int?; let value: String }
struct ScanStatus: Decodable { let scanning: Bool; let count: Int? }
struct MusicFolder: Decodable, Identifiable { let id: Int; let name: String? }
struct MusicFoldersContainer: Decodable { let musicFolder: [MusicFolder]? }

// MARK: - Artist Info (Similar Artists)

struct ArtistInfo2Container: Decodable {
    let similarArtist: [SimilarArtist]?
    let biography: String?
    let musicBrainzId: String?
    let lastFmUrl: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
}

struct SimilarArtist: Identifiable, Decodable {
    let id: String
    let name: String
    let coverArt: String?
    let albumCount: Int?
}

// MARK: - Structured Lyrics (OpenSubsonic)

struct LyricsListContainer: Decodable {
    let structuredLyrics: [StructuredLyrics]?
}

struct StructuredLyrics: Decodable {
    let displayArtist: String?
    let displayTitle: String?
    let lang: String?
    let offset: Int?
    let synced: Bool?
    let line: [StructuredLyricsLine]?
    /// OpenSubsonic `songLyrics` **v2**: real word/syllable timings, present only when the
    /// server has them and `enhanced=true` was requested. Servers below v2 simply omit it.
    let cueLine: [StructuredCueLine]?
    /// v2 classification of the track — `main`, a translation, a romanisation…
    let kind: String?
}

/// One line's worth of v2 timing data. `index` points back at the matching entry in `line`.
struct StructuredCueLine: Decodable {
    let index: Int?
    let start: Int?      // milliseconds
    let end: Int?
    let value: String?
    let cue: [StructuredCue]?
    let agentId: String?
}

/// A single timed word or syllable inside a `StructuredCueLine`.
struct StructuredCue: Decodable {
    let start: Int?      // milliseconds
    let end: Int?
    let value: String?
    /// Byte offsets into the parent `cueLine.value`. They disambiguate a repeated token —
    /// which "love" in "Oh love love me tonight" this cue means — and are the only reliable
    /// way to rebuild the line when untimed text sits between timed cues.
    let byteStart: Int?
    let byteEnd: Int?
}

struct StructuredLyricsLine: Decodable {
    let start: Int? // milliseconds
    let value: String?
}

// MARK: - Lyrics

struct LyricsLine: Identifiable {
    let id = UUID()
    let time: TimeInterval?
    let text: String
    /// Real per-word timings from the server when it publishes them (OpenSubsonic
    /// `songLyrics` v2). `nil` means only the line's start time is known, and the karaoke
    /// display falls back to interpolating — see `LyricWordTiming`.
    var words: [LyricWord]? = nil
}

enum LyricsSource: String, CaseIterable {
    case structured = "Synced (OpenSubsonic)"
    case legacy = "Legacy (Artist/Title)"
}

// MARK: - Download

enum DownloadQuality: String, Codable, CaseIterable {
    case low = "Low (128kbps)"
    case medium = "Medium (256kbps)"
    case high = "High (320kbps)"
    case lossless = "Lossless (Original)"

    var bitRate: Int? {
        switch self {
        case .low: return 128
        case .medium: return 256
        case .high: return 320
        case .lossless: return nil
        }
    }
}

enum ExternalServiceProvider: String, Codable, CaseIterable {
    case slskd = "slskd"
}

// MARK: - Downloaded Song

struct DownloadedSong: Codable, Identifiable {
    let id: String
    let song: Song
    let localPath: String
    let downloadDate: Date
    let fileSize: Int64
}

// MARK: - Enums

enum AppLanguage: String, Codable, CaseIterable {
    case english = "en"

    var displayName: String {
        switch self {
        case .english: return "English"
        }
    }

    var localeIdentifier: String { rawValue }
}

enum ListDensity: String, Codable, CaseIterable {
    case compact = "Compact"
    case normal = "Normal"
    case comfortable = "Comfortable"

    var verticalPadding: CGFloat {
        switch self {
        case .compact: return 2
        case .normal: return 4
        case .comfortable: return 8
        }
    }
}

enum LibraryCategory: String, Codable, CaseIterable, Identifiable {
    case songs = "Songs"
    case recentlyPlayed = "Recently Played"
    case albums = "Albums"
    case favourites = "Favorite Songs"
    case frequentlyPlayed = "Frequently Played"
    case random = "Random"
    case genres = "Genres"
    case artists = "Artists"
    case albumArtists = "Album Artists"
    case downloaded = "Downloaded"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .songs: return "music.note"
        case .recentlyPlayed: return "clock.fill"
        case .albums: return "square.stack.fill"
        case .favourites: return "heart.fill"
        case .frequentlyPlayed: return "star.fill"
        case .random: return "shuffle"
        case .genres: return "guitars.fill"
        case .artists: return "music.mic"
        case .albumArtists: return "person.2.fill"
        case .downloaded: return "arrow.down.circle.fill"
        }
    }

    static var defaultEnabled: [LibraryCategory] {
        [.songs, .recentlyPlayed, .albums, .favourites, .frequentlyPlayed, .random]
    }
}

enum HomeSection: String, Codable, CaseIterable, Identifiable {
    case upNext = "Up Next"
    case recentlyPlayed = "Recently Played"
    case recentlyAdded = "Recently Added"
    case frequentlyPlayed = "Frequently Played"
    case randomAlbums = "Random Albums"
    case favoriteSongs = "Favorite Songs"
    case favoriteArtists = "Favorite Artists"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .upNext: return "forward.fill"
        case .recentlyPlayed: return "clock.fill"
        case .recentlyAdded: return "sparkles"
        case .frequentlyPlayed: return "star.fill"
        case .randomAlbums: return "shuffle"
        case .favoriteSongs: return "heart.fill"
        case .favoriteArtists: return "music.mic"
        }
    }

    static var defaultOrder: [HomeSection] {
        [.favoriteArtists, .favoriteSongs, .recentlyAdded, .upNext, .recentlyPlayed, .frequentlyPlayed, .randomAlbums]
    }
}

enum PlaylistSortOrder: String, CaseIterable {
    case name = "Name"
    case songCount = "Song Count"
    case recentlyChanged = "Recently Changed"
    case created = "Date Created"

    var icon: String {
        switch self {
        case .name: return "textformat.abc"
        case .songCount: return "music.note"
        case .recentlyChanged: return "clock"
        case .created: return "calendar"
        }
    }
}

enum RepeatMode: String, Codable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

enum LosslessTranscodeMode: String, Codable, CaseIterable, Identifiable {
    case original = "Original (No transcode)"
    case mp3_320 = "MP3 (320 kbps)"
    case mp3_256 = "MP3 (256 kbps)"
    case mp3_192 = "MP3 (192 kbps)"
    case mp3_128 = "MP3 (128 kbps)"
    case aac_256 = "AAC (256 kbps)"
    case aac_128 = "AAC (128 kbps)"

    var id: String { rawValue }

    var formatIdentifier: String? {
        switch self {
        case .original: return nil
        case .mp3_320, .mp3_256, .mp3_192, .mp3_128: return "mp3"
        case .aac_256, .aac_128: return "aac"
        }
    }

    var bitrate: Int? {
        switch self {
        case .mp3_320: return 320
        case .mp3_256, .aac_256: return 256
        case .mp3_192: return 192
        case .mp3_128, .aac_128: return 128
        case .original: return nil
        }
    }
}
