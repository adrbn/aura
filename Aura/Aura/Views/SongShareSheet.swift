import SwiftUI
import UIKit

// MARK: - Song Share Sheet

struct SongShareSheet: View {
    let song: Song
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.openURL) private var openURL
    @State private var songLinks: SongLinkService.SongLinks?
    @State private var isLoading = true
    @State private var copiedPlatform: String?
    @State private var shareURL: URL?
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
                    VStack(spacing: 10) {
                        sharePlatformRow(
                            name: "Spotify",
                            icon: "play.circle.fill",
                            iconColor: Color(red: 0.114, green: 0.725, blue: 0.329),
                            link: links.spotify,
                            platform: "spotify"
                        )
                        sharePlatformRow(
                            name: "Apple Music",
                            icon: "music.note",
                            iconColor: .pink,
                            link: links.appleMusic,
                            platform: "appleMusic"
                        )
                        sharePlatformRow(
                            name: "YouTube Music",
                            icon: "play.rectangle.fill",
                            iconColor: .red,
                            link: links.youtubeMusic,
                            platform: "youtubeMusic"
                        )
                        sharePlatformRow(
                            name: "Deezer",
                            icon: "waveform",
                            iconColor: .purple,
                            link: links.deezer,
                            platform: "deezer"
                        )
                        sharePlatformRow(
                            name: "Yandex Music",
                            icon: "y.circle.fill",
                            iconColor: .red,
                            link: links.yandex,
                            platform: "yandex"
                        )

                        Divider().padding(.horizontal, 4)

                        sharePlatformRow(
                            name: "Universal Link",
                            icon: "link.circle.fill",
                            iconColor: .blue,
                            link: links.pageUrl.map { SongLinkService.PlatformLink(url: $0, isSearch: false) },
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
        copiedPlatform = nil
        songLinks = nil
        Task {
            songLinks = await SongLinkService.shared.fetchLinks(title: current.title, artist: current.artist ?? "")
            isLoading = false
            isRefreshing = false
        }
    }

    private func sharePlatformRow(name: String, icon: String, iconColor: Color, link: SongLinkService.PlatformLink?, platform: String) -> some View {
        HStack(spacing: 14) {
            // Tapping the row opens the destination itself. The copy and share
            // buttons stay for when you want the URL rather than the page.
            Button {
                if let link, let url = URL(string: link.url) { openURL(url) }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(iconColor)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.subheadline.weight(.medium))
                        // These platforms have no key-less lookup, so the link opens a
                        // search rather than the song itself — say so instead of implying
                        // we resolved it.
                        if link?.isSearch == true {
                            Text("Opens a search")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(link == nil)

            if let link {
                // Copy button
                Button {
                    UIPasteboard.general.string = link.url
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
                    if let url = URL(string: link.url) {
                        shareURL = url
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
        .opacity(link == nil ? 0.4 : 1.0)
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
