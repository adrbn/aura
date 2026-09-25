import SwiftUI

#if !APPSTORE_BUILD

/// The release being fetched, above the mini player: which of the four steps it's at, and
/// how far into it — then Play once it's in the library, or Retry if it didn't make it.
struct FetchProgressBanner: View {
    /// Room below it: a gap above the mini player, or the tab bar's height without one.
    let bottomGap: CGFloat
    /// The card's own height, so the pages behind it can end above it.
    @Binding var height: CGFloat
    @State private var fetcher = ReleaseFetcher.shared

    var body: some View {
        if let fetch = fetcher.visible.first {
            FetchCard(fetch: fetch, others: fetcher.visible.count - 1)
                .id(fetch.id)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .padding(.bottom, bottomGap)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct FetchCard: View {
    let fetch: ReleaseFetch
    let others: Int

    @Environment(AudioPlayer.self) private var player
    @Environment(\.appAccentColor) private var accentColor
    @Environment(\.openURL) private var openURL
    @State private var isOpening = false

    private var fetcher: ReleaseFetcher { .shared }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: fetch.release.cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.primary.opacity(0.08)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(fetch.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if others > 0 {
                        Text("+\(others)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                // The import's countdown moves with the clock, not with any update.
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    Text(fetch.detail.isEmpty ? fetch.headline : "\(fetch.headline) · \(fetch.detail)")
                        .font(.caption)
                        .foregroundStyle(fetch.stage == .failed ? .orange : .secondary)
                        .lineLimit(1)
                }
                FetchSteps(fetch: fetch, tint: accentColor)
            }

            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if fetch.stage == .ready { Task { await play() } } }
        .contextMenu {
            if let link = fetch.release.link.flatMap(URL.init(string:)) {
                Button { openURL(link) } label: { Label("Open in Deezer", systemImage: "arrow.up.right") }
            }
            Button(role: fetch.isActive ? .destructive : nil) { fetcher.dismiss(fetch.id) } label: {
                Label(fetch.isActive ? "Stop" : "Dismiss", systemImage: "xmark")
            }
        }
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fetch.title), \(fetch.headline). \(fetch.detail)")
    }

    @ViewBuilder
    private var trailing: some View {
        switch fetch.stage {
        case .ready:
            Button { Task { await play() } } label: {
                Group {
                    if isOpening { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")
        case .failed:
            HStack(spacing: 4) {
                Button { fetcher.retry(fetch.id) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Retry")
                Button { fetcher.dismiss(fetch.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 32)
                }
                .accessibilityLabel("Dismiss")
            }
            .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }

    /// The release from the library, from its first track — or the one song fetched.
    private func play() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        guard let songs = await fetcher.songs(of: fetch), let first = songs.first else { return }
        player.playSong(first, fromQueue: songs, source: .album(id: first.albumId ?? "", name: fetch.release.title))
        fetcher.dismiss(fetch.id)
    }
}

/// Four segments — look, download, add, ready: the ones done full, the current one filling.
struct FetchSteps: View {
    let fetch: ReleaseFetch
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<ReleaseFetchAttributes.steps, id: \.self) { index in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.14))
                        Capsule()
                            .fill(fetch.stage == .failed ? Color.orange : tint)
                            .frame(width: geo.size.width * fill(index))
                    }
                }
                .frame(height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: fetch.progress)
        .animation(.easeInOut(duration: 0.4), value: fetch.stage)
    }

    private func fill(_ index: Int) -> CGFloat {
        if fetch.stage == .failed { return index == 0 ? 1 : 0 }
        if index < fetch.step || fetch.stage == .ready { return 1 }
        guard index == fetch.step else { return 0 }
        switch fetch.stage {
        case .searching:
            return fetch.found > 0 ? 0.7 : 0.25
        case .downloading:
            return max(0.04, min(fetch.progress, 1))
        case .importing:
            guard let start = fetch.downloaded else { return 0.1 }
            let share = Date().timeIntervalSince(start) / ReleaseFetcher.importEstimate
            return max(0.05, min(share, 0.95))
        default:
            return 0
        }
    }
}

#endif
