import SwiftUI

struct PlaylistsView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var playlists: [Playlist] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var appSettings = AppSettings.shared
    @State private var sortOrder: PlaylistSortOrder = .recentlyChanged
    @State private var showSearch = false
    @State private var showReorderPinned = false
    @State private var isSelecting = false
    @State private var selectedPlaylistIds: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var recentlyDeletedPlaylists: [Playlist] = []
    @State private var showUndoBanner = false
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var navPath = NavigationPath()
    @State private var editingPlaylist: Playlist?
    @State private var isFindingDuplicates = false
    @State private var scrollY: CGFloat = 0
    @State private var filter: PlaylistFilter = .all
    @State private var downloadedIds: Set<String> = []
    /// The list is the default. The key is new with that change: the grid was the default
    /// before, and anyone still on it under the old key never chose it, so everyone starts
    /// on the list once and what they pick from here on is kept.
    @AppStorage("musika_playlists_layout_v2") private var layout: PlaylistLayout = .list
    let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    private var filterContext: PlaylistFilterContext {
        PlaylistFilterContext(username: serverManager.currentServer?.username,
                              pinned: appSettings.pinnedPlaylistIds,
                              downloaded: downloadedIds)
    }

    /// Moves when a song lands on the device or the offline snapshots change — the two
    /// things the Downloaded filter reads.
    private var downloadSignature: Int {
        DownloadManager.shared.downloadedSongs.count
            &+ OfflinePlaylistsStore.shared.playlists.reduce(0) { $0 &+ $1.songs.count }
    }

    /// The playlists the chosen filter keeps; search and the pinned split work on these.
    private var filteredPlaylists: [Playlist] {
        guard filter != .all else { return playlists }
        let context = filterContext
        return playlists.filter { context.matches($0, filter) }
    }

    var pinnedPlaylists: [Playlist] {
        let pinned = filteredPlaylists.filter { appSettings.isPinned($0.id) }
        let order = appSettings.pinnedPlaylistOrder
        return pinned.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
    }

    var unpinnedPlaylists: [Playlist] {
        let filtered = searchText.isEmpty ? filteredPlaylists : filteredPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.comment ?? "").localizedCaseInsensitiveContains(searchText)
        }
        let unpinned = filtered.filter { !appSettings.isPinned($0.id) }
        return sortPlaylists(unpinned)
    }

    /// When searching, return all matching playlists in a single sorted list (pinned badge preserved but not separated)
    var searchResultPlaylists: [Playlist] {
        let filtered = filteredPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.comment ?? "").localizedCaseInsensitiveContains(searchText)
        }
        return sortPlaylists(filtered)
    }

    private func sortPlaylists(_ list: [Playlist]) -> [Playlist] {
        switch sortOrder {
        case .name:
            return list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .songCount:
            return list.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        case .recentlyChanged:
            return list.sorted { ($0.changed ?? "") > ($1.changed ?? "") }
        case .created:
            return list.sorted { ($0.created ?? "") > ($1.created ?? "") }
        }
    }

    /// Header actions (moved out of the native toolbar since the big title hides the nav bar).
    @ViewBuilder private var playlistsActions: some View {
        HStack(spacing: 14) {
            if isSelecting {
                Button("Cancel") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isSelecting = false
                        selectedPlaylistIds.removeAll()
                    }
                }
                Menu {
                    Button {
                        Task { await findAndSelectDuplicates() }
                    } label: {
                        Label(isFindingDuplicates ? "Scanning..." : "Select Duplicates", systemImage: "doc.on.doc")
                    }
                    .disabled(isFindingDuplicates)
                    Button { selectedPlaylistIds = Set(playlists.map { $0.id }) } label: {
                        Label("Select All", systemImage: "checkmark.circle.fill")
                    }
                    Button { selectedPlaylistIds.removeAll() } label: {
                        Label("Deselect All", systemImage: "circle")
                    }
                } label: {
                    if isFindingDuplicates { ProgressView() } else { Image(systemName: "checklist") }
                }
                // Pin/Delete now live in the floating bottom bar so they're reachable
                // without scrolling back up to the title.
            } else {
                // Beside the menu rather than at the end of the filters, where the chips
                // scrolled under it. Both in the secondary colour, as Library's options
                // button is: the accent made two utility icons the loudest thing on the page.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { layout = layout.toggled }
                } label: {
                    Image(systemName: layout.toggleIcon)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layout == .grid ? "Show as List" : "Show as Grid")
                Menu {
                    Button { showCreatePlaylist = true } label: {
                        Label("Create Playlist", systemImage: "plus")
                    }
                    if !pinnedPlaylists.isEmpty {
                        Button { showReorderPinned = true } label: {
                            Label("Reorder Pinned", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isSelecting = true }
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    Divider()
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(PlaylistSortOrder.allCases, id: \.self) { order in
                            Label(order.rawValue, systemImage: order.icon).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(accentColor)
    }

    /// The rail indexes playlist names, so it only appears under the name sort — and
    /// only once the grid is long enough that scrolling it by hand is actually a chore.
    private var indexTitles: [String] {
        guard sortOrder == .name, searchText.isEmpty, unpinnedPlaylists.count > 25 else { return [] }
        return AlphabetIndex.titles(for: unpinnedPlaylists.map(\.name))
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                ScrollView {
                    TabTitleRow("playlists") { playlistsActions }
                    SearchFieldBar(text: $searchText, prompt: "Search in Playlists")
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    if !isLoading && !playlists.isEmpty {
                        PlaylistFilterBar(filters: filterContext.offered(for: playlists, keeping: filter),
                                          selection: $filter)
                            .padding(.bottom, 6)
                    }
                    if isLoading {
                        loadingPlaceholder
                    } else if playlists.isEmpty {
                        ContentUnavailableView("No Playlists",
                            systemImage: "music.note.list",
                            description: Text("Create playlists on your server"))
                            .padding(.top, 100)
                    } else if filteredPlaylists.isEmpty {
                        Text("No playlists here yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if !searchText.isEmpty {
                        // Search mode: single collection, no separate pinned section
                        playlistCollection(searchResultPlaylists)
                            .padding(.top, 8)
                    } else {
                        VStack(alignment: .leading, spacing: layout == .grid ? 16 : 8) {
                            if !pinnedPlaylists.isEmpty {
                                playlistCollection(pinnedPlaylists)
                            }
                            playlistCollection(unpinnedPlaylists)
                        }
                        .padding(.top, 8)
                    }
                    ListEndSpacer()
                }
                .scrollIndicators(.hidden)
                // No page colour here: `tabRootGlass` paints it, with the glow at its top.
                .overlay(alignment: .trailing) {
                    if !indexTitles.isEmpty {
                        AlphabetIndexBar(titles: indexTitles, tint: accentColor) { letter in
                            guard let target = unpinnedPlaylists.first(where: {
                                AlphabetIndex.key(for: $0.name) == letter
                            }) else { return }
                            proxy.scrollTo(target.id, anchor: .top)
                        }
                        .padding(.trailing, 2)
                        .padding(.bottom, 64 + BottomChrome.shared.cardInset)
                    }
                }
                }

                // Floating selection bar — Pin/Delete stay reachable no matter how far
                // you've scrolled (mirrors the Photos multi-select toolbar).
                if isSelecting {
                    HStack(spacing: 24) {
                        Text(selectedPlaylistIds.isEmpty ? "Select playlists"
                                                         : "\(selectedPlaylistIds.count) selected")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selectedPlaylistIds.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button { pinSelectedPlaylists() } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "pin.fill").font(.body)
                                Text("Pin").font(.caption2)
                            }
                            .foregroundStyle(selectedPlaylistIds.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accentColor))
                        }
                        .disabled(selectedPlaylistIds.isEmpty)
                        Button {
                            if selectedPlaylistIds.isEmpty { return }
                            showDeleteConfirmation = true
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "trash.fill").font(.body)
                                Text("Delete").font(.caption2)
                            }
                            .foregroundStyle(selectedPlaylistIds.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.red))
                        }
                        .disabled(selectedPlaylistIds.isEmpty)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Undo banner
                if showUndoBanner {
                    HStack {
                        Text("\(recentlyDeletedPlaylists.count) playlist(s) deleted")
                            .font(.subheadline)
                        Spacer()
                        Button("Undo") {
                            undoDelete()
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(accentColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: showUndoBanner)
            .tabRootGlass(scrollY: $scrollY)
            .refreshable { await refreshTabContent { await loadPlaylists() } }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id) }
            .navigationDestination(for: PlaylistDeepLink.self) { link in
                PlaylistDetailView(playlistId: link.id)
            }
            .onChange(of: downloadSignature, initial: true) {
                downloadedIds = PlaylistFilterContext.downloadedPlaylistIds()
            }
            .onAppear {
                // Pick up pending values set BEFORE this view mounted (e.g. tab switch)
                if player.isShowingRadioPlaylist {
                    player.isShowingRadioPlaylist = false
                    navPath.append(RadioNavLink())
                }
                if let id = player.pendingPlaylistId {
                    player.pendingPlaylistId = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        navPath.append(PlaylistDeepLink(id: id))
                    }
                }
            }
            .onChange(of: player.pendingPlaylistId) { _, newId in
                guard let id = newId else { return }
                player.pendingPlaylistId = nil
                // Pop to root first so tapping the source doesn't stack a duplicate when
                // the playlist is already open in the background.
                if !navPath.isEmpty { navPath = NavigationPath() }
                // Delay to ensure NavigationStack is active after tab switch / fullScreenCover dismiss
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    navPath.append(PlaylistDeepLink(id: id))
                }
            }
            .navigationDestination(for: RadioNavLink.self) { _ in
                RadioPlaylistView()
            }
            .onChange(of: player.isShowingRadioPlaylist) { _, newValue in
                if newValue {
                    player.isShowingRadioPlaylist = false
                    // Push onto current navPath so back returns to wherever the user was
                    navPath.append(RadioNavLink())
                }
            }
            .sheet(isPresented: $showReorderPinned) {
                ReorderPinnedView(playlists: playlists)
            }
            .sheet(item: $editingPlaylist) { playlist in
                PlaylistEditView(playlistId: playlist.id, currentName: playlist.name, currentComment: playlist.comment ?? "") {
                    await loadPlaylists()
                }
            }
            .alert("Delete \(selectedPlaylistIds.count) Playlist(s)?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deletePlaylists()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the selected playlists from the server. You can undo this briefly after deletion.")
            }
            .alert("New Playlist", isPresented: $showCreatePlaylist) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        guard let server = serverManager.currentServer else { return }
                        if let created = try? await SubsonicClient.shared.createPlaylist(server: server, name: name, songIds: []) {
                            newPlaylistName = ""
                            await loadPlaylists()
                            navPath.append(created)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
            } message: {
                Text("Enter a name for the new playlist.")
            }
        }
        .task { await loadPlaylists() }
    }

    @ViewBuilder private var loadingPlaceholder: some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<8, id: \.self) { _ in
                    SkeletonPlaylistCard()
                }
            }
            .padding()
        case .list:
            VStack(spacing: 8) {
                ForEach(0..<10, id: \.self) { _ in
                    SkeletonPlaylistRow()
                }
            }
            .padding()
        }
    }

    /// The playlists as a grid of covers or a list of rows, as chosen in the filter bar.
    @ViewBuilder
    private func playlistCollection(_ list: [Playlist]) -> some View {
        switch layout {
        case .grid:
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(list) { playlist in
                    playlistCell(playlist, isPinned: appSettings.isPinned(playlist.id))
                        .id(playlist.id)
                }
            }
            .padding(.horizontal)
        case .list:
            LazyVStack(spacing: 0) {
                ForEach(list) { playlist in
                    playlistCell(playlist, isPinned: appSettings.isPinned(playlist.id))
                        .id(playlist.id)
                }
            }
            .padding(.leading)
            // Clear of the alphabet rail when it shows.
            .padding(.trailing, indexTitles.isEmpty ? 16 : 28)
        }
    }

    private func selectionMark(_ playlist: Playlist, onCover: Bool) -> some View {
        let isSelected = selectedPlaylistIds.contains(playlist.id)
        return Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AnyShapeStyle(accentColor)
                                        : onCover ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            .shadow(radius: onCover ? 2 : 0)
    }

    @ViewBuilder
    private func playlistItem(_ playlist: Playlist, isPinned: Bool) -> some View {
        switch layout {
        case .grid:
            PlaylistCardView(playlist: playlist, isPinned: isPinned, showSongCount: isSelecting)
                .overlay(alignment: .topLeading) {
                    if isSelecting { selectionMark(playlist, onCover: true).padding(8) }
                }
        case .list:
            HStack(spacing: 12) {
                if isSelecting { selectionMark(playlist, onCover: false) }
                PlaylistRowView(playlist: playlist, isPinned: isPinned)
            }
            .padding(.vertical, appSettings.listDensity.verticalPadding + 2)
        }
    }

    private func playlistCell(_ playlist: Playlist, isPinned: Bool) -> some View {
        playlistItem(playlist, isPinned: isPinned)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    if selectedPlaylistIds.contains(playlist.id) {
                        selectedPlaylistIds.remove(playlist.id)
                    } else {
                        selectedPlaylistIds.insert(playlist.id)
                    }
                } else {
                    navPath.append(playlist)
                }
            }
            .contextMenu {
                if !isSelecting {
                    playlistContextMenu(playlist)
                }
            }
    }

    private func deletePlaylists() {
        let toDelete = playlists.filter { selectedPlaylistIds.contains($0.id) }
        recentlyDeletedPlaylists = toDelete
        // Remove from local list immediately
        playlists.removeAll { selectedPlaylistIds.contains($0.id) }
        let idsToDelete = selectedPlaylistIds
        isSelecting = false
        selectedPlaylistIds.removeAll()
        showUndoBanner = true

        // Actually delete from server after a delay (undo window)
        Task {
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                withAnimation { showUndoBanner = false }
            }
            // If not undone, actually delete
            if !recentlyDeletedPlaylists.isEmpty {
                guard let server = serverManager.currentServer else { return }
                for id in idsToDelete {
                    try? await SubsonicClient.shared.deletePlaylist(server: server, id: id)
                }
                await MainActor.run { recentlyDeletedPlaylists = [] }
            }
        }
    }

    private func undoDelete() {
        // Re-add to local list
        playlists.append(contentsOf: recentlyDeletedPlaylists)
        recentlyDeletedPlaylists = []
        showUndoBanner = false
    }

    private func pinSelectedPlaylists() {
        let count = selectedPlaylistIds.count
        for id in selectedPlaylistIds {
            if !appSettings.isPinned(id) {
                appSettings.pinnedPlaylistIds.insert(id)
                appSettings.pinnedPlaylistOrder.append(id)
            }
        }
        appSettings.save()
        isSelecting = false
        selectedPlaylistIds.removeAll()
        ToastManager.shared.show("Pinned \(count) playlist(s)", icon: "pin.fill")
    }

    private func findAndSelectDuplicates() async {
        guard let server = serverManager.currentServer else { return }
        isFindingDuplicates = true
        defer { Task { @MainActor in isFindingDuplicates = false } }

        // 1. Group playlists by normalized name
        var groups: [String: [Playlist]] = [:]
        for pl in playlists {
            let key = pl.name.lowercased().trimmingCharacters(in: .whitespaces)
            groups[key, default: []].append(pl)
        }

        // Only care about names that appear more than once
        let duplicateGroups = groups.filter { $0.value.count > 1 }
        guard !duplicateGroups.isEmpty else {
            await MainActor.run {
                ToastManager.shared.show("No duplicates found", icon: "checkmark")
            }
            return
        }

        // 2. For each group, fetch song lists and compare
        var idsToSelect: Set<String> = []

        await withTaskGroup(of: (String, [String])?.self) { group in
            // Fetch all candidate playlists' song IDs concurrently (batched)
            let allCandidates = duplicateGroups.values.flatMap { $0 }
            for pl in allCandidates {
                group.addTask {
                    guard let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: pl.id) else {
                        return (pl.id, [])
                    }
                    let songIds = (detail.entry ?? []).map { $0.id }
                    return (pl.id, songIds)
                }
            }

            var songIdsByPlaylist: [String: [String]] = [:]
            for await result in group {
                if let (plId, songIds) = result {
                    songIdsByPlaylist[plId] = songIds
                }
            }

            // 3. Within each name-group, find true duplicates by comparing song content
            for (_, group) in duplicateGroups {
                // Sort: prefer the one with most songs, then oldest created date
                let sorted = group.sorted { a, b in
                    let aSongs = songIdsByPlaylist[a.id]?.count ?? 0
                    let bSongs = songIdsByPlaylist[b.id]?.count ?? 0
                    if aSongs != bSongs { return aSongs > bSongs }
                    return (a.created ?? "") < (b.created ?? "")
                }

                // The first one is the "keeper" — compare others against it
                guard let keeper = sorted.first else { continue }
                let keeperSongIds = Set(songIdsByPlaylist[keeper.id] ?? [])

                for candidate in sorted.dropFirst() {
                    let candidateSongIds = Set(songIdsByPlaylist[candidate.id] ?? [])

                    // It's a duplicate if:
                    // - Both empty
                    // - Candidate is a subset of keeper (same songs or fewer)
                    // - >80% overlap in song IDs
                    let isDuplicate: Bool
                    if candidateSongIds.isEmpty && keeperSongIds.isEmpty {
                        isDuplicate = true
                    } else if candidateSongIds.isEmpty {
                        isDuplicate = true  // Empty copy vs populated original
                    } else if keeperSongIds.isEmpty {
                        isDuplicate = false // Keeper is empty but candidate has songs — don't delete candidate
                    } else {
                        let overlap = candidateSongIds.intersection(keeperSongIds).count
                        let overlapRatio = Double(overlap) / Double(max(candidateSongIds.count, 1))
                        isDuplicate = overlapRatio >= 0.8
                    }

                    if isDuplicate {
                        idsToSelect.insert(candidate.id)
                    }
                }
            }
        }

        await MainActor.run {
            selectedPlaylistIds = idsToSelect
            if idsToSelect.isEmpty {
                ToastManager.shared.show("No true duplicates found", icon: "checkmark")
            } else {
                ToastManager.shared.show("Selected \(idsToSelect.count) duplicate(s)", icon: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private func playlistContextMenu(_ playlist: Playlist) -> some View {
        Button {
            Task {
                guard let server = serverManager.currentServer else { return }
                let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
                if let songs = detail?.entry, !songs.isEmpty {
                    await MainActor.run { player.playSong(songs[0], fromQueue: songs) }
                }
            }
        } label: { Label("Play", systemImage: "play.fill") }

        Button {
            Task {
                guard let server = serverManager.currentServer else { return }
                let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
                if let songs = detail?.entry, !songs.isEmpty {
                    await MainActor.run {
                        player.playShuffled(songs, source: .playlist(id: playlist.id, name: playlist.name))
                    }
                }
            }
        } label: { Label("Shuffle", systemImage: "shuffle") }

        Button {
            Task {
                guard let server = serverManager.currentServer else { return }
                let detail = try? await SubsonicClient.shared.getPlaylist(server: server, id: playlist.id)
                if let songs = detail?.entry, !songs.isEmpty {
                    var shuffled = songs; shuffled.shuffle()
                    await MainActor.run { player.addToQueue(shuffled) }
                }
            }
        } label: { Label("Add to Queue", systemImage: "text.append") }

        Divider()

        Button {
            appSettings.togglePin(playlistId: playlist.id)
        } label: {
            Label(appSettings.isPinned(playlist.id) ? "Unpin" : "Pin",
                  systemImage: appSettings.isPinned(playlist.id) ? "pin.slash" : "pin")
        }

        Button {
            editingPlaylist = playlist
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Divider()

        Button {
            selectedPlaylistIds = [playlist.id]
            isSelecting = true
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            selectedPlaylistIds = [playlist.id]
            showDeleteConfirmation = true
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    private func loadPlaylists() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let result = try await SubsonicClient.shared.getPlaylists(server: server)
            // Deduplicate by ID (server scans can create duplicates from .m3u files)
            var seen = Set<String>()
            let unique = result.filter { seen.insert($0.id).inserted }
            await MainActor.run {
                playlists = unique
                isLoading = false
                // Opportunistically snapshot playlists (with songs) for the offline library.
                OfflinePlaylistsStore.shared.refresh(from: unique)
            }
            // Warm the grid covers ahead of scroll. Updated covers are picked up via the
            // `changed` cache token — no cache clearing needed.
            ArtworkCache.shared.prefetch(
                unique.compactMap { p in p.coverArt.map { ($0, p.changed) } },
                pointSize: 180
            )
        } catch {
            isLoading = false
        }
    }
}

struct PlaylistCardView: View {
    let playlist: Playlist
    var isPinned: Bool = false
    var showSongCount: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt,
                                  cacheToken: playlist.changed, size: 180, cornerRadius: 12)
                if isPinned {
                    // A quiet badge, not a sticker: in the accent, every pinned cover carried a
                    // bright dot that outshouted the artwork. A small white pin on a dark,
                    // see-through disc reads on any cover and says no more than it has to.
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(5)
                        .background(Color.black.opacity(0.35), in: Circle())
                        .padding(6)
                }
            }
            Text(playlist.name).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
            if showSongCount {
                Text("\(playlist.songCount ?? 0) songs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ReorderPinnedView: View {
    let playlists: [Playlist]
    @State private var appSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var orderedPinned: [Playlist] {
        let pinned = playlists.filter { appSettings.isPinned($0.id) }
        let order = appSettings.pinnedPlaylistOrder
        return pinned.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(orderedPinned) { playlist in
                    HStack(spacing: 12) {
                        PlaylistCoverView(playlistId: playlist.id, coverArt: playlist.coverArt, size: 40, cornerRadius: 6)
                        Text(playlist.name)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                    }
                }
                .onMove { source, dest in
                    appSettings.movePinnedPlaylist(from: source, to: dest)
                }
            }
            .scrollIndicators(.hidden)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("reorder pinned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Hashable wrapper for programmatic playlist deep-link navigation via NavigationPath
struct PlaylistDeepLink: Hashable {
    let id: String
}

/// Hashable wrapper for pushing RadioPlaylistView onto navPath (preserves back stack)
struct RadioNavLink: Hashable {
    let id = UUID()
}

