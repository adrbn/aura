import SwiftUI

#if os(iOS)
struct RadioPlaylistView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var isSaved = false
    @State private var isSaving = false
    /// The radio cover's colour: its seed artist's photo.
    @State private var tint: (seed: String, color: UIColor)?

    private var radioSeed: ArtistRef? { player.radioPlaylistSongs.first.flatMap(CoverArtists.lead(of:)) }

    /// Space kept clear at the bottom of the list for the floating mini player.
    private let miniPlayerClearance: CGFloat = 80

    /// A radio that holds nothing but its seed while its songs are fetched isn't ready to
    /// show. Listing the seed there made it look like the radio's first — or only — song,
    /// with the loader wedged in above it.
    private var isAwaitingSongs: Bool {
        player.isFetchingRadioSongs && player.radioPlaylistSongs.count <= 1
    }

    var body: some View {
        List {
            // Header — cover/name/desc sit at the top; the song list follows directly
            // below the buttons (no vertical centering that would shift on save).
            DetailHeader {
                EditorialRadioCover(songs: player.radioPlaylistSongs,
                                    fallbackName: player.radioPlaylistName
                                        .replacingOccurrences(of: "Radio: ", with: ""),
                                    size: 200,
                                    isLoading: player.isFetchingRadioSongs)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            } titles: { wide in
                // The count closes the list, as it does an album's.
                Text(player.radioPlaylistName)
                    .font(wide ? .title.bold() : .title2.bold())
                    .lineLimit(2)
            } controls: {
                // Play/Shuffle and Save share one spaced stack so Save never
                // overlaps the buttons above it.
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            guard !player.radioPlaylistSongs.isEmpty else { return }
                            player.playRadioPlaylistFromIndex(0)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .lineLimit(1).minimumScaleFactor(0.8)
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
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(player.radioPlaylistSongs.isEmpty)
                    }

                    SaveAsPlaylistButton(isSaving: isSaving, isSaved: isSaved, accent: accentColor) {
                        guard !player.radioPlaylistSongs.isEmpty else { return }
                        Task { await save() }
                    }
                    // Would save a one-song playlist out of a radio still being built.
                    .disabled(player.radioPlaylistSongs.isEmpty || isAwaitingSongs)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, DetailListLayout.gap)
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if isAwaitingSongs {
                // Nothing to list yet: rows in the list's shape stand in for it.
                SkeletonSongList(count: 8)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
            } else {
                // More songs on their way for a list that already has some (a refresh, or
                // an artist mix that opens with the artist's own top songs).
                if player.isFetchingRadioSongs {
                    SkeletonSongList(count: 2)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
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
                if !player.radioPlaylistSongs.isEmpty && !player.isFetchingRadioSongs {
                    ListSummaryRow(text: ListSummaryRow.text(songs: player.radioPlaylistSongs))
                }
            }

            // The fetch card's room too, while it shows — a fixed clearance left the last
            // songs under it.
            ListEndSpacer(height: miniPlayerClearance)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TintedCanvas(tint: tint?.seed == radioSeed?.id ? tint?.color : nil))
        .task(id: radioSeed?.id) {
            guard let seed = radioSeed else { return }
            let portrait = await CoverPortraits.load(seed, subject: false)
            let base = portrait?.band ?? CoverPalette.hashed(seed.name)
            if !Task.isCancelled { tint = (seed.id, PageTint.tone(base)) }
        }
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
                .tint(.primary)
            }
        }
    }

    /// The radio as a playlist, its cover along with it — the one on this page, photos in.
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        guard let playlistId = await player.saveRadioPlaylist() else {
            ToastManager.shared.show(String(localized: "Couldn’t save radio"), icon: "exclamationmark.triangle.fill")
            return
        }
        isSaved = true
        ToastManager.shared.show(String(localized: "Saved to your playlists"))
        let spec = RadioCoverSpec(songs: player.radioPlaylistSongs,
                                  fallbackName: player.radioPlaylistName.replacingOccurrences(of: "Radio: ", with: ""))
        guard let cover = await spec.jpeg(), let server = ServerManager.shared.currentServer else { return }
        await PlaylistCovers.upload(cover, playlistId: playlistId, server: server)
    }
}
#endif

/// Save as Playlist, saying what it is doing: it breathes while the playlist is written, then
/// stays as Saved until there is a new version to save.
struct SaveAsPlaylistButton: View {
    let isSaving: Bool
    let isSaved: Bool
    let accent: Color
    let action: () -> Void
    @State private var breathing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Saved")
                } else if isSaving {
                    ProgressView().controlSize(.small).tint(accent)
                    Text("Saving…")
                } else {
                    Image(systemName: "plus.circle")
                    Text("Save as Playlist")
                }
            }
            .lineLimit(1)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(accent.opacity(isSaving && !isSaved ? (breathing ? 0.24 : 0.08) : isSaved ? 0.14 : 0))
            .background(Color.primary.opacity(0.06)).foregroundStyle(accent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: isSaved)
            .animation(.easeInOut(duration: 0.25), value: isSaving)
        }
        .buttonStyle(.borderless)
        .disabled(isSaving || isSaved)
        .onChange(of: isSaving, initial: true) { _, saving in
            guard saving else { breathing = false; return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}
