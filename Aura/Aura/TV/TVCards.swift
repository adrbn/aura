import SwiftUI

/// One cover on a shelf or in a grid: the system's card focus (lift, shadow, parallax) on the
/// artwork, the names under it.
struct TVCoverCard<Artwork: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 300
    var circular = false
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            artwork()
                .frame(width: width, height: width)
                .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12)))
                .hoverEffect(.highlight)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 22)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: width, alignment: circular ? .center : .leading)
        }
    }
}

extension TVCoverCard where Artwork == CoverArtImage {
    init(coverArt: String?, title: String, subtitle: String? = nil, width: CGFloat = 300,
         circular: Bool = false, placeholder: String? = nil) {
        self.init(title: title, subtitle: subtitle, width: width, circular: circular) {
            CoverArtImage(coverArt: coverArt, size: width, cornerRadius: 0, placeholderName: placeholder ?? title)
        }
    }
}

/// A titled horizontal row of cards; draws nothing at all when it has nothing to show.
struct TVShelf<Item: Identifiable, Card: View>: View {
    let title: LocalizedStringKey
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.system(size: 36, weight: .bold))
                    .padding(.horizontal, 80)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 48) {
                        ForEach(items) { card($0) }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// The links every tab's stack follows: an album, an artist, a playlist, a mix.
extension View {
    func tvDestinations() -> some View {
        navigationDestination(for: Album.self) { TVAlbumView(album: $0) }
            .navigationDestination(for: Artist.self) { TVArtistView(artist: $0) }
            .navigationDestination(for: Playlist.self) { TVPlaylistView(playlist: $0) }
            .navigationDestination(for: Mix.self) { TVMixView(mix: $0) }
    }
}

/// Album and playlist links with their card already inside.
struct TVAlbumLink: View {
    let album: Album
    var width: CGFloat = 300
    var body: some View {
        NavigationLink(value: album) {
            TVCoverCard(coverArt: album.coverArt, title: album.name, subtitle: album.artist, width: width)
        }
        .buttonStyle(.borderless)
    }
}

struct TVPlaylistLink: View {
    let playlist: Playlist
    var width: CGFloat = 300
    var body: some View {
        NavigationLink(value: playlist) {
            TVCoverCard(coverArt: playlist.coverArt, title: playlist.name,
                        subtitle: playlist.songCount.map { String(localized: "\($0) songs") }, width: width)
        }
        .buttonStyle(.borderless)
    }
}

struct TVArtistLink: View {
    let artist: Artist
    var width: CGFloat = 260
    var body: some View {
        NavigationLink(value: artist) {
            TVCoverCard(coverArt: artist.coverArt, title: artist.name, width: width, circular: true)
        }
        .buttonStyle(.borderless)
    }
}

/// A list's loading and empty states, centred in the space.
struct TVStatus: View {
    let loading: Bool
    var empty: LocalizedStringKey = "Nothing here yet"
    var body: some View {
        Group {
            if loading { ProgressView() } else { Text(empty).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}
