import Foundation

/// Tracks played songs locally:
/// - `entries`: a small, deduplicated "recently played" list for the Home screen.
/// - `plays`:   an append-only, richer log used to build listening stats / Wrapped.
final class PlayHistory: @unchecked Sendable {
    static let shared = PlayHistory()

    private let key = "musika_play_history"
    private let maxEntries = 200
    private var entries: [Entry] = []

    private let logKey = "musika_listening_log_v1"
    /// Retain a little over a year so a full-year Wrapped is always available,
    /// with a hard cap so the log can't grow unbounded for heavy listeners.
    private let logRetentionDays = 400
    private let logMaxRecords = 8000
    private var plays: [PlayRecord] = []
    private let lock = NSLock()

    struct Entry: Codable {
        let songId: String
        let timestamp: Date
    }

    /// One rich play event (never deduplicated — every play counts toward stats).
    struct PlayRecord: Codable {
        let songId: String
        let title: String
        let artist: String
        let album: String?
        let genre: String?
        let coverArt: String?
        let durationSeconds: Int
        let playedAt: Date
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
        if let data = UserDefaults.standard.data(forKey: logKey),
           let decoded = try? JSONDecoder().decode([PlayRecord].self, from: data) {
            plays = decoded
        }
    }

    /// Record a song play — updates both the recents list and the rich stats log.
    func record(song: Song) {
        lock.lock()
        // Recents (deduped, newest first).
        entries.removeAll { $0.songId == song.id }
        entries.insert(Entry(songId: song.id, timestamp: Date()), at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        // Rich log (append-only).
        plays.append(PlayRecord(
            songId: song.id,
            title: song.title,
            artist: song.artist ?? "Unknown Artist",
            album: song.album,
            genre: song.genre,
            coverArt: song.displayCoverArt,
            durationSeconds: max(0, song.duration ?? 0),
            playedAt: Date()
        ))
        pruneLogLocked()
        let entriesSnapshot = entries
        let playsSnapshot = plays
        lock.unlock()
        save(entriesSnapshot)
        saveLog(playsSnapshot)
    }

    /// Back-compat entry point for callers that only have a song id.
    func record(songId: String) {
        lock.lock()
        entries.removeAll { $0.songId == songId }
        entries.insert(Entry(songId: songId, timestamp: Date()), at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        let entriesSnapshot = entries
        lock.unlock()
        save(entriesSnapshot)
    }

    /// Returns the most recently played song IDs, newest first, deduplicated.
    func recentSongIds(limit: Int = 50) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.prefix(limit).map(\.songId))
    }

    /// Snapshot of the rich play log (newest last), for stats aggregation.
    func allPlays() -> [PlayRecord] {
        lock.lock(); defer { lock.unlock() }
        return plays
    }

    private func pruneLogLocked() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -logRetentionDays, to: Date()) ?? .distantPast
        plays.removeAll { $0.playedAt < cutoff }
        if plays.count > logMaxRecords {
            plays = Array(plays.suffix(logMaxRecords))
        }
    }

    private func save(_ snapshot: [Entry]) {
        DispatchQueue.global(qos: .utility).async { [key] in
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func saveLog(_ snapshot: [PlayRecord]) {
        DispatchQueue.global(qos: .utility).async { [logKey] in
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: logKey)
            }
        }
    }
}
