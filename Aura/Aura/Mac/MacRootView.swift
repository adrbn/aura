import SwiftUI

struct MacRootView: View {
    var body: some View {
        Text("Aura")
            .font(.largeTitle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Menu-bar commands. Playback belongs in the menu bar on the Mac — it is where the
/// keyboard shortcuts are discovered, and the media keys are handled separately by
/// `MPRemoteCommandCenter`, which the shared player already sets up.
struct MacCommands: Commands {
    let player: AudioPlayer

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") {
                player.isPlaying ? player.pause() : player.play()
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("Next") { player.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
        }
    }
}
