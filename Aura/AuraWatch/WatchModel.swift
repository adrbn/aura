import OSLog
import SwiftUI
import UIKit
import WatchConnectivity

private let log = Logger(subsystem: "com.adrbn.aura.watchkitapp", category: "link")

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

    /// The pages pushed over Now Playing. Emptied when something starts playing from the
    /// library, so the song is what the watch comes back to.
    var path: [WatchRoute] = []

    // The library, as last heard from the phone: kept so a page opened again shows at once
    // while it's asked again.
    private(set) var shelf: WatchShelf?
    private(set) var listings: [WatchItem: WatchListing] = [:]
    private(set) var searches: [String: WatchSearchResults] = [:]
    private(set) var covers: [String: UIImage] = [:]
    private var coversAsked: Set<String> = []
    private var coverBatch: [String] = []
    private var isCoverBatchScheduled = false

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

    /// Plays from the library and goes back to Now Playing to watch it start.
    func play(_ item: WatchItem, index: Int = 0, shuffled: Bool = false) {
        send(.playItem(item, index: index, shuffled: shuffled))
        path = []
    }

    /// False when the phone couldn't be reached or didn't answer.
    @discardableResult
    func loadShelf() async -> Bool {
        guard let shelf: WatchShelf = await ask(.shelf) else { return false }
        self.shelf = shelf
        return true
    }

    @discardableResult
    func open(_ item: WatchItem) async -> Bool {
        guard let listing: WatchListing = await ask(.open(item)) else { return false }
        listings[item] = listing
        return true
    }

    @discardableResult
    func search(_ query: String) async -> Bool {
        guard let results: WatchSearchResults = await ask(.search(query)) else { return false }
        searches[query] = results
        return true
    }

    /// Asks for a cover once, gathered with the others asked for in the same moment.
    func wantCover(_ id: String) {
        guard covers[id] == nil, coversAsked.insert(id).inserted else { return }
        coverBatch.append(id)
        guard !isCoverBatchScheduled else { return }
        isCoverBatchScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            isCoverBatchScheduled = false
            while !coverBatch.isEmpty {
                let ids = Array(coverBatch.prefix(Self.coversPerMessage))
                coverBatch.removeFirst(ids.count)
                await fetchCovers(ids)
            }
        }
    }

    private static let coversPerMessage = 6

    private func fetchCovers(_ ids: [String]) async {
        guard let data = try? JSONEncoder().encode(WatchRequest.covers(ids)),
              WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            // Asked again when the page next shows them.
            coversAsked.subtract(ids)
            return
        }
        let found: [String: Data] = await withCheckedContinuation { continuation in
            WCSession.default.sendMessage([WatchLinkKey.request: data], replyHandler: { reply in
                continuation.resume(returning: reply[WatchLinkKey.covers] as? [String: Data] ?? [:])
            }, errorHandler: { error in
                log.error("Covers not loaded: \(error.localizedDescription)")
                continuation.resume(returning: [:])
            })
        }
        for (id, data) in found { covers[id] = UIImage(data: data) }
        coversAsked.subtract(ids.filter { found[$0] == nil })
    }

    private func ask<Answer: Decodable & Sendable>(_ request: WatchRequest) async -> Answer? {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable,
              let data = try? JSONEncoder().encode(request) else { return nil }
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage([WatchLinkKey.request: data], replyHandler: { reply in
                let answer = (reply[WatchLinkKey.reply] as? Data)
                    .flatMap { try? JSONDecoder().decode(Answer.self, from: $0) }
                continuation.resume(returning: answer)
            }, errorHandler: { error in
                log.error("No answer from the phone: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            })
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
