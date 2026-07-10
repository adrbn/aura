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
        case .artist: return "Artist"
        case .album(let a): return a.artist ?? "Album"
        case .song(let s): return s.artist ?? "Song"
        case .playlist(let p): return p.songCount.map { "\($0) songs" } ?? "Playlist"
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
