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
                .task {
                    PinSync.shared.start()
                    // As the phone opens: the server tried, the queue the phone left picked
                    // up, and the library indexed for search.
                    await serverManager.testConnection()
                    player.resumeQueueFromServer()
                    LibraryIndex.shared.refreshIfNeeded()
                }
                // Leaving the Mac hands the queue to the server, for the phone to pick up.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    player.saveQueueOnServer()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    player.resumeQueueFromServer()
                }
        }
        .defaultSize(width: 1180, height: 760)
        // NOT .hiddenTitleBar. That removes the title bar, and close / minimise / zoom live
        // inside it — they disappear with it and cannot be asked back. MacWindowChrome
        // instead makes an ordinary title bar transparent and lets the content run under it,
        // which looks identical and keeps the buttons.
        .commands { MacCommands(player: player) }
    }
}
