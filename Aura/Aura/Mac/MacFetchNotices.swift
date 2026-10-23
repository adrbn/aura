import SwiftUI

#if !APPSTORE_BUILD

/// Get It on the Mac, as the system's own notifications are: a glass card top-right that,
/// after a moment, slides into a bubble — the four steps' ring, filling as it goes. Hovering
/// or clicking a bubble opens it again, and so does the release being ready or failing.
struct MacFetchNotices: View {
    @State private var fetcher = ReleaseFetcher.shared
    /// The ones shown whole; the rest are bubbles.
    @State private var open: Set<String> = []
    @State private var hovered: String?

    /// How long a card stays whole before it folds into its bubble.
    private static let linger: Duration = .seconds(4)

    /// Several at once: one bubble for all of them, the list under the pointer.
    @State private var listing = false

    var body: some View {
        let fetches = fetcher.fetches
        VStack(alignment: .trailing, spacing: 8) {
            if fetches.count > 1 {
                MacFetchGroupBubble(fetches: fetches)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            // One alone shows as itself; of several, the ones just in or just done, or all
            // of them while the pointer is over the group.
            ForEach(fetches.count > 1 ? fetches.filter { listing || open.contains($0.id) } : Array(fetches.prefix(1))) { fetch in
                MacFetchNotice(fetch: fetch, isOpen: fetches.count > 1 || open.contains(fetch.id) || hovered == fetch.id) {
                    show(fetch.id)
                }
                .onHover { inside in
                    withAnimation(.smooth(duration: 0.35)) { hovered = inside ? fetch.id : nil }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onHover { inside in
            withAnimation(.smooth(duration: 0.35)) { listing = inside && fetches.count > 1 }
        }
        .animation(.smooth(duration: 0.35), value: listing)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: fetches.map(\.id))
        .onChange(of: fetcher.fetches.map(\.id)) { old, new in
            for id in new where !old.contains(id) { show(id) }
        }
        // Done or stuck: worth a look without having to go and find it.
        .onChange(of: fetcher.fetches.map { "\($0.id)\($0.stage)" }) { _, _ in
            for fetch in fetcher.fetches where !fetch.isActive && !open.contains(fetch.id) { show(fetch.id) }
        }
    }

    private func show(_ id: String) {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { _ = open.insert(id) }
        Task {
            try? await Task.sleep(for: Self.linger)
            withAnimation(.spring(duration: 0.5, bounce: 0.12)) { _ = open.remove(id) }
        }
    }
}

/// Several fetches as one bubble: how many are still going, ringed by how many are done.
/// Clicking it opens the panel where they're all managed.
private struct MacFetchGroupBubble: View {
    let fetches: [ReleaseFetch]
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        let active = fetches.filter(\.isActive).count
        let failed = fetches.contains { $0.stage == .failed }
        let done = Double(fetches.count - active) / Double(max(fetches.count, 1))
        Button { MacFetchPanel.shared.isShown = true } label: {
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: max(done, 0.02))
                    .stroke(failed ? Color.orange : accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(active > 0 ? active : fetches.count)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
            }
            .padding(5)
            .frame(width: 46, height: 46)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(MacPressStyle())
        .animation(.smooth, value: done)
        .help("Get It")
        .contextMenu {
            Button("Show All") { MacFetchPanel.shared.isShown = true }
            if fetches.contains(where: { !$0.isActive }) {
                Button("Clear Finished") { MacFetchPanel.clearFinished() }
            }
        }
    }
}

/// One release: the card when open, folded to its ring when not. The same glass morphs
/// between the two, narrowing toward its right edge, so the card visibly becomes the bubble.
private struct MacFetchNotice: View {
    let fetch: ReleaseFetch
    let isOpen: Bool
    let reopen: () -> Void

    @Environment(\.appAccentColor) private var accentColor
    @State private var isOpening = false

    private var fetcher: ReleaseFetcher { .shared }
    private static let bubble: CGFloat = 46

    var body: some View {
        HStack(spacing: 10) {
            if isOpen {
                AsyncImage(url: fetch.release.cover.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.primary.opacity(0.08)
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fetch.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(fetch.detail.isEmpty ? fetch.headline : "\(fetch.headline) · \(fetch.detail)")
                        .font(.caption)
                        .foregroundStyle(fetch.stage == .failed ? .orange : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .offset(x: 24)))
            }
            trailing
        }
        .padding(.leading, isOpen ? 8 : 0)
        .padding(.trailing, isOpen ? 8 : 0)
        .frame(width: isOpen ? 340 : Self.bubble, height: Self.bubble)
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
        .onTapGesture {
            if isOpen, fetch.stage == .ready { Task { await play() } } else { reopen() }
        }
        .contextMenu {
            Button(role: fetch.isActive ? .destructive : nil) { fetcher.dismiss(fetch.id) } label: {
                Label(fetch.isActive ? "Stop" : "Dismiss", systemImage: "xmark")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fetch.title), \(fetch.headline). \(fetch.detail)")
    }

    @ViewBuilder
    private var trailing: some View {
        switch fetch.stage {
        case .ready:
            Button { Task { await play() } } label: {
                Group {
                    if isOpening { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(accentColor, in: Circle())
            }
            .buttonStyle(MacPressStyle())
            .padding(isOpen ? 0 : 7)
            .accessibilityLabel("Play")
        case .failed:
            if isOpen {
                HStack(spacing: 2) {
                    Button { fetcher.retry(fetch.id) } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Retry")
                    Button { fetcher.dismiss(fetch.id) } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary).frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(MacPressStyle())
            } else {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: Self.bubble, height: Self.bubble)
            }
        default:
            FetchStepsRing(fetch: fetch, tint: accentColor)
                .frame(width: isOpen ? 32 : 38, height: isOpen ? 32 : 38)
                .padding(isOpen ? 0 : 4)
        }
    }

    /// The release from the library, from its first track — or the one song fetched.
    private func play() async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        guard let songs = await fetcher.songs(of: fetch), let first = songs.first else { return }
        AudioPlayer.shared.playSong(first, fromQueue: songs,
                                    source: .album(id: first.albumId ?? "", name: fetch.release.title))
        fetcher.dismiss(fetch.id)
    }
}

@MainActor @Observable final class MacFetchPanel {
    static let shared = MacFetchPanel()
    var isShown = false

    static func clearFinished() {
        let fetcher = ReleaseFetcher.shared
        for fetch in fetcher.fetches where !fetch.isActive { fetcher.dismiss(fetch.id) }
    }
}

/// Every Get It at once, as the settings are: a panel over the dimmed window, each release
/// with its step, and what can be done about it.
struct MacFetchPanelView: View {
    @State private var fetcher = ReleaseFetcher.shared
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Get It").font(.system(size: 20, weight: .bold))
                Spacer()
                if fetcher.fetches.contains(where: { !$0.isActive }) {
                    Button("Clear Finished") { MacFetchPanel.clearFinished() }
                        .buttonStyle(MacPressStyle())
                        .font(.callout.weight(.medium))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.trailing, 36)
            .padding(.bottom, 12)
            Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
            if fetcher.fetches.isEmpty {
                ContentUnavailableView("Nothing on its way", systemImage: "arrow.down.circle")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(fetcher.fetches) { MacFetchPanelRow(fetch: $0) }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 560, height: 460)
        .background(MacBackground(grid: false))
        .overlay(alignment: .topTrailing) {
            Button { MacFetchPanel.shared.isShown = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        .tint(Color.appAccent)
        .animation(.smooth(duration: 0.3), value: fetcher.fetches.map(\.id))
    }
}

private struct MacFetchPanelRow: View {
    let fetch: ReleaseFetch
    @Environment(\.appAccentColor) private var accentColor
    @State private var hovering = false
    private var fetcher: ReleaseFetcher { .shared }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: fetch.release.cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.primary.opacity(0.08)
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(fetch.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(fetch.detail.isEmpty ? fetch.headline : "\(fetch.headline) · \(fetch.detail)")
                    .font(.caption)
                    .foregroundStyle(fetch.stage == .failed ? .orange : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            switch fetch.stage {
            case .ready:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(accentColor)
            case .failed:
                Button { fetcher.retry(fetch.id) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }
                .buttonStyle(MacPressStyle())
                .help("Retry")
            default:
                FetchStepsRing(fetch: fetch, tint: accentColor).frame(width: 28, height: 28)
            }
            Button { fetcher.dismiss(fetch.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.primary.opacity(hovering ? 0.08 : 0), in: Circle())
            }
            .buttonStyle(MacPressStyle())
            .help(fetch.isActive ? "Stop" : "Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
        .contextMenu {
            if fetch.stage == .failed { Button("Retry") { fetcher.retry(fetch.id) } }
            Button(role: fetch.isActive ? .destructive : nil) { fetcher.dismiss(fetch.id) } label: {
                Text(fetch.isActive ? "Stop" : "Dismiss")
            }
        }
    }
}

#endif
