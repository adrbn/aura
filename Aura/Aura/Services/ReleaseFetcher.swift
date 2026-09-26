import ActivityKit
import Foundation
import Observation
import UIKit

#if !APPSTORE_BUILD

/// A release on its way from Soulseek into the library — or one of its songs.
struct ReleaseFetch: Codable, Identifiable, Equatable {
    enum Stage: String, Codable {
        case searching, downloading, importing, ready, failed
    }

    let release: RadarRelease
    /// The one song asked for, when it isn't the whole release.
    let track: SoulseekPick.Track?
    /// The preview whose heart started it: starred once the song is in the library.
    let liked: String?
    var stage: Stage = .searching
    /// Copies of it Soulseek turned up.
    var found = 0
    /// The picked copy's format: "FLAC", "MP3 320".
    var format: String?
    /// Of the picked copy's files, how many are in — optional so fetches saved before it still load.
    var tracksDone: Int?
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

    var id: String { Self.id(release.id, track: track?.id) }
    var title: String { track?.title ?? release.title }
    var isActive: Bool { stage != .ready && stage != .failed }

    static func id(_ releaseId: String, track trackId: Int?) -> String {
        trackId.map { "\(releaseId)/\($0)" } ?? releaseId
    }
}

/// Gets a radar release onto the server without anyone choosing files: searches Soulseek,
/// picks the best folder, downloads it — trying the next peer when one stalls — then waits
/// for the server to import it and nudges its scan, so it plays from the library as soon as
/// it can. Each step shows above the mini player and on the Lock Screen.
///
/// The server's import sets the pace: however often it sweeps its downloads folder, and how
/// old a file must be first. `ImportPace` learns it from the fetches that land.
@MainActor
@Observable
final class ReleaseFetcher {
    static let shared = ReleaseFetcher()

    private(set) var fetches: [ReleaseFetch] = []
    /// Releases the server has in part, from songs fetched one by one: the radar keeps
    /// listing them so the rest can be had, until the server has them whole.
    private(set) var picked: Set<String> = []
    @ObservationIgnored private var isSettling = false
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let activities = ReleaseFetchActivities()

    private static let storeKey = "release_fetches_v1"
    private static let pickedKey = "release_fetch_picked_v1"
    /// Stop listening for more answers once a complete copy from a free peer is in hand.
    private static let searchWindow: TimeInterval = 25
    private static let earlyPick: TimeInterval = 6
    private static let maxAttempts = 3
    /// A peer that sends nothing for this long is passed over — unless it's the last one.
    private static let stallLimit: TimeInterval = 90
    private static let lastStallLimit: TimeInterval = 20 * 60
    /// Halfway there with nothing yet: time to ask the server to look.
    private static var firstScan: TimeInterval { ImportPace.estimate / 2 }
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
        picked = Set(UserDefaults.standard.stringArray(forKey: Self.pickedKey) ?? [])
        // Whatever was under way when the app last quit picks up where it was.
        for fetch in fetches where fetch.isActive { start(fetch.id) }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReleaseFetcher.shared.leaving() }
        }
    }

    func fetch(for id: String) -> ReleaseFetch? { fetches.first { $0.id == id } }

    // MARK: Commands

    /// Starts fetching a release, or one of its songs — or does nothing if it is already on
    /// its way, the song included when the whole release is.
    func get(_ release: RadarRelease, track: SoulseekPick.Track? = nil, liking title: String? = nil) {
        guard isAvailable else { return }
        let fetch = ReleaseFetch(release: release, track: track, liked: title)
        if let existing = self.fetch(for: fetch.id), existing.stage != .failed { return }
        if track != nil, let whole = self.fetch(for: release.id), whole.stage != .failed { return }
        fetches.removeAll { $0.id == fetch.id }
        fetches.insert(fetch, at: 0)
        save()
        start(fetch.id)
    }

    /// Lets go of the picked releases the server now has whole — however the rest came —
    /// and of those the radar no longer lists. A song fetched on its own used to keep its
    /// release listed as missing for good, a one-song single included.
    func settlePicked() async {
        guard !isSettling, !picked.isEmpty, let radar = RadarService.shared.current else { return }
        isSettling = true
        defer { isSettling = false }
        for id in picked where !fetches.contains(where: { $0.release.id == id && $0.isActive }) {
            guard let release = radar.releases.first(where: { $0.id == id }) else {
                picked.remove(id)
                continue
            }
            if await RadarService.shared.settle(release) { picked.remove(id) }
        }
        savePicked()
    }

    /// The song a preview plays, fetched, and starred once it's in.
    func get(preview song: Song) {
        guard let release = RadarService.shared.release(of: song) else {
            ToastManager.shared.show(String(localized: "This release is no longer on the radar"), icon: "exclamationmark.triangle")
            return
        }
        get(release, track: Self.track(of: song, in: release), liking: song.title)
    }

    /// What's under way for a preview's song: its own fetch, or its whole release's.
    func fetch(covering song: Song) -> ReleaseFetch? {
        guard let release = RadarService.shared.release(of: song) else { return nil }
        let own = Self.track(of: song, in: release).flatMap { fetch(for: ReleaseFetch.id(release.id, track: $0.id)) }
        let whole = fetch(for: release.id)
        if let whole, whole.stage != .failed { return whole }
        return own ?? whole
    }

    /// A preview's song as Deezer lists it — with its real length, when the release's track
    /// list is at hand, since the preview only runs thirty seconds.
    private static func track(of song: Song, in release: RadarRelease) -> SoulseekPick.Track? {
        guard let id = Int(song.id.replacingOccurrences(of: "deezer-", with: "")) else { return nil }
        if let listed = RadarService.shared.trackLists[release.id]?.tracks.first(where: { $0.id == id }) {
            return SoulseekPick.Track(listed)
        }
        return SoulseekPick.Track(id: id, title: song.title, seconds: nil, position: song.track)
    }

    func retry(_ id: String) {
        guard let fetch = fetch(for: id), fetch.stage == .failed else { return }
        // Failed after the download: only the wait for the server needs doing again. Before
        // it, every peer gets asked afresh — the one that couldn't send may be back.
        update(id) {
            $0.stage = $0.downloaded == nil ? .searching : .importing
            $0.failure = nil
            if $0.downloaded != nil { $0.downloaded = Date() } else { $0.tried = [] }
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
        let tracks: [SoulseekPick.Track]
        if let track = fetch.track {
            tracks = [track]
        } else {
            guard let deezer = await RadarService.shared.tracks(of: fetch.release) else {
                fail(id, String(localized: "Deezer couldn't be reached"))
                return false
            }
            tracks = deezer.map(SoulseekPick.Track.init)
        }
        guard !tracks.isEmpty else {
            fail(id, String(localized: "Deezer lists no tracks for it"))
            return false
        }
        update(id) { $0.trackCount = tracks.count }
        var queries = SoulseekPick.queries(artist: fetch.release.artist.name, title: fetch.title)[...]
        var candidates: [SoulseekPick.Candidate] = []
        var reachable = false

        for attempt in 0..<Self.maxAttempts {
            let tried = Set(self.fetch(for: id)?.tried ?? [])
            let isOpen = { (candidate: SoulseekPick.Candidate) in
                !tried.contains(candidate.username) && candidate.files.keys.contains { !arrived.contains($0) }
            }
            // Down to one peer left to ask, or none: the queries not asked yet may turn up
            // others — and whether anyone's left decides how long the next one is waited on.
            while candidates.filter(isOpen).count < 2, !queries.isEmpty {
                do {
                    let result = try await search(fetch.release, queries: queries, tracks: tracks,
                                                  besides: Set(candidates.map(\.username)), id: id)
                    candidates += result.found
                    queries = result.rest
                    reachable = true
                } catch {
                    if Task.isCancelled { return false }
                    guard reachable else {
                        fail(id, String(localized: "Soulseek isn't reachable — check it in Settings"))
                        return false
                    }
                    queries = []
                }
            }
            if Task.isCancelled { return false }
            let open = candidates.filter(isOpen)
            guard let pick = open.first else { break }
            let files = pick.files.filter { !arrived.contains($0.key) }
            let isLast = attempt == Self.maxAttempts - 1 || open.count == 1
            arrived.formUnion(await download(files, from: pick, id: id, isLast: isLast))
            if Task.isCancelled { return false }
            if arrived.count >= SoulseekPick.required(of: tracks.count) { break }
        }
        guard !arrived.isEmpty else {
            fail(id, candidates.isEmpty
                 ? String(localized: "Nobody on Soulseek shares it yet")
                 : String(localized: "No one could send it — try again later"))
            return false
        }
        return imported(id)
    }

    /// Enough is on the server's disk: from here its import takes over.
    private func imported(_ id: String) -> Bool {
        update(id) { $0.stage = .importing; $0.downloaded = Date(); $0.progress = 1; $0.peer = nil; $0.wanted = [:] }
        return true
    }

    /// Asks Soulseek, one query after another, until a query turns up a copy from someone not
    /// among `known` — returning those copies and the queries left to ask.
    private func search(_ release: RadarRelease, queries: ArraySlice<String>, tracks: [SoulseekPick.Track],
                        besides known: Set<String>,
                        id: String) async throws -> (found: [SoulseekPick.Candidate], rest: ArraySlice<String>) {
        let client = SlskdClient.shared
        var rest = queries
        update(id) { $0.stage = .searching }
        while let query = rest.popFirst() {
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
                    .filter { !known.contains($0.username) }
                let found = known.count + best.count
                update(id) { $0.found = found }
                if status.isFinished { break }
                if let top = best.first, top.files.count == tracks.count, top.hasFreeSlot,
                   Date().timeIntervalSince(began) > Self.earlyPick { break }
            }
            if !best.isEmpty { return (best, rest) }
        }
        return ([], rest)
    }

    /// Downloads a pick's files and follows them until they settle or stall. Returns the
    /// tracks that arrived.
    private func download(_ files: [Int: SlskdFile], from pick: SoulseekPick.Candidate,
                          id: String, isLast: Bool) async -> Set<Int> {
        let wanted = Dictionary(uniqueKeysWithValues: files.map { ($0.value.filename, $0.key) })
        let total = files.values.reduce(Int64(0)) { $0 + $1.size }
        update(id) {
            $0.stage = .downloading
            $0.tried.append(pick.username)
            $0.format = pick.format
            $0.tracksDone = 0
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
            let arrived = Set(transfers.filter(\.isCompleted).compactMap { wanted[$0.filename] })
            update(id) {
                $0.progress = Double(bytes) / Double(max(total, 1))
                $0.bytesPerSecond = speed
                $0.queuePlace = bytes > 0 ? nil : place
                $0.tracksDone = arrived.count
            }
            if bytes > moved { moved = bytes; lastMove = Date() }

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
        guard let fetch = fetch(for: id) else { return }
        let downloaded = fetch.downloaded ?? Date()
        var lastScan: Date?
        while !Task.isCancelled {
            if let songs = await songs(of: fetch) {
                ImportPace.note(Date().timeIntervalSince(downloaded))
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
            let quick = waited > Self.firstScan || ImportPace.estimate < 5 * 60
            try? await Task.sleep(for: .seconds(quick ? 30 : 60))
        }
    }

    /// What the server has of a fetch: the release, or the one song. Nil until it's there.
    func songs(of fetch: ReleaseFetch) async -> [Song]? {
        guard let track = fetch.track else { return await RadarService.shared.lookUp(fetch.release) }
        return await RadarService.shared.lookUp(song: track.title, of: fetch.release)
    }

    private func finish(_ id: String, songs: [Song]) async {
        update(id) { $0.stage = .ready; $0.downloaded = $0.downloaded ?? Date() }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let liked = fetch(for: id)?.liked.flatMap { title in
            songs.first(where: { RadarRules.sameTitle($0.title, title) }) ?? (songs.count == 1 ? songs.first : nil)
        }
        // The song is starred just below; the copy the player takes says so already.
        let arrived = songs.map { song -> Song in
            guard song.id == liked?.id else { return song }
            var starred = song
            starred.starred = ISO8601DateFormatter().string(from: Date())
            return starred
        }
        // Its previews, queued or playing, become the song itself.
        if let release = fetch(for: id)?.release {
            let (album, artistId) = (release.title, release.artist.libraryId)
            Task {
                await AudioPlayer.shared.adoptLibrarySongs { preview in
                    guard preview.album == album, preview.artistId == artistId else { return nil }
                    return arrived.first { RadarRules.sameTitle($0.title, preview.title) }
                }
            }
        }
        // A song leaves its release in part on the server — unless it was the last one
        // missing, when the release moves into the radar's playlist whole.
        if let fetch = fetch(for: id) {
            if fetch.track != nil, !(await RadarService.shared.settle(fetch.release)) {
                picked.insert(fetch.release.id)
            } else {
                picked.remove(fetch.release.id)
            }
            savePicked()
        }
        // The banner lets it go after a while; the Lock Screen keeps it a little longer.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readyShown))
            guard self?.fetch(for: id)?.stage == .ready else { return }
            self?.fetches.removeAll { $0.id == id }
            self?.save()
        }
        guard let song = liked, let server = ServerManager.shared.currentServer else { return }
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
        savePicked()
    }

    private func savePicked() {
        UserDefaults.standard.set(Array(picked), forKey: Self.pickedKey)
    }

    /// The app going to the background: the Lock Screen gets the latest — the download's
    /// expected end included, which its bar runs to on its own once the app is asleep — and
    /// the fetch a few more seconds to move before iOS suspends it.
    private func leaving() {
        let running = fetches.filter(\.isActive)
        guard !running.isEmpty else { return }
        for fetch in running { activities.show(fetch, force: true) }
        BackgroundGrace().hold(for: 25)
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
            // "3/12 tracks": how far through the copy, not how many copies there were.
            let tracks = wanted.count < 2 ? nil : String(localized: "\(tracksDone ?? 0)/\(wanted.count) tracks")
            let parts = [format, tracks,
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
    var importEnd: Date? { downloaded.map { $0.addingTimeInterval(ImportPace.estimate) } }

    /// The download's expected run, from its share so far and its speed, placed so that the
    /// bar stands where the download is now: the Lock Screen runs it to the end on its own
    /// while the app sleeps.
    var downloadWindow: ClosedRange<Date>? {
        guard stage == .downloading, queuePlace == nil, bytesPerSecond > 0, progress > 0.01, progress < 1 else { return nil }
        let left = Double(total) * (1 - progress) / bytesPerSecond
        let now = Date()
        return now.addingTimeInterval(-left * progress / (1 - progress))...now.addingTimeInterval(left)
    }
}

/// A few seconds of background time, ended once — when they run out, or when iOS wants them
/// back, whichever comes first.
@MainActor
private final class BackgroundGrace {
    private var id = UIBackgroundTaskIdentifier.invalid

    func hold(for seconds: Double) {
        id = UIApplication.shared.beginBackgroundTask(withName: "Release fetch") {
            MainActor.assumeIsolated { self.end() }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            end()
        }
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

// MARK: - Live Activity

/// One Live Activity per fetch, updated as it moves and ended when it's done.
@MainActor
private final class ReleaseFetchActivities {
    private var running: [String: Activity<ReleaseFetchAttributes>] = [:]
    private var shown: [String: (state: ReleaseFetchAttributes.ContentState, at: Date)] = [:]

    func show(_ fetch: ReleaseFetch, force: Bool = false) {
        let window = fetch.downloadWindow
        let state = ReleaseFetchAttributes.ContentState(
            step: fetch.step, headline: fetch.headline, detail: fetch.detail,
            progress: fetch.stage == .downloading ? fetch.progress : nil,
            waitStart: fetch.stage == .importing ? fetch.downloaded : window?.lowerBound,
            waitEnd: fetch.stage == .importing ? fetch.importEnd : window?.upperBound)
        // The download ticks every two seconds; the Lock Screen needs far fewer.
        if !force, let last = shown[fetch.id], last.state.step == state.step,
           last.state == state || Date().timeIntervalSince(last.at) < 5 { return }
        shown[fetch.id] = (state, Date())

        let activity = running[fetch.id] ?? Activity<ReleaseFetchAttributes>.activities
            .first { $0.attributes.releaseId == fetch.id }
        // Past its expected end with no word from the app, the card says it may be behind.
        let stale = fetch.isActive ? state.waitEnd?.addingTimeInterval(5 * 60) : nil
        let content = ActivityContent(state: state, staleDate: stale)
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
            let attributes = ReleaseFetchAttributes(releaseId: fetch.id, title: fetch.title,
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

/// How long the server takes to add a download to the library, from the last few measured.
///
/// It is the server's alone — how often its import runs, how old a file must be first — so
/// any fixed figure was wrong for every server but one. The countdown on the card and the
/// Lock Screen, and when the app first asks for a scan, follow what was measured instead.
enum ImportPace {
    private static let key = "release_fetch_import_pace_v1"
    private static let kept = 5
    /// Before anything is measured: a sweep every ten minutes, of files ten minutes old.
    private static let assumed: TimeInterval = 20 * 60

    static var estimate: TimeInterval {
        let recent = UserDefaults.standard.array(forKey: key) as? [Double] ?? []
        guard !recent.isEmpty else { return assumed }
        return max(recent.sorted()[recent.count / 2], 60)
    }

    /// A release found on the server this long after its download finished. Anything under
    /// half a minute was there already, and says nothing about the import.
    static func note(_ seconds: TimeInterval) {
        guard seconds >= 30, seconds < 3 * 60 * 60 else { return }
        let recent = (UserDefaults.standard.array(forKey: key) as? [Double] ?? []) + [seconds]
        UserDefaults.standard.set(Array(recent.suffix(kept)), forKey: key)
    }
}

#endif
