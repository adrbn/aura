import SwiftUI

/// Which engine translates lyrics, and the reader's own Gemini key.
struct LyricsTranslationSettingsView: View {
    private enum Check: Equatable {
        case idle, checking, works
        case failed(String)
    }

    @State private var key = ""
    @State private var hasKey = GeminiLyricsTranslator.isConfigured
    @State private var check: Check = .idle

    private static let keyPage = URL(string: "https://aistudio.google.com/apikey")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Translated by", value: hasKey ? "Gemini" : "iPhone")
            } footer: {
                Text("The iPhone's own models translate the words but often miss the meaning. Gemini reads the whole song the way a person does, creoles included, and it's free with a key of your own.")
            }

            Section {
                if hasKey {
                    checkRow
                    Button("Check the Key") { Task { await runCheck() } }
                        .disabled(check == .checking)
                    Button("Remove the Key", role: .destructive) {
                        GeminiLyricsTranslator.removeKey()
                        hasKey = false
                        check = .idle
                    }
                } else {
                    SecureField("Gemini API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save the Key") {
                        GeminiLyricsTranslator.save(key: key)
                        key = ""
                        hasKey = GeminiLyricsTranslator.isConfigured
                        Task { await runCheck() }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link(destination: Self.keyPage) {
                        Label("Get a Free Key from Google", systemImage: "arrow.up.right")
                    }
                }
            } header: {
                Text("Gemini")
            } footer: {
                Text("With a key, the lyrics you translate go to Google with the song's title and artist, and nothing else. On the free tier, Google may use them to improve its products. The key stays in this iPhone's Keychain.")
            }
        }
        .navigationTitle("Lyrics Translation")
        .navigationBarTitleDisplayMode(.inline)
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
            Label("The key works", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
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
