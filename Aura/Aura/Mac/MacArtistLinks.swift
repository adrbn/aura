import SwiftUI

/// The credited artists, each one its own link.
///
/// `song.artist` is a single string with every name run together and `song.artistId` points
/// at only the first, so a collaboration cannot be navigated from those two fields. Where the
/// server publishes OpenSubsonic's per-artist credits they are used directly; otherwise the
/// string is split on the separators servers actually use and each name is resolved by search
/// when clicked, which costs one request but only for the name you asked for.
struct MacArtistLinks: View {
    let song: Song?
    var size: CGFloat = 11
    var colour: Color = .secondary

    @State private var player = AudioPlayer.shared
    @State private var serverManager = ServerManager.shared
    @State private var hovered: String?

    var body: some View {
        let credits = song?.creditedArtists ?? []
        HStack(spacing: 5) {
            ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                if index > 0 {
                    Text("•")
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                }
                Button { open(credit) } label: {
                    Text(credit.name)
                        .font(.system(size: size))
                        .foregroundStyle(colour)
                        .underline(hovered == credit.name)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? credit.name : nil }
            }
        }
    }

    private func open(_ credit: ArtistRef) {
        // A real id goes straight there. A name-only credit — everything past the first on a
        // server without the extension — has to be looked up first.
        if !credit.id.isEmpty {
            player.pendingArtistId = credit.id
            return
        }
        guard let server = serverManager.currentServer else { return }
        Task {
            let found = try? await SubsonicClient.shared.search3(
                server: server, query: credit.name,
                artistCount: 5, albumCount: 0, songCount: 0
            ).artist
            let match = found?.first { $0.name.caseInsensitiveCompare(credit.name) == .orderedSame }
                ?? found?.first
            if let match { player.pendingArtistId = match.id }
        }
    }
}

extension Song {
    /// Every credited artist, with an id where one is known.
    ///
    /// The separators are the ones servers put in the joined string in practice. Splitting is
    /// deliberately conservative — a band called "Florence + the Machine" must not become two
    /// artists — so only the unambiguous ones are used, and "feat." keeps the featured name
    /// as its own credit because that is exactly the one worth clicking.
    var creditedArtists: [ArtistRef] {
        if let artists, !artists.isEmpty { return artists }
        guard let artist, !artist.isEmpty else { return [] }

        var names = [artist]
        for separator in [" • ", "; ", " feat. ", " ft. ", " featuring ", " with "] {
            names = names.flatMap { $0.components(separatedBy: separator) }
        }
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard cleaned.count > 1 else {
            return [ArtistRef(id: artistId ?? "", name: artist)]
        }
        // Only the first name is the one artistId refers to; the rest are resolved on demand.
        return cleaned.enumerated().map { index, name in
            ArtistRef(id: index == 0 ? (artistId ?? "") : "", name: name)
        }
    }
}
