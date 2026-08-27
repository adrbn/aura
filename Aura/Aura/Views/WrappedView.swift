import SwiftUI

/// A month/year retrospective ("Wrapped").
///
/// When Last.fm is configured it's built from real long-term scrobble history;
/// otherwise it falls back to the app's local listening log (accurate only since
/// rich logging began). When both are available the user can switch sources.
struct WrappedView: View {
    @Environment(\.appAccentColor) private var accent

    @State private var period: WrappedPeriod
    @State private var source: ListeningStats.Source
    @State private var stats: ListeningStats?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isSaved = false

    init(initialPeriod: WrappedPeriod = .currentYear) {
        _period = State(initialValue: initialPeriod)
        _source = State(initialValue: AppSettings.shared.lastfmConfigured ? .lastfm : .device)
    }

    private var lastfmAvailable: Bool { AppSettings.shared.lastfmConfigured }
    private var offeredPeriods: [WrappedPeriod] {
        let p = WrappedAvailability.offeredPeriods()
        return p.isEmpty ? [.currentYear] : p
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 90)
            .animation(.easeInOut(duration: 0.25), value: isLoading)
        }
        .scrollIndicators(.hidden)
        .auraPageBackground()
        .navigationTitle("Wrapped")
        .navigationBarTitleDisplayMode(.inline)
        // Source / period filters and Save live in a toolbar menu so the stats sit right
        // under the hero instead of being pushed down by stacked controls.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if lastfmAvailable {
                        Picker("Source", selection: $source) {
                            Label("Last.fm", systemImage: "waveform").tag(ListeningStats.Source.lastfm)
                            Label("This Device", systemImage: "iphone").tag(ListeningStats.Source.device)
                        }
                    }
                    if offeredPeriods.count > 1 {
                        Picker("Period", selection: $period) {
                            ForEach(offeredPeriods, id: \.self) { p in
                                Text(p.pickerLabel).tag(p)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .task(id: reloadKey) { await reload() }
    }

    private var reloadKey: String { "\(period)-\(source == .lastfm ? "lf" : "dev")" }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading your \(period.title)…")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let errorMessage {
            errorCard(errorMessage)
        } else if let stats, stats.hasData {
            savePlaylistButton(stats)
            statTiles(stats)
            if !stats.topSongs.isEmpty { topSongsCard(stats) }
            if !stats.topArtists.isEmpty { topArtistsCard(stats) }
            if !stats.topAlbums.isEmpty { topAlbumsCard(stats) }
            if !stats.topGenres.isEmpty { topGenresCard(stats) }
            sourceFootnote(stats)
        } else {
            emptyState
        }
    }

    // MARK: - Loading

    private func reload() async {
        errorMessage = nil
        if source == .lastfm {
            isLoading = true
            defer { isLoading = false }
            do {
                let wrapped = try await LastfmService.shared.fetchWrapped(period: period)
                stats = ListeningStats.from(lastfm: wrapped, period: period)
            } catch {
                stats = nil
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            stats = ListeningStats.compute(from: PlayHistory.shared.allPlays(), period: period)
        }
        // Reflect whether *this exact* retrospective was already solidified.
        isSaved = stats.map(isAlreadySaved) ?? false
        // Enrich the shown rows with real server cover art + tap targets (Last.fm serves
        // star placeholders and has no ids; even device rows lack server album/artist ids).
        if let s = stats { await resolveArtwork(for: s) }
    }

    // MARK: - Server resolution (real cover art + tap targets)

    /// Resolve the top rows shown in each card to server entities, then merge their ids
    /// and cover art into `stats`. Best-effort and bounded to the visible top 5.
    private func resolveArtwork(for s: ListeningStats) async {
        guard let server = ServerManager.shared.currentServer, ServerManager.shared.isConnected else { return }
        async let songs = resolveSongs(Array(s.topSongs.prefix(5)), server: server)
        async let albums = resolveAlbums(Array(s.topAlbums.prefix(5)), server: server)
        async let artists = resolveArtists(Array(s.topArtists.prefix(5)), server: server)
        let (sMap, alMap, arMap) = await (songs, albums, artists)
        // Only apply if the user hasn't switched period/source in the meantime.
        guard stats?.period == s.period, stats?.source == s.source else { return }
        stats = s.withResolved(songs: sMap, albums: alMap, artists: arMap)
    }

    private func resolveSongs(_ songs: [ListeningStats.RankedSong], server: ServerConfig) async -> [String: ListeningStats.Resolved] {
        var out: [String: ListeningStats.Resolved] = [:]
        await withTaskGroup(of: (String, ListeningStats.Resolved?).self) { group in
            for song in songs {
                // Device rows already carry a real id + cover → nothing to fetch.
                if let sid = song.serverId, song.coverArt != nil {
                    out[song.id] = ListeningStats.Resolved(serverId: sid, coverArt: song.coverArt)
                    continue
                }
                group.addTask {
                    let r = try? await SubsonicClient.shared.search3(
                        server: server, query: "\(song.title) \(song.artist)", artistCount: 0, albumCount: 0, songCount: 5)
                    let m = Self.bestMatch(in: r?.song ?? [], title: song.title, artist: song.artist)
                    return (song.id, m.map { ListeningStats.Resolved(serverId: $0.id, coverArt: $0.coverArt) })
                }
            }
            for await (id, res) in group { if let res { out[id] = res } }
        }
        return out
    }

    private func resolveAlbums(_ albums: [ListeningStats.RankedAlbum], server: ServerConfig) async -> [String: ListeningStats.Resolved] {
        var out: [String: ListeningStats.Resolved] = [:]
        await withTaskGroup(of: (String, ListeningStats.Resolved?).self) { group in
            for album in albums {
                group.addTask {
                    let r = try? await SubsonicClient.shared.search3(
                        server: server, query: "\(album.name) \(album.artist)", artistCount: 0, albumCount: 5, songCount: 0)
                    let m = Self.bestAlbumMatch(in: r?.album ?? [], name: album.name, artist: album.artist)
                    return (album.id, m.map { ListeningStats.Resolved(serverId: $0.id, coverArt: $0.coverArt) })
                }
            }
            for await (id, res) in group { if let res { out[id] = res } }
        }
        return out
    }

    private func resolveArtists(_ artists: [ListeningStats.RankedArtist], server: ServerConfig) async -> [String: ListeningStats.Resolved] {
        var out: [String: ListeningStats.Resolved] = [:]
        await withTaskGroup(of: (String, ListeningStats.Resolved?).self) { group in
            for artist in artists {
                group.addTask {
                    let r = try? await SubsonicClient.shared.search3(
                        server: server, query: artist.name, artistCount: 5, albumCount: 0, songCount: 0)
                    let m = Self.bestArtistMatch(in: r?.artist ?? [], name: artist.name)
                    return (artist.id, m.map { ListeningStats.Resolved(serverId: $0.id, coverArt: $0.coverArt) })
                }
            }
            for await (id, res) in group { if let res { out[id] = res } }
        }
        return out
    }

    private static func bestArtistMatch(in artists: [Artist], name: String) -> Artist? {
        let n = name.lowercased()
        return artists.first(where: { $0.name.lowercased() == n })
            ?? artists.first(where: { let a = $0.name.lowercased(); return a.contains(n) || n.contains(a) })
    }

    private static func bestAlbumMatch(in albums: [Album], name: String, artist: String) -> Album? {
        let n = name.lowercased(), a = artist.lowercased()
        let nameMatches = albums.filter {
            let an = $0.name.lowercased(); return an == n || an.contains(n) || n.contains(an)
        }
        guard !nameMatches.isEmpty else { return nil }
        return nameMatches.first(where: {
            let aa = $0.artist?.lowercased() ?? ""; return !a.isEmpty && (aa.contains(a) || a.contains(aa))
        }) ?? nameMatches.first
    }

    // MARK: - Save as Playlist (solidify, like a mix)

    private func saveAsPlaylist(_ stats: ListeningStats) async {
        guard !isSaving, let server = ServerManager.shared.currentServer else { return }
        isSaving = true
        defer { isSaving = false }

        let ids: [String]
        if stats.source == .device {
            // Device top songs already carry real Subsonic song ids.
            ids = Array(stats.topSongs.map(\.id).prefix(50))
        } else {
            // Last.fm tracks are name+artist only — resolve each to a server song.
            ids = await resolveLastfmSongIds(Array(stats.topSongs.prefix(40)), server: server)
        }
        guard !ids.isEmpty else {
            ToastManager.shared.show("No matching songs on your server", icon: "exclamationmark.triangle.fill")
            return
        }
        let name = "Wrapped • \(stats.period.title)"
        do {
            // Re-saving updates the existing playlist with the same name (no dupes).
            let existing = try await SubsonicClient.shared.getPlaylists(server: server)
            let existingId = existing.first(where: { $0.name == name })?.id
            _ = try await SubsonicClient.shared.createPlaylist(server: server, name: name, songIds: ids, playlistId: existingId)
            markSaved(stats)
            isSaved = true
            ToastManager.shared.show("Saved “\(name)” to your playlists")
        } catch {
            AppLogger.shared.log("❌ Failed to save Wrapped: \(error.localizedDescription)")
            ToastManager.shared.show("Couldn’t save Wrapped", icon: "exclamationmark.triangle.fill")
        }
    }

    /// Resolve Last.fm (title, artist) pairs to server song ids via search, with a
    /// small concurrency window so we don't flood the server.
    private func resolveLastfmSongIds(_ songs: [ListeningStats.RankedSong], server: ServerConfig) async -> [String] {
        let window = 6
        var collected: [(Int, String?)] = []
        await withTaskGroup(of: (Int, String?).self) { group in
            var added = 0
            for (index, song) in songs.enumerated() {
                if added >= window, let r = await group.next() { collected.append(r) }
                group.addTask {
                    let query = "\(song.title) \(song.artist)"
                    let result = try? await SubsonicClient.shared.search3(
                        server: server, query: query, artistCount: 0, albumCount: 0, songCount: 5)
                    let match = Self.bestMatch(in: result?.song ?? [], title: song.title, artist: song.artist)
                    return (index, match?.id)
                }
                added += 1
            }
            for await r in group { collected.append(r) }
        }
        return collected.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
    }

    /// Pick the server song that best matches a Last.fm track; skip (nil) if the
    /// title doesn't match at all, to avoid adding unrelated songs.
    private static func bestMatch(in songs: [Song], title: String, artist: String) -> Song? {
        guard !songs.isEmpty else { return nil }
        let t = title.lowercased(), a = artist.lowercased()
        let titleMatches = songs.filter {
            let st = $0.title.lowercased()
            return st == t || st.contains(t) || t.contains(st)
        }
        guard !titleMatches.isEmpty else { return nil }
        if let both = titleMatches.first(where: {
            let sa = $0.artist?.lowercased() ?? ""
            return !a.isEmpty && (sa.contains(a) || a.contains(sa))
        }) { return both }
        return titleMatches.first
    }

    // MARK: - Saved-state tracking (UserDefaults; mirrors the mix signature flow)

    private var savedKey: String { "musika_wrapped_saved_v1" }

    private func savedSignatures() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String]) ?? [:]
    }

    private func signature(for stats: ListeningStats) -> String {
        let head = stats.topSongs.prefix(50).map { "\($0.title)|\($0.artist)" }.joined(separator: "~")
        var h = 5381
        for b in "\(stats.period.title)|\(head)".utf8 { h = ((h &* 33) &+ Int(b)) & 0x7fffffffffffffff }
        return String(h, radix: 16)
    }

    private func isAlreadySaved(_ stats: ListeningStats) -> Bool {
        savedSignatures()[stats.period.title] == signature(for: stats)
    }

    private func markSaved(_ stats: ListeningStats) {
        var sigs = savedSignatures()
        sigs[stats.period.title] = signature(for: stats)
        UserDefaults.standard.set(sigs, forKey: savedKey)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            GeneratedCoverView(nature: .retrospective(period.coverLabel), size: 200, cornerRadius: 24)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            VStack(spacing: 4) {
                Text(period.title).font(.largeTitle.bold())
                Text(heroSubtitle).font(.headline).foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var heroSubtitle: String {
        if let stats, stats.hasData { return stats.personality }
        return "Your year in music"
    }

    // MARK: - Save as playlist (prominent)

    private func savePlaylistButton(_ stats: ListeningStats) -> some View {
        Button {
            Task { await saveAsPlaylist(stats) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSaved ? AnyShapeStyle(accent) : AnyShapeStyle(accent.opacity(0.15)))
                        .frame(width: 34, height: 34)
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isSaved ? "star.fill" : "plus")
                            .font(.subheadline.bold())
                            .foregroundStyle(isSaved ? .white : accent)
                    }
                }
                Text(isSaved ? "Saved to Playlists" : "Save as Playlist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSaved ? .secondary : .primary)
                Spacer()
                if !isSaved && !isSaving {
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isSaving || isSaved)
        .animation(.easeInOut(duration: 0.2), value: isSaved)
    }

    // MARK: - Stat tiles

    @ViewBuilder
    private func statTiles(_ stats: ListeningStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(tiles(for: stats), id: \.title) { tile in
                statTile(tile.title, value: tile.value, icon: tile.icon)
            }
        }
    }

    private func tiles(for stats: ListeningStats) -> [(title: String, value: String, icon: String)] {
        let time = timeLabel(stats.totalMinutes)
        switch stats.source {
        case .device:
            return [
                ("Songs Played", "\(stats.totalPlays)", "play.circle.fill"),
                ("Listening Time", time, "clock.fill"),
                ("Unique Songs", "\(stats.uniqueSongs)", "music.note"),
                ("Artists", "\(stats.uniqueArtists)", "music.mic")
            ]
        case .lastfm:
            let second: (String, String, String) = stats.totalMinutes > 0
                ? ("Listening Time", "~\(time)", "clock.fill")
                : ("All-Time Scrobbles", abbreviate(stats.allTimeScrobbles ?? 0), "infinity")
            return [
                ("Scrobbles", abbreviate(stats.totalPlays), "waveform.path.ecg"),
                second,
                // Distinct tracks/artists across the whole period (Last.fm @attr total),
                // abbreviated — not the fetch cap that used to read a flat "200".
                ("Different Tracks", abbreviate(stats.uniqueSongs), "music.note"),
                ("Different Artists", abbreviate(stats.uniqueArtists), "music.mic")
            ]
        }
    }

    private func timeLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60.0
        return hours < 10 ? String(format: "%.1f hrs", hours) : "\(Int(hours.rounded())) hrs"
    }

    private func abbreviate(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        return "\(n)"
    }

    private func statTile(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundStyle(accent)
            Text(value).font(.title.bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Lists

    private func topSongsCard(_ stats: ListeningStats) -> some View {
        cardSection(title: "Top Songs", icon: "star.fill") {
            VStack(spacing: 12) {
                ForEach(Array(stats.topSongs.prefix(5).enumerated()), id: \.element.id) { index, song in
                    Button {
                        if let sid = song.serverId { playServerSong(id: sid) }
                    } label: {
                        HStack(spacing: 12) {
                            rankBadge(index + 1)
                            WrappedArtwork(coverArt: song.coverArt, imageURL: song.imageURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            playsLabel(song.plays)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(song.serverId == nil)
                }
            }
        }
    }

    private func playServerSong(id: String) {
        guard let server = ServerManager.shared.currentServer else { return }
        Task {
            if let song = try? await SubsonicClient.shared.getSong(server: server, id: id) {
                await MainActor.run { AudioPlayer.shared.playSong(song) }
            }
        }
    }

    private func topArtistsCard(_ stats: ListeningStats) -> some View {
        cardSection(title: "Top Artists", icon: "music.mic") {
            VStack(spacing: 12) {
                ForEach(Array(stats.topArtists.prefix(5).enumerated()), id: \.element.id) { index, artist in
                    let row = HStack(spacing: 12) {
                        rankBadge(index + 1)
                        // serverCoverArt is the real library image; Last.fm dropped artist art.
                        WrappedArtwork(coverArt: artist.serverCoverArt, imageURL: artist.imageURL, size: 44, circle: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            if artist.minutes > 0 {
                                Text("\(artist.minutes) min").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        playsLabel(artist.plays)
                    }
                    .contentShape(Rectangle())

                    if let sid = artist.serverId {
                        NavigationLink {
                            ArtistDetailView(artistId: sid, artistName: artist.name, coverArt: artist.serverCoverArt)
                        } label: { row }
                        .buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            }
        }
    }

    private func topAlbumsCard(_ stats: ListeningStats) -> some View {
        cardSection(title: "Top Albums", icon: "square.stack.fill") {
            VStack(spacing: 12) {
                ForEach(Array(stats.topAlbums.prefix(5).enumerated()), id: \.element.id) { index, album in
                    let row = HStack(spacing: 12) {
                        rankBadge(index + 1)
                        WrappedArtwork(coverArt: album.coverArt, imageURL: album.imageURL, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        playsLabel(album.plays)
                    }
                    .contentShape(Rectangle())

                    if let sid = album.serverId {
                        NavigationLink { AlbumDetailView(albumId: sid) } label: { row }
                            .buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            }
        }
    }

    private func topGenresCard(_ stats: ListeningStats) -> some View {
        cardSection(title: "Top Genres", icon: "guitars.fill") {
            let maxPlays = max(stats.topGenres.first?.plays ?? 1, 1)
            VStack(spacing: 10) {
                ForEach(stats.topGenres) { genre in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(genre.name).font(.subheadline.weight(.medium))
                            Spacer()
                            if stats.source == .device {
                                Text("\(genre.plays)×").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        GeometryReader { geo in
                            Capsule().fill(accent.opacity(0.25))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(accent)
                                        .frame(width: geo.size.width * CGFloat(genre.plays) / CGFloat(maxPlays))
                                }
                        }
                        .frame(height: 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sourceFootnote(_ stats: ListeningStats) -> some View {
        if stats.source == .lastfm {
            VStack(spacing: 2) {
                Text("Powered by your Last.fm scrobbles")
                if let year = stats.scrobblingSinceYear {
                    Text("Scrobbling since \(String(year))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    // MARK: - Empty / error

    private var emptyState: some View {
        let isLastfm = source == .lastfm
        return VStack(spacing: 14) {
            Image(systemName: isLastfm ? "waveform.slash" : "hourglass")
                .font(.system(size: 40)).foregroundStyle(accent)
            Text(isLastfm ? "No scrobbles for \(period.title) yet" : "Your Wrapped is still being written")
                .font(.headline).multilineTextAlignment(.center)
            Text(isLastfm
                 ? "Once Last.fm has scrobbles in this period, your top songs, artists, and genres show up here."
                 : "Keep listening — your top songs, artists, and genres for \(period.title) will appear here as you play music.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 18))
        .padding(.top, 8)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud").font(.system(size: 36)).foregroundStyle(.orange)
            Text("Couldn't load from Last.fm").font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Retry") { Task { await reload() } }
                    .buttonStyle(.borderedProminent)
                Button("Use Device Data") { source = .device }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 18))
        .padding(.top, 8)
    }

    // MARK: - Building blocks

    private func playsLabel(_ plays: Int) -> some View {
        Text("\(abbreviate(plays))×")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func cardSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(accent)
                Text(title).font(.title3.bold())
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 18))
    }

    private func rankBadge(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.subheadline.bold().monospacedDigit())
            .foregroundStyle(rank == 1 ? .white : .secondary)
            .frame(width: 26, height: 26)
            .background(rank == 1 ? AnyShapeStyle(accent) : AnyShapeStyle(Color.themeGroupedBg), in: Circle())
    }
}

/// Artwork for a Wrapped row — a Subsonic cover id (device source) or a remote
/// Last.fm image URL, falling back to a music-note placeholder.
private struct WrappedArtwork: View {
    let coverArt: String?
    let imageURL: String?
    var size: CGFloat = 44
    var circle: Bool = false

    var body: some View {
        Group {
            if let coverArt {
                CoverArtImage(coverArt: coverArt, size: size, cornerRadius: circle ? size / 2 : 8)
            } else if let imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
                .frame(width: size, height: size)
                .clipShape(shape)
            } else {
                placeholder.frame(width: size, height: size).clipShape(shape)
            }
        }
    }

    private var shape: AnyShape {
        circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        ZStack {
            Color(.systemGray5)
            Image(systemName: "music.note").foregroundStyle(.secondary).font(.system(size: size * 0.4))
        }
    }
}
