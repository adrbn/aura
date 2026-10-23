import SwiftUI

/// The menu-bar mini player: what's playing and its transport, without bringing the window
/// back. Same player as the window; nothing here keeps state of its own.
struct MacMenuBarPlayer: View {
    @State private var player = AudioPlayer.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            if let song = player.currentSong {
                CoverArtImage(coverArt: song.coverArt ?? song.albumId, size: 248, cornerRadius: 10,
                              placeholderName: song.album ?? song.title)
                VStack(spacing: 2) {
                    Text(song.title).font(.headline).lineLimit(1)
                    Text(song.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                progress
                transport
            } else {
                Text("Nothing playing").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            Divider()
            HStack {
                Button("Open Aura") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var progress: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { player.currentTime },
                                  set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 1))
                .controlSize(.mini)
            HStack {
                Text(MacFormat.time(player.currentTime))
                Spacer()
                Text("-" + MacFormat.time(max(0, player.duration - player.currentTime)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .font(.title3)
        .buttonStyle(.borderless)
    }
}
