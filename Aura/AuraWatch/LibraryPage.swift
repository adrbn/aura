import SwiftUI

/// Where the watch goes from Now Playing: the queue from one corner, the library from the
/// other, and on from the library into search and whatever it lists.
enum WatchRoute: Hashable {
    case upNext
    case library
    case search(String)
    case item(WatchItem)

    @ViewBuilder var page: some View {
        switch self {
        case .upNext: UpNextPage()
        case .library: LibraryPage()
        case .search(let query): SearchPage(query: query)
        case .item(let item): ItemPage(item: item)
        }
    }
}

/// The phone's library on the wrist: search at the top, then what the phone's Home makes
/// for you — the radar leading — then the favourites and the playlists. Everything plays on
/// the phone; starting something comes back to Now Playing.
struct LibraryPage: View {
    @Environment(WatchModel.self) private var model
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageTitle(text: "Library")
                SearchField { query in model.path.append(.search(query)) }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                if let shelf = model.shelf {
                    if !shelf.mixes.isEmpty {
                        SectionTitle(text: "Made For You")
                        ForEach(shelf.mixes) { mix in ItemRow(item: mix) }
                    }
                    SectionTitle(text: "Playlists")
                    ForEach(shelf.playlists) { playlist in ItemRow(item: playlist) }
                } else if failed {
                    Unreachable { await load() }
                } else {
                    Loading()
                }
            }
            .padding(.bottom, 28)
        }
        .screenBackdrop()
        .task { await load() }
    }

    private func load() async {
        failed = false
        failed = !(await model.loadShelf())
    }
}

/// What the phone's search finds, songs first: the quickest thing to want from a wrist is
/// to play something now.
struct SearchPage: View {
    let query: String
    @Environment(WatchModel.self) private var model
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageTitle(text: "“\(query)”")
                if let results = model.searches[query] {
                    if results.isEmpty {
                        Message(text: "Nothing found")
                    }
                    if !results.songs.isEmpty {
                        SectionTitle(text: "Songs")
                        ForEach(results.songs) { song in ItemRow(item: song) }
                    }
                    if !results.albums.isEmpty {
                        SectionTitle(text: "Albums")
                        ForEach(results.albums) { album in ItemRow(item: album) }
                    }
                    if !results.artists.isEmpty {
                        SectionTitle(text: "Artists")
                        ForEach(results.artists) { artist in ItemRow(item: artist) }
                    }
                } else if failed {
                    Unreachable { await load() }
                } else {
                    Loading()
                }
            }
            .padding(.bottom, 28)
        }
        .screenBackdrop()
        .task { await load() }
    }

    private func load() async {
        failed = false
        failed = !(await model.search(query))
    }
}

/// A mix, a playlist, an album or an artist, as the phone's detail pages open: the cover and
/// the name, Play and Shuffle, then the songs — an artist's top songs, then their albums.
struct ItemPage: View {
    let item: WatchItem
    @Environment(WatchModel.self) private var model
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if let listing = model.listings[item] {
                    if listing.songs.isEmpty, listing.albums.isEmpty {
                        Message(text: "Nothing to play")
                    }
                    if item.kind == .artist, !listing.songs.isEmpty {
                        SectionTitle(text: "Top Songs")
                    }
                    ForEach(Array(listing.songs.enumerated()), id: \.offset) { index, song in
                        SongRow(song: song, number: item.kind == .album ? index + 1 : nil) {
                            model.play(item, index: index)
                        }
                    }
                    if !listing.albums.isEmpty {
                        SectionTitle(text: "Albums")
                        ForEach(listing.albums) { album in ItemRow(item: album) }
                    }
                } else if failed {
                    Unreachable { await load() }
                } else {
                    Loading()
                }
            }
            .padding(.bottom, 28)
        }
        .screenBackdrop()
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CoverThumb(item: item, side: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { model.play(item) } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(model.accent)
                Button { model.play(item, shuffled: true) } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Shuffle")
            }
            .disabled(model.listings[item]?.songs.isEmpty ?? true)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func load() async {
        failed = false
        failed = !(await model.open(item))
    }
}

// MARK: - Pieces

/// A page's name, set in the phone's display face as its page titles are.
private struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.custom("VavinCondensed-Bold", size: 30))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }
}

private struct SectionTitle: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }
}

/// A mix, a playlist, an album or an artist opens its page; a song plays.
private struct ItemRow: View {
    let item: WatchItem
    @Environment(WatchModel.self) private var model

    var body: some View {
        Button {
            if item.kind == .song {
                model.play(item)
            } else {
                model.path.append(.item(item))
            }
        } label: {
            HStack(spacing: 9) {
                CoverThumb(item: item, side: 36)
                Lines(title: item.title, subtitle: item.subtitle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
    }
}

/// A song in a page's list: its cover, or on an album — where every cover is the same — its
/// number.
private struct SongRow: View {
    let song: WatchItem
    let number: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .monospacedDigit()
                        .frame(width: 20, alignment: .trailing)
                } else {
                    CoverThumb(item: song, side: 36)
                }
                Lines(title: song.title, subtitle: song.subtitle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, number == nil ? 5 : 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
    }
}

private struct Lines: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }
}

/// A cover as the phone sends it, small; until it comes, or when there's none, a quiet tile —
/// the favourites' a heart in the accent. An artist is round, as on the phone.
private struct CoverThumb: View {
    let item: WatchItem
    let side: CGFloat
    @Environment(WatchModel.self) private var model

    var body: some View {
        let image = item.coverArt.flatMap { model.covers[$0] }
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if item.kind == .favorites {
                model.accent.opacity(0.28)
                Image(systemName: "heart.fill")
                    .font(.system(size: side * 0.42))
                    .foregroundStyle(model.accent)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: item.kind == .artist ? side / 2 : side * 0.17,
                                    style: .continuous))
        .animation(.easeOut(duration: 0.25), value: image == nil)
        .onAppear { if let id = item.coverArt { model.wantCover(id) } }
    }
}

private struct Loading: View {
    var body: some View {
        ProgressView()
            .tint(.white)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }
}

private struct Message: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 12)
            .padding(.top, 8)
    }
}

/// The phone didn't answer: it's out of reach, or Aura isn't running on it.
private struct Unreachable: View {
    let retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Aura on your iPhone")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
            Button("Try Again") { Task { await retry() } }
                .font(.system(size: 15, weight: .semibold))
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
