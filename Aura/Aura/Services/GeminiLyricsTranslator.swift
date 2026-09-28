import Foundation

/// Lyrics translated by Google's Gemini, with the reader's own free API key.
///
/// The models on the iPhone are small: Apple Intelligence's turned "Nothing you can do that
/// can't be done" into its opposite, and read Cape Verdean Creole as Portuguese. A large
/// model reads a song the way a person does — double negatives, idioms, creoles and all.
///
/// The whole song goes in one request, so every line is read knowing the rest. A sentence
/// running over several lines is translated as a sentence, then cut back at the points
/// where the lines break, each line carrying its own part — that's what keeps a translation
/// under the line being sung.
///
/// Off until a key is added in Settings → Lyrics Translation. Then the lines being
/// translated go to Google, with the song's title and artist, and nothing else.
///
/// Google's free tier gives each model its own daily allowance, and Flash's is small — a
/// couple of dozen songs. So the models are tried in turn: when one's allowance is spent,
/// the next carries on, and the spent one is left alone until Google resets it.
@MainActor
enum GeminiLyricsTranslator {
    private static let keyAccount = "gemini-api-key"
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    private static let timeout: TimeInterval = 60

    /// A model, and what it accepts.
    private struct Model {
        let id: String
        /// Thinking a little is what gets the tricky lines right; more only adds seconds.
        let thinks: Bool
        /// Gemma takes no system instructions: they go at the top of the request instead.
        let takesInstructions: Bool
    }

    /// Best first. Google's aliases follow its newest Flash models, so a retired one never
    /// breaks the chain; Gemma's free allowance runs to thousands of songs a day.
    private static let models = [
        Model(id: "gemini-flash-latest", thinks: true, takesInstructions: true),
        Model(id: "gemini-flash-lite-latest", thinks: false, takesInstructions: true),
        Model(id: "gemma-3-27b-it", thinks: false, takesInstructions: false),
    ]

    /// When each spent model can be asked again.
    private static var spentUntil: [String: Date] = [:]

    enum Failure: LocalizedError {
        case refusedKey
        /// Every model's allowance is spent; the first comes back at this time.
        case quota(until: Date?)
        /// Every model was overloaded — Google's 503, "This model is currently experiencing
        /// high demand" — even after a second try.
        case busy
        case server(Int, String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .refusedKey: return String(localized: "Google refused the key.")
            case .quota(let until?):
                return String(localized: "Gemini's free quota is spent until \(until.formatted(date: .omitted, time: .shortened)).")
            case .quota(nil): return String(localized: "Gemini's free quota is spent for now.")
            case .busy: return String(localized: "Google is busy. Tap to try again.")
            // Google's own message is for the log: in place of the artist it was a line of
            // jargon cut off halfway.
            case .server(let status, _): return String(localized: "Google couldn't translate this song (\(status)).")
            case .unreadable: return String(localized: "Google's answer couldn't be read.")
            }
        }
    }

    // MARK: The key

    private static var loadedKey: String??

    /// The key, read from the Keychain once.
    static var apiKey: String? {
        if let loadedKey { return loadedKey }
        let key = KeychainHelper.loadPassword(for: keyAccount).flatMap { $0.isEmpty ? nil : $0 }
        loadedKey = .some(key)
        return key
    }

    static var isConfigured: Bool { apiKey != nil }

    static func save(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainHelper.save(password: trimmed, for: keyAccount)
        loadedKey = .some(trimmed)
        LyricsTranslator.shared.engineChanged()
    }

    static func removeKey() {
        KeychainHelper.delete(for: keyAccount)
        loadedKey = .some(nil)
        LyricsTranslator.shared.engineChanged()
    }

    /// A one-line request, to tell the reader at once whether the key works.
    static func check() async throws {
        _ = try await translate(["Nothing you can do that can't be done"],
                                song: LyricsSong(title: "All You Need Is Love", artist: "The Beatles"),
                                to: LyricsTranslator.target)
    }

    // MARK: Translating

    /// How long to wait before asking overloaded models once more.
    private static let busyPause: Duration = .seconds(4)

    /// Each line with its translation. Lines Gemini leaves out are simply missing.
    static func translate(_ lines: [String], song: LyricsSong,
                          to target: Locale.Language) async throws -> [String: String] {
        guard let key = apiKey else { throw Failure.refusedKey }
        let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let rules = instructions(to: target, song: song)
        // An overloaded model is passed over for the next; when every one is, they're all
        // asked once more after a pause — Google's overloads are over in seconds, and a
        // refused request costs no quota.
        for attempt in 0..<2 {
            if attempt > 0 { try await Task.sleep(for: busyPause) }
            var lastFailure: Failure?
            var sawBusy = false
            for model in models where (spentUntil[model.id] ?? .distantPast) <= Date() {
                do {
                    let text = try await ask(model, rules: rules, lines: numbered, key: key)
                    return parse(text, lines: lines)
                } catch let failure as Failure {
                    switch failure {
                    case .quota(let until):
                        spentUntil[model.id] = until
                        AppLogger.shared.log("🌐 \(model.id)'s free quota is spent — trying the next model")
                    case .busy:
                        sawBusy = true
                        AppLogger.shared.log("🌐 \(model.id) is overloaded — trying the next model")
                    case .server(let status, let message) where status == 404 || status == 400:
                        // Retired, or not offered to this key: the next model may be.
                        AppLogger.shared.log("🌐 \(model.id) unavailable (\(status)): \(message) — trying the next model")
                    case .server(let status, let message):
                        AppLogger.shared.log("🌐 \(model.id) answered \(status): \(message)")
                        throw failure
                    default:
                        throw failure
                    }
                    lastFailure = failure
                }
            }
            if sawBusy { continue }
            if case .server = lastFailure { throw lastFailure! }
            throw Failure.quota(until: spentUntil.values.filter { $0 > Date() }.min())
        }
        throw Failure.busy
    }

    /// One request to one model; its answer's text.
    private static func ask(_ model: Model, rules: String, lines: String, key: String) async throws -> String {
        var body: [String: Any] = [
            "model": model.id,
            "messages": model.takesInstructions
                ? [["role": "system", "content": rules], ["role": "user", "content": lines]]
                : [["role": "user", "content": rules + "\n\nThe lines:\n" + lines]],
        ]
        if model.thinks { body["reasoning_effort"] = "low" }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, data: data) }
        guard let answer = try? JSONDecoder().decode(ChatAnswer.self, from: data),
              let text = answer.choices.first?.message.content, !text.isEmpty
        else { throw Failure.unreadable }
        return text
    }

    /// The numbered answer, back on the lines it translates.
    private static func parse(_ text: String, lines: [String]) -> [String: String] {
        var translated: [String: String] = [:]
        for row in text.components(separatedBy: .newlines) {
            guard let (number, line) = LyricsLines.parse(row), lines.indices.contains(number - 1),
                  translated[lines[number - 1]] == nil else { continue }
            translated[lines[number - 1]] = line
        }
        return translated
    }

    private struct ChatAnswer: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    /// What went wrong, from the status and Google's own message — never the key.
    private static func failure(status: Int, data: Data) -> Failure {
        let message = errorMessage(in: data)
        if status == 401 || status == 403 || (status == 400 && message.localizedCaseInsensitiveContains("API key")) {
            return .refusedKey
        }
        if status == 429 { return .quota(until: resumption(after: data)) }
        if (500..<600).contains(status) { return .busy }
        return .server(status, message)
    }

    /// When a spent model can be asked again. A daily allowance comes back at midnight in
    /// California, where Google counts days; a per-minute one after the wait Google names.
    private static func resumption(after data: Data) -> Date {
        let body = String(decoding: data, as: UTF8.self)
        if body.contains("PerDay") {
            var pacific = Calendar(identifier: .gregorian)
            pacific.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
            let today = pacific.startOfDay(for: Date())
            return pacific.date(byAdding: .day, value: 1, to: today) ?? Date().addingTimeInterval(3600)
        }
        let wait = body.range(of: #"retry in ([0-9.]+)s"#, options: .regularExpression)
            .flatMap { Double(body[$0].dropFirst("retry in ".count).dropLast()) }
        return Date().addingTimeInterval(min(max(wait ?? 60, 5), 3600))
    }

    /// Google answers `{"error": {"message": …}}`, sometimes wrapped in an array.
    private static func errorMessage(in data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        if let error = object?["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    private static func instructions(to target: Locale.Language, song: LyricsSong) -> String {
        let into = LyricsLines.englishName(of: target) ?? "the reader's language"
        let informal = target.languageCode.flatMap { LyricsLines.informalYou[$0.identifier] }
            .map { " Address the listener in the familiar form — \($0) — with each word in the form its place in the sentence calls for." } ?? ""
        let context = song.sentence.isEmpty ? "" : " \(song.sentence)"
        return """
        You translate song lyrics into \(into) for subtitles shown under each sung line.\(context)
        First read the whole song and work out which language it is really in. It may be a \
        creole or a regional language that looks like a major one — Cape Verdean Creole looks \
        like Portuguese, but its words often mean something else — so read every word in the \
        song's own language.
        Translate the meaning, the feeling and the tone, the way a native \(into) speaker would \
        say it, never word for word. Get negations, double negatives and questions exactly \
        right. Render an idiom by the \(into) expression that means the same. Keep the singer's \
        register: casual stays casual.\(informal)
        A sentence often runs over several lines. Translate it as a sentence, then cut your \
        translation back at the same breaks, so each line carries the part of the meaning sung \
        on it, in natural \(into) order. Lines that repeat get the same translation. Leave names, \
        and lines already in \(into), as they are.
        Each line you are given starts with its number. Answer with exactly one line for each, \
        starting with the same number, a full stop and a space, then its translation. Write \
        nothing else: no notes, no quotes, no title.
        """
    }
}
