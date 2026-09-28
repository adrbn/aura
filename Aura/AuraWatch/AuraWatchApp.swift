import SwiftUI

/// Aura on the wrist: a remote for the iPhone's player.
///
/// Three pages side by side — what's playing, its lyrics, what comes next. They swipe
/// sideways so the Digital Crown stays free for the phone's volume on the first page and
/// for scrolling on the other two.
@main
struct AuraWatchApp: App {
    @State private var model = WatchModel()
    @State private var page = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $page) {
                NowPlayingPage(isCurrent: page == 0).tag(0)
                LyricsPage().tag(1)
                UpNextPage().tag(2)
            }
            .tabViewStyle(.page)
            .environment(model)
            .task { model.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refresh() }
            }
        }
    }
}
