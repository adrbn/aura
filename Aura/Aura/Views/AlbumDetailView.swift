import SwiftUI

struct AlbumDetailView: View {
    let albumId: String

    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var album: AlbumWithSongs?
    @State private var isLoading = true
    @State private var isStarred = false

    var body: some View {
        Group {
            if let album = album {
                List {
                    // Header with album art
                    VStack(spacing: 12) {
                        Spacer().frame(height: 16)

                        CoverArtAsyncImage(coverArt: album.coverArt, size: 260)
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                            .contextMenu {
                                Button {
                                    saveCoverArt(coverArtId: album.coverArt)
                                } label: {
                                    Label("Save Cover Art", systemImage: "square.and.arrow.down")
                                }
                            }

                        Text(album.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 24)

                        TappableArtistText(
                            artistString: album.artist ?? "Unknown Artist",
                            primaryArtistId: album.artistId,
                            font: .subheadline,
                            foregroundStyle: AnyShapeStyle(.secondary),
                            tappableStyle: AnyShapeStyle(accentColor)
                        )

                        // Play controls
                        HStack(spacing: 12) {
                            Button { toggleAlbumStar() } label: {
                                Image(systemName: isStarred ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle(accentColor)
                                    .frame(width: 50, height: 40)
                                    .background(Color.themeGroupedBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                if let songs = album.song, !songs.isEmpty {
                                    player.playShuffled(songs, source: .album(id: album.id, name: album.name))
                                }
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.title3)
                                    .frame(width: 50, height: 40)
                                    .background(Color.themeGroupedBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                if let songs = album.song, !songs.isEmpty {
                                    player.playSong(songs[0], fromQueue: songs, source: .album(id: album.id, name: album.name))
                                }
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 40)
                                    .background(accentColor)
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                if let songs = album.song, !songs.isEmpty {
                                    player.startAlbumRadio(songs: songs)
                                }
                            } label: {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.title3)
                                    .frame(width: 50, height: 40)
                                    .background(Color.themeGroupedBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                if let songs = album.song, !songs.isEmpty {
                                    if DownloadManager.shared.isGroupDownloading(albumId) {
                                        DownloadManager.shared.cancelGroupDownload(albumId)
                                    } else {
                                        Task { await DownloadManager.shared.downloadAlbum(songs, groupId: albumId) }
                                    }
                                }
                            } label: {
                                Group {
                                    if DownloadManager.shared.isGroupDownloading(albumId) {
                                        ZStack {
                                            CircularProgressView(progress: DownloadManager.shared.groupProgress(for: albumId))
                                                .frame(width: 22, height: 22)
                                        }
                                    } else if let songs = album.song, DownloadManager.shared.allDownloaded(songs.map { $0.id }) {
                                        Image(systemName: "arrow.down.circle.fill").font(.title3)
                                    } else {
                                        Image(systemName: "arrow.down.circle").font(.title3)
                                    }
                                }
                                    .frame(width: 50, height: 40)
                                    .background(Color.themeGroupedBg)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    // Song list
                    if let songs = album.song {
                        if let songCount = album.songCount {
                            Text("\(songCount) \(songCount == 1 ? "Song" : "Songs")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 16))
                        }
                        let isSingle = songs.count <= 1
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            SongRowView(
                                song: song,
                                showArt: false,
                                showArtist: !isSingle,
                                tappableArtist: false,
                                showTrackNumber: true
                            ) {
                                player.playSong(song, fromQueue: songs, startIndex: index, source: .album(id: album.id, name: album.name))
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
                .background(Color.themeBg)
                .scrollIndicators(.hidden)
            } else if isLoading {
                List {
                    SkeletonAlbumHeader()
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    ForEach(0..<8, id: \.self) { _ in
                        SkeletonSongRow()
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
        .task { await loadAlbum() }
    }

    /// Shown when the album couldn't be loaded (e.g. the server is unreachable)
    /// so navigating in never leaves a blank screen.
    private var loadFailedView: some View {
        ContentUnavailableView {
            Label("Couldn't load album",
                  systemImage: serverManager.hasNetwork ? "exclamationmark.icloud" : "wifi.slash")
        } description: {
            Text("Check your connection or server, then try again.")
        } actions: {
            Button("Retry") {
                Task { await loadAlbum() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.themeBg)
    }

    private func loadAlbum() async {
        await MainActor.run { isLoading = true }
        guard let server = serverManager.currentServer else {
            await MainActor.run { isLoading = false }
            return
        }
        do {
            let result = try await SubsonicClient.shared.getAlbum(server: server, id: albumId)
            // Check if album is starred
            let starred = try? await SubsonicClient.shared.getStarred2(server: server)
            let albumStarred = starred?.album?.contains(where: { $0.id == albumId }) ?? false
            await MainActor.run {
                album = result
                isStarred = albumStarred
                isLoading = false
            }
        } catch {
            AppLogger.shared.log("❌ Album load error: \(error.localizedDescription)")
            await MainActor.run { isLoading = false }
        }
    }

    private func toggleAlbumStar() {
        guard let server = serverManager.currentServer else { return }
        let wasStarred = isStarred
        isStarred.toggle()
        Task {
            do {
                if wasStarred {
                    try await SubsonicClient.shared.unstar(server: server, id: albumId, type: .album)
                } else {
                    try await SubsonicClient.shared.star(server: server, id: albumId, type: .album)
                }
            } catch {
                await MainActor.run { isStarred = wasStarred }
            }
        }
    }

    private func saveCoverArt(coverArtId: String?) {
        guard let coverArtId,
              let server = serverManager.currentServer,
              let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArtId, size: 1200) else { return }
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
}
