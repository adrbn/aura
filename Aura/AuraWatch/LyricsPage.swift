import SwiftUI

/// The lyrics mode of the Now Playing screen, as the phone shows its lyrics: the line being
/// sung large and sharp in the middle, its neighbours small, faint and out of focus, the rest
/// gone — and word by word, when the phone has karaoke on.
///
/// The Crown walks the lines, each one sharpening as it passes the middle; a tap on one jumps
/// the song to it. Left alone for a moment, the sheet returns to the song.
struct LyricsMode: View {
    let state: WatchNowPlaying
    @Environment(\.isLuminanceReduced) private var isDimmed
    /// The line the Crown has reached, while it's being turned.
    @State private var browsed: Int?
    @State private var crown = 0.0
    @State private var settle: Task<Void, Never>?

    var body: some View {
        let isSynced = state.lyrics.contains { $0.time != nil }
        // Only as often as the song asks: a word-by-word line needs a smooth clock, a line
        // at a time a quarter-second one; nothing at all while paused or dimmed.
        let interval = state.karaoke ? 1.0 / 15 : 0.25
        TimelineView(.animation(minimumInterval: interval, paused: isDimmed || !state.isPlaying)) { context in
            let elapsed = state.elapsed(at: context.date)
            let sung = isSynced ? state.lyrics.lastIndex { ($0.time ?? .infinity) <= elapsed } : nil
            LyricSheet(state: state, sung: sung, focus: browsed ?? sung ?? 0, isSynced: isSynced,
                       isBrowsing: browsed != nil, elapsed: elapsed)
                .onChange(of: sung, initial: true) { _, line in
                    if browsed == nil, let line { crown = Double(line) }
                }
        }
        .lyricCrown($crown, lines: state.lyrics.count) { value in
            let line = Int(value.rounded())
            guard line != browsed else { return }
            settle?.cancel()
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) { browsed = line }
        } idle: {
            settle?.cancel()
            settle = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.45)) { browsed = nil }
            }
        }
        .onChange(of: state.songId) { _, _ in
            browsed = nil
            crown = 0
        }
    }
}

/// Every line at one size, stacked, and the stack slid so the line in focus sits in the
/// middle. Neighbours shrink by scale, never by font size, so no line ever re-wraps as the
/// song moves on — the rule the phone's sheet keeps.
private struct LyricSheet: View {
    let state: WatchNowPlaying
    let sung: Int?
    let focus: Int
    let isSynced: Bool
    let isBrowsing: Bool
    let elapsed: TimeInterval
    @Environment(WatchModel.self) private var model

    static let font = Font.system(size: 21, weight: .bold)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(state.lyrics.indices, id: \.self) { index in
                line(index)
                    .alignmentGuide(index == focus ? .focusLine : .notFocus) { $0[VerticalAlignment.center] }
            }
        }
        .padding(.horizontal, 16)
        // As tall as it's given, never as tall as the song: the stack overflows the frame,
        // slid to the focus line, and the mask takes what spills.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
               alignment: Alignment(horizontal: .leading, vertical: .focusLine))
        .animation(.spring(duration: 0.5, bounce: 0.15), value: focus)
        .mask(edgeFade)
    }

    private func line(_ index: Int) -> some View {
        let lyric = state.lyrics[index]
        let distance = abs(index - focus)
        return Group {
            if lyric.text.isEmpty {
                Text("♪")
            } else if state.karaoke, isSynced, index == sung, !isBrowsing {
                karaoke(index)
            } else {
                Text(lyric.text)
            }
        }
        .font(Self.font)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(isSynced && distance > 0 ? 0.84 : 1, anchor: .leading)
        .blur(radius: blur(distance))
        .opacity(opacity(distance))
        .contentShape(Rectangle())
        .onTapGesture {
            if let time = lyric.time { model.send(.seek(time)) }
        }
        .accessibilityAddTraits(index == sung ? .isSelected : [])
    }

    private func opacity(_ distance: Int) -> Double {
        guard isSynced else { return distance == 0 ? 1 : 0.6 }
        switch distance {
        case 0: return 1
        case 1: return 0.3
        case 2: return 0.1
        default: return 0
        }
    }

    private func blur(_ distance: Int) -> CGFloat {
        guard isSynced else { return 0 }
        switch distance {
        case 0: return 0
        case 1: return 2.5
        default: return 5
        }
    }

    /// Each word lights as its turn comes, from a quarter to full in under a tenth of a
    /// second — the phone's karaoke, whose timing is spread over the line by word length.
    private func karaoke(_ index: Int) -> Text {
        let lyric = state.lyrics[index]
        let start = lyric.time ?? 0
        let end = state.lyrics[(index + 1)...].lazy.compactMap(\.time).first ?? start + 5
        let pieces = lyric.text.split(separator: " ", omittingEmptySubsequences: false)
        let weights = pieces.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        var at = start
        var text = Text("")
        for (offset, piece) in pieces.enumerated() {
            let word = offset == pieces.count - 1 ? String(piece) : String(piece) + " "
            let lit = min(1, max(0, (elapsed - at) / 0.09))
            text = text + Text(word).foregroundColor(.white.opacity(0.35 + 0.65 * lit))
            at += (end - start) * weights[offset] / max(total, 1)
        }
        return text
    }

    /// The top and bottom dissolve instead of cutting off, the phone's eased mask.
    private var edgeFade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.55), location: 0.1),
            .init(color: .black, location: 0.22),
            .init(color: .black, location: 0.8),
            .init(color: .black.opacity(0.55), location: 0.92),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

private extension VerticalAlignment {
    enum FocusLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    enum NotFocus: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let focusLine = VerticalAlignment(FocusLine.self)
    static let notFocus = VerticalAlignment(NotFocus.self)
}
