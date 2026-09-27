import SwiftUI

#if !APPSTORE_BUILD

/// The releases being fetched, above the mini player: which of the four steps each is at,
/// and how far into it — then Play once it's in the library, or Retry if it didn't make it.
///
/// A slim pill: the cover, the title with where it's at, and the four steps as a ring at
/// its end — present without weighing on the screen, and nothing drawn over the words.
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
        HStack(spacing: 10) {
            AsyncImage(url: fetch.release.cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.primary.opacity(0.08)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fetch.title)
                        .font(.footnote.weight(.semibold))
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
                        .font(.caption2)
                        .foregroundStyle(fetch.stage == .failed ? .orange : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
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
        .glassEffect(.regular, in: Capsule())
        .clipShape(Capsule())
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
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")
        case .failed:
            HStack(spacing: 4) {
                Button { fetcher.retry(fetch.id) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Retry")
                Button { fetcher.dismiss(fetch.id) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 30)
                }
                .accessibilityLabel("Dismiss")
            }
            .buttonStyle(.plain)
        default:
            FetchStepsRing(fetch: fetch, tint: accentColor)
                .frame(width: 30, height: 30)
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

/// The four steps — look, download, add, ready — as a ring of four arcs: the ones done
/// full, the current one filling, and the step's own sign in the middle.
private struct FetchStepsRing: View {
    let fetch: ReleaseFetch
    let tint: Color

    private static let lineWidth: CGFloat = 2.5
    /// The gap between two arcs, as a share of the circle.
    private static let gap = 0.035

    private var steps: Int { ReleaseFetchAttributes.steps }

    private var symbol: String {
        switch fetch.stage {
        case .searching: return "magnifyingglass"
        case .downloading: return "arrow.down"
        default: return "tray.and.arrow.down"
        }
    }

    var body: some View {
        ZStack {
            ForEach(0..<steps, id: \.self) { index in
                let start = Double(index) / Double(steps) + Self.gap / 2
                let end = Double(index + 1) / Double(steps) - Self.gap / 2
                arc(from: start, to: end).stroke(Color.primary.opacity(0.14), style: stroke)
                arc(from: start, to: start + (end - start) * Double(FetchSteps.fill(index, of: fetch)))
                    .stroke(tint, style: stroke)
            }
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(Self.lineWidth / 2 + 2)
        .animation(.easeInOut(duration: 0.4), value: fetch.progress)
        .animation(.easeInOut(duration: 0.4), value: fetch.stage)
        .accessibilityHidden(true)
    }

    private var stroke: StrokeStyle { StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round) }

    /// From 12 o'clock, clockwise.
    private func arc(from start: Double, to end: Double) -> some Shape {
        Circle().trim(from: start, to: max(start, end)).rotation(.degrees(-90))
    }
}

/// How full each of the four steps is — look, download, add, ready.
enum FetchSteps {
    static func fill(_ index: Int, of fetch: ReleaseFetch) -> CGFloat {
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
