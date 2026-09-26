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
@MainActor
enum GeminiLyricsTranslator {
    private static let keyAccount = "gemini-api-key"
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    /// Google's alias for its newest Flash model, so a retired model never breaks it.
    private static let model = "gemini-flash-latest"
    /// Thinking a little is what gets the tricky lines right; more only adds seconds.
    private static let reasoningEffort = "low"
    private static let timeout: TimeInterval = 60

    enum Failure: LocalizedError {
        case refusedKey
        case quota
        case server(Int, String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .refusedKey: return String(localized: "Google refused the key.")
            case .quota: return String(localized: "The key's free quota is spent for now.")
            case .server(let status, let message): return "Google answered \(status): \(message)"
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

    /// Each line with its translation. Lines Gemini leaves out are simply missing.
    static func translate(_ lines: [String], song: LyricsSong,
                          to target: Locale.Language) async throws -> [String: String] {
        guard let key = apiKey else { throw Failure.refusedKey }
        let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": model,
            "reasoning_effort": reasoningEffort,
            "messages": [
                ["role": "system", "content": instructions(to: target, song: song)],
                ["role": "user", "content": numbered],
            ],
        ]
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

        var translated: [String: String] = [:]
        for row in text.components(separatedBy: .newlines) {
            guard let (number, line) = SongTranslationModel.parse(row), lines.indices.contains(number - 1),
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
        if status == 429 { return .quota }
        return .server(status, message)
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
        let into = SongTranslationModel.englishName(of: target) ?? "the reader's language"
        let informal = target.languageCode.flatMap { SongTranslationModel.informalYou[$0.identifier] }
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
