import Foundation
import MultipeerConnectivity
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// The iPhone as a remote for the Mac, on the same Wi-Fi. The Mac advertises itself; the
/// phone finds it, connects, sends transport commands and gets back what's playing once a
/// second. A Mac only lets in a phone signed into the same server account as itself.
@MainActor @Observable
final class RemoteLink: NSObject {
    static let shared = RemoteLink()
    private static let service = "aura-remote"

    enum Command: Codable { case playPause, next, previous, seek(Double), volume(Double) }

    struct State: Codable, Equatable {
        var title: String?
        var artist: String?
        var coverArt: String?
        var isPlaying = false
        var currentTime: Double = 0
        var duration: Double = 0
        var volume: Double = 1
    }

    /// Macs found on the network (phone side).
    private(set) var macs: [MCPeerID] = []
    /// The Mac being controlled, once connected (phone side).
    private(set) var connected: MCPeerID?
    /// What that Mac plays (phone side).
    private(set) var state: State?

    #if os(macOS)
    private let peer = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    #else
    private let peer = MCPeerID(displayName: UIDevice.current.name)
    #endif
    @ObservationIgnored private lazy var session: MCSession = {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var ticker: Timer?

    /// The server account, hashed: the one thing a phone and a Mac must share to pair.
    private var accountKey: Data? {
        guard let server = ServerManager.shared.currentServer else { return nil }
        return Data(SHA256.hash(data: Data("\(server.url)|\(server.username)".utf8)))
    }

    // MARK: Mac

    func host() {
        guard advertiser == nil else { return }
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: Self.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in RemoteLink.shared.broadcast() }
        }
    }

    private func broadcast() {
        guard !session.connectedPeers.isEmpty else { return }
        let player = AudioPlayer.shared
        let song = player.currentSong
        let now = State(title: song?.title, artist: song?.artist, coverArt: song?.coverArt ?? song?.albumId,
                        isPlaying: player.isPlaying, currentTime: player.currentTime,
                        duration: player.duration, volume: player.volume)
        guard let data = try? JSONEncoder().encode(now) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
    }

    private func perform(_ command: Command) {
        let player = AudioPlayer.shared
        switch command {
        case .playPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let time): player.seek(to: time)
        case .volume(let volume): player.volume = min(1, max(0, volume))
        }
        broadcast()
    }

    // MARK: Phone

    func browse() {
        guard browser == nil else { return }
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
        macs = []
    }

    func connect(to mac: MCPeerID) {
        browser?.invitePeer(mac, to: session, withContext: accountKey, timeout: 15)
    }

    func disconnect() {
        session.disconnect()
        connected = nil
        state = nil
    }

    func send(_ command: Command) {
        guard let connected, let data = try? JSONEncoder().encode(command) else { return }
        try? session.send(data, toPeers: [connected], with: .reliable)
    }
}

extension RemoteLink: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            if state == .connected, browser != nil { connected = peerID }
            if state == .notConnected, connected == peerID { connected = nil; self.state = nil }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            if advertiser != nil, let command = try? JSONDecoder().decode(Command.self, from: data) {
                perform(command)
            } else if let state = try? JSONDecoder().decode(State.self, from: data) {
                self.state = state
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let accepted = context != nil && context == accountKey
            invitationHandler(accepted, accepted ? session : nil)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in if !macs.contains(peerID) { macs.append(peerID) } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in macs.removeAll { $0 == peerID } }
    }
}
