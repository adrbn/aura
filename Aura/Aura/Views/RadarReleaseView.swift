import SwiftUI

/// A radar release opened like an album: every song Deezer lists for it, those the server has
/// marked and played from it, the rest playing their preview — and, in the sideload build, to
/// be had one by one or all at once.
struct RadarReleaseView: View {
    let release: RadarRelease

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.openURL) private var openURL
    @State private var radarService = RadarService.shared
    @State private var tracks: [DeezerTrack]?
    @State private var unreachable = false
    @State private var tint: UIColor?
    /// The release's songs on the server, looked up in full once the page opens.
    @State private var held: [Song]?

    private var source: PlaybackSource { .mix(id: "radar", name: String(localized: "Radar")) }
    /// The release in its own order: the server's copy of each song it has, the preview of
    /// the rest.
    private var songs: [Song] {
        tracks?.compactMap { librarySong(for: $0) ?? $0.previewSong(of: release) } ?? []
    }

    /// The release's songs the server has, wherever they're filed — a single that came out
    /// ahead of it, songs fetched one by one. The radar's few until the full look-up lands.
    private var onServer: [Song] { held ?? radarService.current?.inLibrary[release.id] ?? [] }

    private var canFetch: Bool {
        #if APPSTORE_BUILD
        return false
        #else
        return ReleaseFetcher.shared.isAvailable
        #endif
    }

    /// The server has every song of the release: there is nothing left to get.
    private var isWhole: Bool {
        guard let tracks, !tracks.isEmpty else { return false }
        return tracks.allSatisfy { librarySong(for: $0) != nil }
    }

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            if let tracks {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    RadarTrackRow(track: track, number: track.track_position ?? index + 1, release: release,
                                  librarySong: librarySong(for: track), canFetch: canFetch) {
                        play(track)
                    }
                    .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                              bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                // Closes the list as it does an album's.
                ListSummaryRow(text: meta)
            } else if unreachable {
                ContentUnavailableView {
                    Label("Deezer couldn't be reached", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Pull down to try again.")
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                SkeletonSongList(count: 6, showsArt: false)
                    .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                              bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 16))
            }

            ListEndSpacer()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(TintedCanvas(tint: tint))
        .scrollIndicators(.hidden)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let link = release.link.flatMap(URL.init(string:)) {
                        Button { openURL(link) } label: { Label("Open in Deezer", systemImage: "arrow.up.right") }
                    }
                    if let artistId = release.artist.libraryId {
                        Button { player.pendingArtistId = artistId } label: {
                            Label("Go to Artist", systemImage: "person")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(.primary)
                .accessibilityLabel("More")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .task {
            guard let cover = release.largeCover else { return }
            tint = await PageTint.load(cover)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 16) {
            CoverArtImage(coverArt: release.largeCover, size: 220, cornerRadius: 12, placeholderName: release.title)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(release.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if let artistId = release.artist.libraryId {
                    Button { player.pendingArtistId = artistId } label: {
                        Text(release.byline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accentColor)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(release.byline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button { play(nil) } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.borderless)
                .disabled(songs.isEmpty)

                if canFetch && !isWhole {
                    getAllButton
                } else {
                    Button { player.playShuffled(songs, source: source) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.borderless)
                    .disabled(songs.isEmpty)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 12)
        .padding(.bottom, DetailListLayout.gap)
        .frame(maxWidth: .infinity)
    }

    /// "Single · 25 Sept 2026 · 12 songs · 41 min"
    private var meta: String {
        var parts = [release.typeLabel]
        if let date = release.releaseDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let tracks {
            parts.append(String(localized: "\(tracks.count) songs"))
            let seconds = tracks.compactMap(\.duration).reduce(0, +)
            if seconds > 0 { parts.append(String(localized: "\(max(1, seconds / 60)) min")) }
        }
        return parts.joined(separator: " · ")
    }

    /// The whole release in one tap, and how far along it is.
    @ViewBuilder
    private var getAllButton: some View {
        #if !APPSTORE_BUILD
        let fetch = ReleaseFetcher.shared.fetch(for: release.id)
        let failed = fetch?.stage == .failed
        Button { ReleaseFetcher.shared.get(release) } label: {
            Label(getAllTitle(fetch), systemImage: getAllIcon(fetch))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Color.primary.opacity(0.08))
                .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.borderless)
        .disabled(fetch.map { $0.isActive || $0.stage == .ready } ?? false)
        #endif
    }

    #if !APPSTORE_BUILD
    private func getAllTitle(_ fetch: ReleaseFetch?) -> String {
        switch fetch?.stage {
        case nil: return String(localized: "Get \(release.typeLabel)")
        case .failed?: return String(localized: "Try Again")
        case .ready?: return String(localized: "In Your Library")
        case .downloading? where fetch!.progress > 0:
            return "\(fetch!.headline) · \(fetch!.progress.formatted(.percent.precision(.fractionLength(0))))"
        default: return fetch!.headline
        }
    }

    private func getAllIcon(_ fetch: ReleaseFetch?) -> String {
        switch fetch?.stage {
        case nil: return "arrow.down.circle"
        case .failed?: return "arrow.clockwise"
        case .ready?: return "checkmark.circle.fill"
        default: return "arrow.down.circle.dotted"
        }
    }
    #endif

    // MARK: Playing

    private func librarySong(for track: DeezerTrack) -> Song? {
        onServer.first { RadarRules.sameTitle($0.title, track.title) }
    }

    /// From the top, or from one song, through the release in its own order — the server's
    /// copies and the previews of the rest — then on into the rest of the radar, as its
    /// playlist would.
    private func play(_ track: DeezerTrack?) {
        let songs = songs
        let song: Song?
        if let track {
            let id = librarySong(for: track)?.id ?? "deezer-\(track.id)"
            song = songs.first { $0.id == id }
        } else {
            song = songs.first
        }
        guard let song else {
            ToastManager.shared.show(track == nil ? String(localized: "No previews for this release")
                                                  : String(localized: "No preview for this song"),
                                     icon: "speaker.slash")
            return
        }
        start(song, of: songs)
    }

    private func start(_ song: Song, of songs: [Song]) {
        let queue = radarService.queue(playing: songs, of: release)
        let index = queue.firstIndex { $0.id == song.id } ?? 0
        player.playSong(song, fromQueue: queue, startIndex: index, source: source)
    }

    private func load() async {
        let loaded = await radarService.tracks(of: release)
        if let loaded { tracks = loaded }
        unreachable = loaded == nil && tracks == nil
        held = await radarService.held(release)
    }
}

/// One song of a radar release: its number, title and length — its preview on a tap, and
/// what the sideload build can do to get it.
private struct RadarTrackRow: View {
    let track: DeezerTrack
    let number: Int
    let release: RadarRelease
    let librarySong: Song?
    let canFetch: Bool
    let play: () -> Void

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor

    private var isCurrent: Bool {
        guard let current = player.currentSong?.id else { return false }
        return current == "deezer-\(track.id)" || current == librarySong?.id
    }

    /// What the queue gets: the server's copy, or the preview.
    private var song: Song? { librarySong ?? track.previewSong(of: release) }

    private var subtitle: String {
        var parts: [String] = []
        if let name = track.artist?.name, !release.isBy(name) { parts.append(name) }
        if let seconds = track.duration, seconds > 0 {
            parts.append(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(isCurrent ? AnyShapeStyle(accentColor) : AnyShapeStyle(.secondary))
                .frame(minWidth: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accentColor) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
                .frame(width: 32)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .opacity(track.previewURL == nil && librarySong == nil ? 0.5 : 1)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let song {
                Button { player.addToQueue(song) } label: { Image(systemName: "text.append") }
                    .accessibilityLabel("Add to Queue").tint(.orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let song {
                Button { player.playNext(song) } label: { Image(systemName: "text.insert") }
                    .accessibilityLabel("Play Next").tint(.blue)
            }
            #if !APPSTORE_BUILD
            if canFetch && librarySong == nil {
                Button { ReleaseFetcher.shared.get(release, track: SoulseekPick.Track(track)) } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel("Get This Song").tint(accentColor)
            }
            #endif
        }
        .contextMenu {
            Button(action: play) {
                Label(librarySong == nil ? "Play Preview" : "Play", systemImage: "play.circle")
            }
            if let song {
                Button { player.playNext(song) } label: { Label("Play Next", systemImage: "text.insert") }
                Button { player.addToQueue(song) } label: { Label("Add to Queue", systemImage: "text.append") }
            }
            #if !APPSTORE_BUILD
            if canFetch && librarySong == nil {
                Button { ReleaseFetcher.shared.get(release, track: SoulseekPick.Track(track)) } label: {
                    Label("Get This Song", systemImage: "arrow.down.circle")
                }
            }
            #endif
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(track.title)")
        .accessibilityHint(librarySong == nil ? "Plays its preview" : "Plays it from your library")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        if librarySong != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(accentColor)
                .accessibilityLabel("In your library")
        } else if canFetch {
            #if !APPSTORE_BUILD
            getControl
            #endif
        }
    }

    #if !APPSTORE_BUILD
    private var getControl: some View {
        SongGetControl(release: release, track: SoulseekPick.Track(track))
    }
    #endif
}

#if !APPSTORE_BUILD
/// A song's Get button, then how far along it is: its own fetch — or its whole release's,
/// which covers it.
struct SongGetControl: View {
    let release: RadarRelease
    let track: SoulseekPick.Track

    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        let fetcher = ReleaseFetcher.shared
        let own = fetcher.fetch(for: ReleaseFetch.id(release.id, track: track.id))
        let whole = fetcher.fetch(for: release.id)
        // An album being completed: its fetch covers the song when the song is among those missing.
        let rest = fetcher.fetch(for: ReleaseFetch.restId(release.id)).flatMap { $0.missing?.contains(track) == true ? $0 : nil }
        let shown = [whole, rest].compactMap { $0 }.first { $0.stage != .failed } ?? own
        switch shown?.stage {
        case .searching?, .downloading?, .importing?:
            FetchRing(fetch: shown!)
        case .ready?:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(accentColor)
                .accessibilityLabel("In your library")
        default:
            Button { fetcher.get(release, track: track) } label: {
                Image(systemName: own?.stage == .failed ? "arrow.clockwise.circle" : "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(own?.stage == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Get This Song")
        }
    }
}
#endif
