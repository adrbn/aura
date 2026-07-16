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

struct SiriPlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Toggles playback in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.togglePlayPause() }
        return .result()
    }
}

struct SiriNextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Skips to the next track in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.next() }
        return .result()
    }
}

struct SiriPreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Goes to the previous track in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.previous() }
        return .result()
    }
}

struct SiriShuffleIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle"
    static var description = IntentDescription("Toggles shuffle in Aura.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { AudioPlayer.shared.toggleShuffle() }
        return .result()
    }
}

struct AuraAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
    }
}

#endif
