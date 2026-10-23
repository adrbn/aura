import SwiftUI

/// The window's transport, across the full width at the bottom.
///
/// Three columns of fixed width, not a stack of flexible spacers: the transport has to stay
/// dead centre in the *window* whatever the title is called, and the only way to guarantee
/// that is to give the flanks equal weight rather than letting the content decide.
struct MacPlayerBar: View {
    @State private var player = AudioPlayer.shared
    @State private var showEqualizer = false

    /// Where the scrubber sits while it is being dragged.
    ///
    /// Playback keeps reporting its own position throughout, so binding the slider straight
    /// to `currentTime` would let each report yank the knob out from under the pointer.
    @State private var scrubbing: Double?
    @Environment(\.colorScheme) private var scheme

    private var song: Song? { player.currentSong }
    private let flank: CGFloat = 320

    var body: some View {
        HStack(spacing: 20) {
            nowPlaying
            centre
            secondary
        }
        .padding(.horizontal, 20)
        // Fills the window. Without this the fixed flanks bounded the whole bar to about
        // 1300pt, so on a wider window it floated in the middle with the library visible
        // beside it and running on underneath — it has to be the floor, not a panel.
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        // A wash rather than a bar. It has to separate itself from the artwork scrolling
        // behind it without becoming a second, opaque surface.
        .background(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
        }
        .popover(isPresented: $showEqualizer, arrowEdge: .top) { MacEqualizerView() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // While this Mac plays on another device, or another plays on it, the band says so.
            if let band = RemoteLink.shared.bandText {
                RemoteBand(text: band.text, systemImage: band.symbol)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.smooth(duration: 0.35), value: RemoteLink.shared.bandText?.text)
    }

    // MARK: Left — what is playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Button {
                guard song != nil else { return }
                withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying.toggle() }
            } label: {
                CoverArtImage(coverArt: song?.coverArt, size: 60, cornerRadius: 7)
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
            .help("Now Playing")

            VStack(alignment: .leading, spacing: 3) {
                // Both lead somewhere, as they do on the phone. The bar sits outside the
                // navigation stack, so they set the player's pending id and let
                // MacPendingNavigation resolve and push it.
                linkedText(song?.title ?? String(localized: "Nothing playing"),
                           size: 13, weight: .semibold, colour: .primary) {
                    guard let albumId = song?.albumId else { return }
                    player.pendingAlbumId = albumId
                }
                // Each credited artist separately: a collaboration has more than one name
                // worth going to, and one link across all of them only ever reached the first.
                MacArtistLinks(song: song)
            }

            if song != nil {
                Button { player.toggleFavorite() } label: {
                    Image(systemName: song?.starred != nil ? "heart.fill" : "heart")
                        .font(.system(size: 12))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: song?.starred != nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(song?.starred != nil ? Color.appAccent : .secondary)
                .help("Favourite")
            }
            Spacer(minLength: 0)
        }
        .frame(width: flank, alignment: .leading)
        .overlay { MacRightClick { song.map(menu(for:)) } }
    }

    /// The song's menu, built in AppKit so it can open upward: the bar sits at the foot of
    /// the screen, where a SwiftUI menu slides up over the pointer instead.
    private func menu(for song: Song) -> NSMenu {
        let menu = NSMenu()
        if let albumId = song.albumId {
            menu.add(String(localized: "Go to Album")) { player.pendingAlbumId = albumId }
        }
        if let artistId = song.artistId {
            menu.add(String(localized: "Go to Artist")) { player.pendingArtistId = artistId }
        }
        menu.add(String(localized: "Start Radio")) { player.startRadioFromSong(song) }
        menu.addItem(.separator())
        menu.add(song.starred != nil ? String(localized: "Unfavourite") : String(localized: "Favourite")) { player.toggleFavorite() }
        let ratings = SongRatings.shared, current = ratings.rating(for: song)
        let rating = NSMenu()
        for stars in 0...5 {
            let item = rating.add(stars == 0 ? String(localized: "No Rating") : String(repeating: "★", count: stars)) {
                ratings.set(stars, for: song)
            }
            item.state = stars == current ? .on : .off
        }
        let ratingItem = NSMenuItem(title: String(localized: "Rating"), action: nil, keyEquivalent: "")
        ratingItem.submenu = rating
        menu.addItem(ratingItem)
        let downloads = DownloadManager.shared
        if downloads.isDownloaded(song.id) {
            menu.add(String(localized: "Remove Download")) { downloads.deleteSong(song.id) }
        } else {
            menu.add(String(localized: "Download")) { Task { await downloads.downloadAlbum([song]) } }
        }
        return menu
    }

    // MARK: Centre — transport and scrubber

    private var centre: some View {
        VStack(spacing: 7) {
            HStack(spacing: 24) {
                iconButton("shuffle", active: player.isShuffled, help: "Shuffle") {
                    player.toggleShuffle()
                }
                iconButton("backward.fill", size: 16, help: "Previous") { player.previous() }

                // The one control that has to be found without looking.
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(Color.canvas)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.primary))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(song == nil)
                .opacity(song == nil ? 0.4 : 1)
                .help(player.isPlaying ? "Pause" : "Play")

                iconButton("forward.fill", size: 16, help: "Next") { player.next() }
                iconButton(player.repeatMode == .one ? "repeat.1" : "repeat",
                           active: player.repeatMode != .off, help: "Repeat") { player.cycleRepeat() }
            }

            scrubber
        }
        // Capped so the scrubber doesn't stretch across an ultrawide, then handed the rest
        // of the slack so the transport stays centred in the window rather than in whatever
        // the flanks happen to leave.
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(MacFormat.time(scrubbing ?? player.currentTime))
                .frame(width: 38, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.currentTime },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    // Seek on release, not continuously: every intermediate value would be
                    // another seek, and the player would spend the whole drag catching up.
                    guard !editing, let target = scrubbing else { return }
                    player.seek(to: target)
                    scrubbing = nil
                }
            )
            .controlSize(.mini)
            Text("-" + MacFormat.time(max(0, player.duration - (scrubbing ?? player.currentTime))))
                .frame(width: 38, alignment: .leading)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
        .disabled(song == nil || player.duration <= 0)
    }

    // MARK: Right — lyrics, EQ, queue, volume

    private var secondary: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            iconButton("quote.bubble", active: player.isShowingNowPlaying, help: "Lyrics") {
                guard song != nil else { return }
                withAnimation(.easeInOut(duration: 0.28)) { player.isShowingNowPlaying.toggle() }
            }
            iconButton("slider.horizontal.3", active: EqualizerManager.shared.isEnabled,
                       help: "Equaliser") { showEqualizer.toggle() }
            iconButton("list.bullet", active: MacQueuePanel.shared.isShown, help: "Queue") { MacQueuePanel.shared.isShown.toggle() }
            devicePicker

            HStack(spacing: 6) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 96)
            }
            .help("Volume")
        }
        .frame(width: flank, alignment: .trailing)
    }

    /// Where the music plays: this Mac, or another Aura on the same Wi-Fi.
    @ViewBuilder
    private var devicePicker: some View {
        let link = RemoteLink.shared
        if !link.devices.isEmpty || link.connected != nil {
            Menu {
                Button { link.playHere() } label: {
                    Label("This Mac", systemImage: link.connected == nil ? "checkmark" : "macbook")
                }
                ForEach(link.devices, id: \.self) { RemoteDeviceItem(device: $0) }
                Divider()
                // Speakers, headphones and AirPlay are the Mac's own to choose, in its Sound settings.
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                } label: {
                    Label("AirPlay & Bluetooth", systemImage: "airplayaudio")
                }
            } label: {
                Image(systemName: link.connected?.symbol ?? "hifispeaker.and.homepod")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(link.connected != nil ? Color.appAccent : .secondary)
            .help("Play on")
        }
    }

    private var volumeSymbol: String {
        switch player.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    /// Reads as plain text, a link that doesn't shout, which is what a transport bar wants.
    @ViewBuilder
    private func linkedText(_ text: String, size: CGFloat, weight: Font.Weight,
                            colour: HierarchicalShapeStyle, action: @escaping () -> Void) -> some View {
        if text.isEmpty {
            EmptyView()
        } else {
            HoverLink(text: text, size: size, weight: weight, colour: colour, action: action)
        }
    }

    private func iconButton(_ symbol: String, size: CGFloat = 16, active: Bool = false,
                            help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.appAccent : .secondary)
        .help(help)
    }

}

private struct HoverLink: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let colour: HierarchicalShapeStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: size, weight: weight))
                .macHoverTint(colour)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

/// A menu item that runs a closure.
private final class MacMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let handler = MacMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(MacMenuAction.fire), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler  // the item keeps its handler alive
        addItem(item)
        return item
    }
}

/// Right-click opens `menu` with its top-left corner at the pointer, or its bottom-left
/// when the screen has no room below. Left clicks pass through to the views beneath.
struct MacRightClick: NSViewRepresentable {
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.build = menu }

    final class Catcher: NSView {
        var build: () -> NSMenu? = { nil }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let type = NSApp.currentEvent?.type
            return type == .rightMouseDown || type == .rightMouseUp ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = build(), let window else { return }
            let at = convert(event.locationInWindow, from: nil)
            let room = window.convertPoint(toScreen: event.locationInWindow).y - (window.screen?.visibleFrame.minY ?? 0)
            let height = menu.size.height
            let top = room < height ? (isFlipped ? at.y - height : at.y + height) : at.y
            menu.popUp(positioning: nil, at: NSPoint(x: at.x, y: top), in: self)
        }
    }
}
