import AVFoundation
import MediaPlayer
import OSLog
import SwiftUI
import UIKit
import WatchConnectivity

private let log = Logger(subsystem: "com.adrbn.aura.watchkitapp", category: "offline")

/// Songs kept on the watch, and the watch's own player for them: what plays when the phone is
/// left behind, to Bluetooth headphones.
///
/// The phone sends the files; the watch keeps the collections they came with — their songs and
/// covers as listed when they were kept — in an index beside them.
extension WatchModel {
    private struct Index: Codable {
        var collections: [WatchOffline.Collection] = []
        /// File names by song id.
        var files: [String: String] = [:]
    }

    nonisolated static let offlineFolder = URL.documentsDirectory.appendingPathComponent("Offline", isDirectory: true)
    private static var indexURL: URL { offlineFolder.appendingPathComponent("index.json") }
    private static var coversFolder: URL { offlineFolder.appendingPathComponent("Covers", isDirectory: true) }

    // MARK: - Keeping

    func loadOffline() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        offline = index.collections
        offlineFiles = index.files
        for id in offlineCovers where covers[id] == nil {
            let url = Self.coversFolder.appendingPathComponent("\(id).jpg")
            if let image = UIImage(contentsOfFile: url.path) { covers[id] = image }
        }
    }

    private func saveOffline() {
        do {
            try FileManager.default.createDirectory(at: Self.offlineFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(Index(collections: offline, files: offlineFiles)).write(to: Self.indexURL)
        } catch {
            log.error("Index not saved: \(error.localizedDescription)")
        }
    }

    private var offlineCovers: Set<String> {
        Set(offline.flatMap { [$0.item.coverArt] + $0.songs.map(\.coverArt) }.compactMap { $0 })
    }

    func collection(_ item: WatchItem) -> WatchOffline.Collection? {
        offline.first { $0.item == item }
    }

    /// How many of a kept collection's songs have arrived.
    func arrived(_ collection: WatchOffline.Collection) -> Int {
        collection.songs.filter { offlineFiles[$0.id] != nil }.count
    }

    func isOnWatch(_ song: WatchItem) -> Bool { offlineFiles[song.id] != nil }

    /// Keeps a collection as listed, and asks the phone for its songs.
    func keep(_ item: WatchItem, songs: [WatchItem]) {
        let songs = Array(songs.prefix(WatchOffline.songLimit))
        offline.removeAll { $0.item == item }
        offline.insert(WatchOffline.Collection(item: item, songs: songs), at: 0)
        saveCovers(for: [item] + songs)
        saveOffline()
        sendToPhone(.sendToWatch(item))
    }

    /// Forgets a collection, and deletes the songs no other kept collection holds.
    func remove(_ item: WatchItem) {
        offline.removeAll { $0.item == item }
        let kept = Set(offline.flatMap { $0.songs.map(\.id) })
        for (id, name) in offlineFiles where !kept.contains(id) {
            try? FileManager.default.removeItem(at: Self.offlineFolder.appendingPathComponent(name))
            offlineFiles[id] = nil
        }
        let covers = offlineCovers
        if let names = try? FileManager.default.contentsOfDirectory(atPath: Self.coversFolder.path) {
            for name in names where !covers.contains((name as NSString).deletingPathExtension) {
                try? FileManager.default.removeItem(at: Self.coversFolder.appendingPathComponent(name))
            }
        }
        saveOffline()
    }

    /// The covers on screen when a collection is kept, so it shows them away from the phone.
    private func saveCovers(for items: [WatchItem]) {
        try? FileManager.default.createDirectory(at: Self.coversFolder, withIntermediateDirectories: true)
        for id in Set(items.compactMap(\.coverArt)) {
            let url = Self.coversFolder.appendingPathComponent("\(id).jpg")
            guard !FileManager.default.fileExists(atPath: url.path),
                  let data = covers[id]?.jpegData(compressionQuality: 0.7) else { continue }
            try? data.write(to: url)
        }
    }

    /// A song file the phone sent, already moved into the offline folder.
    func arrived(songId: String, name: String) {
        if let old = offlineFiles[songId], old != name {
            try? FileManager.default.removeItem(at: Self.offlineFolder.appendingPathComponent(old))
        }
        offlineFiles[songId] = name
        saveOffline()
    }

    /// Called before WatchConnectivity deletes the file it received.
    nonisolated static func store(_ file: WCSessionFile) -> (songId: String, name: String)? {
        guard let songId = file.metadata?[WatchOffline.songKey] as? String else { return nil }
        let ext = file.metadata?[WatchOffline.extensionKey] as? String ?? "mp3"
        let name = "\(songId).\(ext)"
        let url = offlineFolder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: offlineFolder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: file.fileURL, to: url)
            return (songId, name)
        } catch {
            log.error("Song not kept: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Playing

    var isLocal: Bool { localPlayer != nil }

    /// Plays a kept collection on the watch. The system asks for headphones first if none are
    /// connected; nothing plays if that's dismissed.
    func playOffline(_ item: WatchItem, index: Int = 0, shuffled: Bool = false) {
        guard let collection = collection(item) else { return }
        var queue = collection.songs.filter(isOnWatch)
        guard !queue.isEmpty else { return }
        var start = queue.firstIndex { $0.id == collection.songs[safe: index]?.id } ?? 0
        if shuffled {
            queue.shuffle()
            start = 0
        }
        path = []
        Task {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                guard try await session.activate(options: []) else { return }
            } catch {
                log.error("Audio not started: \(error.localizedDescription)")
                return
            }
            // The phone stops, so two players aren't heard at once.
            if !isLocal, state?.isPlaying == true { sendToPhone(.playPause) }
            if localPlayer == nil { startLocalPlayer() }
            localQueue = queue
            playLocal(at: start)
        }
    }

    private func startLocalPlayer() {
        let player = AVPlayer()
        localPlayer = player
        localObservers = [
            NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.localStep(1) }
            },
        ]
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in _ = self?.handleLocal(.playPause) }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.localPlayer?.rate == 0 { _ = self?.handleLocal(.playPause) } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.localPlayer?.rate != 0 { _ = self?.handleLocal(.playPause) } }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.localStep(1) }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in _ = self?.handleLocal(.previous) }
            return .success
        }
    }

    /// Back to the phone's player: something was started from the phone's library.
    func stopLocal() {
        guard let player = localPlayer else { return }
        player.pause()
        localObservers.forEach(NotificationCenter.default.removeObserver)
        localObservers = []
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.removeTarget(nil)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        localPlayer = nil
        localQueue = []
        try? AVAudioSession.sharedInstance().setActive(false)
        state = nil
        artwork = nil
        refresh()
    }

    private func playLocal(at index: Int) {
        guard let player = localPlayer, localQueue.indices.contains(index),
              let name = offlineFiles[localQueue[index].id] else { return }
        let direction = index < localIndex ? -1 : 1
        localIndex = index
        let asset = AVURLAsset(url: Self.offlineFolder.appendingPathComponent(name))
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.play()
        localDuration = 0
        songDirection = direction
        publishLocal()
        Task {
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            guard localPlayer?.currentItem?.asset === asset else { return }
            localDuration = duration.isFinite ? duration : 0
            publishLocal()
        }
    }

    private func localStep(_ step: Int) {
        let next = localIndex + step
        if localQueue.indices.contains(next) {
            playLocal(at: next)
        } else {
            localPlayer?.pause()
            localPlayer?.seek(to: .zero)
            publishLocal()
        }
    }

    /// Carries out a command on the watch's player. False for one that belongs to the phone.
    func handleLocal(_ command: WatchCommand) -> Bool {
        guard let player = localPlayer else { return false }
        switch command {
        case .playPause:
            if player.rate == 0 { player.play() } else { player.pause() }
        case .next:
            localStep(1)
            return true
        case .previous:
            if player.currentTime().seconds > 3 || localIndex == 0 {
                player.seek(to: .zero)
            } else {
                localStep(-1)
                return true
            }
        case .seek(let time):
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        case .play(let upcoming):
            playLocal(at: upcoming.slot)
            return true
        case .favorite, .playSomething:
            return true
        case .sendToWatch:
            return false
        case .playItem:
            stopLocal()
            return false
        }
        publishLocal()
        return true
    }

    /// The watch's player, shown the way the phone's is.
    private func publishLocal() {
        guard let player = localPlayer, localQueue.indices.contains(localIndex) else { return }
        let song = localQueue[localIndex]
        let position = player.currentTime().seconds
        var next = WatchNowPlaying(accent: state?.accent ?? [1, 1, 1])
        next.songId = song.id
        next.title = song.title
        next.artist = song.subtitle
        next.artworkId = song.coverArt
        next.isPlaying = player.rate != 0
        next.position = position.isFinite ? position : 0
        next.duration = localDuration
        next.upNext = localQueue.indices.dropFirst(localIndex + 1).prefix(20).map {
            .init(songId: localQueue[$0].id, title: localQueue[$0].title, artist: localQueue[$0].subtitle,
                  slot: $0, isQueued: false)
        }
        state = next
        artwork = song.coverArt.flatMap { covers[$0] }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.subtitle,
            MPMediaItemPropertyPlaybackDuration: localDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: next.position,
            MPNowPlayingInfoPropertyPlaybackRate: next.isPlaying ? 1.0 : 0.0,
        ]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
