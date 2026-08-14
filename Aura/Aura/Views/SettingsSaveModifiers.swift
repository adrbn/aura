import SwiftUI

// MARK: - Settings Save Modifier

private struct SettingsSaveModifier1: ViewModifier {
    @State private var s = AppSettings.shared
    func body(content: Content) -> some View {
        content
            .onChange(of: s.streamingQuality) { _, _ in s.save() }
            .onChange(of: s.scrobbleEnabled) { _, _ in s.save() }
            .onChange(of: s.replayGain) { _, _ in s.save() }
            .onChange(of: s.gaplessPlayback) { _, _ in s.save() }
            .onChange(of: s.cacheEnabled) { _, _ in s.save() }
            .onChange(of: s.cacheMaxSize) { _, _ in s.save() }
    }
}

private struct SettingsSaveModifier2: ViewModifier {
    @State private var s = AppSettings.shared
    func body(content: Content) -> some View {
        content
            .onChange(of: s.artworkQuality) { _, _ in s.save() }
            .onChange(of: s.crossfadeSeconds) { _, _ in s.save() }
            .onChange(of: s.downloadQuality) { _, _ in s.save() }
            .onChange(of: s.offlineMode) { _, _ in s.save() }
            .onChange(of: s.betaFeaturesEnabled) { _, _ in s.save() }
            .onChange(of: s.externalServiceProvider) { _, _ in s.save() }
    }
}

private struct SettingsSaveModifier3: ViewModifier {
    @State private var s = AppSettings.shared
    func body(content: Content) -> some View {
        content
            .onChange(of: s.externalServiceURL) { _, _ in s.save() }
            .onChange(of: s.externalServicePort) { _, _ in s.save() }
            .onChange(of: s.showStatsOnHome) { _, _ in s.save() }
            .onChange(of: s.homeTitleStyle) { _, _ in s.save() }
            .onChange(of: s.showServerStatus) { _, _ in s.save() }

            .onChange(of: s.appLanguage) { _, _ in s.save() }
            .onChange(of: s.appAccentColor) { _, _ in s.save() }
            .onChange(of: s.activeTheme) { _, _ in s.save() }
            .onChange(of: s.eqPreset) { _, _ in s.save() }
            .onChange(of: s.eqCustomBands) { _, _ in s.save() }
            .onChange(of: s.showUpNext) { _, _ in s.save() }
            .onChange(of: s.showPlayCounts) { _, _ in s.save() }
            .onChange(of: s.homeSectionOrder) { _, _ in s.save() }
            .onChange(of: s.selectedMusicFolderId) { _, _ in s.save() }
    }
}

private struct SettingsSaveModifier4: ViewModifier {
    @State private var s = AppSettings.shared
    func body(content: Content) -> some View {
        content
            .onChange(of: s.appearanceMode) { _, _ in s.save() }
            .onChange(of: s.landscapeClockEnabled) { _, _ in s.save() }
            .onChange(of: s.displayFont) { _, _ in s.save() }
            .onChange(of: s.betaKaraokeLyrics) { _, _ in s.save() }
            .onChange(of: s.betaLiveLyrics) { _, _ in s.save() }
            .onChange(of: s.alphaAutoHideToolbar) { _, _ in s.save() }
            .onChange(of: s.wrappedShowOnHome) { _, _ in s.save() }
            // Last.fm username/key are NOT auto-saved here: the Last.fm section owns an
            // explicit Save button that validates the key before persisting.
    }
}

extension View {
    func onChangeSettings() -> some View {
        self.modifier(SettingsSaveModifier1())
            .modifier(SettingsSaveModifier2())
            .modifier(SettingsSaveModifier3())
            .modifier(SettingsSaveModifier4())
    }
}
