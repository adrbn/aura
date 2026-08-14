import Foundation
import AVFoundation
import MediaPlayer
import SwiftUI
import ActivityKit

@Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    var currentSong: Song?
    var queue: [Song] = []
    var userQueue: [Song] = []
    var queueIndex: Int = 0
    /// True while a favourite toggle is waiting on the server. The heart shows a pulse
    /// and stops accepting taps, so a slow round-trip can't be fired twenty times.
    var isTogglingFavorite = false
    /// Bumped each time a song becomes a favourite — drives the one-shot sparkle burst.
    var favoriteCelebration = 0

    /// Which way the last song change went: +1 forward, -1 backward. Drives the Now
    /// Playing slide transition.
    ///
    /// It lives here, not in the view, because the view only ever sees *some* of the
    /// song changes. Autoplay, the lock screen, CarPlay and Siri all move the queue
    /// without any on-screen gesture, and a view-owned flag would keep serving the
    /// stale direction from the last thing the user touched. Worse, `previous()`
    /// restarts the track instead of moving when past 3 s, so a view that set "-1"
    /// on the gesture left it wrong even though nothing had changed.
    var songChangeDirection: Int = 1
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
    var playbackSource: PlaybackSource = .unknown
    var pendingPlaylistId: String?
    var lyrics: [LyricsLine] = []
    var lyricsSource: LyricsSource = .structured
    var lyricsStatus: String = ""
    /// True while lyrics are being fetched. The empty-state ("No lyrics available") must
    /// wait on this being false — otherwise it flashes before any source has been tried.
    var isLoadingLyrics = false
    var isShowingQueue = false
    var radioPlaylistSongs: [Song] = []
    var radioPlaylistName: String = ""
    var radioPlaylistCoverArt: String?
    private var radioPlayedIds: Set<String> = []  // All song IDs played/queued in this radio session
    private(set) var isFetchingRadioSongs = false  // Guard against concurrent fetches
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
    private var timeObserver: Any?
    private var originalQueue: [Song] = []
    private var currentActivity: Activity<MusicPlaybackAttributes>?
    private var backgroundImage: UIImage?
    /// Per-server key so each server profile keeps (and resumes) its own queue/track.
    /// A track from server A can't stream once you've switched to server B, so we never
    /// share one playback session across servers.
    private var lastPlaybackKey: String {
        "musika_last_playback_\(ServerManager.shared.currentServer?.id.uuidString ?? "none")"
    }
    private var sleepTimerTask: Task<Void, Never>?
    private var scrobbleTask: Task<Void, Never>?
    private var lastActivityUpdateTime = Date.distantPast
    private var lastActivityWasPlaying: Bool?
    private var cachedArtwork: UIImage?
    private var cachedArtworkSongId: String?
    private var stableCoverArtURL: String?
    private var savedPlaybackSource: PlaybackSource?
    private var autoplayFromIndex: Int?  // Index where autoplay/random-fill songs begin
    private var isSeeking = false
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
    private var offlineErrorHandled = false
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?

    init() {
        setupAudioSession()
        setupRemoteCommands()
        restoreLastPlayback()
    }

    private func setupAudioSession() {
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
    }

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
            if options.contains(.shouldResume) {
                AppLogger.shared.log("🔊 Interruption ended — resuming")
                DispatchQueue.main.async { self.play() }
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

        enum CodingKeys: String, CodingKey {
            case currentSong, queue, queueIndex, userQueue, playbackSource, repeatMode, position
        }

        init(currentSong: Song, queue: [Song], queueIndex: Int, userQueue: [Song] = [], playbackSource: PlaybackSource = .unknown, repeatMode: RepeatMode = .off, position: TimeInterval = 0) {
            self.currentSong = currentSong
            self.queue = queue
            self.queueIndex = queueIndex
            self.userQueue = userQueue
            self.playbackSource = playbackSource
            self.repeatMode = repeatMode
            self.position = position
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
        }
    }

    private func saveLastPlayback() {
        guard let song = currentSong else { return }
        let state = LastPlayback(currentSong: song, queue: queue, queueIndex: queueIndex, userQueue: userQueue, playbackSource: playbackSource, repeatMode: repeatMode, position: currentTime)
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
        scrobbleTask?.cancel()
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

    /// Load the stream URL and set up AVPlayer without starting playback
    private func preparePlayback(_ song: Song) {
        AudioCacheManager.shared.saveMetadata(song)
        // Restored session (launch / server switch): warm its art too, so opening Now
        // Playing straight after launch is instant.
        ArtworkCache.shared.prefetchNowPlayingCover(coverArt: song.coverArt ?? song.albumId)
        guard let server = ServerManager.shared.currentServer else { return }
        let bitRate = AppSettings.shared.streamingQuality.bitRate

        player?.pause()
        player?.replaceCurrentItem(with: nil)

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemNewErrorLogEntry, object: nil)

        let playerItem = AudioCacheManager.shared.playerItem(songId: song.id, server: server, bitRate: bitRate, songSuffix: song.suffix, songContentType: song.contentType)
        observePlayerItem(playerItem, song: song)
        observeBuffer(playerItem, songId: song.id)
        EqualizerManager.shared.attachToPlayerItem(playerItem)
        player = AVPlayer(playerItem: playerItem)
        player?.pause()

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            self.currentTime = time.seconds
            if let d = self.player?.currentItem?.duration.seconds, !d.isNaN {
                self.duration = d
            }
            self.updateNowPlayingInfo()
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
            // Single song or no queue — fill with random songs for autoplay
            Task { await fillQueueWithRandomSongs(around: song) }
        }
        if isShuffled { shuffleQueue() }
        currentSong = song
        startPlayback(song)
        saveLastPlayback()
    }

    func fillQueueWithRandomSongs(around song: Song) async {
        guard !AppSettings.shared.offlineMode else { return }
        guard let server = ServerManager.shared.currentServer else { return }
        await MainActor.run { isBuildingQueue = true }
        defer { Task { @MainActor in isBuildingQueue = false } }
        do {
            // Try similar songs first for a better autoplay experience
            var autoplaySongs: [Song] = []
            do {
                let similar = try await SubsonicClient.shared.getSimilarSongs2(server: server, id: song.id, count: 50)
                // De-duplicate by id. getSimilarSongs2 (Last.fm-backed) can repeat the
                // same track — and sometimes the seed itself — inside one response. A queue
                // holding duplicate ids breaks everything keyed on id: SwiftUI's queue list
                // (a tap lands on the FIRST row sharing that id) and every firstIndex(where:id)
                // that positions queueIndex. That's what made the queue appear to "loop back
                // to the first song". Keep only the first occurrence of each id.
                var seen: Set<String> = [song.id]
                autoplaySongs = similar.filter { seen.insert($0.id).inserted }
                let removed = similar.count - autoplaySongs.count
                if removed > 0 {
                    AppLogger.shared.log("🎵 Autoplay: dropped \(removed) duplicate similar song(s)", level: .warning)
                }
                AppLogger.shared.log("🎵 Autoplay: found \(autoplaySongs.count) similar songs")
            } catch {
                AppLogger.shared.log("🎵 Autoplay: getSimilarSongs2 failed, falling back to random")
            }

            // If similar songs are too few, pad with random songs
            if autoplaySongs.count < 20 {
                let existingIds = Set(autoplaySongs.map { $0.id } + [song.id])
                var random = try await SubsonicClient.shared.getRandomSongs(server: server, size: 50)
                random.removeAll { existingIds.contains($0.id) }
                autoplaySongs.append(contentsOf: random.prefix(50 - autoplaySongs.count))
                AppLogger.shared.log("🎵 Autoplay: padded with \(random.prefix(50 - autoplaySongs.count).count) random songs (total: \(autoplaySongs.count))")
            }

            await MainActor.run {
                // Do not overwrite a queue that has already moved to another context.
                if !(self.queue.count <= 1 && self.queue.first?.id == song.id) {
                    AppLogger.shared.log("🎵 Autoplay fill ignored (queue changed while fetching)")
                    return
                }

                let activeSongId = self.currentSong?.id ?? song.id
                self.queue = [song] + autoplaySongs
                self.originalQueue = self.queue
                self.queueIndex = self.queue.firstIndex(where: { $0.id == activeSongId }) ?? 0
                self.autoplayFromIndex = 1  // Songs after index 0 are autoplay
                // If playback already advanced past autoplay boundary, update source now
                if self.queueIndex >= 1 && self.playbackSource != .autoplay {
                    self.playbackSource = .autoplay
                }
                if isShuffled { shuffleQueue() }
                saveLastPlayback()
            }
            AppLogger.shared.log("🎵 Autoplay queue filled with \(autoplaySongs.count) songs | queueIdx: \(queueIndex)")
        } catch {
            AppLogger.shared.log("Failed to fill autoplay queue: \(error.localizedDescription)")
        }
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
                    AppLogger.shared.log("⏭ Offline skip → idx \(idx): \(queue[idx].title)")
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
        var neighbours: [Song] = []
        if let upNext = userQueue.first { neighbours.append(upNext) }
        if !queue.isEmpty {
            let forward = (queueIndex + 1) % queue.count
            if forward != queueIndex { neighbours.append(queue[forward]) }
            if queueIndex > 0 { neighbours.append(queue[queueIndex - 1]) }
        }
        for song in neighbours {
            ArtworkCache.shared.prefetchNowPlayingCover(coverArt: song.coverArt ?? song.albumId)
        }
    }

    private func startPlayback(_ song: Song) {
        AudioCacheManager.shared.saveMetadata(song)
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
        offlineErrorHandled = false
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
        isSeeking = false
        bufferProgress = 0
        let playerItem = AudioCacheManager.shared.playerItem(songId: song.id, server: server, bitRate: bitRate, songSuffix: song.suffix, songContentType: song.contentType)
        observePlayerItem(playerItem, song: song)
        observeBuffer(playerItem, songId: song.id)
        EqualizerManager.shared.attachToPlayerItem(playerItem)
        player = AVPlayer(playerItem: playerItem)

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, !self.isSeeking else { return }
            self.currentTime = time.seconds
            if let d = self.player?.currentItem?.duration.seconds, !d.isNaN {
                self.duration = d
            }
            self.updateNowPlayingInfo()

            // Prefetch next track at ~80% progress
            if !self.hasPrefetchedNext, self.duration > 0, self.currentTime / self.duration >= 0.8 {
                self.hasPrefetchedNext = true
                self.prefetchNextTrack()
            }
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

        // Initialize duration from song metadata so Now Playing info shows it immediately
        if let songDuration = song.duration, songDuration > 0 {
            duration = Double(songDuration)
        }

        player?.play()
        isPlaying = true
        currentSong = song

        scrobbleTask?.cancel()
        scrobbleTask = Task {
            let songDuration = Double(song.duration ?? 0)
            let delay = songDuration > 0 ? min(30.0, songDuration / 2) : 30.0
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            PlayHistory.shared.record(song: song)
            if AppSettings.shared.scrobbleEnabled {
                do {
                    try await SubsonicClient.shared.scrobble(server: server, id: song.id)
                } catch {
                    // Offline or failed — queue for later
                    ScrobbleQueue.shared.enqueue(songId: song.id)
                }
            }
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
            Task { await fetchSmartRadioSongs(seed: song) }
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
            } else {
                // Auto-start radio when single song ends with nothing next.
                // Radio needs the server — never kick it off while offline.
                if let song = currentSong, !isEffectivelyOffline {
                    isRadioMode = true
                    isFetchingRadioSongs = false  // Reset for fresh start
                    radioPlaylistName = "Radio: \(song.title)"
                    radioPlaylistSongs = [song]
                    radioPlayedIds = Set(queue.map { $0.id })
                    radioPlayedIds.insert(song.id)
                    playbackSource = .radio(name: radioPlaylistName)
                    Task {
                        await fetchSmartRadioSongs(seed: song)
                        await MainActor.run {
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
            let progress = dur > 0 ? min(buffered / dur, 1.0) : 0
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentSong?.id == songId else { return }
                self.bufferProgress = progress
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
                    if let resume = self.pendingSeekTime {
                        self.pendingSeekTime = nil
                        self.player?.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                        self.currentTime = resume
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
            self?.handleOfflinePlaybackError()
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
        guard isEffectivelyOffline, !offlineErrorHandled else { return }
        offlineErrorHandled = true
        AppLogger.shared.log("📴 Playback error while offline — advancing to next playable song")
        ToastManager.shared.show("Not available offline", icon: "wifi.slash")
        skipToNextPlayableOffline()
    }

    func play() { AppLogger.shared.log("▶️ play()"); player?.play(); isPlaying = true; updateLiveActivity() }
    func pause() { AppLogger.shared.log("⏸ pause()"); player?.pause(); isPlaying = false; updateLiveActivity() }
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

        guard let song = nextSong else { return }
        AudioCacheManager.shared.prefetch(songId: song.id, server: server, bitRate: bitRate, songSuffix: song.suffix, songContentType: song.contentType)
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

        AppLogger.shared.log("⏭ next() → idx \(queueIndex): \(queue[queueIndex].title)")
        currentSong = queue[queueIndex]
        startPlayback(queue[queueIndex])
        saveLastPlayback()
    }

    func previous() {
        if currentTime > 3 { AppLogger.shared.log("⏮ previous() → restart"); seek(to: 0); return }
        guard !queue.isEmpty else { return }
        guard queueIndex > 0 else {
            AppLogger.shared.log("⏮ previous() at first track → restart")
            seek(to: 0)
            return
        }
        var targetIndex = queueIndex - 1
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
        isSeeking = true
        currentTime = time
        updateNowPlayingInfo()
        let target = CMTime(seconds: time, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
            }
        }
    }

    func toggleShuffle() {
        isShuffled.toggle()
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

    func cycleRepeat() { repeatMode = repeatMode.next; AppLogger.shared.log("🔁 repeat: \(repeatMode)"); saveLastPlayback() }

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
        guard var song = currentSong,
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
            radioPlaylistName = "Radio: \(song.title)"
            radioPlaylistSongs = [song]
            radioPlaylistCoverArt = song.coverArt
            radioPlayedIds = [song.id]
            // Don't touch queue — user must explicitly play from RadioPlaylistView
            pendingRadioOpen = true
            Task { await fetchSmartRadioSongs(seed: song) }
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

        radioPlaylistName = expectedName
        radioPlaylistSongs = [song]
        radioPlaylistCoverArt = song.coverArt
        radioPlayedIds = [song.id]
        // Don't touch queue — user must explicitly play from RadioPlaylistView
        pendingRadioOpen = true
        Task { await fetchSmartRadioSongs(seed: song) }
    }

    /// Start an artist-based Instant Mix: blends artist's top songs with similar artists' top songs
    func startArtistInstantMix(artistId: String, artistName: String, topSongs: [Song]) {
        guard !topSongs.isEmpty else { return }
        let seed = topSongs.randomElement() ?? topSongs[0]

        // Build initial playlist with artist's own top songs
        var initialPlaylist = [seed]
        let otherTopSongs = topSongs.filter { $0.id != seed.id }.shuffled()
        initialPlaylist.append(contentsOf: otherTopSongs)

        radioPlaylistName = "Mix: \(artistName)"
        radioPlaylistSongs = initialPlaylist
        radioPlaylistCoverArt = seed.coverArt
        radioPlayedIds = Set(initialPlaylist.map { $0.id })
        isFetchingRadioSongs = true
        // Don't touch queue — user must explicitly play from RadioPlaylistView
        pendingRadioOpen = true

        Task {
            defer { Task { @MainActor in self.isFetchingRadioSongs = false } }
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
        radioPlaylistName = "Radio: \(seed.album ?? "Album")"
        radioPlaylistSongs = [seed]
        radioPlaylistCoverArt = seed.coverArt
        radioPlayedIds = Set(songs.map { $0.id })
        isFetchingRadioSongs = true
        // Don't touch queue — user must explicitly play from RadioPlaylistView
        pendingRadioOpen = true

        Task {
            defer { Task { @MainActor in self.isFetchingRadioSongs = false } }
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
                radioPlaylistSongs.append(contentsOf: mixed)
                radioPlayedIds.formUnion(mixed.map { $0.id })
            }
        }
    }

    func saveRadioPlaylist() async {
        guard !radioPlaylistSongs.isEmpty,
              let server = ServerManager.shared.currentServer else { return }
        do {
            let songIds = radioPlaylistSongs.map { $0.id }
            // Check if a playlist with the same name already exists to avoid duplicates
            let playlists = try await SubsonicClient.shared.getPlaylists(server: server)
            let existingId = playlists.first(where: { $0.name == radioPlaylistName })?.id
            try await SubsonicClient.shared.createPlaylist(server: server, name: radioPlaylistName, songIds: songIds, playlistId: existingId)
        } catch {
            AppLogger.shared.log("❌ Failed to save radio playlist: \(error.localizedDescription)")
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
        Task { await fetchSmartRadioSongs(seed: seed) }
    }

    /// Play from the radio temp playlist at a specific index
    func playRadioPlaylistFromIndex(_ index: Int) {
        guard index < radioPlaylistSongs.count else { return }
        let song = radioPlaylistSongs[index]
        isRadioMode = true
        playbackSource = .radio(name: radioPlaylistName)
        playSong(song, fromQueue: radioPlaylistSongs, startIndex: index, source: .radio(name: radioPlaylistName))
    }

    /// Smart radio: multi-strategy song fetching with evolving seeds
    private func fetchSmartRadioSongs(seed: Song) async {
        // Prevent concurrent fetches — only one at a time
        let alreadyFetching = await MainActor.run {
            if isFetchingRadioSongs { return true }
            isFetchingRadioSongs = true
            return false
        }
        if alreadyFetching {
            AppLogger.shared.log("📻 Skipping fetch — already in progress")
            return
        }
        guard let server = ServerManager.shared.currentServer else {
            await MainActor.run { isFetchingRadioSongs = false }
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

    // MARK: - Lyrics

    func loadLyrics(for song: Song) {
        lyrics = []
        lyricsStatus = "Loading lyrics..."
        isLoadingLyrics = true
        AppLogger.shared.log("🎤 loadLyrics: \(song.title) by \(song.artist ?? "?")")
        Task {
            let found = await resolveLyrics(for: song)
            await MainActor.run {
                if !found {
                    self.lyrics = []
                    self.lyricsStatus = "No lyrics found"
                }
                self.isLoadingLyrics = false
            }
        }
    }

    /// Runs every lyrics source in order and reports whether ANY matched. Each `tryX`
    /// publishes its lyrics on success, so this only exists to let `loadLyrics` settle
    /// `isLoadingLyrics` on a single, well-defined completion point (the early `return`s
    /// used to make that impossible).
    private func resolveLyrics(for song: Song) async -> Bool {
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
                if await tryStructuredLyrics(server: server, song: song) { return true }
                if await tryLegacyLyrics(server: server, song: song) { return true }
            } else {
                if await tryLegacyLyrics(server: server, song: song) { return true }
                if await tryStructuredLyrics(server: server, song: song) { return true }
            }
        }
        // 2. Fall back to LRCLIB community lyrics when the server has none / is offline.
        if await tryLRCLIB(song: song) { return true }
        return false
    }

    private func tryLRCLIB(song: Song) async -> Bool {
        await MainActor.run { self.lyricsStatus = "Trying LRCLIB..." }
        guard let artist = song.artist, !artist.isEmpty else { return false }

        // 1. Try exact match first via /api/get
        if let result = await lrclibExactMatch(artist: artist, title: song.title, album: song.album ?? "", duration: song.duration ?? 0) {
            return await applyLRCLIBResult(result)
        }

        // 2. Fall back to search endpoint with original terms
        if let result = await lrclibSearch(artist: artist, title: song.title) {
            return await applyLRCLIBResult(result)
        }

        // 3. Try with cleaned terms (strip feat., parenthetical, brackets)
        let cleanedArtist = cleanSearchTerm(artist)
        let cleanedTitle = cleanSearchTerm(song.title)
        if cleanedArtist != artist || cleanedTitle != song.title {
            if let result = await lrclibSearch(artist: cleanedArtist, title: cleanedTitle) {
                return await applyLRCLIBResult(result)
            }
        }

        // 4. Free-text search as final fallback
        if let result = await lrclibFreeTextSearch(query: "\(cleanedArtist) \(cleanedTitle)") {
            return await applyLRCLIBResult(result)
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

    private func lrclibSearch(artist: String, title: String) async -> [String: Any]? {
        await MainActor.run { self.lyricsStatus = "Searching LRCLIB..." }
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
            // Prefer result with synced lyrics
            let withSynced = results.first { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            let withPlain = results.first { ($0["plainLyrics"] as? String)?.isEmpty == false }
            if let best = withSynced ?? withPlain {
                AppLogger.shared.log("🎵 LRCLIB search: found match from \(results.count) results")
                return best
            }
        } catch {
            AppLogger.shared.log("LRCLIB search error: \(error.localizedDescription)")
        }
        return nil
    }

    private func lrclibFreeTextSearch(query: String) async -> [String: Any]? {
        await MainActor.run { self.lyricsStatus = "Searching LRCLIB (broad)..." }
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
            let withSynced = results.first { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            let withPlain = results.first { ($0["plainLyrics"] as? String)?.isEmpty == false }
            if let best = withSynced ?? withPlain {
                AppLogger.shared.log("🎵 LRCLIB free-text: found match from \(results.count) results")
                return best
            }
        } catch {
            AppLogger.shared.log("LRCLIB free-text search error: \(error.localizedDescription)")
        }
        return nil
    }

    private func applyLRCLIBResult(_ json: [String: Any]) async -> Bool {
        // Prefer synced lyrics
        if let syncedLyrics = json["syncedLyrics"] as? String, !syncedLyrics.isEmpty {
            let parsed = parseLRC(syncedLyrics)
            if !parsed.isEmpty {
                AppLogger.shared.log("🎵 LRCLIB: Got \(parsed.count) synced lyrics lines")
                await MainActor.run {
                    self.lyrics = parsed
                    self.lyricsSource = .structured
                    self.lyricsStatus = ""
                }
                return true
            }
        }
        // Fall back to plain lyrics
        if let plainLyrics = json["plainLyrics"] as? String, !plainLyrics.isEmpty {
            let lines = plainLyrics.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { LyricsLine(time: nil, text: $0) }
            if !lines.isEmpty {
                await MainActor.run {
                    self.lyrics = lines
                    self.lyricsSource = .legacy
                    self.lyricsStatus = ""
                }
                return true
            }
        }
        return false
    }

    private func tryStructuredLyrics(server: ServerConfig, song: Song) async -> Bool {
        do {
            await MainActor.run { self.lyricsStatus = "Trying synced lyrics..." }
            let structured = try await SubsonicClient.shared.getLyricsBySongId(server: server, id: song.id)
            let synced = structured.first(where: { $0.synced == true }) ?? structured.first
            if let synced = synced, let lines = synced.line, !lines.isEmpty {
                // v2 gives real word cues keyed by line index; v1 servers send none and
                // this map is simply empty, leaving `words` nil and the karaoke display to
                // interpolate as before.
                let cuesByIndex = Dictionary(
                    (synced.cueLine ?? []).compactMap { cueLine -> (Int, [LyricWord])? in
                        guard let index = cueLine.index, let cues = cueLine.cue else { return nil }
                        let words = cues.compactMap { cue -> LyricWord? in
                            guard let value = cue.value, let start = cue.start else { return nil }
                            return LyricWord(id: start, text: value, start: Double(start) / 1000.0)
                        }
                        return words.isEmpty ? nil : (index, words)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                let parsed = lines.enumerated().compactMap { index, line -> LyricsLine? in
                    guard let value = line.value, !value.isEmpty else { return nil }
                    let time: TimeInterval? = line.start.map { Double($0) / 1000.0 }
                    return LyricsLine(time: time, text: value, words: cuesByIndex[index])
                }
                if !cuesByIndex.isEmpty {
                    AppLogger.shared.log("🎤 Lyrics: server supplied word-level timing for \(cuesByIndex.count) line(s)")
                }
                if !parsed.isEmpty {
                    await MainActor.run {
                        self.lyrics = parsed
                        self.lyricsStatus = ""
                    }
                    return true
                }
            }
            await MainActor.run { self.lyricsStatus = "Synced lyrics empty" }
        } catch {
            await MainActor.run { self.lyricsStatus = "Synced: \(error.localizedDescription)" }
        }
        return false
    }

    private func tryLegacyLyrics(server: ServerConfig, song: Song) async -> Bool {
        do {
            await MainActor.run { self.lyricsStatus = "Trying legacy lyrics..." }
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
                    await MainActor.run {
                        self.lyrics = plainLines
                        self.lyricsStatus = ""
                    }
                } else {
                    await MainActor.run {
                        self.lyrics = parsed
                        self.lyricsStatus = ""
                    }
                }
                return true
            }
            await MainActor.run { self.lyricsStatus = "Legacy lyrics empty" }
        } catch {
            await MainActor.run { self.lyricsStatus = "Legacy: \(error.localizedDescription)" }
        }
        return false
    }

    func refetchLyrics() {
        guard let song = currentSong else { return }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

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
        Task {
            for activity in Activity<MusicPlaybackAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func updateLiveActivity() {
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
    }

    private func endLiveActivity() {
        guard let activity = currentActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            await MainActor.run { self.currentActivity = nil }
        }
    }
}
