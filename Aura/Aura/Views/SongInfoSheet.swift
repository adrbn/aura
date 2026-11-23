import SwiftUI

// MARK: - Song Info Sheet

#if os(iOS)
struct SongInfoSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Track Info") {
                    infoRow("Title", song.title)
                    infoRow("Artist", song.artist ?? String(localized: "Unknown"))
                    infoRow("Album", song.album ?? String(localized: "Unknown"))
                    if let track = song.track { infoRow("Track #", "\(track)") }
                    if let year = song.year { infoRow("Year", "\(year)") }
                    if let genre = song.genre { infoRow("Genre", genre) }
                    infoRow("Duration", song.durationFormatted)
                    if let pc = song.playCount { infoRow("Play Count", "\(pc)") }
                }
                SongRatingSection(song: song)
                SongFileSections(song: song)
            }
            .scrollIndicators(.hidden)
            .auraSheet()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("File Info").font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
#endif

/// How the song is playing and the file behind it — shared by File Info and the Now
/// Playing sheet, which shows it under the credits.
struct SongFileSections: View {
    let song: Song

    /// The rows, grouped, for this sheet's List and for the card layout of Song Info.
    static func groups(for song: Song) -> [(title: LocalizedStringKey, rows: [(label: String, value: String)])] {
        let settings = AppSettings.shared
        let suffix = song.suffix?.lowercased() ?? ""
        let format: String
        if suffix == "ogg" || suffix == "opus" || suffix == "wma" {
            format = String(localized: "MP3 (Auto-transcoded from \(suffix.uppercased()))")
        } else if let br = settings.effectiveStreamingQuality.bitRate, suffix == "flac" || suffix == "alac" {
            format = String(localized: "MP3 \(br) kbps (Transcoded from \(suffix.uppercased()))")
        } else {
            format = String(localized: "\(suffix.uppercased()) (Original)")
        }
        var file: [(String, String)] = []
        if let bitRate = song.bitRate { file.append(("Bitrate", "\(bitRate) kbps")) }
        if let s = song.suffix { file.append(("Format", s.uppercased())) }
        if let contentType = song.contentType { file.append(("Content Type", contentType)) }
        file.append(("File Size", song.fileSizeFormatted))
        if let path = song.path { file.append(("Path", path)) }
        var ids: [(String, String)] = [("Song ID", song.id)]
        if let albumId = song.albumId { ids.append(("Album ID", albumId)) }
        if let artistId = song.artistId { ids.append(("Artist ID", artistId)) }
        return [("Currently Playing As", [("Format", format)]), ("Original File", file), ("IDs", ids)]
    }

    var body: some View {
        ForEach(Array(Self.groups(for: song).enumerated()), id: \.offset) { _, group in
            Section(group.title) {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in infoRow(row.label, row.value) }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Rating

/// Stars for one or several songs, in any song's context menu.
struct SongRatingMenu: View {
    let songs: [Song]

    var body: some View {
        let ratings = SongRatings.shared
        let current = songs.count == 1 ? ratings.rating(for: songs[0]) : -1
        #if os(iOS)
        // Stars in a row inside the menu: a submenu closed itself whenever the menu redrew.
        // Tapping the current rating clears it.
        ControlGroup {
            ForEach(1...5, id: \.self) { stars in
                Button {
                    songs.forEach { ratings.set(stars == current ? 0 : stars, for: $0) }
                } label: {
                    // Small, so the first and last stars keep inside the other rows' icon margins.
                    Image(systemName: stars <= current ? "star.fill" : "star")
                        .imageScale(.small)
                        .accessibilityLabel(String(repeating: "★", count: stars))
                }
            }
        }
        .controlGroupStyle(.palette)
        .disabled(songs.isEmpty)
        #else
        Menu {
            ForEach(0...5, id: \.self) { stars in
                Button {
                    songs.forEach { ratings.set(stars, for: $0) }
                } label: {
                    let label = stars == 0 ? String(localized: "No Rating") : String(repeating: "★", count: stars)
                    if stars == current { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            Label("Rating", systemImage: "star")
        }
        .disabled(songs.isEmpty)
        #endif
    }
}


/// Five stars to rate a song on the server. Tapping the current rating clears it.
struct SongRatingSection: View {
    let song: Song
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        if !song.isPreview {
            let ratings = SongRatings.shared
            let rating = ratings.rating(for: song)
            Section("Rating") {
                HStack(spacing: 16) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            ratings.set(rating == star ? 0 : star, for: song)
                        } label: {
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundStyle(accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
        }
    }
}

