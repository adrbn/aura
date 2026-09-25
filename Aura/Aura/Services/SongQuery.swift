import Foundation

/// Pure text handling for matching a locally-tagged song against a streaming
/// catalogue, and for building the search-URL fallbacks.
///
/// Split out of `SongLinkService` so it can be tested without a network: every
/// function here is a total function of its inputs. The service keeps the HTTP
/// and the caching; this keeps the string wrangling.
enum SongQuery {

    // MARK: - Folding

    /// Fold text for comparison: case, diacritics, and the typographic apostrophes
    /// that Apple and Deezer use almost universally while hand-written tags often
    /// spell with ASCII. Without this, "Don\u{2019}t Stop Me Now" from a catalogue never
    /// matches "Don't Stop Me Now" from a tag, and a short unrelated title wins.
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// True when `prefix` ends on a word boundary in `s`, so "Alesso" prefixes
    /// "Alesso & Zara Larsson" but "Ale" does not.
    private static func hasWordPrefix(_ s: String, _ prefix: String) -> Bool {
        guard s.hasPrefix(prefix) else { return false }
        let idx = s.index(s.startIndex, offsetBy: prefix.count)
        guard idx < s.endIndex else { return true }
        return !s[idx].isLetter && !s[idx].isNumber
    }

    // MARK: - Normalization

    /// The primary artist for matching. Streaming search APIs match poorly on
    /// multi-artist credit strings ("Armand van Helden • KAREN HARDING", "A feat. B"),
    /// so we search with just the lead artist and verify the result.
    static func primaryArtist(_ artist: String) -> String {
        // A *spaced* slash separates two credited artists; an unspaced one is part
        // of the name ("AC/DC"), so it must not appear here.
        let separators = [" • ", " •", "• ", "•", " feat.", " feat ", " featuring",
                          " ft.", " ft ", " & ", ", ", " x ", " vs. ", " vs ",
                          " with ", " / ", ";"]
        var result = artist
        for sep in separators {
            guard let range = result.range(of: sep, options: [.caseInsensitive]) else { continue }
            let head = String(result[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // A separator sitting at position 0 means the credit string merely
            // *starts* with it. Keep what follows instead of handing the whole
            // string back with the bullet still attached — that goes verbatim
            // into the search term and guarantees zero results.
            result = head.isEmpty ? String(result[range.upperBound...]) : head
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip featured-artist clutter that blocks exact matches, while keeping
    /// meaningful parentheticals (remix names, "(I Won't Let You Down)", etc.).
    static func cleanTitle(_ title: String) -> String {
        // Each pattern requires whitespace after the keyword, so "(Feathers)" and
        // "(Within)" survive. Both bracket shapes appear in Subsonic tags, as does
        // the unbracketed trailing form.
        let patterns = [
            "\\s*[\\(\\[](feat|ft)\\.?\\s[^\\)\\]]*[\\)\\]]",
            "\\s*[\\(\\[]featuring\\s[^\\)\\]]*[\\)\\]]",
            "\\s*[\\(\\[]with\\s[^\\)\\]]*[\\)\\]]",
            "\\s+(feat|ft)\\.?\\s.*$",
            "\\s+featuring\\s.*$",
        ]
        var t = title
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // A nested "(feat. A (Live))" leaves the outer bracket behind; drop any
        // now-unbalanced tail rather than feeding ")" into the search.
        while let last = t.last, last == ")" || last == "]",
              t.filter({ $0 == last }).count > t.filter({ $0 == (last == ")" ? "(" : "[") }).count {
            t.removeLast()
        }
        let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never hand back an empty target: every candidate would then score 0 and
        // the caller would accept an arbitrary track.
        return cleaned.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    // MARK: - Verification

    /// Does this search result really correspond to the artist we asked for?
    ///
    /// Containment is what lets "Alesso" match "Alesso & Zara Larsson", but a plain
    /// bidirectional substring test also matched "Paul Simon" against a query for
    /// "Simon & Garfunkel" — a different recording. Anchoring at a word boundary
    /// keeps the useful case and drops that one.
    static func artistMatches(_ candidate: String?, query: String) -> Bool {
        guard let candidate else { return false }
        let c = fold(candidate)
        let q = fold(primaryArtist(query))
        guard c.count >= 2, q.count >= 2 else { return false }
        if c == q { return true }
        return hasWordPrefix(c, q) || hasWordPrefix(q, c)
    }

    /// True when the candidate names exactly the artist asked for — used only to
    /// break ties between equally-scored titles.
    static func isExactArtist(_ candidate: String?, query: String) -> Bool {
        guard let candidate else { return false }
        let c = fold(candidate)
        return c == fold(query) || c == fold(primaryArtist(query))
    }

    /// Rank a candidate title against the target. Bands never overlap, so an exact
    /// match always beats a bracketed variant, which always beats a partial one.
    ///
    /// A score of 0 means "not this song" and the caller must reject it.
    static func titleScore(_ trackName: String?, target: String) -> Int {
        guard let trackName else { return 0 }
        let n = fold(trackName)
        let t = fold(target)
        guard !n.isEmpty, !t.isEmpty else { return 0 }

        if n == t { return 1000 }

        // Same song, qualified: "Destinations [Extended Mix]". Among these the
        // shortest wins, since extra qualifiers mean a rarer pressing.
        let stripped = n.replacingOccurrences(of: "\\s*[\\[\\(].*?[\\]\\)]", with: "",
                                              options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if stripped == t { return 700 - min(n.count, 99) }

        // One contains the other. Score by how much of the two actually overlaps:
        // the previous "300 - n.count" rewarded the SHORTEST candidate, so a track
        // called "Free" outranked "Everybody's Free (To Feel Good)".
        if n.contains(t) || t.contains(n) {
            let overlap = (100 * min(n.count, t.count)) / max(n.count, t.count)
            return 200 + overlap
        }

        return 0
    }

    // MARK: - Credits

    /// The artists a credit names, one by one: "Dua Lipa • Pierre de Maere" is two, as is
    /// "Calvin Harris x Dua Lipa". Split on features and bullets first, then on commas and
    /// ampersands.
    static func artistNames(_ credit: String) -> [String] {
        var seen = Set<String>()
        return featureParts(credit).flatMap(nameParts).filter { seen.insert(fold($0)).inserted }
    }

    /// Every way to read a credit as a name: whole, then its parts, then theirs — so
    /// "Tyler, The Creator feat. X" still yields "Tyler, The Creator" whole.
    static func creditedNames(_ credit: String) -> [String] {
        let features = featureParts(credit)
        return [credit] + features + features.flatMap(nameParts)
    }

    private static func featureParts(_ credit: String) -> [String] {
        split(credit, #"\s*(•|;)\s*|\s+(feat\.?|ft\.?|featuring|with)\s+"#)
    }

    private static func nameParts(_ credit: String) -> [String] {
        split(credit, #"\s*,\s+|\s+(&|x|vs\.?|/)\s+"#)
    }

    private static func split(_ s: String, _ pattern: String) -> [String] {
        s.replacingOccurrences(of: pattern, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Text reduced to its words, lowercased: accents, ligatures and punctuation gone.
    static func plainWords(_ s: String) -> String {
        let folded = fold(s)
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "ß", with: "ss")
        let words = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(words).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Search-URL fallbacks

    /// De-bulleted free-text query for the search-URL fallbacks.
    static func fallbackQuery(title: String, artist: String) -> String {
        // Replacing a separator leaves a run of spaces; collapse the lot rather
        // than a single pair, or the run survives into the URL as %20%20.
        // Slashes are left in place — encodeQuery escapes them, and "AC/DC" is a name.
        let cleanedArtist = artist.replacingOccurrences(of: "•", with: " ")
        return "\(cleanedArtist) \(title)"
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Percent-encode free text for use in a path segment OR a query value.
    /// `.urlQueryAllowed` leaves `&`, `+` and `?` intact, which silently truncates
    /// the query for artists like "Simon & Garfunkel".
    static func encodeQuery(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func spotifySearchUrl(title: String, artist: String) -> String {
        "https://open.spotify.com/search/\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
    }

    /// Spotify's app swallows a universal link to a search page and lands on
    /// "recent searches", so we hand it its own URI scheme instead.
    static func spotifyAppSearchUrl(title: String, artist: String) -> String {
        "spotify:search:\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
    }

    static func youtubeMusicSearchUrl(title: String, artist: String) -> String {
        "https://music.youtube.com/search?q=\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
    }

    static func yandexSearchUrl(title: String, artist: String) -> String {
        "https://music.yandex.com/search?text=\(encodeQuery(fallbackQuery(title: title, artist: artist)))"
    }

    // MARK: - Store URLs

    /// Strip Apple's `uo` analytics parameter so the shared link stays clean.
    static func cleanStoreUrl(_ url: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        let kept = (comps.queryItems ?? []).filter { $0.name != "uo" }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url?.absoluteString ?? url
    }
}
