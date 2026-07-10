import SwiftUI

// MARK: - Recently Played Songs (Full List)

struct RecentlyPlayedSongsView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @State private var appSettings = AppSettings.shared
    @State private var songs: [Song] = []
    @State private var isLoading = true

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SongRowView(song: song) {
                    player.playSong(song, fromQueue: songs, startIndex: index, source: .recentlyPlayed)
                }
                .listRowInsets(EdgeInsets(top: appSettings.listDensity.verticalPadding,
                                          leading: 16,
                                          bottom: appSettings.listDensity.verticalPadding,
                                          trailing: 16))
            }
            Color.clear.frame(height: 80)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .scrollIndicators(.hidden)
        .navigationTitle("Recently Played")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && songs.isEmpty {
                List {
                    ForEach(0..<12, id: \.self) { _ in
                        SkeletonSongRow()
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
            }
        }
        .task { await loadSongs() }
    }

    private func loadSongs() async {
        guard let server = serverManager.currentServer else { return }
        let ids = PlayHistory.shared.recentSongIds(limit: 100)
        let fetched = await HomeView.fetchSongs(ids: ids, server: server)
        await MainActor.run {
            songs = fetched
            isLoading = false
        }
    }
}
