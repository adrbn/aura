import SwiftUI

struct RadioPlaylistView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var isSaved = false

    var body: some View {
        List {
            // Header — cover/name/desc sit at the top; the song list follows directly
            // below the buttons (no vertical centering that would shift on save).
            VStack(spacing: 16) {
                CoverArtAsyncImage(coverArt: player.radioPlaylistCoverArt, size: 200)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(player.radioPlaylistName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)

                    Text("\(player.radioPlaylistSongs.count) Songs")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Play/Shuffle and Save share one spaced stack so Save never
                // overlaps the buttons above it.
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            guard !player.radioPlaylistSongs.isEmpty else { return }
                            player.playRadioPlaylistFromIndex(0)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(accentColor).foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.radioPlaylistSongs.isEmpty)
                        Button {
                            guard !player.radioPlaylistSongs.isEmpty else { return }
                            player.playShuffled(player.radioPlaylistSongs, source: .radio(name: player.radioPlaylistName))
                            player.isRadioMode = true
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.radioPlaylistSongs.isEmpty)
                    }

                    if !isSaved {
                        Button {
                            guard !player.radioPlaylistSongs.isEmpty else { return }
                            Task {
                                await player.saveRadioPlaylist()
                                isSaved = true
                                ToastManager.shared.show("Saved to your playlists")
                            }
                        } label: {
                            Label("Save as Playlist", systemImage: "plus.circle")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.primary.opacity(0.06)).foregroundStyle(accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.radioPlaylistSongs.isEmpty)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            // Loading indicator
            if player.isFetchingRadioSongs {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Finding similar songs...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            // Song list
            ForEach(Array(player.radioPlaylistSongs.enumerated()), id: \.element.id) { index, song in
                SongRowView(song: song) {
                    player.playRadioPlaylistFromIndex(index)
                }
                .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                          leading: 16,
                                          bottom: AppSettings.shared.listDensity.verticalPadding,
                                          trailing: 16))
            }

            Color.clear.frame(height: 80)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        player.refreshRadioQueue()
                        isSaved = false   // refreshed songs → offer saving the new version again
                    } label: {
                        Label("Refresh Songs", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    .disabled(player.radioPlaylistSongs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                }
            }
        }
    }
}
