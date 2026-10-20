import Foundation
import GroupActivities
import Combine
import SwiftUI

/// Listening together over FaceTime or Messages.
///
/// Everyone needs Aura and an account on the same server: SharePlay keeps the queue, the
/// song, the position and play or pause in step, and each phone streams the music from
/// the server itself. Nobody's audio crosses the call.
struct ListenTogether: GroupActivity {
    /// The server the queue lives on; a phone signed in elsewhere can't play its songs.
    let serverHost: String

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = String(localized: "Listen Together on Aura")
        metadata.type = .listenTogether
        return metadata
    }
}

/// What the share sheet offers: SharePlay with whoever is picked.
struct ListenTogetherInvite: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        GroupActivityTransferRepresentation { _ in
            ListenTogether(serverHost: SharePlay.currentHost ?? "")
        }
    }
}

@MainActor
@Observable
final class SharePlay {
    static let shared = SharePlay()

    private(set) var isActive = false
    /// Set when a SharePlay was refused because this phone is on another server.
    var notice: String?

    @ObservationIgnored private var session: GroupSession<ListenTogether>?
    @ObservationIgnored private var messenger: GroupSessionMessenger?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()

    /// The whole state a phone needs to fall in step: sent on every song change, play,
    /// pause and seek, and to whoever joins.
    private struct State: Codable {
        var queue: [Song]
        var index: Int
        var position: TimeInterval
        var isPlaying: Bool
        var sentAt: Date
    }

    nonisolated static var currentHost: String? {
        ServerManager.shared.currentServer.flatMap { URL(string: $0.url)?.host?.lowercased() }
    }

    func leave() { session?.leave() }

    /// Takes every SharePlay session the system hands the app, for its whole life.
    func observeSessions() async {
        for await session in ListenTogether.sessions() {
            join(session)
        }
    }

    private func join(_ session: GroupSession<ListenTogether>) {
        guard session.activity.serverHost == Self.currentHost else {
            notice = String(localized: "This SharePlay plays from another server. Everyone needs an account on the same one.")
            session.leave()
            return
        }
        reset()
        self.session = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger

        session.$state
            .sink { [weak self] state in
                if case .invalidated = state { Task { @MainActor in self?.reset() } }
            }
            .store(in: &subscriptions)
        // A newcomer gets the state straight away instead of waiting for the next change.
        session.$activeParticipants
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in await self?.send() } }
            .store(in: &subscriptions)

        tasks.append(Task { [weak self] in
            for await (state, _) in messenger.messages(of: State.self) {
                self?.apply(state)
            }
        })
        tasks.append(Task { [weak self] in await self?.followLocalChanges() })

        session.join()
        isActive = true
    }

    private func reset() {
        tasks.forEach { $0.cancel() }
        tasks = []
        subscriptions = []
        session = nil
        messenger = nil
        isActive = false
    }

    /// Sends the state whenever the song, play or pause, or the position (a seek) changes
    /// here. A change that came from someone else is sent back too, but it matches what
    /// they already have, so `apply` leaves it alone and the exchange stops there.
    private func followLocalChanges() async {
        let player = AudioPlayer.shared
        while !Task.isCancelled {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = player.currentSong?.id
                    _ = player.isPlaying
                    _ = player.seekCount
                } onChange: {
                    continuation.resume()
                }
            }
            // Lets a song change settle (it flips isPlaying and the song in a row).
            try? await Task.sleep(for: .milliseconds(300))
            await send()
        }
    }

    private func send() async {
        let player = AudioPlayer.shared
        guard let messenger, let song = player.currentSong else { return }
        // The songs around the one playing: a whole library queue would not fit a message.
        var queue = [song], index = 0
        if player.queue.indices.contains(player.queueIndex), player.queue[player.queueIndex].id == song.id {
            let low = max(0, player.queueIndex - 10)
            let high = min(player.queue.count, low + 100)
            queue = Array(player.queue[low..<high])
            index = player.queueIndex - low
        }
        let state = State(queue: queue, index: index, position: player.currentTime,
                          isPlaying: player.isPlaying, sentAt: Date())
        try? await messenger.send(state)
    }

    private func apply(_ state: State) {
        let player = AudioPlayer.shared
        guard state.queue.indices.contains(state.index) else { return }
        let song = state.queue[state.index]
        let elapsed = state.isPlaying ? max(0, Date().timeIntervalSince(state.sentAt)) : 0
        let target = state.position + elapsed
        if player.currentSong?.id != song.id {
            player.playSong(song, fromQueue: state.queue, startIndex: state.index)
            if target > 2 {
                // ponytail: waits a fixed second for the stream to open; seeking earlier is lost.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    player.seek(to: target + 1)
                }
            }
        } else if abs(player.currentTime - target) > 2 {
            player.seek(to: target)
        }
        if state.isPlaying != player.isPlaying {
            state.isPlaying ? player.play() : player.pause()
        }
    }
}
