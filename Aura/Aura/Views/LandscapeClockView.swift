import SwiftUI

/// The phone on its side, on a nightstand or a desk: the song and a large clock, or the
/// lyrics, big.
///
/// The interface itself never rotates. The view turns its own content a quarter turn to
/// face the way the phone is held. Letting iOS rotate the window meant Now Playing was laid
/// out again in landscape under a cover sliding up from the bottom of a screen that was
/// turning at the same time, and closing it on its side left Now Playing squeezed into
/// landscape. Turned here, it comes and goes as a fade, and follows the phone from one side
/// to the other.
struct LandscapeClockView: View {
    /// Which side the phone lies on, to start with.
    let orientation: UIDeviceOrientation
    let lyricsMode: Bool
    /// Closes the view — without the slide a dismissal plays.
    let close: () -> Void

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var translator = LyricsTranslator.shared
    @State private var currentTime = Date()
    @State private var backgroundImage: UIImage?
    /// Quarter turns: +90° with the phone's top to the left, -90° with it to the right.
    @State private var angle: Double = 90
    @State private var showsLyrics = false
    @State private var isShown = false
    @AppStorage("landscapeClockStyle") private var clockStyle: ClockStyle = .digital

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum ClockStyle: String {
        case digital, analog
    }

    /// Clear of the Dynamic Island, whichever side it is on.
    private static let sideInset: CGFloat = 60
    private static let fade = Animation.easeOut(duration: 0.25)

    var body: some View {
        GeometryReader { geo in
            // The content laid out on its side: the screen's height across, its width down.
            let size = CGSize(width: geo.size.height, height: geo.size.width)
            ZStack {
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                    // A double tap anywhere the content leaves empty closes it, as before.
                    .onTapGesture(count: 2) { leave() }
                content(size: size)
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(angle))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .ignoresSafeArea()
        .opacity(isShown ? 1 : 0)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)   // nightstand clock: always dark
        .onReceive(timer) { currentTime = $0 }
        .onAppear {
            angle = Self.angle(for: orientation) ?? 90
            showsLyrics = lyricsMode && hasSyncedLyrics
            withAnimation(Self.fade) { isShown = true }
            keepAwakeIfCharging()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let now = UIDevice.current.orientation
            if now == .portrait {
                leave()
            } else if let turned = Self.angle(for: now), turned != angle {
                withAnimation(.smooth(duration: 0.45)) { angle = turned }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            keepAwakeIfCharging()
        }
        .task(id: player.currentSong?.coverArt) { await loadBackground() }
    }

    private static func angle(for orientation: UIDeviceOrientation) -> Double? {
        switch orientation {
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        default: return nil
        }
    }

    private func leave() {
        withAnimation(Self.fade) { isShown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            close()
        }
    }

    /// On a charger the phone is a clock, and stays lit; on battery it sleeps as it always
    /// does rather than drain overnight.
    private func keepAwakeIfCharging() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        UIApplication.shared.isIdleTimerDisabled = state == .charging || state == .full
    }

    // MARK: - Layout

    private var background: some View {
        Color.black
            .overlay {
                if let img = backgroundImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 100)
                        .scaleEffect(1.4)
                        .overlay(Color.black.opacity(0.6))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: backgroundImage)
            .clipped()
    }

    private func content(size: CGSize) -> some View {
        ZStack {
            if showsLyrics && hasSyncedLyrics {
                // A tap anywhere goes back to the clock.
                LandscapeLyrics(size: size)
                    .contentShape(Rectangle())
                    .onTapGesture { showsLyrics = false }
                    .transition(.opacity)
            } else {
                // The time first, as a bedside clock reads; the song beside it.
                HStack(spacing: 0) {
                    clockPanel(size: size)
                        .frame(width: (size.width - Self.sideInset * 2) * 0.58)
                    songPanel(size: size)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Self.sideInset)
                .transition(.opacity)
            }
        }
        .animation(Self.fade, value: showsLyrics)
    }

    /// One line at a time needs to know which line: lyrics without timing stay off.
    private var hasSyncedLyrics: Bool { player.lyrics.contains { $0.time != nil } }

    private func songPanel(size: CGSize) -> some View {
        let artSize = min(size.height * 0.34, size.width * 0.17)
        return VStack(spacing: 0) {
            if let song = player.currentSong {
                CoverArtAsyncImage(coverArt: song.coverArt, size: artSize)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.94)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: player.isPlaying)
                    // The cover opens the lyrics.
                    .onTapGesture { if hasSyncedLyrics { showsLyrics = true } }
                    .accessibilityAddTraits(hasSyncedLyrics ? .isButton : [])
                    .accessibilityHint(hasSyncedLyrics ? "Shows the lyrics" : "")

                VStack(spacing: 3) {
                    Text(song.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(song.artist ?? String(localized: "Unknown Artist"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .frame(width: artSize + 60)
                .padding(.top, 18)

                progress
                    .frame(width: artSize)
                    .padding(.top, 22)

            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Where the song is, to read at a glance — not a slider to catch by mistake.
    private var progress: some View {
        let fraction = player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
        return GeometryReader { bar in
            Capsule().fill(.white.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.75))
                        .frame(width: bar.size.width * fraction)
                }
        }
        .frame(height: 3)
    }

    /// The time, digital or with hands; a tap on it changes which, and it's remembered.
    private func clockPanel(size: CGSize) -> some View {
        Group {
            switch clockStyle {
            case .digital: digitalClock(size: size)
            case .analog: analogClock(diameter: min(size.height * 0.6, size.width * 0.32))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Self.fade) { clockStyle = clockStyle == .digital ? .analog : .digital }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Switches between a digital and an analog clock")
    }

    private func digitalClock(size: CGSize) -> some View {
        // Scaled to the screen, so it reads large on every device and never clips.
        let timeSize = min(size.height * 0.3, size.width * 0.14)
        return VStack(spacing: 4) {
            Text(currentTime, format: .dateTime.hour().minute())
                .font(.system(size: timeSize, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: currentTime.formatted(.dateTime.hour().minute()))
            Text(currentTime, format: .dateTime.weekday(.wide).month().day())
                .font(.system(size: max(timeSize * 0.16, 15), weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    private func analogClock(diameter: CGFloat) -> some View {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: currentTime) % 12)
        let minute = Double(calendar.component(.minute, from: currentTime))
        let second = Double(calendar.component(.second, from: currentTime))

        return ZStack {
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 2)
            ForEach(0..<12, id: \.self) { i in
                Rectangle()
                    .fill(.white.opacity(i % 3 == 0 ? 0.6 : 0.25))
                    .frame(width: i % 3 == 0 ? 2.5 : 1.5, height: i % 3 == 0 ? 14 : 8)
                    .offset(y: -diameter / 2 + 16)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            hand(width: 4, length: diameter * 0.25, colour: .white)
                .rotationEffect(.degrees((hour + minute / 60) * 30))
            hand(width: 2.5, length: diameter * 0.35, colour: .white.opacity(0.8))
                .rotationEffect(.degrees(minute * 6))
            hand(width: 1.5, length: diameter * 0.38, colour: accentColor)
                .rotationEffect(.degrees(second * 6))
            Circle().fill(accentColor).frame(width: 8, height: 8)
        }
        .frame(width: diameter, height: diameter)
    }

    private func hand(width: CGFloat, length: CGFloat, colour: Color) -> some View {
        RoundedRectangle(cornerRadius: width / 2)
            .fill(colour)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
    }

    /// The cover for the blurred background, from the artwork cache — so it's there offline
    /// too, which the direct download it used to make never was.
    private func loadBackground() async {
        guard let coverArt = player.currentSong?.coverArt else {
            backgroundImage = nil
            return
        }
        if let cached = ArtworkCache.shared.cachedImageAnySize(forCoverArt: coverArt) {
            backgroundImage = cached
            return
        }
        let size = ArtworkCache.thumbSize
        let image = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: size,
                                                         key: "\(coverArt)_\(size)")
        if !Task.isCancelled { backgroundImage = image }
    }
}

// MARK: - Lyrics, on its side

/// The sung line alone in the middle, the one before above and the next below, quiet,
/// blurred and well apart. A whole column read as a wall of text from across a room.
private struct LandscapeLyrics: View {
    let size: CGSize

    @Environment(AudioPlayer.self) private var player
    @State private var translator = LyricsTranslator.shared
    @State private var appSettings = AppSettings.shared

    private static let motion = Animation.smooth(duration: 0.6)

    var body: some View {
        let (anchor, sung) = position
        let gap = size.height * 0.3
        ZStack {
            ForEach(max(anchor - 1, 0)...min(anchor + 1, player.lyrics.count - 1), id: \.self) { index in
                let isCurrent = index == anchor && sung
                line(player.lyrics[index], isCurrent: isCurrent)
                    .scaleEffect(isCurrent ? 1 : 0.7)
                    .opacity(isCurrent ? 1 : 0.28)
                    .blur(radius: isCurrent ? 0 : 3)
                    .offset(y: CGFloat(index - anchor) * gap)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 90)
        .frame(width: size.width, height: size.height)
        .animation(Self.motion, value: anchor)
        .animation(Self.motion, value: sung)
    }

    private func line(_ line: LyricsLine, isCurrent: Bool) -> some View {
        VStack(spacing: 6) {
            Text(line.text)
                // One size for every line, as in portrait: a line set smaller re-wraps
                // when it becomes the sung one. The neighbours are scaled down instead.
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)
            if isCurrent, appSettings.translateLyrics,
               let translation = translator.lines[line.text], !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// The line to centre on — the last one reached, or the first before any — and
    /// whether it is being sung now, rather than past in an instrumental break.
    private var position: (Int, Bool) {
        var last: Int?
        for (i, line) in player.lyrics.enumerated() {
            guard let time = line.time else { continue }
            if time <= player.currentTime { last = i } else { break }
        }
        guard let last, let lineTime = player.lyrics[last].time else { return (0, false) }
        let next = last + 1 < player.lyrics.count ? player.lyrics[last + 1].time : nil
        let gap = (next ?? player.duration) - lineTime
        let sung = min(max(Double(player.lyrics[last].text.count) * 0.1, 4), 12)
        if gap > sung + 2, player.currentTime > lineTime + sung { return (last, false) }
        return (last, true)
    }
}
