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

    var body: some View {
        Group {
            if let playlist = playlist {
                List {
                    // Header
                    VStack(spacing: 16) {
                        // Cover + name sit at the top; the song list follows directly
                        // below the buttons rather than being pushed to mid-screen.
                        ZStack {
                            CoverArtAsyncImage(coverArt: playlist.coverArt, size: 200)
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
                        .frame(width: 200, height: 200)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                showCoverPicker = true
                            } label: {
                                Label("Change Cover Art", systemImage: "photo")
                            }
                            Button {
                                saveCoverArt(coverArtId: playlist.coverArt)
                            } label: {
                                Label("Save Cover Art", systemImage: "square.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                Task { await removePlaylistCoverArt() }
                            } label: {
                                Label("Remove Cover Art", systemImage: "trash")
                            }
                        } preview: {
                            // Lift only the cover (not the whole header block) on long-press.
                            CoverArtAsyncImage(coverArt: playlist.coverArt, size: 260)
                        }

                        VStack(spacing: 4) {
                            Text(playlist.name)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 24)

                            // Show the description in place of the author when one is set.
                            if let comment = playlist.comment,
                               !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(comment)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            } else if let owner = playlist.owner {
                                Text(owner).font(.subheadline).foregroundStyle(.secondary)
                            }

                            if let count = playlist.songCount {
                                Text("\(count) \(count == 1 ? "Song" : "Songs")").font(.caption).foregroundStyle(.tertiary)
                            }
                        }

                        HStack(spacing: 12) {
                            Button {
                                if let songs = playlist.entry, !songs.isEmpty {
                                    player.playSong(songs[0], fromQueue: songs, source: .playlist(id: playlistId, name: playlist.name))
                                }
                            } label: {
                                Label("Play", systemImage: "play.fill")
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
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 12)
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
                    }

                    Color.clear.frame(height: 80)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .auraPageBackground()
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
                    }
                    .clearListRows()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .auraPageBackground()
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
                    Divider()
                    Button { showEditSheet = true } label: {
                        Label("Modify", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(90))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let removal = pendingRemoval {
                HStack {
                    Text("Removed \"\(removal.song.title)\"")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Button("Undo") {
                        undoRemoval()
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: pendingRemoval != nil)
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
        .sheet(isPresented: $showEditSheet) {
            if let pl = playlist {
                PlaylistEditView(playlistId: pl.id, currentName: pl.name, currentComment: pl.comment ?? "") {
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

    private func removeSong(song: Song, at index: Int) {
        // Optimistically remove from local list
        pendingRemoval = (song: song, index: index)
        playlist?.entry?.remove(at: index)
        if let count = playlist?.songCount { playlist?.songCount = count - 1 }

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
        .auraPageBackground()
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
            let thumbIds = (result.entry ?? []).prefix(300).compactMap(\.displayCoverArt)
            ArtworkCache.shared.prefetch(coverArtIds: Array(thumbIds), pointSize: 50)
        } catch {
            AppLogger.shared.log("❌ Playlist load error: \(error.localizedDescription)")
            await MainActor.run { isLoading = false }
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

    /// Dedicated session for Navidrome native API calls — shares cookies between login and upload.
    private static let navidromeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    private func getNavidromeToken(server: ServerConfig) async -> String? {
        guard let url = URL(string: "\(server.baseURL)/auth/login") else {
            AppLogger.shared.log("❌ Navidrome auth: invalid login URL")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "username": server.username,
            "password": server.password
        ]) else {
            AppLogger.shared.log("❌ Navidrome auth: failed to build request body")
            return nil
        }
        request.httpBody = body
        do {
            let (data, response) = try await Self.navidromeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            AppLogger.shared.log("🔐 Navidrome auth: HTTP \(http.statusCode)")
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "(no body)"
                AppLogger.shared.log("❌ Navidrome auth failed: \(body)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["token"] as? String, !token.isEmpty {
                AppLogger.shared.log("🔐 Navidrome auth: token received")
                return token
            }
            AppLogger.shared.log("❌ Navidrome auth: no token in response")
        } catch {
            AppLogger.shared.log("❌ Navidrome auth error: \(error.localizedDescription)")
        }
        return nil
    }

    private func saveCoverArt(coverArtId: String?) {
        guard let coverArtId,
              let server = serverManager.currentServer,
              let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArtId, size: ArtworkCache.fullSize) else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    ToastManager.shared.show("Saved to Photos", icon: "checkmark")
                }
            } catch {
                AppLogger.shared.log("❌ Save cover art failed: \(error.localizedDescription)")
            }
        }
    }

    private func uploadPlaylistCoverArt(data: Data) async {
        guard let server = serverManager.currentServer else { return }

        // Authenticate with Navidrome native API via JWT
        guard let token = await getNavidromeToken(server: server) else {
            AppLogger.shared.log("❌ Playlist cover upload: failed to get auth token")
            return
        }

        // Use Navidrome native API: POST /api/playlist/{id}/image
        let urlString = "\(server.baseURL)/api/playlist/\(playlistId)/image"
        guard let url = URL(string: urlString) else {
            AppLogger.shared.log("❌ Playlist cover upload: invalid URL: \(urlString)")
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Set both Authorization and X-ND-Authorization for Navidrome compatibility
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"cover.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        AppLogger.shared.log("📤 Uploading playlist cover: \(urlString) (\(data.count) bytes)")
        do {
            let (responseData, response) = try await Self.navidromeSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let responseBody = String(data: responseData, encoding: .utf8) ?? "(no body)"
                AppLogger.shared.log("Playlist cover upload: HTTP \(httpResponse.statusCode) — \(responseBody)")
                if (200...299).contains(httpResponse.statusCode) {
                    // Invalidate cached cover art so the new image loads
                    if let coverArt = playlist?.coverArt {
                        ArtworkCache.shared.removeImages(forCoverArt: coverArt)
                    }
                    await loadPlaylist()
                    await MainActor.run { coverArtRefreshId = UUID() }
                }
            }
        } catch {
            AppLogger.shared.log("❌ Playlist cover art upload error: \(error.localizedDescription)")
        }
    }

    /// Remove a custom playlist cover via the Navidrome native API (reverts to the
    /// auto-generated cover built from the playlist's songs).
    private func removePlaylistCoverArt() async {
        guard let server = serverManager.currentServer else { return }
        guard let token = await getNavidromeToken(server: server) else {
            AppLogger.shared.log("❌ Remove playlist cover: failed to get auth token")
            return
        }
        let urlString = "\(server.baseURL)/api/playlist/\(playlistId)/image"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        AppLogger.shared.log("🗑 Removing playlist cover: \(urlString)")
        do {
            let (responseData, response) = try await Self.navidromeSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                let body = String(data: responseData, encoding: .utf8) ?? "(no body)"
                AppLogger.shared.log("🗑 Remove playlist cover: HTTP \(http.statusCode) — \(body)")
                if (200...299).contains(http.statusCode) {
                    if let coverArt = playlist?.coverArt {
                        ArtworkCache.shared.removeImages(forCoverArt: coverArt)
                    }
                    await loadPlaylist()
                    await MainActor.run { coverArtRefreshId = UUID() }
                    ToastManager.shared.show("Cover art removed", icon: "checkmark")
                } else {
                    ToastManager.shared.show("Couldn’t remove cover art", icon: "exclamationmark.triangle.fill")
                }
            }
        } catch {
            AppLogger.shared.log("❌ Remove playlist cover error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Playlist Edit View

struct PlaylistEditView: View {
    let playlistId: String
    @State var currentName: String
    @State var currentComment: String
    var onSave: () async -> Void

    @Environment(ServerManager.self) private var serverManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist Info") {
                    TextField("Name", text: $currentName)
                    TextField("Description", text: $currentComment, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Cover Art") {
                    Text("Long-press the cover art on the playlist page to change it from your photo library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("edit playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            guard let server = serverManager.currentServer else { return }
                            try? await SubsonicClient.shared.updatePlaylist(
                                server: server, id: playlistId,
                                name: currentName, comment: currentComment
                            )
                            await onSave()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
