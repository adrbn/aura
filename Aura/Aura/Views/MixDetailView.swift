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
    /// A radar release opened on its own page.
    @State private var openedRelease: RadarRelease?

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
                            Task { await play(shuffled: false) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(accentColor).foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canPlay)
                        Button {
                            Task { await play(shuffled: true) }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canPlay)
                    }

                    // Hidden once this exact version of the mix has been saved; reappears
                    // automatically when the mix is regenerated with different songs. Not on
                    // the radar: it changes by the day and half of it is previews, so a saved
                    // copy would be a few songs of each downloaded release, frozen.
                    if !isSaved && !shown.songs.isEmpty && mix.kind != .radar {
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

            if let radar {
                // The radar lists releases, not songs: an album is one row whatever the server
                // has of it, and the order is the releases', newest first.
                RadarReleaseRows(releases: radar.releases, held: wholeOnServer) { openedRelease = $0 }
            } else if mix.kind != .radar {
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
            }

            ListEndSpacer()
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
        .navigationDestination(item: $openedRelease) { RadarReleaseView(release: $0) }
        .task(id: shown.songs.map(\.id)) { isSaved = MixGenerator.shared.isSavedAsPlaylist(shown) }
        .task {
            guard mix.kind == .radar else { return }
            await radarService.refreshIfNeeded()
            #if !APPSTORE_BUILD
            await ReleaseFetcher.shared.settlePicked()
            #endif
            await radarService.loadTrackLists()
        }
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
            let saved = try await SubsonicClient.shared.createPlaylist(
                server: server, name: name, songIds: shown.songs.map { $0.id }, playlistId: existingId
            )
            MixGenerator.shared.markSavedAsPlaylist(shown)
            isSaved = true
            ToastManager.shared.show("Saved “\(shown.title)” to your playlists")
            // The mix's cover goes along, photo in, instead of the server's collage of its songs.
            if let cover = await EditorialMixCover.jpeg(of: shown) {
                await PlaylistCovers.upload(cover, playlistId: existingId ?? saved.id, server: server)
            }
        } catch {
            AppLogger.shared.log("❌ Failed to save mix: \(error.localizedDescription)")
            ToastManager.shared.show("Couldn’t save mix", icon: "exclamationmark.triangle.fill")
        }
    }

    /// The releases the server has whole, marked as such. The others are still to get, in full
    /// or in part — or had songs fetched one by one, until it's known whether the rest is in.
    private var wholeOnServer: Set<String> {
        guard let radar else { return [] }
        var toGet = Set(radar.listed.map(\.id))
        #if !APPSTORE_BUILD
        toGet.formUnion(ReleaseFetcher.shared.picked)
        #endif
        return Set(radar.releases.map(\.id)).subtracting(toGet)
    }

    private var countLabel: String {
        guard let radar else { return String(localized: "\(mix.songs.count) songs") }
        // Counted once the previews are in, so it never reads "0 songs" over a page of them.
        let songs = radarService.queue.count
        guard songs > 0 else { return String(localized: "\(radar.releases.count) new releases") }
        return String(localized: "\(songs) songs · \(radar.releases.count) new releases")
    }

    /// The radar plays its releases' previews too, so it has something to play as soon as it
    /// has releases, whether or not the server has any of them.
    private var canPlay: Bool {
        guard let radar else { return !shown.songs.isEmpty }
        return !radar.releases.isEmpty
    }

    private func play(shuffled: Bool) async {
        var songs = shown.songs
        if radar != nil {
            // A preview's address lasts a quarter of an hour: fetch what has gone stale.
            await radarService.loadTrackLists()
            songs = radarService.queue
        }
        guard let first = songs.first else { return }
        if shuffled {
            player.playShuffled(songs, source: source)
        } else {
            player.playSong(first, fromQueue: songs, startIndex: 0, source: source)
        }
    }

    private var formattedToday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date())
    }
}
