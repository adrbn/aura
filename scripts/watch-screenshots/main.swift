import AppKit
import SwiftUI

// Draws the watch app's pages side by side, at a 46 mm watch's size, into one PNG.
// Everything shown is made up: the song, its words, the queue.

let screen = CGSize(width: 208, height: 248)
let output = CommandLine.arguments.dropFirst().first ?? "aura-watch.png"

@MainActor
func cover() -> NSImage {
    let art = ZStack {
        LinearGradient(colors: [Color(red: 0.05, green: 0.35, blue: 0.45), Color(red: 0.55, green: 0.1, blue: 0.4)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        Circle().fill(Color(red: 1, green: 0.55, blue: 0.2).opacity(0.85)).frame(width: 90).offset(x: 30, y: -20)
        Text("NH").font(.system(size: 44, weight: .black)).foregroundStyle(.white.opacity(0.9))
            .offset(x: -40, y: 50)
    }
    .frame(width: 200, height: 200)
    let renderer = ImageRenderer(content: art)
    renderer.scale = 1
    return renderer.nsImage ?? NSImage()
}

let lyrics: [WatchNowPlaying.Line] = [
    .init(time: 12, text: "Streetlights hum a quiet tune"),
    .init(time: 17, text: "Every window holds a moon"),
    .init(time: 22, text: "I keep your signal on repeat"),
    .init(time: 27, text: "Static dancing under my feet"),
    .init(time: 33, text: "Midnight signals, calling low"),
    .init(time: 38, text: "Tell me where the night can go"),
    .init(time: 44, text: ""),
    .init(time: 48, text: "Harbour lights are fading out"),
]

let upNext: [WatchNowPlaying.Upcoming] = [
    .init(songId: "1", title: "Paper Lanterns", artist: "Neon Harbour", slot: 0, isQueued: true),
    .init(songId: "2", title: "Low Tide (Extended Mix)", artist: "Mira Vale", slot: 5, isQueued: false),
    .init(songId: "3", title: "Coastline", artist: "The Quiet Hours", slot: 6, isQueued: false),
    .init(songId: "4", title: "Glasshouse", artist: "Ada Lune", slot: 7, isQueued: false),
]

let playing = WatchNowPlaying(
    songId: "0", title: "Midnight Signals", artist: "Neon Harbour", artworkId: "c",
    isPlaying: true, position: 23, positionDate: Date(), duration: 214,
    isFavorite: true, canFavorite: true, lyrics: lyrics, upNext: upNext,
    accent: [0.98, 0.26, 0.4])

@MainActor
struct WatchScreen<Page: View>: View {
    let label: String
    let page: Int
    let model: WatchModel
    @ViewBuilder let content: Page

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                Color.black
                content
                    .safeAreaPadding(.top, 30)
                    .safeAreaPadding(.bottom, 14)
                    .environment(model)
                    .frame(width: screen.width, height: screen.height)
                HStack {
                    Spacer()
                    Text("10:09").font(compact(16, .semibold)).foregroundStyle(.white)
                }
                .padding(.top, 8)
                .padding(.trailing, 22)
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { dot in
                        Circle().fill(.white.opacity(dot == page ? 1 : 0.3)).frame(width: 6, height: 6)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
                .opacity(page < 0 ? 0 : 1)
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 51, style: .continuous).fill(Color(white: 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 51, style: .continuous).stroke(Color(white: 0.2), lineWidth: 1))
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.6))
        }
    }
}

MainActor.assumeIsolated {
    let art = cover()
    let live = WatchModel(state: playing, artwork: art)
    let idle = WatchModel(state: WatchNowPlaying(accent: playing.accent), artwork: nil)
    let sheet = HStack(alignment: .top, spacing: 28) {
        WatchScreen(label: "Now Playing", page: 0, model: live) { NowPlayingPage(isCurrent: true) }
        WatchScreen(label: "Lyrics", page: 1, model: live) { LyricsPage() }
        WatchScreen(label: "Up Next", page: 2, model: live) { UpNextPage() }
        WatchScreen(label: "Nothing playing", page: 0, model: idle) { NowPlayingPage(isCurrent: true) }
    }
    .buttonStyle(WatchButtonStyle())
    .padding(32)
    .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    .environment(\.colorScheme, .dark)

    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("Nothing rendered") }
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    try! png!.write(to: URL(fileURLWithPath: output))
    print(output)
}
