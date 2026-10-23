import Foundation
import SwiftUI
import MultipeerConnectivity
import CryptoKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Aura playing on another Aura on the same Wi-Fi: the iPhone on the Mac, the Mac on the
/// iPhone, either on an iPad. Every Aura announces itself and looks for the others. The one
/// in control mirrors the other in its own player (what plays, the queue, the moment) and
/// sends it every play, pause, skip, seek, queue edit and volume change. A device only lets
/// in one signed into the same server account as itself.
@MainActor @Observable
final class RemoteLink: NSObject {
    static let shared = RemoteLink()
    private static let service = "aura-remote"

    enum Command: Codable {
        case play, pause, playPause, next, previous, seek(Double), shuffle, cycleRepeat, volume(Double)
        case playSong(Song, queue: [Song]?, index: Int, source: PlaybackSource, at: Double)
        case setQueue(Queue)
        case removeFromQueue(Int)
        /// The controller's accent, so both ends show the same colour.
        case accent(red: Double, green: Double, blue: Double)
    }

    struct State: Codable {
        var song: Song?
        var isPlaying = false
        var currentTime: Double = 0
        var duration: Double = 0
        var isShuffled = false
        var repeatMode: RepeatMode = .off
        var volume: Double = 1
        /// Sent only when it changed since the last state: a queue can be hundreds of songs.
        var queue: Queue?
    }

    struct Queue: Codable {
        var songs: [Song]
        var upNext: [Song]
        var index: Int
    }

    private enum Message: Codable { case command(Command), state(State) }

    struct Device: Hashable {
        let peer: MCPeerID
        let kind: String
        /// The title it plays right now, nil while it's paused or idle; its artist and cover.
        var playing: String? = nil
        var artist: String? = nil
        var cover: String? = nil
        var name: String { peer.displayName }
        var symbol: String { RemoteLink.symbol(for: kind) }
        static func == (a: Device, b: Device) -> Bool { a.peer == b.peer }
        func hash(into hasher: inout Hasher) { hasher.combine(peer) }
    }

    /// The other Auras in reach.
    private(set) var devices: [Device] = []
    /// The one this device plays on.
    private(set) var connected: Device?
    /// The ones playing on this device.
    private(set) var controllers: [MCPeerID] = []
    /// The band's colour: the controller's accent, on both ends.
    private(set) var accent: Color?

    #if os(macOS)
    static let kind = "mac"
    private let peer = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    #else
    static let kind = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    private let peer = MCPeerID(displayName: UIDevice.current.name)
    #endif
    nonisolated static func symbol(for kind: String) -> String {
        switch kind { case "mac": "macbook"; case "ipad": "ipad"; default: "iphone" }
    }

    /// Where this device plays on another.
    @ObservationIgnored private lazy var outgoing = makeSession()
    /// Where others play on this device.
    @ObservationIgnored private lazy var incoming = makeSession()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var ticker: Timer?
    private var volumeWatch: NSKeyValueObservation?
    private var invited: MCPeerID?
    /// What this device was on before it took control of another, given back after.
    private var local = (song: Song?.none, queue: Queue(songs: [], upNext: [], index: 0), volume: 1.0)
    /// The queue as last sent, to send it again only once it changes.
    private var sentQueue: [String]?
    private var bringing = true
    private var lastShown: (id: String?, playing: Bool, time: Double) = (nil, false, 0)
    /// What the announcement last said this device plays, to announce again once it changes.
    private var announced: String?

    private func makeSession() -> MCSession {
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    /// The server account, hashed: the one thing two devices must share to pair.
    private var accountKey: Data? {
        guard let server = ServerManager.shared.currentServer else { return nil }
        return Data(SHA256.hash(data: Data("\(server.url)|\(server.username)".utf8)))
    }

    var bandText: (text: String, symbol: String)? {
        if let connected { return (String(localized: "Playing on \(connected.name)"), connected.symbol) }
        if let controller = controllers.first {
            let kind = devices.first { $0.name == controller.displayName }?.kind ?? "iphone"
            return (String(localized: "Controlled from \(controller.displayName)"), Self.symbol(for: kind))
        }
        return nil
    }

    // MARK: Starting

    func start() {
        guard advertiser == nil else { return }
        announce()
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in RemoteLink.shared.tick() }
        }
        #if os(iOS)
        // The volume buttons, while this iPhone plays on another device, set that one's volume.
        volumeWatch = AVAudioSession.sharedInstance().observe(\.outputVolume) { session, _ in
            let volume = Double(session.outputVolume)
            Task { @MainActor in if RemoteLink.shared.connected != nil { RemoteLink.shared.send(.volume(volume)) } }
        }
        #endif
    }

    private var ticks = 0

    private func tick() {
        broadcast()
        announce()
        // A peer already found isn't reported again when its announcement changes: looking
        // afresh every few seconds is what shows a song started on the other device.
        ticks += 1
        // Each fresh browser finds the others again; one not found for a while has gone.
        devices.removeAll { device in
            device != connected && Date().timeIntervalSince(lastFound[device.name] ?? .distantPast) > 20
        }
        if ticks % 6 == 0, connected == nil, controllers.isEmpty, let old = browser {
            // A fresh browser rather than the same one stopped and started: restarting one
            // crashed in CFNetwork, cancelling a search still being torn down.
            old.stopBrowsingForPeers()
            old.delegate = nil
            retire(old)
            let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
        }
    }

    private var lastFound: [String: Date] = [:]

    /// Kept alive a few seconds after being stopped, for the network to finish with it.
    private var retired: [NSObject] = []
    private func retire(_ object: NSObject) {
        retired.append(object)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.retired.removeAll { $0 === object }
        }
    }

    /// Announces this device, with what it plays: the others see it playing without
    /// connecting. An announcement can't change, so a new one replaces it.
    private func announce() {
        let player = AudioPlayer.shared
        // Never while linked: the announcement that let a controller in carries its session,
        // and replacing it dropped the link seconds later.
        guard advertiser == nil || (connected == nil && controllers.isEmpty) else { return }
        let song = player.isPlaying ? player.currentSong : nil
        guard advertiser == nil || song?.id != announced else { return }
        announced = song?.id
        if let old = advertiser {
            old.stopAdvertisingPeer()
            old.delegate = nil
            retire(old)
        }
        var info = ["kind": Self.kind]
        // Kept short: the whole announcement has to fit in a Bonjour record.
        info["playing"] = song.map { String($0.title.prefix(80)) }
        info["artist"] = song?.artist.map { String($0.prefix(60)) }
        info["cover"] = song?.coverArt.map { String($0.prefix(80)) }
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: info, serviceType: Self.service)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    /// Another Aura playing at the same time as this one, which plays nothing of it.
    var playingElsewhere: Device? {
        guard connected == nil, controllers.isEmpty else { return nil }
        return devices.first { $0.playing != nil }
    }

    // MARK: Played on

    private func broadcast() {
        guard !incoming.connectedPeers.isEmpty else { return }
        let player = AudioPlayer.shared
        var now = State(song: player.currentSong, isPlaying: player.isPlaying,
                        currentTime: player.currentTime, duration: player.duration,
                        isShuffled: player.isShuffled, repeatMode: player.repeatMode, volume: player.volume)
        let ids = [String(player.queueIndex)] + player.queue.map(\.id) + ["|"] + player.userQueue.map(\.id)
        if ids != sentQueue {
            now.queue = Queue(songs: player.queue, upNext: player.userQueue, index: player.queueIndex)
            sentQueue = ids
        }
        guard let data = try? JSONEncoder().encode(Message.state(now)) else { return }
        try? incoming.send(data, toPeers: incoming.connectedPeers, with: now.queue == nil ? .unreliable : .reliable)
    }

    private func perform(_ command: Command) {
        handOver()
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
        case .volume(let volume): player.volume = min(1, max(0, volume))
        case .playSong(let song, let queue, let index, let source, let time):
            player.playSong(song, fromQueue: queue, startIndex: index, source: source)
            if time > 1 { player.pendingSeekTime = time }
        case .setQueue(let queue):
            player.queue = queue.songs
            player.userQueue = queue.upNext
            player.queueIndex = min(queue.index, max(queue.songs.count - 1, 0))
        case .removeFromQueue(let index):
            if player.queue.indices.contains(index) { player.removeFromQueue(at: index) }
        case .accent(let red, let green, let blue):
            accent = Color(.sRGB, red: red, green: green, blue: blue)
        }
        broadcast()
    }

    // MARK: Playing on

    /// `bringing`: what plays here moves over and replaces what plays there. Without it,
    /// this device stops and takes the remote of what the other one already plays.
    func connect(to device: Device, bringing: Bool = true) {
        if connected != nil { playHere() }
        self.bringing = bringing
        invited = device.peer
        browser?.invitePeer(device.peer, to: outgoing, withContext: accountKey, timeout: 15)
    }

    /// Back to this device: what the other one was playing carries on here, from the same
    /// moment, and the other one stops.
    func playHere() {
        guard connected != nil else { return }
        let player = AudioPlayer.shared
        let song = player.currentSong, queue = player.queue, index = player.queueIndex
        let time = player.currentTime, wasPlaying = player.isPlaying
        send(.pause)
        // A moment for the pause to arrive before the line drops.
        let session = outgoing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { session.disconnect() }
        letGo()
        guard wasPlaying, let song else { return }
        player.playSong(song, fromQueue: queue, startIndex: index)
        if time > 1 { player.pendingSeekTime = time }
    }

    func send(_ command: Command) {
        guard let connected, let data = try? JSONEncoder().encode(Message.command(command)) else { return }
        try? outgoing.send(data, toPeers: [connected.peer], with: .reliable)
    }

    private func takeControl(of peerID: MCPeerID) {
        let device = devices.first { $0.peer == peerID } ?? Device(peer: peerID, kind: "mac")
        let player = AudioPlayer.shared
        local = (player.currentSong, Queue(songs: player.queue, upNext: player.userQueue, index: player.queueIndex), player.volume)
        let wasPlaying = player.isPlaying, time = player.currentTime
        player.pause()
        player.remote = { command in MainActor.assumeIsolated { RemoteLink.shared.send(command) } }
        connected = device
        let tone = Color.appAccent.resolve(in: EnvironmentValues())
        accent = Color.appAccent
        send(.accent(red: Double(tone.red), green: Double(tone.green), blue: Double(tone.blue)))
        // What this device was playing moves over, from the same moment.
        if bringing, wasPlaying, let song = local.song {
            send(.playSong(song, queue: local.queue.songs, index: local.queue.index, source: .unknown, at: time))
        }
    }

    /// Another device plays on this one: this one stops playing on any other, or each
    /// would drive the other. What the new controller plays comes over with its first command.
    private func handOver() {
        guard connected != nil else { return }
        outgoing.disconnect()
        letGo()
    }

    private func letGo() {
        guard connected != nil else { return }
        connected = nil
        if controllers.isEmpty { accent = nil }
        let player = AudioPlayer.shared
        player.remote = nil
        player.remoteAnchor = nil
        player.isMirroring = true
        player.isPlaying = false
        player.currentSong = local.song
        player.currentTime = 0
        player.queue = local.queue.songs
        player.userQueue = local.queue.upNext
        player.queueIndex = local.queue.index
        player.volume = local.volume
        player.isMirroring = false
        if let song = local.song { player.loadLyrics(for: song) }
        player.updateNowPlayingInfo()
    }

    private func mirror(_ state: State) {
        let player = AudioPlayer.shared
        player.isMirroring = true
        defer { player.isMirroring = false }
        if let song = state.song, song.id != player.currentSong?.id {
            player.currentSong = song
            player.loadLyrics(for: song)
        }
        // Re-anchored only when the reports drift from the running clock, so the word
        // highlight never steps back by the network's delay.
        let running = player.remoteAnchor.map { $0.time + (player.isPlaying ? Date().timeIntervalSince($0.at) : 0) }
        if running == nil || abs(running! - state.currentTime) > 0.4 || state.isPlaying != player.isPlaying || state.song?.id != player.currentSong?.id {
            player.remoteAnchor = (state.currentTime, Date())
        }
        player.isPlaying = state.isPlaying
        player.currentTime = state.currentTime
        player.duration = state.duration
        player.isShuffled = state.isShuffled
        player.repeatMode = state.repeatMode
        player.volume = state.volume
        if let queue = state.queue {
            player.queue = queue.songs
            player.userQueue = queue.upNext
            player.queueIndex = queue.index
        }
        // The lock screen and the Dynamic Island show the other device, refreshed when what
        // they show changes, not every second (the elapsed time runs on by itself).
        let expected = lastShown.time + (lastShown.playing ? 1 : 0)
        if lastShown.id != state.song?.id || lastShown.playing != state.isPlaying || abs(state.currentTime - expected) > 2 {
            player.updateNowPlayingInfo()
            player.publishPlaybackState()
        }
        lastShown = (state.song?.id, state.isPlaying, state.currentTime)
    }
}

extension RemoteLink: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            if session === incoming {
                controllers = session.connectedPeers
                // One just in gets the whole queue with the next state.
                if state == .connected { sentQueue = nil; handOver() }
                if controllers.isEmpty, connected == nil { accent = nil }
            } else if state == .connected, invited == peerID {
                invited = nil
                takeControl(of: peerID)
            } else if state == .notConnected, let lost = connected, lost.peer == peerID {
                letGo()
                // Dropped rather than handed back: link up again, or the next Space plays here
                // and pulls the AirPods away from the device that was playing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    MainActor.assumeIsolated {
                        let link = RemoteLink.shared
                        guard link.connected == nil, link.invited == nil,
                              let device = link.devices.first(where: { $0.name == lost.name }) else { return }
                        link.connect(to: device, bringing: false)
                    }
                }
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            switch try? JSONDecoder().decode(Message.self, from: data) {
            case .command(let command) where session === incoming: perform(command)
            case .state(let state) where session === outgoing && connected?.peer == peerID: mirror(state)
            default: break
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
            invitationHandler(accepted, accepted ? incoming : nil)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard peerID != peer else { return }
            // A device that relaunched comes back under a new identity with the same name.
            devices.removeAll { $0.name == peerID.displayName }
            lastFound[peerID.displayName] = Date()
            devices.append(Device(peer: peerID, kind: info?["kind"] ?? "mac", playing: info?["playing"],
                                  artist: info?["artist"], cover: info?["cover"]))
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in devices.removeAll { $0.peer == peerID } }
    }
}

/// A device in a "Play on" menu. While this one plays, it asks which music goes on: the
/// song playing here, or the one already playing there.
struct RemoteDeviceItem: View {
    let device: RemoteLink.Device

    var body: some View {
        let link = RemoteLink.shared
        if AudioPlayer.shared.isPlaying, link.connected == nil {
            Menu {
                Button("Send This Song") { link.connect(to: device) }
                Button("Control What It Plays") { link.connect(to: device, bringing: false) }
            } label: {
                Label(device.name, systemImage: device.symbol)
            }
        } else {
            Button { link.connect(to: device) } label: {
                Label(device.name, systemImage: link.connected == device ? "checkmark" : device.symbol)
            }
        }
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
            .padding(.top, 5)
            // The text sits just above the home indicator, not a whole safe area higher.
            .padding(.bottom, max(5, bottomInset - 14))
            .background(colour)
    }
}

/// Another Aura playing at the same time, the Mac on the phone, the phone on the Mac: what it plays, and a tap to
/// control it from here. Left alone, this device plays its own music beside it.
struct PlayingElsewhereRow: View {
    @Environment(\.appAccentColor) private var accentColor
    @State private var dismissed: String?

    var body: some View {
        let link = RemoteLink.shared
        if let device = link.playingElsewhere, let playing = device.playing, dismissed != "\(device.name)|\(playing)" {
            // The mini player's own shape, over it: a second player, the other device's. Left
            // alone, this device goes on playing its own music.
            HStack(spacing: 12) {
                CoverArtImage(coverArt: device.cover, size: 44, cornerRadius: 6,
                              placeholderName: playing, placeholderKind: .song)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playing)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Label(device.name, systemImage: device.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { link.connect(to: device, bringing: false) } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Control")
                Button {
                    withAnimation(.smooth(duration: 0.3)) { dismissed = "\(device.name)|\(playing)" }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 26, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 16).padding(.trailing, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { link.connect(to: device, bringing: false) }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            #if os(iOS)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            #else
            .frame(width: 340)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            #endif
        }
    }
}
