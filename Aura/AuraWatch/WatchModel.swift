import OSLog
import SwiftUI
import UIKit
import WatchConnectivity

private let log = Logger(subsystem: "com.aura.goldian.watchkitapp", category: "link")

/// The watch's view of the player on the iPhone, and the way back to it.
///
/// Taps answer at once — the play button flips, the heart pulses — and the phone's next
/// snapshot confirms or corrects them, the same round-trip the phone's own heart makes.
@MainActor
@Observable
final class WatchModel: NSObject {
    private(set) var state: WatchNowPlaying?
    private(set) var artwork: UIImage?
    private(set) var isReachable = false
    private(set) var tone = WatchTone()
    /// Which way the last song change went: 1 forward, -1 back. A new song slides in from
    /// that side, as it does on the phone.
    private(set) var songDirection = 1
    private var pendingDirection = 1

    var accent: Color {
        let rgb = state?.accent ?? [1, 1, 1]
        guard rgb.count == 3 else { return .white }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ command: WatchCommand) {
        if case .previous = command { pendingDirection = -1 }
        anticipate(command)
        guard let data = try? JSONEncoder().encode(command) else { return }
        WCSession.default.sendMessage([WatchLinkKey.command: data], replyHandler: nil) { error in
            log.error("Command not sent: \(error.localizedDescription)")
        }
    }

    /// Asks the phone where it's at — on opening, and whenever it comes back in reach.
    func refresh() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([WatchLinkKey.hello: true], replyHandler: { reply in
            let box = UncheckedMessage(content: reply)
            Task { @MainActor in self.apply(box.content) }
        }, errorHandler: { error in
            log.error("No answer from the phone: \(error.localizedDescription)")
        })
    }

    private func anticipate(_ command: WatchCommand) {
        guard var state else { return }
        switch command {
        case .playPause:
            state.position = state.elapsed(at: Date())
            state.positionDate = Date()
            state.isPlaying.toggle()
        case .favorite:
            state.isSavingFavorite = true
        case .seek(let time):
            state.position = time
            state.positionDate = Date()
        default:
            return
        }
        self.state = state
    }

    fileprivate func apply(_ message: [String: Any]) {
        if let data = message[WatchLinkKey.state] as? Data,
           let state = try? JSONDecoder().decode(WatchNowPlaying.self, from: data) {
            if state.artworkId != self.state?.artworkId {
                artwork = nil
                tone = WatchTone()
            }
            if state.songId != self.state?.songId {
                songDirection = pendingDirection
                pendingDirection = 1
            }
            self.state = state
        }
        if let data = message[WatchLinkKey.artwork] as? Data { artwork = UIImage(data: data) }
        if let data = message[WatchLinkKey.tone] as? Data,
           let tone = try? JSONDecoder().decode(WatchTone.self, from: data) {
            self.tone = tone
        }
    }

    fileprivate func setReachable(_ reachable: Bool) {
        isReachable = reachable
        if reachable { refresh() }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        let box = UncheckedMessage(content: context)
        Task { @MainActor in
            self.apply(box.content)
            self.setReachable(reachable)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.setReachable(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let box = UncheckedMessage(content: context)
        Task { @MainActor in self.apply(box.content) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = UncheckedMessage(content: message)
        Task { @MainActor in self.apply(box.content) }
    }
}

/// A WatchConnectivity dictionary, carried to the main actor. It holds only property-list
/// values, which nothing else keeps a reference to.
private struct UncheckedMessage: @unchecked Sendable {
    let content: [String: Any]
}
