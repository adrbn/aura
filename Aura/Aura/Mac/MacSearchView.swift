import SwiftUI

/// Search, over the same ranked index the phone uses — including its offline fallback and
/// its "did you mean" correction.
struct MacSearchView: View {
    @Binding var query: String
    @State private var results = SearchResults()
    @State private var isSearching = false

    var body: some View {
        Group {
            if isSearching {
                // Replaces the results rather than sitting above them: a query in flight
                // should not leave the previous query's hits on screen looking like answers.
                MacLoadingState()
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                found
            }
        }
        .navigationTitle("Search")
        .task(id: query) { await run() }
    }

    private var found: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let correction = results.suggestedCorrection {
                    Button { query = correction } label: {
                        HStack(spacing: 4) {
                            Text("Did you mean:").foregroundStyle(.secondary)
                            Text(correction).bold().foregroundStyle(Color.appAccent)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                if !results.artists.isEmpty {
                    header("Artists")
                    row(results.artists) { artist in
                        NavigationLink(value: artist) {
                            MacCoverTile(coverArt: artist.coverArt, title: artist.name,
                                         placeholderName: artist.name, circular: true)
                                .frame(width: 132)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !results.albums.isEmpty {
                    header("Albums")
                    row(results.albums) { album in
                        NavigationLink(value: album) {
                            MacCoverTile(coverArt: album.coverArt, title: album.name,
                                         subtitle: album.artist, placeholderName: album.name)
                                .frame(width: 132)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !results.playlists.isEmpty {
                    header("Playlists")
                    row(results.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            MacCoverTile(coverArt: playlist.coverArt, title: playlist.name,
                                         subtitle: playlist.songCount.map { "\($0) songs" },
                                         placeholderName: playlist.name)
                                .frame(width: 132)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !results.songs.isEmpty {
                    header("Songs")
                    LazyVStack(spacing: 2) {
                        ForEach(results.songs) { song in
                            MacSongRow(song: song, source: .search(query: query),
                                       queue: results.songs)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).auraDisplay(34)
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
    }

    private func row<T: Identifiable, V: View>(_ items: [T],
                                               @ViewBuilder tile: @escaping (T) -> V) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) { ForEach(items) { tile($0) } }
                .padding(.horizontal, 24)
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = SearchResults(); isSearching = false; return
        }
        isSearching = true
        // Debounced by `.task(id:)`, which cancels the previous run on every keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let found = await SearchIndex.shared.search(query: q)
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }
}
