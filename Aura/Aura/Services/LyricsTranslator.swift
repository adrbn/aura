import Foundation
import NaturalLanguage

/// The lyrics on screen, in the reader's language — a line of translation under each line.
///
/// Written by Google's Gemini with the reader's own free key (`GeminiLyricsTranslator`), and
/// by nothing else. The iPhone's own translators were tried and taken out: Apple's
/// Translation framework goes line by line and word for word ("sotto, sotto" came out as
/// "en bas, en bas", a lover as "vous"), and Apple Intelligence's small model turned
/// "Nothing you can do that can't be done" into its opposite and read Cape Verdean Creole
/// as Portuguese. A translation that wrong is worse than none: it tells the reader the song
/// means something it doesn't. So without a key, the translate button leads to setting one
/// up. A song translated once is kept, so it comes back instantly, offline too.
///
/// Lines are keyed by their text, so a chorus is translated once, and a sheet replaced by
/// another version's keeps whatever lines the two share.
@MainActor @Observable
final class LyricsTranslator {
    static let shared = LyricsTranslator()

    /// Each line of the sheet on screen, translated. An empty translation marks a line that
    /// needs none — already in the reader's language, or the same once translated.
    private(set) var lines: [String: String] = [:]
    /// Whether the sheet on screen is in another language than the reader's.
    private(set) var isAvailable = false
    /// Whether lines are on their way.
    private(set) var isWorking = false
    /// Why the last attempt failed — a refused key, a spent quota, no network — until the
    /// next one starts.
    private(set) var failure: String?

    @ObservationIgnored private var songId: String?
    @ObservationIgnored private var song = LyricsSong(title: nil, artist: nil)
    @ObservationIgnored private var texts: [String] = []
    @ObservationIgnored private var source: Locale.Language?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var memory: [String: [String: String]] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var translatingAsked = false

    /// The version of kept translations. g1: Gemini's. The on-device ones kept before (v1–v4)
    /// are left behind rather than shown again.
    private static let keptVersion = "g1"

    /// The reader's language: the first one the device is set to.
    static var target: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// Whether translating needs a key first.
    var needsKey: Bool { !GeminiLyricsTranslator.isConfigured }

    /// Whether some line on screen has a translation to show.
    var hasTranslation: Bool { lines.values.contains { !$0.isEmpty } }

    /// Whether Gemini can be asked at all. Offline, only the songs translated before can show
    /// a translation — and only they show the button.
    private static var canAsk: Bool {
        !AppSettings.shared.offlineMode && ServerManager.shared.hasNetwork
    }

    // MARK: The sheet on screen

    /// Takes in the sheet on screen: works out its language and brings back what was
    /// translated before. The rest is asked for only when `translating` — the reader tapped
    /// the button for this song. Asking for every song played would spend the reader's
    /// quota on lyrics nobody looked at.
    func show(songId: String?, song: LyricsSong, texts: [String], translating: Bool = false) async {
        // Another version of the same song's sheet carries on with what the reader asked.
        let continuing = songId != nil && songId == self.songId && translatingAsked
        generation += 1
        task?.cancel()
        task = nil
        self.songId = songId
        self.song = song
        self.texts = texts
        translatingAsked = translating || continuing
        lines = [:]
        isAvailable = false
        isWorking = false
        failure = nil
        source = nil

        let target = Self.target
        guard let songId, !texts.isEmpty,
              let source = Self.language(of: texts),
              source.languageCode != target.languageCode
        else { return }

        self.source = source
        lines = cached(songId: songId, target: target)
        isAvailable = Self.canAsk || hasTranslation
        if translatingAsked { translateMissing() }
    }

    /// The sheet on screen again, from the start: a key was added or removed.
    func engineChanged() {
        let songId = songId, song = song, texts = texts, translating = translatingAsked
        Task { await show(songId: songId, song: song, texts: texts, translating: translating) }
    }

    /// Translates the lines not translated yet — the whole song in one request.
    func translateMissing() {
        guard isAvailable, source != nil, let songId, GeminiLyricsTranslator.isConfigured,
              Self.canAsk else { return }
        let target = Self.target
        var seen = Set<String>()
        var missing: [String] = []
        for text in texts where lines[text] == nil && seen.insert(text).inserted {
            guard text.contains(where: \.isLetter) else { continue }
            // A line already in the reader's language — a song switching languages — needs
            // no translation.
            if let source, Self.isWritten(text, in: target, ratherThan: source) {
                lines[text] = ""
            } else {
                missing.append(text)
            }
        }
        guard !missing.isEmpty else { return }
        translatingAsked = true
        isWorking = true
        failure = nil
        let generation = generation
        let song = song
        task?.cancel()
        task = Task { [weak self] in
            do {
                let translated = try await GeminiLyricsTranslator.translate(missing, song: song, to: target)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                for (line, translation) in translated {
                    self.lines[line] = Self.same(translation, line) ? "" : translation
                }
                self.store(self.lines, songId: songId, target: target)
                let left = missing.filter { self.lines[$0] == nil }.count
                if left > 0 { AppLogger.shared.log("🌐 Gemini left \(left) lyric line(s) out") }
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                // The network dropping says nothing about the translation: no message for
                // it in place of the artist.
                if !(error is URLError) { self.failure = error.localizedDescription }
                AppLogger.shared.log("🌐 Gemini couldn't translate the lyrics: \(error.localizedDescription)")
            }
            if let self, generation == self.generation { self.isWorking = false }
        }
    }

    // MARK: Languages

    /// The language most of the sheet is in.
    private static func language(of texts: [String]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Whether a line reads as the reader's language rather than the sheet's. Short lines
    /// ("oh", "yeah") are too little to judge, and are left to the translator.
    private static func isWritten(_ text: String, in target: Locale.Language,
                                  ratherThan source: Locale.Language) -> Bool {
        guard text.split(separator: " ").count >= 3,
              let targetCode = target.languageCode?.identifier,
              let sourceCode = source.languageCode?.identifier
        else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [NLLanguage(targetCode), NLLanguage(sourceCode)]
        recognizer.processString(text)
        let odds = recognizer.languageHypotheses(withMaximum: 2)
        return (odds[NLLanguage(targetCode)] ?? 0) > 0.8
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || a.isEmpty
    }

    // MARK: Keeping

    private static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("LyricsTranslations", isDirectory: true)
    }()

    private static func key(songId: String, target: Locale.Language) -> String {
        let safe = songId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return "\(String(safe))-\(target.minimalIdentifier)-\(keptVersion)"
    }

    private func cached(songId: String, target: Locale.Language) -> [String: String] {
        let key = Self.key(songId: songId, target: target)
        if let known = memory[key] { return known }
        let file = Self.folder.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: file),
              let known = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        memory[key] = known
        return known
    }

    private func store(_ lines: [String: String], songId: String, target: Locale.Language) {
        let key = Self.key(songId: songId, target: target)
        memory[key] = lines
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(lines).write(to: Self.folder.appendingPathComponent("\(key).json"),
                                                  options: .atomic)
        } catch {
            AppLogger.shared.log("🌐 Couldn't keep the lyrics translation: \(error.localizedDescription)")
        }
    }
}

// MARK: - The song

/// The song whose lyrics are translated: who sings it tells the translator a lot about the words.
struct LyricsSong: Sendable {
    let title: String?
    let artist: String?

    /// "The song is "Sodade" by Cesária Évora." — or nothing, when neither is known.
    var sentence: String {
        switch (title?.isEmpty == false ? title : nil, artist?.isEmpty == false ? artist : nil) {
        case let (title?, artist?): return "The song is \"\(title)\" by \(artist)."
        case let (title?, nil): return "The song is \"\(title)\"."
        case let (nil, artist?): return "The song is by \(artist)."
        default: return ""
        }
    }
}

// MARK: - Reading the answer

/// What the translation prompt and its answer share: numbered lines, the reader's language
/// by its English name, and the familiar "you".
enum LyricsLines {
    /// "12. the translation" → (12, "the translation").
    static func parse(_ row: String) -> (Int, String)? {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard let number = Int(digits) else { return nil }
        var rest = trimmed.dropFirst(digits.count)
        guard let mark = rest.first, ".):-".contains(mark) else { return nil }
        rest = rest.dropFirst()
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }

    static func englishName(of language: Locale.Language) -> String? {
        language.languageCode.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0.identifier) }
    }

    /// The familiar "you", where the language has a formal one to avoid — every form of it,
    /// with the one that stands alone. Given "tu" alone, the model wrote "You you you you"
    /// as "Tu tu tu tu" rather than "Toi, toi, toi, toi".
    static let informalYou: [String: String] = [
        "fr": "tu, te, t', toi, ton, ta, tes — a \"you\" standing on its own is \"toi\" — never vous",
        "de": "du, dich, dir, dein — never Sie",
        "es": "tú, te, ti, tu — never usted",
        "it": "tu, te, ti, tuo — never Lei",
        "pt": "tu or você, te, ti — never o senhor",
        "nl": "jij, je, jou, jouw — never u",
    ]
}
