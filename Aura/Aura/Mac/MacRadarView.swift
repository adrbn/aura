import SwiftUI

/// The radar on the Mac: the same releases, rows and Get It as the phone's radar page. A
/// release of several songs plays whole here instead of opening a page of its own.
struct MacRadarView: View {
    @State private var radarService = RadarService.shared
    @Environment(AudioPlayer.self) private var player

    var body: some View {
        Group {
            if let radar = radarService.current, !radar.releases.isEmpty {
                List {
                    // The rows' own inset, so the title and the covers line up as on every page.
                    Text("Radar")
                        .auraDisplay(52)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 26, leading: 16, bottom: 4, trailing: 16))
                    RadarReleaseRows(releases: radar.releases, held: wholeOnServer(radar)) { release in
                        Task { await play(release, held: wholeOnServer(radar).contains(release.id)) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
            } else if !AppSettings.shared.radarEnabled {
                ContentUnavailableView("Radar is off", systemImage: "dot.radiowaves.left.and.right")
            } else {
                MacLoadingState()
            }
        }
        .navigationTitle("Radar")
        .toolbar {
            Button { Task { await refresh(force: true) } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .task { await refresh(force: false) }
    }

    private func refresh(force: Bool) async {
        await radarService.refreshIfNeeded(force: force)
        #if !APPSTORE_BUILD
        await ReleaseFetcher.shared.settlePicked()
        #endif
        await radarService.loadTrackLists()
    }

    /// As on the phone: whole on the server unless listed or picked song by song.
    private func wholeOnServer(_ radar: Radar) -> Set<String> {
        var toGet = Set(radar.listed.map(\.id))
        #if !APPSTORE_BUILD
        toGet.formUnion(ReleaseFetcher.shared.picked)
        #endif
        return Set(radar.releases.map(\.id)).subtracting(toGet)
    }

    /// The server's copy when it has it whole, the previews otherwise, on into the radar.
    private func play(_ release: RadarRelease, held: Bool) async {
        var songs = held ? radarService.current?.inLibrary[release.id] ?? [] : []
        if songs.isEmpty {
            guard let tracks = await radarService.tracks(of: release) else {
                ToastManager.shared.show(String(localized: "Deezer couldn't be reached"), icon: "wifi.exclamationmark")
                return
            }
            songs = tracks.compactMap { $0.previewSong(of: release) }
        }
        guard let first = songs.first else {
            ToastManager.shared.show(String(localized: "No previews for this release"), icon: "speaker.slash")
            return
        }
        let queue = radarService.queue(playing: songs, of: release)
        player.playSong(first, fromQueue: queue, startIndex: queue.firstIndex { $0.id == first.id } ?? 0,
                        source: .mix(id: "radar", name: String(localized: "Radar")))
    }
}
