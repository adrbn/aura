import AppIntents

struct PlayPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description: IntentDescription = "Toggles playback"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { AudioPlayer.shared.togglePlayPause() }
        #endif
        return .result()
    }
}

struct NextTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = "Skips to next track"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { AudioPlayer.shared.next() }
        #endif
        return .result()
    }
}

struct PreviousTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = "Goes to previous track"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { AudioPlayer.shared.previous() }
        #endif
        return .result()
    }
}

// MARK: - Siri App Shortcuts (app target only)
//
// Discoverable AppIntents + an AppShortcutsProvider so playback can be driven
// hands-free: "Hey Siri, pause Aura", "next track in Aura", "shuffle Aura".
// Kept out of the widget target, which uses the LiveActivityIntents above.
#if !WIDGET_EXTENSION

// Every playback intent below conforms to `AudioPlaybackIntent` rather than plain
// `AppIntent`.
//
// That protocol is the contract that lets an intent run in the background AND take the
// audio session. A plain `AppIntent` is allowed to run but has no standing to start or
// resume audio, so "Play Aura" with the app closed was at best unreliable.
// `AudioStartingIntent` is its stricter form, for the one intent here that begins playback
// from nothing.
//
// `openAppWhenRun` stays false throughout: bringing the app to the front to press play is
// exactly what asking out loud was meant to avoid.

/// The only one that can answer from cold, hence `AudioStartingIntent`.
struct SiriPlayIntent: AudioStartingIntent {
    static var title: LocalizedStringResource = "Play Music"
    static var description = IntentDescription("Resumes Aura, or starts something if nothing is loaded.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await AudioPlayer.shared.playSomething()
        return .result()
    }
}

struct SiriPlayPauseIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Toggles playback in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.togglePlayPause() }
        return .result()
    }
}

struct SiriNextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Skips to the next track in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.next() }
        return .result()
    }
}

struct SiriPreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Goes to the previous track in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.previous() }
        return .result()
    }
}

struct SiriShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Shuffle"
    static var description = IntentDescription("Toggles shuffle in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.toggleShuffle() }
        return .result()
    }
}

struct SiriRepeatIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Repeat"
    static var description = IntentDescription("Cycles repeat in Aura: off, all, then one.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run {
            let player = AudioPlayer.shared
            player.repeatMode = player.repeatMode.next
        }
        return .result()
    }
}

/// Favouriting touches the library, not the audio session, so a plain `AppIntent` is the
/// honest conformance — claiming playback rights it does not need would be worse, not safer.
struct SiriFavouriteIntent: AppIntent {
    static var title: LocalizedStringResource = "Favourite Current Song"
    static var description = IntentDescription("Adds the song playing in Aura to your favourites.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.toggleFavorite() }
        return .result()
    }
}

struct AuraAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SiriPlayIntent(),
            phrases: [
                "Play \(.applicationName)",
                "Play music on \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SiriPlayPauseIntent(),
            phrases: [
                "Play or pause \(.applicationName)",
                "Pause \(.applicationName)",
                "Resume \(.applicationName)"
            ],
            shortTitle: "Play / Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: SiriNextTrackIntent(),
            phrases: [
                "Skip in \(.applicationName)",
                "Next track in \(.applicationName)",
                "Play the next song in \(.applicationName)"
            ],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: SiriPreviousTrackIntent(),
            phrases: [
                "Previous track in \(.applicationName)",
                "Go back a track in \(.applicationName)"
            ],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: SiriShuffleIntent(),
            phrases: [
                "Shuffle \(.applicationName)",
                "Toggle shuffle in \(.applicationName)"
            ],
            shortTitle: "Shuffle",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: SiriRepeatIntent(),
            phrases: [
                "Repeat in \(.applicationName)",
                "Change repeat in \(.applicationName)"
            ],
            shortTitle: "Repeat",
            systemImageName: "repeat"
        )
        // The two parameterised ones. A spoken phrase resolves its parameter only against
        // the values `suggestedEntities()` supplied beforehand, which is why playlists and
        // recent albums work by voice while the library at large does not — and why both
        // are still fully usable by name in the Shortcuts app, where you type it.
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play the \(\.$playlist) playlist in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play the album \(\.$album) in \(.applicationName)",
                "Play \(\.$album) album in \(.applicationName)"
            ],
            shortTitle: "Play Album",
            systemImageName: "square.stack"
        )
        AppShortcut(
            intent: SiriFavouriteIntent(),
            phrases: [
                "Favourite this in \(.applicationName)",
                "Favorite this song in \(.applicationName)",
                "Like this in \(.applicationName)"
            ],
            shortTitle: "Favourite",
            systemImageName: "heart.fill"
        )
    }
}

#endif
