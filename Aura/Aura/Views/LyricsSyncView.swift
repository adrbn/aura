import SwiftUI

/// Puts a song's lyrics in time by hand, over the same blurred cover as Now Playing. A dot
/// marks the line the next tap places; tap Now as it starts. Lyrics already timed need only a
/// line or two — each tap moves its line and those after it, up to the next tap, so a pause
/// the lyrics didn't know about is one tap after it — and tapping a line plays from just
/// before it. The steps move what's heard now by 0.05 s. What's saved stays on this device
/// and comes before every other source; on the server too, when set up.
struct LyricsSyncView: View {
    let song: Song
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    /// The lines as they were when this opened, blank ones left out: they have no start to
    /// tap, and the lyrics view skips them anyway.
    private let lines: [LyricsLine]
    @State private var retiming: LyricsRetiming
    /// The line the next tap places; nil once the last one is.
    @State private var armed: Int?
    /// Lines in the order they were tapped, for Undo.
    @State private var tapped: [Int] = []
    @State private var backdrop: UIImage?
    @State private var tone = BackdropTone.plain
    @State private var isSaving = false
    @State private var failure: String?
    /// Saved here, but the server's copy failed: closing follows the alert.
    @State private var savedLocally = false
    @State private var confirmRestore = false

    private static let step: TimeInterval = 0.05

    init(song: Song, lines: [LyricsLine]) {
        self.song = song
        let kept = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        self.lines = kept
        var retiming = LyricsRetiming(found: kept.map(\.time))
        retiming.keepsLinesAbove = LyricsOverrides.has(song.id)
        _retiming = State(initialValue: retiming)
    }

    private var accent: Color { AppSettings.shared.activeTheme.accentColor }

    var body: some View {
        let times = retiming.times
        let sung = times.lastIndex { ($0 ?? .infinity) <= player.lyricsTime }
        VStack(spacing: 0) {
            header
            lyrics(sung: sung)
            controls(focus: sung ?? armed ?? 0, times: times)
        }
        .background { background }
        .preferredColorScheme(.dark)
        .onAppear(perform: armFirst)
        .task(id: song.coverArt) { await loadBackdrop() }
        // Another song's lyrics would be timed against this one's.
        .onChange(of: player.currentSong?.id) { _, id in
            if id != song.id { dismiss() }
        }
        .alert(savedLocally ? "Saved on this iPhone only" : "Not saved",
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { if savedLocally { dismiss() } }
        } message: {
            Text(failure ?? "")
        }
        .confirmationDialog("Restore the original timing?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Original Timing", role: .destructive) {
                player.restoreFoundLyrics(for: song)
                dismiss()
            }
        } message: {
            Text("Your timing for this song is deleted and the lyrics are looked up again.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
            CoverArtImage(coverArt: song.coverArt, size: 44, cornerRadius: 6,
                          placeholderName: song.title, placeholderKind: .album)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(song.artist ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if LyricsOverrides.has(song.id) {
                Button { confirmRestore = true } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restore Original Timing")
            }
            Button(action: save) {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Save")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(retiming.hasChanges ? accent : .white.opacity(0.3))
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .glassEffect(.regular, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!retiming.hasChanges || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: Lyrics

    private func lyrics(sung: Int?) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        row(line, index: index, isSung: index == sung)
                            .id(index)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
            }
            .scrollIndicators(.hidden)
            .mask {
                // Lines fade in and out at the edges, as on Now Playing.
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                       .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .onChange(of: armed, initial: true) { _, line in
                guard let line else { return }
                withAnimation(.easeOut(duration: 0.3)) { reader.scrollTo(line, anchor: .center) }
            }
        }
    }

    /// The line sung now in white, the rest dimmed. In the margin, a dot in the accent for
    /// the line the next tap places, a small one for each line tapped.
    private func row(_ line: LyricsLine, index: Int, isSung: Bool) -> some View {
        let isArmed = index == armed
        let isTapped = retiming.anchors[index] != nil
        return Text(line.text)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white.opacity(isSung ? 1 : 0.35))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if isArmed || isTapped {
                    Circle()
                        .fill(isArmed ? accent : .white.opacity(0.4))
                        .frame(width: isArmed ? 8 : 5, height: isArmed ? 8 : 5)
                        .frame(width: 8, height: 8)
                        .offset(x: -17, y: 12)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { arm(index) }
            .animation(.easeOut(duration: 0.2), value: isArmed)
            .animation(.easeOut(duration: 0.2), value: isSung)
            .accessibilityAddTraits(isArmed ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Controls

    private func controls(focus: Int, times: [TimeInterval?]) -> some View {
        VStack(spacing: 18) {
            if retiming.isTimed || !tapped.isEmpty {
                nudger(focus: focus, times: times)
            }

            HStack(spacing: 12) {
                Button(action: undo) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .glassEffect(.regular, in: Circle())
                }
                .buttonStyle(PressScale())
                .disabled(tapped.isEmpty)
                .opacity(tapped.isEmpty ? 0.35 : 1)
                .accessibilityLabel("Undo")

                Button(action: tap) {
                    Text("Now")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(accent.opacity(armed == nil ? 0.35 : 1), in: Capsule())
                }
                .buttonStyle(PressScale())
                .disabled(armed == nil)
                .sensoryFeedback(.impact(weight: .light), trigger: tapped.count)
                .accessibilityHint("Places the marked line where the song is now")
            }

            VStack(spacing: 6) {
                BufferedProgressBar(progress: player.progress, buffer: player.bufferProgress, accentColor: .white,
                                    onSeek: { player.seek(to: $0 * player.duration) }, loading: player.isBuffering)
                    .frame(height: 32)
                HStack {
                    Text(clock(player.currentTime))
                    Spacer()
                    Text("-" + clock(max(0, player.duration - player.currentTime)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }

            HStack(spacing: 48) {
                Button { player.seek(to: max(0, player.currentTime - 5)) } label: {
                    Image(systemName: "gobackward.5").font(.title2)
                }
                .accessibilityLabel("Back 5 seconds")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36))
                        .frame(width: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.seek(to: min(player.duration, player.currentTime + 5)) } label: {
                    Image(systemName: "goforward.5").font(.title2)
                }
                .accessibilityLabel("Forward 5 seconds")
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// How far the line heard now has moved, with steps of 0.05 s either way — for its
    /// section, or every line before any tap.
    private func nudger(focus: Int, times: [TimeInterval?]) -> some View {
        let moved: TimeInterval = if times.indices.contains(focus), let now = times[focus], let was = lines[focus].time {
            now - was
        } else {
            retiming.offset
        }
        return HStack(spacing: 24) {
            stepButton("minus", by: -Self.step, label: "Earlier")
            Text(String(format: "%+.2f s", (moved * 100).rounded() / 100))
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 88)
                .contentTransition(.numericText())
            stepButton("plus", by: Self.step, label: "Later")
        }
    }

    private func stepButton(_ symbol: String, by step: TimeInterval, label: LocalizedStringKey) -> some View {
        Button {
            let focus = retiming.times.lastIndex { ($0 ?? .infinity) <= player.lyricsTime } ?? armed ?? 0
            retiming.nudge(by: step, at: focus)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: Circle())
        }
        .buttonStyle(PressScale())
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    /// The line coming next in the song, or the first when the lyrics have no timing.
    private func armFirst() {
        guard armed == nil, tapped.isEmpty else { return }
        armed = lines.isEmpty ? nil
            : retiming.times.firstIndex { ($0 ?? -.infinity) > player.lyricsTime } ?? 0
    }

    /// Marks the line for the next tap, and plays from a little before where it's expected.
    private func arm(_ index: Int) {
        armed = index
        UISelectionFeedbackGenerator().selectionChanged()
        guard let time = retiming.times[index] else { return }
        player.seek(to: max(0, time - AppSettings.shared.lyricsOffset - 3))
        if !player.isPlaying { player.play() }
    }

    private func tap() {
        guard let line = armed else { return }
        retiming.anchors[line] = player.liveLyricsTime
        tapped.removeAll { $0 == line }
        tapped.append(line)
        armed = line + 1 < lines.count ? line + 1 : nil
    }

    /// Takes the last tap back, and the song to a little before it, to tap it again.
    private func undo() {
        guard let line = tapped.popLast(), let mark = retiming.anchors.removeValue(forKey: line) else { return }
        armed = line
        player.seek(to: max(0, mark - AppSettings.shared.lyricsOffset - 3))
        if !player.isPlaying { player.play() }
    }

    /// Every line where it now starts, its words moved along with it.
    private var timedLines: [LyricsOverrides.Line] {
        zip(lines, retiming.times).compactMap { line, time in
            guard let time else { return nil }
            let moved = time - (line.time ?? time)
            let words = line.time == nil ? nil
                : line.words?.map { LyricWord(id: $0.id, text: $0.text, start: $0.start + moved) }
            return LyricsOverrides.Line(time: time, text: line.text, words: words)
        }
    }

    private func save() {
        let timed = timedLines
        do {
            try player.saveTimedLyrics(timed, for: song)
        } catch {
            AppLogger.shared.log("🎵 Lyrics timing not saved: \(error.localizedDescription)")
            failure = error.localizedDescription
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard LyricsOnServer.isEnabled else { return dismiss() }
        isSaving = true
        Task {
            do {
                try await LyricsOnServer.save(LyricsOverrides.lrc(timed), for: song)
                dismiss()
            } catch {
                AppLogger.shared.log("🎵 Server lyrics timing not written: \(error.localizedDescription)")
                isSaving = false
                savedLocally = true
                failure = error.localizedDescription
            }
        }
    }

    // MARK: Backdrop

    /// Now Playing's backdrop: the cover blurred, deepened as much as white text needs.
    private var background: some View {
        Color.black
            .overlay {
                if let backdrop {
                    Image(uiImage: backdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 130)
                        .scaleEffect(1.5)
                        .saturation(tone.saturation)
                        .overlay(Color.black.opacity(tone.veil))
                    if let vibrant = tone.vibrant {
                        vibrant.opacity(0.4).blendMode(.screen)
                    }
                }
            }
            .drawingGroup()
            .ignoresSafeArea()
    }

    /// The cover Now Playing blurs, from the cache it already filled.
    private func loadBackdrop() async {
        guard let coverArt = song.coverArt else { return }
        let cached = ArtworkCache.shared.image(for: "\(coverArt)_bg")
            ?? ArtworkCache.shared.cachedImageAnySize(forCoverArt: coverArt)
        let fetched: UIImage? = cached == nil
            ? await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: ArtworkCache.thumbSize,
                                                   key: "\(coverArt)_\(ArtworkCache.thumbSize)")
            : nil
        guard let image = cached ?? fetched else { return }
        let found = await Task.detached(priority: .userInitiated) { NowPlayingView.analyseBackdrop(image) }.value
        backdrop = image
        tone = found
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A press that answers at once: the button gives a little under the finger.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
