import SwiftUI

/// The window's options, behind one unobtrusive button.
///
/// A Mac app of this kind does not want a Settings window: almost everything worth changing
/// is something you change *while looking at the thing it affects* — how big the artwork is,
/// how the lyrics are timed against what is playing right now. A menu in the toolbar keeps
/// those a click away and nothing on screen the rest of the time.
struct MacOptionsMenu: View {
    @State private var settings = AppSettings.shared
    @State private var preferences = MacPreferences.shared

    var body: some View {
        Menu {
            Picker("Cover Size", selection: $preferences.coverSize) {
                ForEach(MacCoverSize.allCases) { Text($0.label).tag($0) }
            }

            Divider()

            Picker("Accent", selection: $settings.appAccentColor) {
                ForEach(AppAccentColor.allCases, id: \.self) { colour in
                    Text(colour.rawValue).tag(colour)
                }
            }
            Divider()

            Toggle("Word-by-Word Lyrics", isOn: $settings.betaKaraokeLyrics)
            // In a menu rather than a settings pane precisely because it is judged by ear,
            // against the song playing at that moment.
            Picker("Lyrics Timing", selection: $settings.lyricsOffset) {
                ForEach([-0.6, -0.4, -0.2, -0.1, 0.0, 0.1, 0.2, 0.4, 0.6], id: \.self) { offset in
                    Text(offset == 0 ? "In sync" : String(format: "%+.1f s", offset)).tag(offset)
                }
            }

            Divider()

            Picker("Streaming Quality", selection: $settings.streamingQuality) {
                ForEach(StreamingQuality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Settings")
        // Every control above writes straight into the shared settings object, which is not
        // persisted until asked. One place to do it, rather than nine.
        .onChange(of: settingsFingerprint) { _, _ in settings.save() }
    }

    /// Cheap stand-in for "any of these changed", so one `onChange` can cover the lot.
    private var settingsFingerprint: String {
        [settings.appAccentColor.rawValue,
         String(settings.betaKaraokeLyrics), String(settings.lyricsOffset),
         settings.streamingQuality.rawValue].joined(separator: "|")
    }
}
