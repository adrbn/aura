import Foundation
import NaturalLanguage
import Translation

/// The lyrics on screen, in the reader's language — a line of translation under each line.
///
/// Made on the device by Apple's Translation framework: no account, no key, nothing sent
/// anywhere, and free for everyone. The first time a pair of languages is used iOS offers to
/// download it; from then on it works offline. A song translated once is kept, so it comes
/// back instantly — a sheet takes about a second the first time, fast enough that nothing
/// needs translating ahead of the song.
///
/// Lines are keyed by their text, so a chorus is translated once, and a sheet replaced by
/// another version's keeps whatever lines the two share.
@MainActor @Observable
final class LyricsTranslator {
    static let shared = LyricsTranslator()

    /// Each line of the sheet on screen, translated. An empty translation marks a line that
    /// needs none — already in the reader's language, or the same once translated.
    private(set) var lines: [String: String] = [:]
    /// Whether the sheet on screen is in a language that can be translated into the reader's.
    private(set) var isAvailable = false
    /// Whether lines are on their way.
    private(set) var isWorking = false
    /// Set when there is something to translate; the view's `.translationTask` then hands a
    /// session to `translate(with:)`, after asking to download the languages if need be.
    var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var songId: String?
    @ObservationIgnored private var texts: [String] = []
    @ObservationIgnored private var source: Locale.Language?
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var memory: [String: [String: String]] = [:]

    /// The reader's language: the first one the device is set to.
    static var target: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    // MARK: The sheet on screen

    /// Takes in the sheet on screen: works out its language, brings back what was translated
    /// before, and — when translation is on — translates the rest.
    func show(songId: String?, texts: [String], translating: Bool) async {
        generation += 1
        let generation = generation
        self.songId = songId
        self.texts = texts
        lines = [:]
        isAvailable = false
        isWorking = false
        pending = []
        source = nil

        let target = Self.target
        guard let songId, !texts.isEmpty,
              let source = Self.language(of: texts),
              source.languageCode != target.languageCode
        else { return }
        let status = await LanguageAvailability().status(from: source, to: target)
        guard generation == self.generation, status != .unsupported else { return }

        self.source = source
        isAvailable = true
        lines = cached(songId: songId, target: target)
        if translating { translateMissing() }
    }

    /// Asks for a session to translate the lines not translated yet.
    func translateMissing() {
        guard isAvailable, let source else { return }
        let target = Self.target
        var seen = Set<String>()
        var missing: [String] = []
        for text in texts where lines[text] == nil && seen.insert(text).inserted {
            guard text.contains(where: \.isLetter) else { continue }
            // A line already in the reader's language — a song switching languages — needs
            // no translation, and a translator fed it as the other language mangles it.
            if Self.isWritten(text, in: target, ratherThan: source) {
                lines[text] = ""
            } else {
                missing.append(text)
            }
        }
        guard !missing.isEmpty else { return }
        pending = missing
        isWorking = true
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Runs in the view's translation task. Lines arrive one by one, so the sheet fills in
    /// from the top rather than all at once after a wait.
    func translate(with session: TranslationSession) async {
        let batch = pending
        pending = []
        let generation = generation
        guard !batch.isEmpty, let songId else {
            isWorking = false
            return
        }
        let requests = batch.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        do {
            for try await response in session.translate(batch: requests) {
                guard generation == self.generation else { return }
                let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                lines[response.sourceText] = Self.same(translated, response.sourceText) ? "" : translated
            }
            store(lines, songId: songId, target: Self.target)
        } catch {
            AppLogger.shared.log("🌐 Lyrics translation failed: \(error.localizedDescription)")
        }
        if generation == self.generation { isWorking = false }
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
        return "\(String(safe))-\(target.minimalIdentifier)"
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
