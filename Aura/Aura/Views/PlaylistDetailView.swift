import SwiftUI
import PhotosUI

struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var playlist: PlaylistWithSongs?
    @State private var isLoading = true
    @State private var showEditSheet = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showCoverPicker = false
    @State private var pendingRemoval: (song: Song, index: Int)?
    @State private var undoTask: Task<Void, Never>?
    @State private var isStarred = false
    @State private var showDownloadConfirm = false
    @State private var coverArtRefreshId = UUID()
    @State private var showAddSongs = false
    @State private var suggestions: [Song] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var wide: Bool { horizontalSizeClass == .regular }
    private var headerLayout: AnyLayout {
        wide ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 24)) : AnyLayout(VStackLayout(spacing: 16))
    }

    var body: some View {
        Group {
            if let playlist = playlist {
                List {
                    // Header. On an iPhone Duo's wide screen the cover stands at the left and
                    // the name and buttons sit beside it, at its foot, as on an album page.
                    headerLayout {
                        // Cover + name sit at the top; the song list follows directly
                        // below the buttons rather than being pushed to mid-screen.
                        headerCover
                        .frame(width: 200, height: 200)
                        .coverMenu(cornerRadius: 12, actions: [
                            CoverMenuAction(title: String(localized: "Change Cover Art"), systemImage: "photo") {
                                showCoverPicker = true
                            },
                            CoverMenuAction(title: String(localized: "Save Cover Art"), systemImage: "square.and.arrow.down") {
                                if let period = WrappedCovers.period(for: playlistId) {
                                    CoverArtSaver.save(rendering: GeneratedCoverView(nature: .retrospective(period.coverLabel),
                                                                                     size: 400, cornerRadius: 0))
                                } else {
                                    CoverArtSaver.save(coverArt: playlist.coverArt)
                                }
                            },
                            CoverMenuAction(title: String(localized: "Remove Cover Art"), systemImage: "trash",
                                            isDestructive: true) {
                                Task { await removePlaylistCoverArt() }
                            },
                        ])

                        VStack(alignment: wide ? .leading : .center, spacing: 16) {
                        VStack(alignment: wide ? .leading : .center, spacing: 4) {
                            Text(playlist.name)
                                .font(wide ? .title.bold() : .title2.bold())
                                .multilineTextAlignment(wide ? .leading : .center)
                                .lineLimit(2)
                                .padding(.horizontal, wide ? 0 : 24)

                            // Show the description in place of the author when one is set.
                            if let comment = playlist.comment,
                               !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(comment)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(wide ? .leading : .center)
                                    .padding(.horizontal, wide ? 0 : 24)
                            } else if let owner = playlist.owner {
                                Text(owner).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            Button {
                                if let songs = playlist.entry, !songs.isEmpty {
                                    player.playSong(songs[0], fromQueue: songs, source: .playlist(id: playlistId, name: playlist.name))
                                }
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .background(accentColor).foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.borderless)
                            Button {
                                if let songs = playlist.entry, !songs.isEmpty {
                                    player.playShuffled(songs, source: .playlist(id: playlistId, name: playlist.name))
                                }
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.borderless)
                        }
                        .frame(maxWidth: wide ? 360 : nil)
                        .padding(.horizontal, wide ? 0 : 16)
                        }
                        .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
                    }
                    .padding(.horizontal, wide ? 16 : 0)
                    .padding(.top, 12)
                    .padding(.bottom, DetailListLayout.gap)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    if let songs = playlist.entry {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            SongRowView(song: song, tappableArtist: false, disableSwipeActions: true) {
                                player.playSong(song, fromQueue: songs, startIndex: index, source: .playlist(id: playlistId, name: playlist.name))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    removeSong(song: song, at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .accessibilityLabel("Remove")
                                Button { player.playNext(song) } label: {
                                    Image(systemName: "text.insert")
                                }
                                .accessibilityLabel("Play Next")
                                .tint(.blue)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { player.addToQueue(song) } label: {
                                    Image(systemName: "text.append")
                                }
                                .accessibilityLabel("Add to Queue")
                                .tint(.orange)
                            }
                            .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                                      leading: 16,
                                                      bottom: AppSettings.shared.listDensity.verticalPadding,
                                                      trailing: 16))
                        }
                        // Closes the list as it does an album's.
                        if !songs.isEmpty {
                            ListSummaryRow(text: Self.summary(of: songs))
                        }
                    }
                    if playlist.entry?.isEmpty ?? true {
                        emptyPlaylistPrompt
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    if !suggestions.isEmpty {
                        suggestionsSection
                    }

                    ListEndSpacer()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(ArtworkCanvas(coverArt: playlist.coverArt))
                .scrollIndicators(.hidden)
            } else if isLoading {
                List {
                    SkeletonPlaylistHeader()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    ForEach(0..<10, id: \.self) { _ in
                        SkeletonSongRow()
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            } else {
                loadFailedView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { togglePlaylistStar() } label: {
                        Label(isStarred ? "Unpin" : "Pin", systemImage: isStarred ? "pin.slash" : "pin")
                    }
                    Button {
                        if let songs = playlist?.entry, !songs.isEmpty {
                            var shuffled = songs; shuffled.shuffle()
                            player.addToQueue(shuffled)
                        }
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                    downloadMenuButton
                    Toggle(isOn: Binding(
                        get: { DownloadManager.shared.keptPlaylistIds.contains(playlistId) },
                        set: { DownloadManager.shared.setKeepDownloaded(playlistId, $0) }
                    )) {
                        Label("Keep Downloaded", systemImage: "arrow.down.circle.dotted")
                    }
                    Divider()
                    Button { showAddSongs = true } label: {
                        Label("Add Songs", systemImage: "plus")
                    }
                    Button { showEditSheet = true } label: {
                        Label("Modify", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                }
                // In the back button's colour, not the accent: the pair frames the page.
                .tint(.primary)
            }
        }
        .confirmationDialog("Download Playlist?", isPresented: $showDownloadConfirm, titleVisibility: .visible) {
            Button("Download All Songs") {
                if let songs = playlist?.entry, !songs.isEmpty {
                    Task { await DownloadManager.shared.downloadAlbum(songs, groupId: playlistId) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download all \(playlist?.entry?.count ?? 0) songs in this playlist?")
        }
        .task {
            isStarred = AppSettings.shared.isPinned(playlistId)
            await loadPlaylist()
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsSheet(playlistSongs: playlist?.entry ?? []) { song in
                await add(song)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let pl = playlist {
                PlaylistEditView(playlistId: pl.id, currentName: pl.name, currentComment: pl.comment ?? "", coverArt: pl.coverArt) {
                    await loadPlaylist()
                }
            }
        }
        .photosPicker(isPresented: $showCoverPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, newItem in
            handlePhotoPicked(newItem)
        }
    }

    /// The Download entry for the playlist menu — reflects the three group states.
    @ViewBuilder private var downloadMenuButton: some View {
        if DownloadManager.shared.isGroupDownloading(playlistId) {
            Button(role: .destructive) {
                DownloadManager.shared.cancelGroupDownload(playlistId)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else if let songs = playlist?.entry, !songs.isEmpty, DownloadManager.shared.allDownloaded(songs.map { $0.id }) {
            Button {} label: {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
            }
            .disabled(true)
        } else {
            Button {
                showDownloadConfirm = true
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }

    /// "12 songs · 48 min".
    private static func summary(of songs: [Song]) -> String {
        let seconds = songs.compactMap(\.duration).reduce(0, +)
        let count = songs.count == 1 ? String(localized: "1 song") : String(localized: "\(songs.count) songs")
        guard seconds > 0 else { return count }
        let length = Duration.seconds(max(seconds, 60))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(count) · \(length)"
    }

    private func removeSong(song: Song, at index: Int) {
        // Optimistically remove from local list
        pendingRemoval = (song: song, index: index)
        playlist?.entry?.remove(at: index)
        if let count = playlist?.songCount { playlist?.songCount = count - 1 }
        ToastManager.shared.show(String(localized: "Removed \"\(song.title)\""), icon: "minus.circle.fill",
                                 duration: 4, action: (String(localized: "Undo"), undoRemoval))

        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // Commit removal to server
            await commitRemoval(songIndex: index)
        }
    }

    private func undoRemoval() {
        undoTask?.cancel()
        guard let removal = pendingRemoval else { return }
        // Re-insert the song at its original position
        let insertIndex = min(removal.index, playlist?.entry?.count ?? 0)
        playlist?.entry?.insert(removal.song, at: insertIndex)
        if let count = playlist?.songCount { playlist?.songCount = count + 1 }
        pendingRemoval = nil
    }

    private func commitRemoval(songIndex: Int) async {
        guard let server = serverManager.currentServer else { return }
        do {
            try await SubsonicClient.shared.removeSongFromPlaylist(server: server, playlistId: playlistId, songIndex: songIndex)
        } catch {
            // If server fails, reload to get correct state
            await loadPlaylist()
        }
        await MainActor.run { pendingRemoval = nil }
    }

    /// Shown when the playlist couldn't be loaded (e.g. the server is
    /// unreachable) so navigating in never leaves a blank screen.
    private var loadFailedView: some View {
        ContentUnavailableView {
            Label("Couldn't load playlist",
                  systemImage: serverManager.hasNetwork ? "exclamationmark.icloud" : "wifi.slash")
        } description: {
            Text("Check your connection or server, then try again.")
        } actions: {
            Button("Retry") {
                Task { await loadPlaylist() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.themeBg)
    }

    private func loadPlaylist() async {
        await MainActor.run { isLoading = true }
        guard let server = serverManager.currentServer else {
            await MainActor.run { isLoading = false }
            return
        }
        do {
            let result = try await SubsonicClient.shared.getPlaylist(server: server, id: playlistId)
            await MainActor.run {
                playlist = result
                isLoading = false
                coverArtRefreshId = UUID()
            }
            // Warm song thumbnails so rows don't pop in while scrolling.
            // Capped: huge playlists shouldn't trigger hundreds of fetches at once.
            if suggestions.isEmpty {
                let picked = await PlaylistSuggester.suggest(server: server, for: result.entry ?? [])
                await MainActor.run { withAnimation { suggestions = picked } }
            }
            let thumbIds = (result.entry ?? []).prefix(300).compactMap(\.displayCoverArt)
            ArtworkCache.shared.prefetch(coverArtIds: Array(thumbIds), pointSize: 50)
        } catch {
            AppLogger.shared.log("❌ Playlist load error: \(error.localizedDescription)")
            await MainActor.run { isLoading = false }
        }
    }

    /// An empty playlist says so and offers the way to fill it.
    private var emptyPlaylistPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("This playlist is empty")
                .font(.headline)
            Text("Add songs here, or from any song's menu with Add to Playlist.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showAddSongs = true } label: {
                Label("Add Songs", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(accentColor)
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        HStack {
            Text("Suggestions").font(.title3.bold())
            Spacer()
            Button {
                Task {
                    guard let server = serverManager.currentServer else { return }
                    let picked = await PlaylistSuggester.suggest(server: server, for: playlist?.entry ?? [])
                    withAnimation { suggestions = picked }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh Suggestions")
        }
        .padding(.top, 24)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        ForEach(suggestions) { song in
            HStack(spacing: 8) {
                SongRowView(song: song, disableSwipeActions: true) {
                    player.playSong(song, fromQueue: [song])
                }
                Button { Task { await add(song) } } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(accentColor)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add to Playlist")
            }
            .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                      bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 8))
            .listRowBackground(Color.clear)
        }
    }

    private func add(_ song: Song) async {
        guard let server = serverManager.currentServer else { return }
        do {
            try await SubsonicClient.shared.addSongToPlaylist(server: server, playlistId: playlistId, songId: song.id)
            await MainActor.run { withAnimation { suggestions.removeAll { $0.id == song.id } } }
            await loadPlaylist()
        } catch {
            ToastManager.shared.show(String(localized: "Couldn't add the song"), icon: "exclamationmark.triangle")
        }
    }

    private func togglePlaylistStar() {
        // Playlist starring is visual-only (Subsonic doesn't support starring playlists)
        // We use it as a local favourite indicator
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            isStarred.toggle()
        }
        // Persist via pinning
        AppSettings.shared.togglePin(playlistId: playlistId)
    }

    @State private var isProcessingPhoto = false

    private func handlePhotoPicked(_ newItem: PhotosPickerItem?) {
        guard let newItem else { return }
        guard !isProcessingPhoto else { return }
        isProcessingPhoto = true
        AppLogger.shared.log("📷 Photo picked, loading data...")
        Task.detached(priority: .userInitiated) {
            do {
                guard let data = try await newItem.loadTransferable(type: Data.self) else {
                    AppLogger.shared.log("📷 Failed to load transferable data")
                    await MainActor.run { isProcessingPhoto = false }
                    return
                }
                AppLogger.shared.log("📷 Got data: \(data.count) bytes, processing...")
                guard let processed = Self.processPickedImageSync(data: data) else {
                    AppLogger.shared.log("📷 Image processing failed")
                    await MainActor.run { isProcessingPhoto = false }
                    return
                }
                AppLogger.shared.log("📷 Done: \(Int(processed.size.width))x\(Int(processed.size.height)), uploading directly")
                // Upload directly — no crop step (crop was causing freezes)
                if let jpegData = processed.jpegData(compressionQuality: 0.9) {
                    await uploadPlaylistCoverArt(data: jpegData)
                }
                await MainActor.run {
                    isProcessingPhoto = false
                }
            } catch {
                AppLogger.shared.log("📷 Error: \(error.localizedDescription)")
                await MainActor.run { isProcessingPhoto = false }
            }
        }
    }

    /// Normalize orientation, center-crop to square, and downscale.
    private static func processPickedImageSync(data: Data) -> UIImage? {
        guard let uiImage = UIImage(data: data) else { return nil }
        var image = uiImage

        // Normalize EXIF orientation
        if image.imageOrientation != .up {
            let renderer = UIGraphicsImageRenderer(size: image.size)
            image = renderer.image { _ in image.draw(at: .zero) }
        }

        // Center-crop to square
        let side = min(image.size.width, image.size.height)
        let x = (image.size.width - side) / 2
        let y = (image.size.height - side) / 2
        if let cgImage = image.cgImage?.cropping(to: CGRect(x: x * image.scale, y: y * image.scale, width: side * image.scale, height: side * image.scale)) {
            image = UIImage(cgImage: cgImage)
        }

        // Downscale to max 1200px for cover art
        let maxDim: CGFloat = 1200
        if max(image.size.width, image.size.height) > maxDim {
            let s = maxDim / max(image.size.width, image.size.height)
            let newSize = CGSize(width: image.size.width * s, height: image.size.height * s)
            let r = UIGraphicsImageRenderer(size: newSize)
            image = r.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }

        return image.preparingForDisplay() ?? image
    }

    /// Pulled out of the header: inlined, the surrounding expression stopped
    /// type-checking in reasonable time.
    @ViewBuilder private var headerCover: some View {
        ZStack {
            PlaylistCoverView(playlistId: playlistId, coverArt: playlist?.coverArt, size: 200, cornerRadius: 12)
                .id(coverArtRefreshId)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

            if isProcessingPhoto {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .frame(width: 200, height: 200)
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.primary)
            }
        }
    }

    private func uploadPlaylistCoverArt(data: Data) async {
        guard let server = serverManager.currentServer,
              await PlaylistCovers.upload(data, playlistId: playlistId, server: server) else { return }
        // The cached picture would otherwise keep showing.
        if let coverArt = playlist?.coverArt {
            ArtworkCache.shared.removeImages(forCoverArt: coverArt)
        }
        await loadPlaylist()
        coverArtRefreshId = UUID()
    }

    /// Remove a custom playlist cover via the Navidrome native API (reverts to the
    /// auto-generated cover built from the playlist's songs).
    private func removePlaylistCoverArt() async {
        guard let server = serverManager.currentServer else { return }
        guard await PlaylistCovers.remove(playlistId: playlistId, server: server) else {
            ToastManager.shared.show(String(localized: "Couldn’t remove cover art"), icon: "exclamationmark.triangle.fill")
            return
        }
        if let coverArt = playlist?.coverArt {
            ArtworkCache.shared.removeImages(forCoverArt: coverArt)
        }
        await loadPlaylist()
        coverArtRefreshId = UUID()
        ToastManager.shared.show(String(localized: "Cover art removed"), icon: "checkmark")
    }
}

// MARK: - Playlist Edit View

struct PlaylistEditView: View {
    let playlistId: String
    let currentName: String
    let currentComment: String
    var coverArt: String? = nil
    var onSave: () async -> Void

    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        PlaylistFormSheet(playlistId: playlistId, coverArt: coverArt,
                          initialName: currentName, initialComment: currentComment) { name, comment in
            guard let server = serverManager.currentServer,
                  (try? await SubsonicClient.shared.updatePlaylist(server: server, id: playlistId,
                                                                   name: name, comment: comment)) != nil
            else { return false }
            // Now Playing names what plays by its source; a renamed playlist renames it there too.
            if case .playlist(let id, _) = player.playbackSource, id == playlistId {
                player.playbackSource = .playlist(id: id, name: name)
            }
            await onSave()
            return true
        }
    }
}

/// Songs to offer under a playlist: like a few of its songs, or like what played lately when
/// it is empty, and random ones when the server knows no similar songs.
enum PlaylistSuggester {
    static func suggest(server: ServerConfig, for songs: [Song], count: Int = 10) async -> [Song] {
        let inside = Set(songs.map(\.id))
        let seeds = songs.isEmpty
            ? Array(PlayHistory.shared.recentSongIds(limit: 20).shuffled().prefix(3))
            : Array(songs.shuffled().prefix(3).map(\.id))
        var picked: [Song] = []
        for seed in seeds {
            let similar = (try? await SubsonicClient.shared.getSimilarSongs2(server: server, id: seed, count: 10)) ?? []
            picked += similar
        }
        if picked.isEmpty {
            picked = (try? await SubsonicClient.shared.getRandomSongs(server: server, size: count * 2)) ?? []
        }
        var seen = inside
        return Array(picked.shuffled().filter { seen.insert($0.id).inserted }.prefix(count))
    }
}

/// Search the server and add songs one tap at a time, the sheet staying open. Before a
/// search it offers suggestions, so it never opens on a blank page.
struct AddSongsSheet: View {
    let playlistSongs: [Song]
    let onAdd: (Song) async -> Void
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var suggestions: [Song] = []
    @State private var isSearching = false
    @State private var added: Set<String> = []

    private var alreadyIn: Set<String> { Set(playlistSongs.map(\.id)) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                VStack(spacing: 12) {
                    SheetTitle("add songs")
                        .padding(.horizontal, 16)
                    SearchFieldBar(text: $query, prompt: "Songs, artists, albums")
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if searching {
                    if results.isEmpty && !isSearching {
                        Text("No results")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(results) { row($0) }
                } else if !suggestions.isEmpty {
                    Text("Suggestions")
                        .font(.title3.bold())
                        .padding(.top, 8)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(suggestions) { row($0) }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .auraSheet()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task {
                guard let server = serverManager.currentServer else { return }
                suggestions = await PlaylistSuggester.suggest(server: server, for: playlistSongs, count: 25)
            }
            .task(id: query) {
                let text = query.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { results = []; return }
                isSearching = true
                defer { isSearching = false }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let server = serverManager.currentServer else { return }
                let found = try? await SubsonicClient.shared.search3(server: server, query: text,
                                                                     artistCount: 0, albumCount: 0, songCount: 40)
                if !Task.isCancelled { results = found?.song ?? [] }
            }
        }
    }

    private func row(_ song: Song) -> some View {
        let isIn = alreadyIn.contains(song.id) || added.contains(song.id)
        return HStack(spacing: 8) {
            SongRowView(song: song, disableSwipeActions: true) {
                player.playSong(song, fromQueue: [song])
            }
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { _ = added.insert(song.id) }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await onAdd(song) }
            } label: {
                Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(isIn)
            .accessibilityLabel(isIn ? "Added" : "Add to Playlist")
        }
        .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                  bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 8))
        .listRowBackground(Color.clear)
    }
}
