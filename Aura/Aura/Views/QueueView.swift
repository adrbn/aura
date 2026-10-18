import SwiftUI

struct QueueView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @State private var undoQueue: [Song]?
    @State private var undoTimer: Timer?
    /// Drawn beside the player on an iPhone Duo instead of in its own sheet.
    var embedded = false

    var body: some View {
        if embedded {
            embeddedQueue
        } else {
            NavigationStack {
                queueList
                    .background(Color.themeBg)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("Queue").font(.headline)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            if !autoNextSongs.isEmpty || !player.userQueue.isEmpty {
                                Button("Clear") { player.clearUpNext() }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        }
    }

    private var queueList: some View {
        List {
            Group {
                // Now playing
                if !embedded, let song = player.currentSong {
                    Section("Now Playing") {
                        HStack(spacing: 12) {
                            CoverArtImage(coverArt: song.coverArt, size: 50, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(accentColor)
                                    .lineLimit(1)
                                Text(song.artist ?? String(localized: "Unknown Artist"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if player.isPlaying {
                                Image(systemName: "waveform")
                                    .foregroundStyle(accentColor)
                                    .symbolEffect(.variableColor.iterative)
                            }
                        }
                    }
                }

                // User queue — songs added via "Add to Queue" / "Play Next"
                if !player.userQueue.isEmpty {
                    Section {
                        // Keyed by song and by which of its copies it is (see `keyed`).
                        ForEach(Self.keyed(player.userQueue)) { row in
                            let index = row.index
                            let song = row.song
                            HStack(spacing: 12) {
                                CoverArtImage(coverArt: song.coverArt, size: 46, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(song.artist ?? String(localized: "Unknown Artist"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let song = player.userQueue.remove(at: index)
                                player.playSong(song, fromQueue: player.queue, startIndex: player.queueIndex, source: .queue)
                            }
                        }
                        .onDelete { indices in
                            for i in indices.sorted().reversed() {
                                player.userQueue.remove(at: i)
                            }
                        }
                        .onMove { source, dest in
                            player.userQueue.move(fromOffsets: source, toOffset: dest)
                        }
                    } header: {
                        HStack {
                            Text("Next in Queue")
                            Spacer()
                            Button("Clear") {
                                player.userQueue = []
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }

                // Auto-generated queue
                let autoNext = autoNextSongs
                if !autoNext.isEmpty {
                    Section {
                        ForEach(Self.keyed(autoNext)) { row in
                            let index = row.index
                            let song = row.song
                            HStack(spacing: 12) {
                                CoverArtImage(coverArt: song.coverArt, size: 46, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(song.artist ?? String(localized: "Unknown Artist"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let actualIndex = player.queueIndex + 1 + index
                                if actualIndex < player.queue.count {
                                    player.playSong(song, fromQueue: player.queue, startIndex: actualIndex, source: .autoplay)
                                }
                            }
                        }
                        .onDelete { indices in
                            let offsets = indices.map { $0 + player.queueIndex + 1 }
                            for offset in offsets.sorted().reversed() {
                                player.removeFromQueue(at: offset)
                            }
                        }
                        .onMove { source, dest in
                            let adjustedSource = IndexSet(source.map { $0 + player.queueIndex + 1 })
                            let adjustedDest = dest + player.queueIndex + 1
                            player.moveInQueue(from: adjustedSource, to: adjustedDest)
                        }
                    } header: {
                        HStack {
                            Text("Autoplay")
                            Spacer()
                            Button {
                                if let old = player.shuffleUpNext() {
                                    undoTimer?.invalidate()
                                    undoQueue = old
                                    undoTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                                        DispatchQueue.main.async { undoQueue = nil }
                                    }
                                }
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.subheadline)
                            }
                            .textCase(nil)
                            .disabled(autoNext.isEmpty)
                        }
                    }
                } else if player.userQueue.isEmpty {
                    Section("Autoplay") {
                        // The tail is fetched after playback starts, and the server's
                        // recommendation agent can take half a minute to answer. Say so,
                        // rather than claim there is nothing coming.
                        if player.isBuildingQueue {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Finding songs to play next…")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        } else {
                            Text("Nothing in the queue")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
            }
            // Beside the player, the rows sit on its own background.
            .listRowBackground(embedded ? Color.clear : nil)
            .listRowSeparator(embedded ? .hidden : .automatic)
        }
        // A song played leaves the top and the rest slide up; a new album's songs fade
        // in over the old — rather than every row rewritten where it stands.
        .animation(.smooth(duration: 0.35), value: Self.keyed(player.userQueue).map(\.id))
        .animation(.smooth(duration: 0.35), value: Self.keyed(autoNextSongs).map(\.id))
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .onDisappear { undoTimer?.invalidate() }
        .overlay(alignment: .bottom) {
            if undoQueue != nil {
                Button {
                    if let saved = undoQueue {
                        player.restoreQueue(saved)
                        undoTimer?.invalidate()
                        undoQueue = nil
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Undo shuffle")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3), value: undoQueue != nil)
            }
        }
    }

    /// Rows keyed by song and by which of its copies they are. Keyed by position, as they
    /// were, every row was a different song after each track and simply rewrote itself;
    /// keyed by song alone, two copies of one song collapsed and a tap could play the wrong
    /// one. This way each row is itself for as long as it's there, and a tap still plays
    /// the row touched.
    private static func keyed(_ songs: [Song]) -> [QueueRow] {
        var copies: [String: Int] = [:]
        return songs.enumerated().map { index, song in
            let copy = copies[song.id, default: 0]
            copies[song.id] = copy + 1
            return QueueRow(index: index, song: song, id: "\(song.id)#\(copy)")
        }
    }

    struct QueueRow: Identifiable {
        let index: Int
        let song: Song
        let id: String
    }

    private var autoNextSongs: [Song] {
        guard !player.queue.isEmpty, player.queueIndex + 1 < player.queue.count else { return [] }
        return Array(player.queue[(player.queueIndex + 1)...])
    }
}

// MARK: - Beside or under the player

/// The queue drawn on Now Playing's own background — under the artwork header on a phone,
/// beside the player on an open iPhone Duo: a fixed "Playing Next" head with shuffle and
/// repeat, compact rows, and the autoplay tail under its own heading.
extension QueueView {
    var embeddedQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room between the source line and where the rows have faded out entirely.
            embeddedHeader.padding(.bottom, 4)
            List {
                ForEach(Self.keyed(player.userQueue)) { row in
                    embeddedRow(row.song)
                        .onTapGesture {
                            let song = player.userQueue.remove(at: row.index)
                            player.playSong(song, fromQueue: player.queue, startIndex: player.queueIndex, source: .queue)
                        }
                }
                .onDelete { indices in
                    for i in indices.sorted().reversed() { player.userQueue.remove(at: i) }
                }
                .onMove { player.userQueue.move(fromOffsets: $0, toOffset: $1) }

                queueSection(fromSourceSongs, start: player.queueIndex + 1, source: player.playbackSource)

                let autoplay = autoplaySongs
                if !autoplay.isEmpty {
                    // A small mark beside the word: as a Label's icon the infinity drew at the
                    // full headline size and outweighed the heading itself.
                    HStack(spacing: 6) {
                        Image(systemName: "infinity").font(.footnote.weight(.bold))
                        Text("Autoplay")
                    }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.top, 14)
                        .embeddedRowStyle()
                    queueSection(autoplay, start: autoplayStart, source: .autoplay)
                } else if player.userQueue.isEmpty && fromSourceSongs.isEmpty {
                    Group {
                        if player.isBuildingQueue {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Finding songs to play next…")
                            }
                        } else {
                            Text("Nothing in the queue")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .embeddedRowStyle()
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            // Rows fade out under the head as they scroll up and at the foot (Now Playing's
            // mask); a margin as tall as each fade lets the first and last rows rest clear of it.
            .contentMargins(.top, 28, for: .scrollContent)
            .contentMargins(.bottom, 48, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                    Color.white
                }
            }
            .animation(.smooth(duration: 0.35), value: Self.keyed(player.userQueue).map(\.id))
            .animation(.smooth(duration: 0.35), value: Self.keyed(autoNextSongs).map(\.id))
            // Warm every row's cover up front — loading them as they scroll in shows placeholders.
            .task(id: upcomingCovers) {
                ArtworkCache.shared.prefetch(coverArtIds: upcomingCovers, pointSize: 52)
            }
        }
    }

    private var upcomingCovers: [String] {
        (player.userQueue + autoNextSongs).compactMap(\.coverArt)
    }

    private var embeddedHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Playing Next")
                    .font(.headline)
                    .foregroundStyle(.white)
                if player.playbackSource != .unknown {
                    Text("From \(player.playbackSource.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            headerToggle("shuffle", on: player.isShuffled, label: "Shuffle") { player.toggleShuffle() }
            headerToggle(player.repeatMode.systemImage, on: player.repeatMode != .off, label: "Repeat") {
                player.cycleRepeat()
            }
        }
    }

    /// A toggle that lights a soft tile behind itself when on.
    private func headerToggle(_ symbol: String, on: Bool, label: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(on ? 1 : 0.6))
                .frame(width: 36, height: 30)
                .background(.white.opacity(on ? 0.22 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Rows of `player.queue` from `start` on, each played from where it stands.
    @ViewBuilder
    private func queueSection(_ songs: [Song], start: Int, source: PlaybackSource) -> some View {
        ForEach(Self.keyed(songs)) { row in
            embeddedRow(row.song)
                .onTapGesture {
                    let index = start + row.index
                    if index < player.queue.count {
                        player.playSong(row.song, fromQueue: player.queue, startIndex: index, source: source)
                    }
                }
        }
        .onDelete { indices in
            for offset in indices.map({ $0 + start }).sorted().reversed() { player.removeFromQueue(at: offset) }
        }
        .onMove { from, to in
            player.moveInQueue(from: IndexSet(from.map { $0 + start }), to: to + start)
        }
    }

    private func embeddedRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            CoverArtImage(coverArt: song.coverArt, size: 52, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(song.artist ?? String(localized: "Unknown Artist"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.35))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        // A held row lifts as a rounded tile; with the clear row background it lifted on black.
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 8, style: .continuous))
        .embeddedRowStyle()
    }

    /// Where the autoplay tail begins: past the source's own songs.
    private var autoplayStart: Int {
        max(player.queueIndex + 1, player.autoplayFromIndex ?? player.queue.count)
    }

    /// What's left of the album, playlist or artist being played.
    private var fromSourceSongs: [Song] {
        let start = player.queueIndex + 1
        guard start < autoplayStart, autoplayStart <= player.queue.count else { return [] }
        return Array(player.queue[start..<autoplayStart])
    }

    /// Songs added after the source ran out, by autoplay.
    private var autoplaySongs: [Song] {
        guard autoplayStart < player.queue.count else { return [] }
        return Array(player.queue[autoplayStart...])
    }
}

private extension View {
    /// A row edge to edge, on the player's background, with no separator.
    func embeddedRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
