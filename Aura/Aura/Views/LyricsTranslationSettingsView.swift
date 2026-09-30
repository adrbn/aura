import SwiftUI

/// Lyrics translation: the reader's own Gemini key, set up in a minute, then checked.
///
/// Gemini is the only translator. Without a key nothing is translated, so this screen is
/// mostly a setup: what it gives, three steps to a free key, a field that takes a paste.
struct LyricsTranslationSettingsView: View {
    private enum Check: Equatable {
        case idle, checking, works
        case failed(String)
    }

    @State private var key = ""
    @State private var hasKey = GeminiLyricsTranslator.isConfigured
    @State private var check: Check = .idle
    @Environment(\.appAccentColor) private var accentColor

    private static let keyPage = URL(string: "https://aistudio.google.com/apikey")!

    /// "French": the language translations are written in, the iPhone's own.
    private var targetName: String {
        let target = LyricsTranslator.target
        return target.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }?
            .localizedCapitalized ?? target.minimalIdentifier
    }

    var body: some View {
        Form {
            Section {
                header
            }
            .listRowBackground(Color.clear)

            if hasKey {
                keySection
            } else {
                setupSection
            }

            Section {
                LabeledContent("Translated Into", value: targetName)
            } footer: {
                Text("Your iPhone's language. Songs already in it aren't translated.")
            }

            Section {
                Label("Only the lyrics you translate go to Google, with the song's title and artist.",
                      systemImage: "text.quote")
                Label("A song translated once is kept on this iPhone, and comes back offline.",
                      systemImage: "arrow.down.circle")
                Label("The key stays in this iPhone's Keychain.", systemImage: "key")
            } header: {
                Text("Privacy")
            } footer: {
                Text("On Google's free tier, what you send may be used to improve Google's products.")
            }
        }
        .endsAboveBottomChrome()
        .navigationTitle("Lyrics Translation")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: What it is

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "translate")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(accentColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Every Line, Understood")
                .font(.title3.weight(.semibold))
            Text("Gemini reads the whole song before translating it, so the meaning comes through: idioms, double negatives, slang and creoles. Each translation sits under its sung line.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: No key yet

    private var setupSection: some View {
        Section {
            step(1) {
                Link(destination: Self.keyPage) {
                    HStack {
                        Text("Open Google AI Studio")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            step(2) {
                Text("Sign in, tap **Create API key**, then copy it.")
            }
            step(3) {
                HStack(spacing: 10) {
                    SecureField("Paste the key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    // Pastes without the system's "Allow Paste" prompt, and saves at once.
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first else { return }
                        Task { @MainActor in
                            key = pasted
                            save()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
            }
            Button("Save the Key", action: save)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Set Up — Free, About a Minute")
        } footer: {
            Text("A Google account is all it takes: no card, no subscription.")
        }
    }

    /// A numbered step of the setup.
    private func step<Content: View>(_ number: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(accentColor)
                .frame(width: 22, height: 22)
                .background(accentColor.opacity(0.15), in: Circle())
            content()
        }
    }

    // MARK: With a key

    private var keySection: some View {
        Section {
            checkRow
            Button("Check the Key") { Task { await runCheck() } }
                .disabled(check == .checking)
            Button("Remove the Key", role: .destructive) {
                GeminiLyricsTranslator.removeKey()
                hasKey = false
                check = .idle
            }
        } header: {
            Text("Gemini")
        } footer: {
            Text("Tap the translate button above the lyrics to show or hide the translation.")
        }
    }

    @ViewBuilder
    private var checkRow: some View {
        switch check {
        case .idle:
            Label("Key saved", systemImage: "key.fill")
        case .checking:
            HStack {
                Text("Checking…")
                Spacer()
                ProgressView()
            }
        case .works:
            Label("Ready: lyrics will be translated", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GeminiLyricsTranslator.save(key: trimmed)
        key = ""
        hasKey = GeminiLyricsTranslator.isConfigured
        Task { await runCheck() }
    }

    private func runCheck() async {
        check = .checking
        do {
            try await GeminiLyricsTranslator.check()
            check = .works
        } catch {
            check = .failed(error.localizedDescription)
        }
    }
}
