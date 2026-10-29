import SwiftUI

/// Whether Up Next is open, so the player bar's button and the pane's own close agree.
@MainActor @Observable final class MacQueuePanel {
    static let shared = MacQueuePanel()
    var isShown = false
}

/// What is coming up, as a pane on the window's right edge — the sidebar's twin, opened and
/// closed from the queue button, so it can stay open beside the library while you browse.
///
/// Rows are dragged to reorder by hand rather than through a List: a List outlines the row
/// under a right-click in the accent, a frame that doesn't belong in this pane. Every edit
/// here goes through the player's queue, which sends it on when this Mac plays elsewhere.
struct MacQueueView: View {
    @State private var player = AudioPlayer.shared
    @State private var hovered: Int?
    /// The row a dragged one would land in front of.
    @State private var dropTarget: Int?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appAccentColor) private var accentColor

    /// One key per row: offsets in the queue, negatives for the songs added by hand.
    private enum Part { case added, upcoming }
    private static func key(added index: Int) -> Int { -1 - index }

    private var upcoming: [(offset: Int, song: Song)] {
        guard player.queueIndex + 1 < player.queue.count else { return [] }
        return Array(player.queue.enumerated())
            .filter { $0.offset > player.queueIndex }
            .map { (offset: $0.offset, song: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").auraDisplay(30)
                Spacer()
                Button { MacQueuePanel.shared.isShown = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 18)
            // Level with the sections' titles, below the title bar's row.
            .padding(.top, MacRootView.topRoom)
            .padding(.bottom, 10)

            if upcoming.isEmpty && player.userQueue.isEmpty {
                Text("Nothing queued")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !player.userQueue.isEmpty {
                            sectionHeader("Next in Queue") {
                                headerButton("xmark.circle", help: "Clear") { player.userQueue = [] }
                            }
                            ForEach(Array(player.userQueue.enumerated()), id: \.offset) { index, song in
                                row(song, key: Self.key(added: index), part: .added)
                            }
                        }
                        if !upcoming.isEmpty {
                            sectionHeader(LocalizedStringKey(player.playbackSource.displayName)) {
                                headerButton("shuffle", help: "Shuffle") { _ = player.shuffleUpNext() }
                                headerButton("xmark.circle", help: "Clear") { player.clearUpNext() }
                            }
                            .padding(.top, player.userQueue.isEmpty ? 0 : 10)
                            ForEach(upcoming, id: \.offset) { item in
                                row(item.song, key: item.offset, part: .upcoming)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(scheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.35))
        .overlay(alignment: .leading) {
            Rectangle().fill(.primary.opacity(0.07)).frame(width: 1)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: Editing

    private func play(_ key: Int, part: Part) {
        switch part {
        case .added:
            let song = player.userQueue.remove(at: -1 - key)
            player.playSong(song, fromQueue: player.queue, startIndex: player.queueIndex, source: .queue)
        case .upcoming:
            player.playSong(player.queue[key], fromQueue: player.queue, startIndex: key, source: player.playbackSource)
        }
    }

    private func remove(_ key: Int, part: Part) {
        switch part {
        case .added: player.userQueue.remove(at: -1 - key)
        case .upcoming: player.removeFromQueue(at: key)
        }
    }

    /// `from` lands where `to` is now; the rows between shift over by one.
    private func move(_ from: Int, to: Int, part: Part) {
        guard from != to else { return }
        switch part {
        case .added:
            let a = -1 - from, b = -1 - to
            player.userQueue.move(fromOffsets: [a], toOffset: b > a ? b + 1 : b)
        case .upcoming:
            player.moveInQueue(from: [from], to: to > from ? to + 1 : to)
        }
    }

    private func first(of part: Part) -> Int {
        part == .added ? Self.key(added: 0) : player.queueIndex + 1
    }

    private func last(of part: Part) -> Int {
        part == .added ? Self.key(added: player.userQueue.count - 1) : player.queue.count - 1
    }

    // MARK: Pieces

    private func sectionHeader(_ title: LocalizedStringKey, @ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            buttons()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func headerButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func row(_ song: Song, key: Int, part: Part) -> some View {
        HStack(spacing: 10) {
            CoverArtImage(coverArt: song.coverArt, size: 38, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(song.artist ?? "").font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered == key {
                Button { remove(key, part: part) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove")
            } else {
                Text(MacFormat.duration(song.duration))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(hovered == key ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
        // Where the dragged row will go: a line in the accent above this one.
        .overlay(alignment: .top) {
            if dropTarget == key {
                Capsule().fill(accentColor).frame(height: 2).offset(y: -2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .onTapGesture(count: 2) { play(key, part: part) }
        .draggable("\(part == .added ? "a" : "u")\(key)") {
            HStack(spacing: 8) {
                CoverArtImage(coverArt: song.coverArt, size: 28, cornerRadius: 4)
                Text(song.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { items, _ in
            dropTarget = nil
            guard let item = items.first, item.first == (part == .added ? "a" : "u"),
                  let from = Int(item.dropFirst()) else { return false }
            withAnimation(.smooth(duration: 0.25)) { move(from, to: key, part: part) }
            return true
        } isTargeted: { inside in
            if inside { dropTarget = key } else if dropTarget == key { dropTarget = nil }
        }
        .contextMenu { menu(song, key: key, part: part) }
    }

    @ViewBuilder
    private func menu(_ song: Song, key: Int, part: Part) -> some View {
        Button("Play", systemImage: "play") { play(key, part: part) }
        if key != first(of: part) {
            Button("Play Next", systemImage: "text.insert") { move(key, to: first(of: part), part: part) }
        }
        if key != last(of: part) {
            Button("Move to End", systemImage: "text.append") { move(key, to: last(of: part), part: part) }
        }
        Divider()
        MacSongMenuItems(songs: [song])
        Divider()
        Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(key, part: part) }
    }
}
