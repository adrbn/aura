import SwiftUI

/// The generated mixes — genre, daypart, mood, retrospective — built by the same
/// `MixGenerator` the phone uses, from the same listening history.
struct MacMixesView: View {
    @State private var generator = MixGenerator.shared
    @State private var serverManager = ServerManager.shared

    var body: some View {
        Group {
            if generator.mixes.isEmpty {
                if generator.isGenerating {
                    MacLoadingState()
                } else {
                    ContentUnavailableView(
                        "No mixes yet",
                        systemImage: "sparkles",
                        description: Text("Mixes are built from what you listen to. Play a few things first.")
                    )
                }
            } else {
                grid
            }
        }
        .navigationTitle("Made For You")
        .toolbar {
            Button { Task { await generator.generate() } } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .disabled(generator.isGenerating)
        }
        .task {
            guard serverManager.currentServer != nil else { return }
            await generator.generateIfNeeded()
        }
    }

    private var grid: some View {
        ScrollView {
            Text("Made For You")
                .auraDisplay(52)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 26)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 230), spacing: 20)],
                      spacing: 22) {
                ForEach(generator.mixes) { mix in
                    NavigationLink(value: mix) { tile(mix) }.buttonStyle(MacPressStyle())
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    private func tile(_ mix: Mix) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                // The phone's editorial cover: the most-played artist's photo under the mix's type.
                EditorialMixCover(mix: mix, size: geo.size.width, cornerRadius: 10)
            }
            .aspectRatio(1, contentMode: .fit)
            .macHoverLift()
            VStack(alignment: .leading, spacing: 1) {
                Text(mix.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(mix.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct MacMixDetailView: View {
    let mix: Mix
    @State private var player = AudioPlayer.shared

    var body: some View {
        VStack(spacing: 0) {
            MacDetailHeader(
                coverArt: mix.coverArt,
                title: mix.title,
                subtitle: String(localized: "\(mix.subtitle) · \(mix.songs.count) songs"),
                placeholderName: mix.title,
                mix: mix
            ) {
                Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            }
            Divider()
            MacSongTable(songs: mix.songs, source: .mix(id: mix.id, name: mix.title))
        }
        .navigationTitle(mix.title)
    }

    private func play(shuffled: Bool) {
        guard !mix.songs.isEmpty else { return }
        let source = PlaybackSource.mix(id: mix.id, name: mix.title)
        shuffled ? player.playShuffled(mix.songs, source: source)
                 : player.playSong(mix.songs[0], fromQueue: mix.songs, startIndex: 0, source: source)
    }
}
