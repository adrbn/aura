import SwiftUI
import WidgetKit
import AppIntents

/// Home Screen widget: the song Aura is on, its cover, and (medium size) the transport.
/// The app writes the song to the App Group and reloads this widget at each change.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingSnapshot.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing in Aura.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
    let cover: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: nil, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> NowPlayingEntry {
        let cover = NowPlayingSnapshot.coverURL.flatMap { UIImage(contentsOfFile: $0.path) }
        return NowPlayingEntry(date: .now, snapshot: NowPlayingSnapshot.load(), cover: cover)
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemMedium {
                medium
            } else {
                small
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color.black
                if let cover = entry.cover {
                    Image(uiImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 30)
                        .opacity(0.6)
                }
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            coverView(size: 64)
            Spacer(minLength: 0)
            titles
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            coverView(size: 120)
            VStack(alignment: .leading, spacing: 10) {
                titles
                Spacer(minLength: 0)
                transport
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.snapshot?.title ?? String(localized: "Nothing playing"))
                .font(.subheadline.bold())
                .lineLimit(2)
            if let artist = entry.snapshot?.artist {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill").font(.title3)
            }
            Button(intent: PlayPauseIntent()) {
                Image(systemName: entry.snapshot?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill").font(.title3)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(entry.snapshot == nil)
    }

    @ViewBuilder
    private func coverView(size: CGFloat) -> some View {
        Group {
            if let cover = entry.cover {
                Image(uiImage: cover).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 80 ? 12 : 8))
    }
}
