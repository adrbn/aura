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
