import SwiftUI

/// The window's permanent navigation, and where the server identity lives.
struct MacSidebar: View {
    @Binding var section: MacSection?
    @Binding var query: String
    @FocusState private var searching: Bool
    @State private var serverManager = ServerManager.shared
    @State private var settings = AppSettings.shared
    @State private var player = AudioPlayer.shared
    @State private var playlists: [Playlist] = []

    var body: some View {
        List(selection: $section) {
            ForEach([MacSection.home, .mixes]) { item in
                Label(item.label, systemImage: item.symbol).tag(item)
            }
            Section("Library") {
                ForEach([MacSection.songs, .playlists, .albums, .artists]) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
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
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task(id: serverManager.currentServer?.id) { await loadPlaylists() }
    }

    /// Where a Mac app keeps the account it is signed into, and the settings that go with
    /// it: bottom-left, out of the way, in the same place every time.
    private var footer: some View {
        HStack(spacing: 4) {
            MacServerPicker()
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
            Text("aura")
                .auraDisplay(30)
                .foregroundStyle(.primary)
            searchField
        }
        .padding(.horizontal, 14)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text("Search").font(.system(size: 12)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searching)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(searching ? 0.12 : 0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(searching ? Color.appAccent.opacity(0.8) : .clear)
        )
    }
}
