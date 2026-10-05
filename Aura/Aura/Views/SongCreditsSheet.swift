import SwiftUI

// MARK: - Song Credits Sheet

struct SongCreditsSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @State private var mbCredits: SongCredits?
    @State private var isLoadingCredits = true

    var body: some View {
        NavigationStack {
            List {
                // Header with cover art
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            CoverArtImage(coverArt: song.coverArt, size: 120, cornerRadius: 12,
                              fallbackCoverArt: song.albumId)
                            Text(song.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            if let artist = song.artist {
                                Text(artist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let album = song.album {
                                Text(album)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                SongRatingSection(song: song)

                // Song info from local metadata
                Section("Song") {
                    if let artist = song.artist {
                        creditRow("Artist", artist)
                    }
                    if let album = song.album {
                        creditRow("Album", album)
                    }
                    if let genre = song.genre {
                        creditRow("Genre", genre)
                    }
                    if let year = song.year {
                        creditRow("Year", "\(year)")
                    }
                    if let track = song.track {
                        creditRow("Track", "\(track)")
                    }
                    creditRow("Duration", song.durationFormatted)
                }

                // MusicBrainz credits
                if isLoadingCredits {
                    Section("Credits") {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding(.vertical, 8)
                            Text("Looking up credits…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                            Spacer()
                        }
                    }
                } else if let credits = mbCredits, credits.hasAnyCredits {
                    // Writers
                    if !credits.writers.isEmpty {
                        Section("Written By") {
                            ForEach(credits.writers, id: \.self) { writer in
                                creditPersonRow(writer, role: String(localized: "Writer"))
                            }
                        }
                    }

                    // Composers
                    if !credits.composers.isEmpty {
                        Section("Composed By") {
                            ForEach(credits.composers, id: \.self) { composer in
                                creditPersonRow(composer, role: String(localized: "Composer"))
                            }
                        }
                    }

                    // Lyricists
                    if !credits.lyricists.isEmpty {
                        Section("Lyrics By") {
                            ForEach(credits.lyricists, id: \.self) { lyricist in
                                creditPersonRow(lyricist, role: String(localized: "Lyricist"))
                            }
                        }
                    }

                    // Producers
                    if !credits.producers.isEmpty {
                        Section("Produced By") {
                            ForEach(credits.producers, id: \.self) { producer in
                                creditPersonRow(producer, role: String(localized: "Producer"))
                            }
                        }
                    }

                    // Performers
                    if !credits.performers.isEmpty {
                        Section("Performers") {
                            ForEach(Array(credits.performers.enumerated()), id: \.offset) { _, performer in
                                creditPersonRow(performer.name, role: performer.role)
                            }
                        }
                    }

                    // Mixing
                    if !credits.mixers.isEmpty {
                        Section("Mixed By") {
                            ForEach(credits.mixers, id: \.self) { mixer in
                                creditPersonRow(mixer, role: String(localized: "Mixing"))
                            }
                        }
                    }

                    // Engineers
                    if !credits.engineers.isEmpty {
                        Section("Engineering") {
                            ForEach(credits.engineers, id: \.self) { engineer in
                                creditPersonRow(engineer, role: String(localized: "Engineer"))
                            }
                        }
                    }

                    // Arrangers
                    if !credits.arrangers.isEmpty {
                        Section("Arranged By") {
                            ForEach(credits.arrangers, id: \.self) { arranger in
                                creditPersonRow(arranger, role: String(localized: "Arranger"))
                            }
                        }
                    }

                    // Remixers
                    if !credits.remixers.isEmpty {
                        Section("Remixed By") {
                            ForEach(credits.remixers, id: \.self) { remixer in
                                creditPersonRow(remixer, role: String(localized: "Remixer"))
                            }
                        }
                    }

                    // Release info
                    Section("Release Info") {
                        if let label = credits.label {
                            creditRow("Label", label)
                        }
                        if let date = credits.releaseDate {
                            creditRow("Release Date", date)
                        }
                        if let country = credits.releaseCountry {
                            creditRow("Country", country)
                        }
                        if let catalog = credits.catalogNumber {
                            creditRow("Catalog #", catalog)
                        }
                        if let isrc = credits.isrc {
                            creditRow("ISRC", isrc)
                        }
                    }

                    // Tags
                    if !credits.tags.isEmpty {
                        Section("Tags") {
                            FlowLayout(spacing: 6) {
                                ForEach(credits.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(accentColor.opacity(0.15))
                                        .foregroundStyle(accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                } else {
                    Section("Credits") {
                        Text("No additional credits found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SongFileSections(song: song)

                // Source attribution
                Section {
                    HStack {
                        Spacer()
                        Text("Credits data from MusicBrainz")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Song Info").font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let artist = song.artist {
                    mbCredits = await MusicBrainzService.shared.fetchCredits(title: song.title, artist: artist)
                }
                isLoadingCredits = false
            }
        }
    }

    private func creditRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func creditPersonRow(_ name: String, role: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (positions, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
