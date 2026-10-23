import Foundation
import SwiftUI
import MultipeerConnectivity
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// The iPhone as a remote for the Mac, on the same Wi-Fi. The Mac advertises itself; the
/// phone finds it, connects, and from then on its own player shows what the Mac plays and
/// sends it every play, pause, skip and seek. A Mac only lets in a phone signed into the
/// same server account as itself.
@MainActor @Observable
final class RemoteLink: NSObject {
    static let shared = RemoteLink()
    private static let service = "aura-remote"

    enum Command: Codable {
        case play, pause, playPause, next, previous, seek(Double), shuffle, cycleRepeat
        case playSong(Song, queue: [Song]?, index: Int, source: PlaybackSource, at: Double)
        /// The phone's accent, so both ends show the same colour.
        case accent(red: Double, green: Double, blue: Double)
    }

    struct State: Codable {
        var song: Song?
        var isPlaying = false
        var currentTime: Double = 0
        var duration: Double = 0
        var isShuffled = false
        var repeatMode: RepeatMode = .off
        /// Sent only when it changed since the last state: a queue can be hundreds of songs.
        var queue: Queue?
    }

    struct Queue: Codable {
        var songs: [Song]
        var upNext: [Song]
        var index: Int
    }

    /// Macs found on the network (phone side).
    private(set) var macs: [MCPeerID] = []
    /// The Mac being controlled (phone side).
    private(set) var connected: MCPeerID?
    /// The phones controlling this Mac (Mac side).
    private(set) var controllers: [MCPeerID] = []
    /// The band's colour: the controlling phone's accent, on both ends.
    private(set) var accent: Color?

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
    /// What the phone was on before it took control, given back when it lets go.
    private var localSong: Song?
    private var localQueue = Queue(songs: [], upNext: [], index: 0)
    /// The queue as last sent (Mac side), to send it again only once it changes.
    private var sentQueue: [String]?

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
        var now = State(song: player.currentSong, isPlaying: player.isPlaying,
                        currentTime: player.currentTime, duration: player.duration,
                        isShuffled: player.isShuffled, repeatMode: player.repeatMode)
        let ids = [String(player.queueIndex)] + player.queue.map(\.id) + ["|"] + player.userQueue.map(\.id)
        if ids != sentQueue {
            now.queue = Queue(songs: player.queue, upNext: player.userQueue, index: player.queueIndex)
            sentQueue = ids
        }
        guard let data = try? JSONEncoder().encode(now) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: now.queue == nil ? .unreliable : .reliable)
    }

    private func perform(_ command: Command) {
        let player = AudioPlayer.shared
        switch command {
        case .play: player.play()
        case .pause: player.pause()
        case .playPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let time): player.seek(to: time)
        case .shuffle: player.toggleShuffle()
        case .cycleRepeat: player.cycleRepeat()
        case .playSong(let song, let queue, let index, let source, let time):
            player.playSong(song, fromQueue: queue, startIndex: index, source: source)
            if time > 1 { player.pendingSeekTime = time }
        case .accent(let red, let green, let blue):
            accent = Color(.sRGB, red: red, green: green, blue: blue)
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

    func connect(to mac: MCPeerID) {
        if connected != nil { playHere() }
        browser?.invitePeer(mac, to: session, withContext: accountKey, timeout: 15)
    }

    /// Back to this iPhone: what the Mac was playing carries on here, from the same
    /// moment, and the Mac stops.
    func playHere() {
        guard connected != nil else { return }
        let player = AudioPlayer.shared
        let song = player.currentSong, queue = player.queue, index = player.queueIndex
        let time = player.currentTime, wasPlaying = player.isPlaying
        send(.pause)
        // A moment for the pause to reach the Mac before the line drops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.session.disconnect() }
        letGo()
        guard wasPlaying, let song else { return }
        player.playSong(song, fromQueue: queue, startIndex: index)
        if time > 1 { player.pendingSeekTime = time }
    }

    func send(_ command: Command) {
        guard let connected, let data = try? JSONEncoder().encode(command) else { return }
        try? session.send(data, toPeers: [connected], with: .reliable)
    }

    private func takeControl(of mac: MCPeerID) {
        let player = AudioPlayer.shared
        localSong = player.currentSong
        localQueue = Queue(songs: player.queue, upNext: player.userQueue, index: player.queueIndex)
        let wasPlaying = player.isPlaying, time = player.currentTime
        player.pause()
        player.remote = { command in MainActor.assumeIsolated { RemoteLink.shared.send(command) } }
        connected = mac
        // What this iPhone was playing moves to the Mac, from the same moment.
        if wasPlaying, let song = localSong {
            send(.playSong(song, queue: localQueue.songs, index: localQueue.index, source: .unknown, at: time))
        }
        let tone = Color.appAccent.resolve(in: EnvironmentValues())
        accent = Color.appAccent
        send(.accent(red: Double(tone.red), green: Double(tone.green), blue: Double(tone.blue)))
    }

    private func letGo() {
        guard connected != nil else { return }
        connected = nil
        let player = AudioPlayer.shared
        player.remote = nil
        player.isPlaying = false
        player.currentSong = localSong
        player.currentTime = 0
        player.queue = localQueue.songs
        player.userQueue = localQueue.upNext
        player.queueIndex = localQueue.index
        if let localSong { player.loadLyrics(for: localSong) }
    }

    private func mirror(_ state: State) {
        let player = AudioPlayer.shared
        if let song = state.song, song.id != player.currentSong?.id {
            player.currentSong = song
            player.loadLyrics(for: song)
        }
        player.isPlaying = state.isPlaying
        player.currentTime = state.currentTime
        player.duration = state.duration
        player.isShuffled = state.isShuffled
        player.repeatMode = state.repeatMode
        if let queue = state.queue {
            player.queue = queue.songs
            player.userQueue = queue.upNext
            player.queueIndex = queue.index
        }
    }
}

extension RemoteLink: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            if advertiser != nil {
                controllers = session.connectedPeers
                // A phone just in gets the whole queue with the next state.
                if state == .connected { sentQueue = nil }
                if controllers.isEmpty { accent = nil }
            } else if state == .connected {
                takeControl(of: peerID)
            } else if state == .notConnected, connected == peerID {
                letGo()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            if advertiser != nil, let command = try? JSONDecoder().decode(Command.self, from: data) {
                perform(command)
            } else if connected == peerID, let state = try? JSONDecoder().decode(State.self, from: data) {
                mirror(state)
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

/// The band along the bottom while one device plays for another: the same colour, the
/// controlling phone's accent, on both ends.
struct RemoteBand: View {
    let text: String
    let systemImage: String
    var bottomInset: CGFloat = 0

    var body: some View {
        let colour = RemoteLink.shared.accent ?? .accentColor
        let tone = colour.resolve(in: EnvironmentValues())
        // Dark text on a light accent (yellow, green), white on a deep one.
        let light = 0.2126 * tone.red + 0.7152 * tone.green + 0.0722 * tone.blue > 0.55
        Label(text, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(light ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.top, 7)
            .padding(.bottom, 7 + bottomInset)
            .background(colour)
    }
}
