import SwiftUI

/// The window's permanent navigation, and where the server identity lives.
struct MacSidebar: View {
    @Binding var section: MacSection?
    /// The section already showing, clicked again: back to its top, as a tab bar does.
    var reselect: () -> Void = {}
    @State private var serverManager = ServerManager.shared
    @State private var settings = AppSettings.shared
    @State private var player = AudioPlayer.shared
    @State private var playlists: [Playlist] = []

    var body: some View {
        // The footer under the list, not a safe-area inset: as an inset the playlists
        // scrolled on under the server picker and the two were drawn over each other.
        VStack(spacing: 0) {
        // Above the list rather than an inset over it: as an inset the list scrolled on
        // under the wordmark and the search field, drawn through them.
        header
        List(selection: $section) {
            ForEach([MacSection.home, .mixes, .radar, .wrapped]) { item in
                row(item)
            }
            Section("Library") {
                ForEach([MacSection.songs, .favorites, .recentlyPlayed, .playlists, .albums, .artists, .genres, .downloads]) { item in
                    row(item)
                }
            }
            // The playlists you pinned — here rather than buried in a grid, which is the
            // whole point of pinning one. They arrive from the phone through iCloud.
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { playlist in
                        Button {
                            player.pendingPlaylistId = playlist.id
                        } label: {
                            Label {
                                Text(playlist.name).lineLimit(1)
                            } icon: {
                                CoverArtImage(coverArt: playlist.coverArt, size: 16, cornerRadius: 3,
                                              placeholderName: playlist.name)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // The window's gradient runs *through* the sidebar. Left to itself a sidebar draws
        // its own vibrant material, which is exactly the seam that made the three regions
        // read as three panels bolted together.
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
            footer
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.vertical, 6)
        }
        // The same fixed room as the pages, so the wordmark doesn't jump either.
        .safeAreaPadding(.top, MacWindowState.shared.isFullScreen ? 20 : MacRootView.topRoom)
        .ignoresSafeArea(.container, edges: .top)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        .task(id: serverManager.currentServer?.id) { await loadPlaylists() }
    }

    /// The symbol in the accent, set by hand: left to the sidebar it took the accent at low
    /// strength and only the selected row's showed, barely.
    private func row(_ item: MacSection) -> some View {
        Label {
            Text(item.label)
        } icon: {
            Image(systemName: item.symbol)
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole row answers a second click, not just the glyphs of its label.
        .contentShape(Rectangle())
        .tag(item)
        .simultaneousGesture(TapGesture().onEnded { if section == item { reselect() } })
    }

    /// Where a Mac app keeps the account it is signed into, and the settings that go with
    /// it: bottom-left, out of the way, in the same place every time.
    private var footer: some View {
        HStack(spacing: 4) {
            MacServerPicker()
            Spacer(minLength: 0)
            MacOptionsMenu()
                .padding(.trailing, 12)
        }
    }

    private var pinned: [Playlist] {
        playlists.filter { settings.isPinned($0.id) }
    }

    private func loadPlaylists() async {
        guard let server = serverManager.currentServer else { return }
        playlists = (try? await SubsonicClient.shared.getPlaylists(server: server)) ?? []
    }

    /// The wordmark, in the space the hidden title bar frees up. Search lives in the title
    /// bar's row above the content (`MacSearchBar`).
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("aura")
                    .auraDisplay(30)
                    .foregroundStyle(.primary)
                Spacer()
                MacSidebarButton()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }
}

/// Folds the sidebar away or brings it back: in its header while it shows, beside the
/// window's buttons while it's folded. `⌃⌘S` from the View menu does the same.
struct MacSidebarButton: View {
    /// Over the page rather than in the sidebar: drawn as the back button is, so the two
    /// read as a pair instead of a bare glyph left in the corner.
    var floating = false
    @State private var preferences = MacPreferences.shared

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) { preferences.sidebarVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(floating ? .primary : .secondary)
                .frame(width: floating ? 30 : 28, height: floating ? 30 : 28)
                .background { if floating { Circle().fill(.regularMaterial) } }
                .overlay { if floating { Circle().stroke(.primary.opacity(0.10), lineWidth: 0.5) } }
                .contentShape(Circle())
        }
        .buttonStyle(MacPressStyle())
        .help(preferences.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }
}
