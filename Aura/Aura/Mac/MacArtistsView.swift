import SwiftUI

struct MacArtistsView: View {
    @State private var serverManager = ServerManager.shared
    @State private var artists: [Artist] = []
    @State private var isLoading = false
    @State private var filter = ""

    private var shown: [Artist] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? artists : artists.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        MacGrid(title: "Artists", items: shown, isLoading: isLoading, emptyMessage: "No artists") { artist in
            NavigationLink(value: artist) {
                MacCoverTile(coverArt: artist.coverArt, title: artist.name,
                             subtitle: artist.albumCount.map { String(localized: "\($0) albums") },
                             placeholderName: artist.name, circular: true)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Artists")
        // A plain filter over an already-loaded list, not a server search: the artist list
        // is small enough to hold, and filtering it is instant where a round trip is not.
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter artists")
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer, artists.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        artists = (try? await SubsonicClient.shared.getArtists(server: server)) ?? []
    }
}

struct MacArtistDetailView: View {
    let artist: Artist
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var albums: [Album] = []
    @State private var topSongs: [Song] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MacDetailHeader(
                    coverArt: artist.coverArt,
                    title: artist.name,
                    subtitle: String(localized: "\(albums.count) albums"),
                    placeholderName: artist.name
                ) {
                    Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    Button { mix() } label: { Label("Instant Mix", systemImage: "sparkles") }
                        .disabled(topSongs.isEmpty)
                }

                if !topSongs.isEmpty {
                    sectionTitle("Top Songs")
                    MacSongTable(songs: Array(topSongs.prefix(10)),
                                 source: .artist(id: artist.id, name: artist.name))
                        .frame(height: 260)
                        .padding(.horizontal, 16)
                }

                sectionTitle("Albums")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 20)],
                          spacing: 22) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            MacCoverTile(coverArt: album.coverArt, title: album.name,
                                         subtitle: album.year.map(String.init),
                                         placeholderName: album.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(artist.name)
        .task { await load() }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text).auraDisplay(34).padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        albums = (try? await SubsonicClient.shared.getArtist(server: server, id: artist.id))?.album ?? []
        topSongs = (try? await SubsonicClient.shared.getTopSongs(
            server: server, artistName: artist.name, count: 20)) ?? []
    }

    private func play() {
        guard let first = topSongs.first else { return }
        player.playSong(first, fromQueue: topSongs, startIndex: 0,
                        source: .artist(id: artist.id, name: artist.name))
    }

    private func mix() {
        player.startArtistInstantMix(artistId: artist.id, artistName: artist.name, topSongs: topSongs)
    }
}
