import SwiftUI

struct AddToPlaylistView: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    /// Design trial: 0 cover grid, 1 tinted list, 2 song card with a shelf.
    @AppStorage("design_trial_addToPlaylist") private var variant = 0
    @State private var detent: PresentationDetent =
        UserDefaults.standard.integer(forKey: "design_trial_addToPlaylist") == 1 ? .medium : .large
    @State private var playlists: [Playlist] = []
    @State private var sortedPlaylistIds: [String] = [] // Stable sort order captured on load
    @State private var isLoading = true
    @State private var newPlaylistName = ""
    @State private var isCreating = false
    @FocusState private var nameFieldFocused: Bool
    @State private var searchText = ""
    @State private var isFavorited: Bool = false
    @State private var favoriteCount: Int = 0
    @State private var contentWidth: CGFloat = 0

    private let spring = Animation.spring(duration: 0.35, bounce: 0.3)

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

    /// The shelf of design 3: pinned first, then the newest. Built from `playlists` alone,
    /// so toggling never reshuffles it.
    private var recentPlaylists: [Playlist] {
        let pinned = playlists.filter { AppSettings.shared.isPinned($0.id) }
        let rest = playlists.filter { !AppSettings.shared.isPinned($0.id) }
            .sorted { ($0.created ?? "") > ($1.created ?? "") }
        return Array((pinned + rest).prefix(10))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch variant {
                    case 1: tintedListLayout
                    case 2: shelfLayout
                    default: gridLayout
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(spring, value: isCreating)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .searchable(text: $searchText, prompt: "Search playlists")
            // The page's own colour under the rows, the search field and the bar alike.
            .background(Color.themeBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Done"))
                }
                ToolbarItem(placement: .principal) {
                    DesignTrialSwitcher(variant: $variant)
                }
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
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
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

    // MARK: - Design 1: cover grid

    private var tileSize: CGFloat { max(100, (contentWidth - 32 - 14) / 2) }
    private var gridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]
    }

    private var gridLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            songHeader
            if isCreating { newPlaylistField }
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 20) {
                if isLoading {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: tileSize, height: tileSize)
                    }
                } else {
                    gridTile(on: isFavorited, action: tapFavorite) {
                        heartTile(size: tileSize, radius: 16)
                    } title: { Text("Favorite Songs") } subtitle: { Text("\(favoriteCount) songs") }

                    if searchText.isEmpty && !isCreating {
                        gridTile(on: false, action: startCreating) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: tileSize, height: tileSize)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.system(size: tileSize * 0.26, weight: .medium))
                                        .foregroundStyle(accentColor)
                                }
                        } title: { Text("New Playlist") } subtitle: { Text(verbatim: " ") }
                    }

                    ForEach(filteredPlaylists) { playlist in
                        gridTile(on: isIn(playlist), action: { toggle(playlist) }) {
                            PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt,
                                              size: tileSize, cornerRadius: 16, placeholderName: playlist.name)
                        } title: { Text(playlist.name) } subtitle: { Text("\(playlist.songCount ?? 0) songs") }
                    }
                }
            }
        }
    }

    private func gridTile<Cover: View, Title: View, Subtitle: View>(
        on: Bool, action: @escaping () -> Void,
        @ViewBuilder cover: () -> Cover,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                cover()
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(accentColor, lineWidth: on ? 3 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if on {
                            checkBadge(true, size: 30)
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                                .padding(8)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .scaleEffect(on ? 0.96 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    title()
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? accentColor : .primary)
                        .lineLimit(1)
                    subtitle()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Design 2: tinted list

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

                    tintedRow(on: isFavorited, action: tapFavorite) {
                        heartTile(size: 56, radius: 10)
                    } title: { Text("Favorite Songs") } subtitle: { Text("\(favoriteCount) songs") }

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

    // MARK: - Design 3: song card, shelf, list

    private var shelfLayout: some View {
        VStack(alignment: .leading, spacing: 22) {
            if searchText.isEmpty {
                VStack(spacing: 6) {
                    CoverArtImage(coverArt: song.displayCoverArt, size: 140, cornerRadius: 18,
                                  fallbackCoverArt: song.albumId,
                                  placeholderName: song.title, placeholderKind: .song)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                        .padding(.bottom, 8)
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
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }

            HStack(spacing: 12) {
                pillButton(icon: isFavorited ? "heart.fill" : "heart", title: "Favorite Songs",
                           active: isFavorited, action: tapFavorite)
                pillButton(icon: "plus", title: "New Playlist", active: false, action: startCreating)
            }
            if isCreating { newPlaylistField }

            if isLoading {
                skeletonRows
            } else {
                if searchText.isEmpty && !recentPlaylists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent").font(.title3.weight(.bold))
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(recentPlaylists) { shelfCard($0) }
                            }
                            .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.hidden)
                        .padding(.horizontal, -16)
                    }
                    Text("Playlists").font(.title3.weight(.bold))
                }
                LazyVStack(spacing: 2) {
                    ForEach(filteredPlaylists) { playlist in
                        let on = isIn(playlist)
                        Button { toggle(playlist) } label: {
                            HStack(spacing: 12) {
                                PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt,
                                                  size: 48, cornerRadius: 8, placeholderName: playlist.name)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text("\(playlist.songCount ?? 0) songs")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                checkBadge(on, size: 24)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func pillButton(icon: String, title: LocalizedStringKey, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: {
                Image(systemName: icon).contentTransition(.symbolEffect(.replace))
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(active ? accentColor.opacity(0.18) : Color.primary.opacity(0.08))
            .foregroundStyle(accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func shelfCard(_ playlist: Playlist) -> some View {
        let on = isIn(playlist)
        return Button { toggle(playlist) } label: {
            VStack(alignment: .leading, spacing: 8) {
                PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt,
                                  size: 116, cornerRadius: 14, placeholderName: playlist.name)
                    .overlay(alignment: .bottomTrailing) {
                        checkBadge(on, size: 28)
                            .background(Circle().fill(on ? .clear : Color.black.opacity(0.35)))
                            .padding(7)
                    }
                Text(playlist.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(on ? accentColor : .primary)
                    .lineLimit(1)
            }
            .frame(width: 116)
            .contentShape(Rectangle())
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
