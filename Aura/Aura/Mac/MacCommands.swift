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

        CommandGroup(after: .toolbar) {
            // The window buttons hide themselves in full screen, which is the only way to
            // be rid of them — they are the system's, not the app's.
            Button("Enter Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Button("Toggle Sidebar") {
                MacPreferences.shared.sidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Menu("Cover Size") {
                ForEach(MacCoverSize.allCases) { size in
                    Button(size.label) { MacPreferences.shared.coverSize = size }
                        .keyboardShortcut(size.shortcut, modifiers: .command)
                }
            }
        }

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
