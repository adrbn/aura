import SwiftUI

enum SongFetchType {
    case all
    case starred
    case random
    case recentSongs
    case frequentSongs
}

enum SongSortOrder: String, CaseIterable {
    case none = "Default"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case year = "Year"
    case duration = "Duration"
    case recentlyAdded = "Recently Added"
}

/// Per-fetch-type cache that survives navigation pushes.
/// Eliminates the loading-skeleton flicker when re-entering a Songs list.
@Observable
final class SongsCache {
    static let shared = SongsCache()

    private var storage: [String: [Song]] = [:]
    private var dates: [String: Date] = [:]

    /// Songs that don't auto-stale: full library and starred — rarely change in practice.
    /// Random songs are never cached (point of `.random` is freshness).
    private func ttl(for type: SongFetchType) -> TimeInterval {
        switch type {
        case .all: return 30 * 60        // 30 min
        case .starred: return 30 * 60
        case .recentSongs: return 10 * 60
        case .frequentSongs: return 10 * 60
        case .random: return 0           // never reuse
        }
    }

    private func key(for type: SongFetchType) -> String {
        switch type {
        case .all: return "all"
        case .starred: return "starred"
        case .recentSongs: return "recent"
        case .frequentSongs: return "frequent"
        case .random: return "random"
        }
    }

    func cached(for type: SongFetchType) -> [Song] {
        storage[key(for: type)] ?? []
    }

    func isFresh(for type: SongFetchType) -> Bool {
        let ttl = ttl(for: type)
        guard ttl > 0, let date = dates[key(for: type)] else { return false }
        return Date().timeIntervalSince(date) < ttl
    }

    func store(_ songs: [Song], for type: SongFetchType) {
        let k = key(for: type)
        storage[k] = songs
        dates[k] = Date()
    }

    func invalidate(_ type: SongFetchType) {
        let k = key(for: type)
        storage[k] = nil
        dates[k] = nil
    }
}

struct SongsListView: View {
    let title: String
    let fetchType: SongFetchType

    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var loadingProgress: String = ""
    @State private var sortOrder: SongSortOrder
    @State private var sortAscending = true
    @State private var displayLimit = 44
    /// True while the full library is still paging in, so rows show in arrival order
    /// (no reshuffle on every page); the chosen sort applies once loading completes.
    @State private var isStreaming = false

    init(title: String, fetchType: SongFetchType) {
        self.title = title
        self.fetchType = fetchType

        // Prefill from cache so re-entering the screen doesn't flash the skeleton.
        let cached = SongsCache.shared.cached(for: fetchType)
        if !cached.isEmpty {
            _songs = State(initialValue: cached)
            _isLoading = State(initialValue: false)
        }

        switch fetchType {
        case .random, .recentSongs, .frequentSongs:
            _sortOrder = State(initialValue: .none)
        case .starred:
            _sortOrder = State(initialValue: .recentlyAdded)
        default:
            _sortOrder = State(initialValue: .recentlyAdded)
        }
    }

    private var sortedSongs: [Song] {
        // While the full library is still streaming in, keep arrival (server) order so the
        // visible rows stay put; the chosen sort is applied once loading completes.
        if isStreaming { return songs }
        let sorted: [Song]
        switch sortOrder {
        case .none:
            return songs
        case .recentlyAdded:
            // Sort by created date descending (newest first)
            return songs.sorted { ($0.created ?? "") > ($1.created ?? "") }
        case .title:
            sorted = songs.sorted { ($0.title).localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            sorted = songs.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .album:
            sorted = songs.sorted { ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending }
        case .year:
            sorted = songs.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        case .duration:
            sorted = songs.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private var displayedSongs: ArraySlice<Song> {
        sortedSongs.prefix(displayLimit)
    }

    var body: some View {
        Group {
            if isLoading && songs.isEmpty {
                List {
                    if !loadingProgress.isEmpty {
                        Text(loadingProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(0..<15, id: \.self) { _ in
                        SkeletonSongRow()
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
            } else if songs.isEmpty, let loadError {
                ContentUnavailableView {
                    Label(loadError, systemImage: serverManager.hasNetwork ? "exclamationmark.icloud" : "wifi.slash")
                } description: {
                    Text("Check your connection or server, then try again.")
                } actions: {
                    Button("Retry") {
                        isLoading = true
                        self.loadError = nil
                        Task { await loadSongs() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if songs.isEmpty {
                ContentUnavailableView("No Songs",
                    systemImage: "music.note",
                    description: Text("No songs found"))
            } else {
                List {
                    // Favorite Songs header with heart cover art
                    if fetchType == .starred {
                        VStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(
                                        LinearGradient(
                                            colors: [accentColor, accentColor.opacity(0.7)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 160, height: 160)
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 60))
                                    .foregroundStyle(.white)
                            }
                            .shadow(color: accentColor.opacity(0.4), radius: 12, y: 6)
                            .allowsHitTesting(false)

                            Text("\(songs.count) songs")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            // Play / Shuffle buttons
                            HStack(spacing: 12) {
                                Button {
                                    guard !sortedSongs.isEmpty else { return }
                                    player.playSong(sortedSongs[0], fromQueue: sortedSongs, startIndex: 0, source: .favorites)
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(accentColor.opacity(0.15))
                                        .foregroundStyle(accentColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }

                                Button {
                                    guard !sortedSongs.isEmpty else { return }
                                    player.playShuffled(sortedSongs, source: .favorites)
                                } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(accentColor.opacity(0.15))
                                        .foregroundStyle(accentColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { } // Absorb taps on header area (outside buttons)
                        .padding(.vertical, 16)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }

                    ForEach(Array(displayedSongs.enumerated()), id: \.element.id) { index, song in
                        SongRowView(song: song) {
                            player.playSong(song, fromQueue: sortedSongs, startIndex: index, source: fetchType == .starred ? .favorites : .songs)
                        }
                        .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                                  leading: 16,
                                                  bottom: AppSettings.shared.listDensity.verticalPadding,
                                                  trailing: 16))
                        .onAppear {
                            // Load more songs when approaching the end
                            if index >= displayLimit - 10 && displayLimit < sortedSongs.count {
                                displayLimit += 44
                            }
                        }
                    }

                    if displayLimit < sortedSongs.count {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }

                    Color.clear.frame(height: 60)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(SongSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    Divider()
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Label(sortAscending ? "Descending" : "Ascending",
                              systemImage: sortAscending ? "arrow.down" : "arrow.up")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task { await loadSongs() }
        .refreshable {
            SongsCache.shared.invalidate(fetchType)
            displayLimit = 44
            await loadSongs()
        }
        .onChange(of: sortOrder) { _, _ in
            displayLimit = 44
        }
    }

    private func loadSongs() async {
        guard let server = serverManager.currentServer else { return }

        // Cache hit → done. We already prefilled from cache in init, but this also
        // covers the case where another screen populated the cache after init ran.
        if SongsCache.shared.isFresh(for: fetchType) {
            let cached = SongsCache.shared.cached(for: fetchType)
            if !cached.isEmpty {
                await MainActor.run {
                    songs = cached
                    isLoading = false
                }
                return
            }
        }

        do {
            switch fetchType {
            case .all:
                AppLogger.shared.log("📚 Loading all songs via search3...")
                await MainActor.run { isStreaming = true }
                var allSongs: [Song] = []
                var offset = 0
                let pageSize = 500
                while true {
                    let result = try await SubsonicClient.shared.search3(
                        server: server, query: "", artistCount: 0, albumCount: 0,
                        songCount: pageSize, songOffset: offset
                    )
                    let batch = result.song ?? []
                    allSongs.append(contentsOf: batch)
                    // Progressive cache: if user navigates away mid-fetch, the next visit
                    // still has all songs loaded so far — no re-streaming from zero.
                    SongsCache.shared.store(allSongs, for: .all)
                    let snapshot = allSongs
                    await MainActor.run {
                        // Show songs as they arrive (in `isStreaming` arrival order) instead
                        // of waiting for all ~23k — the first page appears in well under a second.
                        songs = snapshot
                        isLoading = false
                        loadingProgress = ""
                    }
                    if batch.count < pageSize { break }
                    offset += batch.count
                }
                AppLogger.shared.log("📚 Loaded \(allSongs.count) songs total")
                // Done — drop streaming mode so the chosen sort takes effect (one re-sort).
                await MainActor.run {
                    isStreaming = false
                    loadingProgress = ""
                }

            case .starred:
                let starred = try await SubsonicClient.shared.getStarred2(server: server)
                let result = starred.song ?? []
                SongsCache.shared.store(result, for: .starred)
                await MainActor.run {
                    songs = result
                    isLoading = false
                }

            case .random:
                let result = try await SubsonicClient.shared.getRandomSongs(server: server, size: 50)
                await MainActor.run {
                    songs = result
                    isLoading = false
                }

            case .recentSongs:
                let albums = try await SubsonicClient.shared.getAlbumList2(server: server, type: "recent", size: 10)
                var allSongs: [Song] = []
                for album in albums {
                    let detail = try await SubsonicClient.shared.getAlbum(server: server, id: album.id)
                    allSongs.append(contentsOf: detail.song ?? [])
                }
                SongsCache.shared.store(allSongs, for: .recentSongs)
                await MainActor.run {
                    songs = allSongs
                    isLoading = false
                }

            case .frequentSongs:
                let albums = try await SubsonicClient.shared.getAlbumList2(server: server, type: "frequent", size: 10)
                var allSongs: [Song] = []
                for album in albums {
                    let detail = try await SubsonicClient.shared.getAlbum(server: server, id: album.id)
                    allSongs.append(contentsOf: detail.song ?? [])
                }
                SongsCache.shared.store(allSongs, for: .frequentSongs)
                await MainActor.run {
                    songs = allSongs
                    isLoading = false
                }
            }
        } catch {
            AppLogger.shared.log("❌ Songs load error: \(error.localizedDescription)")
            await MainActor.run {
                isLoading = false
                // Only surface an error state when there's nothing to show — with
                // cached songs on screen, a failed refresh shouldn't interrupt.
                if songs.isEmpty {
                    loadError = serverManager.hasNetwork ? "Server Unreachable" : "No Internet Connection"
                }
            }
        }
    }
}
