import SwiftUI
import UIKit

// MARK: - Song Share Sheet

struct SongShareSheet: View {
    let song: Song
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @State private var songLinks: SongLinkService.SongLinks?
    @State private var isLoading = true
    @State private var copiedPlatform: String?
    @State private var shareURL: URL?
    // Freeze song info at open time so it doesn't update if the song changes
    @State private var frozenTitle: String = ""
    @State private var frozenArtist: String = ""
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Finding links...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let links = songLinks {
                    Spacer().frame(height: 8)
                    // Song info — title on top, artist below
                    VStack(spacing: 2) {
                        Text(frozenTitle)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text(frozenArtist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 60)
                    Spacer().frame(height: 4)

                    VStack(spacing: 10) {
                        sharePlatformRow(
                            name: "Spotify",
                            icon: "play.circle.fill",
                            iconColor: Color(red: 0.114, green: 0.725, blue: 0.329),
                            url: links.spotify,
                            platform: "spotify"
                        )
                        sharePlatformRow(
                            name: "Apple Music",
                            icon: "music.note",
                            iconColor: .pink,
                            url: links.appleMusic,
                            platform: "appleMusic"
                        )
                        sharePlatformRow(
                            name: "YouTube Music",
                            icon: "play.rectangle.fill",
                            iconColor: .red,
                            url: links.youtubeMusic,
                            platform: "youtubeMusic"
                        )
                        sharePlatformRow(
                            name: "Deezer",
                            icon: "waveform",
                            iconColor: .purple,
                            url: links.deezer,
                            platform: "deezer"
                        )
                        sharePlatformRow(
                            name: "Yandex Music",
                            icon: "y.circle.fill",
                            iconColor: .red,
                            url: links.yandex,
                            platform: "yandex"
                        )

                        Divider().padding(.horizontal, 4)

                        sharePlatformRow(
                            name: "Universal Link",
                            icon: "link.circle.fill",
                            iconColor: .blue,
                            url: links.pageUrl,
                            platform: "universal"
                        )
                    }
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Song not found on streaming platforms")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        refreshForCurrentSong()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .disabled(isRefreshing || isLoading)
                    .opacity(isRefreshing ? 0.5 : 1)
                }
                ToolbarItem(placement: .principal) {
                    Text("Share").font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareURL) { url in
                ShareSheet(activityItems: [url])
            }
            .task {
                frozenTitle = song.title
                frozenArtist = song.artist ?? "Unknown"
                let artist = song.artist ?? ""
                songLinks = await SongLinkService.shared.fetchLinks(title: song.title, artist: artist)
                isLoading = false
            }
        }
    }

    private func refreshForCurrentSong() {
        guard let current = player.currentSong else { return }
        isRefreshing = true
        isLoading = true
        frozenTitle = current.title
        frozenArtist = current.artist ?? "Unknown"
        copiedPlatform = nil
        songLinks = nil
        Task {
            songLinks = await SongLinkService.shared.fetchLinks(title: current.title, artist: current.artist ?? "")
            isLoading = false
            isRefreshing = false
        }
    }

    private func sharePlatformRow(name: String, icon: String, iconColor: Color, url: String?, platform: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
            Text(name)
                .font(.subheadline.weight(.medium))
            Spacer()
            if url != nil {
                // Copy button
                Button {
                    UIPasteboard.general.string = url
                    copiedPlatform = platform
                    ToastManager.shared.show("Copied \(name) link", icon: "doc.on.doc")
                } label: {
                    Image(systemName: copiedPlatform == platform ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.subheadline)
                        .foregroundStyle(copiedPlatform == platform ? .green : accentColor)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                // Native iOS share button
                Button {
                    if let url, let link = URL(string: url) {
                        shareURL = link
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundStyle(accentColor)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            } else {
                Text("Not available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(url == nil ? 0.4 : 1.0)
    }
}

// UIKit share sheet wrapper
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
