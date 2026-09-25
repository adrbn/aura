import SwiftUI

/// The radar's releases the server doesn't have yet, listed under its playlist. They are rows
/// of the page's own List, so they scroll with it and sit on its tinted canvas.
struct RadarMissingRows: View {
    let releases: [RadarRelease]
    /// Opens a release's own page, a level down.
    let open: (RadarRelease) -> Void

    var body: some View {
        ForEach(releases) { release in
            RadarReleaseRow(release: release) { open(release) }
                .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                          bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 16))
                .listRowBackground(Color.clear)
        }
    }
}

struct RadarReleaseRow: View {
    let release: RadarRelease
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
                    .lineLimit(1)
                Text("\(release.artist.name) · \(release.typeLabel) · \(dateLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Group {
                if isLoadingPreview {
                    ProgressView()
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
        .onTapGesture(perform: open)
        .contextMenu {
            Button { Task { await playPreviews() } } label: {
                Label("Play Previews", systemImage: "play.circle")
            }
            if let deezerURL {
                Button { openURL(deezerURL) } label: {
                    Label("Open in Deezer", systemImage: "arrow.up.right")
                }
            }
            if canSearchSoulseek {
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
        .accessibilityHint("Opens its songs")
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $showSoulseek) { soulseekSheet }
    }

    /// The release's tracks as Deezer previews, played like any other queue.
    private func playPreviews() async {
        guard !isLoadingPreview else { return }
        isLoadingPreview = true
        defer { isLoadingPreview = false }
        guard let tracks = await RadarService.shared.tracks(of: release) else {
            ToastManager.shared.show(String(localized: "Deezer couldn't be reached"), icon: "wifi.exclamationmark")
            return
        }
        let songs = tracks.compactMap { $0.previewSong(of: release) }
        guard let first = songs.first else {
            ToastManager.shared.show(String(localized: "No previews for this release"), icon: "speaker.slash")
            return
        }
        player.playSong(first, fromQueue: songs, source: .mix(id: "radar", name: String(localized: "Radar")))
        player.isShowingNowPlaying = true
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
