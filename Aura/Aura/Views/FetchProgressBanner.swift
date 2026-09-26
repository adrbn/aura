import SwiftUI

#if !APPSTORE_BUILD

/// The releases being fetched, above the mini player: which of the four steps each is at,
/// and how far into it — then Play once it's in the library, or Retry if it didn't make it.
///
/// With several on their way they sit side by side, one on screen at a time: a swipe
/// slides the next one in, and it lands with a small bounce. Past either end the row
/// gives a little, then springs back.
struct FetchProgressBanner: View {
    /// Room below it: a gap above the mini player, or the tab bar's height without one.
    let bottomGap: CGFloat
    /// The card's own height, so the pages behind it can end above it.
    @Binding var height: CGFloat
    @State private var fetcher = ReleaseFetcher.shared
    @State private var selected: String?

    var body: some View {
        // In the order they were asked for, newest first — not running-first like
        // `visible`, which would reshuffle the row under the finger as fetches finish.
        let fetches = fetcher.fetches
        FetchDeck(fetches: fetches, selected: $selected)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .padding(.bottom, fetches.isEmpty ? 0 : bottomGap)
            .onChange(of: fetches.map(\.id)) { old, new in
                withAnimation(FetchDeck.settle) {
                    // One just asked for comes to the front; one that's gone hands the front
                    // over to its neighbour.
                    if let fresh = new.first(where: { !old.contains($0) }) {
                        selected = fresh
                    } else if let current = selected, !new.contains(current) {
                        let was = old.firstIndex(of: current) ?? 0
                        selected = new.isEmpty ? nil : new[min(was, new.count - 1)]
                    }
                }
            }
    }
}

private struct FetchDeck: View {
    let fetches: [ReleaseFetch]
    @Binding var selected: String?
    @State private var drag: CGFloat = 0
    @State private var width: CGFloat = 1

    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.72)

    private var index: Int { fetches.firstIndex { $0.id == selected } ?? 0 }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(fetches.enumerated()), id: \.element.id) { offset, fetch in
                // 0 on screen, -1 off to the left, 1 waiting off to the right; a swipe
                // carries the whole row with the finger.
                let place = CGFloat(offset - index) + drag / max(width, 1)
                let onScreen = offset == index
                FetchCard(fetch: fetch,
                          position: fetches.count > 1 ? "\(offset + 1)/\(fetches.count)" : nil)
                    .offset(x: place * width)
                    // Only a neighbour ever slides into view; the rest keep out of the way.
                    .opacity(abs(place) < 1.5 ? 1 : 0)
                    .allowsHitTesting(onScreen)
                    .accessibilityHidden(!onScreen)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: settle(on: index + 1)
                        case .decrement: settle(on: index - 1)
                        @unknown default: break
                        }
                    }
                    // Leaves by sliding down behind the mini player, fading once it's under
                    // the glass, rather than sliding across it.
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(
                            with: .opacity.animation(.easeIn(duration: 0.2).delay(0.18)))))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
        .gesture(swipe, including: fetches.count > 1 ? .all : .subviews)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let x = value.translation.width
                // Sideways only: a mostly vertical drag is left alone.
                guard drag != 0 || abs(x) > abs(value.translation.height) else { return }
                // Past either end the row gives a little, then springs back.
                let pastEnd = (index == 0 && x > 0) || (index == fetches.count - 1 && x < 0)
                drag = pastEnd ? x / (1 + abs(x) / 90) : x
            }
            .onEnded { value in
                guard drag != 0 else { return }
                let reach = value.predictedEndTranslation.width
                let threshold = width * 0.3
                settle(on: reach < -threshold ? index + 1 : reach > threshold ? index - 1 : index)
            }
    }

    private func settle(on target: Int) {
        let clamped = min(max(target, 0), fetches.count - 1)
        guard fetches.indices.contains(clamped) else { return }
        withAnimation(Self.settle) {
            selected = fetches[clamped].id
            drag = 0
        }
    }
}

private struct FetchCard: View {
    let fetch: ReleaseFetch
    /// Where it sits in the row, as "2/3" — nil when it's alone.
    let position: String?

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
                    if let position {
                        Text(position)
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
            let share = Date().timeIntervalSince(start) / ImportPace.estimate
            return max(0.05, min(share, 0.95))
        default:
            return 0
        }
    }
}

#endif
