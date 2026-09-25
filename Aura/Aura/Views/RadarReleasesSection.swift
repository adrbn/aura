import SwiftUI

/// The radar's releases the server doesn't have yet, listed under its playlist. They are rows
/// of the page's own List, so they scroll with it and sit on its tinted canvas.
struct RadarMissingRows: View {
    let releases: [RadarRelease]

    var body: some View {
        Text("Not in your library yet")
            .font(.title3.bold())
            .padding(.top, 20)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

        ForEach(releases) { release in
            RadarReleaseRow(release: release)
                .listRowInsets(EdgeInsets(top: AppSettings.shared.listDensity.verticalPadding, leading: 16,
                                          bottom: AppSettings.shared.listDensity.verticalPadding, trailing: 16))
                .listRowBackground(Color.clear)
        }

        Text("Found in Deezer's catalogue. A release joins the playlist above once it's on your server.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct RadarReleaseRow: View {
    let release: RadarRelease

    @Environment(AudioPlayer.self) private var player
    @Environment(\.openURL) private var openURL
    @State private var showSoulseek = false

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
            Image(systemName: canSearchSoulseek ? "magnifyingglass" : "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canSearchSoulseek {
                showSoulseek = true
            } else if let deezerURL {
                openURL(deezerURL)
            }
        }
        .contextMenu {
            if let deezerURL {
                Button { openURL(deezerURL) } label: {
                    Label("Open in Deezer", systemImage: "arrow.up.right")
                }
            }
            if canSearchSoulseek {
                Button { showSoulseek = true } label: {
                    Label("Search on Soulseek", systemImage: "magnifyingglass")
                }
            }
            Button { player.pendingArtistId = release.artist.id } label: {
                Label("Go to Artist", systemImage: "person")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(release.title), \(release.typeLabel) by \(release.artist.name), \(dateLabel)")
        .sheet(isPresented: $showSoulseek) { soulseekSheet }
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
