import SwiftUI

/// The radar's releases, newest first: those the server has whole marked and played from it,
/// the rest previewed and, in the sideload build, to get. They are rows of the page's own List,
/// so they scroll with it and sit on its tinted canvas.
struct RadarReleaseRows: View {
    let releases: [RadarRelease]
    /// The ids of the releases the server has whole.
    let held: Set<String>
    /// Opens a release's own page, a level down — for a release of more than one song.
    let open: (RadarRelease) -> Void

    var body: some View {
        ForEach(releases) { release in
            RadarReleaseRow(release: release, isHeld: held.contains(release.id)) { open(release) }
                .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                          bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 16))
                .listRowBackground(Color.clear)
        }
    }
}

struct RadarReleaseRow: View {
    let release: RadarRelease
    /// On the server whole: marked, and played from it.
    var isHeld = false
    let open: () -> Void

    @Environment(AudioPlayer.self) private var player
    @Environment(\.openURL) private var openURL
    @Environment(\.appAccentColor) private var accentColor
    @State private var showSoulseek = false
    @State private var isLoadingPreview = false

    private var deezerURL: URL? { release.link.flatMap(URL.init(string:)) }

    /// Only the sideload build can fetch a release, and only with its beta features on.
    private var canSearchSoulseek: Bool {
        #if APPSTORE_BUILD
        return false
        #else
        return AppSettings.shared.betaFeaturesEnabled
        #endif
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: release.cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.primary.opacity(0.08)
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(release.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accentColor) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Group {
                if isLoadingPreview {
                    ProgressView()
                } else if isHeld {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(accentColor)
                        .accessibilityLabel("In your library")
                } else if canSearchSoulseek {
                    getControl
                } else {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 32)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await tap() } }
        .contextMenu {
            if isHeld {
                Button { Task { await tap() } } label: {
                    Label(heldSingle == nil ? "Open" : "Play", systemImage: "play.circle")
                }
            } else {
                Button { Task { await playPreviews() } } label: {
                    Label("Play Previews", systemImage: "play.circle")
                }
            }
            if let deezerURL {
                Button { openURL(deezerURL) } label: {
                    Label("Open in Deezer", systemImage: "arrow.up.right")
                }
            }
            if canSearchSoulseek && !isHeld {
                #if !APPSTORE_BUILD
                Button { ReleaseFetcher.shared.get(release) } label: {
                    Label("Get It", systemImage: "arrow.down.circle")
                }
                #endif
                Button { showSoulseek = true } label: {
                    Label("Search by Hand", systemImage: "magnifyingglass")
                }
            }
            Button { player.pendingArtistId = release.artist.id } label: {
                Label("Go to Artist", systemImage: "person")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(release.title), \(release.typeLabel) by \(release.artist.name), \(dateLabel)")
        .accessibilityHint(isHeld ? (heldSingle == nil ? "Opens its songs" : "Plays it from your library")
                                  : isOneSong ? "Plays its preview" : "Opens its songs")
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $showSoulseek) { soulseekSheet }
    }

    /// A single of one song has no page worth opening.
    private var isOneSong: Bool { RadarService.shared.trackLists[release.id]?.tracks.count == 1 }

    /// A single of one song the server has: its copy there.
    private var heldSingle: Song? {
        guard isHeld, release.type == "single",
              let songs = RadarService.shared.current?.inLibrary[release.id], songs.count == 1 else { return nil }
        return songs.first
    }

    /// Whether what's playing is one of this release's songs, its server copy or its preview.
    private var isCurrent: Bool {
        guard let current = player.currentSong else { return false }
        if current.isPreview { return RadarService.shared.release(of: current)?.id == release.id }
        return RadarService.shared.current?.inLibrary[release.id]?.contains { $0.id == current.id } == true
    }

    /// Opens the release — or, when it's a single of one song, plays it like a row of the
    /// radar's playlist, on into the next releases: from the server when it's there.
    private func tap() async {
        if let song = heldSingle {
            let queue = RadarService.shared.queue(playing: [song], of: release)
            player.playSong(song, fromQueue: queue, startIndex: queue.firstIndex { $0.id == song.id } ?? 0,
                            source: .mix(id: "radar", name: String(localized: "Radar")))
            return
        }
        if isHeld { return open() }
        let known = RadarService.shared.trackLists[release.id]
        guard known?.tracks.count == 1 || (known == nil && release.type == "single") else { return open() }
        await playPreviews(fromRow: true)
    }

    /// The release's tracks as Deezer previews, then on into the rest of the radar's.
    /// `fromRow`: a tap on the row, which opens the release after all if it has more songs.
    private func playPreviews(fromRow: Bool = false) async {
        guard !isLoadingPreview else { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        guard let tracks = await RadarService.shared.tracks(of: release) else {
            ToastManager.shared.show(String(localized: "Deezer couldn't be reached"), icon: "wifi.exclamationmark")
            return
        }
        if fromRow, tracks.count > 1 { return open() }
        let songs = tracks.compactMap { $0.previewSong(of: release) }
        guard let first = songs.first else {
            ToastManager.shared.show(String(localized: "No previews for this release"), icon: "speaker.slash")
            return
        }
        let queue = RadarService.shared.queue(playing: songs, of: release)
        let index = queue.firstIndex { $0.id == first.id } ?? 0
        player.playSong(first, fromQueue: queue, startIndex: index,
                        source: .mix(id: "radar", name: String(localized: "Radar")))
        if !fromRow { player.isShowingNowPlaying = true }
    }

    /// Gets the release in one tap, then shows how far along it is.
    @ViewBuilder
    private var getControl: some View {
        #if !APPSTORE_BUILD
        let fetch = ReleaseFetcher.shared.fetch(for: release.id)
        switch fetch?.stage {
        case .searching?, .downloading?, .importing?:
            FetchRing(fetch: fetch!)
        case .ready?:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(accentColor)
                .accessibilityLabel("In your library")
        default:
            Button { ReleaseFetcher.shared.get(release) } label: {
                Image(systemName: fetch?.stage == .failed ? "arrow.clockwise.circle" : "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(fetch?.stage == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Get It")
        }
        #endif
    }

    /// "Zaoui · Album · Sep 25", and how many songs are still to get when the server has some.
    private var details: String {
        var parts = [release.artist.name, release.typeLabel, dateLabel]
        if let lacking = RadarService.shared.current?.lacking?[release.id] {
            parts.append(String(localized: "\(lacking) to get"))
        }
        return parts.joined(separator: " · ")
    }

    private var dateLabel: String {
        release.releaseDate?.formatted(.dateTime.month(.abbreviated).day()) ?? release.released
    }

    @ViewBuilder
    private var soulseekSheet: some View {
        #if !APPSTORE_BUILD
        NavigationStack {
            SlskdSearchView(initialQuery: "\(release.artist.name) \(release.title)")
                .navigationTitle("Soulseek")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSoulseek = false }
                    }
                }
        }
        #endif
    }
}

#if !APPSTORE_BUILD
/// A fetch's progress as a small ring: the download's share, or a spinning arc while it
/// searches or waits for the server.
struct FetchRing: View {
    let fetch: ReleaseFetch
    @Environment(\.appAccentColor) private var accentColor
    @State private var spin = false

    var body: some View {
        let determinate = fetch.stage == .downloading && fetch.progress > 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: determinate ? max(0.04, fetch.progress) : 0.25)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(determinate ? -90 : (spin ? 270 : -90)))
                .animation(determinate ? .easeInOut(duration: 0.3)
                           : .linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                .animation(.easeInOut(duration: 0.3), value: fetch.progress)
            Image(systemName: fetch.stage == .importing ? "tray.and.arrow.down.fill" : "arrow.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 22, height: 22)
        .onAppear { spin = true }
        .accessibilityLabel(fetch.headline)
    }
}
#endif
