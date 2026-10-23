import SwiftUI

/// The window's permanent navigation, and where the server identity lives.
struct MacSidebar: View {
    @Binding var section: MacSection?
    @Binding var query: String
    /// The section already showing, clicked again: back to its top, as a tab bar does.
    var reselect: () -> Void = {}
    @FocusState private var searching: Bool
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
                ForEach([MacSection.songs, .playlists, .albums, .artists, .downloads]) { item in
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

    /// Wordmark and search, in the space the hidden title bar frees up.
    ///
    /// Search belongs here rather than above the content: it is a fixture of the app, not of
    /// whatever page you are on, and the Mac's own music app puts it in exactly this corner.
    /// It also gives the content area its full height back.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("aura")
                    .auraDisplay(30)
                    .foregroundStyle(.primary)
                Spacer()
                MacSidebarButton()
            }
            searchField
        }
        .padding(.horizontal, 14)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(searching ? Color.appAccent : .secondary)
            TextField("", text: $query, prompt: Text("Search").font(.system(size: 13)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .onExitCommand { searching = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                // The shortcut, shown until it is needed — the Mac convention for a field
                // you are expected to reach for by keyboard.
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.primary.opacity(searching ? 0.13 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searching ? Color.appAccent.opacity(0.85) : .primary.opacity(0.06),
                              lineWidth: searching ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: searching)
        .animation(.easeOut(duration: 0.15), value: query.isEmpty)
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
