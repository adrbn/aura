import SwiftUI

/// Settings ▸ Made For You: which mixes the Home shelf makes, from which genres, and how
/// long they run. Leaving the page rebuilds the shelf if anything changed.
struct MadeForYouSettingsView: View {
    @Environment(ServerManager.self) private var serverManager
    @AppStorage(MixPreferences.timeOfDayKey) private var timeOfDay = true
    @AppStorage(MixPreferences.genreMixesKey) private var genreMixes = true
    @AppStorage(MixPreferences.discoverKey) private var discover = true
    @AppStorage(MixPreferences.genresKey) private var genresRaw = ""
    @AppStorage(MixPreferences.lengthKey) private var length = 50
    @AppStorage(MixPreferences.moodKey(.chill)) private var chill = true
    @AppStorage(MixPreferences.moodKey(.focus)) private var focus = true
    @AppStorage(MixPreferences.moodKey(.feelGood)) private var feelGood = true
    @AppStorage(MixPreferences.moodKey(.energy)) private var energy = true
    @State private var serverGenres: [GenreEntry] = []
    @State private var signatureOnAppear = ""
    @State private var generator = MixGenerator.shared
    private var accentColor: Color { AppSettings.shared.activeTheme.accentColor }

    private var pickedGenres: [String] {
        genresRaw.split(separator: "\n").map(String.init)
    }

    var body: some View {
        List {
            Section {
                Toggle("Time of Day Mix", isOn: $timeOfDay)
                ForEach(MixGenerator.Mood.allCases, id: \.self) { mood in
                    Toggle(mood.title, isOn: moodBinding(mood))
                }
                Toggle("Genre Mixes", isOn: $genreMixes)
                Toggle("New Discoveries", isOn: $discover)
            } header: {
                Text("Mixes")
            } footer: {
                Text("The time of day mix follows the hour: morning, afternoon, evening or late night.")
            }

            if genreMixes {
                Section {
                    row(String(localized: "Automatic"), selected: pickedGenres.isEmpty) { genresRaw = "" }
                    ForEach(serverGenres, id: \.value) { genre in
                        row(genre.value, selected: pickedGenres.contains(genre.value)) { toggle(genre.value) }
                    }
                } header: {
                    Text("Genres")
                } footer: {
                    Text("Automatic makes a mix for each of the four genres you play and like most. Tick genres to choose them yourself.")
                }
            }

            Section {
                Picker("Songs per Mix", selection: $length) {
                    Text(verbatim: "25").tag(25)
                    Text(verbatim: "50").tag(50)
                    Text(verbatim: "100").tag(100)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Songs per Mix")
            }

            Section {
                Button {
                    Task { await generator.generate() }
                } label: {
                    HStack {
                        Label("Make New Mixes Now", systemImage: "arrow.clockwise")
                        Spacer()
                        if generator.isGenerating { ProgressView() }
                    }
                }
                .disabled(generator.isGenerating)
            } footer: {
                Text("Mixes are made again every eight hours, and when the time of day changes.")
            }
        }
        .endsAboveBottomChrome()
        .scrollIndicators(.hidden)
        .navigationTitle("made for you")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accentColor)
        .task { await loadGenres() }
        .onAppear { signatureOnAppear = MixPreferences.signature }
        .onDisappear {
            guard MixPreferences.signature != signatureOnAppear else { return }
            Task { await MixGenerator.shared.generate() }
        }
    }

    private func moodBinding(_ mood: MixGenerator.Mood) -> Binding<Bool> {
        switch mood {
        case .chill: return $chill
        case .focus: return $focus
        case .feelGood: return $feelGood
        case .energy: return $energy
        }
    }

    private func row(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ genre: String) {
        var picked = pickedGenres
        if let i = picked.firstIndex(of: genre) { picked.remove(at: i) } else { picked.append(genre) }
        genresRaw = picked.joined(separator: "\n")
    }

    /// The server's genres, biggest first, so the ones worth a mix are at the top.
    private func loadGenres() async {
        guard let server = serverManager.currentServer,
              let genres = try? await SubsonicClient.shared.getGenres(server: server) else { return }
        serverGenres = genres
            .filter { ($0.songCount ?? 0) >= 8 && !$0.value.isEmpty }
            .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
    }
}
