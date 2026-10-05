import SwiftUI

struct AddToPlaylistView: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var playlists: [Playlist] = []
    @State private var sortedPlaylistIds: [String] = [] // Stable sort order captured on load
    @State private var isLoading = true
    @State private var newPlaylistName = ""
    @State private var showCreateAlert = false
    @State private var searchText = ""
    @State private var isFavorited: Bool = false
    @State private var favoriteCount: Int = 0

    /// Read from the shared pre-fetched cache
    private var playlistsContainingSong: Set<String> {
        PlaylistMembershipCache.shared.cache[song.id] ?? []
    }

    /// Playlists in stable order — sort is captured at load time so toggling doesn't reorder
    private var filteredPlaylists: [Playlist] {
        let filtered = searchText.isEmpty ? playlists : playlists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.comment ?? "").localizedCaseInsensitiveContains(searchText)
        }
        // Use the stable sort order captured at load
        let idOrder = Dictionary(uniqueKeysWithValues: sortedPlaylistIds.enumerated().map { ($1, $0) })
        return filtered.sorted { (idOrder[$0.id] ?? Int.max) < (idOrder[$1.id] ?? Int.max) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    List {
                        ForEach(0..<8, id: \.self) { _ in
                            SkeletonPlaylistRow()
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                } else {
                    List {
                        // Favorite Songs pseudo-playlist at the top
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await toggleFavorite() }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(
                                            LinearGradient(
                                                colors: [accentColor, accentColor.opacity(0.7)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "heart.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Favorite Songs")
                                        .font(.subheadline.weight(.medium))
                                    Text("\(favoriteCount) songs")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isFavorited {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(accentColor)
                                } else {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)

                        ForEach(filteredPlaylists) { playlist in
                            let isInPlaylist = playlistsContainingSong.contains(playlist.id)
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if isInPlaylist {
                                    // Optimistic: immediately unmark in cache
                                    PlaylistMembershipCache.shared.unmarkSongFromPlaylist(songId: song.id, playlistId: playlist.id)
                                    Task { await removeFromPlaylist(playlist) }
                                } else {
                                    // Optimistic: immediately mark in cache
                                    PlaylistMembershipCache.shared.markSongInPlaylist(songId: song.id, playlistId: playlist.id)
                                    Task { await addToPlaylist(playlist) }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt, size: 44, cornerRadius: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("\(playlist.songCount ?? 0) songs")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if isInPlaylist {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(accentColor)
                                    } else {
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.hidden)
                    .searchable(text: $searchText, prompt: "Search playlists")
                }
            }
            // The page's own colour under the rows, the search field and the bar alike: the
            // plain list used to sit on the system's grey below a darker header.
            .background(Color.themeBg)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Add to Playlist").font(.headline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showCreateAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Playlist", isPresented: $showCreateAlert) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task { await createAndAdd(name: name) }
                }
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
            } message: {
                Text("Enter a name for the new playlist.")
            }
            .task {
                isFavorited = song.isStarred
                await loadPlaylists()
                // Load favorite count
                if let server = serverManager.currentServer {
                    if let starred = try? await SubsonicClient.shared.getStarred2(server: server) {
                        await MainActor.run { favoriteCount = starred.song?.count ?? 0 }
                    }
                }
            }
        }
        .presentationBackground(Color.themeBg)
    }

    private func toggleFavorite() async {
        guard let server = serverManager.currentServer else { return }
        let wasFavorited = isFavorited
        isFavorited.toggle() // Optimistic update
        do {
            if wasFavorited {
                try await SubsonicClient.shared.unstar(server: server, id: song.id)
                await MainActor.run {
                    // Sync with AudioPlayer if this is the current song
                    if var current = player.currentSong, current.id == song.id {
                        current.starred = nil
                        player.currentSong = current
                        if let idx = player.queue.firstIndex(where: { $0.id == song.id }) {
                            player.queue[idx] = current
                        }
                    }
                    ToastManager.shared.show(String(localized: "Removed from Favorites"), icon: "heart")
                }
            } else {
                try await SubsonicClient.shared.star(server: server, id: song.id)
                await MainActor.run {
                    if var current = player.currentSong, current.id == song.id {
                        current.starred = ISO8601DateFormatter().string(from: Date())
                        player.currentSong = current
                        if let idx = player.queue.firstIndex(where: { $0.id == song.id }) {
                            player.queue[idx] = current
                        }
                    }
                    ToastManager.shared.show(String(localized: "Added to Favorites"), icon: "heart.fill")
                }
            }
        } catch {
            await MainActor.run { isFavorited = wasFavorited } // Rollback
            AppLogger.shared.log("Failed to toggle favorite: \(error.localizedDescription)")
        }
    }

    private func loadPlaylists() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let result = try await SubsonicClient.shared.getPlaylists(server: server)

            // If the cache doesn't have data for this song yet, trigger a fetch now
            // (fallback for when Add to Playlist is opened from outside NowPlayingView)
            if PlaylistMembershipCache.shared.cache[song.id] == nil {
                PlaylistMembershipCache.shared.preloadMembership(for: song.id)
                // Brief wait for membership cache to populate
                try? await Task.sleep(for: .milliseconds(200))
            }

            await MainActor.run {
                playlists = result
                // Capture stable sort order: containing first, then pinned, then by date
                if sortedPlaylistIds.isEmpty {
                    let membership = PlaylistMembershipCache.shared.cache[song.id] ?? []
                    let containing = result.filter { membership.contains($0.id) }
                    let notContaining = result.filter { !membership.contains($0.id) }
                    let pinned = notContaining.filter { AppSettings.shared.isPinned($0.id) }
                    let rest = notContaining.filter { !AppSettings.shared.isPinned($0.id) }
                        .sorted { ($0.created ?? "") > ($1.created ?? "") }
                    sortedPlaylistIds = (containing + pinned + rest).map(\.id)
                }
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    private func addToPlaylist(_ playlist: Playlist) async {
        guard let server = serverManager.currentServer else { return }
        do {
            try await SubsonicClient.shared.addSongToPlaylist(server: server, playlistId: playlist.id, songId: song.id)
            AppLogger.shared.log("Added '\(song.title)' to playlist '\(playlist.name)'")
            await MainActor.run {
                PlaylistMembershipCache.shared.markSongInPlaylist(songId: song.id, playlistId: playlist.id)
                ToastManager.shared.show(String(localized: "Added to \(playlist.name)"), icon: "text.badge.plus")
            }
        } catch {
            AppLogger.shared.log("Failed to add to playlist: \(error.localizedDescription)")
        }
    }

    private func removeFromPlaylist(_ playlist: Playlist) async {
        guard let server = serverManager.currentServer else { return }
        do {
            // Get playlist detail to find the song's index
            let detail = try await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
            if let entries = detail.entry,
               let index = entries.firstIndex(where: { $0.id == song.id }) {
                try await SubsonicClient.shared.removeSongFromPlaylist(server: server, playlistId: playlist.id, songIndex: index)
                AppLogger.shared.log("Removed '\(song.title)' from playlist '\(playlist.name)'")
                await MainActor.run {
                    PlaylistMembershipCache.shared.unmarkSongFromPlaylist(songId: song.id, playlistId: playlist.id)
                    ToastManager.shared.show(String(localized: "Removed from \(playlist.name)"), icon: "minus.circle")
                }
            }
        } catch {
            AppLogger.shared.log("Failed to remove from playlist: \(error.localizedDescription)")
        }
    }

    private func createAndAdd(name: String) async {
        guard let server = serverManager.currentServer else { return }
        do {
            let created = try await SubsonicClient.shared.createPlaylist(server: server, name: name, songIds: [song.id])
            AppLogger.shared.log("Created playlist '\(name)' with '\(song.title)'")
            // Mark song as in the newly created playlist so tapping it won't add again
            PlaylistMembershipCache.shared.markSongInPlaylist(songId: song.id, playlistId: created.id)
            // Refresh playlist list to show the new one
            await loadPlaylists()
            await MainActor.run {
                ToastManager.shared.show(String(localized: "Created \(name)"), icon: "plus.circle.fill")
            }
        } catch {
            AppLogger.shared.log("Failed to create playlist: \(error.localizedDescription)")
        }
    }
}
