import SwiftUI

/// One tile of the playlists grid: a playlist, or a folder gathering "Folder/Name" playlists.
private enum MacPlaylistEntry: Identifiable {
    case folder(path: String, name: String, count: Int)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .folder(let path, _, _): return "folder:" + path
        case .playlist(let playlist): return playlist.id
        }
    }
}

/// Set by Undo, read by the delete waiting out its window.
private final class MacUndoFlag { var undone = false }

/// Renaming and deleting playlists, from the grid or a playlist's own page. Deleted ones go
/// at once, and from the server once Undo has had its five seconds.
@Observable
private final class MacPlaylistEdits {
    static let shared = MacPlaylistEdits()
    /// Kept out of the grid from the moment they're deleted: a reload in the five seconds
    /// would otherwise bring them back.
    private(set) var hidden: Set<String> = []

    func delete(_ doomed: [Playlist]) {
        let ids = Set(doomed.map(\.id))
        let flag = MacUndoFlag()
        withAnimation { hidden.formUnion(ids) }
        ToastManager.shared.show(String(localized: "\(doomed.count) playlist(s) deleted"), icon: "trash.fill", duration: 5,
                                 action: (String(localized: "Undo"), {
                                     flag.undone = true
                                     withAnimation { self.hidden.subtract(ids) }
                                 }))
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard !flag.undone, let server = ServerManager.shared.currentServer else { return }
            for id in ids { try? await SubsonicClient.shared.deletePlaylist(server: server, id: id) }
        }
    }

    /// False, said in a toast, when the server refused it.
    static func rename(_ playlist: Playlist, to name: String) async -> Bool {
        guard let server = ServerManager.shared.currentServer else { return false }
        do {
            try await SubsonicClient.shared.updatePlaylist(server: server, id: playlist.id, name: name)
            return true
        } catch {
            ToastManager.shared.show(String(localized: "Couldn't save the playlist"), icon: "exclamationmark.triangle.fill")
            return false
        }
    }
}

private extension View {
    /// The delete confirmation, for one playlist or several.
    func macPlaylistDeleteAlert(_ deleting: Binding<[Playlist]>) -> some View {
        alert(deleting.wrappedValue.count == 1 ? String(localized: "Delete “\(deleting.wrappedValue[0].name)”?")
                                               : String(localized: "Delete \(deleting.wrappedValue.count) Playlist(s)?"),
              isPresented: Binding(get: { !deleting.wrappedValue.isEmpty }, set: { if !$0 { deleting.wrappedValue = [] } }),
              presenting: deleting.wrappedValue) { doomed in
            Button("Delete", role: .destructive) { MacPlaylistEdits.shared.delete(doomed) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This will permanently delete the selected playlists from the server. You can undo this briefly after deletion.")
        }
    }
}

struct MacPlaylistsView: View {
    @State private var serverManager = ServerManager.shared
    @State private var allPlaylists: [Playlist] = []
    @State private var edits = MacPlaylistEdits.shared
    @State private var player = AudioPlayer.shared
    @State private var isLoading = false
    @State private var settings = AppSettings.shared
    /// The phone's key, so the sort is chosen the same way on both.
    @AppStorage("playlists_sort") private var sortOrder: PlaylistSortOrder = .recentlyChanged
    /// The folder being browsed, as a name prefix ending in "/" ("" is the top).
    @State private var folder = ""
    /// The playlist being renamed; `isCreating` names a new one instead.
    @State private var renaming: Playlist?
    @State private var isCreating = false
    @State private var newName = ""
    @State private var deleting: [Playlist] = []
    @State private var isFindingDuplicates = false
    @State private var filter: PlaylistFilter = .all
    @State private var downloadedIds: Set<String> = []
    /// The full path ("Mixes/") of the folder being renamed, or deleted.
    @State private var renamingFolder: String?
    @State private var folderNewName = ""
    @State private var deletingFolder: String?

    private var playlists: [Playlist] { allPlaylists.filter { !edits.hidden.contains($0.id) } }

    /// The phone's filters, read the phone's way.
    private var filterContext: PlaylistFilterContext {
        PlaylistFilterContext(username: serverManager.currentServer?.username,
                              pinned: settings.pinnedPlaylistIds, downloaded: downloadedIds)
    }

    /// Moves when a song lands on this Mac or the offline snapshots change: what Downloaded reads.
    private var downloadSignature: Int {
        DownloadManager.shared.downloadedSongs.count
            &+ OfflinePlaylistsStore.shared.playlists.reduce(0) { $0 &+ $1.songs.count }
    }

    private var filtered: [Playlist] {
        guard filter != .all else { return playlists }
        let context = filterContext
        return playlists.filter { context.matches($0, filter) }
    }

    /// Pinned playlists lead at the top level, then this level's folders, then its playlists.
    private var entries: [MacPlaylistEntry] {
        let pinned = folder.isEmpty ? MacPlaylistOrder.pinnedFirst(filtered).filter { settings.isPinned($0.id) } : []
        let level = MacPlaylistOrder.level(filtered.filter { !settings.isPinned($0.id) }, in: folder)
        return pinned.map { .playlist($0) }
            + level.folders.map { .folder(path: folder + $0.name + "/", name: $0.name, count: $0.count) }
            + MacPlaylistOrder.sorted(level.loose, by: sortOrder).map { .playlist($0) }
    }

    private var folderName: String { String(folder.dropLast().split(separator: "/").last ?? "") }

    var body: some View {
        // MacGrid's title row is drawn here the same way, so the filters can sit under it
        // and the empty state can have its button.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(folder.isEmpty ? "Playlists" : "\(folderName)").auraDisplay(52)
                Spacer()
                headerActions
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 4)
            filterChips
            if !isLoading && playlists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists", systemImage: "music.note.list")
                } actions: {
                    Button("New Playlist") { startCreating() }
                }
            } else {
                MacGrid(items: entries, isLoading: isLoading, emptyMessage: "No playlists") { entry in
                    switch entry {
                    case .folder(let path, let name, let count): folderTile(path: path, name: name, count: count)
                    case .playlist(let playlist): playlistTile(playlist)
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .task { await load() }
        .onChange(of: downloadSignature, initial: true) {
            downloadedIds = PlaylistFilterContext.downloadedPlaylistIds()
        }
        .alert(deletingFolder.map { String(localized: "Delete the folder “\(String($0.dropLast().split(separator: "/").last ?? ""))”?") } ?? "",
               isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
               presenting: deletingFolder) { path in
            Button("Keep the Playlists") { Task { await ungroupFolder(path) } }
            Button("Delete the Playlists Too", role: .destructive) {
                MacPlaylistEdits.shared.delete(playlists.filter { $0.name.hasPrefix(path) })
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Keeping them moves them out of the folder.")
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil },
                                                     set: { if !$0 { renamingFolder = nil } })) {
            TextField("Folder Name", text: $folderNewName)
            Button("OK") {
                guard let path = renamingFolder else { return }
                Task { await renameFolder(path, to: folderNewName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(isCreating ? Text("New Playlist") : Text("Rename…"),
               isPresented: Binding(get: { isCreating || renaming != nil },
                                    set: { if !$0 { isCreating = false; renaming = nil } })) {
            TextField("Name", text: $newName)
            Button { Task { await commitName() } } label: { isCreating ? Text("Create") : Text("Save") }
            Button("Cancel", role: .cancel) {}
        }
        .macPlaylistDeleteAlert($deleting)
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            if !folder.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        folder = String(folder.dropLast().split(separator: "/").dropLast().map { $0 + "/" }.joined())
                    }
                } label: { Label("Back", systemImage: "chevron.left") }
            }
            Button { startCreating() } label: { Label("New Playlist", systemImage: "plus") }
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(PlaylistSortOrder.allCases, id: \.self) { order in
                        Label(LocalizedStringKey(order.rawValue), systemImage: order.icon).tag(order)
                    }
                }
                Divider()
                Button { Task { await findDuplicates() } } label: {
                    Label("Find Duplicates", systemImage: "doc.on.doc")
                }
                .disabled(isFindingDuplicates || playlists.isEmpty)
            } label: {
                Image(systemName: isFindingDuplicates ? "hourglass" : "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.large)
    }

    /// The phone's filter chips: only those that leave some playlists out, clicked again to clear.
    @ViewBuilder private var filterChips: some View {
        let chips = filterContext.offered(for: playlists, keeping: filter).filter { $0 != .all }
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    let isOn = chip == filter
                    QuietChip(title: chip.rawValue, isOn: isOn, showsClear: true) {
                        withAnimation(.easeInOut(duration: 0.2)) { filter = isOn ? .all : chip }
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
        }
    }

    private func folderTile(path: String, name: String, count: Int) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { folder = path }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "folder.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                    }
                    .macHoverLift()
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(count) playlists").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(MacPressStyle())
        .contextMenu { folderMenu(path: path, name: name) }
    }

    /// The phone's folder menu, but Select: the Mac grid has no multiple selection.
    @ViewBuilder
    private func folderMenu(path: String, name: String) -> some View {
        let inside = playlists.filter { $0.name.hasPrefix(path) }
        if inside.contains(where: { !settings.isPinned($0.id) }) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    for playlist in inside where !settings.isPinned(playlist.id) {
                        settings.togglePin(playlistId: playlist.id)
                    }
                }
            } label: { Label("Pin All", systemImage: "pin") }
        }
        Button {
            folderNewName = name
            renamingFolder = path
        } label: { Label("Rename Folder", systemImage: "pencil") }
        Button(role: .destructive) { deletingFolder = path } label: {
            Label("Delete Folder", systemImage: "trash")
        }
    }

    private func parentPath(of path: String) -> String {
        String(path.dropLast().split(separator: "/").dropLast().map { $0 + "/" }.joined())
    }

    /// The folder's playlists move up one level, the folder itself gone.
    private func ungroupFolder(_ path: String) async {
        guard let server = serverManager.currentServer else { return }
        for playlist in playlists where playlist.name.hasPrefix(path) {
            let renamed = parentPath(of: path) + playlist.name.dropFirst(path.count)
            try? await SubsonicClient.shared.updatePlaylist(server: server, id: playlist.id, name: renamed)
        }
        await load()
    }

    /// Renames every playlist under the folder, which is what renaming a folder means here.
    private func renameFolder(_ oldPath: String, to newName: String) async {
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, let server = serverManager.currentServer else { return }
        let newPath = parentPath(of: oldPath) + name + "/"
        guard newPath != oldPath else { return }
        for playlist in playlists where playlist.name.hasPrefix(oldPath) {
            let renamed = newPath + playlist.name.dropFirst(oldPath.count)
            try? await SubsonicClient.shared.updatePlaylist(server: server, id: playlist.id, name: renamed)
        }
        await load()
    }

    private func playlistTile(_ playlist: Playlist) -> some View {
        NavigationLink(value: playlist) {
            // Inside a folder the folder's path is the title already.
            MacCoverTile(coverArt: playlist.coverArt,
                         title: playlist.name.hasPrefix(folder) ? String(playlist.name.dropFirst(folder.count)) : playlist.name,
                         subtitle: playlist.songCount.map { String(localized: "\($0) songs") },
                         placeholderName: playlist.name)
                .overlay(alignment: .topTrailing) {
                    if settings.isPinned(playlist.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .padding(5)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .padding(6)
                    }
                }
        }
        .buttonStyle(MacPressStyle())
        .contextMenu {
            let source = PlaybackSource.playlist(id: playlist.id, name: playlist.name)
            Button { withSongs(of: playlist) { player.playSong($0[0], fromQueue: $0, startIndex: 0, source: source) } } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button { withSongs(of: playlist) { player.playShuffled($0, source: source) } } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            // Shuffled, as the phone adds a playlist to the queue.
            Button { withSongs(of: playlist) { player.addToQueue($0.shuffled()) } } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            Divider()
            MacPinButton(playlistId: playlist.id, asLabel: true)
            Button {
                newName = playlist.name
                renaming = playlist
            } label: { Label("Rename…", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { deleting = [playlist] } label: {
                Label("Delete Playlist", systemImage: "trash")
            }
        }
    }

    /// The playlist's songs, fetched for the tile's menu; nothing happens for an empty one.
    private func withSongs(of playlist: Playlist, _ act: @escaping ([Song]) -> Void) {
        Task {
            guard let server = serverManager.currentServer,
                  let songs = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id).entry,
                  !songs.isEmpty else { return }
            act(songs)
        }
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        isLoading = true
        defer { isLoading = false }
        allPlaylists = (try? await SubsonicClient.shared.getPlaylists(server: server)) ?? []
        // As on the phone: snapshot them for offline, and bring kept playlists' new songs down.
        OfflinePlaylistsStore.shared.refresh(from: allPlaylists)
        Task { await DownloadManager.shared.syncKeptPlaylists() }
    }

    /// A new playlist starts in the folder being browsed.
    private func startCreating() {
        newName = folder
        isCreating = true
    }

    /// A folder path typed into the name ("Folder/Name") files the playlist there.
    private func commitName() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let target = renaming
        guard !name.isEmpty, let server = serverManager.currentServer else { return }
        do {
            if let target {
                guard name != target.name else { return }
                if await MacPlaylistEdits.rename(target, to: name) { await load() }
            } else {
                let created = try await SubsonicClient.shared.createPlaylist(server: server, name: name, songIds: [])
                await load()
                AudioPlayer.shared.pendingPlaylistId = created.id
            }
        } catch {
            ToastManager.shared.show(target == nil ? String(localized: "Couldn't create the playlist")
                                                   : String(localized: "Couldn't save the playlist"),
                                     icon: "exclamationmark.triangle.fill")
        }
    }

    private func findDuplicates() async {
        guard let server = serverManager.currentServer else { return }
        isFindingDuplicates = true
        defer { isFindingDuplicates = false }
        let copies = await MacPlaylistOrder.duplicates(in: playlists, server: server)
        if copies.isEmpty {
            ToastManager.shared.show(String(localized: "No duplicates found"), icon: "checkmark")
        } else {
            deleting = copies
        }
    }
}

struct MacPlaylistDetailView: View {
    let playlist: Playlist
    @State private var serverManager = ServerManager.shared
    @State private var player = AudioPlayer.shared
    @State private var downloads = DownloadManager.shared
    @State private var songs: [Song] = []
    @State private var name: String?
    @State private var comment: String?
    @State private var coverArt: String?
    /// Changed after a new cover, so the header draws it rather than the cached one.
    @State private var coverId = UUID()
    @State private var loaded = false
    @State private var isEditing = false
    @State private var showAddSongs = false
    @State private var suggestions: [Song] = []
    @State private var deleting: [Playlist] = []
    @State private var edits = MacPlaylistEdits.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MacDetailHeader(
                coverArt: coverArt ?? playlist.coverArt,
                title: name ?? playlist.name,
                // The description, as on the phone, over the songs' count and length — from
                // the songs once they're here, so a removal shows in the count.
                subtitle: [comment.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
                           [(loaded ? songs.count : playlist.songCount).map { String(localized: "\($0) songs") },
                            MacFormat.duration(loaded ? songs.compactMap(\.duration).reduce(0, +) : playlist.duration)]
                               .compactMap { $0 }.joined(separator: " · ")]
                    .compactMap { $0 }.joined(separator: "\n"),
                placeholderName: playlist.name
            ) {
                Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                MacPinButton(playlistId: playlist.id, asLabel: true)
                Menu {
                    // Shuffled, as the phone adds a playlist to the queue.
                    Button { player.addToQueue(songs.shuffled()) } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }
                    .disabled(songs.isEmpty)
                    downloadItem
                    Toggle(isOn: Binding(get: { downloads.keptPlaylistIds.contains(playlist.id) },
                                         set: { downloads.setKeepDownloaded(playlist.id, $0) })) {
                        Label("Keep Downloaded", systemImage: "arrow.down.circle.dotted")
                    }
                    Divider()
                    Button { showAddSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                    Button { isEditing = true } label: { Label("Modify", systemImage: "pencil") }
                    Divider()
                    Button { Task { await changeCover() } } label: {
                        Label("Change Cover Art", systemImage: "photo")
                    }
                    Button { saveCover() } label: {
                        Label("Save Cover Art", systemImage: "square.and.arrow.down")
                    }
                    Button(role: .destructive) { Task { await removeCover() } } label: {
                        Label("Remove Cover Art", systemImage: "trash")
                    }
                    Divider()
                    Button(role: .destructive) { deleting = [playlist] } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
            }
            .id(coverId)
            Divider()
            if loaded {
                if songs.isEmpty {
                    emptyPrompt
                } else {
                    MacPlaylistSongTable(songs: $songs, source: .playlist(id: playlist.id, name: name ?? playlist.name),
                                         onEdit: save)
                }
                if !suggestions.isEmpty { suggestionsSection }
            } else {
                MacLoadingState()
            }
        }
        .background { ZStack { ArtworkCanvas(coverArt: playlist.coverArt, height: 640); MacFadingGrid() } }
        .navigationTitle(playlist.name)
        .task { await load() }
        .sheet(isPresented: $showAddSongs) {
            MacAddSongsSheet(playlistSongs: songs) { await add($0) }
        }
        .sheet(isPresented: $isEditing) {
            MacPlaylistEditSheet(playlistId: playlist.id, currentName: name ?? playlist.name,
                                 currentComment: comment ?? "") { newName, newComment in
                name = newName
                comment = newComment
            }
        }
        .macPlaylistDeleteAlert($deleting)
        // Deleted from here: back to where it was opened from.
        .onChange(of: edits.hidden.contains(playlist.id)) { _, gone in
            if gone { dismiss() }
        }
    }

    /// The phone's three states: cancel while it runs, done once it's all here, else start.
    @ViewBuilder private var downloadItem: some View {
        if downloads.isGroupDownloading(playlist.id) {
            Button(role: .destructive) { downloads.cancelGroupDownload(playlist.id) } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else if !songs.isEmpty, downloads.allDownloaded(songs.map(\.id)) {
            Button {} label: { Label("Downloaded", systemImage: "checkmark.circle.fill") }
                .disabled(true)
        } else {
            Button { Task { await downloads.downloadAlbum(songs, groupId: playlist.id) } } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(songs.isEmpty)
        }
    }

    private func load() async {
        guard let server = serverManager.currentServer else { return }
        let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
        songs = detail?.entry ?? []
        name = detail?.name
        comment = detail?.comment
        coverArt = detail?.coverArt
        loaded = true
        if suggestions.isEmpty { await refreshSuggestions() }
    }

    /// An empty playlist says so and offers the way to fill it.
    private var emptyPrompt: some View {
        ContentUnavailableView {
            Label("This playlist is empty", systemImage: "music.note.list")
        } description: {
            Text("Add songs here, or from any song's menu with Add to Playlist.")
        } actions: {
            Button { showAddSongs = true } label: { Label("Add Songs", systemImage: "plus") }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Suggestions").font(.title3.bold())
                Spacer()
                Button { Task { await refreshSuggestions() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh Suggestions")
                    .accessibilityLabel("Refresh Suggestions")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(suggestions) { song in
                        HStack(spacing: 4) {
                            MacSongRow(song: song)
                            Button { Task { await add(song) } } label: {
                                Image(systemName: "plus.circle")
                                    .font(.title3)
                                    .foregroundStyle(Color.appAccent)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add to Playlist")
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    /// Like a few of its songs, or what played lately when it is empty, as on the phone.
    private func refreshSuggestions() async {
        guard let server = serverManager.currentServer else { return }
        let picked = await PlaylistSuggester.suggest(server: server, for: songs)
        withAnimation { suggestions = picked }
    }

    private func add(_ song: Song) async {
        guard let server = serverManager.currentServer else { return }
        do {
            try await SubsonicClient.shared.addSongToPlaylist(server: server, playlistId: playlist.id, songId: song.id)
            withAnimation { suggestions.removeAll { $0.id == song.id } }
            await load()
        } catch {
            ToastManager.shared.show(String(localized: "Couldn't add the song"), icon: "exclamationmark.triangle")
        }
    }

    /// Through the same Navidrome call as the phone; the cached picture is dropped after.
    private func changeCover() async {
        guard let jpeg = MacCoverFile.pickJPEG(), let server = serverManager.currentServer,
              await PlaylistCovers.upload(jpeg, playlistId: playlist.id, server: server) else { return }
        await coverChanged()
    }

    private func removeCover() async {
        guard let server = serverManager.currentServer,
              await PlaylistCovers.remove(playlistId: playlist.id, server: server) else {
            ToastManager.shared.show(String(localized: "Couldn’t remove cover art"), icon: "exclamationmark.triangle.fill")
            return
        }
        await coverChanged()
        ToastManager.shared.show(String(localized: "Cover art removed"), icon: "checkmark")
    }

    private func coverChanged() async {
        if let cover = coverArt ?? playlist.coverArt { ArtworkCache.shared.removeImages(forCoverArt: cover) }
        await load()
        coverId = UUID()
    }

    /// A Wrapped playlist's drawn cover, else the server's picture.
    private func saveCover() {
        let title = name ?? playlist.name
        if let period = WrappedCovers.period(for: playlist.id) {
            let renderer = ImageRenderer(content: GeneratedCoverView(nature: .retrospective(period.coverLabel),
                                                                     size: 400, cornerRadius: 0))
            renderer.scale = 3
            if let image = renderer.nsImage { MacCoverFile.save(image, name: title) }
        } else {
            MacCoverFile.save(coverArt: coverArt ?? playlist.coverArt, name: title)
        }
    }

    /// Subsonic has no "move" and only removes by position, so an edit sends the whole list
    /// back in its new order, as saving a mix over its playlist does. On failure the list
    /// returns to `previous`.
    // ponytail: edits made faster than the server answers can land out of order; a save
    // queue if that ever shows.
    private func save(previous: [Song]) {
        Task {
            guard let server = serverManager.currentServer else { return }
            do {
                try await SubsonicClient.shared.createPlaylist(server: server, name: name ?? playlist.name,
                                                               songIds: songs.map(\.id), playlistId: playlist.id)
            } catch {
                songs = previous
                ToastManager.shared.show(String(localized: "Couldn't save the playlist"), icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func play(shuffled: Bool) {
        guard !songs.isEmpty else { return }
        let source = PlaybackSource.playlist(id: playlist.id, name: name ?? playlist.name)
        shuffled ? player.playShuffled(songs, source: source)
                 : player.playSong(songs[0], fromQueue: songs, startIndex: 0, source: source)
    }
}

/// A playlist's songs: `MacSongTable`'s columns and menu, plus what only a playlist can do —
/// drag rows to reorder, and Remove from Playlist (or the Delete key) on the selection.
/// Rows are keyed by position, not song id, since a playlist may hold a song twice.
private struct MacPlaylistSongTable: View {
    @Binding var songs: [Song]
    let source: PlaybackSource
    /// Called after every edit with the list as it was, to save it or roll back.
    let onEdit: ([Song]) -> Void

    private struct Row: Identifiable {
        let id: Int
        let song: Song
    }

    @State private var selection = Set<Int>()
    @State private var player = AudioPlayer.shared

    private var rows: [Row] { songs.enumerated().map { Row(id: $0.offset, song: $0.element) } }

    var body: some View {
        Table(of: Row.self, selection: $selection) {
            TableColumn("") { row in
                CoverArtImage(coverArt: row.song.coverArt, size: 24, cornerRadius: 3)
            }
            .width(34)
            TableColumn("Title") { row in
                Text(row.song.title)
                    .foregroundStyle(row.song.id == player.currentSong?.id ? Color.appAccent : .primary)
                    .lineLimit(1)
                    .padding(.vertical, 5)
            }
            .width(min: 180, ideal: 380)
            TableColumn("Artist") { row in
                Text(row.song.artist ?? String(localized: "Unknown Artist")).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 110, ideal: 200, max: 280)
            TableColumn("Album") { row in
                Text(row.song.album ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 110, ideal: 220, max: 300)
            TableColumn("Rating") { row in MacStars(song: row.song) }
                .width(78)
            TableColumn("Time") { row in
                Text(MacFormat.duration(row.song.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(52)
        } rows: {
            ForEach(rows) { row in
                TableRow(row).draggable(String(row.id))
            }
            .dropDestination(for: String.self) { index, items in
                move(items.compactMap(Int.init), to: index)
            }
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .padding(.horizontal, 12)
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Play") { play(ids) }
            Button("Play Next") { chosen(ids).reversed().forEach { player.playNext($0) } }
            Button("Add to Queue") { player.addToQueue(chosen(ids)) }
            Divider()
            MacSongMenuItems(songs: chosen(ids))
            Divider()
            Button("Remove from Playlist", role: .destructive) { remove(ids) }
        } primaryAction: { ids in
            play(ids)
        }
        .onDeleteCommand { remove(selection) }
    }

    private func chosen(_ ids: Set<Int>) -> [Song] {
        ids.sorted().filter { songs.indices.contains($0) }.map { songs[$0] }
    }

    private func play(_ ids: Set<Int>) {
        guard let index = ids.min(), songs.indices.contains(index) else { return }
        player.playSong(songs[index], fromQueue: songs, startIndex: index, source: source)
    }

    private func move(_ from: [Int], to destination: Int) {
        let previous = songs
        var reordered = songs
        reordered.move(fromOffsets: IndexSet(from.filter { songs.indices.contains($0) }), toOffset: destination)
        guard reordered.map(\.id) != previous.map(\.id) else { return }
        selection = []
        songs = reordered
        onEdit(previous)
    }

    private func remove(_ ids: Set<Int>) {
        let gone = chosen(ids)
        guard !gone.isEmpty else { return }
        let previous = songs
        selection = []
        withAnimation { songs = songs.enumerated().filter { !ids.contains($0.offset) }.map(\.element) }
        onEdit(previous)
        let what = gone.count == 1 ? gone[0].title : String(localized: "\(gone.count) songs")
        ToastManager.shared.show(String(localized: "Removed \"\(what)\""), icon: "minus.circle.fill", duration: 4,
                                 action: (String(localized: "Undo"), {
                                     let removed = songs
                                     songs = previous
                                     onEdit(removed)
                                 }))
    }
}
