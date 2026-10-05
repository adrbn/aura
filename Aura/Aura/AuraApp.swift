import SwiftUI
import CarPlay

class AppDelegate: NSObject, UIApplicationDelegate {
    /// Stored when iOS relaunches us to deliver background download events;
    /// called by DownloadManager once the session has finished processing them.
    static var backgroundSessionCompletionHandler: (() -> Void)?

    /// Vends the scene configuration. SwiftUI's generated Info.plist wipes the custom
    /// `UISceneConfigurations`, so the CarPlay scene must be registered here in code —
    /// otherwise CarPlay connects to an empty (black) scene. The phone window role falls
    /// through to a plain configuration that SwiftUI's `WindowGroup` drives as usual.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// Always upright: the landscape clock turns its own content rather than the window.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        AppDelegate.backgroundSessionCompletionHandler = completionHandler
        // Touching the singleton recreates the background session so the
        // pending delegate events (finished downloads) get delivered.
        _ = DownloadManager.shared
    }
}

@main
struct AuraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var serverManager = ServerManager.shared
    @State private var audioPlayer = AudioPlayer.shared
    @State private var appSettings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false
    @State private var showSplash = true
    @State private var showOnboarding = false
    /// True during first-launch onboarding — keeps ContentView hidden behind splash
    @State private var isFirstLaunchFlow = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    init() {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
        applyThemeAppearance()
        WatchLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(serverManager)
                    .environment(audioPlayer)
                    .preferredColorScheme(appSettings.appearanceMode.colorScheme)
                    .tint(appSettings.activeTheme.accentColor)
                    .environment(\.appAccentColor, appSettings.activeTheme.accentColor)
                    .environment(\.locale, Locale(identifier: appSettings.appLanguage.localeIdentifier))
                    .onChange(of: scenePhase) { oldPhase, newPhase in
                        // No auto-open of NowPlayingView on return from background.
                        // Dynamic Island / Control Center / Lock Screen taps already
                        // trigger isShowingNowPlaying via remote command handlers.

                        // Persist the session (song + queue + live position) as soon as we
                        // leave the foreground, so a cold relaunch resumes where we were —
                        // iOS may terminate a backgrounded app with no further callback.
                        if newPhase == .inactive || newPhase == .background {
                            audioPlayer.persistPlaybackState()
                        }
                        // Back in the app: online or offline is decided again, from the
                        // connection as it is now, not as it was when the app was left.
                        if newPhase == .background {
                            wasInBackground = true
                            audioPlayer.saveQueueOnServer()
                        } else if newPhase == .active && wasInBackground {
                            wasInBackground = false
                            Task { await serverManager.settleModeOnOpen() }
                        }
                    }
                    .onChange(of: appSettings.activeTheme) { _, _ in
                        applyThemeAppearance()
                        forceUIKitRefresh()
                    }
                    .onChange(of: appSettings.appAccentColor) { _, accent in
                        // Not for a custom colour: it's set from inside the colour picker,
                        // and re-mounting the window's views under it would close it.
                        if accent != .custom { forceUIKitRefresh() }
                    }

                if showSplash {
                    SplashScreen()
                        .transition(.opacity.animation(.easeOut(duration: 0.8)))
                        .zIndex(1)
                }
            }
            // Opens online if the server answers, offline if it doesn't — decided while the
            // splash is up, so the app usually appears in the right mode from the start.
            .task { await serverManager.settleModeOnOpen() }
            .task {
                // Pinned playlists follow you between devices; start listening for the
                // Mac's changes before anything can touch them here.
                PinSync.shared.start()
                // Spoken shortcut phrases match a parameter only against values handed to
                // the system in advance, so the vocabulary has to be refreshed whenever the
                // library might have changed — a playlist made on the web will not be
                // sayable until this runs.
                AuraAppShortcuts.updateAppShortcutParameters()
                // Wordmark finishes its entrance at ~1.5s (0.3s delay + 1.2s ease); hold a
                // beat past that, then fade. 2.5s felt draggy.
                try? await Task.sleep(for: .seconds(1.8))
                if isFirstLaunchFlow {
                    // First launch: show onboarding immediately, keep splash behind it
                    showOnboarding = true
                    // Small delay then fade splash so onboarding aurora is seamless
                    try? await Task.sleep(for: .seconds(0.3))
                    showSplash = false
                } else {
                    showSplash = false
                }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    isFirstLaunchFlow = false
                }
                .environment(serverManager)
                .environment(audioPlayer)
                .interactiveDismissDisabled() // Prevent swipe-to-dismiss
            }
        }
    }

    private func applyThemeAppearance() {
        let theme = AppSettings.shared.activeTheme

        // Display face for navigation titles.
        let displayLarge = AppTypography.uiDisplay(34)
        let displayInline = AppTypography.uiDisplay(17)

        if theme.usePureBlack {
            let black = UIColor.black
            UITableView.appearance().backgroundColor = black
            UICollectionView.appearance().backgroundColor = black
            UINavigationBar.appearance().barTintColor = black
            // Tab bar: no UIKit overrides — iOS 26 liquid glass handles it
            let navBarAppearance = UINavigationBarAppearance()
            navBarAppearance.configureWithOpaqueBackground()
            navBarAppearance.backgroundColor = black
            navBarAppearance.titleTextAttributes = [.foregroundColor: UIColor.white, .font: displayInline]
            navBarAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white, .font: displayLarge]
            UINavigationBar.appearance().standardAppearance = navBarAppearance
            let scrollEdge = UINavigationBarAppearance()
            scrollEdge.configureWithTransparentBackground()
            scrollEdge.titleTextAttributes = [.foregroundColor: UIColor.white, .font: displayInline]
            scrollEdge.largeTitleTextAttributes = [.foregroundColor: UIColor.white, .font: displayLarge]
            UINavigationBar.appearance().scrollEdgeAppearance = scrollEdge
        } else {
            UITableView.appearance().backgroundColor = nil
            UICollectionView.appearance().backgroundColor = nil
            UINavigationBar.appearance().barTintColor = nil
            let navBarAppearance = UINavigationBarAppearance()
            navBarAppearance.configureWithDefaultBackground()
            navBarAppearance.titleTextAttributes = [.font: displayInline]
            navBarAppearance.largeTitleTextAttributes = [.font: displayLarge]
            UINavigationBar.appearance().standardAppearance = navBarAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        }
    }

    private func forceUIKitRefresh() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                for view in window.subviews {
                    view.removeFromSuperview()
                    window.addSubview(view)
                }
            }
        }
    }
}

struct SplashScreen: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Drifting aurora blobs in the icon's pink, deliberately soft: pink is the
            // icon's ACCENT, never the field. A saturated pink background reads as a
            // different brand — and it is what the white wordmark would otherwise need.
            // These sit below the gold originals' opacities for that reason.
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    // Top-left rose glow
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.45, blue: 0.52).opacity(0.60),
                                    Color(red: 1.0, green: 0.25, blue: 0.31).opacity(0.28),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 220
                            )
                        )
                        .frame(width: 440, height: 440)
                        .offset(
                            x: -80 + CGFloat(sin(t * 0.4)) * 30,
                            y: -200 + CGFloat(cos(t * 0.3)) * 25
                        )
                        .scaleEffect(appeared ? 1.15 + CGFloat(sin(t * 0.5)) * 0.05 : 0.6)

                    // Center-right rose glow
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.35, blue: 0.45).opacity(0.46),
                                    Color(red: 0.95, green: 0.20, blue: 0.35).opacity(0.20),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 30,
                                endRadius: 200
                            )
                        )
                        .frame(width: 380, height: 380)
                        .offset(
                            x: 100 + CGFloat(cos(t * 0.35)) * 25,
                            y: 50 + CGFloat(sin(t * 0.45)) * 30
                        )
                        .scaleEffect(appeared ? 1.1 + CGFloat(cos(t * 0.4)) * 0.05 : 0.6)

                    // Bottom soft blush
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.55, blue: 0.60).opacity(0.34),
                                    Color(red: 0.90, green: 0.30, blue: 0.40).opacity(0.14),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 10,
                                endRadius: 180
                            )
                        )
                        .frame(width: 360, height: 360)
                        .offset(
                            x: -40 + CGFloat(sin(t * 0.5)) * 20,
                            y: 250 + CGFloat(cos(t * 0.35)) * 20
                        )
                        .scaleEffect(appeared ? 1.2 + CGFloat(sin(t * 0.3)) * 0.06 : 0.6)

                    // Extra subtle highlight glow — adds depth
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.78, blue: 0.82).opacity(0.20),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 10,
                                endRadius: 150
                            )
                        )
                        .frame(width: 300, height: 300)
                        .offset(
                            x: CGFloat(cos(t * 0.6)) * 60,
                            y: -50 + CGFloat(sin(t * 0.4)) * 50
                        )
                        .scaleEffect(appeared ? 1.0 : 0.4)
                }
                .blur(radius: 65)
            }
            .animation(.easeOut(duration: 1.8), value: appeared)

            // Film grain overlay
            GrainOverlay()
                .opacity(0.08)
                .blendMode(.overlay)
                .ignoresSafeArea()

            // "aura" text
            Text("aura")
                .font(AppTypography.display(52, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .opacity(appeared ? 1.0 : 0.0)
                .scaleEffect(appeared ? 1.0 : 0.85)
                .animation(.easeOut(duration: 1.2).delay(0.3), value: appeared)
        }
        .ignoresSafeArea()
        .onAppear { appeared = true }
    }
}

/// Procedural film grain using a Canvas
struct GrainOverlay: View {
    @State private var seed: UInt64 = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { timeline in
            Canvas { context, size in
                let w = Int(size.width)
                let h = Int(size.height)
                let step = 4 // pixel step for performance
                var rng = SplitMix64(state: UInt64(timeline.date.timeIntervalSince1970 * 1000))
                for y in stride(from: 0, to: h, by: step) {
                    for x in stride(from: 0, to: w, by: step) {
                        let brightness = Double(rng.next() % 256) / 255.0
                        context.fill(
                            Path(CGRect(x: x, y: y, width: step, height: step)),
                            with: .color(.white.opacity(brightness))
                        )
                    }
                }
            }
        }
    }
}

/// Fast PRNG for grain noise
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z = z ^ (z >> 31)
        return z
    }
}
