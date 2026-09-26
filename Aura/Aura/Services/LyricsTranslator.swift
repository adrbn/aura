import Foundation
import FoundationModels
import NaturalLanguage
import Translation

/// The lyrics on screen, in the reader's language — a line of translation under each line.
///
/// With the reader's own Gemini key, Google's large model writes it
/// (`GeminiLyricsTranslator`): the small models on the iPhone get the words but miss the
/// meaning, "Nothing you can do that can't be done" coming out as its opposite. Without a
/// key, or when Google fails, it's made on the device: no account, nothing sent anywhere.
/// Where Apple Intelligence is on, its language model writes it (`SongTranslationModel`),
/// reading the song as a whole, as a subtitler would. Elsewhere, and for any line the model
/// leaves out, Apple's Translation framework does — line by line and word for word, which
/// is what made "sotto, sotto" come out as "en bas, en bas" rather than "au fond", and a
/// lover "vous". The first time a pair of languages goes through it iOS offers to download
/// them; from then on it works offline. A song translated once is kept, so it comes back
/// instantly.
///
/// Lines are keyed by their text, so a chorus is translated once, and a sheet replaced by
/// another version's keeps whatever lines the two share.
///
/// The language is first guessed by the system's recognizer, which only knows the major
/// languages: Cesária Évora's Cape Verdean Creole reads to it as Portuguese, and translated
/// as Portuguese "ta ba panha'l" came out as a banana. So the model is asked which language
/// the song is really in, knowing who sings it, and translates from that.
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
    @ObservationIgnored private var song = LyricsSong(title: nil, artist: nil)
    @ObservationIgnored private var texts: [String] = []
    @ObservationIgnored private var source: Locale.Language?
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var memory: [String: [String: String]] = [:]
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var translatingAsked = false

    /// Who made a kept translation. Each keeps its own copy, so adding a Gemini key has every
    /// song translated afresh rather than showing the small model's lines again.
    private enum Engine: String {
        case gemini = "g1"
        // v4: the on-device model knowing the song and its real language. The ones kept
        // before — word for word, from its first instructions, or read as the wrong
        // language — are left behind rather than shown again.
        case device = "v4"
    }

    private static var engine: Engine { GeminiLyricsTranslator.isConfigured ? .gemini : .device }

    /// The reader's language: the first one the device is set to.
    static var target: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    // MARK: The sheet on screen

    /// Takes in the sheet on screen: works out its language, brings back what was translated
    /// before, and — when translation is on — translates the rest.
    func show(songId: String?, song: LyricsSong, texts: [String], translating: Bool) async {
        generation += 1
        let generation = generation
        modelTask?.cancel()
        modelTask = nil
        self.songId = songId
        self.song = song
        self.texts = texts
        translatingAsked = translating
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
        guard generation == self.generation,
              GeminiLyricsTranslator.isConfigured || status != .unsupported
                || SongTranslationModel.canTranslate(from: source, to: target)
        else { return }

        self.source = source
        isAvailable = true
        lines = cached(songId: songId, target: target, engine: Self.engine)
        if translating { translateMissing() }
    }

    /// The sheet on screen again, from the start: a Gemini key was added or removed.
    func engineChanged() {
        let songId = songId, song = song, texts = texts, translating = translatingAsked
        Task { await show(songId: songId, song: song, texts: texts, translating: translating) }
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
        translatingAsked = true
        isWorking = true
        if GeminiLyricsTranslator.isConfigured {
            let generation = generation
            let song = song
            modelTask?.cancel()
            modelTask = Task { [weak self] in
                await self?.translateWithGemini(missing, from: source, to: target, song: song, generation: generation)
            }
        } else {
            translateOnDevice(missing, from: source, to: target)
        }
    }

    /// The small models on the iPhone: Apple Intelligence's where it can, else the
    /// Translation framework line by line.
    private func translateOnDevice(_ missing: [String], from source: Locale.Language, to target: Locale.Language) {
        if SongTranslationModel.canTranslate(from: source, to: target) {
            let generation = generation
            modelTask?.cancel()
            let song = song
            let sample = texts
            modelTask = Task { [weak self] in
                // Which language it really is, before a line is translated: a creole read as
                // its neighbour gets that neighbour's meanings.
                let variety = await SongTranslationModel.variety(of: sample, looksLike: source, song: song)
                await self?.translateWithModel(missing, from: source, variety: variety, to: target,
                                               song: song, generation: generation)
            }
        } else {
            translateLineByLine(missing)
        }
    }

    /// Hands lines to the Translation framework, through the view's `.translationTask`.
    private func translateLineByLine(_ missing: [String]) {
        guard let source else { return }
        let target = Self.target
        pending = missing
        isWorking = true
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// The whole song through Gemini in one go. If Google can't — no network, a refused key,
    /// the day's quota spent — the iPhone's own models take over for this time.
    private func translateWithGemini(_ missing: [String], from source: Locale.Language, to target: Locale.Language,
                                     song: LyricsSong, generation: Int) async {
        guard let songId else { return }
        do {
            let translated = try await GeminiLyricsTranslator.translate(missing, song: song, to: target)
            guard generation == self.generation, !Task.isCancelled else { return }
            for (line, translation) in translated {
                lines[line] = Self.same(translation, line) ? "" : translation
            }
            store(lines, songId: songId, target: target, engine: .gemini)
            let left = missing.filter { lines[$0] == nil }
            if left.isEmpty {
                isWorking = false
            } else {
                AppLogger.shared.log("🌐 Gemini left \(left.count) lyric line(s) out; the iPhone translates them")
                translateOnDevice(left, from: source, to: target)
            }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            AppLogger.shared.log("🌐 Gemini couldn't translate the lyrics (\(error.localizedDescription)); the iPhone does")
            translateOnDevice(missing, from: source, to: target)
        }
    }

    /// The song through the language model, a stretch at a time, each line shown as soon as
    /// it's written. Whatever it leaves out goes line by line to the Translation framework.
    private func translateWithModel(_ missing: [String], from source: Locale.Language, variety: String?,
                                    to target: Locale.Language, song: LyricsSong, generation: Int) async {
        guard let songId, generation == self.generation, !Task.isCancelled else { return }
        var left: [String] = []
        for stretch in SongTranslationModel.stretches(of: missing) {
            await SongTranslationModel.translate(stretch, from: source, variety: variety, to: target,
                                                 song: song) { line, translated in
                guard generation == self.generation else { return }
                self.lines[line] = Self.same(translated, line) ? "" : translated
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            left += stretch.filter { lines[$0] == nil }
        }
        store(lines, songId: songId, target: target, engine: .device)
        if left.isEmpty {
            isWorking = false
        } else if let variety {
            // The Translation framework would read them as the language they look like —
            // the very mistake the model was steered away from. Better untranslated.
            AppLogger.shared.log("🌐 \(left.count) line(s) in \(variety) left untranslated")
            isWorking = false
        } else {
            AppLogger.shared.log("🌐 \(left.count) lyric line(s) left to the line-by-line translator")
            translateLineByLine(left)
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
            store(lines, songId: songId, target: Self.target, engine: .device)
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

    private static func key(songId: String, target: Locale.Language, engine: Engine) -> String {
        let safe = songId.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return "\(String(safe))-\(target.minimalIdentifier)-\(engine.rawValue)"
    }

    private func cached(songId: String, target: Locale.Language, engine: Engine) -> [String: String] {
        let key = Self.key(songId: songId, target: target, engine: engine)
        if let known = memory[key] { return known }
        let file = Self.folder.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: file),
              let known = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        memory[key] = known
        return known
    }

    private func store(_ lines: [String: String], songId: String, target: Locale.Language, engine: Engine) {
        let key = Self.key(songId: songId, target: target, engine: engine)
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

// MARK: - The language model

/// The song whose lyrics are translated: who sings it tells the model a lot about the words.
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

/// Lyrics put into another language by Apple Intelligence's on-device language model.
///
/// It reads a stretch of the song at once, so a line is translated knowing the ones around
/// it, and is asked for what a native speaker would say — idioms by their sense, the
/// singer's register kept — rather than the words one by one. It runs on the device like
/// the Translation framework: nothing is sent anywhere, and no language needs downloading.
///
/// The guardrails are the ones Apple provides for transforming text a person brought, so a
/// song's rough words are translated rather than refused. Plain text rather than guided
/// generation: those guardrails apply to text only. Each line goes in numbered and comes back
/// under its number, which is what ties a translation to its line.
@MainActor
enum SongTranslationModel {
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    /// A stretch small enough that it, its translation and the instructions sit well inside
    /// the model's context.
    private static let stretchCharacters = 1_200
    private static let stretchLines = 36
    private static var loggedUnavailable = false

    static func canTranslate(from source: Locale.Language, to target: Locale.Language) -> Bool {
        guard case .available = model.availability else {
            if !loggedUnavailable, case .unavailable(let reason) = model.availability {
                loggedUnavailable = true
                AppLogger.shared.log("🌐 Apple Intelligence can't translate lyrics here: \(reason)")
            }
            return false
        }
        let spoken = Set(model.supportedLanguages.compactMap(\.languageCode))
        return [source, target].allSatisfy { $0.languageCode.map(spoken.contains) ?? false }
    }

    /// The lines in stretches the model can take at once, in the song's order.
    static func stretches(of lines: [String]) -> [[String]] {
        var stretches: [[String]] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if !current.isEmpty, size + line.count > stretchCharacters || current.count >= stretchLines {
                stretches.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.count
        }
        if !current.isEmpty { stretches.append(current) }
        return stretches
    }

    /// The language the lyrics are really in, when it isn't the one they look like — a creole
    /// or a regional language the recognizer takes for its neighbour. Nil when the model
    /// agrees with the recognizer, or can't say.
    static func variety(of texts: [String], looksLike source: Locale.Language, song: LyricsSong) async -> String? {
        guard let looksLike = englishName(of: source) else { return nil }
        var seen = Set<String>()
        let sample = texts.filter { $0.contains(where: \.isLetter) && seen.insert($0).inserted }.prefix(16)
        guard !sample.isEmpty else { return nil }
        // No languages named as examples: a small model given "such as X" answers X.
        let session = LanguageModelSession(model: model, instructions: """
        You name the language song lyrics are written in. Answer with the language's English \
        name and nothing else. For a creole or a regional language, give that language's own \
        name, not the name of the major language it resembles.
        """)
        let prompt = [song.sentence, sample.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n\n")
        do {
            let answer = try await session.respond(
                to: prompt, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)).content
            let named = languageName(in: answer)
            guard !named.isEmpty, named.count <= 40, named.contains(where: \.isLetter) else { return nil }
            let lowered = named.lowercased()
            let isOwnLanguage = ["creole", "kriol", "dialect", "pidgin", "patois"].contains { lowered.contains($0) }
            guard isOwnLanguage || !lowered.contains(looksLike.lowercased()) else { return nil }
            AppLogger.shared.log("🌐 The lyrics look \(looksLike) but are in \(named)")
            return named
        } catch {
            AppLogger.shared.log("🌐 The language model couldn't name the lyrics' language: \(error.localizedDescription)")
            return nil
        }
    }

    /// "The lyrics are in Cape Verdean Creole." → "Cape Verdean Creole": asked for a bare name,
    /// a small model still sometimes answers in a sentence.
    private static func languageName(in answer: String) -> String {
        var line = answer.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if let colon = line.lastIndex(of: ":") { line = String(line[line.index(after: colon)...]) }
        for lead in [" are in ", " is in ", " is "] {
            if let range = line.range(of: lead, options: [.caseInsensitive, .backwards]) {
                line = String(line[range.upperBound...])
                break
            }
        }
        line = line.replacingOccurrences(of: #"\s*\([^)]*\)?"#, with: "", options: .regularExpression)
        return line.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static func englishName(of language: Locale.Language) -> String? {
        language.languageCode.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0.identifier) }
    }

    /// Translates a stretch, handing over each line as soon as its translation is complete.
    static func translate(_ lines: [String], from source: Locale.Language, variety: String?,
                          to target: Locale.Language, song: LyricsSong,
                          onLine: (String, String) -> Void) async {
        let session = LanguageModelSession(
            model: model, instructions: instructions(from: source, variety: variety, to: target, song: song))
        let prompt = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        var handed = Set<Int>()
        // A row is complete once the next has begun; the last, once the answer ends.
        func take(_ text: String, isFinal: Bool) {
            var rows = text.components(separatedBy: "\n")
            if !isFinal { rows.removeLast() }
            for row in rows {
                guard let (number, translated) = parse(row), lines.indices.contains(number - 1),
                      handed.insert(number).inserted else { continue }
                onLine(lines[number - 1], translated)
            }
        }
        var answer = ""
        do {
            let stream = session.streamResponse(to: prompt, options: GenerationOptions(samplingMode: .greedy))
            for try await snapshot in stream {
                if Task.isCancelled { return }
                answer = snapshot.content
                take(answer, isFinal: false)
            }
            take(answer, isFinal: true)
        } catch {
            // What came before the failure is kept; the rest goes line by line.
            take(answer, isFinal: false)
            AppLogger.shared.log("🌐 The language model couldn't translate a stretch: \(error.localizedDescription)")
        }
    }

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

    private static func instructions(from source: Locale.Language, variety: String?,
                                     to target: Locale.Language, song: LyricsSong) -> String {
        let looksLike = englishName(of: source)
        let from = variety ?? looksLike ?? "the original"
        let into = englishName(of: target) ?? "the reader's language"
        let context = song.sentence.isEmpty ? "" : " \(song.sentence)"
        // Words a creole shares in spelling with its neighbour rarely share their meaning:
        // "sabe" is "knows" in Portuguese and "sweet" in Cape Verdean Creole.
        let falseFriends = variety.flatMap { variety in
            looksLike.map { " The lyrics are in \(variety), not \($0): a word spelt as in \($0) often means something else in \(variety), so read every word as \(variety)." }
        } ?? ""
        let informal = target.languageCode.flatMap { informalYou[$0.identifier] }
            .map { " In \(into), address the listener in the familiar form — \($0) — with each word in the form its place in the sentence calls for." } ?? ""
        return """
        You translate song lyrics from \(from) into \(into), the way a good subtitler would.\(context)\(falseFriends) \
        Write what a native \(into) speaker would actually say: carry the meaning, the feeling \
        and the tone, never word for word. Render an idiom by the \(into) expression that means \
        the same thing. Keep the singer's register: casual lyrics stay casual.\(informal) \
        Read the lines together, since one line often finishes the sentence of the line before. \
        Leave names, and words already in \(into), as they are.
        Each line you are given starts with its number. Answer with exactly one line for each, \
        starting with the same number, a full stop and a space, then its translation. \
        Write nothing else: no notes, no quotes, no title.
        """
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
