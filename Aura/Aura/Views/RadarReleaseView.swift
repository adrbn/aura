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
    private var previews: [Song] { tracks?.compactMap { $0.previewSong(of: release) } ?? [] }

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
            } else if unreachable {
                ContentUnavailableView {
                    Label("Deezer couldn't be reached", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Pull down to try again.")
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
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
                        Text(release.artist.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accentColor)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(release.artist.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                .disabled(previews.isEmpty)

                if canFetch {
                    getAllButton
                } else {
                    Button { player.playShuffled(previews, source: source) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Color.primary.opacity(0.08)).foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.borderless)
                    .disabled(previews.isEmpty)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    /// "Album · 25 Sept 2026 · 12 songs · 41 min"
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

    /// From the top, or from one song: the server's copy when it has it, else the previews —
    /// then on into the rest of the radar, as its playlist would.
    private func play(_ track: DeezerTrack?) {
        if let track, let song = librarySong(for: track) {
            start(song, of: onServer)
            return
        }
        let songs = previews
        let song: Song?
        if let track {
            song = songs.first { $0.id == "deezer-\(track.id)" }
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

    private var subtitle: String {
        var parts: [String] = []
        if let name = track.artist?.name, name != release.artist.name { parts.append(name) }
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
        .contextMenu {
            Button(action: play) {
                Label(librarySong == nil ? "Play Preview" : "Play", systemImage: "play.circle")
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
        let shown = (whole?.stage != .failed ? whole : nil) ?? own
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
