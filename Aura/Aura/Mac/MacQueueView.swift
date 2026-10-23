import SwiftUI

/// Whether Up Next is open, so the player bar's button and the pane's own close agree.
@MainActor @Observable final class MacQueuePanel {
    static let shared = MacQueuePanel()
    var isShown = false
}

/// What is coming up, as a pane on the window's right edge — the sidebar's twin, opened and
/// closed from the queue button, so it can stay open beside the library while you browse.
struct MacQueueView: View {
    @State private var player = AudioPlayer.shared
    @State private var hovered: Int?
    @Environment(\.colorScheme) private var scheme

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
            Spacer().frame(height: 10)

            if upcoming.isEmpty && player.userQueue.isEmpty {
                Text("Nothing queued")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A List for its drag to reorder; dressed down to the pane's own look.
                List {
                    if !player.userQueue.isEmpty {
                        Section {
                            ForEach(Array(player.userQueue.enumerated()), id: \.offset) { index, song in
                                row(song, key: -1 - index,
                                    play: {
                                        let song = player.userQueue.remove(at: index)
                                        player.playSong(song, fromQueue: player.queue, startIndex: player.queueIndex, source: .queue)
                                    },
                                    remove: { player.userQueue.remove(at: index) })
                            }
                            .onMove { player.userQueue.move(fromOffsets: $0, toOffset: $1) }
                        } header: {
                            sectionHeader("Next in Queue") {
                                headerButton("xmark.circle", help: "Clear") { player.userQueue = [] }
                            }
                        }
                    }
                    if !upcoming.isEmpty {
                        Section {
                            ForEach(upcoming, id: \.offset) { item in
                                row(item.song, key: item.offset,
                                    play: {
                                        player.playSong(item.song, fromQueue: player.queue,
                                                        startIndex: item.offset, source: player.playbackSource)
                                    },
                                    remove: { player.removeFromQueue(at: item.offset) })
                            }
                            .onMove { source, destination in
                                let start = player.queueIndex + 1
                                player.moveInQueue(from: IndexSet(source.map { $0 + start }), to: destination + start)
                            }
                        } header: {
                            sectionHeader(LocalizedStringKey(player.playbackSource.displayName)) {
                                headerButton("shuffle", help: "Shuffle") { _ = player.shuffleUpNext() }
                                headerButton("xmark.circle", help: "Clear") { player.clearUpNext() }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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

    private func sectionHeader(_ title: LocalizedStringKey, @ViewBuilder buttons: () -> some View) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            buttons()
        }
        .padding(.horizontal, 8)
    }

    private func headerButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// `key` only tells the rows apart for the hover: offsets in the queue, negatives for
    /// the songs added by hand.
    private func row(_ song: Song, key: Int, play: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            CoverArtImage(coverArt: song.coverArt, size: 38, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(song.artist ?? "").font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered == key {
                Button(action: remove) {
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
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play", systemImage: "play", action: play)
            Button("Remove", systemImage: "minus.circle", role: .destructive, action: remove)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
    }
}
