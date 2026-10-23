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
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { MacSettingsPanel.shared.isShown.toggle() }
                .keyboardShortcut(",")
        }

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
            Button("Repeat") { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Volume Up") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("Show Lyrics") { player.isShowingNowPlaying.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(player.currentSong == nil)
            Button("Go to Album") { player.pendingAlbumId = player.currentSong?.albumId }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(player.currentSong?.albumId == nil || player.currentSong?.isPreview == true)
            Button("Go to Artist") { player.pendingArtistId = player.currentSong?.artistId }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(player.currentSong?.artistId == nil || player.currentSong?.isPreview == true)

            Divider()

            Button(player.currentSong?.starred != nil ? "Unfavourite" : "Favourite") {
                player.toggleFavorite()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(player.currentSong == nil)
            MacRatingMenu(songs: player.currentSong.map { [$0] } ?? [])

            Divider()

            // A turntable's pitch, for this song only, as on the phone.
            Button("Pitch Up") { player.pitchSemitones += 1 }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(player.currentSong == nil || player.pitchSemitones >= 6)
            Button("Pitch Down") { player.pitchSemitones -= 1 }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(player.currentSong == nil || player.pitchSemitones <= -6)
            Button("Normal Pitch") {
                player.pitchSemitones = 0
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(player.pitchSemitones == 0)
        }
    }
}

/// Space plays and pauses wherever the focus is. As a menu shortcut alone it never fired:
/// the focused list or table took the key first and spent it on its own selection.
enum MacSpaceKey {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let typing = event.window?.firstResponder is NSText
            guard event.keyCode == 49, !typing,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  AudioPlayer.shared.currentSong != nil else { return event }
            AudioPlayer.shared.togglePlayPause()
            return nil
        }
    }
}
