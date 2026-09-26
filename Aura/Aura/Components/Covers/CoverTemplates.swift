import SwiftUI
import UIKit

// The editorial templates. Each is laid out for a side of `s` points, so the same cover is
// drawn crisp at 40 pt in a list and at 260 pt in a header. With no photo — while it loads,
// or on a server without artist pictures — each still draws a complete, typographic cover.

// MARK: - Mix

/// Full-bleed portrait framed on the face; the title on a band that bleeds off the left edge
/// and ends with the word; the artists on a black strip beneath it.
struct MixCoverTemplate: View {
    let portrait: CoverPortrait?
    let kicker: String
    let title: String
    let artists: [String]
    let band: UIColor
    let s: CGFloat

    private static let artistsSize: CGFloat = 0.032

    var body: some View {
        let g = CoverGrid(s: s)
        let size = CoverMetrics.fit(title.uppercased(), CoverFont.title, width: g.column, maxCap: s * 0.15)
        let box = CGSize(width: s, height: s)
        let bandColor = Color(uiColor: band)
        // Without a photo the band colour becomes the field, and the title band turns black.
        let fieldInk = CoverPalette.ink(on: band)
        ZStack(alignment: .topLeading) {
            if let portrait {
                FramedPortrait(image: portrait.image,
                               framing: CoverFraming(portrait, box: box, target: CGPoint(x: 0.5, y: 0.32),
                                                     zoom: 1.05),
                               box: box)
                CoverTopScrim(s: s)
            } else {
                bandColor
            }
            CoverLockup(label: kicker, s: s, color: portrait == nil ? fieldInk : .white,
                        mark: portrait == nil ? fieldInk : coverRed)
                .padding(g.margin)
            VStack(alignment: .leading, spacing: 0) {
                CapText(text: title.uppercased(), font: CoverFont.title, size: size,
                        color: portrait == nil ? bandColor : fieldInk)
                    .padding(.leading, g.margin).padding(.trailing, s * 0.035)
                    .padding(.vertical, s * 0.032)
                    .background(portrait == nil ? Color.black : bandColor)
                if let line = artistsLine(width: g.column - s * 0.04) {
                    CapText(text: line, font: CoverFont.label, size: s * Self.artistsSize,
                            color: .white, tracking: s * 0.002)
                        .padding(.horizontal, s * 0.02).padding(.vertical, s * 0.017)
                        .background(.black)
                        .padding(.leading, g.margin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, g.margin)
        }
        .frame(width: s, height: s)
        .clipped()
    }

    /// As many names as fit the column, most-played first.
    private func artistsLine(width: CGFloat) -> String? {
        let size = s * Self.artistsSize
        let tracking = s * 0.002
        for count in stride(from: min(3, artists.count), through: 1, by: -1) {
            let line = artists.prefix(count).joined(separator: " · ").uppercased()
            if CoverMetrics.width(line, CoverFont.label, size, tracking: tracking) <= width { return line }
        }
        return nil
    }
}

// MARK: - Genre

/// A portrait mapped to two colours; the genre stacked to fill the column, sitting on the
/// duotone's own shadow colour rather than on a busy chest.
struct GenreCoverTemplate: View {
    let portrait: CoverPortrait?
    /// `portrait.image` already mapped to `dark` → `light`.
    let duotone: UIImage?
    let words: [String]
    let kicker: String
    let dark: UIColor
    let light: UIColor
    /// Whether the duotone's top is bright — measured once when it is made, not per frame.
    var topIsLight = false
    let s: CGFloat

    var body: some View {
        let g = CoverGrid(s: s)
        let box = CGSize(width: s, height: s)
        let sizes = words.map {
            CoverMetrics.fit($0.uppercased(), CoverFont.title, width: g.column, maxCap: s * 0.3)
        }
        let darkColor = Color(uiColor: dark)
        let lightColor = Color(uiColor: light)
        ZStack(alignment: .topLeading) {
            darkColor
            if let portrait, let duotone {
                FramedPortrait(image: duotone,
                               framing: CoverFraming(portrait, box: box, target: CGPoint(x: 0.6, y: 0.36),
                                                     zoom: 1.1),
                               box: box)
                LinearGradient(stops: [.init(color: darkColor.opacity(0), location: 0.4),
                                       .init(color: darkColor, location: 0.85)],
                               startPoint: .top, endPoint: .bottom)
            }
            // Over a bright top the light colour vanishes; the shadow colour reads instead.
            let labelColor = topIsLight ? darkColor : lightColor
            CoverLockup(label: kicker, s: s, color: labelColor, mark: labelColor).padding(g.margin)
            VStack(alignment: .leading, spacing: s * 0.03) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                    CapText(text: word.uppercased(), font: CoverFont.title, size: sizes[i], color: lightColor)
                }
            }
            .padding(g.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: s, height: s)
        .clipped()
    }
}

// MARK: - Year

/// The period set huge, the artist cut out and standing in front of its lower half.
struct YearCoverTemplate: View {
    let portrait: CoverPortrait?
    let period: String
    let kicker: String
    let s: CGFloat

    static let colors: [Color] = [0xFF6B2C, 0xC2185B, 0x311B92].map { Color(uiColor: CoverPalette.ui($0)) }

    var body: some View {
        let g = CoverGrid(s: s)
        let text = period.uppercased()
        let size = CoverMetrics.fit(text, CoverFont.title, width: g.column, maxCap: s * 0.42)
        let cap = CoverMetrics(CoverFont.title, size).cap
        let top = g.margin + CoverLockup.height(s) + s * 0.035
        let box = CGSize(width: s, height: s)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: Self.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            CapText(text: text, font: CoverFont.title, size: size, color: .white)
                .padding(.leading, g.margin).padding(.top, top)
            if let portrait, let subject = portrait.subject {
                // The top of the head lands a little past the middle of the figures.
                let headTarget = (top + cap * 0.62) / s
                // Face-to-head distance is a share of the photo; the target is a share of the
                // box, and the photo is drawn taller than the box once scaled to fill it.
                let px = portrait.image.size
                let drawnHeight = px.height * max(s / max(1, px.width), s / max(1, px.height))
                let faceToHeadTop = ((portrait.face?.midY ?? 0.4) - portrait.headTop) * drawnHeight / s
                FramedPortrait(image: subject,
                               framing: CoverFraming(portrait, box: box,
                                                     target: CGPoint(x: 0.5, y: headTarget + faceToHeadTop),
                                                     maxTopGap: 0.5),
                               box: box)
            }
            CoverLockup(label: kicker, s: s, mark: .white).padding(g.margin)
        }
        .frame(width: s, height: s)
        .clipped()
    }
}

// MARK: - Radio

/// The seed artist in a large disc broadcasting rings, two similar artists riding the first
/// ring in the field's tone, on a field of the seed photo's own colour; the name in a black
/// band, the similar artists on a strip under it — the mixes' lockup. The rings travel while
/// the radio is still being put together, and every disc is drawn from the start, a tinted
/// stand-in until its photo is in.
struct RadioCoverTemplate: View {
    let lead: CoverPortrait?
    let left: CoverPortrait?
    let right: CoverPortrait?
    let name: String
    /// The similar artists, for the strip under the name.
    var artists: [String] = []
    let field: UIColor
    var isLoading = false
    let s: CGFloat

    /// The lead disc's centre, as fractions of the side; the rings spread from it.
    private static let hub = CGPoint(x: 0.5, y: 0.40)
    private static let leadSide: CGFloat = 0.62
    private static let sideSide: CGFloat = 0.36
    private static let ringGap: CGFloat = 0.12
    private static let artistsSize: CGFloat = 0.032
    /// Seconds for a ring to travel to the next one's place.
    private static let broadcast: TimeInterval = 2.4

    var body: some View {
        let g = CoverGrid(s: s)
        let size = CoverMetrics.fit(name.uppercased(), CoverFont.title, width: g.column - s * 0.035,
                                    maxCap: s * 0.14)
        let fieldColor = Color(uiColor: field)
        let ink = CoverPalette.ink(on: field)
        ZStack(alignment: .topLeading) {
            RadialGradient(stops: [.init(color: fieldColor, location: 0),
                                   .init(color: fieldColor, location: 0.42),
                                   .init(color: shade(field, toward: .black, 0.3), location: 1)],
                           center: UnitPoint(x: Self.hub.x, y: Self.hub.y), startRadius: 0, endRadius: s * 0.9)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isLoading)) { timeline in
                rings(ink, phase: isLoading ? phase(at: timeline.date) : 0)
            }
            ZStack {
                disc(left, Self.sideSide, tonal: true)
                    .position(x: s * 0.11, y: s * 0.49)
                disc(right, Self.sideSide, tonal: true)
                    .position(x: s * 0.88, y: s * 0.25)
                disc(lead, Self.leadSide, tonal: false)
                    .padding(s * 0.014)
                    .background(Circle().fill(fieldColor))
                    .position(x: s * Self.hub.x, y: s * Self.hub.y)
            }
            .frame(width: s, height: s)
            CoverLockup(label: String(localized: "Radio"), s: s, color: ink).padding(g.margin)
            VStack(alignment: .leading, spacing: 0) {
                CapText(text: name.uppercased(), font: CoverFont.title, size: size, color: fieldColor)
                    .padding(.leading, g.margin).padding(.trailing, s * 0.035)
                    .padding(.vertical, s * 0.032)
                    .background(Color.black)
                if let line = artistsLine(width: g.column - s * 0.04) {
                    CapText(text: line, font: CoverFont.label, size: s * Self.artistsSize,
                            color: .black, tracking: s * 0.002)
                        .padding(.horizontal, s * 0.02).padding(.vertical, s * 0.017)
                        .background(.white)
                        .padding(.leading, g.margin)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, g.margin)
            CoverGrain()
        }
        .frame(width: s, height: s)
        .compositingGroup()
        .clipped()
    }

    /// A photo in a circle — the similar artists in the field's tone, so three unrelated press
    /// shots read as one set and the seed stays in front — or its stand-in until it's in.
    @ViewBuilder
    private func disc(_ portrait: CoverPortrait?, _ side: CGFloat, tonal: Bool) -> some View {
        let d = s * side
        let box = CGSize(width: d, height: d)
        ZStack {
            Circle().fill(shade(field, toward: .black, 0.16))
            if let portrait {
                FramedPortrait(image: portrait.image,
                               framing: CoverFraming(portrait, box: box, target: CGPoint(x: 0.5, y: 0.45),
                                                     zoom: 1.45),
                               box: box)
                    .grayscale(tonal ? 1 : 0)
                    .contrast(tonal ? 1.15 : 1)
                    .colorMultiply(tonal ? shade(field, toward: .white, 0.45) : .white)
                    .clipShape(Circle())
                    .transition(.opacity)
            }
        }
        .frame(width: d, height: d)
        .shadow(color: .black.opacity(0.28), radius: s * 0.03, y: s * 0.012)
    }

    /// Circles around the lead disc, fading towards the edges. `phase` 0…1 moves each one to
    /// the next one's place, a new one coming out from under the disc.
    private func rings(_ ink: Color, phase: CGFloat) -> some View {
        Canvas { context, size in
            let hub = CGPoint(x: size.width * Self.hub.x, y: size.height * Self.hub.y)
            for index in -1..<5 {
                let r = s * (0.40 + (CGFloat(index) + phase) * Self.ringGap)
                guard r > s * Self.leadSide / 2 else { continue }
                let fade = min(1, max(0, (s * 0.95 - r) / (s * 0.25)))
                context.stroke(Path(ellipseIn: CGRect(x: hub.x - r, y: hub.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(ink.opacity(0.16 * fade)), lineWidth: max(0.5, s * 0.005))
            }
        }
        .frame(width: s, height: s)
    }

    private func phase(at date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.broadcast)
                / Self.broadcast)
    }

    private func shade(_ color: UIColor, toward target: UIColor, _ amount: CGFloat) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount)
    }

    /// As many names as fit the column.
    private func artistsLine(width: CGFloat) -> String? {
        let size = s * Self.artistsSize
        let tracking = s * 0.002
        for count in stride(from: min(2, artists.count), through: 1, by: -1) {
            let line = artists.prefix(count).joined(separator: " · ").uppercased()
            if CoverMetrics.width(line, CoverFont.label, size, tracking: tracking) <= width { return line }
        }
        return nil
    }
}
