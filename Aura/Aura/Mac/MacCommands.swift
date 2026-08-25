import SwiftUI

/// Menu-bar commands.
///
/// The media keys are handled separately, by the `MPRemoteCommandCenter` the shared player
/// already registers — that is what makes F7/F8/F9 and the Now Playing tile in Control
/// Centre work without a line of Mac-specific code. These are the in-app shortcuts, and the
/// menu is mostly how anyone discovers them.
struct MacCommands: Commands {
    let player: AudioPlayer

    var body: some Commands {
        // Replaces the New Window item: this app has one window and nothing to put in a
        // second one.
        CommandGroup(replacing: .newItem) { }

        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.currentSong == nil)

            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("Shuffle") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(player.currentSong?.starred != nil ? "Unfavourite" : "Favourite") {
                player.toggleFavorite()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(player.currentSong == nil)
        }
    }
}
