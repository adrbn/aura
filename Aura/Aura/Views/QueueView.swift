import SwiftUI

struct QueueView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @State private var undoQueue: [Song]?
    @State private var undoTimer: Timer?

    var body: some View {
        NavigationStack {
            List {
                // Now playing
                if let song = player.currentSong {
                    Section("Now Playing") {
                        HStack(spacing: 12) {
                            CoverArtImage(coverArt: song.coverArt, size: 50, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(accentColor)
                                    .lineLimit(1)
                                Text(song.artist ?? "Unknown Artist")
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
                        ForEach(Array(player.userQueue.enumerated()), id: \.element.id) { index, song in
                            HStack(spacing: 12) {
                                CoverArtImage(coverArt: song.coverArt, size: 46, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(song.artist ?? "Unknown Artist")
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
                        ForEach(Array(autoNext.enumerated()), id: \.element.id) { index, song in
                            HStack(spacing: 12) {
                                CoverArtImage(coverArt: song.coverArt, size: 46, cornerRadius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(song.artist ?? "Unknown Artist")
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
                        Text("Nothing in the queue")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
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
    }

    private var autoNextSongs: [Song] {
        guard !player.queue.isEmpty, player.queueIndex + 1 < player.queue.count else { return [] }
        return Array(player.queue[(player.queueIndex + 1)...])
    }
}
