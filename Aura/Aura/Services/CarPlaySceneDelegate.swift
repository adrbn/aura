import CarPlay
import UIKit

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private let player = AudioPlayer.shared

    // MARK: - Scene Lifecycle

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        AppLogger.shared.log("🚗 CarPlay connected")
        let tabBar = buildTabBar()
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        AppLogger.shared.log("🚗 CarPlay disconnected")
    }

    // MARK: - Tab Bar

    private func buildTabBar() -> CPTabBarTemplate {
        let nowPlaying = buildNowPlayingTab()
        let recents = buildRecentsTab()
        let playlists = buildPlaylistsTab()
        let library = buildLibraryTab()

        let tabBar = CPTabBarTemplate(templates: [nowPlaying, recents, playlists, library])
        return tabBar
    }

    // MARK: - Now Playing Tab

    private func buildNowPlayingTab() -> CPNowPlayingTemplate {
        let template = CPNowPlayingTemplate.shared
        template.tabSystemItem = .mostViewed
        template.tabTitle = "Now Playing"
        template.tabImage = UIImage(systemName: "play.circle.fill")

        let shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
            self?.player.toggleShuffle()
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            self?.player.cycleRepeat()
        }
        template.updateNowPlayingButtons([shuffleButton, repeatButton])

        return template
    }

    // MARK: - Recents Tab

    private func buildRecentsTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Recent Albums", sections: [])
        template.tabSystemItem = .history
        template.tabTitle = "Recents"
        template.tabImage = UIImage(systemName: "clock.fill")

        Task { @MainActor in
            guard let server = ServerManager.shared.currentServer else { return }
            do {
                let albums = try await SubsonicClient.shared.getAlbumList2(server: server, type: "recent", size: 20)
                let items = albums.map { album in
                    let item = CPListItem(text: album.name, detailText: album.artist)
                    item.handler = { [weak self] _, completion in
                        self?.showAlbum(album, completion: completion)
                    }
                    if let coverArt = album.coverArt {
                        self.loadArtwork(coverArt: coverArt, size: ArtworkCache.thumbSize) { image in
                            item.setImage(image)
                        }
                    }
                    return item
                }
                let section = CPListSection(items: items)
                template.updateSections([section])
            } catch {
                AppLogger.shared.log("🚗 Failed to load recents: \(error)")
            }
        }

        return template
    }

    // MARK: - Playlists Tab

    private func buildPlaylistsTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [])
        template.tabSystemItem = .favorites
        template.tabTitle = "Playlists"
        template.tabImage = UIImage(systemName: "music.note.list")

        Task { @MainActor in
            guard let server = ServerManager.shared.currentServer else { return }
            do {
                let playlists = try await SubsonicClient.shared.getPlaylists(server: server)
                let items = playlists.prefix(20).map { playlist in
                    let detail = playlist.songCount.map { "\($0) songs" } ?? ""
                    let item = CPListItem(text: playlist.name, detailText: detail)
                    item.handler = { [weak self] _, completion in
                        self?.showPlaylist(playlist, completion: completion)
                    }
                    if let coverArt = playlist.coverArt {
                        self.loadArtwork(coverArt: coverArt, size: ArtworkCache.thumbSize) { image in
                            item.setImage(image)
                        }
                    }
                    return item
                }
                let section = CPListSection(items: items)
                template.updateSections([section])
            } catch {
                AppLogger.shared.log("🚗 Failed to load playlists: \(error)")
            }
        }

        return template
    }

    // MARK: - Library Tab

    private func buildLibraryTab() -> CPListTemplate {
        let items: [CPListItem] = [
            {
                let item = CPListItem(text: "Random Songs", detailText: "Shuffle random tracks")
                item.setImage(UIImage(systemName: "shuffle"))
                item.handler = { [weak self] _, completion in
                    self?.playRandomSongs(completion: completion)
                }
                return item
            }(),
            {
                let item = CPListItem(text: "Starred Songs", detailText: "Your favourites")
                item.setImage(UIImage(systemName: "heart.fill"))
                item.handler = { [weak self] _, completion in
                    self?.playStarredSongs(completion: completion)
                }
                return item
            }(),
            {
                let item = CPListItem(text: "Instant Mix", detailText: "Radio from current song")
                item.setImage(UIImage(systemName: "antenna.radiowaves.left.and.right"))
                item.handler = { [weak self] _, completion in
                    if let song = self?.player.currentSong {
                        self?.player.startRadioFromSong(song)
                    }
                    completion()
                }
                return item
            }()
        ]

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Library", sections: [section])
        template.tabSystemItem = .more
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "square.stack.fill")
        return template
    }

    // MARK: - Album Detail

    private func showAlbum(_ album: Album, completion: @escaping () -> Void) {
        guard let server = ServerManager.shared.currentServer else {
            completion()
            return
        }
        Task { @MainActor in
            do {
                let albumDetail = try await SubsonicClient.shared.getAlbum(server: server, id: album.id)
                let songs = albumDetail.song ?? []
                let items: [CPListItem] = songs.enumerated().map { index, song in
                    let item = CPListItem(text: song.title, detailText: song.artist ?? album.artist ?? "")
                    item.handler = { [weak self] _, itemCompletion in
                        self?.player.playSong(song, fromQueue: songs, startIndex: index)
                        self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        itemCompletion()
                    }
                    return item
                }

                // Add shuffle all at top
                let shuffleItem = CPListItem(text: "Shuffle All", detailText: "\(songs.count) songs")
                shuffleItem.setImage(UIImage(systemName: "shuffle"))
                shuffleItem.handler = { [weak self] _, itemCompletion in
                    if !songs.isEmpty {
                        var shuffled = songs
                        shuffled.shuffle()
                        self?.player.playSong(shuffled[0], fromQueue: shuffled)
                        self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    }
                    itemCompletion()
                }

                let section = CPListSection(items: [shuffleItem] + items)
                let template = CPListTemplate(title: album.name, sections: [section])
                self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
                completion()
            } catch {
                AppLogger.shared.log("🚗 Failed to load album: \(error)")
                completion()
            }
        }
    }

    // MARK: - Playlist Detail

    private func showPlaylist(_ playlist: Playlist, completion: @escaping () -> Void) {
        guard let server = ServerManager.shared.currentServer else {
            completion()
            return
        }
        Task { @MainActor in
            do {
                let playlistDetail = try await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
                let songs = playlistDetail.entry ?? []
                let items: [CPListItem] = songs.enumerated().map { index, song in
                    let item = CPListItem(text: song.title, detailText: song.artist ?? "")
                    item.handler = { [weak self] _, itemCompletion in
                        self?.player.playSong(song, fromQueue: songs, startIndex: index)
                        self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        itemCompletion()
                    }
                    return item
                }

                let shuffleItem = CPListItem(text: "Shuffle All", detailText: "\(songs.count) songs")
                shuffleItem.setImage(UIImage(systemName: "shuffle"))
                shuffleItem.handler = { [weak self] _, itemCompletion in
                    if !songs.isEmpty {
                        var shuffled = songs
                        shuffled.shuffle()
                        self?.player.playSong(shuffled[0], fromQueue: shuffled)
                        self?.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    }
                    itemCompletion()
                }

                let section = CPListSection(items: [shuffleItem] + items)
                let template = CPListTemplate(title: playlist.name, sections: [section])
                self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
                completion()
            } catch {
                AppLogger.shared.log("🚗 Failed to load playlist: \(error)")
                completion()
            }
        }
    }

    // MARK: - Quick Actions

    private func playRandomSongs(completion: @escaping () -> Void) {
        guard let server = ServerManager.shared.currentServer else {
            completion()
            return
        }
        Task { @MainActor in
            do {
                let songs = try await SubsonicClient.shared.getRandomSongs(server: server, size: 50)
                if let first = songs.first {
                    player.playSong(first, fromQueue: songs)
                    interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                }
                completion()
            } catch {
                AppLogger.shared.log("🚗 Failed to load random songs: \(error)")
                completion()
            }
        }
    }

    private func playStarredSongs(completion: @escaping () -> Void) {
        guard let server = ServerManager.shared.currentServer else {
            completion()
            return
        }
        Task { @MainActor in
            do {
                let starred = try await SubsonicClient.shared.getStarred2(server: server)
                let songs = starred.song ?? []
                if let first = songs.first {
                    var shuffled = songs
                    shuffled.shuffle()
                    player.playSong(shuffled[0], fromQueue: shuffled)
                    interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                }
                completion()
            } catch {
                AppLogger.shared.log("🚗 Failed to load starred songs: \(error)")
                completion()
            }
        }
    }

    // MARK: - Artwork Loading

    private func loadArtwork(coverArt: String, size: Int, completion: @escaping (UIImage?) -> Void) {
        guard let server = ServerManager.shared.currentServer,
              let url = SubsonicClient.shared.coverArtURL(server: server, id: coverArt, size: size) else {
            completion(nil)
            return
        }

        let key = "\(coverArt)_\(size)"
        if let cached = ArtworkCache.shared.image(for: key) {
            completion(cached)
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    ArtworkCache.shared.store(image, for: key)
                    await MainActor.run { completion(image) }
                }
            } catch {
                await MainActor.run { completion(nil) }
            }
        }
    }
}
