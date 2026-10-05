import Foundation

/// A single entry in the "Recently Searched" history — an actual entity the user
/// opened or played from search, so we can show artwork and re-navigate on tap.
enum RecentSearchEntry: Codable, Hashable, Identifiable {
    case artist(Artist)
    case album(Album)
    case song(Song)
    case playlist(Playlist)

    /// Stable id namespaced by kind (the same id can exist as both an album and a playlist).
    var id: String {
        switch self {
        case .artist(let a): return "artist:\(a.id)"
        case .album(let a): return "album:\(a.id)"
        case .song(let s): return "song:\(s.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        }
    }

    var title: String {
        switch self {
        case .artist(let a): return a.name
        case .album(let a): return a.name
        case .song(let s): return s.title
        case .playlist(let p): return p.name
        }
    }

    var subtitle: String? {
        switch self {
        case .artist: return String(localized: "Artist")
        case .album(let a): return a.artist ?? String(localized: "Album")
        case .song(let s): return s.artist ?? String(localized: "Song")
        case .playlist(let p): return p.songCount.map { String(localized: "\($0) songs") } ?? String(localized: "Playlist")
        }
    }

    var coverArt: String? {
        switch self {
        case .artist(let a): return a.coverArt
        case .album(let a): return a.coverArt
        case .song(let s): return s.coverArt
        case .playlist(let p): return p.coverArt
        }
    }

    /// Artist artwork is shown as a circle.
    var isCircular: Bool { if case .artist = self { return true } else { return false } }

    var playableSong: Song? {
        if case .song(let s) = self { return s } else { return nil }
    }
}

/// Persisted, app-wide "Recently Searched" history shared by every search entry point.
@MainActor
@Observable
final class SearchHistory {
    static let shared = SearchHistory()

    private(set) var entries: [RecentSearchEntry] = []
    private let key = "musika_search_history_v1"
    private let maxEntries = 24

    private init() { load() }

    /// Opened from search, but not yet listened to.
    ///
    /// Recently Searched is a record of what you *played*, not of what you looked at — an
    /// album opened to read its tracklist and left behind has no business sitting in it.
    /// Navigation only arms an entry; playing something from it is what commits it.
    private(set) var pending: RecentSearchEntry?

    /// Called when search navigates to an artist, album or playlist.
    func arm(_ entry: RecentSearchEntry) { pending = entry }

    /// Called when the user comes back without having played anything.
    func disarm() { pending = nil }

    /// Commits the armed entry, but only if playback has actually started from that same
    /// entity — matched on id, so leaving search open and playing something unrelated
    /// somewhere else can't quietly write a row nobody asked for.
    func commitIfPlaying(source: PlaybackSource) {
        guard let entry = pending, Self.matches(entry: entry, source: source) else { return }
        pending = nil
        record(entry)
    }

    private static func matches(entry: RecentSearchEntry, source: PlaybackSource) -> Bool {
        switch (entry, source) {
        case (.album(let a), .album(let id, _)): return a.id == id
        case (.artist(let a), .artist(let id, _)): return a.id == id
        case (.playlist(let p), .playlist(let id, _)): return p.id == id
        // Songs never go through this: playing one from search records it outright.
        default: return false
        }
    }

    func record(_ entry: RecentSearchEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
    }

    func remove(_ entry: RecentSearchEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentSearchEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
