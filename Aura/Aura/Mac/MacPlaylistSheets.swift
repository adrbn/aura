import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The phone's Add Songs: search the server and add songs one click at a time, the sheet
/// staying open. Before a search it offers suggestions, so it never opens on a blank page.
struct MacAddSongsSheet: View {
    let playlistSongs: [Song]
    let onAdd: (Song) async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var suggestions: [Song] = []
    @State private var isSearching = false
    @State private var added: Set<String> = []

    private var alreadyIn: Set<String> { Set(playlistSongs.map(\.id)) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Songs").font(.title2.bold())
            TextField("Songs, artists, albums", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if searching {
                        if results.isEmpty && !isSearching {
                            Text("No results").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(results) { row($0) }
                    } else if !suggestions.isEmpty {
                        Text("Suggestions").font(.title3.bold()).padding(.vertical, 6)
                        ForEach(suggestions) { row($0) }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 620)
        .task {
            guard let server = ServerManager.shared.currentServer else { return }
            suggestions = await PlaylistSuggester.suggest(server: server, for: playlistSongs, count: 25)
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { results = []; return }
            isSearching = true
            defer { isSearching = false }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let server = ServerManager.shared.currentServer else { return }
            let found = try? await SubsonicClient.shared.search3(server: server, query: text,
                                                                 artistCount: 0, albumCount: 0, songCount: 40)
            if !Task.isCancelled { results = found?.song ?? [] }
        }
    }

    private func row(_ song: Song) -> some View {
        let isIn = alreadyIn.contains(song.id) || added.contains(song.id)
        return HStack(spacing: 4) {
            MacSongRow(song: song)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { _ = added.insert(song.id) }
                Task { await onAdd(song) }
            } label: {
                Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isIn)
            .accessibilityLabel(isIn ? "Added" : "Add to Playlist")
        }
    }
}

/// A playlist's name and description, as the phone's Modify sheet edits them.
struct MacPlaylistEditSheet: View {
    let playlistId: String
    let currentName: String
    let currentComment: String
    /// Called with the new name and description once the server took them.
    let onSaved: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var comment = ""
    @State private var isSaving = false

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Playlist Name", text: $name)
                TextField("Description (optional)", text: $comment, axis: .vertical)
                    .lineLimit(1...4)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleanName.isEmpty || isSaving)
            }
            .padding(16)
        }
        .frame(width: 440)
        .onAppear {
            name = currentName
            comment = currentComment
        }
    }

    private func save() async {
        let typedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server = ServerManager.shared.currentServer else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await SubsonicClient.shared.updatePlaylist(server: server, id: playlistId,
                                                           name: cleanName, comment: typedComment)
        } catch {
            ToastManager.shared.show(String(localized: "Couldn't save the playlist"), icon: "exclamationmark.triangle.fill")
            return
        }
        // Now Playing names what plays by its source; a renamed playlist renames it there too.
        let player = AudioPlayer.shared
        if case .playlist(let id, _) = player.playbackSource, id == playlistId {
            player.playbackSource = .playlist(id: id, name: cleanName)
        }
        onSaved(cleanName, typedComment)
        dismiss()
    }
}

/// Picking a picture for a playlist's cover and saving one, through the Mac's own panels.
@MainActor
enum MacCoverFile {
    /// A picture picked in an open panel, made what the phone uploads: square, at most
    /// 1200 px, JPEG.
    static func pickJPEG() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              // Upright, whatever the photo's orientation says.
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let side = min(image.width, image.height)
        let out = min(side, 1200)
        guard let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                     width: side, height: side)),
              let context = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// The server's picture at full size, saved where a save panel says.
    static func save(coverArt: String?, name: String) {
        guard let coverArt else { return }
        Task {
            let size = ArtworkCache.fullSize
            guard let image = await ArtworkCache.shared.fetchImage(coverArt: coverArt, requestSize: size,
                                                                   key: "\(coverArt)_\(size)") else {
                ToastManager.shared.show(String(localized: "Couldn’t load the cover"), icon: "exclamationmark.triangle.fill")
                return
            }
            save(image, name: name)
        }
    }

    static func save(_ image: NSImage, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = image.auraJPEGData(quality: 0.95) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
        } catch {
            AppLogger.shared.log("❌ Save cover art failed: \(error.localizedDescription)")
            ToastManager.shared.show(String(localized: "Couldn’t save the cover"), icon: "exclamationmark.triangle.fill")
        }
    }
}
