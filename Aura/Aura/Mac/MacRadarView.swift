import SwiftUI

/// The radar on the Mac: the same releases, rows and Get It as the phone's radar page, a
/// release of several songs opening its own page.
struct MacRadarView: View {
    @State private var radarService = RadarService.shared
    @Environment(\.macOpenRelease) private var openRelease

    var body: some View {
        Group {
            if let radar = radarService.current, !radar.releases.isEmpty {
                List {
                    // The rows' own inset, so the title and the covers line up as on every page.
                    Text("Radar")
                        .auraDisplay(52)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 26, leading: 16, bottom: 4, trailing: 16))
                    RadarReleaseRows(releases: radar.releases, held: wholeOnServer(radar)) { openRelease($0) }
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
}
