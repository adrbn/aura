import SwiftUI

/// Pushes a radar or Deezer release's page onto the window's stack. Always equal, so a new
/// copy from each render of the root doesn't redraw every page that reads it: each copy
/// appends to the same path.
struct MacReleaseOpener: Equatable {
    var open: (RadarRelease) -> Void = { _ in }
    func callAsFunction(_ release: RadarRelease) { open(release) }
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var macOpenRelease = MacReleaseOpener()
}

/// A radar or Deezer release opened like an album, as on the phone: every song Deezer lists
/// for it, those the server has marked and played from it, the rest playing their preview —
/// and, in the sideload build, to be had one by one or all at once.
struct MacReleaseView: View {
    let release: RadarRelease

    @State private var player = AudioPlayer.shared
    @State private var radarService = RadarService.shared
    @State private var tracks: [DeezerTrack]?
    @State private var unreachable = false
    /// The release's songs on the server, looked up in full once the page opens.
    @State private var held: [Song]?
    @Environment(\.appAccentColor) private var accentColor

    private var source: PlaybackSource { .mix(id: "radar", name: String(localized: "Radar")) }
    private var songs: [Song] {
        tracks?.compactMap { librarySong(for: $0) ?? $0.previewSong(of: release) } ?? []
    }
    private var onServer: [Song] { held ?? radarService.current?.inLibrary[release.id] ?? [] }

    private var canFetch: Bool {
        #if APPSTORE_BUILD
        return false
        #else
        return ReleaseFetcher.shared.isAvailable
        #endif
    }

    private var isWhole: Bool {
        guard let tracks, !tracks.isEmpty else { return false }
        return tracks.allSatisfy { librarySong(for: $0) != nil }
    }

    /// "Artist · Single · 25 Sept 2026 · 12 songs · 41 min"
    private var meta: String {
        var parts = [release.byline, release.typeLabel]
        if let date = release.releaseDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let tracks {
            parts.append(String(localized: "\(tracks.count) songs"))
            let seconds = tracks.compactMap(\.duration).reduce(0, +)
            if seconds > 0 { parts.append(String(localized: "\(max(1, seconds / 60)) min")) }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                MacDetailHeader(coverArt: release.largeCover, title: release.title, subtitle: meta,
                                placeholderName: release.title) {
                    Button { play(nil) } label: { Label("Play", systemImage: "play.fill") }
                        .disabled(songs.isEmpty)
                    Button { player.playShuffled(songs, source: source) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .disabled(songs.isEmpty)
                    #if !APPSTORE_BUILD
                    if canFetch && !isWhole { getAll }
                    #endif
                    if let link = release.link.flatMap(URL.init(string:)) {
                        Link(destination: link) { Label("Open in Deezer", systemImage: "arrow.up.right") }
                    }
                }
                Divider()
                if let tracks {
                    VStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            row(track, number: track.track_position ?? index + 1)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                } else if unreachable {
                    ContentUnavailableView("Deezer couldn't be reached", systemImage: "wifi.exclamationmark")
                        .frame(height: 240)
                } else {
                    MacLoadingState().frame(height: 240)
                }
            }
        }
        .background { ZStack { ArtworkCanvas(coverArt: release.largeCover, height: 640); MacFadingGrid() } }
        .navigationTitle(release.title)
        .task { await load() }
    }

    private func row(_ track: DeezerTrack, number: Int) -> some View {
        let song = librarySong(for: track)
        let isCurrent = player.currentSong.map { $0.id == "deezer-\(track.id)" || $0.id == song?.id } ?? false
        let queued = song ?? track.previewSong(of: release)
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 22, alignment: .leading)
                Text(track.title).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accentColor) : AnyShapeStyle(.primary))
                Spacer(minLength: 12)
                Text(track.artist?.name ?? release.artist.name)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(track.duration.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? "")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .opacity(track.previewURL == nil && song == nil ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { play(track) }
            trailing(track, inLibrary: song != nil)
                .frame(width: 32, height: 30)
        }
        .frame(height: 30)
        .contextMenu {
            if let queued {
                Button { player.playNext(queued) } label: { Label("Play Next", systemImage: "text.insert") }
                Button { player.addToQueue(queued) } label: { Label("Add to Queue", systemImage: "text.append") }
                Divider()
            }
            Button { play(track) } label: {
                Label(song == nil ? "Play Preview" : "Play", systemImage: "play.circle")
            }
            if let song {
                Divider()
                MacSongMenuItems(songs: [song])
            }
            #if !APPSTORE_BUILD
            if canFetch && song == nil {
                Button { ReleaseFetcher.shared.get(release, track: SoulseekPick.Track(track)) } label: {
                    Label("Get This Song", systemImage: "arrow.down.circle")
                }
            }
            #endif
        }
    }

    /// A check once the server has it; in the sideload build, the song's own Get until then.
    @ViewBuilder
    private func trailing(_ track: DeezerTrack, inLibrary: Bool) -> some View {
        if inLibrary {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accentColor).help("In your library")
        } else if canFetch {
            #if !APPSTORE_BUILD
            getOne(track)
            #endif
        }
    }

    #if !APPSTORE_BUILD
    /// The phone's `SongGetControl`: the song's own fetch, or its whole release's, which covers it.
    @ViewBuilder
    private func getOne(_ track: DeezerTrack) -> some View {
        let fetcher = ReleaseFetcher.shared
        let pick = SoulseekPick.Track(track)
        let own = fetcher.fetch(for: ReleaseFetch.id(release.id, track: pick.id))
        let whole = fetcher.fetch(for: release.id)
        let rest = fetcher.fetch(for: ReleaseFetch.restId(release.id)).flatMap { $0.missing?.contains(pick) == true ? $0 : nil }
        let shown = [whole, rest].compactMap { $0 }.first { $0.stage != .failed } ?? own
        switch shown?.stage {
        case .searching?, .downloading?, .importing?:
            FetchRing(fetch: shown!)
        case .ready?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accentColor).help("In your library")
        default:
            Button { fetcher.get(release, track: pick) } label: {
                Image(systemName: own?.stage == .failed ? "arrow.clockwise.circle" : "arrow.down.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(own?.stage == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Get This Song")
        }
    }

    /// The whole release in one click, and how far along it is.
    private var getAll: some View {
        let fetch = ReleaseFetcher.shared.fetch(for: release.id)
        return Button { ReleaseFetcher.shared.get(release) } label: {
            Label(getAllTitle(fetch), systemImage: getAllIcon(fetch))
                .foregroundStyle(fetch?.stage == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        }
        .disabled(fetch.map { $0.isActive || $0.stage == .ready } ?? false)
    }

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

    private func librarySong(for track: DeezerTrack) -> Song? {
        onServer.first { RadarRules.sameTitle($0.title, track.title) }
    }

    /// From the top, or from one song, through the release — the server's copies and the
    /// previews of the rest — then on into the rest of the radar, as on the phone.
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
        let queue = radarService.queue(playing: songs, of: release)
        player.playSong(song, fromQueue: queue, startIndex: queue.firstIndex { $0.id == song.id } ?? 0, source: source)
    }

    private func load() async {
        let loaded = await radarService.tracks(of: release)
        if let loaded { tracks = loaded }
        unreachable = loaded == nil && tracks == nil
        held = await radarService.held(release)
    }
}
