import SwiftUI

// MARK: - Full Albums List

struct AlbumsFullListView: View {
    let title: String
    let listType: String

    @Environment(ServerManager.self) private var serverManager
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var offset = 0
    private let pageSize = 40

    let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            if isLoading && albums.isEmpty {
                SkeletonAlbumGrid(count: 8)
                    .padding(.top, 16)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(albums) { album in
                        AlbumCardView(album: album)
                        .onAppear {
                            if album.id == albums.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 80)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAlbums() }
    }

    private func loadAlbums() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let result = try await SubsonicClient.shared.getAlbumList2(server: server, type: listType, size: pageSize, offset: 0)
            await MainActor.run {
                albums = result
                offset = result.count
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    private func loadMore() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let result = try await SubsonicClient.shared.getAlbumList2(server: server, type: listType, size: pageSize, offset: offset)
            if !result.isEmpty {
                await MainActor.run {
                    albums.append(contentsOf: result)
                    offset += result.count
                }
            }
        } catch { AppLogger.shared.log("❌ Load more albums failed: \(error.localizedDescription)") }
    }
}

// MARK: - Full Artists List

struct ArtistsListView: View {
    @Environment(ServerManager.self) private var serverManager
    @State private var artists: [Artist] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                List {
                    ForEach(0..<12, id: \.self) { _ in
                        SkeletonArtistRow()
                    }
                    .clearListRows()
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
            } else {
                List(artists) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 12) {
                            CoverArtImage(coverArt: artist.coverArt, size: 44, cornerRadius: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).font(.subheadline.weight(.medium))
                                if let count = artist.albumCount {
                                    Text("\(count) albums").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("Favorite Artists")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadArtists() }
    }

    private func loadArtists() async {
        guard let server = serverManager.currentServer else { return }
        do {
            let starred = try await SubsonicClient.shared.getStarred2(server: server)
            await MainActor.run {
                artists = starred.artist ?? []
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}
