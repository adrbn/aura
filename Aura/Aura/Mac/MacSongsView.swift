import SwiftUI

/// Every song in the library, in one table — or the songs of one of the library's lists: the
/// favourites, the ones played last, a genre's.
///
/// Subsonic has no "all songs" call, so this is `search3` with an empty query, paged — the
/// same trick the iOS app's bulk operations use. The whole library is pulled once per
/// launch rather than paged in on scroll: a `Table` that grows underneath you loses the
/// selection and the scroll position, and a personal library fits in memory comfortably.
struct MacSongsView: View {
    enum Kind: Hashable {
        case all, favorites, recentlyPlayed
        case genre(String)
    }

    var kind: Kind = .all
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var songs: [Song] = []
    @State private var isLoading = false

    private let pageSize = 500
    /// A stop, so a mis-configured server can't spin forever.
    private let ceiling = 20_000

    private var title: Text {
        switch kind {
        case .all: return Text("Songs")
        case .favorites: return Text("Favorites")
        case .recentlyPlayed: return Text("Recently Played")
        case .genre(let name): return Text(verbatim: name)
        }
    }

    private var source: PlaybackSource {
        switch kind {
        case .all: return .songs
        case .favorites: return .favorites
        case .recentlyPlayed: return .recentlyPlayed
        case .genre(let name): return .genre(name: name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if songs.isEmpty && isLoading {
                MacLoadingState()
            } else if songs.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    title.auraDisplay(52).lineLimit(1)
                    Text("^[\(songs.count) song](inflect: true)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if isLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { player.playShuffled(songs, source: source) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 10)
                MacSongTable(songs: songs, source: source)
            }
        }
        .navigationTitle(title)
        .task { await load() }
    }

    private func load() async {
        guard let server = serverManager.currentServer, songs.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        switch kind {
        case .all:
            await loadPaged { try await SubsonicClient.shared.search3(
                server: server, query: "", artistCount: 0, albumCount: 0,
                songCount: pageSize, songOffset: $0
            ).song ?? [] }
        case .genre(let name):
            await loadPaged { try await SubsonicClient.shared.getSongsByGenre(
                server: server, genre: name, count: pageSize, offset: $0) }
        case .favorites:
            songs = (try? await SubsonicClient.shared.getStarred2(server: server).song) ?? []
        case .recentlyPlayed:
            songs = await Self.songs(ids: PlayHistory.shared.recentSongIds(limit: 100), server: server)
        }
    }

    /// Pages of `pageSize` from the offset, until a short page or the ceiling.
    private func loadPaged(_ page: (Int) async throws -> [Song]) async {
        var collected: [Song] = []
        var seen = Set<String>()
        while collected.count < ceiling {
            guard let batch = try? await page(collected.count), !batch.isEmpty else { break }

            // Deduplicated, and stopped as soon as a page adds nothing new. Not every
            // server honours songOffset on an empty query — some hand back the same page
            // every time, which used to run this straight into the ceiling and report a
            // library of exactly 20,000 songs that didn't exist.
            let fresh = batch.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { break }
            collected += fresh
            songs = collected
            if batch.count < pageSize { break }
        }
        songs = collected
    }

    /// Songs by id, in the ids' order, ten requests at a time. The play history keeps ids,
    /// and the server has no call for many songs at once.
    static func songs(ids: [String], server: ServerConfig) async -> [Song] {
        var found: [String: Song] = [:]
        for start in stride(from: 0, to: ids.count, by: 10) {
            await withTaskGroup(of: Song?.self) { group in
                for id in ids[start..<min(start + 10, ids.count)] {
                    group.addTask { try? await SubsonicClient.shared.getSong(server: server, id: id) }
                }
                for await song in group { if let song { found[song.id] = song } }
            }
        }
        return ids.compactMap { found[$0] }
    }
}

/// A genre, as a value a page can be pushed for.
struct MacGenre: Hashable { let name: String }

/// The library's genres, the largest first, each opening its songs.
struct MacGenresView: View {
    @State private var serverManager = ServerManager.shared
    @State private var genres: [GenreEntry] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Genres").auraDisplay(52)
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 4)
            if isLoading && genres.isEmpty {
                MacLoadingState()
            } else if genres.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "guitars")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(genres, id: \.value) { genre in
                            NavigationLink(value: MacGenre(name: genre.value)) { tile(genre) }
                                .buttonStyle(MacPressStyle())
                                .macHoverLift(scale: 1.015)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Genres")
        .task { await load() }
    }

    /// The Home's quick-pick tile, without the cover: a name and its count, one glance.
    private func tile(_ genre: GenreEntry) -> some View {
        HStack {
            Text(genre.value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            if let count = genre.songCount {
                Text("\(count) songs").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        defer { isLoading = false }
        do {
            genres = try await SubsonicClient.shared.getGenres(server: server)
                .sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        } catch {
            AppLogger.shared.log("❌ genres failed: \(error.localizedDescription)")
        }
    }
}
