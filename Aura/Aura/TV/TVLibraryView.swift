import SwiftUI

/// The library: albums, artists or playlists, as a grid of covers.
struct TVLibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case albums, artists, playlists
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .albums: "Albums"
            case .artists: "Artists"
            case .playlists: "Playlists"
            }
        }
    }

    @State private var section: Section = .albums
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var playlists: [Playlist] = []
    @State private var loading: Set<Section> = []

    private let columns = Array(repeating: GridItem(.fixed(300), spacing: 48, alignment: .top), count: 5)

    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Picker("Library", selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 800)

                LazyVGrid(columns: columns, spacing: 60) {
                    switch section {
                    case .albums: ForEach(albums) { TVAlbumLink(album: $0) }
                    case .artists: ForEach(artists) { TVArtistLink(artist: $0, width: 300) }
                    case .playlists: ForEach(playlists) { TVPlaylistLink(playlist: $0) }
                    }
                }
                if isEmpty { TVStatus(loading: loading.contains(section)) }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .task(id: section) { await load(section) }
    }

    private var isEmpty: Bool {
        switch section {
        case .albums: albums.isEmpty
        case .artists: artists.isEmpty
        case .playlists: playlists.isEmpty
        }
    }

    private func load(_ section: Section) async {
        guard isEmpty, let server = ServerManager.shared.currentServer else { return }
        loading.insert(section)
        defer { loading.remove(section) }
        let client = SubsonicClient.shared
        switch section {
        case .albums:
            // The server pages its album list; the pages are asked for until one comes back short.
            let page = 500
            var all: [Album] = []
            while let batch = try? await client.getAlbumList2(server: server, type: "alphabeticalByName",
                                                              size: page, offset: all.count) {
                all += batch
                albums = all
                if batch.count < page { break }
            }
        case .artists:
            artists = ((try? await client.getArtists(server: server)) ?? [])
                .sorted { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
        case .playlists:
            playlists = (try? await client.getPlaylists(server: server)) ?? []
        }
    }
}

/// Search: the system's on-screen keyboard and dictation, results as shelves.
struct TVSearchView: View {
    @State private var query = ""
    @State private var result: SearchResult3?
    @State private var searching = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if let songs = result?.song, !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Songs").font(.system(size: 36, weight: .bold))
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 40), GridItem(.flexible())], spacing: 6) {
                            ForEach(Array(songs.prefix(10).enumerated()), id: \.offset) { index, song in
                                TVSongRow(song: song, showsArtwork: true) {
                                    TVPlayback.shared.play(songs, from: index, source: .search(query: query))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                }
                TVShelf(title: "Artists", items: result?.artist ?? []) { TVArtistLink(artist: $0) }
                TVShelf(title: "Albums", items: result?.album ?? []) { TVAlbumLink(album: $0) }
                if searching && result == nil { TVStatus(loading: true) }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .searchable(text: $query)
        .task(id: query) { await search() }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { result = nil; return }
        // A moment's pause, so each letter typed doesn't send a request of its own.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, let server = ServerManager.shared.currentServer else { return }
        searching = true
        defer { searching = false }
        let found = try? await SubsonicClient.shared.search3(server: server, query: text, artistCount: 12,
                                                             albumCount: 20, songCount: 20)
        guard !Task.isCancelled else { return }
        result = found
    }
}
