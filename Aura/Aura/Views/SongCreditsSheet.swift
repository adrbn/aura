import SwiftUI

// MARK: - Song Credits Sheet

/// Song Info, laid out like Add to Playlist: the song at the top, then rounded cards on the
/// page colour — rating, the song, its credits, the release and the file.
struct SongCreditsSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @State private var mbCredits: SongCredits?
    @State private var isLoadingCredits = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !song.isPreview { ratingCard }
                    card("Song", rows: songRows)
                    credits
                    ForEach(Array(SongFileSections.groups(for: song).enumerated()), id: \.offset) { _, group in
                        card(group.title, rows: group.rows)
                    }
                    Text("Credits data from MusicBrainz")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Color.themeBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Done"))
                }
            }
            .task {
                if let artist = song.artist {
                    mbCredits = await MusicBrainzService.shared.fetchCredits(title: song.title, artist: artist)
                }
                isLoadingCredits = false
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(Color.themeBg)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 14) {
            CoverArtImage(coverArt: song.displayCoverArt, size: 60, cornerRadius: 10,
                          fallbackCoverArt: song.albumId,
                          placeholderName: song.title, placeholderKind: .song)
            VStack(alignment: .leading, spacing: 2) {
                Text("Song Info")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(song.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                if let artist = song.artist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var ratingCard: some View {
        let ratings = SongRatings.shared
        let rating = ratings.rating(for: song)
        return HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    ratings.set(rating == star ? 0 : star, for: song)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(star <= rating ? accentColor : Color.primary.opacity(0.3))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.08)))
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: ratings.set(min(rating + 1, 5), for: song)
            case .decrement: ratings.set(max(rating - 1, 0), for: song)
            @unknown default: break
            }
        }
    }

    private var songRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let album = song.album { rows.append(("Album", album)) }
        if let genre = song.genre { rows.append(("Genre", genre)) }
        if let year = song.year { rows.append(("Year", "\(year)")) }
        if let track = song.track { rows.append(("Track", "\(track)")) }
        rows.append(("Duration", song.durationFormatted))
        if let plays = song.playCount { rows.append(("Play Count", "\(plays)")) }
        return rows
    }

    @ViewBuilder
    private var credits: some View {
        if isLoadingCredits {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking up credits…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else if let c = mbCredits, c.hasAnyCredits {
            let people: [(LocalizedStringKey, [(String, String)])] = [
                ("Written By", c.writers.map { ($0, String(localized: "Writer")) }),
                ("Composed By", c.composers.map { ($0, String(localized: "Composer")) }),
                ("Lyrics By", c.lyricists.map { ($0, String(localized: "Lyricist")) }),
                ("Produced By", c.producers.map { ($0, String(localized: "Producer")) }),
                ("Performers", c.performers.map { ($0.name, $0.role) }),
                ("Mixed By", c.mixers.map { ($0, String(localized: "Mixing")) }),
                ("Engineering", c.engineers.map { ($0, String(localized: "Engineer")) }),
                ("Arranged By", c.arrangers.map { ($0, String(localized: "Arranger")) }),
                ("Remixed By", c.remixers.map { ($0, String(localized: "Remixer")) }),
            ]
            ForEach(Array(people.enumerated()), id: \.offset) { _, group in
                if !group.1.isEmpty { peopleCard(group.0, group.1) }
            }
            var release: [(label: String, value: String)] {
                var rows: [(String, String)] = []
                if let v = c.label { rows.append(("Label", v)) }
                if let v = c.releaseDate { rows.append(("Release Date", v)) }
                if let v = c.releaseCountry { rows.append(("Country", v)) }
                if let v = c.catalogNumber { rows.append(("Catalog #", v)) }
                if let v = c.isrc { rows.append(("ISRC", v)) }
                return rows
            }
            if !release.isEmpty { card("Release Info", rows: release) }
            if !c.tags.isEmpty {
                section("Tags") {
                    FlowLayout(spacing: 6) {
                        ForEach(c.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(accentColor.opacity(0.15))
                                .foregroundStyle(accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        } else {
            Text("No additional credits found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    /// A title over its content, the way the sheet groups everything.
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
        }
    }

    private func card(_ title: LocalizedStringKey, rows: [(label: String, value: String)]) -> some View {
        section(title) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider().padding(.leading, 16) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(LocalizedStringKey(row.label))
                        Spacer(minLength: 8)
                        Text(row.value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.08)))
        }
    }

    private func peopleCard(_ title: LocalizedStringKey, _ people: [(String, String)]) -> some View {
        section(title) {
            VStack(spacing: 0) {
                ForEach(Array(people.enumerated()), id: \.offset) { i, person in
                    if i > 0 { Divider().padding(.leading, 16) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.0).font(.subheadline.weight(.semibold))
                        Text(person.1).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.08)))
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
