import Foundation

/// Learns from user taps to boost frequently-selected results for a given query.
/// Stores [normalizedQuery: [resultId: tapCount]] in UserDefaults.
final class SearchRanking: @unchecked Sendable {
    static let shared = SearchRanking()

    private let key = "searchRankingData"
    private var data: [String: [String: Int]]

    private init() {
        data = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]]) ?? [:]
    }

    // MARK: - Recording

    /// Record that the user tapped a result while searching for `query`.
    /// Boosts are stored for the full query AND every prefix >= 2 characters,
    /// so typing "hor" benefits from a previous "hormiga" tap.
    func recordTap(query: String, resultId: String) {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard normalized.count >= 2 else { return }

        // Store boost for the full query and all prefixes >= 2 chars
        let prefixes = (2...normalized.count).map { String(normalized.prefix($0)) }
        for prefix in prefixes {
            var entry = data[prefix] ?? [:]
            entry[resultId, default: 0] += 1
            data[prefix] = entry
        }
        save()
    }

    // MARK: - Ranking

    /// Returns the tap-boost score for a given result ID at this query.
    func score(for resultId: String, query: String) -> Int {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard normalized.count >= 2 else { return 0 }
        return data[normalized]?[resultId] ?? 0
    }

    /// Re-sort an array of items by combining their original position with tap boost.
    /// Items with boost > 0 float to the top, ordered by boost descending,
    /// then original order for unranked items.
    func ranked<T>(_ items: [T], query: String, id: (T) -> String) -> [T] {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard normalized.count >= 2, let boosts = data[normalized], !boosts.isEmpty else { return items }

        return items.enumerated().sorted { a, b in
            let scoreA = boosts[id(a.element)] ?? 0
            let scoreB = boosts[id(b.element)] ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            return a.offset < b.offset // preserve original order for ties
        }.map(\.element)
    }

    // MARK: - Persistence

    private func save() {
        UserDefaults.standard.set(data, forKey: key)
    }
}
