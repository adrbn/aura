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

    init(state: WatchNowPlaying?, artwork: NSImage?) {
        self.state = state
        self.artwork = artwork
    }

    var accent: Color {
        let rgb = state?.accent ?? [1, 1, 1]
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    func send(_ command: WatchCommand) {}
    func refresh() {}
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

/// watchOS draws a List as a column of rounded platters; the Mac's would be a table.
struct List<Data: RandomAccessCollection, RowContent: View>: View where Data.Element: Identifiable {
    let data: Data
    let row: (Data.Element) -> RowContent

    init(_ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) {
        self.data = data
        self.row = rowContent
    }

    var body: some View {
        // Laid over the page rather than inside it: rows past the bottom are cut off, as
        // they wait below the fold, instead of squeezing the page taller than the screen.
        Color.clear.overlay(alignment: .top) {
            VStack(spacing: 5) {
                ForEach(data) { row($0).buttonStyle(WatchRowStyle()) }
            }
        }
        .clipped()
    }
}

/// A scroll view shown at its top, as a page is when it opens.
struct ScrollView<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        Color.clear.overlay(alignment: .top) {
            content.fixedSize(horizontal: false, vertical: true)
        }
        .clipped()
    }
}

struct WatchRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.16)))
    }
}

/// A bordered watch button: a full-width capsule in the tint.
struct WatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact(17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color(white: 0.2)))
    }
}
