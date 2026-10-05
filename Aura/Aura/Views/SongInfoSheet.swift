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
                    infoRow("Artist", song.artist ?? "Unknown")
                    infoRow("Album", song.album ?? "Unknown")
                    if let track = song.track { infoRow("Track #", "\(track)") }
                    if let year = song.year { infoRow("Year", "\(year)") }
                    if let genre = song.genre { infoRow("Genre", genre) }
                    infoRow("Duration", song.durationFormatted)
                    if let pc = song.playCount { infoRow("Play Count", "\(pc)") }
                }
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
            Text(label)
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
            return "MP3 (Auto-transcoded from \(suffix.uppercased()))"
        } else if let br = appSettings.streamingQuality.bitRate, suffix == "flac" || suffix == "alac" {
            return "MP3 \(br) kbps (Transcoded from \(suffix.uppercased()))"
        } else {
            return "\(suffix.uppercased()) (Original)"
        }
    }

    private var playbackBitrate: String {
        let suffix = song.suffix?.lowercased() ?? ""
        if suffix == "ogg" || suffix == "opus" || suffix == "wma" {
            let br = appSettings.streamingQuality.bitRate ?? 320
            return "\(br) kbps"
        } else if let br = appSettings.streamingQuality.bitRate {
            return "\(br) kbps (max)"
        } else {
            return "Original"
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
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
