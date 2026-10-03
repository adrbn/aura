import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
#if os(iOS)
import ActivityKit
#endif

@Observable
final class AudioPlayer {
    static let shared = AudioPlayer()
    /// A preview is thirty seconds cut from the middle of a song: it fades out over its last
    /// few rather than stopping dead.
    private static let previewFade: TimeInterval = 3

    var currentSong: Song?
    var queue: [Song] = []
    var userQueue: [Song] = []
    var queueIndex: Int = 0
    /// True while a favourite toggle is waiting on the server. The heart shows a pulse
    /// and stops accepting taps, so a slow round-trip can't be fired twenty times.
    var isTogglingFavorite = false
    /// Bumped each time a song becomes a favourite — drives the one-shot sparkle burst.
    var favoriteCelebration = 0

    /// Which way the last song change went: +1 forward, -1 backward — or 0 when a preview
    /// became its own song, which dissolves in place rather than sliding. Drives the Now
    /// Playing slide transition.
    ///
    /// It lives here, not in the view, because the view only ever sees *some* of the
    /// song changes. Autoplay, the lock screen, CarPlay and Siri all move the queue
    /// without any on-screen gesture, and a view-owned flag would keep serving the
    /// stale direction from the last thing the user touched. Worse, `previous()`
    /// restarts the track instead of moving when past 3 s, so a view that set "-1"
    /// on the gesture left it wrong even though nothing had changed.
    var songChangeDirection: Int = 1
    /// Output level, 0...1, independent of the system volume.
    ///
    /// Desktop music apps are expected to have their own fader — you set the app against
    /// everything else once and leave the system volume alone. Persisted, because a level
    /// that resets on every launch is worse than none at all.
    var volume: Double = UserDefaults.standard.object(forKey: "aura_volume") as? Double ?? 1 {
        didSet {
            applyOutputVolume()
            UserDefaults.standard.set(volume, forKey: "aura_volume")
        }
    }
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffled = false
    var repeatMode: RepeatMode = .off
    var isShowingNowPlaying = false
    var pendingArtistId: String?
    var pendingAlbumId: String?
    var isRadioMode = false
    var isShowingRadioPlaylist = false
    var pendingRadioOpen = false
    var pendingFavoritesOpen = false
    var pendingGenreName: String?
    var pendingRecentlyPlayedOpen = false
    var pendingFrequentlyPlayedOpen = false
    /// Set when the user taps a "mix" playback source on Now Playing — Home opens that mix.
    var pendingMixId: String?
    var pendingWrappedPeriod: WrappedPeriod?
    var playbackSource: PlaybackSource = .unknown
    var pendingPlaylistId: String?
    var lyrics: [LyricsLine] = []
    var lyricsSource: LyricsSource = .structured
    var lyricsStatus: String = ""
    /// True while lyrics are being fetched. The empty-state ("No lyrics available") must
    /// wait on this being false — otherwise it flashes before any source has been tried.
    var isLoadingLyrics = false
    /// Which lyrics fetch is the current one. Bumped by every `loadLyrics`, so a fetch still
    /// running for the song before — a slow server, a retry — can neither put its words on
    /// this song nor end this song's spinner when it lands.
    private var lyricsGeneration = 0
    private var lyricsTask: Task<Void, Never>?
    var isShowingQueue = false
    var radioPlaylistSongs: [Song] = []
    var radioPlaylistName: String = ""
    var radioPlaylistCoverArt: String?
    private var radioPlayedIds: Set<String> = []  // All song IDs played/queued in this radio session
    private(set) var isFetchingRadioSongs = false  // Guard against concurrent fetches
    /// Which radio is the current one. Bumped whenever a new radio replaces the last, so a
    /// fetch still running for the old one can neither add its songs to the new one nor
    /// switch off the new one's loader when it lands.
    private var radioGeneration = 0
    private var radioFetchTimestamp: Date?  // Cache: skip refetch if < 5 min old
    var sleepTimerRemaining: TimeInterval = 0
    var sleepTimerActive: Bool = false
    var sleepTimerEndOfSong: Bool = false
    var bufferProgress: Double = 0
    /// True while a freshly-selected track is loading and hasn't reached
    /// `readyToPlay` yet — drives the shimmering progress bar in Now Playing.
    var isBuffering = false
    var isBuildingQueue = false  // True while fetching similar songs for autoplay

    private var player: AVPlayer?

    /// Experimental, sideload only: the song played up or down by whole semitones. It is a
    /// turntable's pitch — the speed goes with it — since AVPlayer can't move one without the
    /// other. Held for the session, back to 0 at the next launch.
    var pitchSemitones = 0 {
        didSet { applyPitch() }
    }

    // ponytail: the Lock Screen and the car still count song time at 1×, so their progress bar
    // drifts from the real one while the pitch is off zero. Pass the rate on if this ever ships.
    private func applyPitch() {
        guard let player else { return }
        if pitchSemitones != 0 { player.currentItem?.audioTimePitchAlgorithm = .varispeed }
        let rate = Float(pow(2, Double(pitchSemitones) / 12))
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }
    private var timeObserver: Any?
    private var originalQueue: [Song] = []
    #if os(iOS)
    private var currentActivity: Activity<MusicPlaybackAttributes>?
    #endif
    private var backgroundImage: PlatformImage?
    /// Per-server key so each server profile keeps (and resumes) its own queue/track.
    /// A track from server A can't stream once you've switched to server B, so we never
    /// share one playback session across servers.
    private var lastPlaybackKey: String {
        "musika_last_playback_\(ServerManager.shared.currentServer?.id.uuidString ?? "none")"
    }
    private var sleepTimerTask: Task<Void, Never>?
    /// Watches a play actually take effect — see `confirmPlaybackStarted`.
    private var playbackWatchdog: Task<Void, Never>?
    private var playHistoryTask: Task<Void, Never>?
    /// Last fraction of the current song seen while playing, and whether it has been
    /// scrobbled — see `scrobbleIfDue`.
    private var scrobbleProgress: Double?
    private var hasScrobbledCurrent = false
    private var lastActivityUpdateTime = Date.distantPast
    private var lastActivityWasPlaying: Bool?
    private var cachedArtwork: PlatformImage?
    private var cachedArtworkSongId: String?
    private var stableCoverArtURL: String?
    private var savedPlaybackSource: PlaybackSource?
    private var autoplayFromIndex: Int?  // Index where autoplay/random-fill songs begin
    private var isSeeking = false
    /// Where the current item's stream begins in the song. Past zero once a jump ahead in a
    /// stream the server converts as it sends has asked for it again from there (see
    /// `reopen(at:)`): the player's own clock then counts from that point.
    private var streamOffset: TimeInterval = 0
    /// Playback position used to sync lyrics.
    ///
    /// No automatic output-latency compensation, deliberately. Subtracting
    /// `AVAudioSession.outputLatency` seemed principled — Bluetooth really does add
    /// 150–300 ms — but measuring on AirPods Pro 2 showed it needed cancelling out almost
    /// exactly, which means `AVPlayer.currentTime` already reports presentation time with
    /// that delay accounted for. Subtracting it again was double-counting.
    ///
    /// What remains is one manual correction, because sources genuinely disagree by a
    /// tenth of a second either way. Positive shows the words earlier.
    /// Playback position read straight from the player, rather than from its last periodic
    /// report.
    ///
    /// The time observer fires every 100ms. That is ample for a progress bar and far too
    /// coarse for anything drawn per frame: a word fade sampled at 10Hz visibly steps.
    /// AVPlayer will state its exact position whenever asked, so anything redrawing on the
    /// display link should ask rather than read `currentTime`.
    ///
    /// Falls back to the reported time while seeking, where the player's own answer is the
    /// old position until the seek lands.
    var liveTime: TimeInterval {
        guard let player, !isSeeking else { return currentTime }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? streamOffset + seconds : currentTime
    }

    /// `lyricsTime`, at whatever resolution the caller asks for it.
    var liveLyricsTime: TimeInterval { max(0, liveTime + AppSettings.shared.lyricsOffset) }

    var lyricsTime: TimeInterval {
        max(0, currentTime + AppSettings.shared.lyricsOffset)
    }

    /// Id of the most recent seek request.
    ///
    /// AVPlayer reports `finished == false` when a seek is superseded by a newer one. The
    /// old code treated that as a failure and RE-ISSUED the same target — dragging playback
    /// back to a stale position, which is what made a scrub or a rewind visibly snap back
    /// to where it had been. An interrupted seek must simply be abandoned: the newer
    /// request already owns the outcome. Only the newest completion clears `isSeeking`, so
    /// a late one can't unfreeze the clock mid-scrub either.
    private var seekGeneration = 0
    /// One-shot: a saved position to seek to as soon as the restored item is ready to play.
    private var pendingSeekTime: TimeInterval?
    private var consecutiveFailures = 0
    /// One-shot per track: prevents repeated offline error toasts/skips from the
    /// multiple AVPlayerItem failure signals a single dead item can emit.
    private var playbackErrorHandled = false
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?

    init() {
        setupAudioSession()
        setupRemoteCommands()
        restoreLastPlayback()
    }

    private func setupAudioSession() {
        // No counterpart on macOS, and none wanted: there is no audio session to claim,
        // no interruption to arbitrate with a phone call, and no route to be yanked out.
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AppLogger.shared.log("❌ Audio session setup failed: \(error.localizedDescription)")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance()
        )
        #endif
    }

    #if os(iOS)
    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            AppLogger.shared.log("🔇 Audio session interrupted — pausing")
            DispatchQueue.main.async { self.pause() }
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            AppLogger.shared.log("🔊 Interruption ended — \(shouldResume ? "resuming" : "staying paused")")
            DispatchQueue.main.async {
                // Reclaim the session either way. Without `.shouldResume` we correctly stay
                // paused, but the session stays dead too, and the *next* press of play
                // would have been a silent no-op — which is how one voice message in
                // another app used to end listening until the app was force-quit.
                self.activateAudioSession()
                if shouldResume { self.play() }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        if reason == .oldDeviceUnavailable {
            AppLogger.shared.log("🎧 Audio route lost (device unplugged) — pausing")
            DispatchQueue.main.async { self.pause() }
        }
    }
    #endif

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }

        // Some Bluetooth accessories, and macOS itself, send a single toggle rather than
        // separate play and pause. Unhandled, they did nothing at all.
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // Aura is a track player, so Control Center and the Lock Screen must show ⏮ / ⏭.
        //
        // Those two buttons are not ours to place: the system picks between track
        // navigation and interval skipping, and interval skipping wins whenever it is
        // enabled — the arrows are meant for podcasts and audiobooks, where there is no
        // next track to go to. Registering a handler on a command enables it implicitly,
        // so simply *supporting* "skip ahead thirty seconds" as a spoken command was
        // enough to replace both track buttons with ⏪15 / ⏩15 everywhere.
        //
        // Being able to change song from the Lock Screen is worth more to a music app
        // than a spoken seek, so the skip commands stay off, explicitly.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.stopCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        // Car head units and some Bluetooth remotes carry their own shuffle and repeat
        // buttons. They ask for a mode, not a toggle, so each answer lands on the one asked.
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            if (e.shuffleType != .off) != self.isShuffled { self.toggleShuffle() }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            switch e.repeatType {
            case .one: self.repeatMode = .one
            case .all: self.repeatMode = .all
            default: self.repeatMode = .off
            }
            self.syncRemoteModes()
            self.saveLastPlayback()
            return .success
        }
        syncRemoteModes()
    }

    /// Tells the system which shuffle and repeat modes are on, for the remotes that show them.
    func syncRemoteModes() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = switch repeatMode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    /// Starts something when nothing is playing.
    ///
    /// Every remote command above needs a session that already exists, so none of them can
    /// answer "play Aura" from cold — this is the one path that can. It resumes whatever is
    /// loaded if there is anything, and only reaches for the server when there is not.
    func playSomething() async {
        if currentSong != nil {
            await MainActor.run { self.play() }
            return
        }
        guard let server = ServerManager.shared.currentServer,
              let songs = try? await SubsonicClient.shared.getRandomSongs(server: server, size: 50),
              !songs.isEmpty else { return }
        await MainActor.run {
            self.playSong(songs[0], fromQueue: songs, startIndex: 0, source: .songs)
        }
    }

    private struct LastPlayback: Codable {
        let currentSong: Song
        let queue: [Song]
        let queueIndex: Int
        var userQueue: [Song] = []
        var playbackSource: PlaybackSource = .unknown
        var repeatMode: RepeatMode = .off
        /// Playback position (seconds) within `currentSong` at the moment of saving, so a
        /// cold relaunch resumes where the user left off — not just the same track at 0:00.
        var position: TimeInterval = 0
        /// Where the autoplay tail begins. Not kept before, so after a relaunch the songs
        /// autoplay added behind a one-song album went on showing as that album's.
        var autoplayFromIndex: Int?

        enum CodingKeys: String, CodingKey {
            case currentSong, queue, queueIndex, userQueue, playbackSource, repeatMode, position, autoplayFromIndex
        }

        init(currentSong: Song, queue: [Song], queueIndex: Int, userQueue: [Song] = [], playbackSource: PlaybackSource = .unknown, repeatMode: RepeatMode = .off, position: TimeInterval = 0, autoplayFromIndex: Int? = nil) {
            self.currentSong = currentSong
            self.queue = queue
            self.queueIndex = queueIndex
            self.userQueue = userQueue
            self.playbackSource = playbackSource
            self.repeatMode = repeatMode
            self.position = position
            self.autoplayFromIndex = autoplayFromIndex
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currentSong = try c.decode(Song.self, forKey: .currentSong)
            queue = try c.decode([Song].self, forKey: .queue)
            queueIndex = try c.decode(Int.self, forKey: .queueIndex)
            userQueue = try c.decodeIfPresent([Song].self, forKey: .userQueue) ?? []
            playbackSource = try c.decodeIfPresent(PlaybackSource.self, forKey: .playbackSource) ?? .unknown
            repeatMode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
            position = try c.decodeIfPresent(TimeInterval.self, forKey: .position) ?? 0
            autoplayFromIndex = try c.decodeIfPresent(Int.self, forKey: .autoplayFromIndex)
        }
    }

    private func saveLastPlayback() {
        // A preview's address expires within the hour: the session to come back to is the
        // last one played from the server.
        guard let song = currentSong, !song.isPreview else { return }
        let state = LastPlayback(currentSong: song, queue: queue, queueIndex: queueIndex, userQueue: userQueue, playbackSource: playbackSource, repeatMode: repeatMode, position: currentTime, autoplayFromIndex: autoplayFromIndex)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: lastPlaybackKey)
        }
    }

    /// Persist the current session — song, queue, AND live playback position — so a cold
    /// relaunch resumes exactly where the user left off. Call when the app leaves the
    /// foreground: iOS can terminate a backgrounded app with no further callback, and the
    /// periodic saves elsewhere fire on track changes (position 0), not mid-song.
    func persistPlaybackState() { saveLastPlayback() }

    private func restoreLastPlayback() {
        guard let data = UserDefaults.standard.data(forKey: lastPlaybackKey),
              let state = try? JSONDecoder().decode(LastPlayback.self, from: data) else { return }
        currentSong = state.currentSong
        queue = state.queue
        originalQueue = state.queue
        queueIndex = state.queueIndex
        userQueue = state.userQueue
        playbackSource = state.playbackSource
        repeatMode = state.repeatMode
        autoplayFromIndex = state.autoplayFromIndex
        leaveSourceIfForeign(state.currentSong)
        // Restore radioPlaylistName from persisted source
        if case .radio(let name) = state.playbackSource {
            radioPlaylistName = name
        }
        // Resume at the saved position: show it right away, and stash it so the seek fires
        // once the player item is ready (see the readyToPlay handler in observePlayerItem).
        if state.position > 1 {
            currentTime = state.position
            pendingSeekTime = state.position
        }
        // Prepare the player so pressing play works immediately
        preparePlayback(state.currentSong)
    }

    /// Called by `ServerManager` *before* switching to a different server. Persists the
    /// current session under the outgoing server's key, then tears the live player down —
    /// its tracks stop being reachable the moment we point the app at another server, so we
    /// must not leave a dead item loaded (that's what used to make the queue unplayable).
    func prepareForServerSwitch() {
        saveLastPlayback()                 // capture outgoing server's queue/track under ITS key
        playHistoryTask?.cancel()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false
        isBuffering = false
        currentSong = nil
        queue = []
        originalQueue = []
        userQueue = []
        queueIndex = 0
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Called by `ServerManager` *after* `currentServer` is set to the new server. Restores
    /// that server's saved session (prepared but paused, so a single tap resumes it). If the
    /// server has no prior session, playback simply stays cleared.
    func restoreForCurrentServer() {
        restoreLastPlayback()
    }

    /// The item for a song: its preview's address for a release not on the server, else the
    /// download, the cache or the server's stream.
    private func makePlayerItem(for song: Song, server: ServerConfig, bitRate: Int?) -> AVPlayerItem {
        if let preview = song.preview, let url = URL(string: preview) {
            return AVPlayerItem(url: url)
        }
        return AudioCacheManager.shared.playerItem(songId: song.id, server: server, bitRate: bitRate,
                                                  songSuffix: song.suffix, songContentType: song.contentType)
    }

    /// Load the stream URL and set up AVPlayer without starting playback
    private func preparePlayback(_ song: Song) {
        if !song.isPreview { AudioCacheManager.shared.saveMetadata(song) }
        // Restored session (launch / server switch): warm its art too, so opening Now
        // Playing straight after launch is instant.
        ArtworkCache.shared.prefetchNowPlayingCover(coverArt: song.coverArt ?? song.albumId)
        guard let server = ServerManager.shared.currentServer else { return }
        let bitRate = AppSettings.shared.streamingQuality.bitRate

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        streamOffset = 0
        isSeeking = false

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemNewErrorLogEntry, object: nil)

        let playerItem = makePlayerItem(for: song, server: server, bitRate: bitRate)
        observePlayerItem(playerItem, song: song)
        observeBuffer(playerItem, songId: song.id)
        EqualizerManager.shared.attachToPlayerItem(playerItem, fadeOut: song.isPreview ? Self.previewFade : nil)
        player = AVPlayer(playerItem: playerItem)
        applyPitch()
        applyOutputVolume(for: song)
        resetScrobbleProgress()
        player?.pause()

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            self.currentTime = self.streamOffset + time.seconds
            // A stream begun partway is only the rest of the song: its length isn't the song's.
            if self.streamOffset == 0, let d = self.player?.currentItem?.duration.seconds, !d.isNaN {
                self.duration = d
            }
            self.updateNowPlayingInfo()
            self.scrobbleIfDue()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime, object: playerItem
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerItemFailedToPlayToEnd(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerItemNewErrorLogEntry(_:)),
            name: .AVPlayerItemNewErrorLogEntry, object: playerItem
        )

        if let songDuration = song.duration, songDuration > 0 {
            duration = Double(songDuration)
        }

        isPlaying = false
        if let coverArt = song.coverArt, let srv = ServerManager.shared.currentServer {
            stableCoverArtURL = SubsonicClient.shared.coverArtURL(server: srv, id: coverArt, size: ArtworkCache.thumbSize)?.absoluteString
        }
        updateNowPlayingInfo()
    }

    /// Play a list of songs in shuffled order, preserving the *real* order in `originalQueue`
    /// so toggling shuffle off later restores the natural sequence.
    func playShuffled(_ songs: [Song], source: PlaybackSource = .unknown) {
        guard !songs.isEmpty else { return }
        AppLogger.shared.log("🎲 playShuffled: \(songs.count) songs | source: \(source)")
        let pick = songs.randomElement() ?? songs[0]
        isRadioMode = false
        playbackSource = source
        autoplayFromIndex = nil
        userQueue = []
        originalQueue = songs
        isShuffled = true
        songChangeDirection = 1
        var rest = songs.filter { $0.id != pick.id }
        rest.shuffle()
        queue = [pick] + rest
        queueIndex = 0
        currentSong = pick
        startPlayback(pick)
        saveLastPlayback()
    }

    func playSong(_ song: Song, fromQueue songs: [Song]? = nil, startIndex: Int = 0, source: PlaybackSource = .unknown) {
        AppLogger.shared.log("🎵 playSong: \(song.title) | queue: \(songs?.count ?? 1) songs | idx: \(startIndex)")
        if case .radio = source {} else { isRadioMode = false }
        self.playbackSource = source
        self.autoplayFromIndex = nil  // Reset autoplay boundary
        // A picked song isn't "back" from anywhere — always slide in forward.
        self.songChangeDirection = 1
        userQueue = []
        if let songs = songs, songs.count > 1 {
            originalQueue = songs
            queue = songs
            queueIndex = startIndex
        } else {
            originalQueue = [song]
            queue = [song]
            queueIndex = 0
            // Single song or no queue — fill with random songs for autoplay. Not after a
            // preview: the release is what was asked for, not the library around it.
            if !song.isPreview { Task { await fillQueueWithRandomSongs(around: song) } }
        }
        if isShuffled { shuffleQueue() }
        currentSong = song
        startPlayback(song)
        saveLastPlayback()
    }

    /// Bumped by every fill. A fetch that finishes after a newer one started — or after
    /// the user moved on — compares its captured value and stands down.
    private var autoplayFillGeneration = 0

    func fillQueueWithRandomSongs(around song: Song) async {
        guard !AppSettings.shared.offlineMode else { return }
        guard let server = ServerManager.shared.currentServer else { return }
        let generation = await MainActor.run { () -> Int in
            autoplayFillGeneration += 1
            isBuildingQueue = true
            return autoplayFillGeneration
        }
        defer { Task { @MainActor in
            if self.autoplayFillGeneration == generation { self.isBuildingQueue = false }
        } }

        // Two sources, asked at the same time rather than one after the other.
        // Random songs answer in about a second and exist so the queue is never
        // empty; similar songs are the ones actually worth having, but they come
        // from the server's Last.fm agent, which takes twenty seconds on a good
        // day and over a minute when Last.fm doesn't answer. Waiting for them in
        // sequence is what left "Nothing in the queue" on screen long after the
        // music had started.
        async let similarFetch = try? SubsonicClient.shared.getSimilarSongs2(server: server, id: song.id, count: 50)
        async let nearbyFetch = buildSimilarTail(for: song, server: server, limit: 50)

        let nearby = await nearbyFetch
        if !nearby.isEmpty, await applyAutoplay(nearby, around: song, generation: generation) {
            AppLogger.shared.log("🎵 Autoplay: seeded with \(nearby.count) songs from nearby artists and genre")
        }

        guard let similar = await similarFetch, !similar.isEmpty else {
            if nearby.isEmpty {
                AppLogger.shared.log("🎵 Autoplay: nothing to queue behind \(song.title)", level: .warning)
            }
            return
        }

        // De-duplicate by id. getSimilarSongs2 (Last.fm-backed) can repeat the
        // same track — and sometimes the seed itself — inside one response. A queue
        // holding duplicate ids breaks everything keyed on id: SwiftUI's queue list
        // (a tap lands on the FIRST row sharing that id) and every firstIndex(where:id)
        // that positions queueIndex. That's what made the queue appear to "loop back
        // to the first song". Keep only the first occurrence of each id.
        var autoplaySongs = Self.deduplicated(similar, excluding: song.id)
        let removed = similar.count - autoplaySongs.count
        if removed > 0 {
            AppLogger.shared.log("🎵 Autoplay: dropped \(removed) duplicate similar song(s)", level: .warning)
        }

        // Too few to carry a listening session on their own — pad from the tail
        // already in hand rather than asking the server a second time.
        if autoplaySongs.count < 20, !nearby.isEmpty {
            let taken = Set(autoplaySongs.map { $0.id } + [song.id])
            autoplaySongs += nearby.filter { !taken.contains($0.id) }.prefix(50 - autoplaySongs.count)
        }

        if await applyAutoplay(autoplaySongs, around: song, generation: generation) {
            AppLogger.shared.log("🎵 Autoplay: upgraded to \(autoplaySongs.count) similar songs")
        } else {
            AppLogger.shared.log("🎵 Autoplay: similar songs arrived too late — queue had moved on")
        }
    }

    /// Songs that actually belong next to `song`, found without waiting on the
    /// server's recommendation agent.
    ///
    /// Navidrome answers `getSimilarSongs2` by asking Last.fm for similar artists and
    /// then for the top tracks of each, one HTTP call at a time — measured at twenty
    /// to seventy seconds on a cold cache. This asks for the similar artists only, a
    /// single call it answers in about a second, and then reads their music straight
    /// out of the library, which is a local database query. Same idea, a second
    /// instead of half a minute, and every track is one you own.
    private func buildSimilarTail(for song: Song, server: ServerConfig, limit: Int) async -> [Song] {
        async let nearbyFetch = songsByArtistsNear(song, server: server)
        async let genreFetch: [Song] = {
            guard let genre = song.genre, !genre.isEmpty else { return [] }
            return (try? await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre, count: 100)) ?? []
        }()

        let nearby = await nearbyFetch
        var genre = await genreFetch

        // Prefer the same era when the seed is dated — a 1974 chanson and a 2024 one
        // share a genre label and very little else.
        if let seedYear = song.year, seedYear > 0 {
            genre.sort { a, b in
                let da = a.year.map { abs($0 - seedYear) } ?? Int.max
                let db = b.year.map { abs($0 - seedYear) } ?? Int.max
                return da < db
            }
        } else {
            genre.shuffle()
        }

        // Artists the server calls close come first; the genre pool is what keeps the
        // queue long enough to be worth having.
        var tail = Self.deduplicated(nearby.shuffled() + genre, excluding: song.id)
        if tail.count < 10 {
            // No artist match and no genre — a library with bare tags. Rather than
            // leave the queue empty, fall back to whatever the server offers.
            let random = (try? await SubsonicClient.shared.getRandomSongs(server: server, size: 50)) ?? []
            tail = Self.deduplicated(tail + random, excluding: song.id)
        }
        return Array(tail.prefix(limit))
    }

    /// Up to two albums' worth of music from each artist the server places near this
    /// one, fetched concurrently. Every call here hits the library, not the internet.
    private func songsByArtistsNear(_ song: Song, server: ServerConfig) async -> [Song] {
        guard let artistId = song.artistId, !artistId.isEmpty else { return [] }
        guard let info = try? await SubsonicClient.shared.getArtistInfo2(server: server, id: artistId, count: 12),
              let similar = info.similarArtist, !similar.isEmpty else { return [] }

        // The seed's own artist belongs in the mix too, and costs nothing extra.
        let ids = ([artistId] + similar.map(\.id)).filter { !$0.isEmpty }.prefix(10)

        return await withTaskGroup(of: [Song].self) { group in
            for id in ids {
                group.addTask {
                    guard let artist = try? await SubsonicClient.shared.getArtist(server: server, id: id),
                          let albums = artist.album else { return [] }
                    var songs: [Song] = []
                    for album in albums.shuffled().prefix(2) {
                        if let full = try? await SubsonicClient.shared.getAlbum(server: server, id: album.id) {
                            songs += full.song ?? []
                        }
                    }
                    return songs
                }
            }
            var all: [Song] = []
            for await songs in group { all += songs }
            return all
        }
    }

    private static func deduplicated(_ songs: [Song], excluding seedId: String) -> [Song] {
        var seen: Set<String> = [seedId]
        return songs.filter { seen.insert($0.id).inserted }
    }

    /// Installs an autoplay tail behind `song`, but only while the queue is still the
    /// one this fill is entitled to write: same seed, still sitting on it, nothing the
    /// listener has queued or played since. Returns whether it was applied.
    @MainActor
    private func applyAutoplay(_ autoplaySongs: [Song], around song: Song, generation: Int) -> Bool {
        guard autoplayFillGeneration == generation else { return false }
        guard userQueue.isEmpty else { return false }
        guard queueIndex == 0, queue.first?.id == song.id, currentSong?.id == song.id else { return false }
        // Either an untouched single-song queue, or the tail an earlier pass of this
        // same fill put there. Anything else is a real context and not ours to replace.
        guard queue.count <= 1 || autoplayFromIndex == 1 else { return false }

        queue = [song] + autoplaySongs
        originalQueue = queue
        queueIndex = 0
        autoplayFromIndex = 1  // Songs after index 0 are autoplay
        if isShuffled { shuffleQueue() }
        saveLastPlayback()
        return true
    }

    private var hasPrefetchedNext = false

    // MARK: - Offline playability

    /// Effectively offline: offline mode is on (manual or auto), or the device has
    /// no network path at all — either way only local audio can play.
    private var isEffectivelyOffline: Bool {
        AppSettings.shared.offlineMode || !ServerManager.shared.hasNetwork
    }

    /// True when the song can play without the server: a permanent download exists,
    /// or the stream cache has its audio on disk.
    func isPlayableOffline(_ song: Song) -> Bool {
        if DownloadManager.shared.localURL(for: song.id) != nil { return true }
        let bitRate = AppSettings.shared.streamingQuality.bitRate
        return AudioCacheManager.shared.hasCachedAudio(for: song, bitRate: bitRate)
    }

    /// While effectively offline, advance to the next offline-playable song in the
    /// queue (user queue first, then a single bounded pass over the main queue).
    /// Pauses with a toast when nothing in the queue is playable.
    private func skipToNextPlayableOffline() {
        // User queue first — mirrors next()'s priority.
        while !userQueue.isEmpty {
            let song = userQueue.removeFirst()
            if isPlayableOffline(song) {
                if savedPlaybackSource == nil { savedPlaybackSource = playbackSource }
                playbackSource = .queue
                songChangeDirection = 1
                currentSong = song
                startPlayback(song)
                saveLastPlayback()
                return
            }
        }
        let count = queue.count
        if count > 1 {
            for offset in 1..<count {
                let idx = (queueIndex + offset) % count
                if isPlayableOffline(queue[idx]) {
                    queueIndex = idx
                    if let autoIdx = autoplayFromIndex, idx >= autoIdx, playbackSource != .autoplay {
                        playbackSource = .autoplay
                    }
                    leaveSourceIfForeign(queue[idx])
                    AppLogger.shared.log("⏭ Offline skip → idx \(idx): \(queue[idx].title)")
                    // This walks the queue forward like next() does, so it has to say so —
                    // otherwise the artwork slides using whatever the last manual action left.
                    songChangeDirection = 1
                    currentSong = queue[idx]
                    startPlayback(queue[idx])
                    saveLastPlayback()
                    return
                }
            }
        }
        AppLogger.shared.log("⏸ Offline: no playable songs left in queue")
        player?.pause()
        isPlaying = false
        endLiveActivity()
        ToastManager.shared.show("No offline songs in queue", icon: "wifi.slash")
    }

    /// Warm the hero artwork for the tracks on either side of the current one.
    ///
    /// Only the *current* song's art used to be prefetched, so skipping showed a
    /// placeholder while the next cover downloaded — the wait landed exactly on the
    /// interaction. Both directions are warmed because the Now Playing cover can be
    /// swiped backwards as well as forwards.
    private func prefetchNeighbourCovers() {
        // Three ahead, two back. One each way was not enough: swiping quickly through the
        // Now Playing artwork outruns a single-song buffer and you land on a cover that
        // hasn't started loading.
        //
        // Widening costs almost nothing in steady state. Advancing one song shifts the
        // window by one, so only the newly exposed track actually needs fetching — the
        // rest were warmed on the previous change and are already cached.
        let forward = 3, backward = 2
        var neighbours: [Song] = Array(userQueue.prefix(forward))
        if !queue.isEmpty {
            for step in 1...forward {
                let index = (queueIndex + step) % queue.count
                if index != queueIndex { neighbours.append(queue[index]) }
            }
            for step in 1...backward where queueIndex - step >= 0 {
                neighbours.append(queue[queueIndex - step])
            }
        }
        // A song can sit in both the user queue and the main queue; fetch it once.
        var seen: Set<String> = []
        for song in neighbours where seen.insert(song.id).inserted {
            // Utility, not userInitiated: these must never compete for a download slot with
            // the cover actually on screen.
            ArtworkCache.shared.prefetchNowPlayingCover(coverArt: song.coverArt ?? song.albumId,
                                                        priority: .utility)
        }
    }

    private func startPlayback(_ song: Song, renewing: Bool = true) {
        // A preview's address runs out a quarter of an hour after Deezer hands it out, and a
        // radar queue plays for longer than that: an expired one is asked for again first.
        #if os(iOS)
        if renewing, let preview = song.preview, RadarRules.previewExpired(preview) {
            renewPreview(song)
            return
        }
        #endif
        if !song.isPreview { AudioCacheManager.shared.saveMetadata(song) }
        // Warm the Now Playing artwork as soon as the track starts, not when the screen
        // opens — by the time the user swipes up, it's already there.
        ArtworkCache.shared.prefetchNowPlayingCover(coverArt: song.coverArt ?? song.albumId)
        // ...and the neighbours, so a skip swaps to art that is already in memory instead
        // of starting its download at the moment the user asks for it.
        prefetchNeighbourCovers()
        guard let server = ServerManager.shared.currentServer else {
            AppLogger.shared.log("❌ startPlayback: no server configured")
            return
        }
        // Offline guard: never silently hand AVPlayer a stream URL it can't load.
        if isEffectivelyOffline && !isPlayableOffline(song) {
            AppLogger.shared.log("📴 Not available offline: \(song.title) — skipping")
            ToastManager.shared.show("Not available offline", icon: "wifi.slash")
            skipToNextPlayableOffline()
            return
        }
        playbackErrorHandled = false
        let bitRate = AppSettings.shared.streamingQuality.bitRate
        AppLogger.shared.log("▶️ Playing: \(song.title) by \(song.artist ?? "Unknown") | bitRate: \(bitRate) | id: \(song.id)")
        currentTime = 0
        duration = 0

        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil

        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemNewErrorLogEntry, object: nil)

        hasPrefetchedNext = false
        resetScrobbleProgress()
        isSeeking = false
        streamOffset = 0
        bufferProgress = 0
        let playerItem = makePlayerItem(for: song, server: server, bitRate: bitRate)
        observePlayerItem(playerItem, song: song)
        observeBuffer(playerItem, songId: song.id)
        EqualizerManager.shared.attachToPlayerItem(playerItem, fadeOut: song.isPreview ? Self.previewFade : nil)
        player = AVPlayer(playerItem: playerItem)
        applyPitch()
        // This path never applied the fader: every song started from here played at full
        // level until the fader was next touched.
        applyOutputVolume(for: song)
        watchPlayback(of: playerItem)

        // Initialize duration from song metadata so Now Playing info shows it immediately
        if let songDuration = song.duration, songDuration > 0 {
            duration = Double(songDuration)
        }

        // The same claim the play button makes. Without it a track change simply
        // inherited whatever state the session was left in: after an interruption — a
        // call, a voice prompt in another app — the session is dead, `play()` on it is a
        // silent no-op, and the queue looked like it had stopped of its own accord at the
        // end of a song. The watchdog then covers the other half of that failure, where
        // the session comes back but the item is still dead.
        activateAudioSession()
        player?.play()
        isPlaying = true
        currentSong = song
        publishPlaybackState()
        confirmPlaybackStarted()
        announce(song)
    }

    /// The clock, the prefetch at 80%, the scrobble, and the end or failure of the item.
    private func watchPlayback(of playerItem: AVPlayerItem) {
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            self.currentTime = self.streamOffset + time.seconds
            // A stream begun partway is only the rest of the song: its length isn't the song's.
            if self.streamOffset == 0, let d = self.player?.currentItem?.duration.seconds, !d.isNaN {
                self.duration = d
            }
            self.updateNowPlayingInfo()

            // Prefetch next track at ~80% progress
            if !self.hasPrefetchedNext, self.duration > 0, self.currentTime / self.duration >= 0.8 {
                self.hasPrefetchedNext = true
                self.prefetchNextTrack()
            }
            self.scrobbleIfDue()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime, object: playerItem
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerItemFailedToPlayToEnd(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerItemNewErrorLogEntry(_:)),
            name: .AVPlayerItemNewErrorLogEntry, object: playerItem
        )
    }

    /// What follows a song starting: history, lyrics, artwork, the Lock Screen, the radio.
    private func announce(_ song: Song) {
        // Local history only — what Wrapped and the stats count — on the rule it has
        // always used, half the song or 30 seconds. The server scrobble is separate: it
        // follows the "Scrobble After" setting on the playback position, in
        // `scrobbleIfDue`.
        playHistoryTask?.cancel()
        playHistoryTask = Task {
            let songDuration = Double(song.duration ?? 0)
            let delay = songDuration > 0 ? min(30.0, songDuration / 2) : 30.0
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !song.isPreview else { return }
            PlayHistory.shared.record(song: song)
        }

        loadLyrics(for: song)
        // Clear cached artwork for new song, pre-populate stable cover URL
        cachedArtwork = nil
        cachedArtworkSongId = nil
        if let coverArt = song.coverArt, let srv = ServerManager.shared.currentServer {
            stableCoverArtURL = SubsonicClient.shared.coverArtURL(server: srv, id: coverArt, size: ArtworkCache.thumbSize)?.absoluteString
        } else {
            stableCoverArtURL = nil
        }
        updateNowPlayingInfo()
        startLiveActivity(for: song)

        if isRadioMode && queueIndex >= queue.count - 2 {
            // Evolving seed: use the current song as the new seed, not the original
            startSmartRadioFetch(seed: song)
        }
    }

    @objc private func playerDidFinish() {
        DispatchQueue.main.async { [weak self] in
            self?.handlePlayerDidFinish()
        }
    }

    private func handlePlayerDidFinish() {
        AppLogger.shared.log("⏭ playerDidFinish | repeatMode: \(repeatMode) | queueIdx: \(queueIndex)/\(queue.count) | radio: \(isRadioMode)")
        if sleepTimerEndOfSong {
            AppLogger.shared.log("😴 Sleep timer (end of song) — pausing")
            pause()
            cancelSleepTimer()
            return
        }
        switch repeatMode {
        case .one:
            if let song = currentSong { startPlayback(song) }
        case .all:
            next()
        case .off:
            if queueIndex < queue.count - 1 {
                next()
            } else if isRadioMode {
                next()
            } else if currentSong?.isPreview == true {
                // The release's previews have all played: nothing on the server follows them.
                pause()
                seek(to: 0)
            } else {
                // Auto-start radio when single song ends with nothing next.
                // Radio needs the server — never kick it off while offline.
                if let song = currentSong, !isEffectivelyOffline {
                    isRadioMode = true
                    beginNewRadio()
                    isFetchingRadioSongs = true  // Claimed here: this path awaits the fetch itself
                    let generation = radioGeneration
                    radioPlaylistName = "Radio: \(song.title)"
                    radioPlaylistSongs = [song]
                    radioPlayedIds = Set(queue.map { $0.id })
                    radioPlayedIds.insert(song.id)
                    playbackSource = .radio(name: radioPlaylistName)
                    Task {
                        await fetchSmartRadioSongs(seed: song, generation: generation)
                        await MainActor.run {
                            // Another radio took over while this one loaded — not ours to advance.
                            guard self.radioGeneration == generation else { return }
                            if self.queue.count > self.queueIndex + 1 {
                                self.next()
                            } else {
                                self.isPlaying = false
                                self.endLiveActivity()
                            }
                        }
                    }
                } else {
                    isPlaying = false
                    endLiveActivity()
                }
            }
        }
    }

    private func observeBuffer(_ playerItem: AVPlayerItem, songId: String) {
        bufferObservation?.invalidate()
        bufferObservation = playerItem.observe(\.loadedTimeRanges, options: [.new]) { item, _ in
            guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return }
            let buffered = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)
            let dur = CMTimeGetSeconds(item.duration)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentSong?.id == songId else { return }
                // A stream the server converts as it sends states no length, and one begun
                // partway counts from there: both are measured against the song's own.
                let length = self.streamOffset == 0 && dur > 0 ? dur : self.duration
                self.bufferProgress = length > 0 ? min((self.streamOffset + buffered) / length, 1.0) : 0
            }
        }
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem, song: Song) {
        isBuffering = true
        playerItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { item, _ in
            switch item.status {
            case .unknown:
                AppLogger.shared.log("🎧 PlayerItem status unknown for \(song.title)")
            case .readyToPlay:
                AppLogger.shared.log("✅ PlayerItem readyToPlay for \(song.title)")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.consecutiveFailures = 0
                    self.isBuffering = false
                    // Resume from the position saved at last quit (one-shot). Applied here
                    // because seeking before the item is ready is unreliable.
                    // Through `seek(to:)`, so a stream that can't reach it yet is asked for
                    // again from there rather than left at the start.
                    if let resume = self.pendingSeekTime {
                        self.pendingSeekTime = nil
                        self.seek(to: resume)
                    }
                }
            case .failed:
                AppLogger.shared.log("❌ PlayerItem failed for \(song.title): \(item.error?.localizedDescription ?? "unknown error")")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.currentSong?.id == song.id else { return }
                    self.isBuffering = false
                    if self.isEffectivelyOffline {
                        self.handleOfflinePlaybackError()
                        return
                    }
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures >= 3 {
                        AppLogger.shared.log("🛑 Stopping playback: \(self.consecutiveFailures) consecutive failures (server may be unreachable)")
                        ToastManager.shared.show("Playback stopped — server unreachable", icon: "exclamationmark.icloud")
                        self.isPlaying = false
                        self.consecutiveFailures = 0
                    } else if self.queueIndex < self.queue.count - 1 {
                        AppLogger.shared.log("⏭ Auto-skipping failed track (\(self.consecutiveFailures)/3): \(song.title)")
                        ToastManager.shared.show("Couldn't play \"\(song.title)\" — skipped", icon: "forward.fill")
                        self.next()
                    } else {
                        AppLogger.shared.log("⏸ No more tracks after failed: \(song.title)")
                        ToastManager.shared.show("Couldn't play \"\(song.title)\"", icon: "exclamationmark.triangle")
                        self.isPlaying = false
                    }
                }
            @unknown default:
                AppLogger.shared.log("⚠️ PlayerItem returned an unknown future status for \(song.title)")
            }
        }
    }

    @objc private func playerItemFailedToPlayToEnd(_ notification: Notification) {
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        AppLogger.shared.log("❌ playerItemFailedToPlayToEnd: \(error?.localizedDescription ?? "unknown error")")
        DispatchQueue.main.async { [weak self] in
            self?.handleStreamEndedEarly()
        }
    }

    @objc private func playerItemNewErrorLogEntry(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              let event = playerItem.errorLog()?.events.last else {
            AppLogger.shared.log("⚠️ PlayerItem emitted an empty error log entry")
            return
        }

        AppLogger.shared.log(
            "❌ PlayerItem errorLog: domain=\(event.errorDomain) status=\(event.errorStatusCode) comment=\(event.errorComment ?? "n/a") uri=\(event.uri ?? "n/a") server=\(event.serverAddress ?? "n/a")"
        )
        DispatchQueue.main.async { [weak self] in
            self?.handleOfflinePlaybackError()
        }
    }

    /// Offline recovery for a track AVPlayer can't load: toast once and move on to
    /// the next locally-playable song instead of failing silently.
    private func handleOfflinePlaybackError() {
        guard isEffectivelyOffline, !playbackErrorHandled else { return }
        playbackErrorHandled = true
        AppLogger.shared.log("📴 Playback error while offline — advancing to next playable song")
        ToastManager.shared.show("Not available offline", icon: "wifi.slash")
        skipToNextPlayableOffline()
    }

    /// A stream that broke instead of finishing.
    ///
    /// `AVPlayerItemDidPlayToEndTime` never arrives for these, and online this was the
    /// end of it: the error was logged and nothing else happened. The song stopped —
    /// typically seconds from its end, where a dropped connection is least likely to be
    /// noticed as one — the queue never advanced, and the result was indistinguishable
    /// from the app having paused itself. A queue does not stop because one stream died.
    ///
    /// From the queue's point of view this is simply the track being over, so it takes
    /// the ordinary end-of-track path: repeat, user queue, next, radio, all of it. The
    /// exception is repeat-one, where replaying an item that just failed would fail the
    /// same way, forever.
    private func handleStreamEndedEarly() {
        if isEffectivelyOffline { handleOfflinePlaybackError(); return }
        guard !playbackErrorHandled else { return }
        playbackErrorHandled = true
        AppLogger.shared.log("⚠️ Stream ended early at \(Int(currentTime))s/\(Int(duration))s — treating as end of track")
        if repeatMode == .one { next() } else { handlePlayerDidFinish() }
    }

    #if os(iOS)
    /// Plays a preview from a freshly signed address, put in its place in the queue too. If
    /// Deezer can't be reached, the old address is tried anyway and fails like any stream.
    private func renewPreview(_ song: Song) {
        let trackId = String(song.id.dropFirst("deezer-".count))
        Task { @MainActor [weak self] in
            let address = await RadarCatalog.previewAddress(trackId: trackId)
            guard let self, self.currentSong?.id == song.id else { return }
            guard let address else {
                self.startPlayback(song, renewing: false)
                return
            }
            var renewed = song
            renewed.preview = address
            self.queue = self.queue.map { $0.id == song.id ? renewed : $0 }
            self.originalQueue = self.originalQueue.map { $0.id == song.id ? renewed : $0 }
            self.currentSong = renewed
            self.startPlayback(renewed, renewing: false)
        }
    }
    #endif

    // MARK: - Output level

    /// Sets the player's level: the app's own fader, times the song's ReplayGain.
    /// Every place a player is created goes through here, and so does the toggle.
    func applyOutputVolume(for song: Song? = nil) {
        player?.volume = Float(volume * replayGainFactor(for: song ?? currentSong))
    }

    /// ReplayGain as a multiplier of the fader, or 1 when it is off or the song has none.
    ///
    /// Track gain first, album gain as the fallback. Capped at 1, because `AVPlayer.volume`
    /// can only attenuate: loud masters come down to the reference level and quiet ones
    /// stay where they are. That narrows the gap between them rather than closing it —
    /// which is also how most mobile players do it without a DSP of their own.
    private func replayGainFactor(for song: Song?) -> Double {
        guard AppSettings.shared.replayGain,
              let gain = song?.replayGain?.trackGain ?? song?.replayGain?.albumGain
        else { return 1 }
        return min(1, pow(10, gain / 20))
    }

    // MARK: - Scrobbling

    private func resetScrobbleProgress() {
        scrobbleProgress = nil
        hasScrobbledCurrent = false
    }

    /// Scrobbles the current song when its playback position *crosses* the "Scrobble
    /// After" share, while playing.
    ///
    /// Position rather than time: the old timer ran on the wall clock, so a song paused a
    /// few seconds in was scrobbled anyway once the timer ran out. Crossing rather than
    /// being past: a song restored at launch already beyond the threshold was scrobbled in
    /// the session that played it, and must not be counted twice.
    private func scrobbleIfDue() {
        guard isPlaying, duration > 0 else { return }
        let fraction = currentTime / duration
        let previous = scrobbleProgress
        scrobbleProgress = fraction
        let threshold = AppSettings.shared.scrobbleThreshold
        guard !hasScrobbledCurrent, let previous, previous < threshold, fraction >= threshold,
              let song = currentSong, !song.isPreview else { return }
        hasScrobbledCurrent = true
        guard AppSettings.shared.scrobbleEnabled,
              let server = ServerManager.shared.currentServer else { return }
        Task {
            do {
                try await SubsonicClient.shared.scrobble(server: server, id: song.id)
            } catch {
                // Offline or failed — queued, and sent once the server is back.
                ScrobbleQueue.shared.enqueue(songId: song.id)
            }
        }
    }

    func play() {
        AppLogger.shared.log("▶️ play()")
        // If the session refuses us, say so instead of flipping the button to "playing"
        // over silence. A play that cannot happen is not a play.
        guard activateAudioSession() else {
            isPlaying = false
            publishPlaybackState()
            return
        }
        player?.play(); isPlaying = true; publishPlaybackState(); updateLiveActivity()
        confirmPlaybackStarted()
    }

    /// Checks shortly after a play that sound is actually coming out, and rebuilds the
    /// item if it is not.
    ///
    /// Reclaiming the session is necessary but not sufficient: an interruption can leave
    /// the *item* dead too. The session comes back, `play()` returns without complaint,
    /// and the player simply sits at paused — which is why changing track appeared to fix
    /// it, since that is the one action that builds a fresh item. This does that itself,
    /// at the same position, rather than leaving the user to discover the workaround.
    private func confirmPlaybackStarted() {
        #if os(iOS)
        playbackWatchdog?.cancel()
        guard let song = currentSong else { return }
        playbackWatchdog = Task { @MainActor [weak self] in
            // Long enough that a slow start is not mistaken for a dead one; short enough
            // that the user has not yet reached for the button a second time.
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled,
                  self.isPlaying, self.currentSong?.id == song.id else { return }
            // `paused` is the telling state. A player that is merely buffering reports
            // `waitingToPlayAtSpecifiedRate`, so this cannot mistake a slow network for a
            // dead item.
            let refused = self.player?.timeControlStatus == .paused
                || self.player?.currentItem?.status == .failed
            guard refused else { return }
            AppLogger.shared.log("⚠️ Playback never started — rebuilding the item at \(Int(self.currentTime))s")
            let resume = self.currentTime
            self.preparePlayback(song)
            if resume > 1 { self.pendingSeekTime = resume }
            _ = self.activateAudioSession()
            self.player?.play()
        }
        #endif
    }

    /// Claims the audio session before playing.
    ///
    /// Anything that interrupts us — a call, a voice message in another app — leaves our
    /// session deactivated, and the system does not hand it back. `AVPlayer.play()` on a
    /// dead session fails silently, so playback would stop while `isPlaying` went on
    /// saying otherwise: the button read "playing", nothing came out, and every later tap
    /// did the same. Reclaiming here is idempotent and costs nothing when we already hold
    /// it, and it means no missed notification can strand playback for the whole session.
    @discardableResult
    private func activateAudioSession() -> Bool {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            AppLogger.shared.log("❌ Could not claim the audio session: \(error.localizedDescription)")
            return false
        }
        #else
        return true
        #endif
    }
    func pause() {
        AppLogger.shared.log("⏸ pause()")
        playbackWatchdog?.cancel()
        player?.pause(); isPlaying = false; publishPlaybackState(); updateLiveActivity()
    }

    /// Tells the system whether we are playing.
    ///
    /// macOS will not treat an app as the Now Playing app at all until it publishes one, so
    /// without this the media keys, the Touch Bar and Control Centre go on addressing
    /// whatever was there before it. iOS can infer the state from the playback rate and so
    /// never strictly needed it — but the rate is ambiguous while paused with the session
    /// deactivated, which is exactly when Siri is asked to resume. Stated on both.
    private func publishPlaybackState() {
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
    func togglePlayPause() { if isPlaying { pause() } else { play() } }

    /// Begin caching the next track in queue when the current song is near completion
    private func prefetchNextTrack() {
        guard let server = ServerManager.shared.currentServer else { return }
        let bitRate = AppSettings.shared.streamingQuality.bitRate

        // Determine next song: user queue first, then main queue
        let nextSong: Song?
        if !userQueue.isEmpty {
            nextSong = userQueue.first
        } else if queueIndex + 1 < queue.count {
            nextSong = queue[queueIndex + 1]
        } else if repeatMode == .all, !queue.isEmpty {
            nextSong = queue[0]
        } else {
            nextSong = nil
        }

        guard let song = nextSong, !song.isPreview else { return }
        AudioCacheManager.shared.prefetch(songId: song.id, server: server, bitRate: bitRate, songSuffix: song.suffix, songContentType: song.contentType)
    }

    /// A song that isn't on the album Now Playing names was added after it — by autoplay,
    /// whatever the queue's bookkeeping says. It stops showing, and leading back to, an
    /// album it isn't on.
    private func leaveSourceIfForeign(_ song: Song) {
        guard case .album(let id, _) = playbackSource, let albumId = song.albumId, albumId != id else { return }
        playbackSource = .autoplay
    }

    func next() {
        AppLogger.shared.log("⏭ next() request | queueCount: \(queue.count) | queueIdx: \(queueIndex) | current: \(currentSong?.title ?? "nil")")

        // Play from user queue first (songs added via "Add to Queue" / "Play Next")
        if !userQueue.isEmpty {
            let song = userQueue.removeFirst()
            songChangeDirection = 1
            AppLogger.shared.log("⏭ next() → userQueue: \(song.title)")
            // Save original source before switching to queue display
            if savedPlaybackSource == nil {
                savedPlaybackSource = playbackSource
            }
            playbackSource = .queue
            currentSong = song
            startPlayback(song)
            saveLastPlayback()
            return
        }

        // Restore original source when userQueue is exhausted
        if let saved = savedPlaybackSource {
            playbackSource = saved
            savedPlaybackSource = nil
        }

        guard !queue.isEmpty else { return }

        // If we only have the current song, avoid replaying it in a loop while
        // random queue fill is still in flight.
        if queue.count == 1, let only = queue.first, only.id == currentSong?.id {
            AppLogger.shared.log("⏭ next() ignored: queue has only current song; waiting for random fill")
            Task { await fillQueueWithRandomSongs(around: only) }
            return
        }

        queueIndex = (queueIndex + 1) % queue.count
        songChangeDirection = 1

        // Detect transition into autoplay (random-fill) songs
        if let autoIdx = autoplayFromIndex, queueIndex >= autoIdx, playbackSource != .autoplay {
            playbackSource = .autoplay
        }
        leaveSourceIfForeign(queue[queueIndex])

        AppLogger.shared.log("⏭ next() → idx \(queueIndex): \(queue[queueIndex].title)")
        currentSong = queue[queueIndex]
        startPlayback(queue[queueIndex])
        saveLastPlayback()
    }

    /// Back a song — or, as the previous button does, to the start of this one once it's
    /// a few seconds in. A swipe across the cover always means the song before.
    func previous(restartsFirst: Bool = true) {
        if restartsFirst, currentTime > 3 { AppLogger.shared.log("⏮ previous() → restart"); seek(to: 0); return }
        guard !queue.isEmpty else { return }
        // Wrap to the end, mirroring next(). Forward already loops via `% queue.count`;
        // going back from the first track dead-ended on a restart instead, so an album that
        // had just wrapped from its last track to its first could not be stepped back into.
        var targetIndex = queueIndex > 0 ? queueIndex - 1 : queue.count - 1
        // Offline: walk further back past songs that can't play locally, so
        // "previous" never jumps forward via the startPlayback skip guard.
        if isEffectivelyOffline {
            while targetIndex >= 0 && !isPlayableOffline(queue[targetIndex]) {
                targetIndex -= 1
            }
            guard targetIndex >= 0 else {
                AppLogger.shared.log("⏮ previous(): no offline-playable song before current → restart")
                ToastManager.shared.show("Not available offline", icon: "wifi.slash")
                seek(to: 0)
                return
            }
        }
        queueIndex = targetIndex
        // Set only here — past every early return that restarts instead of moving,
        // so a no-op "previous" can't leave the next real change pointing backwards.
        songChangeDirection = -1
        AppLogger.shared.log("⏮ previous() → idx \(queueIndex): \(queue[queueIndex].title)")
        currentSong = queue[queueIndex]
        startPlayback(queue[queueIndex])
        saveLastPlayback()
    }

    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        // Every seek gets an id, so a completion belonging to a superseded one can be
        // recognised and ignored.
        seekGeneration &+= 1
        let generation = seekGeneration
        if reopen(at: time) { return }
        isSeeking = true
        currentTime = time
        updateNowPlayingInfo()
        let target = CMTime(seconds: time - streamOffset, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
            }
        }
    }

    /// Asks again for a stream the server converts as it sends, from `time`, when that part of
    /// it hasn't arrived yet. False when the item can seek there itself.
    ///
    /// Such a stream states no length and answers no byte range, so the player can't seek
    /// past what it has brought: it stayed where it was and the bar jumped back to it. Asked
    /// to start converting at the moment wanted, the server plays from there after a moment's
    /// loading, the bar staying on it meanwhile. A song the phone holds whole by now — the
    /// cache fills alongside — reopens from there instead, where any seek works.
    private func reopen(at time: TimeInterval) -> Bool {
        guard playsLiveConversion, !hasLoaded(time), let song = currentSong,
              let server = ServerManager.shared.currentServer else { return false }
        let bitRate = AppSettings.shared.streamingQuality.bitRate
        let offset = Int(max(0, time))
        let item: AVPlayerItem
        if let stream = AudioCacheManager.shared.streamItem(
            songId: song.id, server: server, bitRate: bitRate, songSuffix: song.suffix,
            songContentType: song.contentType, from: offset) {
            item = stream
            streamOffset = TimeInterval(offset)
            isSeeking = false
        } else {
            item = makePlayerItem(for: song, server: server, bitRate: bitRate)
            streamOffset = 0
            // Held on the moment wanted until the item is ready and seeks there.
            isSeeking = true
            pendingSeekTime = time
        }
        AppLogger.shared.log("⏩ Reopening \(song.title) at \(offset)s: not loaded yet")
        currentTime = time
        updateNowPlayingInfo()
        observePlayerItem(item, song: song)
        observeBuffer(item, songId: song.id)
        EqualizerManager.shared.attachToPlayerItem(item)
        watchEnd(of: item)
        player?.replaceCurrentItem(with: item)
        applyPitch()
        if isPlaying { player?.play() }
        return true
    }

    /// Whether the item plays a stream the server converts as it sends. Downloads play from
    /// files and the cache through its own scheme, and a stream of the file itself ("raw",
    /// or no format for a lossy file) answers byte ranges: all of those seek anywhere.
    private var playsLiveConversion: Bool {
        guard let url = (player?.currentItem?.asset as? AVURLAsset)?.url,
              url.scheme == "http" || url.scheme == "https", url.path.hasSuffix("/rest/stream"),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        return query.contains { $0.name == "format" && $0.value != "raw" }
    }

    /// Whether the item has already brought the part of the song at `time`.
    private func hasLoaded(_ time: TimeInterval) -> Bool {
        guard let item = player?.currentItem else { return false }
        let local = time - streamOffset
        guard local >= 0 else { return false }
        return item.loadedTimeRanges.contains { value in
            let range = value.timeRangeValue
            return local >= range.start.seconds && local <= range.end.seconds
        }
    }

    /// Follows `item`'s end and failures, and no earlier item's.
    private func watchEnd(of item: AVPlayerItem) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        center.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        center.removeObserver(self, name: .AVPlayerItemNewErrorLogEntry, object: nil)
        center.addObserver(self, selector: #selector(playerDidFinish),
                           name: .AVPlayerItemDidPlayToEndTime, object: item)
        center.addObserver(self, selector: #selector(playerItemFailedToPlayToEnd(_:)),
                           name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        center.addObserver(self, selector: #selector(playerItemNewErrorLogEntry(_:)),
                           name: .AVPlayerItemNewErrorLogEntry, object: item)
    }

    func toggleShuffle() {
        isShuffled.toggle()
        syncRemoteModes()
        AppLogger.shared.log("🔀 shuffle: \(isShuffled)")
        if isShuffled {
            shuffleQueue()
        } else {
            // Restore natural order. If the current song exists in the saved
            // original order, resume from its position; otherwise (e.g. a
            // radio-evolved queue whose current track isn't in originalQueue)
            // keep it playing at the front so unshuffled "next" stays deterministic.
            guard let current = currentSong, !originalQueue.isEmpty else { return }
            if let idx = originalQueue.firstIndex(where: { $0.id == current.id }) {
                queue = originalQueue
                queueIndex = idx
            } else {
                queue = [current] + originalQueue.filter { $0.id != current.id }
                queueIndex = 0
            }
        }
    }

    private func shuffleQueue() {
        guard let current = currentSong else { return }
        var shuffled = queue.filter { $0.id != current.id }
        shuffled.shuffle()
        shuffled.insert(current, at: 0)
        queue = shuffled
        queueIndex = 0
        // Also shuffle the user queue (songs added via "Add to Queue")
        if !userQueue.isEmpty {
            userQueue.shuffle()
        }
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
        syncRemoteModes()
        AppLogger.shared.log("🔁 repeat: \(repeatMode)")
        saveLastPlayback()
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var hasQueue: Bool { !queue.isEmpty && currentSong != nil }

    var upNextSongs: [Song] {
        var result = userQueue
        if !queue.isEmpty, queueIndex + 1 < queue.count {
            result += Array(queue.suffix(from: queueIndex + 1))
        }
        return Array(result.prefix(10))
    }

    // MARK: - Queue Management

    func playNext(_ song: Song) {
        AppLogger.shared.log("➕ playNext: \(song.title)")
        userQueue.insert(song, at: 0)
        ToastManager.shared.show("Playing next: \(song.title)", icon: "text.insert")
    }

    func addToQueue(_ song: Song) {
        AppLogger.shared.log("➕ addToQueue: \(song.title)")
        userQueue.append(song)
        ToastManager.shared.show("Added to queue: \(song.title)", icon: "text.append")
    }

    func addToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        AppLogger.shared.log("➕ addToQueue: \(songs.count) songs")
        userQueue.append(contentsOf: songs)
        ToastManager.shared.show("Added \(songs.count) songs to queue", icon: "text.append")
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < queue.count else { return }
        AppLogger.shared.log("➖ removeFromQueue idx \(index): \(queue[index].title)")
        if index < queueIndex {
            queueIndex -= 1
        } else if index == queueIndex {
            // removing current song, skip to next
            queue.remove(at: index)
            if !queue.isEmpty {
                queueIndex = min(queueIndex, queue.count - 1)
                currentSong = queue[queueIndex]
                startPlayback(queue[queueIndex])
            } else {
                currentSong = nil
                isPlaying = false
            }
            saveLastPlayback()
            return
        }
        queue.remove(at: index)
        saveLastPlayback()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        // Update queueIndex to track current song
        if let current = currentSong,
           let newIdx = queue.firstIndex(where: { $0.id == current.id }) {
            queueIndex = newIdx
        }
        saveLastPlayback()
    }

    func clearUpNext() {
        guard queueIndex < queue.count else { return }
        AppLogger.shared.log("🗑 clearUpNext: removing \(userQueue.count) user-queued + \(queue.count - queueIndex - 1) auto songs")
        userQueue = []
        queue = Array(queue.prefix(queueIndex + 1))
        saveLastPlayback()
    }

    /// Shuffle the upcoming songs in the queue, returning the old queue for undo
    func shuffleUpNext() -> [Song]? {
        guard queueIndex + 1 < queue.count else { return nil }
        let oldQueue = queue
        var upcoming = Array(queue[(queueIndex + 1)...])
        upcoming.shuffle()
        queue = Array(queue.prefix(queueIndex + 1)) + upcoming
        AppLogger.shared.log("🔀 shuffleUpNext: reshuffled \(upcoming.count) upcoming songs")
        return oldQueue
    }

    /// Restore queue from a previous snapshot (for undo)
    func restoreQueue(_ savedQueue: [Song]) {
        queue = savedQueue
        if let current = currentSong,
           let idx = queue.firstIndex(where: { $0.id == current.id }) {
            queueIndex = idx
        }
    }

    // MARK: - Favorite Toggle

    func toggleFavorite() {
        guard var song = currentSong, !song.isPreview,
              let server = ServerManager.shared.currentServer else { return }
        guard !isTogglingFavorite else { return }
        isTogglingFavorite = true
        let wasStarred = song.isStarred
        Task {
            defer { Task { @MainActor in self.isTogglingFavorite = false } }
            do {
                if song.isStarred {
                    try await SubsonicClient.shared.unstar(server: server, id: song.id)
                    song.starred = nil
                } else {
                    try await SubsonicClient.shared.star(server: server, id: song.id)
                    song.starred = ISO8601DateFormatter().string(from: Date())
                }
                await MainActor.run {
                    self.currentSong = song
                    // Only celebrate the off → on direction.
                    if !wasStarred { self.favoriteCelebration += 1 }
                    if let idx = self.queue.firstIndex(where: { $0.id == song.id }) {
                        self.queue[idx] = song
                    }
                    if let idx = self.originalQueue.firstIndex(where: { $0.id == song.id }) {
                        self.originalQueue[idx] = song
                    }
                }
            } catch { AppLogger.shared.log("❌ Toggle favorite failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Radio Mode

    /// Toggle radio mode on/off. Does NOT auto-play — opens RadioPlaylistView for user to browse.
    func startRadioMode() {
        AppLogger.shared.log("📻 startRadioMode called")
        if let song = currentSong {
            beginNewRadio()
            radioPlaylistName = "Radio: \(song.title)"
            radioPlaylistSongs = [song]
            radioPlaylistCoverArt = song.coverArt
            radioPlayedIds = [song.id]
            // Don't touch queue — user must explicitly play from RadioPlaylistView
            pendingRadioOpen = true
            startSmartRadioFetch(seed: song)
        }
    }

    /// Start radio from a specific song (e.g. from context menu)
    func startRadioFromSong(_ song: Song) {
        // If we already have a radio for this song and it's less than 5 min old, reuse it
        let expectedName = "Radio: \(song.title)"
        if radioPlaylistName == expectedName,
           !radioPlaylistSongs.isEmpty,
           let ts = radioFetchTimestamp,
           Date().timeIntervalSince(ts) < 300 {
            AppLogger.shared.log("📻 Reusing cached radio for \(song.title) (\(radioPlaylistSongs.count) songs)")
            pendingRadioOpen = true
            return
        }

        beginNewRadio()
        radioPlaylistName = expectedName
        radioPlaylistSongs = [song]
        radioPlaylistCoverArt = song.coverArt
        radioPlayedIds = [song.id]
        // Don't touch queue — user must explicitly play from RadioPlaylistView
        pendingRadioOpen = true
        startSmartRadioFetch(seed: song)
    }

    /// Start an artist-based Instant Mix: blends artist's top songs with similar artists' top songs
    func startArtistInstantMix(artistId: String, artistName: String, topSongs: [Song]) {
        guard !topSongs.isEmpty else { return }
        let seed = topSongs.randomElement() ?? topSongs[0]

        // Build initial playlist with artist's own top songs
        var initialPlaylist = [seed]
        let otherTopSongs = topSongs.filter { $0.id != seed.id }.shuffled()
        initialPlaylist.append(contentsOf: otherTopSongs)

        beginNewRadio()
        radioPlaylistName = "Mix: \(artistName)"
        radioPlaylistSongs = initialPlaylist
        radioPlaylistCoverArt = seed.coverArt
        radioPlayedIds = Set(initialPlaylist.map { $0.id })
        isFetchingRadioSongs = true
        let generation = radioGeneration
        // Don't touch queue — user must explicitly play from RadioPlaylistView
        pendingRadioOpen = true

        Task {
            defer { Task { @MainActor in self.endRadioFetch(generation) } }
            guard let server = ServerManager.shared.currentServer else { return }
            var pool: [Song] = []

            // 1. Get similar artists and their top songs
            do {
                let artistInfo = try await SubsonicClient.shared.getArtistInfo2(server: server, id: artistId, count: 10)
                if let similarArtists = artistInfo.similarArtist, !similarArtists.isEmpty {
                    AppLogger.shared.log("📻 Instant Mix: found \(similarArtists.count) similar artists")
                    let artistsToFetch = Array(similarArtists.prefix(5))
                    for simArtist in artistsToFetch {
                        do {
                            let simTopSongs = try await SubsonicClient.shared.getTopSongs(server: server, artistName: simArtist.name, count: 10)
                            pool.append(contentsOf: simTopSongs)
                            AppLogger.shared.log("📻 Instant Mix: \(simArtist.name) → \(simTopSongs.count) songs")
                        } catch { continue }
                    }
                }
            } catch {
                AppLogger.shared.log("📻 ArtistInfo2 failed for instant mix: \(error.localizedDescription)")
            }

            // 2. Also try getSimilarSongs2 from the seed
            do {
                let similar = try await SubsonicClient.shared.getSimilarSongs2(server: server, id: seed.id, count: 20)
                pool.append(contentsOf: similar)
                AppLogger.shared.log("📻 Instant Mix: getSimilarSongs2 → \(similar.count) songs")
            } catch {
                AppLogger.shared.log("📻 Instant Mix: getSimilarSongs2 failed: \(error.localizedDescription)")
            }

            // Deduplicate
            let existing = await MainActor.run { Set(self.radioPlayedIds) }
            var seen = existing
            let unique = pool.filter { seen.insert($0.id).inserted }
            var shuffled = Array(unique)
            shuffled.shuffle()
            let toAdd = Array(shuffled.prefix(35))

            AppLogger.shared.log("📻 Instant Mix: adding \(toAdd.count) songs (pool had \(pool.count), \(unique.count) unique)")

            await MainActor.run {
                guard radioGeneration == generation else { return }
                radioPlaylistSongs.append(contentsOf: toAdd)
                radioPlayedIds.formUnion(toAdd.map { $0.id })
            }
        }
    }

    /// Start radio from an album: seeds from multiple album songs for variety
    func startAlbumRadio(songs: [Song]) {
        guard !songs.isEmpty else { return }
        let seed = songs.randomElement()!
        let otherAlbumSongs = songs.filter { $0.id != seed.id }

        // Start with just the seed song; album songs will be mixed in with similar songs
        beginNewRadio()
        radioPlaylistName = "Radio: \(seed.album ?? "Album")"
        radioPlaylistSongs = [seed]
        radioPlaylistCoverArt = seed.coverArt
        radioPlayedIds = Set(songs.map { $0.id })
        isFetchingRadioSongs = true
        let generation = radioGeneration
        // Don't touch queue — user must explicitly play from RadioPlaylistView
        pendingRadioOpen = true

        Task {
            defer { Task { @MainActor in self.endRadioFetch(generation) } }
            guard let server = ServerManager.shared.currentServer else { return }
            var pool: [Song] = []

            // Use up to 3 album songs as seeds for getSimilarSongs2
            let seeds = Array(songs.shuffled().prefix(3))
            for s in seeds {
                do {
                    let similar = try await SubsonicClient.shared.getSimilarSongs2(server: server, id: s.id, count: 20)
                    pool.append(contentsOf: similar)
                } catch { continue }
            }

            // Also get similar artists from the album's artist
            if let artistId = seed.artistId {
                do {
                    let artistInfo = try await SubsonicClient.shared.getArtistInfo2(server: server, id: artistId, count: 5)
                    if let similarArtists = artistInfo.similarArtist {
                        for simArtist in similarArtists.prefix(3) {
                            do {
                                let topSongs = try await SubsonicClient.shared.getTopSongs(server: server, artistName: simArtist.name, count: 8)
                                pool.append(contentsOf: topSongs)
                            } catch { continue }
                        }
                    }
                } catch { }
            }

            // Fallback: genre songs if pool is thin
            if pool.count < 10, let genre = seed.genre {
                do {
                    let genreSongs = try await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre, count: 20)
                    pool.append(contentsOf: genreSongs)
                } catch { }
            }

            // Deduplicate against already-tracked IDs (includes all album songs)
            let existing = await MainActor.run { Set(self.radioPlayedIds) }
            var seen = existing
            let unique = pool.filter { seen.insert($0.id).inserted }
            var similarSongs = Array(unique.prefix(35))

            // Mix the remaining album songs in with the similar songs, then shuffle
            var mixed = otherAlbumSongs + similarSongs
            mixed.shuffle()

            await MainActor.run {
                guard radioGeneration == generation else { return }
                radioPlaylistSongs.append(contentsOf: mixed)
                radioPlayedIds.formUnion(mixed.map { $0.id })
            }
        }
    }

    /// Saves the radio as a playlist — the one of the same name, if there is one. The id of
    /// the playlist saved, nil when it couldn't be.
    func saveRadioPlaylist() async -> String? {
        guard !radioPlaylistSongs.isEmpty,
              let server = ServerManager.shared.currentServer else { return nil }
        do {
            let songIds = radioPlaylistSongs.map { $0.id }
            // Check if a playlist with the same name already exists to avoid duplicates
            let playlists = try await SubsonicClient.shared.getPlaylists(server: server)
            let existingId = playlists.first(where: { $0.name == radioPlaylistName })?.id
            let saved = try await SubsonicClient.shared.createPlaylist(server: server, name: radioPlaylistName,
                                                                       songIds: songIds, playlistId: existingId)
            return existingId ?? saved.id
        } catch {
            AppLogger.shared.log("❌ Failed to save radio playlist: \(error.localizedDescription)")
            return nil
        }
    }

    /// Refresh radio queue with a new rolling seed (called from QueueView refresh)
    func refreshRadioQueue() {
        AppLogger.shared.log("📻 refreshRadioQueue called | radioMode=\(isRadioMode) | fetching=\(isFetchingRadioSongs)")
        guard isRadioMode else { return }
        // Use the last song in the radio playlist as the new seed (evolving taste)
        let seed = radioPlaylistSongs.last ?? currentSong
        guard let seed else {
            AppLogger.shared.log("📻 refreshRadioQueue: no seed found")
            return
        }
        AppLogger.shared.log("📻 refreshRadioQueue: seeding from \(seed.title)")
        startSmartRadioFetch(seed: seed)
    }

    /// Play from the radio temp playlist at a specific index
    func playRadioPlaylistFromIndex(_ index: Int) {
        guard index < radioPlaylistSongs.count else { return }
        let song = radioPlaylistSongs[index]
        isRadioMode = true
        playbackSource = .radio(name: radioPlaylistName)
        playSong(song, fromQueue: radioPlaylistSongs, startIndex: index, source: .radio(name: radioPlaylistName))
    }

    /// Starts a smart-radio fetch unless one is already running — only one at a time.
    ///
    /// The slot is claimed right here, before the task starts, not from inside it. A radio
    /// that has just been opened has to read as loading from its very first frame: claimed
    /// from the task, there was a gap in which the radio page showed the seed song on its
    /// own, as if that were the whole radio, before the loader turned up.
    private func startSmartRadioFetch(seed: Song) {
        guard !isFetchingRadioSongs else {
            AppLogger.shared.log("📻 Skipping fetch — already in progress")
            return
        }
        isFetchingRadioSongs = true
        let generation = radioGeneration
        Task { await fetchSmartRadioSongs(seed: seed, generation: generation) }
    }

    /// Makes way for a new radio: whatever the previous one is still fetching goes stale,
    /// and the fetch slot is free for the new one.
    private func beginNewRadio() {
        radioGeneration += 1
        isFetchingRadioSongs = false
    }

    /// Releases the fetch slot — unless a newer radio has claimed it since.
    private func endRadioFetch(_ generation: Int) {
        guard radioGeneration == generation else { return }
        isFetchingRadioSongs = false
    }

    /// Smart radio: multi-strategy song fetching with evolving seeds.
    /// The caller claims `isFetchingRadioSongs` first; this releases it when done. Songs
    /// fetched for a radio that has since been replaced are dropped.
    private func fetchSmartRadioSongs(seed: Song, generation: Int) async {
        guard let server = ServerManager.shared.currentServer else {
            await MainActor.run { endRadioFetch(generation) }
            return
        }
        AppLogger.shared.log("📻 fetchSmartRadioSongs for: \(seed.title) by \(seed.artist ?? "?")")

        let minSongs = 30
        var pool: [Song] = []

        // Strategy 1: getSimilarSongs2 from current seed (evolving)
        do {
            let similar = try await SubsonicClient.shared.getSimilarSongs2(server: server, id: seed.id, count: 50)
            AppLogger.shared.log("📻 getSimilarSongs2 → \(similar.count) songs")
            pool.append(contentsOf: similar)
        } catch {
            AppLogger.shared.log("📻 getSimilarSongs2 failed: \(error.localizedDescription)")
        }

        // Strategy 2: Similar artists via getArtistInfo2 → their top songs
        if let artistId = seed.artistId {
            do {
                let artistInfo = try await SubsonicClient.shared.getArtistInfo2(server: server, id: artistId, count: 12)
                if let similarArtists = artistInfo.similarArtist, !similarArtists.isEmpty {
                    AppLogger.shared.log("📻 getArtistInfo2 → \(similarArtists.count) similar artists")
                    // Fetch top songs from up to 5 similar artists
                    for simArtist in similarArtists.prefix(5) {
                        do {
                            let topSongs = try await SubsonicClient.shared.getTopSongs(server: server, artistName: simArtist.name, count: 10)
                            pool.append(contentsOf: topSongs)
                        } catch { continue }
                    }
                }
            } catch {
                AppLogger.shared.log("📻 getArtistInfo2 failed: \(error.localizedDescription)")
            }
        }

        // Strategy 3: Genre + era matching
        if let genre = seed.genre {
            do {
                let genreSongs = try await SubsonicClient.shared.getSongsByGenre(server: server, genre: genre, count: 50)
                // Prefer songs from similar era if seed has a year
                if let seedYear = seed.year, seedYear > 0 {
                    let eraMatched = genreSongs.filter { song in
                        guard let y = song.year, y > 0 else { return false }
                        return abs(y - seedYear) <= 8
                    }
                    pool.append(contentsOf: eraMatched)
                    let rest = genreSongs.filter { song in
                        guard let y = song.year, y > 0 else { return true }
                        return abs(y - seedYear) > 8
                    }
                    pool.append(contentsOf: rest)
                } else {
                    pool.append(contentsOf: genreSongs)
                }
            } catch {
                AppLogger.shared.log("📻 getSongsByGenre failed: \(error.localizedDescription)")
            }
        }

        // Strategy 4: Starred songs in same genre (user taste signal)
        if let genre = seed.genre {
            do {
                let starred = try await SubsonicClient.shared.getStarred2(server: server)
                let starredInGenre = (starred.song ?? []).filter { $0.genre?.lowercased() == genre.lowercased() }
                pool.append(contentsOf: starredInGenre)
            } catch { }
        }

        // Strategy 5: Random songs as last resort to reach minimum
        if pool.count < minSongs {
            do {
                let random = try await SubsonicClient.shared.getRandomSongs(server: server, size: 50)
                pool.append(contentsOf: random)
            } catch { }
        }

        // Deduplicate against already-played radio songs
        let existingIds = await MainActor.run { radioPlayedIds }
        var seen = existingIds
        let unique = pool.filter { seen.insert($0.id).inserted }
        var shuffled = Array(unique)
        shuffled.shuffle()
        let toAdd = Array(shuffled.prefix(max(minSongs, 30)))

        AppLogger.shared.log("📻 Smart radio: adding \(toAdd.count) new songs (pool had \(pool.count), \(unique.count) unique)")

        await MainActor.run {
            guard radioGeneration == generation else {
                AppLogger.shared.log("📻 Dropping \(toAdd.count) songs fetched for a radio that was replaced")
                return
            }
            radioPlaylistSongs.append(contentsOf: toAdd)
            radioPlayedIds.formUnion(toAdd.map { $0.id })
            radioFetchTimestamp = Date()  // Cache timestamp for 5-min reuse
            // If currently playing from this radio, also update the live queue
            if isRadioMode {
                queue.append(contentsOf: toAdd)
                originalQueue.append(contentsOf: toAdd)
            }
            isFetchingRadioSongs = false
        }
    }

    // MARK: - Previews becoming songs

    /// How far ahead of the preview the song is readied, and how long the two overlap.
    private static let handOverLead: TimeInterval = 1.5
    private static let crossover: TimeInterval = 0.25

    /// Songs a fetch just brought into the library take their previews' places, in the queue
    /// and in the player. A preview playing hands over to its song without a seam — see
    /// `handOver(from:to:)`; one paused gives way quietly, at the same point in the song.
    @MainActor
    func adoptLibrarySongs(_ replacement: @escaping (Song) -> Song?) async {
        let swap = { (song: Song) -> Song in song.isPreview ? replacement(song) ?? song : song }
        queue = queue.map(swap)
        originalQueue = originalQueue.map(swap)
        userQueue = userQueue.map(swap)
        guard let preview = currentSong, preview.isPreview, let full = replacement(preview) else {
            saveLastPlayback()
            return
        }
        #if os(iOS)
        if isPlaying, await handOver(from: preview, to: full) { return }
        #endif
        // It moved on while the song was being lined up: the queue is all that changes.
        guard currentSong?.id == preview.id else {
            saveLastPlayback()
            return
        }
        if isPlaying {
            // No seamless way in: the preview plays out, and its song follows from the top.
            if queue.indices.contains(queueIndex), queue[queueIndex].id == full.id {
                queue[queueIndex] = preview
                queue.insert(full, at: queueIndex + 1)
            }
            saveLastPlayback()
            return
        }
        let resume = await pausedPosition(in: full, from: preview)
        guard currentSong?.id == preview.id, !isPlaying else { return }
        songChangeDirection = 0
        currentSong = full
        currentTime = resume
        pendingSeekTime = resume > 1 ? resume : nil
        preparePlayback(full)
        loadLyrics(for: full)
        saveLastPlayback()
    }

    /// Where the song stands at the point a paused preview was left: its start when the
    /// preview had played out, or when the two can't be lined up.
    @MainActor
    private func pausedPosition(in full: Song, from preview: Song) async -> TimeInterval {
        #if os(iOS)
        let at = currentTime
        guard at > 1, let offset = await previewOffset(preview, in: full) else { return 0 }
        return offset + at
        #else
        return 0
        #endif
    }

    #if os(iOS)
    /// Seconds into `full` at which `preview` begins, from the song's own copy on disk —
    /// the copy the player then plays, so the two agree to the sample.
    @MainActor
    private func previewOffset(_ preview: Song, in full: Song) async -> TimeInterval? {
        guard let server = ServerManager.shared.currentServer,
              let address = preview.preview.flatMap(URL.init(string:)),
              let copy = await AudioCacheManager.shared.localCopy(
                  of: full, server: server, bitRate: AppSettings.shared.streamingQuality.bitRate)
        else { return nil }
        defer { if copy.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: copy) } }
        return await PreviewAligner.offset(ofPreviewAt: address, inSongAt: copy)
    }

    /// A playing preview becomes its song mid-note.
    ///
    /// The song, lined up against the preview, is readied on a second player at the point
    /// the preview will reach a moment later, and started at exactly that moment by the host
    /// clock. The two then cross over in a quarter of a second — the same recording twice,
    /// in step, so nothing is heard change — and the song is simply what's playing: its
    /// clock, its length, its lyrics in time.
    @MainActor
    private func handOver(from preview: Song, to full: Song) async -> Bool {
        guard let offset = await previewOffset(preview, in: full),
              let server = ServerManager.shared.currentServer,
              currentSong?.id == preview.id, isPlaying,
              let outgoing = player, let timebase = outgoing.currentItem?.timebase
        else { return false }

        let item = makePlayerItem(for: full, server: server, bitRate: AppSettings.shared.streamingQuality.bitRate)
        await EqualizerManager.shared.attach(to: item)
        let incoming = AVPlayer(playerItem: item)
        // Required for a start set by the host clock.
        incoming.automaticallyWaitsToMinimizeStalling = false
        incoming.volume = 0
        guard await Self.becomesReady(item) else { return false }

        let previewNow = CMSyncGetTime(timebase).seconds
        let previewLength = outgoing.currentItem?.duration.seconds ?? .nan
        let meet = previewNow + Self.handOverLead
        // Past the preview's closing fade, there's nothing left to cross over from.
        guard previewLength.isFinite, meet < previewLength - Self.previewFade - Self.crossover,
              meet + offset < Double(full.duration ?? .max) - 5
        else { return false }
        let songPoint = CMTime(seconds: meet + offset, preferredTimescale: 44_100)
        guard await incoming.seek(to: songPoint, toleranceBefore: .zero, toleranceAfter: .zero),
              await incoming.preroll(atRate: 1),
              currentSong?.id == preview.id, isPlaying, player === outgoing
        else { return false }

        let clock = CMClockGetHostTimeClock()
        let meetHost = CMSyncConvertTime(CMTime(seconds: meet, preferredTimescale: 44_100), from: timebase, to: clock)
        let wait = (meetHost - CMClockGetTime(clock)).seconds
        guard wait > 0.02 else { return false }
        incoming.setRate(1, time: .invalid, atHostTime: meetHost)
        try? await Task.sleep(for: .seconds(wait))

        let from = outgoing.volume
        let to = Float(volume * replayGainFactor(for: full))
        let steps = 12
        for step in 1...steps {
            let share = Float(step) / Float(steps)
            outgoing.volume = from * (1 - share)
            incoming.volume = to * share
            try? await Task.sleep(for: .seconds(Self.crossover / Double(steps)))
        }
        adopt(incoming, playing: item, as: full, replacing: outgoing)
        AppLogger.shared.log("🔀 Preview handed over to \(full.title) at \(meet + offset)s")
        return true
    }

    /// Whether the item can play, within a few seconds.
    @MainActor
    private static func becomesReady(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<80 {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return false
    }

    /// The second player becomes the player: the preview's is let go, and the song is
    /// watched, announced and saved like any song begun the usual way.
    @MainActor
    private func adopt(_ incoming: AVPlayer, playing item: AVPlayerItem, as full: Song, replacing outgoing: AVPlayer) {
        if let observer = timeObserver {
            outgoing.removeTimeObserver(observer)
            timeObserver = nil
        }
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemNewErrorLogEntry, object: nil)
        outgoing.pause()
        outgoing.replaceCurrentItem(with: nil)

        hasPrefetchedNext = false
        resetScrobbleProgress()
        isSeeking = false
        streamOffset = 0
        bufferProgress = 0
        incoming.automaticallyWaitsToMinimizeStalling = true
        player = incoming
        applyPitch()
        observePlayerItem(item, song: full)
        observeBuffer(item, songId: full.id)
        watchPlayback(of: item)
        if let length = full.duration, length > 0 { duration = Double(length) }
        currentTime = incoming.currentTime().seconds
        songChangeDirection = 0
        currentSong = full
        announce(full)
        saveLastPlayback()
    }
    #endif

    // MARK: - Lyrics

    func loadLyrics(for song: Song) {
        lyricsTask?.cancel()
        lyricsGeneration += 1
        let generation = lyricsGeneration
        lyrics = []
        lyricsStatus = "Loading lyrics..."
        isLoadingLyrics = true
        AppLogger.shared.log("🎤 loadLyrics: \(song.title) by \(song.artist ?? "?")")
        lyricsTask = Task {
            // A preview is thirty seconds from somewhere in the song, and nothing says where:
            // its words come from LRCLIB alone — the server doesn't hold the song — and as a
            // sheet, since timed lines would run out of step. The whole song, once it's in,
            // brings them back in time.
            let found = song.isPreview
                ? await tryLRCLIB(song: song, generation: generation, timed: false)
                : await resolveLyrics(for: song, generation: generation)
            await publishLyrics(generation) {
                if !found {
                    self.lyrics = []
                    self.lyricsStatus = "No lyrics found"
                }
                self.isLoadingLyrics = false
            }
        }
    }

    /// Applies a lyrics update on the main actor — unless another fetch has started since
    /// `generation`, in which case the update belongs to a song no longer on screen.
    private func publishLyrics(_ generation: Int, _ update: @escaping () -> Void) async {
        await MainActor.run {
            guard self.lyricsGeneration == generation else { return }
            update()
        }
    }

    /// Finds the song's lyrics, then makes sure they are this version's: a duet or a remix
    /// named as such gets its own words even when every source hands back the original's.
    /// A verdict already reached for the song applies at once, network or not.
    private func resolveLyrics(for song: Song, generation: Int) async -> Bool {
        // Timed by hand on this device: nothing found anywhere else replaces that.
        if await tryOverride(for: song, generation: generation) { return true }
        if case .replaced(let synced, let plain)? = LyricsVersion.verdict(for: song.id) {
            if await applyLRCLIBResult(["syncedLyrics": synced ?? "", "plainLyrics": plain ?? ""],
                                       generation: generation) {
                return true
            }
            // A verdict that can't be shown would otherwise stop the song from being checked again.
            LyricsVersion.forget(song.id)
        }
        guard await findLyrics(for: song, generation: generation) else { return false }
        if !isEffectivelyOffline, LyricsVersion.verdict(for: song.id) == nil,
           !LyricsVersion.markers(title: song.title, artist: song.artist).isEmpty {
            await checkVersion(of: song, generation: generation)
        }
        return true
    }

    /// Asks LRCLIB for the version's own sheets and, when most of them disagree with the
    /// lyrics on screen, shows theirs instead; then, in the sideload build, NetEase for the
    /// recording's timed sheet, shown when the lyrics found keep another recording's time.
    /// The verdict is kept, so this runs once a song — unless a source didn't answer.
    private func checkVersion(of song: Song, generation: Int) async {
        let current = await MainActor.run { () -> [LyricsLine]? in
            self.lyricsGeneration == generation ? self.lyrics : nil
        }
        guard let current, !current.isEmpty else { return }
        let candidates = await LyricsVersion.candidates(title: song.title, artist: song.artist, duration: song.duration)
        if let candidates,
           let pick = LyricsVersion.replacement(among: candidates, for: current.map(\.text), duration: song.duration) {
            AppLogger.shared.log("🎵 Lyrics version: \(song.title) — the lyrics found are another version's; "
                                 + "LRCLIB \(pick.id) (\(pick.artistName ?? "?")) replaces them")
            await replaceLyrics(of: song, synced: pick.syncedLyrics, plain: pick.plainLyrics, generation: generation)
            return
        }
        var settled = candidates != nil
        #if !APPSTORE_BUILD
        switch await LyricsVersion.recordingSheet(title: song.title, artist: song.artist, duration: song.duration) {
        case .found(let sheet) where !LyricsVersion.agrees(sheet, with: current):
            AppLogger.shared.log("🎵 Lyrics version: \(song.title) — the lyrics found keep another recording's time; "
                                 + "NetEase's replace them")
            await replaceLyrics(of: song, synced: sheet, plain: nil, generation: generation)
            return
        case .failed:
            settled = false
        default:
            break
        }
        #endif
        if settled { LyricsVersion.store(.kept, for: song.id) }
    }

    private func replaceLyrics(of song: Song, synced: String?, plain: String?, generation: Int) async {
        LyricsVersion.store(.replaced(synced: synced, plain: plain), for: song.id)
        _ = await applyLRCLIBResult(["syncedLyrics": synced ?? "", "plainLyrics": plain ?? ""], generation: generation)
    }

    /// Runs every lyrics source in order and reports whether ANY matched. Each `tryX`
    /// publishes its lyrics on success, so this only exists to let `loadLyrics` settle
    /// `isLoadingLyrics` on a single, well-defined completion point (the early `return`s
    /// used to make that impossible).
    private func findLyrics(for song: Song, generation: Int) async -> Bool {
        // 0. The copy already on this device, saved when the song was downloaded.
        //    It costs nothing, it cannot fail, and it is the only source that works with
        //    the network off — which is the whole point of having downloaded the song.
        //    Until now it was written at download time and never read again.
        if await tryLocalLyrics(for: song, generation: generation) { return true }
        // 1. Prefer the user's OWN server. This matches the privacy policy ("Aura
        //    queries LRCLIB only when your server does not provide lyrics") and avoids
        //    reaching a third-party, largely-unlicensed lyrics DB whenever the server
        //    already ships the .lrc.
        //    Gate on real reachability (network up & not offline), NOT `isConnected`:
        //    that flag only flips true after a successful ping test and is routinely
        //    still false at the instant a song starts — even though the server is plainly
        //    reachable (its audio is streaming). Gating on it skipped the server on
        //    auto-load, so lyrics only appeared after a manual "Try Again". `isEffectivelyOffline`
        //    is the honest signal, and the loading spinner covers the rare unreachable-server wait.
        if let server = ServerManager.shared.currentServer, !isEffectivelyOffline {
            if lyricsSource == .structured {
                if await tryStructuredLyrics(server: server, song: song, generation: generation) { return true }
                if await tryLegacyLyrics(server: server, song: song, generation: generation) { return true }
            } else {
                if await tryLegacyLyrics(server: server, song: song, generation: generation) { return true }
                if await tryStructuredLyrics(server: server, song: song, generation: generation) { return true }
            }
        }
        // 2. Fall back to LRCLIB community lyrics when the server has none / is offline.
        if await tryLRCLIB(song: song, generation: generation) { return true }
        return false
    }


    private func tryOverride(for song: Song, generation: Int) async -> Bool {
        guard let text = LyricsOverrides.lrc(for: song.id) else { return false }
        let parsed = LyricsOverrides.parse(text)
        guard !parsed.isEmpty else { return false }
        AppLogger.shared.log("🎵 Lyrics timed by hand: \(parsed.count) lines")
        await publishLyrics(generation) {
            self.lyrics = parsed
            self.lyricsSource = .structured
            self.lyricsStatus = ""
        }
        return true
    }

    /// Keeps lines timed by hand for the song, and shows them at once.
    func saveTimedLyrics(_ lines: [LyricsOverrides.Line], for song: Song) throws {
        try LyricsOverrides.save(lines, for: song.id)
        guard currentSong?.id == song.id else { return }
        // A fetch still under way would put back the lines just replaced.
        lyricsTask?.cancel()
        lyricsGeneration += 1
        lyrics = lines.map { LyricsLine(time: $0.time, text: $0.text, words: $0.words) }
        lyricsSource = .structured
        lyricsStatus = ""
        isLoadingLyrics = false
    }

    /// Back to the lyrics as found.
    func restoreFoundLyrics(for song: Song) {
        LyricsOverrides.remove(song.id)
        guard LyricsOnServer.isEnabled else {
            if currentSong?.id == song.id { refetchLyrics() }
            return
        }
        // The server's copy goes first, or the fetch would bring it straight back.
        Task {
            do {
                try await LyricsOnServer.remove(for: song)
            } catch {
                AppLogger.shared.log("🎵 Server lyrics timing not removed: \(error.localizedDescription)")
            }
            if currentSong?.id == song.id { refetchLyrics() }
        }
    }

    /// Reads the `.lrc` saved next to a downloaded song.
    private func tryLocalLyrics(for song: Song, generation: Int) async -> Bool {
        guard let text = await MainActor.run(body: { DownloadManager.shared.localLyrics(for: song.id) })
        else { return false }
        let parsed = parseLRC(text)
        guard !parsed.isEmpty else { return false }
        AppLogger.shared.log("🎵 Lyrics from the downloaded copy: \(parsed.count) lines")
        await publishLyrics(generation) {
            self.lyrics = parsed
            // A `.lrc` carrying timestamps follows the song; one without them is a plain
            // sheet, and `legacy` is what this app calls that.
            self.lyricsSource = parsed.contains { $0.time != nil } ? .structured : .legacy
            self.lyricsStatus = ""
        }
        return true
    }

    private func tryLRCLIB(song: Song, generation: Int, timed: Bool = true) async -> Bool {
        await publishLyrics(generation) { self.lyricsStatus = "Trying LRCLIB..." }
        guard let artist = song.artist, !artist.isEmpty else { return false }

        // 1. Try exact match first via /api/get
        if let result = await lrclibExactMatch(artist: artist, title: song.title, album: song.album ?? "", duration: song.duration ?? 0) {
            return await applyLRCLIBResult(result, generation: generation, timed: timed)
        }

        // 2. Fall back to search endpoint with original terms
        if let result = await lrclibSearch(artist: artist, title: song.title, duration: song.duration,
                                           generation: generation) {
            return await applyLRCLIBResult(result, generation: generation, timed: timed)
        }

        // 3. Try with cleaned terms (strip feat., parenthetical, brackets)
        let cleanedArtist = cleanSearchTerm(artist)
        let cleanedTitle = cleanSearchTerm(song.title)
        if cleanedArtist != artist || cleanedTitle != song.title {
            if let result = await lrclibSearch(artist: cleanedArtist, title: cleanedTitle, duration: song.duration,
                                               generation: generation) {
                return await applyLRCLIBResult(result, generation: generation, timed: timed)
            }
        }

        // 4. Free-text search as final fallback
        if let result = await lrclibFreeTextSearch(query: "\(cleanedArtist) \(cleanedTitle)", duration: song.duration,
                                                   generation: generation) {
            return await applyLRCLIBResult(result, generation: generation, timed: timed)
        }

        return false
    }

    /// Strips parenthetical content, brackets, feat./ft. suffixes, and extra whitespace.
    private func cleanSearchTerm(_ term: String) -> String {
        var cleaned = term
        // Remove content in parentheses: (feat. X), (Remix), (Deluxe), etc.
        cleaned = cleaned.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        // Remove content in brackets: [feat. X], [Remix], etc.
        cleaned = cleaned.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
        // Remove "feat." / "ft." and everything after
        cleaned = cleaned.replacingOccurrences(of: #"\s*(feat\.?|ft\.?)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        // Collapse whitespace
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return cleaned
    }

    private func lrclibExactMatch(artist: String, title: String, album: String, duration: Int) async -> [String: Any]? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(duration))
        ]
        guard let url = components?.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Aura/1.0.0 (https://github.com/adrbn)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            AppLogger.shared.log("LRCLIB exact match error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Picks the candidate that is actually the same *recording*.
    ///
    /// Both search endpoints were taking `results.first`, which is LRCLIB's own ordering and
    /// has nothing to do with which version you are playing. A title that exists as a single,
    /// a remix, a live cut and a cover returns all four, and the first one won — which is
    /// exactly how a song ends up showing somebody else's words.
    ///
    /// Duration is the one field that separates them reliably: two recordings of the same
    /// song rarely agree to within a few seconds unless they are the same recording. Where
    /// the track's length is known, anything more than 8s out is rejected outright rather
    /// than ranked, because a wrong lyric sheet is worse than none.
    private func bestLRCLIBMatch(_ results: [[String: Any]], duration: Int?) -> [String: Any]? {
        func hasLyrics(_ entry: [String: Any]) -> Bool {
            ((entry["syncedLyrics"] as? String)?.isEmpty == false)
                || ((entry["plainLyrics"] as? String)?.isEmpty == false)
        }
        func isSynced(_ entry: [String: Any]) -> Bool {
            (entry["syncedLyrics"] as? String)?.isEmpty == false
        }

        var candidates = results.filter(hasLyrics)
        guard !candidates.isEmpty else { return nil }

        if let duration, duration > 0 {
            let target = Double(duration)
            candidates = candidates.filter { entry in
                guard let length = entry["duration"] as? Double else { return false }
                return abs(length - target) <= 8
            }
            guard !candidates.isEmpty else {
                AppLogger.shared.log("🎵 LRCLIB: \(results.count) results, none within 8s of \(duration)s — rejected")
                return nil
            }
            // Closest length first, and among equally close ones prefer the synced sheet.
            candidates.sort { a, b in
                let da = abs((a["duration"] as? Double ?? .infinity) - target)
                let db = abs((b["duration"] as? Double ?? .infinity) - target)
                if abs(da - db) > 0.5 { return da < db }
                return isSynced(a) && !isSynced(b)
            }
            return candidates.first
        }

        return candidates.first(where: isSynced) ?? candidates.first
    }

    private func lrclibSearch(artist: String, title: String, duration: Int?, generation: Int) async -> [String: Any]? {
        await publishLyrics(generation) { self.lyricsStatus = "Searching LRCLIB..." }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = components?.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Aura/1.0.0 (https://github.com/adrbn)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            if let best = bestLRCLIBMatch(results, duration: duration) {
                AppLogger.shared.log("🎵 LRCLIB search: matched 1 of \(results.count) results")
                return best
            }
        } catch {
            AppLogger.shared.log("LRCLIB search error: \(error.localizedDescription)")
        }
        return nil
    }

    private func lrclibFreeTextSearch(query: String, duration: Int?, generation: Int) async -> [String: Any]? {
        await publishLyrics(generation) { self.lyricsStatus = "Searching LRCLIB (broad)..." }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components?.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("Aura/1.0.0 (https://github.com/adrbn)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            if let best = bestLRCLIBMatch(results, duration: duration) {
                AppLogger.shared.log("🎵 LRCLIB free-text: matched 1 of \(results.count) results")
                return best
            }
        } catch {
            AppLogger.shared.log("LRCLIB free-text search error: \(error.localizedDescription)")
        }
        return nil
    }

    /// `timed: false` shows the words as a sheet even when they come timed — for a preview.
    private func applyLRCLIBResult(_ json: [String: Any], generation: Int, timed: Bool = true) async -> Bool {
        let plain = json["plainLyrics"] as? String ?? ""
        // Prefer synced lyrics
        if let syncedLyrics = json["syncedLyrics"] as? String, !syncedLyrics.isEmpty {
            let parsed = parseLRC(syncedLyrics)
            if !timed, plain.isEmpty {
                let lines = parsed.filter { !$0.text.isEmpty }.map { LyricsLine(time: nil, text: $0.text) }
                guard !lines.isEmpty else { return false }
                await publishLyrics(generation) {
                    self.lyrics = lines
                    self.lyricsSource = .legacy
                    self.lyricsStatus = ""
                }
                return true
            }
            if !parsed.isEmpty, timed {
                AppLogger.shared.log("🎵 LRCLIB: Got \(parsed.count) synced lyrics lines")
                await publishLyrics(generation) {
                    self.lyrics = parsed
                    self.lyricsSource = .structured
                    self.lyricsStatus = ""
                }
                return true
            }
        }
        // Fall back to plain lyrics
        if !plain.isEmpty {
            let lines = plain.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { LyricsLine(time: nil, text: $0) }
            if !lines.isEmpty {
                await publishLyrics(generation) {
                    self.lyrics = lines
                    self.lyricsSource = .legacy
                    self.lyricsStatus = ""
                }
                return true
            }
        }
        return false
    }

    private func tryStructuredLyrics(server: ServerConfig, song: Song, generation: Int) async -> Bool {
        do {
            await publishLyrics(generation) { self.lyricsStatus = "Trying synced lyrics..." }
            let structured = try await SubsonicClient.shared.getLyricsBySongId(server: server, id: song.id)
            let synced = structured.first(where: { $0.synced == true }) ?? structured.first
            if let synced = synced, let lines = synced.line, !lines.isEmpty {
                // v2 gives real word cues keyed by line index; v1 servers send none and
                // this map is simply empty, leaving `words` nil and the karaoke display to
                // interpolate as before.
                let cuesByIndex = Dictionary(
                    (synced.cueLine ?? []).compactMap { cueLine -> (Int, [LyricWord])? in
                        guard let index = cueLine.index, let cues = cueLine.cue else { return nil }
                        let cueOffset = Double(synced.offset ?? 0) / 1000.0
                        let words = cues.compactMap { cue -> LyricWord? in
                            guard let value = cue.value, let start = cue.start else { return nil }
                            return LyricWord(id: start, text: value, start: Double(start) / 1000.0 + cueOffset)
                        }
                        return words.isEmpty ? nil : (index, words)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                // `offset` is the correction the source itself declares, in milliseconds.
                // It was decoded and then ignored; a set of lyrics shipped with a non-zero
                // offset played early or late by exactly that amount.
                let offset = Double(synced.offset ?? 0) / 1000.0
                let parsed = lines.enumerated().compactMap { index, line -> LyricsLine? in
                    guard let value = line.value, !value.isEmpty else { return nil }
                    let time: TimeInterval? = line.start.map { Double($0) / 1000.0 + offset }
                    return LyricsLine(time: time, text: value, words: cuesByIndex[index])
                }
                if !cuesByIndex.isEmpty {
                    AppLogger.shared.log("🎤 Lyrics: server supplied word-level timing for \(cuesByIndex.count) line(s)")
                }
                if !parsed.isEmpty {
                    await publishLyrics(generation) {
                        self.lyrics = parsed
                        self.lyricsStatus = ""
                    }
                    return true
                }
            }
            await publishLyrics(generation) { self.lyricsStatus = "Synced lyrics empty" }
        } catch {
            await publishLyrics(generation) { self.lyricsStatus = "Synced: \(error.localizedDescription)" }
        }
        return false
    }

    private func tryLegacyLyrics(server: ServerConfig, song: Song, generation: Int) async -> Bool {
        do {
            await publishLyrics(generation) { self.lyricsStatus = "Trying legacy lyrics..." }
            let lrcText = try await SubsonicClient.shared.getLyrics(
                server: server, artist: song.artist ?? "", title: song.title
            )
            if !lrcText.isEmpty {
                let parsed = parseLRC(lrcText)
                if parsed.isEmpty {
                    let plainLines = lrcText.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .map { LyricsLine(time: nil, text: $0) }
                    await publishLyrics(generation) {
                        self.lyrics = plainLines
                        self.lyricsStatus = ""
                    }
                } else {
                    await publishLyrics(generation) {
                        self.lyrics = parsed
                        self.lyricsStatus = ""
                    }
                }
                return true
            }
            await publishLyrics(generation) { self.lyricsStatus = "Legacy lyrics empty" }
        } catch {
            await publishLyrics(generation) { self.lyricsStatus = "Legacy: \(error.localizedDescription)" }
        }
        return false
    }

    func refetchLyrics() {
        guard let song = currentSong else { return }
        // A refetch asked for by hand checks the version afresh too.
        LyricsVersion.forget(song.id)
        loadLyrics(for: song)
    }

    func switchLyricsSource() {
        lyricsSource = lyricsSource == .structured ? .legacy : .structured
        refetchLyrics()
    }

    private func parseLRC(_ text: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let match = trimmed.range(of: #"\[(\d+):(\d+[\.\d]*)\]"#, options: .regularExpression) {
                let tag = String(trimmed[match])
                let content = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if content.isEmpty { continue }
                let nums = tag.dropFirst().dropLast()
                let parts = nums.split(separator: ":")
                if parts.count == 2 {
                    let time = (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
                    lines.append(LyricsLine(time: time, text: content))
                }
            } else if !trimmed.hasPrefix("[") {
                lines.append(LyricsLine(time: nil, text: trimmed))
            }
        }
        return lines.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    // MARK: - Sleep Timer

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerEndOfSong = false
        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimerActive = true
        AppLogger.shared.log("😴 Sleep timer: \(minutes) min")
        sleepTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.sleepTimerRemaining -= 1
                if self.sleepTimerRemaining <= 0 {
                    self.pause()
                    self.cancelSleepTimer()
                    AppLogger.shared.log("😴 Sleep timer fired — paused")
                    return
                }
            }
        }
    }

    func startSleepTimerEndOfSong() {
        cancelSleepTimer()
        sleepTimerEndOfSong = true
        sleepTimerActive = true
        AppLogger.shared.log("😴 Sleep timer: end of current song")
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerActive = false
        sleepTimerRemaining = 0
        sleepTimerEndOfSong = false
    }

    var sleepTimerFormatted: String {
        let m = Int(sleepTimerRemaining) / 60
        let s = Int(sleepTimerRemaining) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        guard let song = currentSong else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "Unknown",
            MPMediaItemPropertyAlbumTitle: song.album ?? "Unknown",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            // What the rate returns to after a pause, so a car's progress bar keeps moving
            // on its own between updates instead of waiting for the next one.
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            // Without a media type the system does not reliably classify this as music,
            // which is what decides whether it appears where music is expected. The content
            // identifier gives the item a stable name across processes, so anything that
            // wants to resume or re-target this exact song has something to hold on to.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: song.id
        ]

        // "4 of 20", where the screen has room for it.
        if !queue.isEmpty, queue.indices.contains(queueIndex) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }

        // Use cached artwork immediately if available for this song
        if let artwork = cachedArtwork, cachedArtworkSongId == song.id {
            let mpArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            info[MPMediaItemPropertyArtwork] = mpArtwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            updateLiveActivity()
            return
        }

        // No cached artwork yet — set info without artwork once, then fetch
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateLiveActivity()

        if let coverArt = song.coverArt {
            // Same bucket as the Now Playing hero, so the lock screen usually costs the
            // server nothing — the image is already cached by the time it's needed.
            let artSize = ArtworkCache.fullSize
            let cacheKey = "\(coverArt)_\(artSize)"
            // Check ArtworkCache first (memory + disk)
            if let cached = ArtworkCache.shared.image(for: cacheKey) {
                cachedArtwork = cached
                cachedArtworkSongId = song.id
                let mpArtwork = MPMediaItemArtwork(boundsSize: cached.size) { _ in cached }
                info[MPMediaItemPropertyArtwork] = mpArtwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                return
            }
            // Fetch through ArtworkCache, NOT URLSession.shared: this fires on every song
            // change and used to bypass the artwork throttle entirely, adding an ungated
            // request to an endpoint that was already being saturated.
            if ServerManager.shared.currentServer != nil {
                let songId = song.id
                Task {
                    if let image = await ArtworkCache.shared.fetchImage(
                        coverArt: coverArt, requestSize: artSize, key: cacheKey) {
                        await MainActor.run {
                            guard self.currentSong?.id == songId else { return }
                            self.cachedArtwork = image
                            self.cachedArtworkSongId = songId
                            // Rebuild info with current time, not stale captured values
                            self.updateNowPlayingInfo()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Live Activity

    /// Aura uses the SYSTEM Now Playing presentation (Dynamic Island, Lock Screen,
    /// Control Center) driven by `MPNowPlayingInfoCenter` — the standard media UI
    /// that Apple Music/Spotify get automatically — rather than a custom ActivityKit
    /// Live Activity. This is intentionally a no-op; it also ends any lingering
    /// custom activity so the system UI takes over. (The `MusicLiveActivity` widget
    /// stays in the target, unused, so re-enabling is a one-line change.)
    private func startLiveActivity(for song: Song) {
        #if os(iOS)
        Task {
            for activity in Activity<MusicPlaybackAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    private func updateLiveActivity() {
        #if os(iOS)
        guard let song = currentSong, let activity = currentActivity else { return }

        let now = Date()
        if lastActivityWasPlaying == isPlaying, now.timeIntervalSince(lastActivityUpdateTime) < 1.0 { return }
        lastActivityUpdateTime = now
        lastActivityWasPlaying = isPlaying

        let coverURLString = stableCoverArtURL

        let state = MusicPlaybackAttributes.ContentState(
            isPlaying: isPlaying,
            songTitle: song.title,
            artist: song.artist ?? "Unknown",
            album: song.album ?? "Unknown",
            elapsed: currentTime,
            duration: duration,
            coverArtURL: coverURLString
        )

        Task {
            let content = ActivityContent(state: state, staleDate: nil)
            await activity.update(content)
        }
        #endif
    }

    private func endLiveActivity() {
        #if os(iOS)
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            await MainActor.run { self.currentActivity = nil }
        }
        #endif
    }
}
