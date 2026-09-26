import SwiftUI
import AVKit
import AVFoundation
import Translation

struct NowPlayingView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var appSettings = AppSettings.shared
    @State private var serverManager = ServerManager.shared
    @State private var translator = LyricsTranslator.shared
    @State private var showLyrics = false
    @State private var backgroundImage: UIImage?
    @State private var vibrantOverlayColor: Color?
    @State private var showFileInfo = false
    @State private var showClockMode = false
    @State private var showAddToPlaylist = false
    @State private var showEqualizer = false
    @State private var navAlbumId: String?
    @State private var trackedLyricId: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var isUserScrolling = false
    @State private var scrollReturnTask: Task<Void, Never>?
    @State private var recenterTask: Task<Void, Never>?
    @State private var previousSongId: String?
    @State private var coverDragOffset: CGFloat = 0
    @State private var showSleepTimerSheet = false
    @State private var selectedSleepMinutes: Int = 15
    @State private var coverDragAxis: CoverDragAxis = .undecided
    @State private var showCredits = false
    @State private var showShareSheet = false
    @State private var showRadioExistsDialog = false
    @State private var existingRadioPlaylistId: String?
    @State private var existingRadioPlaylistName: String = ""
    @State private var currentLineIndex: Int?
    @State private var nearestLineIndex: Int?
    @State private var dismissTask: Task<Void, Never>?
    /// ALPHA auto-hide toolbar: whether the options bar is currently revealed, and the
    /// timer that retracts it again.
    @State private var toolbarRevealed = false
    @State private var toolbarHideTask: Task<Void, Never>?
    /// Height of the artwork-plus-title region, captured from the normal state and then held
    /// constant so switching to lyrics cannot move anything above or below it.
    @State private var mediaRegionHeight: CGFloat?
    /// Natural height of the title block, so collapsing it for the lyrics can animate.
    @State private var songInfoHeight: CGFloat?

    /// Side inset shared by the artwork, the title block, the transport row and the
    /// options bar — they must stay on the same vertical guides.
    private let horizontalPadding: CGFloat = 30

    /// The artwork once it has shrunk into the lyrics header, and the gap to the title
    /// beside it.
    private static let lyricsArtSize: CGFloat = 44
    private static let lyricsTitleGap: CGFloat = 12
    /// What the translate button takes from the end of the lyrics header.
    private static let translateButtonRoom: CGFloat = 44

    private enum CoverDragAxis { case undecided, horizontal, vertical }

    private var accentColor: Color { appSettings.activeTheme.accentColor }

    /// Radio needs the server — greyed out in offline mode or without any network.
    private var isEffectivelyOffline: Bool {
        appSettings.offlineMode || !serverManager.hasNetwork
    }

    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top) ?? 59
    }

    private var safeBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom) ?? 34
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if let song = player.currentSong {
                    ZStack {
                        cachedBackground(for: song, in: geo)
                        playerView(song: song, geo: geo)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                    .cornerRadius(dragOffset > 0 ? min(dragOffset / 3, 30) : 0)
                    .offset(y: dragOffset)
                    // Immersive artwork canvas: always dark, whatever the app appearance.
                    // Pinned here (not on the NavigationStack) so the sheets presented from
                    // this screen — queue, info, credits, EQ — still follow the user's setting.
                    .preferredColorScheme(.dark)
                }
            }
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .gesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .global)
                    .onChanged { value in
                        guard coverDragAxis == .undecided else { return }
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        guard coverDragAxis == .undecided else { return }
                        if value.translation.height > 150 || value.predictedEndTranslation.height > 300 {
                            withAnimation(.easeOut(duration: 0.25)) { dragOffset = 1000 }
                            scheduleDragDismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                        }
                    }
            )
            .navigationDestination(item: $navAlbumId) { albumId in
                AlbumDetailView(albumId: albumId)
            }
            .onAppear {
                AppDelegate.allowLandscape = AppSettings.shared.landscapeClockEnabled
                // Start preloading playlist membership and song links for current song
                if let song = player.currentSong {
                    if !song.isPreview { PlaylistMembershipCache.shared.preloadMembership(for: song.id) }
                    SongLinkService.shared.preloadLinks(title: song.title, artist: song.artist ?? "")
                }
            }
            .onDisappear {
                AppDelegate.allowLandscape = false
                scrollReturnTask?.cancel()
                dismissTask?.cancel()
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
            }
        }
        .presentationBackground(.clear)
        // Every sheet that arrives is looked at for its language — and translated when the
        // reader has asked for translations — whether or not the lyrics are open yet.
        .task(id: player.lyrics.map(\.text)) {
            await translator.show(songId: player.currentSong?.id,
                                  song: LyricsSong(title: player.currentSong?.title,
                                                   artist: player.currentSong?.artist),
                                  texts: player.lyrics.map(\.text),
                                  translating: appSettings.translateLyrics)
        }
        .translationTask(translator.configuration) { session in
            await translator.translate(with: session)
        }
        .onChange(of: player.currentSong?.id) { oldId, newId in
            previousSongId = oldId
            if showLyrics {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if player.lyrics.isEmpty {
                        withAnimation(.easeInOut(duration: 0.35)) { showLyrics = false }
                    }
                }
            }
            // Pre-fetch playlist membership and song links for the new song in background
            if let newId, let song = player.currentSong {
                if !song.isPreview { PlaylistMembershipCache.shared.preloadMembership(for: newId) }
                PlaylistMembershipCache.shared.trimCache(keeping: newId)
                SongLinkService.shared.preloadLinks(title: song.title, artist: song.artist ?? "")
                SongLinkService.shared.trimCache(keeping: song.title, artist: song.artist ?? "")
            }
        }
        .sheet(isPresented: Binding(
            get: { player.isShowingQueue },
            set: { player.isShowingQueue = $0 }
        )) {
            QueueView()
        }
        .sheet(isPresented: $showFileInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.currentSong {
                AddToPlaylistView(song: song)
            }
        }
        .sheet(isPresented: $showCredits) {
            if let song = player.currentSong {
                SongCreditsSheet(song: song)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let song = player.currentSong {
                SongShareSheet(song: song)
            }
        }
        .sheet(isPresented: $showEqualizer) {
            EqualizerView()
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            sleepTimerPickerSheet
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .confirmationDialog("A radio already exists", isPresented: $showRadioExistsDialog) {
            if let savedId = existingRadioPlaylistId {
                // Saved playlist on server
                Button("View Saved Playlist") {
                    player.pendingPlaylistId = savedId
                    player.isShowingNowPlaying = false
                }
            } else {
                // In-memory radio
                Button("View Existing Radio") {
                    player.pendingRadioOpen = true
                    player.isShowingNowPlaying = false
                }
            }
            Button("Generate New Radio") {
                if let current = player.currentSong {
                    player.startRadioFromSong(current)
                    player.isShowingNowPlaying = false
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\"\(existingRadioPlaylistName)\" already exists. View it or generate a new one?")
        }
        .fullScreenCover(isPresented: $showClockMode) {
            LandscapeClockView(lyricsMode: showLyrics)
                .environment(player)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Physical-rotation notifications fire even when the interface is locked
            // to portrait, so honor the opt-in here too — not just the orientation mask.
            guard AppSettings.shared.landscapeClockEnabled else { return }
            let orientation = UIDevice.current.orientation
            if orientation == .landscapeLeft || orientation == .landscapeRight {
                showClockMode = true
            } else if orientation == .faceDown || orientation == .portraitUpsideDown {
                // Ignore upside-down orientations
            }
        }
    }

    // MARK: - Player View

    @ViewBuilder
    private func playerView(song: Song, geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let artSize = w - (horizontalPadding * 2)

        VStack(spacing: 0) {
            Spacer().frame(height: max(safeTop, 20) + 24)

            // Playing from source indicator (above cover art)
            if player.playbackSource != .unknown {
                Button {
                    handlePlaybackSourceTap(player.playbackSource)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: player.playbackSource.systemImage)
                            .font(.caption2)
                        Text(player.playbackSource.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: w - 80)
                }
                .disabled(!player.playbackSource.isNavigable)
                .padding(.bottom, 4)
            }

            Spacer(minLength: 4)

            // Everything from the artwork down to the title sits in a container of FIXED
            // height, measured once from the normal state. Opening lyrics rearranges what is
            // inside it — the artwork shrinks into a header, the title block fades out, the
            // lyrics take the space both vacate — but the container's own height never moves,
            // so the playback source above and the transport controls below stay put.
            VStack(spacing: 0) {
            // ONE artwork view for both states. It stays at the same place in the tree and
            // only its SIZE changes, so SwiftUI animates the frame and the picture genuinely
            // contracts on its way to the corner.
            //
            // This replaced a matchedGeometryEffect between two separate views. That only
            // hands a view a new frame, and CoverArtAsyncImage fixes its own dimensions
            // internally — so the frame travelled while the picture stayed hero-sized, and
            // the already-small copy simply appeared at the destination. It read as a jump.
            //
            // The small title of the lyrics header lives inside artworkView, underneath the
            // cover — see there for why.
            artworkView(song: song, size: showLyrics ? Self.lyricsArtSize : artSize, slideWidth: w)
                .frame(maxWidth: .infinity, alignment: showLyrics ? .leading : .center)
                // Facing the small title, at the far end of the header.
                .overlay(alignment: .trailing) {
                    if showLyrics && translator.isAvailable {
                        translateButton
                            .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.15)))
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, showLyrics ? 14 : 0)
                .offset(x: showLyrics ? 0 : coverDragOffset)
                .gesture(showLyrics ? nil : coverDragGesture)

            if showLyrics {
                lyricsScrollView
                    // Takes whatever the artwork and the title block give up. The container
                    // is height-locked, so this expands into exactly the space they vacate.
                    .frame(maxHeight: .infinity)
                    // Long eased dissolves at both ends, not the old 16pt hairline. Lines
                    // don't stop at an edge, they thin out into the background — which is
                    // what keeps a dense lyric sheet from feeling like a wall of text.
                    .mask(
                        VStack(spacing: 0) {
                            LinearGradient(gradient: Self.lyricsEdgeFade,
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.lyricsEdgeFadeHeight)
                            Color.white
                            // Same curve, read from the other end — so both edges fall off
                            // identically and can't drift apart when the curve is retuned.
                            LinearGradient(gradient: Self.lyricsEdgeFade,
                                           startPoint: .bottom, endPoint: .top)
                                .frame(height: Self.lyricsEdgeFadeHeight)
                        }
                    )
                    .padding(.horizontal, horizontalPadding)
                    .transition(.opacity)
            }

            Spacer().frame(height: 20)

            // Song info — hidden while lyrics are open, where the header already shows the
            // title and artist. Its height is what lets the lyrics breathe.
            // Deliberately always in the tree, never behind `if !showLyrics`. Presence is
            // what makes SwiftUI choose a transition, and this block already owns one for
            // song changes; a second reason to appear made the two fight, and the
            // directional slide won — so closing the lyrics replayed a track-change
            // animation and the title flew in from the right for a song that never changed.
            // Wrapping it in a `Group` did not help: `Group` is a passthrough that hands the
            // modifier to its child, putting both transitions back on one view. Collapsing
            // it keeps a single stable identity instead. The opacity is the fade; the height
            // is what gives the lyrics their room.
            VStack(spacing: 4) {
                if let albumId = song.albumId {
                    Button {
                        player.pendingAlbumId = albumId
                        player.isShowingNowPlaying = false
                    } label: {
                        MarqueeText(text: displayTitle(for: song),
                                    font: .title2.bold(),
                                    color: .white,)
                    }
                } else {
                    MarqueeText(text: displayTitle(for: song),
                                font: .title2.bold(),
                                color: .white,)
                }
                TappableArtistText(
                    artistString: song.artist ?? "Unknown Artist",
                    primaryArtistId: song.artistId,
                    font: .body,
                    foregroundStyle: AnyShapeStyle(.white.opacity(0.7)),
                    tappableStyle: AnyShapeStyle(.white.opacity(0.7)),
                    onNavigate: { artistId in
                        player.pendingArtistId = artistId
                        player.isShowingNowPlaying = false
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, horizontalPadding)
            .id("songinfo-\(song.id)")
            // Same travel and same drag rate as the artwork above: title and cover are
            // one object as far as the eye is concerned, and the old 80 pt / half-speed
            // parallax made them visibly drift apart mid-swipe.
            // Same reasoning as the artwork above: directional in, plain fade out.
            .transition(.asymmetric(
                insertion: .offset(x: CGFloat(player.songChangeDirection.signum()) * w).combined(with: .opacity),
                removal: .opacity
            ))
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: song.id)
            .offset(x: showLyrics ? 0 : coverDragOffset)
            // Measured before the collapsing frame below, and only while open, so the frame
            // has a real number to animate to and from rather than `nil`.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if !showLyrics, height > 0 { songInfoHeight = height }
            }
            .frame(height: showLyrics ? 0 : songInfoHeight, alignment: .top)
            // Clipped to the collapsing frame. Unclipped, the title overflowed the frame
            // as it shrank and lay across the year and the heart below it while fading.
            .clipped()
            .opacity(showLyrics ? 0 : 1)
            // It still owns a coordinate space once collapsed, it just has no height —
            // so make sure nothing invisible can be tapped.
            .allowsHitTesting(!showLyrics)
            }
            // Locked *only* while the lyrics are open. That is the only thing the lock is
            // for — stopping the HUD below from moving when the artwork shrinks and the
            // title block collapses. With the lyrics closed the region should simply be its
            // natural size, and constraining it then bought nothing.
            //
            // It used to be locked at all times, with the measurement taken outside the
            // lock, so the value could only ever confirm itself: a single transient
            // under-measurement — the sheet mid-presentation, artwork not yet sized —
            // latched permanently. `.frame(height:)` does not clip, so the region went on
            // drawing content taller than the box it claimed, and the year row, scrubber and
            // transport rode up over the artwork. Reopening the view or switching tabs only
            // appeared to fix it: it discarded the state and re-measured from scratch.
            //
            // `.frame(height:)` also centres its content unless told otherwise, which pushed
            // the header down the locked box instead of pinning it to the top.
            .frame(height: showLyrics ? mediaRegionHeight : nil, alignment: .top)
            // Recorded only in the normal state — that layout is the reference the lyrics
            // state has to match — which is now also the only state where nothing is
            // constraining it, so this reads the true natural height.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if !showLyrics, height > 0 { mediaRegionHeight = height }
            }

            // Year + genre + favourite + menu row
            HStack {
                if song.year != nil || song.genre != nil {
                    HStack(spacing: 4) {
                        if let year = song.year {
                            Text(String(year)).font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        if song.year != nil && song.genre != nil {
                            Text("·").font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        if let genre = song.genre {
                            Button {
                                player.pendingGenreName = genre
                                player.isShowingNowPlaying = false
                            } label: {
                                Text(genre).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer()
                SongActionsRow(
                    song: song,
                    showLyrics: showLyrics,
                    accentColor: accentColor,
                    showAddToPlaylist: $showAddToPlaylist,
                    showFileInfo: $showFileInfo,
                    showCredits: $showCredits,
                    showEqualizer: $showEqualizer,
                    showSleepTimer: $showSleepTimerSheet,
                    showShare: $showShareSheet
                )
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 2)

            progressAndControls
                .padding(.horizontal, horizontalPadding)

            Spacer()

            // Bottom toolbar. Under the alpha auto-hide setting it collapses to a small
            // glass handle and expands from the centre on demand.
            //
            // The bar keeps its layout height either way, and the handle is stacked on top
            // of it rather than replacing it — so the handle sits exactly where the icons
            // are and nothing above it shifts when the bar comes and goes.
            ZStack {
                optionsBar
                    .scaleEffect(x: optionsBarShown ? 1 : 0.02, anchor: .center)
                    .opacity(optionsBarShown ? 1 : 0)
                    .allowsHitTesting(optionsBarShown)
                if appSettings.alphaAutoHideToolbar && !toolbarRevealed {
                    optionsHandle
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.bottom, max(safeBottom, 20) + 40)
        }
        .frame(width: w)
    }

    /// Shown when the bar is collapsed. Its width matches the span between the midpoint of
    /// the previous/play gap and the midpoint of the play/next gap, so it reads as part of
    /// the transport row rather than a stray pill.
    private var optionsHandle: some View {
        Capsule(style: .continuous)
            .fill(.clear)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .frame(width: 80, height: 26)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
            .onTapGesture { revealOptionsBar() }
            .accessibilityLabel("Show player options")
            .accessibilityAddTraits(.isButton)
    }

    /// True when the bar should be on screen: always, unless the alpha setting is on and
    /// the bar hasn't been revealed.
    private var optionsBarShown: Bool {
        !appSettings.alphaAutoHideToolbar || toolbarRevealed
    }

    private func revealOptionsBar() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        toolbarHideTask?.cancel()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { toolbarRevealed = true }
        toolbarHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { toolbarRevealed = false }
        }
    }

    /// A radio grows from the server's knowledge of the song: none offline, none for a preview.
    private var radioUnavailable: Bool {
        isEffectivelyOffline || player.currentSong?.isPreview == true
    }

    /// Four everyday controls — lyrics, radio, queue, output. The sleep timer and sharing
    /// live in the "…" menu beside the heart: occasional actions, not a permanent row of icons.
    private var optionsBar: some View {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { showLyrics.toggle() }
                } label: {
                    Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.title2)
                        .foregroundStyle(showLyrics ? accentColor : .white.opacity(0.6))
                }
                .accessibilityLabel(showLyrics ? "Hide lyrics" : "Show lyrics")
                Spacer()
                Button {
                    if let current = player.currentSong {
                        // Check if in-memory radio is specifically FOR this song
                        let radioNameForSong = "Radio: \(current.title)"
                        if player.radioPlaylistName == radioNameForSong && !player.radioPlaylistSongs.isEmpty {
                            existingRadioPlaylistId = nil
                            existingRadioPlaylistName = player.radioPlaylistName
                            showRadioExistsDialog = true
                        } else {
                            // Check saved playlists on server for this song's radio
                            Task { await checkForSavedRadio(song: current) }
                        }
                    }
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(radioUnavailable ? 0.25 : 0.6))
                }
                .disabled(radioUnavailable)
                .accessibilityLabel("Start radio from this song")
                Spacer()
                Button { player.isShowingQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .accessibilityLabel("Show queue")
                Spacer()
                AudioOutputButtonWrapper(accentColor: accentColor)
                Spacer()
            }
            .padding(.horizontal, horizontalPadding)
    }

    /// A lyric line, word-highlighted when karaoke mode is on and this is the line being sung.
    ///
    /// Only the *current* line is broken into words — every other line stays a single `Text`,
    /// so a 60-line lyric sheet costs no more to render than before.
    ///
    /// Built by concatenating `Text` values rather than laying out words in an `HStack`:
    /// concatenation keeps SwiftUI's natural line wrapping, which a stack of words would
    /// break on any line long enough to need it — i.e. exactly the lines that matter.
    /// Which line to put the focus on: the one being sung, or — once that one is done and
    /// the next hasn't begun — the one about to be.
    ///
    /// "Done" is known exactly when the server gave us word cues: the last cue's start. With
    /// only a line timing to go on it has to be estimated from the text length, which is why
    /// the estimate is deliberately generous — holding a finished line a beat too long reads
    /// far better than jumping ahead of the music.
    // Not a @ViewBuilder: the builder would wrap the branches in _ConditionalContent, and
    // returning a concrete `Text` is the whole point — only `Text` concatenates.
    /// The words of `line` with their timings, or `nil` when it should be drawn as one
    /// undivided run: highlighting off, unsynced lyrics, or nothing to time it against.
    private func karaokeWords(line: LyricsLine, index: Int, isCurrent: Bool) -> [LyricWord]? {
        guard appSettings.betaKaraokeLyrics, isCurrent, areLyricsSynced else { return nil }
        // The same words `LyricWordTiming.focusIndex` judges the line's end by.
        return LyricWordTiming.timedWords(lines: player.lyrics, index: index)
    }

    private func lyricLineText(line: LyricsLine, index: Int, isCurrent: Bool) -> Text {
        guard let words = karaokeWords(line: line, index: index, isCurrent: isCurrent) else {
            return Text(line.text)
        }
        // A switch per word, deliberately, and not a fill travelling through the glyphs.
        // That was built — a TextRenderer sweeping a soft gradient front across each word —
        // and it read as sluggish against the beat however fast it was tuned. What survives
        // of it is only the last moment: a word still *arrives* rather than snapping on.
        // The rest stay dimmed but legible, so the eye can read ahead.
        return words.reduce(Text("")) { partial, word in
            partial + Text(word.text).foregroundColor(.white.opacity(wordBrightness(word)))
        }
    }

    /// How lit a word is, from `unsungWord` to full.
    ///
    /// Short, and smooth because it is drawn on the display link rather than sampled from
    /// the playback observer. Tying it to that observer instead put the whole fade inside
    /// two or three of its 100ms reports, which is why it stepped.
    private static let wordFade: TimeInterval = 0.09
    private static let unsungWord: Double = 0.35

    private func wordBrightness(_ word: LyricWord) -> Double {
        let elapsed = player.liveLyricsTime - word.start
        guard elapsed > 0 else { return Self.unsungWord }
        let progress = min(1, elapsed / Self.wordFade)
        return Self.unsungWord + (1 - Self.unsungWord) * progress
    }

    /// The artwork, at whatever size the current state asks for.
    ///
    /// Deliberately NOT two views swapped by a transition: keeping one identity is what lets
    /// the frame animate between hero and header, and it also preserves the song-change
    /// slide, which a geometry match would have suppressed.
    private func artworkView(song: Song, size: CGFloat, slideWidth w: CGFloat) -> some View {
        let heroSize = w - horizontalPadding * 2   // the full-size artwork, as in playerView

        return ZStack {
            CoverArtAsyncImage(coverArt: song.coverArt ?? song.albumId, size: size,
                               fallbackCoverArt: song.albumId)
                .shadow(color: .black.opacity(showLyrics ? 0.35 : 0.4),
                        radius: showLyrics ? 6 : 20,
                        y: showLyrics ? 3 : 10)
                .id(song.id)
                // Only the INCOMING view is directional. `removal` belongs to the outgoing
                // view, which SwiftUI built during an earlier body pass — so it carries the
                // direction as it was THEN. Go back a track, then let the next one end on
                // its own, and the stale removal slid the old cover the same way the new one
                // arrived: both from the right, which read as the wrong direction. A plain
                // fade out cannot contradict the slide in.
                .transition(.asymmetric(
                    insertion: .offset(x: CGFloat(player.songChangeDirection.signum()) * w).combined(with: .opacity),
                    removal: .opacity
                ))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: song.id)
        // The lyrics header's title, drawn BEHIND the cover and pinned from its first frame
        // to where it ends up. The cover's top-left corner never moves — it shrinks into
        // it — so while the cover is large this spot is under it, and as the cover
        // contracts its trailing edge sweeps left and uncovers the title, which reads as
        // having been waiting underneath the whole time. Closing is the exact mirror.
        //
        // It used to be a column beside the cover whose width grew from zero, clipped. That
        // made the title ride the cover's edge in from the right, cut off by an invisible
        // line at the far edge of the screen — it read as a shutter opening, not as
        // something the artwork had been hiding.
        //
        // Still only built while lyrics are open, so no marquee keeps scrolling out of sight.
        .background(alignment: .topLeading) {
            if showLyrics {
                lyricsHeaderText(song: song)
                    .frame(width: max(0, heroSize - Self.lyricsArtSize - Self.lyricsTitleGap
                                          - (translator.isAvailable ? Self.translateButtonRoom : 0)),
                           height: Self.lyricsArtSize, alignment: .leading)
                    .padding(.leading, Self.lyricsArtSize + Self.lyricsTitleGap)
                    .transition(UncoveredByArtwork(coveredEdge: heroSize,
                                                   uncoveredEdge: Self.lyricsArtSize))
            }
        }
        // The paused-state shrink is a hero gesture; at 44pt it would just look like a
        // glitch, so it only applies at full size. It scales the title underneath too: the
        // title only stays hidden if it shrinks with the cover. Opened while paused, the
        // cover starts at 85% and an unscaled title would already poke out above it.
        .scaleEffect(showLyrics || player.isPlaying ? 1.0 : 0.85)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
    }

    /// Shows or hides a translation under each line. Only there when the lyrics are in
    /// another language than the reader's, and one the device can translate.
    private var translateButton: some View {
        let on = appSettings.translateLyrics
        return Button {
            appSettings.translateLyrics.toggle()
            appSettings.save()
            if appSettings.translateLyrics { translator.translateMissing() }
        } label: {
            Image(systemName: "translate")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(on ? 1 : 0.55))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(on ? 0.16 : 0)))
                .symbolEffect(.pulse, isActive: on && translator.isWorking)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: on)
        .accessibilityLabel(on ? "Hide translation" : "Translate lyrics")
    }

    /// Title and artist beside the shrunken artwork once lyrics are open, so the song stays
    /// identifiable while reading.
    private func lyricsHeaderText(song: Song) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MarqueeText(text: displayTitle(for: song),
                        font: .subheadline.weight(.semibold),
                        color: .white,
                        alignment: .leading)
            Text(song.artist ?? "Unknown Artist")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    /// Swipe the artwork to change track, or pull down to dismiss.
    private var coverDragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { value in
                let dx = abs(value.translation.width)
                let dy = abs(value.translation.height)
                if coverDragAxis == .undecided && (dx + dy) > 15 {
                    coverDragAxis = dx >= dy ? .horizontal : .vertical
                }
                switch coverDragAxis {
                case .horizontal:
                    coverDragOffset = value.translation.width
                case .vertical:
                    if value.translation.height > 0 { dragOffset = value.translation.height }
                case .undecided:
                    break
                }
            }
            .onEnded { value in
                switch coverDragAxis {
                case .horizontal:
                    let threshold: CGFloat = 60
                    if value.translation.width < -threshold || value.predictedEndTranslation.width < -threshold * 2 {
                        player.next()
                    } else if value.translation.width > threshold || value.predictedEndTranslation.width > threshold * 2 {
                        player.previous()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { coverDragOffset = 0 }
                case .vertical:
                    if value.translation.height > 150 || value.predictedEndTranslation.height > 300 {
                        withAnimation(.easeOut(duration: 0.25)) { dragOffset = 1000 }
                        scheduleDragDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                    }
                case .undecided:
                    break
                }
                coverDragAxis = .undecided
            }
    }

    /// One size for every line, deliberately.
    ///
    /// Sizing the current line larger meant its wrapping was recomputed the instant it
    /// became current, so the words visibly redistributed themselves as the line arrived —
    /// the most distracting moment possible. Focus is carried by brightness and blur, which
    /// change nothing about layout.
    /// One size for every line, always. The neighbours are made smaller with `scaleEffect`
    /// instead — a smaller *font* would re-wrap them and reshuffle the words mid-phrase.
    private func lyricFont(isCurrent: Bool) -> Font {
        .system(size: 30, weight: .bold, design: .default)
    }

    // Patterns: "(feat. X)", "(ft. X)", "(featuring X)", or without parens at end
    private static let featRegexes: [NSRegularExpression] = [
        "\\s*\\(feat\\.?\\s+([^)]+)\\)",
        "\\s*\\(ft\\.?\\s+([^)]+)\\)",
        "\\s*\\(featuring\\s+([^)]+)\\)",
        "\\s+feat\\.?\\s+(.+)$",
        "\\s+ft\\.?\\s+(.+)$",
        "\\s+featuring\\s+(.+)$"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    /// Strips "(feat. X)", "(ft. X)", "feat. X" etc. from a title when X already appears in the artist line.
    private func displayTitle(for song: Song) -> String {
        let title = song.title
        let artist = song.artist ?? ""
        guard !artist.isEmpty else { return title }

        for regex in Self.featRegexes {
            guard let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let featRange = Range(match.range(at: 1), in: title) else { continue }

            let featArtists = String(title[featRange])
            // Split featured artists by , & and similar
            let featNames = featArtists
                .replacingOccurrences(of: " & ", with: ",")
                .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let artistLower = artist.lowercased()
            let allPresent = featNames.allSatisfy { artistLower.contains($0.lowercased()) }

            if allPresent {
                let cleaned = title.replacingCharacters(in: Range(match.range, in: title)!, with: "")
                    .trimmingCharacters(in: .whitespaces)
                return cleaned
            }
        }
        return title
    }

    private func scheduleDragDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func handlePlaybackSourceTap(_ source: PlaybackSource) {
        switch source {
        case .album(let id, _):
            navAlbumId = id
        case .artist(let id, _):
            player.pendingArtistId = id
            player.isShowingNowPlaying = false
        case .playlist(let id, _):
            player.isShowingNowPlaying = false
            player.pendingPlaylistId = id
        case .mix(let id, _):
            player.isShowingNowPlaying = false
            player.pendingMixId = id
        case .wrapped(let period):
            player.isShowingNowPlaying = false
            player.pendingWrappedPeriod = period
        case .radio(let name):
            // Dismiss NowPlaying first, THEN navigate after animation completes
            player.isShowingNowPlaying = false
            if player.radioPlaylistName == name {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    player.pendingRadioOpen = true
                }
            } else {
                // In-memory radio was overwritten — search for saved playlist with this name
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if let server = ServerManager.shared.currentServer,
                       let playlists = try? await SubsonicClient.shared.getPlaylists(server: server),
                       let saved = playlists.first(where: { $0.name == name }) {
                        await MainActor.run {
                            player.pendingPlaylistId = saved.id
                        }
                    } else {
                        await MainActor.run {
                            player.pendingRadioOpen = true
                        }
                    }
                }
            }
        case .favorites:
            player.isShowingNowPlaying = false
            player.pendingFavoritesOpen = true
        case .genre(let name):
            player.isShowingNowPlaying = false
            player.pendingGenreName = name
        case .recentlyPlayed:
            player.isShowingNowPlaying = false
            player.pendingRecentlyPlayedOpen = true
        case .frequentlyPlayed:
            player.isShowingNowPlaying = false
            player.pendingFrequentlyPlayedOpen = true
        case .queue, .autoplay:
            player.isShowingQueue = true
        case .search, .songs, .unknown:
            break
        }
    }

    // MARK: - Radio Duplicate Check

    /// Check server-side playlists for an existing saved radio matching this song
    private func checkForSavedRadio(song: Song) async {
        guard let server = ServerManager.shared.currentServer else {
            player.startRadioFromSong(song)
            player.isShowingNowPlaying = false
            return
        }
        let radioName = "Radio: \(song.title)"
        do {
            let playlists = try await SubsonicClient.shared.getPlaylists(server: server)
            if let existing = playlists.first(where: { $0.name == radioName }) {
                // Found a saved radio playlist for this song
                await MainActor.run {
                    existingRadioPlaylistId = existing.id
                    existingRadioPlaylistName = existing.name
                    showRadioExistsDialog = true
                }
            } else {
                // No saved radio — create a new one
                await MainActor.run {
                    player.startRadioFromSong(song)
                    player.isShowingNowPlaying = false
                }
            }
        } catch {
            // Network error — just create the radio
            await MainActor.run {
                player.startRadioFromSong(song)
                player.isShowingNowPlaying = false
            }
        }
    }

    // MARK: - Lyrics Scroll View

    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if player.lyrics.isEmpty && player.isLoadingLyrics {
                    // Still searching every source — don't claim "no lyrics" yet.
                    VStack(spacing: 14) {
                        BouncingDotsLoader(color: .white)
                        // Only the live status survives — it names the source being tried,
                        // which the dots can't convey. The generic "Searching…" placeholder
                        // said nothing the animation doesn't already say.
                        if !player.lyricsStatus.isEmpty {
                            Text(player.lyricsStatus)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.45))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical) { h, _ in h }
                    .padding(.horizontal, 16)
                } else if player.lyrics.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "text.quote").font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No lyrics available")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.5))
                        if !player.lyricsStatus.isEmpty {
                            Text(player.lyricsStatus)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.35))
                                .multilineTextAlignment(.center)
                        }
                        Button { player.refetchLyrics() } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .font(.callout).foregroundStyle(accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical) { h, _ in h }
                    .padding(.horizontal, 16)
                    .task {
                        // Auto-dismiss lyrics view after 2s if no lyrics found
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        guard player.lyrics.isEmpty, !player.isLoadingLyrics else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { showLyrics = false }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Spacer().frame(height: 120)
                            .id("lyrics-top-spacer")
                        ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = index == currentLineIndex
                            let distance = distanceFromCurrentLine(index: index)
                            // Focused but not yet begun — the anticipated line during an
                            // instrumental. Word highlighting already greys it out cue by
                            // cue, but with that turned off it would sit there in full
                            // white as though it had been sung.
                            let isAnticipated = isCurrent && (line.time ?? 0) > player.lyricsTime
                            // Only the line being sung redraws on the display link, and
                            // only while the song is actually moving. Every other line is
                            // paused, so it draws once and costs nothing — which is what
                            // makes a per-frame fade affordable inside a scrolling list.
                            VStack(alignment: .leading, spacing: 6) {
                                TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                                        paused: !isCurrent || !player.isPlaying)) { _ in
                                    lyricLineText(line: line, index: index, isCurrent: isCurrent)
                                        .font(lyricFont(isCurrent: isCurrent))
                                }
                                // Small and dimmer than the words sung, so the eye stays on
                                // the song and drops to the meaning when it wants it. It
                                // takes the line's own fade, blur and scale.
                                if appSettings.translateLyrics,
                                   let translation = translator.lines[line.text], !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: 17, weight: .semibold))
                                        .opacity(0.6)
                                        .transition(.opacity)
                                }
                            }
                                .animation(.easeOut(duration: 0.3), value: translator.lines[line.text])
                                .animation(.easeOut(duration: 0.3), value: appSettings.translateLyrics)
                                .foregroundStyle(.white.opacity(
                                    isUserScrolling ? 0.8
                                    : opacityForDistance(distance) * (isAnticipated ? 0.45 : 1)
                                ))
                                .blur(radius: isUserScrolling ? 0 : blurForDistance(distance))
                                .scaleEffect(scaleForDistance(distance), anchor: .leading)
                                .id(line.id)
                                .onTapGesture {
                                    if let time = line.time {
                                        player.seek(to: time)
                                    }
                                }
                                .animation(.spring(duration: 0.5, bounce: 0.15), value: isCurrent)
                                .animation(.easeOut(duration: 0.4), value: distance)
                        }
                        Spacer().frame(height: 120)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting || newPhase == .decelerating {
                    isUserScrolling = true
                    scrollReturnTask?.cancel()
                } else if newPhase == .idle && isUserScrolling {
                    scrollReturnTask?.cancel()
                    scrollReturnTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isUserScrolling = false
                            if let id = currentLyricId {
                                withAnimation(.easeInOut(duration: 0.4)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            .onAppear {
                // Immediately scroll to current lyric when lyrics view appears
                updateLyricIndices()
                if let id = currentLyricId {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: player.lyricsTime) { _, _ in
                updateLyricIndices()
            }
            .onChange(of: player.lyrics.count) { _, _ in
                updateLyricIndices()
            }
            .onChange(of: currentLyricId) { _, newId in
                guard let newId, !isUserScrolling else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            // Translations shown, hidden or arriving change every line's height, and the
            // list keeps its offset: the line being sung drifted off the centre until the
            // next one brought it back.
            .onChange(of: appSettings.translateLyrics) { _, _ in recenterLyrics(proxy) }
            .onChange(of: translator.lines.count) { _, _ in
                if appSettings.translateLyrics { recenterLyrics(proxy) }
            }
        }
    }

    /// Centres the line being sung once the lines have finished changing height (0.3 s).
    private func recenterLyrics(_ proxy: ScrollViewProxy) {
        recenterTask?.cancel()
        recenterTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, !isUserScrolling, let id = currentLyricId else { return }
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    @ViewBuilder
    // MARK: - Progress + Controls

    private var progressAndControls: some View {
        VStack(spacing: 8) {
            BufferedProgressBar(
                progress: player.progress,
                buffer: player.bufferProgress,
                accentColor: .white,
                onSeek: { player.seek(to: $0 * player.duration) },
                loading: player.isBuffering
            )

            HStack {
                Text(formatTime(player.currentTime))
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("-\(formatTime(max(0, player.duration - player.currentTime)))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }

            HStack(spacing: 36) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.title3)
                        .frame(minWidth: 32, minHeight: 32)
                        .foregroundStyle(player.isShuffled ? accentColor : .white.opacity(0.7))
                }
                .accessibilityLabel("Shuffle \(player.isShuffled ? "on" : "off")")
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill").font(.title).foregroundStyle(.white)
                }
                .accessibilityLabel("Previous track")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 50)).foregroundStyle(.white)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill").font(.title).foregroundStyle(.white)
                }
                .accessibilityLabel("Next track")
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode.systemImage).font(.title3)
                        .frame(minWidth: 32, minHeight: 32)
                        .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.7) : accentColor)
                }
                .accessibilityLabel("Repeat \(player.repeatMode == .off ? "off" : player.repeatMode == .all ? "all" : "one")")
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Sleep Timer Sheet

    private var sleepTimerPickerSheet: some View {
        VStack(spacing: 16) {
            Text("Sleep Timer")
                .font(.headline)
                .padding(.top, 20)

            if player.sleepTimerActive {
                // Active timer: show remaining time and cancel button
                VStack(spacing: 12) {
                    if player.sleepTimerEndOfSong {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(accentColor)
                            .padding(.top, 20)
                        Text("End of current song")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.primary)
                    } else {
                        Text(player.sleepTimerFormatted)
                            .font(.system(size: 56, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .padding(.top, 20)
                        Text("remaining")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 150)

                Button {
                    player.cancelSleepTimer()
                    showSleepTimerSheet = false
                } label: {
                    Text("Cancel Timer")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.red.opacity(0.8))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            } else {
                // No active timer: show picker
                Picker("Minutes", selection: $selectedSleepMinutes) {
                    ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { min in
                        Text(min < 60 ? "\(min) min" : "\(min / 60)h\(min % 60 > 0 ? " \(min % 60)m" : "")")
                            .tag(min)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 150)

                HStack(spacing: 16) {
                    Button {
                        player.startSleepTimerEndOfSong()
                        showSleepTimerSheet = false
                    } label: {
                        Text("End of Song")
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        player.startSleepTimer(minutes: selectedSleepMinutes)
                        showSleepTimerSheet = false
                    } label: {
                        Text("Start Timer")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Helpers

    /// Recomputes the current and nearest lyric line indices once per time change,
    /// so each row only does O(1) index arithmetic.
    private func updateLyricIndices() {
        guard !player.lyrics.isEmpty else {
            currentLineIndex = nil
            nearestLineIndex = nil
            return
        }
        // The heard position, not the decoder's — see AudioPlayer.lyricsTime. The line and
        // the word highlight must use the same clock or they'd drift apart from each other.
        let time = player.lyricsTime
        var last: Int?
        for (i, line) in player.lyrics.enumerated() {
            guard let t = line.time else { continue }
            if t <= time {
                last = i
            } else {
                break
            }
        }
        nearestLineIndex = last
        // Karaoke logic: once the sung line is spent, move the focus to the one COMING, not
        // nowhere. It renders unlit — for a line whose cues are all in the future, no word
        // passes the "already sung" test, so the whole line comes out grey — and lights up
        // word by word when it starts. Clearing the focus instead, as this used to, left no
        // current line at all, so every line went dim and blurred during the instrumental.
        currentLineIndex = LyricWordTiming.focusIndex(lines: player.lyrics, after: last, at: time)
    }

    private var currentLyricId: UUID? {
        guard let index = currentLineIndex, index < player.lyrics.count else { return nil }
        return player.lyrics[index].id
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

    private func distanceFromCurrentLine(index: Int) -> Int {
        if let currentIndex = currentLineIndex {
            return abs(index - currentIndex)
        }
        // During instrumental gaps, measure from the nearest (anchor) line
        if let anchor = nearestLineIndex {
            return abs(index - anchor)
        }
        return 0
    }

    /// True when at least one lyric line has a timestamp.
    private var areLyricsSynced: Bool {
        player.lyrics.contains { $0.time != nil }
    }

    private func blurForDistance(_ distance: Int) -> CGFloat {
        guard areLyricsSynced else { return 0 }          // Unsynced → no blur
        guard currentLineIndex != nil else {
            // Instrumental gap: blur nearby lines, hide the rest
            if distance == 0 { return 3 }
            if distance == 1 { return 5 }
            return 8
        }
        if distance == 0 { return 0 }
        // Harder falloff than before: the neighbours are context, not something to read, and
        // a long lyric sheet reads as calmer when only the sung line is sharp.
        if distance == 1 { return 5.0 }
        return 11
    }

    /// Size of a line relative to the one being sung.
    ///
    /// Applied as `scaleEffect`, never as a font size. The sheet draws every line at one
    /// size precisely so that wrapping is decided once; handing the neighbours a smaller
    /// font would re-wrap them, and the words would reshuffle inside the phrase on every
    /// line change — the exact thing that was taken out in 0f56a16. Scaling the rendered
    /// result moves the whole line as one block, however many rows it wraps onto, and it is
    /// invisible to layout, so nothing above or below shifts as the song moves on.
    ///
    /// It animates for free: the value is keyed on `distance`, which already carries an
    /// `.easeOut` on this view.
    private func scaleForDistance(_ distance: Int) -> CGFloat {
        // Full size while the sheet is being browsed by hand — every line is a candidate
        // then, so none of them should be demoted.
        guard areLyricsSynced, !isUserScrolling else { return 1 }
        return distance == 0 ? 1 : 0.84
    }

    private func opacityForDistance(_ distance: Int) -> Double {
        guard areLyricsSynced else { return 0.8 }        // Unsynced → all visible
        guard currentLineIndex != nil else {
            // Instrumental gap: only show 3 lines (anchor ± 1), all dimmed
            if distance <= 1 { return 0.3 }
            return 0.0
        }
        if distance == 0 { return 1.0 }
        // Deliberately faint. Blurring the neighbour alone wasn't enough — a blurred line
        // at 0.45 still carries enough ink to pull the eye off the line being sung. It only
        // has to say "there is more text here", so it sits at roughly a quarter, and the
        // edge mask thins it further still the closer it is to the top or bottom.
        if distance == 1 { return 0.28 }
        return 0.0
    }

    /// How far the lyric sheet dissolves into the background at each end, in points.
    ///
    /// Sized against what has to stay legible in the middle: at ~355pt of lyric area on a
    /// 16 Pro this leaves a ~170pt clear band, enough for a three-row line at the 30pt
    /// lyric size. Growing this much further would start eating the line being sung.
    private static let lyricsEdgeFadeHeight: CGFloat = 92

    /// Eased, not linear. A straight ramp still hands the outermost line half its opacity;
    /// front-loading the falloff means the outer half of the zone is all but gone, so the
    /// sheet reads as fading out rather than as being cut off.
    private static let lyricsEdgeFade = Gradient(stops: [
        .init(color: .clear,               location: 0.00),
        .init(color: .white.opacity(0.06), location: 0.25),
        .init(color: .white.opacity(0.22), location: 0.50),
        .init(color: .white.opacity(0.55), location: 0.75),
        .init(color: .white,               location: 1.00),
    ])

    private func cachedBackground(for song: Song, in geo: GeometryProxy) -> some View {
        Color.black
            .overlay {
                if let img = backgroundImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 130)
                        .scaleEffect(1.5)
                        .overlay(Color.black.opacity(0.22))
                    // If cover is too dark, blend in the most vibrant color
                    if let vibrant = vibrantOverlayColor {
                        vibrant.opacity(0.4)
                            .blendMode(.screen)
                    }
                }
            }
            .drawingGroup() // Flatten to bitmap — prevents per-frame recomposite flicker
            .ignoresSafeArea(.all)
            .transaction { $0.animation = nil } // No stray animations on background
            .task(id: song.coverArt) {
                await loadBackgroundImage(for: song)
            }
    }

    private func loadBackgroundImage(for song: Song) async {
        guard let coverArt = song.coverArt, ServerManager.shared.currentServer != nil else {
            backgroundImage = nil
            vibrantOverlayColor = nil
            return
        }
        let key = "\(coverArt)_bg"
        if let cached = ArtworkCache.shared.image(for: key) {
            let vibrant = await Self.vibrantColorIfDark(from: cached)
            await MainActor.run {
                backgroundImage = cached
                vibrantOverlayColor = vibrant
            }
            return
        }
        // Show ANY already-cached size of this cover immediately (it's heavily blurred
        // anyway) so the background never flashes empty while the dedicated bitmap loads —
        // the same progressive trick the foreground cover uses.
        if let anySize = ArtworkCache.shared.cachedImageAnySize(forCoverArt: coverArt)
            ?? song.albumId.flatMap({ ArtworkCache.shared.cachedImageAnySize(forCoverArt: $0) }) {
            let vibrant = await Self.vibrantColorIfDark(from: anySize)
            await MainActor.run {
                backgroundImage = anySize
                vibrantOverlayColor = vibrant
            }
        }
        // Reuse the ordinary thumbnail rather than downloading a second bitmap.
        //
        // This used to fetch its own copy at the same size, through URLSession.shared — so
        // outside the artwork throttle — on every single song change. The image is blurred
        // beyond recognition behind the artwork, so a dedicated download bought nothing and
        // cost a round-trip each time. Going through ArtworkCache means it is usually
        // already in memory (the row thumbnail and this share a bucket), and when it isn't,
        // the fetch is throttled and cached like every other cover.
        let thumbKey = "\(coverArt)_\(ArtworkCache.thumbSize)"
        guard let img = await ArtworkCache.shared.fetchImage(
            coverArt: coverArt, requestSize: ArtworkCache.thumbSize, key: thumbKey) else { return }
        let vibrant = await Self.vibrantColorIfDark(from: img)
        await MainActor.run {
            backgroundImage = img
            vibrantOverlayColor = vibrant
        }
    }

    /// Runs the pixel analysis off the main thread.
    private static func vibrantColorIfDark(from image: UIImage) async -> Color? {
        await Task.detached(priority: .userInitiated) {
            extractVibrantColorIfDark(from: image)
        }.value
    }

    /// Analyzes image brightness; if too dark, finds the most vibrant (saturated) non-dark color.
    /// Returns nil for normal-brightness images (no correction needed).
    private nonisolated static func extractVibrantColorIfDark(from image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        let width = min(cgImage.width, 50)
        let height = min(cgImage.height, 50)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalBrightness: Double = 0
        var bestSaturation: Double = 0
        var bestColor: (r: Double, g: Double, b: Double)?
        let pixelCount = width * height

        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Double(pixelData[offset]) / 255.0
            let g = Double(pixelData[offset + 1]) / 255.0
            let b = Double(pixelData[offset + 2]) / 255.0

            // Perceived brightness (ITU-R BT.601)
            let brightness = 0.299 * r + 0.587 * g + 0.114 * b
            totalBrightness += brightness

            // HSB saturation
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0

            // We want the most saturated, not-too-dark pixel
            if saturation > bestSaturation && brightness > 0.1 {
                bestSaturation = saturation
                bestColor = (r, g, b)
            }
        }

        let avgBrightness = totalBrightness / Double(pixelCount)

        // Only apply vibrant color correction for dark covers (avg brightness < 0.2)
        guard avgBrightness < 0.2, let color = bestColor, bestSaturation > 0.15 else { return nil }

        // Boost the vibrant color's brightness for a more visible effect
        let boostFactor = 1.5
        return Color(
            red: min(color.r * boostFactor, 1.0),
            green: min(color.g * boostFactor, 1.0),
            blue: min(color.b * boostFactor, 1.0)
        )
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite else { return "0:00" }
        let t = max(0, time)
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Lyrics header title reveal

/// Shows the lyrics header's title only where the artwork has already moved off it.
///
/// The mask's edge travels with the cover's trailing edge — same start, same end, same
/// animation, since both ride the transaction that toggles the lyrics — so each part of the
/// title appears the instant the cover uncovers it, and goes the instant the cover slides
/// back over it. It has to be a transition: a mask laid out inside a freshly inserted view
/// has no earlier frame to animate from and would sit at its final size from the start.
///
/// Lying under the cover isn't enough on its own. A cover that isn't square is fitted with
/// transparent bands above and below it, and the title would show through them.
private struct UncoveredByArtwork: Transition {
    /// The cover's trailing edge, from its leading edge: at full size, and in the header.
    let coveredEdge: CGFloat
    let uncoveredEdge: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.mask(alignment: .leading) {
            Rectangle().offset(x: phase.isIdentity ? uncoveredEdge : coveredEdge)
        }
    }
}

// MARK: - Song Actions Row (isolated from progress re-renders)

/// Extracted view so the Menu doesn't re-render on every progress tick.
/// Only reads `currentSong` and `lyricsSource` from AudioPlayer — NOT progress/currentTime.
struct SongActionsRow: View {
    let song: Song
    let showLyrics: Bool
    let accentColor: Color
    @Binding var showAddToPlaylist: Bool
    @Binding var showFileInfo: Bool
    @Binding var showCredits: Bool
    @Binding var showEqualizer: Bool
    @Binding var showSleepTimer: Bool
    @Binding var showShare: Bool

    @Environment(AudioPlayer.self) private var player
    @State private var heartPop = false

    private var isStarred: Bool { player.currentSong?.isStarred ?? false }

    /// The heart, with the two pieces of feedback the plain icon was missing.
    ///
    /// Starring is a server round-trip that can take seconds. With no visible state the
    /// only signal was "nothing happened", so the natural reaction was to tap again and
    /// again. It now pulses and refuses further taps while the call is in flight, and
    /// answers a successful star with a short burst so the action reads as finished.
    private var favoriteButton: some View {
        ZStack {
            if player.isTogglingFavorite {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.75))
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Image(systemName: isStarred ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isStarred ? accentColor : .white.opacity(0.7))
                    .scaleEffect(heartPop ? 1.35 : 1)
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !player.isTogglingFavorite else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isStarred {
                // Already favorited → open Add to Playlist
                showAddToPlaylist = true
            } else {
                // Not favorited → add to favorites
                player.toggleFavorite()
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showAddToPlaylist = true
        }
        .accessibilityLabel(player.isTogglingFavorite ? "Saving favourite"
                            : (isStarred ? "Remove from favourites" : "Add to favourites"))
        .onChange(of: player.favoriteCelebration) { _, _ in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { heartPop = true }
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { heartPop = false }
            }
        }
    }

    var body: some View {
        if song.isPreview {
            HStack(spacing: 6) {
                #if !APPSTORE_BUILD
                if ReleaseFetcher.shared.isAvailable { getButton }
                #endif
                previewBadge
            }
        } else {
            actions
        }
    }

    /// A release not on the server yet: nothing to queue or download from it — only heard,
    /// or, in the sideload build, fetched.
    private var previewBadge: some View {
        Text(badgeText)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.15), in: Capsule())
            .contentTransition(.numericText())
            .animation(.easeInOut, value: badgeText)
            .accessibilityLabel(badgeText == String(localized: "Preview") ? String(localized: "Thirty-second preview") : badgeText)
    }

    private var badgeText: String {
        #if !APPSTORE_BUILD
        if let fetch = releaseFetch {
            switch fetch.stage {
            case .searching: return String(localized: "Searching…")
            case .downloading:
                return fetch.progress > 0
                    ? fetch.progress.formatted(.percent.precision(.fractionLength(0)))
                    : String(localized: "Queued…")
            case .importing: return String(localized: "Adding…")
            case .ready: return String(localized: "In your library")
            case .failed: break
            }
        }
        #endif
        return String(localized: "Preview")
    }

    #if !APPSTORE_BUILD
    private var releaseFetch: ReleaseFetch? { ReleaseFetcher.shared.fetch(covering: song) }

    /// Liking a preview gets the song: found on Soulseek, downloaded, added to the server —
    /// and starred once it's there. The whole release is had from its page.
    private var getButton: some View {
        let fetch = releaseFetch
        let isOn = fetch != nil && fetch?.stage != .failed
        return Image(systemName: isOn ? "heart.fill" : "heart")
            .font(.title3)
            .foregroundStyle(isOn ? accentColor : .white.opacity(0.7))
            .symbolEffect(.pulse, options: .repeating, isActive: fetch?.isActive == true)
            .scaleEffect(heartPop ? 1.35 : 1)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isOn else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                ReleaseFetcher.shared.get(preview: song)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { heartPop = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(220))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { heartPop = false }
                }
            }
            .accessibilityLabel(isOn ? "Getting this song" : "Like, and get this song")
    }
    #endif

    private var actions: some View {
        HStack(spacing: 2) {
            favoriteButton
            Menu {
                if showLyrics {
                    Button { player.refetchLyrics() } label: {
                        Label("Refetch Lyrics", systemImage: "arrow.clockwise")
                    }
                    Button { player.switchLyricsSource() } label: {
                        Label("Switch Source (\(player.lyricsSource == .structured ? "Legacy" : "Synced"))",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                }
                Button { showFileInfo = true } label: {
                    Label("File Info", systemImage: "info.circle")
                }
                Button { showEqualizer = true } label: {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
                Button { showCredits = true } label: {
                    Label("Credits", systemImage: "person.text.rectangle")
                }
                Divider()
                Button { player.playNext(song) } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button { player.addToQueue(song) } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                Button { showAddToPlaylist = true } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
                Button {
                    Task { await DownloadManager.shared.downloadSong(song) }
                } label: {
                    Label(DownloadManager.shared.isDownloaded(song.id) ? "Downloaded" : "Download",
                          systemImage: DownloadManager.shared.isDownloaded(song.id) ? "checkmark.circle.fill" : "arrow.down.circle")
                }
                .disabled(DownloadManager.shared.isDownloaded(song.id))
                Divider()
                Button { showSleepTimer = true } label: {
                    Label(player.sleepTimerActive ? "Sleep Timer (On)" : "Sleep Timer",
                          systemImage: player.sleepTimerActive ? "moon.fill" : "moon.zzz")
                }
                Button { showShare = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: player.sleepTimerActive ? "ellipsis.circle.fill" : "ellipsis")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
    }
}

