import SwiftUI

struct AddToPlaylistView: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var detent: PresentationDetent = .medium
    @State private var playlists: [Playlist] = []
    @State private var sortedPlaylistIds: [String] = [] // Stable sort order captured on load
    @State private var isLoading = true
    @State private var newPlaylistName = ""
    @State private var isCreating = false
    @FocusState private var nameFieldFocused: Bool
    @State private var searchText = ""
    @State private var isFavorited: Bool = false
    /// Last count seen, so the row shows a number at once instead of 0 while it's fetched.
    @AppStorage("aura.favoriteSongCount") private var favoriteCount: Int = 0

    private let spring = Animation.spring(duration: 0.35, bounce: 0.3)

    /// Read from the shared pre-fetched cache
    private var playlistsContainingSong: Set<String> {
        PlaylistMembershipCache.shared.containing(song.id)
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
            ScrollView {
                tintedListLayout
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(spring, value: isCreating)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $searchText, prompt: "Search playlists")
            // The page's own colour under the rows, the search field and the bar alike.
            .background(Color.themeBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Done"))
                }
            }
            .task {
                isFavorited = song.isStarred
                await loadPlaylists()
                // Load favorite count
                if let server = serverManager.currentServer {
                    if let starred = try? await SubsonicClient.shared.getStarred2(server: server) {
                        await MainActor.run { favoriteCount = starred.song?.count ?? favoriteCount }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(Color.themeBg)
    }

    // MARK: - Shared actions

    private func isIn(_ playlist: Playlist) -> Bool { playlistsContainingSong.contains(playlist.id) }

    private func toggle(_ playlist: Playlist) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let wasIn = isIn(playlist)
        // Optimistic: the cache flips at once, the server call follows.
        withAnimation(spring) {
            if wasIn {
                PlaylistMembershipCache.shared.unmarkSongFromPlaylist(songId: song.id, playlistId: playlist.id)
            } else {
                PlaylistMembershipCache.shared.markSongInPlaylist(songId: song.id, playlistId: playlist.id)
            }
        }
        Task {
            if wasIn { await removeFromPlaylist(playlist) } else { await addToPlaylist(playlist) }
        }
    }

    private func tapFavorite() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await toggleFavorite() }
    }

    private func startCreating() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        newPlaylistName = ""
        isCreating = true
    }

    private func cancelCreating() {
        nameFieldFocused = false
        newPlaylistName = ""
        isCreating = false
    }

    private func submitNewPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        cancelCreating()
        Task { await createAndAdd(name: name) }
    }

    // MARK: - Shared pieces

    private var songHeader: some View {
        HStack(spacing: 14) {
            CoverArtImage(coverArt: song.displayCoverArt, size: 60, cornerRadius: 10,
                          fallbackCoverArt: song.albumId,
                          placeholderName: song.title, placeholderKind: .song)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to Playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(song.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private func heartTile(size: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(LinearGradient(colors: [accentColor, accentColor.opacity(0.7)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.white)
            }
    }

    /// Filled accent disc with a knocked-out check when included, a thin ring when not.
    private func checkBadge(_ on: Bool, size: CGFloat) -> some View {
        ZStack {
            Circle().strokeBorder(Color.primary.opacity(on ? 0 : 0.3), lineWidth: 1.5)
            if on {
                Circle().fill(accentColor)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.44, weight: .bold))
                            .foregroundStyle(Color.themeBg)
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
    }

    private var newPlaylistField: some View {
        HStack(spacing: 12) {
            TextField("Playlist Name", text: $newPlaylistName)
                .font(.body.weight(.medium))
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit(submitNewPlaylist)
                .onAppear { nameFieldFocused = true }
            Button("Create", action: submitNewPlaylist)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(action: cancelCreating) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("Cancel"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.08)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var skeletonRows: some View {
        VStack(spacing: 8) {
            ForEach(0..<8, id: \.self) { _ in SkeletonPlaylistRow() }
        }
    }

    // MARK: - Layout

    private var tintedListLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            songHeader
            if isLoading {
                skeletonRows
            } else {
                LazyVStack(spacing: 4) {
                    if isCreating {
                        newPlaylistField.padding(.horizontal, 8)
                    } else if searchText.isEmpty {
                        Button(action: startCreating) {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(width: 56, height: 56)
                                    .overlay {
                                        Image(systemName: "plus")
                                            .font(.title2.weight(.medium))
                                            .foregroundStyle(accentColor)
                                    }
                                Text("New Playlist")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(accentColor)
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if searchText.isEmpty
                        || String(localized: "Favorite Songs").localizedCaseInsensitiveContains(searchText) {
                        tintedRow(on: isFavorited, action: tapFavorite) {
                            heartTile(size: 56, radius: 10)
                        } title: { Text("Favorite Songs") } subtitle: { Text("\(favoriteCount) songs") }
                    }

                    ForEach(filteredPlaylists) { playlist in
                        tintedRow(on: isIn(playlist), action: { toggle(playlist) }) {
                            PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt,
                                              size: 56, cornerRadius: 10, placeholderName: playlist.name)
                        } title: { Text(playlist.name) } subtitle: { Text("\(playlist.songCount ?? 0) songs") }
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }

    private func tintedRow<Cover: View, Title: View, Subtitle: View>(
        on: Bool, action: @escaping () -> Void,
        @ViewBuilder cover: () -> Cover,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                cover()
                VStack(alignment: .leading, spacing: 3) {
                    title()
                        .font(.body.weight(.semibold))
                        .foregroundStyle(on ? accentColor : .primary)
                        .lineLimit(1)
                    subtitle()
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                checkBadge(on, size: 26)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(accentColor.opacity(on ? 0.16 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private func toggleFavorite() async {
        guard let server = serverManager.currentServer else { return }
        let wasFavorited = isFavorited
        withAnimation(spring) { isFavorited.toggle() } // Optimistic update
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
            await MainActor.run { withAnimation(spring) { isFavorited = wasFavorited } } // Rollback
            AppLogger.shared.log("Failed to toggle favorite: \(error.localizedDescription)")
        }
    }

    private func loadPlaylists() async {
        // The playlists saved on the device show at once, ticks included; the server's
        // list replaces them when it arrives and refreshes the saved ones behind it.
        await MainActor.run {
            if playlists.isEmpty {
                let saved = OfflinePlaylistsStore.shared.playlists.map(\.asPlaylist)
                if !saved.isEmpty { show(saved) }
            }
        }
        guard let server = serverManager.currentServer else { return }
        do {
            var seen = Set<String>()
            let result = try await SubsonicClient.shared.getPlaylists(server: server)
                .filter { seen.insert($0.id).inserted }
            await MainActor.run {
                show(result)
                OfflinePlaylistsStore.shared.refresh(from: result)
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    @MainActor
    private func show(_ result: [Playlist]) {
                playlists = result
                // Capture stable sort order: containing first, then pinned, then by date
                if sortedPlaylistIds.isEmpty {
                    let membership = PlaylistMembershipCache.shared.containing(song.id)
                    let containing = result.filter { membership.contains($0.id) }
                    let notContaining = result.filter { !membership.contains($0.id) }
                    let pinned = notContaining.filter { AppSettings.shared.isPinned($0.id) }
                    let rest = notContaining.filter { !AppSettings.shared.isPinned($0.id) }
                        .sorted { ($0.created ?? "") > ($1.created ?? "") }
                    sortedPlaylistIds = (containing + pinned + rest).map(\.id)
                } else {
                    // One just created goes on top, not at the end of a long list.
                    let known = Set(sortedPlaylistIds)
                    sortedPlaylistIds = result.map(\.id).filter { !known.contains($0) } + sortedPlaylistIds
                }
                isLoading = false
    }

    private func addToPlaylist(_ playlist: Playlist) async {
        do {
            // Offline, the song is in the playlist here at once and on the server once it's back.
            try await PlaylistEditQueue.shared.add([song], to: playlist.id)
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
        do {
            // The queue finds the song's row in the server's list, now or once it's back.
            try await PlaylistEditQueue.shared.remove([song.id], from: playlist.id)
            AppLogger.shared.log("Removed '\(song.title)' from playlist '\(playlist.name)'")
            await MainActor.run {
                PlaylistMembershipCache.shared.unmarkSongFromPlaylist(songId: song.id, playlistId: playlist.id)
                ToastManager.shared.show(String(localized: "Removed from \(playlist.name)"), icon: "minus.circle")
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
            await MainActor.run {
                ToastManager.shared.show(String(localized: "Couldn't create the playlist"), icon: "exclamationmark.triangle.fill")
            }
        }
    }
}
