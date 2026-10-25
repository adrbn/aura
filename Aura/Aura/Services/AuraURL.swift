import Foundation

// MARK: - aura:// links

/// Links other apps, Shortcuts' Open URL and automations can use:
/// aura://playlist/<id>, aura://album/<id> (add ?shuffle=1 to shuffle),
/// aura://play, aura://pause, aura://toggle, aura://next, aura://previous.
enum AuraURL {
    @MainActor static func open(_ url: URL) {
        guard url.scheme == "aura" else { return }
        let player = AudioPlayer.shared
        let id = url.pathComponents.dropFirst().first
        let shuffle = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "shuffle" && $0.value != "0" } == true
        switch url.host {
        case "play": if !player.isPlaying { player.togglePlayPause() }
        case "pause": if player.isPlaying { player.togglePlayPause() }
        case "toggle": player.togglePlayPause()
        case "next": player.next()
        case "previous": player.previous()
        case "playlist", "album":
            guard let id, let server = ServerManager.shared.currentServer else { return }
            let isPlaylist = url.host == "playlist"
            Task {
                let found: (name: String, songs: [Song])?
                if isPlaylist {
                    found = (try? await SubsonicClient.shared.getPlaylist(server: server, id: id))
                        .map { ($0.name, $0.entry ?? []) }
                } else {
                    found = (try? await SubsonicClient.shared.getAlbum(server: server, id: id))
                        .map { ($0.name, $0.song ?? []) }
                }
                guard let found, let first = found.songs.first else {
                    AppLogger.shared.log("🔗 \(url.absoluteString): nothing to play")
                    return
                }
                let source: PlaybackSource = isPlaylist ? .playlist(id: id, name: found.name)
                                                        : .album(id: id, name: found.name)
                if shuffle {
                    player.playShuffled(found.songs, source: source)
                } else {
                    player.playSong(first, fromQueue: found.songs, startIndex: 0, source: source)
                }
            }
        default:
            AppLogger.shared.log("🔗 Unknown link: \(url.absoluteString)")
        }
    }
}
