import SwiftUI

struct LandscapeClockView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @State private var currentTime = Date()
    @State private var clockStyle: ClockStyle = .digital
    @State private var backgroundImage: UIImage?
    var lyricsMode: Bool = false

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum ClockStyle: String, CaseIterable {
        case digital = "Digital"
        case analog = "Analog"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background
                backgroundLayer(geo: geo)

                if lyricsMode && !player.lyrics.isEmpty {
                    // Landscape lyrics mode
                    landscapeLyricsContent(geo: geo)
                } else {
                    // Content
                    HStack(spacing: 0) {
                        // Left: Cover art + play control
                        leftPanel(geo: geo)
                            .frame(width: geo.size.width * 0.5)

                        // Right: Clock
                        rightPanel(geo: geo)
                            .frame(width: geo.size.width * 0.5)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)   // nightstand clock: always dark
        .onReceive(timer) { currentTime = $0 }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                let orientation = UIDevice.current.orientation
                if orientation.isPortrait {
                    dismiss()
                }
            }
        }
        .onTapGesture(count: 2) { dismiss() }
        .gesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                clockStyle = clockStyle == .digital ? .analog : .digital
            }
        )
    }

    @ViewBuilder
    private func backgroundLayer(geo: GeometryProxy) -> some View {
        Color.black
            .overlay {
                if let img = backgroundImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 100)
                        .scaleEffect(1.4)
                        .overlay(Color.black.opacity(0.6))
                }
            }
            .clipped()
            .task(id: player.currentSong?.coverArt) {
                await loadBackground()
            }
    }

    @ViewBuilder
    private func leftPanel(geo: GeometryProxy) -> some View {
        let artSize = min(geo.size.height * 0.65, geo.size.width * 0.35)
        VStack(spacing: 16) {
            Spacer()
            if let song = player.currentSong {
                CoverArtAsyncImage(coverArt: song.coverArt, size: artSize)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.9)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

                VStack(spacing: 4) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    Text(song.artist ?? "Unknown Artist")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)

                HStack(spacing: 32) {
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func rightPanel(geo: GeometryProxy) -> some View {
        VStack {
            Spacer()
            if clockStyle == .digital {
                digitalClock(geo: geo)
            } else {
                analogClock(size: min(geo.size.height * 0.6, geo.size.width * 0.35))
            }
            Spacer()
        }
    }

    private func digitalClock(geo: GeometryProxy) -> some View {
        // Scale the clock to the screen instead of a fixed 72pt so it reads large
        // and consistent on every device (iPhone → iPad), and never clips.
        let timeSize = min(geo.size.height * 0.26, geo.size.width * 0.16)
        return VStack(spacing: timeSize * 0.06) {
            Text(currentTime, format: .dateTime.hour().minute())
                .font(.system(size: timeSize, weight: .thin, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(currentTime, format: .dateTime.weekday(.wide).month().day())
                .font(.system(size: max(timeSize * 0.2, 15), weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private func analogClock(size: CGFloat) -> some View {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: currentTime) % 12)
        let minute = Double(calendar.component(.minute, from: currentTime))
        let second = Double(calendar.component(.second, from: currentTime))

        return ZStack {
            // Face
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 2)
                .frame(width: size, height: size)

            // Hour markers
            ForEach(0..<12, id: \.self) { i in
                Rectangle()
                    .fill(.white.opacity(i % 3 == 0 ? 0.6 : 0.25))
                    .frame(width: i % 3 == 0 ? 2.5 : 1.5, height: i % 3 == 0 ? 14 : 8)
                    .offset(y: -size / 2 + 16)
                    .rotationEffect(.degrees(Double(i) * 30))
            }

            // Hour hand
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 4, height: size * 0.25)
                .offset(y: -size * 0.125)
                .rotationEffect(.degrees((hour + minute / 60) * 30))

            // Minute hand
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.white.opacity(0.8))
                .frame(width: 2.5, height: size * 0.35)
                .offset(y: -size * 0.175)
                .rotationEffect(.degrees(minute * 6))

            // Second hand
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor)
                .frame(width: 1.5, height: size * 0.38)
                .offset(y: -size * 0.19)
                .rotationEffect(.degrees(second * 6))

            // Center dot
            Circle()
                .fill(accentColor)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Landscape Lyrics

    @ViewBuilder
    private func landscapeLyricsContent(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer()

            // Centered lyrics
            VStack(spacing: 20) {
                ForEach(visibleLyricLines(), id: \.line.id) { item in
                    if item.isCurrent {
                        Text(item.line.text)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    } else {
                        Text(item.line.text)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white.opacity(item.opacity))
                            .blur(radius: item.blur)
                    }
                }
            }
            .frame(maxWidth: geo.size.width * 0.75)
            .multilineTextAlignment(.center)
            .animation(.easeInOut(duration: 0.3), value: currentLineIndex)

            Spacer()

            // Song info bar at bottom
            if let song = player.currentSong {
                HStack {
                    Text("\(song.title) — \(song.artist ?? "Unknown")")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 40)
    }

    private struct VisibleLine {
        let line: LyricsLine
        let isCurrent: Bool
        let opacity: Double
        let blur: CGFloat
    }

    /// Nearest lyric line before current time, ignoring instrumental gap detection.
    private var nearestLineIndex: Int? {
        guard !player.lyrics.isEmpty else { return nil }
        var last: Int?
        for (i, line) in player.lyrics.enumerated() {
            guard let time = line.time else { continue }
            if time <= player.currentTime { last = i } else { break }
        }
        return last
    }

    private var currentLineIndex: Int? {
        guard let last = nearestLineIndex else { return nil }
        // Gap detection: if we're past the estimated duration of the last line, it's instrumental
        let line = player.lyrics[last]
        guard let lineTime = line.time else { return last }
        let nextTime = (last + 1 < player.lyrics.count) ? player.lyrics[last + 1].time : nil
        let gap = (nextTime ?? player.duration) - lineTime
        let estimatedDuration = min(max(Double(line.text.count) * 0.1, 4.0), 12.0)
        if gap > estimatedDuration + 2.0 && player.currentTime > lineTime + estimatedDuration {
            return nil
        }
        return last
    }

    private func lineProgress(for line: LyricsLine) -> Double {
        guard let time = line.time else { return 0 }
        let nextTime = player.lyrics.first(where: { ($0.time ?? 0) > time })?.time ?? player.duration
        let lineDuration = nextTime - time
        guard lineDuration > 0 else { return 1 }
        let elapsed = player.currentTime - time
        if elapsed < 0 { return 0 }
        if elapsed >= lineDuration { return 1 }
        return elapsed / lineDuration
    }

    private func visibleLyricLines() -> [VisibleLine] {
        guard let idx = currentLineIndex else {
            // Instrumental gap: show 3 lines around anchor, all blurred
            if let anchor = nearestLineIndex {
                var result: [VisibleLine] = []
                if anchor > 0 {
                    result.append(VisibleLine(line: player.lyrics[anchor - 1], isCurrent: false, opacity: 0.15, blur: 4))
                }
                result.append(VisibleLine(line: player.lyrics[anchor], isCurrent: false, opacity: 0.25, blur: 3))
                if anchor + 1 < player.lyrics.count {
                    result.append(VisibleLine(line: player.lyrics[anchor + 1], isCurrent: false, opacity: 0.15, blur: 4))
                }
                return result
            }
            // Before first line, show first 3
            let lines = Array(player.lyrics.prefix(3))
            return lines.enumerated().map { i, line in
                VisibleLine(line: line, isCurrent: false, opacity: [0.5, 0.3, 0.15][min(i, 2)], blur: CGFloat(i) * 2)
            }
        }

        var result: [VisibleLine] = []
        // 1 line before
        if idx > 0 {
            result.append(VisibleLine(line: player.lyrics[idx - 1], isCurrent: false, opacity: 0.25, blur: 2))
        }
        // Current
        result.append(VisibleLine(line: player.lyrics[idx], isCurrent: true, opacity: 1.0, blur: 0))
        // 2 lines after
        for offset in 1...2 {
            let nextIdx = idx + offset
            if nextIdx < player.lyrics.count {
                let op = offset == 1 ? 0.4 : 0.2
                result.append(VisibleLine(line: player.lyrics[nextIdx], isCurrent: false, opacity: op, blur: CGFloat(offset) * 2))
            }
        }
        return result
    }

    private func loadBackground() async {
        guard let coverArt = player.currentSong?.coverArt,
              let server = ServerManager.shared.currentServer,
              let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: ArtworkCache.thumbSize) else {
            backgroundImage = nil
            return
        }
        let key = "\(coverArt)_clock_bg"
        if let cached = ArtworkCache.shared.image(for: key) {
            await MainActor.run { backgroundImage = cached }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                ArtworkCache.shared.store(img, for: key)
                await MainActor.run { backgroundImage = img }
            }
        } catch { AppLogger.shared.log("❌ Clock background image load failed: \(error.localizedDescription)") }
    }
}
