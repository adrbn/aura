import SwiftUI

/// The radio's page, pushed as the phone pushes it: the radio as a playlist, played from any
/// row, refreshed, or saved as a real playlist with its cover.
struct MacRadioRoute: Hashable {}

struct MacRadioView: View {
    @State private var player = AudioPlayer.shared
    @State private var isSaved = false
    @State private var isSaving = false
    @Environment(\.appAccentColor) private var accentColor

    private var songs: [Song] { player.radioPlaylistSongs }
    private var source: PlaybackSource { .radio(name: player.radioPlaylistName) }

    /// Only its seed while its songs are fetched: not a radio to show yet.
    private var isAwaitingSongs: Bool { player.isFetchingRadioSongs && songs.count <= 1 }

    var body: some View {
        VStack(spacing: 0) {
            MacDetailHeader(
                coverArt: player.radioPlaylistCoverArt,
                title: player.radioPlaylistName,
                subtitle: String(localized: "\(songs.count) songs"),
                placeholderName: player.radioPlaylistName
            ) {
                Button { player.playRadioPlaylistFromIndex(0) } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(songs.isEmpty)
                Button {
                    player.playShuffled(songs, source: source)
                    player.isRadioMode = true
                } label: { Label("Shuffle", systemImage: "shuffle") }
                    .disabled(songs.isEmpty)
                SaveAsPlaylistButton(isSaving: isSaving, isSaved: isSaved, accent: accentColor) {
                    Task { await save() }
                }
                .minimumScaleFactor(0.8)
                .frame(width: 180)
                .disabled(songs.isEmpty || isAwaitingSongs)
                Button {
                    player.refreshRadioQueue()
                    isSaved = false   // new songs, a new version to save
                } label: { Label("Refresh Songs", systemImage: "arrow.trianglehead.2.clockwise") }
                    .labelStyle(.iconOnly)
                    .help("Refresh Songs")
                    .disabled(songs.isEmpty)
            }
            Divider()
            if isAwaitingSongs {
                MacLoadingState()
            } else {
                MacSongTable(songs: songs, source: source)
            }
        }
        .navigationTitle(player.radioPlaylistName)
        // A row double-clicked plays with the radio's source: keep it going as a radio, as
        // the phone's rows do.
        .onChange(of: player.playbackSource) { _, playing in
            if playing == source { player.isRadioMode = true }
        }
    }

    /// The radio as a playlist, its cover along with it.
    private func save() async {
        guard !isSaving, !songs.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        guard let playlistId = await player.saveRadioPlaylist() else {
            ToastManager.shared.show(String(localized: "Couldn’t save radio"), icon: "exclamationmark.triangle.fill")
            return
        }
        isSaved = true
        ToastManager.shared.show(String(localized: "Saved to your playlists"))
        let spec = RadioCoverSpec(songs: songs,
                                  fallbackName: player.radioPlaylistName.replacingOccurrences(of: "Radio: ", with: ""))
        guard let cover = await spec.jpeg(), let server = ServerManager.shared.currentServer else { return }
        await PlaylistCovers.upload(cover, playlistId: playlistId, server: server)
    }
}

/// Start Radio, asking first when this song's radio already exists — still in hand, or saved
/// as a playlist — as the phone does. The question is put by the player bar.
@MainActor @Observable final class MacRadioStarter {
    static let shared = MacRadioStarter()
    struct Existing { let song: Song; let name: String; let playlistId: String? }
    var existing: Existing?

    func start(_ song: Song) {
        let player = AudioPlayer.shared
        let name = "Radio: \(song.title)"
        if player.radioPlaylistName == name && !player.radioPlaylistSongs.isEmpty {
            existing = Existing(song: song, name: name, playlistId: nil)
            return
        }
        Task {
            if let server = ServerManager.shared.currentServer,
               let saved = try? await SubsonicClient.shared.getPlaylists(server: server).first(where: { $0.name == name }) {
                existing = Existing(song: song, name: saved.name, playlistId: saved.id)
            } else {
                player.startRadioFromSong(song)
            }
        }
    }
}

/// The pages a "Playing from" leads to that the album, artist and playlist ids don't: the
/// radio, a mix, a genre, a Wrapped, favourites and recently played.
private struct MacSourceNavigation: ViewModifier {
    @Binding var path: NavigationPath
    @Binding var section: MacSection?
    @State private var player = AudioPlayer.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: player.pendingRadioOpen) { _, open in
                guard open else { return }
                player.pendingRadioOpen = false
                reveal()
                path.append(MacRadioRoute())
            }
            .onChange(of: player.pendingMixId) { _, id in
                guard let id else { return }
                player.pendingMixId = nil
                reveal()
                if id == "radar" {
                    section = .radar
                } else if let mix = MixGenerator.shared.mixes.first(where: { $0.id == id }) {
                    path.append(mix)
                }
            }
            .onChange(of: player.pendingGenreName) { _, name in
                guard let name else { return }
                player.pendingGenreName = nil
                reveal()
                path.append(MacGenre(name: name))
            }
            .onChange(of: player.pendingWrappedPeriod) { _, period in
                guard let period else { return }
                player.pendingWrappedPeriod = nil
                reveal()
                path.append(period)
            }
            .onChange(of: player.pendingFavoritesOpen) { _, open in
                guard open else { return }
                player.pendingFavoritesOpen = false
                reveal()
                section = .favorites
            }
            .onChange(of: player.pendingRecentlyPlayedOpen) { _, open in
                guard open else { return }
                player.pendingRecentlyPlayedOpen = false
                reveal()
                section = .recentlyPlayed
            }
    }

    /// Anything opened has to be visible, and the lyrics screen covers the whole window.
    private func reveal() {
        if player.isShowingNowPlaying {
            withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying = false }
        }
    }
}

extension View {
    func macSourceNavigation(path: Binding<NavigationPath>, section: Binding<MacSection?>) -> some View {
        modifier(MacSourceNavigation(path: path, section: section))
    }
}

extension PlaybackSource {
    /// Opens where the music is playing from, as tapping "Playing from" does on the phone.
    @MainActor func open() {
        let player = AudioPlayer.shared
        switch self {
        case .album(let id, _): player.pendingAlbumId = id
        case .artist(let id, _): player.pendingArtistId = id
        case .playlist(let id, _): player.pendingPlaylistId = id
        case .mix(let id, _): player.pendingMixId = id
        case .wrapped(let period): player.pendingWrappedPeriod = period
        case .genre(let name): player.pendingGenreName = name
        case .favorites: player.pendingFavoritesOpen = true
        case .recentlyPlayed: player.pendingRecentlyPlayedOpen = true
        case .radio(let name):
            guard player.radioPlaylistName != name else { player.pendingRadioOpen = true; return }
            // The radio in hand is another one now: this one's saved playlist, if it was saved.
            Task {
                if let server = ServerManager.shared.currentServer,
                   let saved = try? await SubsonicClient.shared.getPlaylists(server: server).first(where: { $0.name == name }) {
                    player.pendingPlaylistId = saved.id
                } else {
                    player.pendingRadioOpen = true
                }
            }
        // Frequently Played has no page on the Mac; the queue and autoplay are the pane itself.
        case .frequentlyPlayed, .queue, .autoplay, .search, .songs, .unknown: break
        }
    }

    /// Whether `open()` leads anywhere on the Mac.
    var opensOnMac: Bool {
        switch self {
        case .frequentlyPlayed, .queue, .autoplay: return false
        default: return isNavigable
        }
    }
}
