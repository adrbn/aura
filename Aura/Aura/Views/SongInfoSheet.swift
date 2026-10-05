import SwiftUI

// MARK: - Song Info Sheet

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

/// How the song is playing and the file behind it — shared by File Info and the Now
/// Playing sheet, which shows it under the credits.
struct SongFileSections: View {
    let song: Song
    @State private var appSettings = AppSettings.shared

    private var playbackFormat: String {
        let suffix = song.suffix?.lowercased() ?? ""
        let needsTranscode = suffix == "ogg" || suffix == "opus" || suffix == "wma"
        if needsTranscode {
            return String(localized: "MP3 (Auto-transcoded from \(suffix.uppercased()))")
        } else if let br = appSettings.effectiveStreamingQuality.bitRate, suffix == "flac" || suffix == "alac" {
            return String(localized: "MP3 \(br) kbps (Transcoded from \(suffix.uppercased()))")
        } else {
            return String(localized: "\(suffix.uppercased()) (Original)")
        }
    }

    private var playbackBitrate: String {
        let suffix = song.suffix?.lowercased() ?? ""
        if suffix == "ogg" || suffix == "opus" || suffix == "wma" {
            let br = appSettings.effectiveStreamingQuality.bitRate ?? 320
            return "\(br) kbps"
        } else if let br = appSettings.effectiveStreamingQuality.bitRate {
            return String(localized: "\(br) kbps (max)")
        } else {
            return String(localized: "Original")
        }
    }

    var body: some View {
        Section("Currently Playing As") {
            infoRow("Format", playbackFormat)
        }
        Section("Original File") {
            if let bitRate = song.bitRate { infoRow("Bitrate", "\(bitRate) kbps") }
            if let suffix = song.suffix { infoRow("Format", suffix.uppercased()) }
            if let contentType = song.contentType { infoRow("Content Type", contentType) }
            infoRow("File Size", song.fileSizeFormatted)
            if let path = song.path { infoRow("Path", path) }
        }
        Section("IDs") {
            infoRow("Song ID", song.id)
            if let albumId = song.albumId { infoRow("Album ID", albumId) }
            if let artistId = song.artistId { infoRow("Artist ID", artistId) }
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

