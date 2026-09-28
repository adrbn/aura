import SwiftUI

/// Aura on the wrist: a remote for the iPhone's player.
///
/// One screen at the root — what's playing, its lyrics a mode of it — with the library pushed
/// from one top corner and the queue from a bottom one, so the Digital Crown has one job at
/// a time: the phone's volume, the lyrics' lines, a list's scroll.
@main
struct AuraWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: Bindable(model).path) {
                NowPlayingPage()
            }
            .environment(model)
            .task { model.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refresh() }
            }
        }
    }
}
