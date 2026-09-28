#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import WatchConnectivity

/// Keeps the watch app in step with the player, and carries out what it asks.
///
/// Nothing runs unless a paired watch has Aura on it: the player isn't watched and nothing
/// is sent. When one does, a snapshot goes out whenever the song, the play state, the
/// favourite, the lyrics or the queue change — the position only when it drifts from what
/// the watch is counting, so a playing song isn't a message a second.
@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// How far the watch's count may stray from the player before it's corrected.
    private static let drift: TimeInterval = 1.5
    private static let upNextCount = 20
    /// Pixels a side: the cover fills the watch's display, and a message must stay well under
    /// WatchConnectivity's 64 KB with the lyrics and the queue beside it.
    private static let artworkSize: CGFloat = 360

    private let player = AudioPlayer.shared
    private var isObserving = false
    private var isScheduled = false
    private var lastSent: WatchNowPlaying?
    private var artworkId: String?
    private var artwork: Data?
    private var tone: Data?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private var hasWatchApp: Bool {
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    private func beginObservingIfNeeded() {
        guard hasWatchApp, !isObserving else { return }
        isObserving = true
        observe()
        schedulePublish()
    }

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = (player.currentSong, player.isPlaying, player.currentTime, player.duration,
                 player.isTogglingFavorite, player.lyrics.count, player.queue.count,
                 player.queueIndex, player.userQueue.count)
        } onChange: { [weak self] in
            // Called before the change lands: read it on the next turn of the main loop.
            Task { @MainActor in
                self?.observe()
                self?.schedulePublish()
            }
        }
    }

    private func schedulePublish() {
        guard !isScheduled else { return }
        isScheduled = true
        Task { @MainActor in
            isScheduled = false
            publishIfChanged()
        }
    }

    private func publishIfChanged() {
        guard hasWatchApp else { return }
        let state = snapshot()
        if let lastSent, lastSent.matches(state),
           abs(lastSent.elapsed(at: Date()) - state.position) < Self.drift { return }
        lastSent = state
        if state.artworkId != artworkId {
            artworkId = state.artworkId
            artwork = nil
            tone = nil
            loadArtwork(for: state.artworkId)
        }
        send(state)
    }

    private func snapshot() -> WatchNowPlaying {
        guard let song = player.currentSong else { return WatchNowPlaying(accent: accent) }
        let offset = AppSettings.shared.lyricsOffset
        let queued = player.userQueue.enumerated().map { slot, song in
            upcoming(song, slot: slot, isQueued: true)
        }
        let rest = player.queue.indices.dropFirst(player.queueIndex + 1).map { slot in
            upcoming(player.queue[slot], slot: slot, isQueued: false)
        }
        return WatchNowPlaying(
            songId: song.id,
            title: song.title,
            artist: song.artist ?? "Unknown Artist",
            artworkId: song.coverArt,
            isPlaying: player.isPlaying,
            position: player.currentTime,
            positionDate: Date(),
            duration: player.duration,
            isFavorite: song.isStarred,
            isSavingFavorite: player.isTogglingFavorite,
            canFavorite: !song.isPreview,
            lyrics: player.lyrics.map { .init(time: $0.time.map { $0 - offset }, text: $0.text) },
            upNext: Array((queued + rest).prefix(Self.upNextCount)),
            accent: accent,
            karaoke: AppSettings.shared.betaKaraokeLyrics)
    }

    private func upcoming(_ song: Song, slot: Int, isQueued: Bool) -> WatchNowPlaying.Upcoming {
        .init(songId: song.id, title: song.title, artist: song.artist ?? "Unknown Artist",
              slot: slot, isQueued: isQueued)
    }

    private var accent: [Double] {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        UIColor(AppSettings.shared.activeTheme.accentColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map(Double.init)
    }

    private func payload(_ state: WatchNowPlaying) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(state) else { return [:] }
        var message: [String: Any] = [WatchLinkKey.state: data]
        if let artwork { message[WatchLinkKey.artwork] = artwork }
        if let tone { message[WatchLinkKey.tone] = tone }
        return message
    }

    private func send(_ state: WatchNowPlaying) {
        let message = payload(state)
        guard !message.isEmpty else { return }
        let session = WCSession.default
        // The context waits for the watch app to open; a message reaches it at once if it's up.
        do { try session.updateApplicationContext(message) } catch {
            AppLogger.shared.log("⌚️ Watch context not sent: \(error.localizedDescription)")
        }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                AppLogger.shared.log("⌚️ Watch message not sent: \(error.localizedDescription)")
            }
        }
    }

    /// A small copy of the cover, fetched once per cover and sent with every snapshot after.
    private func loadArtwork(for coverArt: String?) {
        guard let coverArt, let server = ServerManager.shared.currentServer,
              let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: Int(Self.artworkSize))
        else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let side = Self.artworkSize
            // At one pixel a point: the renderer would otherwise draw at the phone's scale, three
            // times the pixels the watch is sent for.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            guard artworkId == coverArt, let lastSent else { return }
            artwork = small.jpegData(compressionQuality: 0.6)
            tone = try? JSONEncoder().encode(Self.tone(of: small))
            send(lastSent)
        }
    }

    private nonisolated static func tone(of image: UIImage) -> WatchTone {
        let measured = NowPlayingView.analyseBackdrop(image)
        var tone = WatchTone(veil: measured.veil)
        if let vibrant = measured.vibrant {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(vibrant).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            tone.vibrant = [red, green, blue].map(Double.init)
        }
        return tone
    }

    private func perform(_ command: WatchCommand) {
        switch command {
        case .playPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .favorite: player.toggleFavorite()
        case .seek(let time): player.seek(to: time)
        case .playSomething: Task { await player.playSomething() }
        case .play(let upcoming): play(upcoming)
        }
    }

    /// The same as tapping the row in the phone's queue — once it's sure the row is still
    /// the song the watch showed.
    private func play(_ upcoming: WatchNowPlaying.Upcoming) {
        if upcoming.isQueued {
            guard player.userQueue.indices.contains(upcoming.slot),
                  player.userQueue[upcoming.slot].id == upcoming.songId else { return }
            let song = player.userQueue.remove(at: upcoming.slot)
            player.playSong(song, fromQueue: player.queue, startIndex: player.queueIndex, source: .queue)
        } else {
            guard player.queue.indices.contains(upcoming.slot),
                  player.queue[upcoming.slot].id == upcoming.songId else { return }
            player.playSong(player.queue[upcoming.slot], fromQueue: player.queue,
                            startIndex: upcoming.slot, source: .autoplay)
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        if let error { AppLogger.shared.log("⌚️ Watch session: \(error.localizedDescription)") }
        Task { @MainActor in beginObservingIfNeeded() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in beginObservingIfNeeded() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Another watch was switched to: the session has to be started again for it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchLinkKey.command] as? Data,
              let command = try? JSONDecoder().decode(WatchCommand.self, from: data) else { return }
        Task { @MainActor in perform(command) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = UncheckedReply(send: replyHandler)
        Task { @MainActor in
            beginObservingIfNeeded()
            let state = snapshot()
            lastSent = state
            if state.artworkId != artworkId {
                artworkId = state.artworkId
                artwork = nil
                tone = nil
                loadArtwork(for: state.artworkId)
            }
            reply.send(payload(state))
        }
    }
}

/// WatchConnectivity's reply block, carried to the main actor where the answer is built.
private struct UncheckedReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}
#endif
