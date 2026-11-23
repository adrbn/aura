import SwiftUI

/// The Apple TV app's entry point: the iPhone's engine under an interface made for the
/// remote, three metres from the screen.
@main
struct AuraTVApp: App {
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(serverManager)
                .environment(player)
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                    // Screenshots in the simulator: `-tvDemo` connects the public demo server.
                    if CommandLine.arguments.contains("-tvDemo"), serverManager.servers.isEmpty {
                        serverManager.addServer(ServerConfig(url: "https://demo.navidrome.org", username: "demo",
                                                             password: "demo", friendlyName: "demo.navidrome.org"))
                    }
                    // Silent playback, so screenshots of Now Playing make no sound on the Mac.
                    if CommandLine.arguments.contains("-tvMute") { player.volume = 0 }
                    #endif
                    // The iPhone finds this TV and plays on it, as it does on the Mac.
                    RemoteLink.shared.start()
                    guard let server = serverManager.currentServer else { return }
                    await serverManager.testConnection()
                    LibraryIndex.shared.refreshIfNeeded()
                    #if DEBUG
                    // `-tvPlay` starts random songs, to see Now Playing without the remote.
                    if CommandLine.arguments.contains("-tvPlay"),
                       let songs = try? await SubsonicClient.shared.getRandomSongs(server: server, size: 20) {
                        TVPlayback.shared.play(songs, source: .search(query: ""))
                    }
                    // `-tvSeek N` jumps N seconds in, so the lyrics show mid-song (the simulator plays no audio).
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "-tvSeek"), i + 1 < args.count, let t = TimeInterval(args[i + 1]) {
                        try? await Task.sleep(for: .seconds(5))
                        player.seek(to: t)
                    }
                    #endif
                }
        }
    }
}

/// Starting playback from any page: the queue handed to the player, and Now Playing brought up
/// over everything, as the TV's own music app does.
@MainActor
@Observable
final class TVPlayback {
    static let shared = TVPlayback()
    var showNowPlaying = false

    func play(_ songs: [Song], from index: Int = 0, source: PlaybackSource, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        let player = AudioPlayer.shared
        let list = shuffled ? songs.shuffled() : songs
        let start = shuffled ? 0 : min(index, list.count - 1)
        player.playSong(list[start], fromQueue: list, startIndex: start, source: source)
        showNowPlaying = true
    }
}

struct TVRootView: View {
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var playback = TVPlayback.shared
    @State private var tab = TVRootView.launchTab

    var body: some View {
        Group {
            if serverManager.currentServer == nil {
                TVSetupView()
            } else {
                tabs
            }
        }
        .background(TVBackground())
        .fullScreenCover(isPresented: $playback.showNowPlaying) {
            TVNowPlayingView()
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: 0) {
                NavigationStack { TVHomeView().tvDestinations() }
            }
            Tab("Library", systemImage: "square.stack", value: 1) {
                NavigationStack { TVLibraryView().tvDestinations() }
            }
            Tab(value: 2, role: .search) {
                NavigationStack { TVSearchView().tvDestinations() }
            }
            if player.currentSong != nil {
                // The full player itself, lyrics and controls, not a cover to press a second time.
                Tab("Now Playing", systemImage: "waveform", value: 3) {
                    TVNowPlayingView(inTab: true)
                }
            }
            // The icon alone, like Search: with five named tabs the bar ran past its edge.
            Tab(value: 4) {
                NavigationStack { TVSettingsView() }
            } label: {
                Image(systemName: "gearshape").accessibilityLabel("Settings")
            }
        }
    }

    /// `-tvTab N` opens on tab N in debug builds, for screenshots in the simulator.
    private static var launchTab: Int {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-tvTab"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
        #endif
        return 0
    }
}

/// The phone's tab-root ground: #121212 with the time-of-day glow across the top.
struct TVBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.canvas
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                GlowField(hue: DayHue.hue(at: Date()),
                          time: context.date.timeIntervalSinceReferenceDate,
                          isDark: true)
            }
            .frame(height: 620)
        }
        .ignoresSafeArea()
    }
}
