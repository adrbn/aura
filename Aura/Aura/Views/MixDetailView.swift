import SwiftUI

/// Detail view for an auto-generated mix: collage header, play/shuffle, save-to-playlist,
/// and the full track list. Mirrors the radio-playlist flow but for on-device mixes.
struct MixDetailView: View {
    let mix: Mix
    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @State private var isSaving = false
    @State private var isSaved = false
    /// The cover's colour, once its photo is in.
    @State private var tint: UIColor?
    @State private var radarService = RadarService.shared

    /// The radar keeps changing while its page is open — a release lands on the server, the
    /// day's catalogue comes in — so it is read live rather than from the value pushed.
    private var radar: Radar? { mix.kind == .radar ? radarService.current : nil }
    private var shown: Mix { radar?.mix ?? mix }
    private var source: PlaybackSource { .mix(id: shown.id, name: shown.title) }
    private var spec: MixCoverSpec { MixCoverSpec(shown) }

    var body: some View {
        List {
            // Header (collage + title + actions) — one full-width row, no separator.
            VStack(spacing: 16) {
                // Cover + name + description sit at the top; the track list follows
                // directly below the buttons, so hiding Save just lifts the list.
                EditorialMixCover(mix: shown, size: 200)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(shown.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(shown.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(countLabel).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            guard let first = shown.songs.first else { return }
                            player.playSong(first, fromQueue: shown.songs, startIndex: 0, source: source)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(accentColor).foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(shown.songs.isEmpty)
                        Button {
                            player.playShuffled(shown.songs, source: source)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(shown.songs.isEmpty)
                    }

                    // Hidden once this exact version of the mix has been saved; reappears
                    // automatically when the mix is regenerated with different songs.
                    if !isSaved && !shown.songs.isEmpty {
                        Button {
                            Task { await save() }
                        } label: {
                            Label("Save as Playlist", systemImage: "plus.circle")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.primary.opacity(0.06)).foregroundStyle(accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(isSaving)
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

            // Song rows — full SongRowView (swipe actions + context menu) with
            // List separators, exactly like a playlist.
            ForEach(Array(shown.songs.enumerated()), id: \.element.id) { index, song in
                SongRowView(song: song, tappableArtist: false) {
                    player.playSong(song, fromQueue: shown.songs, startIndex: index, source: source)
                }
                .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding,
                                          leading: 16,
                                          bottom: AppSettings.shared.listDensity.verticalPadding,
                                          trailing: 16))
            }

            if let missing = radar?.missing, !missing.isEmpty {
                RadarMissingRows(releases: missing)
            }

            Color.clear.frame(height: 80)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TintedCanvas(tint: tint ?? PageTint.tone(spec.accent(MixCoverArt.cached(spec)))))
        .scrollIndicators(.hidden)
        // Title is shown under the cover already — keep the nav bar title empty to avoid a duplicate.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: shown.songs.map(\.id)) { isSaved = MixGenerator.shared.isSavedAsPlaylist(shown) }
        .task { if mix.kind == .radar { await radarService.refreshIfNeeded() } }
        .task(id: spec.taskKey) {
            let art = await MixCoverArt.load(spec)
            if !Task.isCancelled { tint = PageTint.tone(spec.accent(art)) }
        }
        .task {
            // Warm the song-row covers so they're ready instead of loading on scroll.
            ArtworkCache.shared.prefetch(
                coverArtIds: shown.songs.compactMap { $0.coverArt ?? $0.albumId }, pointSize: 50)
        }
    }

    private func save() async {
        guard !isSaving, let server = ServerManager.shared.currentServer else { return }
        isSaving = true
        defer { isSaving = false }
        let name = "\(shown.title) • \(formattedToday)"
        do {
            // Avoid duplicates: update an existing playlist with the same name.
            let existing = try await SubsonicClient.shared.getPlaylists(server: server)
            let existingId = existing.first(where: { $0.name == name })?.id
            try await SubsonicClient.shared.createPlaylist(
                server: server, name: name, songIds: shown.songs.map { $0.id }, playlistId: existingId
            )
            MixGenerator.shared.markSavedAsPlaylist(shown)
            isSaved = true
            ToastManager.shared.show("Saved “\(shown.title)” to your playlists")
        } catch {
            AppLogger.shared.log("❌ Failed to save mix: \(error.localizedDescription)")
            ToastManager.shared.show("Couldn’t save mix", icon: "exclamationmark.triangle.fill")
        }
    }

    private var countLabel: String {
        guard let radar else { return String(localized: "\(mix.songs.count) songs") }
        return String(localized: "\(radar.songs.count) songs · \(radar.releases.count) new releases")
    }

    private var formattedToday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date())
    }
}
