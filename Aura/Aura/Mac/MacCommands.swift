import SwiftUI

/// Menu-bar commands.
///
/// The media keys are handled separately, by the `MPRemoteCommandCenter` the shared player
/// already registers — that is what makes F7/F8/F9 and the Now Playing tile in Control
/// Centre work without a line of Mac-specific code. These are the in-app shortcuts, and the
/// menu is mostly how anyone discovers them.
struct MacCommands: Commands {
    let player: AudioPlayer
    @Binding var syncing: Song?
    @Environment(\.openWindow) private var openWindow

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
            Button("Sync Lyrics…") { syncing = player.currentSong }
                .disabled(player.currentSong == nil || player.lyrics.isEmpty || syncing != nil)
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

            Divider()

            // Listen Together over FaceTime or Messages, as from the phone's Now Playing.
            if SharePlay.shared.isActive {
                Button("Leave SharePlay") { SharePlay.shared.leave() }
            } else {
                ShareLink(item: ListenTogetherInvite(), preview: SharePreview("Listen Together on Aura")) {
                    Text("SharePlay")
                }
            }
        }

        #if !APPSTORE_BUILD
        // Developer options only, as on the phone: Soulseek search and slskd's transfers.
        CommandGroup(before: .windowList) {
            if AppSettings.shared.betaFeaturesEnabled {
                Button("Search Soulseek") { openWindow(id: "soulseek") }
                Divider()
            }
        }
        #endif
    }
}

/// Space plays and pauses wherever the focus is. As a menu shortcut alone it never fired:
/// the focused list or table took the key first and spent it on its own selection.
/// A text field keeps the key only once something is typed in it: the window opens with the
/// search field focused, and an empty field has no use for a space.
enum MacSpaceKey {
    private static var monitor: Any?
    private static var clicks: Any?
    /// Set while the lyrics sync sheet is open: Space taps Now there instead.
    static var tapNow: (() -> Void)?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let typing = (event.window?.firstResponder as? NSText).map { !$0.string.isEmpty } ?? false
            guard event.keyCode == 49, !typing,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            if let tapNow {
                tapNow()
                return nil
            }
            guard AudioPlayer.shared.currentSong != nil else { return event }
            AudioPlayer.shared.togglePlayPause()
            return nil
        }
        // A click anywhere outside the field being typed in leaves it, as Escape does.
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSText,
                  let field = editor.delegate as? NSView else { return event }
            if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
}
