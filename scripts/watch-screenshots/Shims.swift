import AppKit
import SwiftUI

// Stand-ins that let the watch app's own pages compile and draw on a Mac. Only what the Mac
// lacks is replaced: WatchConnectivity (the model), UIKit's image, the Crown's volume control,
// and the look watchOS gives a List and a Button. The pages themselves are the real files.

typealias UIImage = NSImage

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

/// SF Compact, the watch's typeface, at the watch's sizes: the pages' text styles are
/// rewritten to this before compiling (see watch-screenshots.sh). It's a private system face,
/// so it's read from its file and given its weight on the variable font's axis.
func compact(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
    let axis = 0x7767_6874 // 'wght'
    let value: Double = switch weight {
    case .medium: 510
    case .semibold: 590
    case .bold: 700
    default: 400
    }
    guard let face = compactFace else { return .system(size: size, weight: .init(weight)) }
    let weighted = CTFontDescriptorCreateCopyWithAttributes(
        face, [kCTFontVariationAttribute: [axis: value]] as CFDictionary)
    return Font(CTFontCreateWithFontDescriptor(weighted, size, nil))
}

private let compactFace: CTFontDescriptor? = {
    let url = URL(fileURLWithPath: "/System/Library/Fonts/SFCompact.ttf") as CFURL
    return (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor])?.first
}()

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        self = switch weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
}

@MainActor
@Observable
final class WatchModel {
    var state: WatchNowPlaying?
    var artwork: NSImage?
    var isReachable = true
    var tone = WatchTone()
    var songDirection = 1
    var path: [WatchRoute] = []
    var shelf: WatchShelf?
    var listings: [WatchItem: WatchListing] = [:]
    var searches: [String: WatchSearchResults] = [:]
    var covers: [String: NSImage] = [:]

    init(state: WatchNowPlaying?, artwork: NSImage?, tone: WatchTone = WatchTone()) {
        self.state = state
        self.artwork = artwork
        self.tone = tone
    }

    func play(_ item: WatchItem, index: Int = 0, shuffled: Bool = false) {}
    func loadShelf() async -> Bool { true }
    func open(_ item: WatchItem) async -> Bool { true }
    func search(_ query: String) async -> Bool { true }
    func wantCover(_ id: String) {}

    var accent: Color {
        let rgb = state?.accent ?? [1, 1, 1]
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    func send(_ command: WatchCommand) {}
    func refresh() {}
}

/// Vavin, the phone's display face, read from the repo as the watch reads it from its bundle.
func registerVavin(root: String) {
    let url = URL(fileURLWithPath: root + "/Aura/Aura/VavinCondensed-Bold-Latin.ttf") as CFURL
    CTFontManagerRegisterFontsForURL(url, .process, nil)
}

// The watch-only calls the pages make (AuraWatch/WatchChrome.swift), drawn as a watch draws them.

extension View {
    /// The watch lays it as the navigation container's background; the screen frame in
    /// main.swift draws it.
    func screenBackdrop() -> some View { self }

    /// Liquid Glass doesn't draw off-screen: a pale disc with a bright rim stands in.
    func harnessGlass<S: Shape>(in shape: S) -> some View {
        background(shape.fill(.white.opacity(0.14)))
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
    }

    /// A toolbar item, drawn by the screen frame in main.swift beside the clock.
    func volumeCorner(_ shown: Bool, tint: Color) -> some View { self }

    /// Also a toolbar item, drawn by the screen frame.
    func libraryCorner(_ shown: Bool, open: @escaping () -> Void) -> some View { self }

    func primaryAction() -> some View { self }

    func lyricCrown(_ line: Binding<Double>, lines: Int,
                    turned: @escaping (Double) -> Void, idle: @escaping () -> Void) -> some View { self }
}

/// A prominent glass button: a capsule in the tint — the sample accent, as SwiftUI keeps
/// the tint to itself.
struct HarnessProminent: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color(red: 0.98, green: 0.26, blue: 0.4)))
    }
}

/// A glass button: a capsule of pale glass.
struct HarnessGlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .padding(.horizontal, 12)
            .harnessGlass(in: Capsule())
    }
}

/// The search field as the watch draws it, empty: its prompt in a glass capsule.
struct SearchField: View {
    let submit: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(compact(14, .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("Search")
                .font(compact(15))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .harnessGlass(in: Capsule())
    }
}

/// A lazy stack draws nothing off screen; the Mac draws it whole.
struct LazyVStack<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) { content }
    }
}

/// The Crown's volume control as watchOS draws it: a speaker in a thin ring.
struct CompanionVolume: View {
    let tint: Color
    let isFocused: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.6).rotation(.degrees(-90))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Image(systemName: "speaker.wave.2.fill").font(compact(11)).foregroundStyle(.white)
        }
        .padding(3)
    }
}

/// A scroll view shown at its top, as a page is when it opens.
struct ScrollView<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        // Runs on under the display's foot, as a watch's scroll view does.
        Color.clear.overlay(alignment: .top) {
            content.fixedSize(horizontal: false, vertical: true)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
