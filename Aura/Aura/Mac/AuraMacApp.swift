import SwiftUI

/// The Mac app's entry point.
///
/// Deliberately its own target rather than Catalyst: everything below the interface —
/// `SubsonicClient`, `AudioPlayer`, `ImageLoader`, `MixGenerator`, `EqualizerManager` — is
/// the same code the iPhone app runs, while the interface itself is written for a window
/// with a sidebar, a table and a keyboard, which an iPad layout stretched to 1400pt is not.
@main
struct AuraMacApp: App {
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(serverManager)
                .environment(player)
                .frame(minWidth: 900, minHeight: 560)
                .task { PinSync.shared.start() }
        }
        .defaultSize(width: 1180, height: 760)
        // The sidebar is the app's own navigation; the system title bar would only
        // duplicate it.
        .windowStyle(.hiddenTitleBar)
        .commands { MacCommands(player: player) }
    }
}
