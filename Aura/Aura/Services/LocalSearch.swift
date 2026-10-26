import Foundation

/// Search over the library held on the phone: the query's operators, typo correction and
/// ranking, with no network and no app state — every function here is a total function of
/// its inputs, so the rules can be checked on their own.
///
/// Operators, all optional:
/// - words must all match, each one as the start of a word ("dua lip")
/// - `"exact phrase"`
/// - `-word` leaves out what matches it
/// - `artist:`, `album:`, `title:`, `genre:` keep a word to one field; `year:2019`, `year:2010-2015`
/// - `OR` (or `|`) between two searches gives either; `AND` is what spaces already mean
enum LocalSearch {

    // MARK: - Query

    enum Field: String, CaseIterable, Sendable { case title, artist, album, genre }

    struct Term: Equatable, Sendable {
        /// nil: any field.
        var field: Field?
        /// Folded words; a phrase is matched as one run of text.
        var words: [String]
        var phrase = false
        var negated = false
    }

    struct Query: Equatable, Sendable {
        /// Either of these; each one's terms must all match.
        var alternatives: [[Term]] = []
        var years: ClosedRange<Int>?
        var isEmpty: Bool { alternatives.allSatisfy(\.isEmpty) && years == nil }
    }

    private static let fieldNames: [String: Field] = [
        "title": .title, "song": .title, "artist": .artist, "by": .artist,
        "album": .album, "genre": .genre,
    ]

    /// Folded, apostrophes dropped: "don't" and "dont" are one word.
    static func fold(_ s: String) -> String { SongQuery.fold(s).replacingOccurrences(of: "'", with: "") }

    /// Words as the index keeps them: folded, split on anything that isn't a letter or digit.
    static func words(_ s: String) -> [String] {
        fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func parse(_ raw: String) -> Query {
        var query = Query()
        var current: [Term] = []
        for token in tokens(raw) {
            if !token.quoted, token.text == "OR" || token.text == "|" {
                if !current.isEmpty { query.alternatives.append(current); current = [] }
                continue
            }
            if !token.quoted, token.text == "AND" || token.text == "&&" { continue }

            var text = token.text
            var term = Term(words: [], phrase: token.quoted)
            if !token.quoted, text.count > 1, text.hasPrefix("-") {
                term.negated = true
                text.removeFirst()
            }
            if let colon = text.firstIndex(of: ":"), !token.quoted || token.fieldBeforeQuote {
                let name = text[..<colon].lowercased()
                let value = String(text[text.index(after: colon)...])
                if name == "year" || name == "annee" || name == "année" {
                    // "year:" or "year:20" while typing is no search for the word "year".
                    if let years = yearRange(value) { query.years = years }
                    continue
                } else if let field = fieldNames[name] {
                    // "album:" with nothing after it yet is no search for the word "album".
                    if value.isEmpty { continue }
                    term.field = field
                    text = value
                }
            }
            term.words = term.phrase ? [fold(text)] : words(text)
            if !term.words.isEmpty, term.words != [""] { current.append(term) }
        }
        if !current.isEmpty { query.alternatives.append(current) }
        if query.alternatives.isEmpty, query.years != nil { query.alternatives = [[]] }
        return query
    }

    private struct Token { var text: String; var quoted: Bool; var fieldBeforeQuote = false }

    /// Splits on spaces, keeping a quoted run whole — `artist:"daft punk"` too.
    private static func tokens(_ raw: String) -> [Token] {
        var out: [Token] = []
        var buffer = ""
        var quoted = false, sawQuote = false
        for ch in raw {
            if ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" {
                if quoted {
                    out.append(Token(text: buffer, quoted: true, fieldBeforeQuote: buffer.contains(":")))
                    buffer = ""; quoted = false
                } else {
                    sawQuote = true; quoted = true
                    // `artist:"…"`: what came before the quote is the field.
                    if !buffer.hasSuffix(":") { if !buffer.isEmpty { out.append(Token(text: buffer, quoted: false)) }; buffer = "" }
                }
            } else if ch.isWhitespace, !quoted {
                if !buffer.isEmpty { out.append(Token(text: buffer, quoted: false)) }
                buffer = ""
            } else {
                buffer.append(ch)
            }
        }
        // An unclosed quote, as while typing one, is still a phrase.
        if !buffer.isEmpty { out.append(Token(text: buffer, quoted: quoted && sawQuote, fieldBeforeQuote: buffer.contains(":"))) }
        return out
    }

    private static func yearRange(_ s: String) -> ClosedRange<Int>? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first, (1000...2999).contains(first) else { return nil }
        let last = parts.count > 1 ? parts[1] : first
        return min(first, last)...max(first, last)
    }

    // MARK: - Documents

    struct Doc: Sendable {
        var fields: [Field: [String]] = [:]
        var text: [Field: String] = [:]
        var year: Int?
        /// Plays, as a tie-breaker.
        var popularity: Int

        init(title: String? = nil, artist: String? = nil, album: String? = nil,
             genre: String? = nil, year: Int? = nil, popularity: Int = 0) {
            for (field, value) in [(Field.title, title), (.artist, artist), (.album, album), (.genre, genre)] {
                guard let value, !value.isEmpty else { continue }
                fields[field] = LocalSearch.words(value)
                text[field] = LocalSearch.fold(value)
            }
            self.year = year
            self.popularity = popularity
        }
    }

    /// Every word in the library and how often it appears: what a typo is corrected to.
    struct Vocabulary: Sendable {
        let counts: [String: Int]
        /// Sorted, for prefix lookups.
        let sorted: [String]
        /// Each word as characters, split once rather than on every keystroke.
        private let spelled: [(word: String, chars: [Character], count: Int)]

        init(_ docs: [Doc]) {
            var counts: [String: Int] = [:]
            for doc in docs { for words in doc.fields.values { for w in words { counts[w, default: 0] += 1 } } }
            self.counts = counts
            sorted = counts.keys.sorted()
            spelled = counts.map { ($0.key, Array($0.key), $0.value) }
        }

        func hasWord(startingWith prefix: String) -> Bool {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
            }
            return lo < sorted.count && sorted[lo].hasPrefix(prefix)
        }

        /// The library word a typed one most likely meant, or nil when it already starts a
        /// word, is too short to judge, or nothing is close enough.
        func correction(for word: String) -> String? {
            guard word.count >= 4, !hasWord(startingWith: word), Int(word) == nil else { return nil }
            // "avvici" is two edits from "avicii": a name typed by ear needs both.
            let allowed = word.count >= 6 ? 2 : 1
            let typed = Array(word)
            var best: (word: String, distance: Int, count: Int)?
            for (candidate, c, count) in spelled {
                guard c.count + allowed >= typed.count else { continue }
                // Against the whole word, and against its start: "avicci" is still being
                // typed toward "avicii".
                var d = LocalSearch.distance(typed, c, limit: allowed)
                if c.count > typed.count {
                    d = min(d, LocalSearch.distance(typed, Array(c.prefix(typed.count)), limit: allowed))
                }
                guard d <= allowed else { continue }
                if best == nil || d < best!.distance || (d == best!.distance && count > best!.count) {
                    best = (candidate, d, count)
                }
            }
            return best?.word
        }
    }

    /// Edit distance counting a swap of neighbours as one edit; anything above `limit`
    /// comes back as `limit + 1`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    curr[j] = min(curr[j], prev2[j - 2] + 1)
                }
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, curr) = (prev, curr, prev2)
        }
        return min(prev[b.count], limit + 1)
    }

    // MARK: - Correction

    /// The query with each word that matches nothing replaced by the library word it most
    /// likely meant. Phrases and field names are left as typed.
    static func corrected(_ query: Query, vocabulary: Vocabulary) -> (query: Query, changes: [String: String]) {
        var changes: [String: String] = [:]
        var out = query
        for a in out.alternatives.indices {
            for t in out.alternatives[a].indices where !out.alternatives[a][t].phrase {
                out.alternatives[a][t].words = out.alternatives[a][t].words.map { word in
                    guard let fix = vocabulary.correction(for: word) else { return word }
                    changes[word] = fix
                    return fix
                }
            }
        }
        return (out, changes)
    }

    /// The typed text with corrected words swapped in, for "Did you mean".
    static func rewrite(_ raw: String, changes: [String: String]) -> String {
        raw.split(separator: " ", omittingEmptySubsequences: false).map { piece -> String in
            let s = String(piece)
            for (typo, fix) in changes {
                guard let range = s.range(of: typo, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                return s.replacingCharacters(in: range, with: fix)
            }
            return s
        }.joined(separator: " ")
    }

    // MARK: - Matching

    /// How much a hit in each field counts toward the order.
    private static let weight: [Field: Double] = [.title: 3, .artist: 2, .album: 1.5, .genre: 0.5]

    /// The doc's score for one term, or nil when the term doesn't match it.
    private static func score(_ term: Term, _ doc: Doc) -> Double? {
        let fields = term.field.map { [$0] } ?? Field.allCases
        var best: Double?
        for field in fields {
            guard let words = doc.fields[field] else { continue }
            var s: Double
            if term.phrase {
                guard let text = doc.text[field], text.contains(term.words[0]) else { continue }
                s = weight[field]! * 1.5
            } else {
                s = 0
                var all = true
                for w in term.words {
                    if words.contains(w) { s += weight[field]! * 1.2 }
                    else if words.contains(where: { $0.hasPrefix(w) }) { s += weight[field]! }
                    else { all = false; break }
                }
                guard all else { continue }
            }
            best = max(best ?? 0, s)
        }
        // Words spread over fields ("daft one more time"): each word on its own, anywhere.
        if best == nil, term.field == nil, !term.phrase, term.words.count > 1 {
            var total = 0.0
            for w in term.words {
                guard let s = score(Term(words: [w]), doc) else { return nil }
                total += s
            }
            return total * 0.8
        }
        return best
    }

    /// The doc's score for the whole query, or nil when it isn't a result.
    static func score(_ query: Query, _ doc: Doc) -> Double? {
        if let years = query.years {
            guard let year = doc.year, years.contains(year) else { return nil }
        }
        var best: Double?
        for terms in query.alternatives {
            var total = 0.0
            var matched = true
            for term in terms {
                let s = score(term, doc)
                if term.negated { if s != nil { matched = false; break } }
                else if let s { total += s } else { matched = false; break }
            }
            if matched { best = max(best ?? 0, total) }
        }
        guard var s = best else { return nil }
        // A title typed in full beats one that only starts with it.
        let typed = query.alternatives.first?.filter { !$0.negated }.flatMap(\.words) ?? []
        if let title = doc.fields[.title], title == typed { s += 5 }
        return s + log(Double(doc.popularity) + 1) * 0.3
    }

    /// Indices of the docs that answer the query, best first.
    static func search(_ query: Query, in docs: [Doc], limit: Int) -> [Int] {
        guard !query.isEmpty else { return [] }
        var hits: [(Int, Double)] = []
        for (i, doc) in docs.enumerated() {
            if let s = score(query, doc) { hits.append((i, s)) }
        }
        return hits.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }
}
