import AppKit
import SwiftUI

// Draws the watch app's pages side by side, at a 46 mm watch's size, into one PNG.
// Everything shown is made up: the song, its words, the queue.

let screen = CGSize(width: 208, height: 248)
let output = CommandLine.arguments.dropFirst().first ?? "aura-watch.png"
let root = CommandLine.arguments.dropFirst(2).first ?? "."

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
    accent: [0.98, 0.26, 0.4], karaoke: true)

/// Where the clock sits: to the right, or in the middle when the trailing corner holds a button.
enum Clock { case trailing, center }

/// One watch face-on, drawn as the system frames an app: the navigation container's backdrop
/// under everything, the page, the clock, and — on a pushed page — the back button.
@MainActor
struct WatchScreen<Page: View>: View {
    let label: String
    let model: WatchModel
    var clock = Clock.trailing
    var pushed = false
    var dimmed = false
    @ViewBuilder let content: Page

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                Color.black
                Backdrop()
                content
                    // The clock's band; the foot has none, content runs to the edge.
                    .safeAreaPadding(.top, pushed ? 44 : 40)
                    .frame(width: screen.width, height: screen.height)
                Text("10:09")
                    .font(compact(16, .semibold))
                    .foregroundStyle(.white.opacity(dimmed ? 0.7 : 1))
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: clock == .center ? .center : .trailing)
                    .padding(.top, 15)
                if clock == .center {
                    // The volume, a top trailing toolbar item, beside the clock.
                    CompanionVolume(tint: model.accent, isFocused: true)
                        .frame(width: 30, height: 30)
                        .opacity(dimmed ? 0.5 : 1)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 9)
                }
                if pushed {
                    Image(systemName: "chevron.left")
                        .font(compact(15, .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .harnessGlass(in: Circle())
                        .padding(.leading, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 9)
                }
            }
            .environment(model)
            .environment(\.isLuminanceReduced, dimmed)
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
    registerVavin(root: root)
    let art = cover()
    // What the phone measures for this cover: a mid-dark one, lightly veiled.
    let tone = WatchTone(veil: 0.3, vibrant: nil)
    let live = WatchModel(state: playing, artwork: art, tone: tone)
    var pausedState = playing
    pausedState.isPlaying = false
    let paused = WatchModel(state: pausedState, artwork: art, tone: tone)
    let idle = WatchModel(state: WatchNowPlaying(accent: playing.accent), artwork: nil)
    let sheet = VStack(alignment: .leading, spacing: 28) {
        HStack(alignment: .top, spacing: 28) {
            WatchScreen(label: "Now Playing", model: live, clock: .center) { NowPlayingPage() }
            WatchScreen(label: "Lyrics (karaoke)", model: live) { NowPlayingPage(showsLyrics: true) }
            WatchScreen(label: "Up Next (pushed)", model: live, pushed: true) { UpNextPage() }
        }
        HStack(alignment: .top, spacing: 28) {
            WatchScreen(label: "Paused", model: paused, clock: .center) { NowPlayingPage() }
            WatchScreen(label: "Always On", model: live, clock: .center, dimmed: true) { NowPlayingPage() }
            WatchScreen(label: "Nothing playing", model: idle) { NowPlayingPage() }
        }
    }
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
