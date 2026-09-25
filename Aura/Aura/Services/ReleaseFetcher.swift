import ActivityKit
import Foundation
import Observation
import UIKit

#if !APPSTORE_BUILD

/// A release on its way from Soulseek into the library.
struct ReleaseFetch: Codable, Identifiable, Equatable {
    enum Stage: String, Codable {
        case searching, downloading, importing, ready, failed
    }

    let release: RadarRelease
    /// The preview whose heart started it: starred once the song is in the library.
    let liked: String?
    var stage: Stage = .searching
    /// Copies of it Soulseek turned up.
    var found = 0
    /// What was picked: "FLAC · 4 tracks".
    var source: String?
    var progress: Double = 0
    var bytesPerSecond: Double = 0
    var queuePlace: Int?
    var downloaded: Date?
    var failure: String?
    /// The peers already asked, so a second attempt goes to someone else.
    var tried: [String] = []
    /// The download under way — who from, and which file is which track — so a relaunch
    /// follows it rather than starting over.
    var peer: String?
    var wanted: [String: Int] = [:]
    var total: Int64 = 0
    var trackCount = 0

    var id: String { release.id }
    var isActive: Bool { stage != .ready && stage != .failed }
}

/// Gets a radar release onto the server without anyone choosing files: searches Soulseek,
/// picks the best folder, downloads it — trying the next peer when one stalls — then waits
/// for the server to import it and nudges its scan, so it plays from the library as soon as
/// it can. Each step shows above the mini player and on the Lock Screen.
///
/// The server's import sets the pace: its downloads folder is swept every ten minutes, for
/// files at least ten minutes old, so a release lands 10–25 minutes after its download.
@MainActor
@Observable
final class ReleaseFetcher {
    static let shared = ReleaseFetcher()

    private(set) var fetches: [ReleaseFetch] = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let activities = ReleaseFetchActivities()

    private static let storeKey = "release_fetches_v1"
    /// Stop listening for more answers once a complete copy from a free peer is in hand.
    private static let searchWindow: TimeInterval = 25
    private static let earlyPick: TimeInterval = 6
    private static let maxAttempts = 3
    /// A peer that sends nothing for this long is passed over — unless it's the last one.
    private static let stallLimit: TimeInterval = 90
    private static let lastStallLimit: TimeInterval = 20 * 60
    /// The server's sweep: files wait ten minutes, then the next ten-minute run takes them.
    static let importEstimate: TimeInterval = 20 * 60
    private static let firstScan: TimeInterval = 10.5 * 60
    private static let scanEvery: TimeInterval = 4 * 60
    private static let importLimit: TimeInterval = 90 * 60
    private static let readyKept: TimeInterval = 30 * 60
    private static let readyShown: TimeInterval = 10 * 60

    /// Soulseek is the sideload build's, behind its beta switch.
    var isAvailable: Bool { AppSettings.shared.betaFeaturesEnabled }

    /// The fetches worth a banner: running ones first, then what just finished.
    var visible: [ReleaseFetch] {
        fetches.filter(\.isActive) + fetches.filter { !$0.isActive }
    }

    private init() {
        let now = Date()
        fetches = Self.load().filter { $0.isActive || $0.stage == .failed
            || now.timeIntervalSince($0.downloaded ?? now) < Self.readyKept }
        // Whatever was under way when the app last quit picks up where it was.
        for fetch in fetches where fetch.isActive { start(fetch.id) }
    }

    func fetch(for id: String) -> ReleaseFetch? { fetches.first { $0.id == id } }

    // MARK: Commands

    /// Starts fetching a release, or does nothing if it is already on its way.
    func get(_ release: RadarRelease, liking title: String? = nil) {
        guard isAvailable else { return }
        if let existing = fetch(for: release.id), existing.stage != .failed { return }
        fetches.removeAll { $0.id == release.id }
        fetches.insert(ReleaseFetch(release: release, liked: title), at: 0)
        save()
        start(release.id)
    }

    /// The release a preview comes from, fetched, and the preview starred once it's in.
    func get(preview song: Song) {
        guard let release = RadarService.shared.release(of: song) else {
            ToastManager.shared.show(String(localized: "This release is no longer on the radar"), icon: "exclamationmark.triangle")
            return
        }
        get(release, liking: song.title)
    }

    func retry(_ id: String) {
        guard let fetch = fetch(for: id), fetch.stage == .failed else { return }
        // Failed after the download: only the wait for the server needs doing again.
        update(id) {
            $0.stage = $0.downloaded == nil ? .searching : .importing
            $0.failure = nil
            if $0.downloaded != nil { $0.downloaded = Date() }
        }
        start(id)
    }

    func dismiss(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        activities.end(id)
        fetches.removeAll { $0.id == id }
        save()
    }

    // MARK: Pipeline

    private func start(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            await self?.run(id)
            self?.tasks[id] = nil
        }
    }

    private func run(_ id: String) async {
        guard let fetch = fetch(for: id) else { return }
        if fetch.stage == .searching || fetch.stage == .downloading {
            guard await obtain(id) else { return }
        }
        guard !Task.isCancelled, self.fetch(for: id)?.stage == .importing else { return }
        await awaitImport(id)
    }

    /// Search, pick, download. True once enough of the release is on the server's disk.
    private func obtain(_ id: String) async -> Bool {
        guard let fetch = fetch(for: id) else { return false }
        var arrived = Set<Int>()
        // Back from a relaunch mid-download: that download is still running on the server.
        if fetch.stage == .downloading, let peer = fetch.peer, !fetch.wanted.isEmpty {
            arrived = await follow(id, peer: peer, wanted: fetch.wanted, total: fetch.total, isLast: false)
            if Task.isCancelled { return false }
            if arrived.count >= SoulseekPick.required(of: fetch.trackCount) { return imported(id) }
        }

        update(id) { $0.stage = .searching; $0.progress = 0; $0.found = 0; $0.peer = nil; $0.wanted = [:] }
        guard let deezer = await RadarCatalog.tracks(albumId: fetch.release.id) else {
            fail(id, String(localized: "Deezer couldn't be reached"))
            return false
        }
        let tracks = deezer.map(SoulseekPick.Track.init)
        guard !tracks.isEmpty else {
            fail(id, String(localized: "Deezer lists no tracks for it"))
            return false
        }
        update(id) { $0.trackCount = tracks.count }
        let candidates: [SoulseekPick.Candidate]
        do {
            candidates = try await search(fetch.release, tracks: tracks, id: id)
        } catch {
            if !Task.isCancelled {
                fail(id, String(localized: "Soulseek isn't reachable — check it in Settings"))
            }
            return false
        }
        guard !candidates.isEmpty else {
            if !Task.isCancelled { fail(id, String(localized: "Nobody on Soulseek shares it yet")) }
            return false
        }

        for attempt in 0..<Self.maxAttempts {
            let tried = Set(self.fetch(for: id)?.tried ?? [])
            guard let pick = candidates.first(where: { candidate in
                !tried.contains(candidate.username)
                    && candidate.files.keys.contains { !arrived.contains($0) }
            }) else { break }
            let files = pick.files.filter { !arrived.contains($0.key) }
            let isLast = attempt == Self.maxAttempts - 1
                || !candidates.contains { $0.username != pick.username && !tried.contains($0.username) }
            arrived.formUnion(await download(files, from: pick, id: id, isLast: isLast))
            if Task.isCancelled { return false }
            if arrived.count >= SoulseekPick.required(of: tracks.count) { break }
        }
        guard !arrived.isEmpty else {
            fail(id, String(localized: "No one could send it — try again later"))
            return false
        }
        return imported(id)
    }

    /// Enough is on the server's disk: from here its import takes over.
    private func imported(_ id: String) -> Bool {
        update(id) { $0.stage = .importing; $0.downloaded = Date(); $0.progress = 1; $0.peer = nil; $0.wanted = [:] }
        return true
    }

    /// Asks Soulseek, one query after another, until a query turns up a copy.
    private func search(_ release: RadarRelease, tracks: [SoulseekPick.Track],
                        id: String) async throws -> [SoulseekPick.Candidate] {
        let client = SlskdClient.shared
        for query in SoulseekPick.queries(artist: release.artist.name, title: release.title) {
            let search = try await client.search(query: query)
            defer { Task { try? await client.deleteSearch(id: search.id) } }
            let began = Date()
            var best: [SoulseekPick.Candidate] = []
            while Date().timeIntervalSince(began) < Self.searchWindow {
                try await Task.sleep(for: .seconds(1.5))
                guard let status = try? await client.getSearch(id: search.id),
                      let responses = try? await client.getSearchResponses(id: search.id) else { continue }
                best = SoulseekPick.candidates(for: tracks, artist: release.artist.name,
                                               album: release.title, in: responses)
                let found = best.count
                update(id) { $0.found = found }
                if status.isFinished { break }
                if let top = best.first, top.files.count == tracks.count, top.hasFreeSlot,
                   Date().timeIntervalSince(began) > Self.earlyPick { break }
            }
            if !best.isEmpty { return best }
        }
        return []
    }

    /// Downloads a pick's files and follows them until they settle or stall. Returns the
    /// tracks that arrived.
    private func download(_ files: [Int: SlskdFile], from pick: SoulseekPick.Candidate,
                          id: String, isLast: Bool) async -> Set<Int> {
        let wanted = Dictionary(uniqueKeysWithValues: files.map { ($0.value.filename, $0.key) })
        let total = files.values.reduce(Int64(0)) { $0 + $1.size }
        let source = "\(pick.format) · \(String(localized: "\(files.count) tracks"))"
        update(id) {
            $0.stage = .downloading
            $0.tried.append(pick.username)
            $0.source = source
            $0.progress = 0
            $0.bytesPerSecond = 0
            $0.queuePlace = nil
            $0.peer = pick.username
            $0.wanted = wanted
            $0.total = total
        }
        let requests = files.values.map { SlskdDownloadRequest(filename: $0.filename, size: $0.size) }
        guard let response = try? await SlskdClient.shared.download(username: pick.username, files: requests)
        else { return [] }
        if (response.enqueued ?? []).isEmpty && !(response.failed ?? []).isEmpty { return [] }
        return await follow(id, peer: pick.username, wanted: wanted, total: total, isLast: isLast)
    }

    /// Follows a peer's transfers until they all settle, or stop moving for too long — then
    /// they're cancelled so the next peer can be asked.
    private func follow(_ id: String, peer: String, wanted: [String: Int], total: Int64,
                        isLast: Bool) async -> Set<Int> {
        let client = SlskdClient.shared
        var moved: Int64 = -1
        var lastMove = Date()
        let limit = isLast ? Self.lastStallLimit : Self.stallLimit
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let groups = try? await client.getDownloads() else { continue }
            let transfers = Self.latest(groups, username: peer, files: Set(wanted.keys))
            let bytes = transfers.reduce(Int64(0)) { $0 + ($1.bytesTransferred ?? 0) }
            let speed = transfers.filter(\.isInProgress).reduce(0) { $0 + ($1.averageSpeed ?? 0) }
            let place = transfers.compactMap(\.placeInQueue).filter { $0 > 0 }.min()
            update(id) {
                $0.progress = Double(bytes) / Double(max(total, 1))
                $0.bytesPerSecond = speed
                $0.queuePlace = bytes > 0 ? nil : place
            }
            if bytes > moved { moved = bytes; lastMove = Date() }

            let arrived = Set(transfers.filter(\.isCompleted).compactMap { wanted[$0.filename] })
            let settled = transfers.count == wanted.count && transfers.allSatisfy { $0.isCompleted || $0.isFailed }
            if settled { return arrived }
            if Date().timeIntervalSince(lastMove) > limit {
                for transfer in transfers where !transfer.isCompleted && !transfer.isFailed {
                    try? await client.deleteTransfer(username: peer, id: transfer.id)
                }
                return arrived
            }
        }
        return []
    }

    /// The newest transfer for each file: an earlier failed try may still be listed.
    private static func latest(_ groups: [SlskdTransferGroup], username: String,
                               files: Set<String>) -> [SlskdTransfer] {
        let all = groups.filter { $0.username == username }
            .flatMap { $0.directories ?? [] }
            .flatMap { $0.files ?? [] }
            .filter { files.contains($0.filename) }
        return Dictionary(grouping: all, by: \.filename).values.compactMap { copies in
            copies.max { ($0.startedAt ?? "", $0.isFailed ? 0 : 1) < ($1.startedAt ?? "", $1.isFailed ? 0 : 1) }
        }
    }

    /// Waits for the server to have the release, asking it to scan once its import has had
    /// time to run, rather than leaving it to the hourly scan.
    private func awaitImport(_ id: String) async {
        guard let release = fetch(for: id)?.release else { return }
        let downloaded = fetch(for: id)?.downloaded ?? Date()
        var lastScan: Date?
        while !Task.isCancelled {
            if let songs = await RadarService.shared.lookUp(release) {
                await finish(id, songs: songs)
                return
            }
            let waited = Date().timeIntervalSince(downloaded)
            if waited > Self.importLimit {
                fail(id, String(localized: "Downloaded, but your server hasn't added it yet"))
                return
            }
            if waited > Self.firstScan, lastScan.map({ Date().timeIntervalSince($0) > Self.scanEvery }) ?? true,
               let server = ServerManager.shared.currentServer {
                _ = try? await SubsonicClient.shared.startScan(server: server)
                lastScan = Date()
            }
            update(id) { _ in }
            try? await Task.sleep(for: .seconds(waited > Self.firstScan ? 30 : 60))
        }
    }

    private func finish(_ id: String, songs: [Song]) async {
        update(id) { $0.stage = .ready; $0.downloaded = $0.downloaded ?? Date() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // The banner lets it go after a while; the Lock Screen keeps it a little longer.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readyShown))
            guard self?.fetch(for: id)?.stage == .ready else { return }
            self?.fetches.removeAll { $0.id == id }
            self?.save()
        }
        guard let liked = fetch(for: id)?.liked,
              let song = songs.first(where: { RadarRules.sameTitle($0.title, liked) }) ?? (songs.count == 1 ? songs.first : nil),
              let server = ServerManager.shared.currentServer else { return }
        try? await SubsonicClient.shared.star(server: server, id: song.id)
    }

    private func fail(_ id: String, _ reason: String) {
        update(id) { $0.stage = .failed; $0.failure = reason }
        AppLogger.shared.log("⬇️ Fetch of \(id) failed: \(reason)")
    }

    // MARK: State

    private func update(_ id: String, _ change: (inout ReleaseFetch) -> Void) {
        guard let index = fetches.firstIndex(where: { $0.id == id }) else { return }
        var fetch = fetches[index]
        change(&fetch)
        fetches[index] = fetch
        save()
        activities.show(fetch)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(fetches) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private static func load() -> [ReleaseFetch] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([ReleaseFetch].self, from: data)) ?? []
    }
}

// MARK: - Wording

extension ReleaseFetch {
    /// The step it's at, in a few words.
    var headline: String {
        switch stage {
        case .searching:
            return found > 0 ? String(localized: "Picking the best copy") : String(localized: "Looking on Soulseek")
        case .downloading:
            return queuePlace != nil ? String(localized: "Waiting for the peer") : String(localized: "Downloading")
        case .importing:
            return String(localized: "Adding to your library")
        case .ready:
            return String(localized: "In your library")
        case .failed:
            return failure ?? String(localized: "Couldn't get it")
        }
    }

    /// The step's numbers.
    var detail: String {
        switch stage {
        case .searching:
            return found > 0 ? String(localized: "\(found) copies found") : ""
        case .downloading:
            if let queuePlace { return String(localized: "Place \(queuePlace) in their queue") }
            let parts = [source,
                         progress > 0 ? progress.formatted(.percent.precision(.fractionLength(0))) : nil,
                         bytesPerSecond > 0 ? "\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s" : nil]
            return parts.compactMap { $0 }.joined(separator: " · ")
        case .importing:
            guard let end = importEnd else { return "" }
            let minutes = Int((end.timeIntervalSinceNow / 60).rounded(.up))
            return minutes > 1 ? String(localized: "About \(minutes) min left") : String(localized: "Any moment now")
        case .ready:
            return String(localized: "Tap to play")
        case .failed:
            return downloaded == nil ? "" : String(localized: "The download itself went through")
        }
    }

    /// 0–3 through the four steps; -1 once it failed.
    var step: Int {
        switch stage {
        case .searching: 0
        case .downloading: 1
        case .importing: 2
        case .ready: 3
        case .failed: -1
        }
    }

    /// When the server's import should be done.
    var importEnd: Date? { downloaded.map { $0.addingTimeInterval(ReleaseFetcher.importEstimate) } }
}

// MARK: - Live Activity

/// One Live Activity per fetch, updated as it moves and ended when it's done.
@MainActor
private final class ReleaseFetchActivities {
    private var running: [String: Activity<ReleaseFetchAttributes>] = [:]
    private var shown: [String: (state: ReleaseFetchAttributes.ContentState, at: Date)] = [:]

    func show(_ fetch: ReleaseFetch) {
        let state = ReleaseFetchAttributes.ContentState(
            step: fetch.step, headline: fetch.headline, detail: fetch.detail,
            progress: fetch.stage == .downloading ? fetch.progress : nil,
            waitStart: fetch.stage == .importing ? fetch.downloaded : nil,
            waitEnd: fetch.stage == .importing ? fetch.importEnd : nil)
        // The download ticks every two seconds; the Lock Screen needs far fewer.
        if let last = shown[fetch.id], last.state.step == state.step,
           last.state == state || Date().timeIntervalSince(last.at) < 5 { return }
        shown[fetch.id] = (state, Date())

        let activity = running[fetch.id] ?? Activity<ReleaseFetchAttributes>.activities
            .first { $0.attributes.releaseId == fetch.id }
        let content = ActivityContent(state: state, staleDate: nil)
        if !fetch.isActive {
            if let activity {
                let policy: ActivityUIDismissalPolicy = fetch.stage == .ready ? .after(.now + 15 * 60) : .default
                Task { await activity.end(content, dismissalPolicy: policy) }
            }
            running[fetch.id] = nil
            shown[fetch.id] = nil
            return
        }
        if let activity {
            running[fetch.id] = activity
            Task { await activity.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            let attributes = ReleaseFetchAttributes(releaseId: fetch.id, title: fetch.release.title,
                                                    artist: fetch.release.artist.name)
            running[fetch.id] = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        }
    }

    func end(_ id: String) {
        let activity = running[id] ?? Activity<ReleaseFetchAttributes>.activities.first { $0.attributes.releaseId == id }
        running[id] = nil
        shown[id] = nil
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

#endif
