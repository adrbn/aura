import SwiftUI

/// The downloads screen: storage first, then what's downloading, the albums and the songs.
struct DownloadManagerView: View {
    #if DEBUG
    private static let inScreenshot = Shot.name != nil
    #else
    private static let inScreenshot = false
    #endif

    @State private var dm = DownloadManager.shared
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var searchText = ""
    @State private var addingToPlaylist: Song?
    @State private var freeBytes: Int64 = 0
    @State private var capacityBytes: Int64 = 0

    // MARK: - Shared state

    /// One album's downloaded songs (or one album's in-flight queue items).
    fileprivate struct AlbumGroup: Identifiable {
        let id: String
        let title: String
        let artist: String?
        let coverArt: String?
        var songs: [DownloadedSong] = []
        var queue: [DownloadQueueItem] = []
        var size: Int64 { songs.reduce(0) { $0 + $1.fileSize } }
        var latest: Date { songs.map(\.downloadDate).max() ?? .distantFuture }
        var orderedSongs: [Song] {
            songs.map(\.song).sorted { ($0.discNumber ?? 1, $0.track ?? 0) < ($1.discNumber ?? 1, $1.track ?? 0) }
        }
        var inFlight: [DownloadQueueItem] { queue.filter { $0.state != .failed } }
        var progress: Double {
            let items = inFlight
            return items.isEmpty ? 0 : items.reduce(0) { $0 + $1.progress } / Double(items.count)
        }
    }

    private var filteredDownloads: [DownloadedSong] {
        if searchText.isEmpty {
            return dm.downloadedSongs.sorted { $0.downloadDate > $1.downloadDate }
        }
        return dm.downloadedSongs
            .filter {
                $0.song.title.localizedCaseInsensitiveContains(searchText) ||
                ($0.song.artist ?? "").localizedCaseInsensitiveContains(searchText) ||
                ($0.song.album ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.downloadDate > $1.downloadDate }
    }

    private var activeItems: [DownloadQueueItem] {
        // The one actually downloading first, then the rest in line.
        dm.queueItems.filter { $0.state == .downloading } + dm.queueItems.filter { $0.state == .waiting }
    }

    private var pausedItems: [DownloadQueueItem] {
        dm.queueItems.filter { $0.state == .paused }
    }

    private var failedItems: [DownloadQueueItem] {
        Self.inScreenshot ? [] : dm.queueItems.filter { $0.state == .failed }
    }

    private var pendingItems: [DownloadQueueItem] { activeItems + pausedItems + failedItems }

    private var isEmpty: Bool { dm.downloadedSongs.isEmpty && pendingItems.isEmpty }

    /// Under 2 GB free, the room left shows in orange.
    private var lowSpace: Bool { freeBytes > 0 && freeBytes < 2_000_000_000 }

    private var downloadedBytes: Int64 { dm.downloadedSongs.reduce(0) { $0 + $1.fileSize } }

    /// Downloaded songs (and, when asked, pending queue items) folded into albums,
    /// albums with something in flight first, then the most recently downloaded.
    private func albumGroups(includingQueue: Bool) -> [AlbumGroup] {
        func key(_ song: Song) -> String { song.albumId ?? song.album ?? song.id }
        var groups: [String: AlbumGroup] = [:]
        func group(for song: Song) -> AlbumGroup {
            groups[key(song)] ?? AlbumGroup(id: key(song),
                                             title: song.album ?? String(localized: "Unknown Album"),
                                             artist: song.artist, coverArt: song.coverArt)
        }
        for item in filteredDownloads {
            var g = group(for: item.song)
            g.songs.append(item)
            groups[g.id] = g
        }
        if includingQueue && searchText.isEmpty {
            for item in pendingItems {
                var g = group(for: item.song)
                g.queue.append(item)
                groups[g.id] = g
            }
        }
        return groups.values.sorted {
            if $0.queue.isEmpty != $1.queue.isEmpty { return !$0.queue.isEmpty }
            return $0.latest > $1.latest
        }
    }

    /// What is really moving: the album/playlist being saved, else the song in flight.
    /// An average over hundreds of queued rows sat at 0 % whatever happened.
    private var overallProgress: Double {
        let song = dm.currentDownloadId.flatMap { dm.downloadProgress[$0] } ?? 0
        if let group = dm.currentGroup { return (Double(group.completed) + song) / Double(group.total) }
        return song
    }

    private func refreshStorage() {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
        capacityBytes = Int64(values?.volumeTotalCapacity ?? 0)
    }

    // MARK: - Shared actions

    private func playAll(shuffled: Bool = false) {
        play(dm.downloadedSongs.map(\.song), shuffled: shuffled)
    }

    private func play(_ songs: [Song], shuffled: Bool = false) {
        guard let first = songs.first else { return }
        if shuffled { player.playShuffled(songs, source: .songs) }
        else { player.playSong(first, fromQueue: songs, startIndex: 0, source: .songs) }
    }

    private func pause(_ items: [DownloadQueueItem]) { items.forEach { dm.pauseDownload($0.id) } }
    private func resume(_ items: [DownloadQueueItem]) { items.forEach { dm.resumeDownload($0.id) } }
    private func cancel(_ items: [DownloadQueueItem]) { items.forEach { dm.cancelDownload($0.id) } }
    private func retry(_ items: [DownloadQueueItem]) { items.forEach { dm.retryDownload($0.song) } }

    // MARK: - Body

    var body: some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                storageLayout
            }
        }
        .background(Color.themeBg)
        .searchable(text: $searchText, prompt: "Search downloads")
        .navigationTitle("downloaded")
        .task(id: dm.downloadedSongs.count) { refreshStorage() }
        .sheet(item: $addingToPlaylist) { AddToPlaylistView(song: $0) }
        .toolbar {
            if !dm.downloadedSongs.isEmpty || !dm.queueItems.isEmpty || dm.hasPaused {
                ToolbarItem(placement: .topBarTrailing) { overflowMenu }
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            if dm.isDownloading {
                Button { dm.pauseAllDownloads() } label: { Label("Pause All", systemImage: "pause.circle") }
            }
            if dm.hasPaused {
                Button { dm.resumeAllDownloads() } label: { Label("Resume All", systemImage: "play.circle") }
            }
            if dm.isDownloading || dm.hasPaused {
                Button(role: .destructive) { dm.cancelAllDownloads() } label: { Label("Stop All", systemImage: "stop.circle") }
            }
            if dm.queueItems.contains(where: { $0.state == .completed || $0.state == .cancelled || $0.state == .failed }) {
                Button("Clear Queue History") { dm.clearFinishedFromQueue() }
            }
            if !dm.downloadedSongs.isEmpty {
                Divider()
                Button("Play All") { playAll() }
                Button("Shuffle All") { playAll(shuffled: true) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Shared pieces

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(accentColor.opacity(0.12), lineWidth: 1).frame(width: 168, height: 168)
                Circle().stroke(accentColor.opacity(0.22), lineWidth: 1).frame(width: 124, height: 124)
                Image(systemName: "arrow.down")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 80, height: 80)
                    .glassEffect(.regular.tint(accentColor.opacity(0.18)), in: Circle())
            }
            VStack(spacing: 6) {
                Text("No Downloads").font(.title3.weight(.semibold))
                Text("Download songs or albums to listen offline.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if freeBytes > 0 {
                Text("\(String(localized: "Available")) · \(DownloadManager.formatBytes(freeBytes))")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Dark rounded pill with an accent icon and label.
    private func pill(_ title: LocalizedStringKey, _ icon: String, role: ButtonRole? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1).minimumScaleFactor(0.8)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(role == .destructive ? Color.red : accentColor)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.borderless)
    }

    private var playShufflePills: some View {
        HStack(spacing: 10) {
            pill("Play", "play.fill") { playAll() }
            pill("Shuffle", "shuffle") { playAll(shuffled: true) }
        }
    }

    @ViewBuilder
    private var queueControlPills: some View {
        HStack(spacing: 10) {
            if dm.isDownloading { pill("Pause All", "pause.fill") { dm.pauseAllDownloads() } }
            if dm.hasPaused { pill("Resume All", "play.fill") { dm.resumeAllDownloads() } }
            if dm.isDownloading || dm.hasPaused {
                pill("Stop All", "stop.fill", role: .destructive) { dm.cancelAllDownloads() }
            }
        }
    }

    /// Capacity bar: this app's downloads, everything else on the device, free space.
    private func capacityBar(height: CGFloat) -> some View {
        GeometryReader { geo in
            // Downloads against the room left: the whole device made them a dot.
            let total = max(Double(downloadedBytes + freeBytes), 1)
            let mine = Double(downloadedBytes) / total
            HStack(spacing: 2) {
                Capsule().fill(accentColor).frame(width: max(height, (geo.size.width - 2) * mine))
                Capsule().fill(lowSpace ? Color.orange.opacity(0.5) : Color.primary.opacity(0.12))
            }
        }
        .frame(height: height)
        .opacity(capacityBytes > 0 ? 1 : 0)
    }

    private func legend(_ title: LocalizedStringKey, _ value: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: DownloadManager.formatBytes(value)).monospacedDigit()
        }
        .font(.footnote)
    }

    private func thinBar(_ progress: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.2), value: progress)
    }

    private func sizeText(_ bytes: Int64) -> some View {
        Text(verbatim: DownloadManager.formatBytes(bytes))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func albumMenu(_ group: AlbumGroup) -> some View {
        if !group.songs.isEmpty {
            Button { play(group.orderedSongs) } label: { Label("Play", systemImage: "play.fill") }
            Button { play(group.orderedSongs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
        }
        if let albumId = group.songs.first?.song.albumId ?? group.queue.first?.song.albumId {
            Button { player.pendingAlbumId = albumId } label: { Label("Go to Album", systemImage: "square.stack") }
        }
        if !group.queue.isEmpty { queueMenu(group.queue) }
        if !group.songs.isEmpty {
            Divider()
            Button(role: .destructive) {
                group.songs.forEach { dm.deleteSong($0.id) }
            } label: { Label("Remove Download", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func queueMenu(_ items: [DownloadQueueItem]) -> some View {
        let running = items.filter { $0.state == .downloading || $0.state == .waiting }
        let paused = items.filter { $0.state == .paused }
        let failed = items.filter { $0.state == .failed }
        Divider()
        if !running.isEmpty { Button { pause(running) } label: { Label("Pause", systemImage: "pause.fill") } }
        if !paused.isEmpty { Button { resume(paused) } label: { Label("Resume", systemImage: "play.fill") } }
        if !failed.isEmpty { Button { retry(failed) } label: { Label("Retry", systemImage: "arrow.clockwise") } }
        if !(running + paused).isEmpty {
            Button(role: .destructive) { cancel(running + paused) } label: { Label("Cancel", systemImage: "xmark") }
        }
    }

    // MARK: - Rows

    private func downloadedSongRow(_ downloaded: DownloadedSong, cover: CGFloat, queue: [Song]) -> some View {
        Button {
            if let idx = queue.firstIndex(where: { $0.id == downloaded.song.id }) {
                player.playSong(downloaded.song, fromQueue: queue, startIndex: idx, source: .songs)
            }
        } label: {
            HStack(spacing: 12) {
                CoverArtImage(coverArt: downloaded.song.coverArt, size: cover, cornerRadius: cover > 48 ? 8 : 6,
                              fallbackCoverArt: downloaded.song.albumId)
                VStack(alignment: .leading, spacing: 3) {
                    Text(downloaded.song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(downloaded.song.artist ?? String(localized: "Unknown")) · \(downloaded.song.durationFormatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                sizeText(downloaded.fileSize)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { player.playSong(downloaded.song) } label: { Label("Play Now", systemImage: "play.fill") }
            Button { player.playNext(downloaded.song) } label: { Label("Play Next", systemImage: "text.insert") }
            Button { player.addToQueue(downloaded.song) } label: { Label("Add to Queue", systemImage: "text.append") }
            Divider()
            Button { addingToPlaylist = downloaded.song } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
            if let albumId = downloaded.song.albumId {
                Button { player.pendingAlbumId = albumId } label: { Label("Go to Album", systemImage: "square.stack") }
            }
            if let artistId = downloaded.song.artistId {
                Button { player.pendingArtistId = artistId } label: { Label("Go to Artist", systemImage: "person") }
            }
            Divider()
            Button(role: .destructive) { dm.deleteSong(downloaded.id) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { dm.deleteSong(downloaded.id) } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete")
        }
    }

    private func iconButton(_ icon: String, _ color: Color, _ label: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func queueActions(_ item: DownloadQueueItem) -> some View {
        switch item.state {
        case .downloading:
            HStack(spacing: 10) {
                iconButton("pause.circle.fill", .orange, "Pause") { dm.pauseDownload(item.id) }
                iconButton("xmark.circle.fill", .secondary, "Cancel") { dm.cancelDownload(item.id) }
            }
        case .waiting:
            // In line, not started: no pause to offer, only a quiet way out.
            iconButton("xmark", .secondary, "Cancel") { dm.cancelDownload(item.id) }
                .font(.footnote)
        case .paused:
            HStack(spacing: 10) {
                iconButton("play.circle.fill", accentColor, "Resume") { dm.resumeDownload(item.id) }
                iconButton("xmark.circle.fill", .secondary, "Cancel") { dm.cancelDownload(item.id) }
            }
        case .failed, .cancelled:
            iconButton("arrow.clockwise.circle.fill", accentColor, "Retry") { dm.retryDownload(item.song) }
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
        }
    }

    private func queueRow(_ item: DownloadQueueItem, cover: CGFloat) -> some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: item.song.coverArt, size: cover, cornerRadius: cover > 48 ? 8 : 6,
                          fallbackCoverArt: item.song.albumId)
                .opacity(item.state == .downloading ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.song.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                switch item.state {
                case .failed:
                    Text(item.error ?? String(localized: "Failed"))
                        .font(.caption).foregroundStyle(.red).lineLimit(1)
                case .paused:
                    Text("Paused").font(.caption).foregroundStyle(.orange)
                case .waiting:
                    Text("Queued…").font(.caption).foregroundStyle(.tertiary)
                default:
                    Text(item.song.artist ?? String(localized: "Unknown"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.state == .downloading || item.state == .paused {
                    thinBar(item.progress, tint: item.state == .paused ? .orange : accentColor)
                }
            }
            Spacer(minLength: 8)
            if item.state == .downloading {
                Text("\(Int(item.progress * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            queueActions(item)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Layout

    private var storageLayout: some View {
        List {
            if searchText.isEmpty {
                storageHeader.plainRow(EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20))
                if !pendingItems.isEmpty {
                    inProgressCard.plainRow(EdgeInsets(top: 0, leading: 16, bottom: 24, trailing: 16))
                }
                let albums = albumGroups(includingQueue: false)
                if !albums.isEmpty {
                    Section {
                        albumShelf(albums).plainRow(EdgeInsets(top: 4, leading: 0, bottom: 20, trailing: 0))
                    } header: { sectionTitle("Recently Downloaded") }
                }
            }
            if !filteredDownloads.isEmpty {
                Section {
                    songRows(filteredDownloads, cover: 44)
                } header: {
                    sectionTitle("Downloaded Songs", trailing: searchText.isEmpty ? nil : "\(filteredDownloads.count)")
                }
            }
        }
        .listChrome()
    }

    private var storageHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Storage Used").font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: dm.totalDownloadSize)
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("\(dm.downloadedSongs.count) songs")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            capacityBar(height: 10)
            HStack(spacing: 16) {
                legend("Downloaded", downloadedBytes, accentColor)
                legend("Available", freeBytes, lowSpace ? .orange : Color.primary.opacity(0.18))
            }
            if !dm.downloadedSongs.isEmpty { playShufflePills.padding(.top, 4) }
        }
    }

    private var inProgressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ProgressRing(progress: overallProgress, tint: dm.isDownloading ? accentColor : .orange, lineWidth: 5)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Text("\(Int(overallProgress * 100))%").font(.caption2.weight(.semibold).monospacedDigit())
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("In Progress").font(.headline)
                    Text("\(pendingItems.count) songs")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            queueControlPills
            VStack(spacing: 12) {
                ForEach(pendingItems.prefix(6)) { queueRow($0, cover: 40) }
            }
            if pendingItems.count > 6 {
                Text(verbatim: "+\(pendingItems.count - 6)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
    }

    private func albumShelf(_ albums: [AlbumGroup]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(albums.prefix(20)) { group in
                    Button { play(group.orderedSongs) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverArtImage(coverArt: group.coverArt, size: 136, cornerRadius: 12,
                                          placeholderName: group.title)
                            Text(group.title).font(.footnote.weight(.semibold)).lineLimit(1)
                            Text("\(group.artist ?? String(localized: "Unknown")) · \(DownloadManager.formatBytes(group.size))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 136, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { albumMenu(group) }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func songRows(_ songs: [DownloadedSong], cover: CGFloat) -> some View {
        let queue = songs.map(\.song)
        return ForEach(songs) { downloadedSongRow($0, cover: cover, queue: queue).listRowBackground(Color.clear) }
            .onDelete { offsets in offsets.map { songs[$0].id }.forEach { dm.deleteSong($0) } }
    }

    private func sectionTitle(_ title: LocalizedStringKey, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(.primary)
            Spacer()
            if let trailing {
                Text(verbatim: trailing).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }
}

// MARK: - Helpers

private struct ProgressRing: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
}

private extension View {
    func plainRow(_ insets: EdgeInsets) -> some View {
        listRowInsets(insets).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }

    func listChrome() -> some View {
        endsAboveBottomChrome()
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
    }
}
