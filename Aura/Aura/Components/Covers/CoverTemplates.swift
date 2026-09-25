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

/// The seed artist in a large disc, two similar artists tucked behind it, on a field of the
/// seed photo's own colour.
struct RadioCoverTemplate: View {
    let lead: CoverPortrait?
    let left: CoverPortrait?
    let right: CoverPortrait?
    let name: String
    let field: UIColor
    let s: CGFloat

    var body: some View {
        let g = CoverGrid(s: s)
        let size = CoverMetrics.fit(name.uppercased(), CoverFont.title, width: g.column, maxCap: s * 0.13)
        let fieldColor = Color(uiColor: field)
        let ink = CoverPalette.ink(on: field)
        ZStack(alignment: .topLeading) {
            fieldColor
            ZStack {
                if let left { disc(left, s * 0.36).offset(x: -s * 0.27, y: s * 0.02).transition(.opacity) }
                if let right { disc(right, s * 0.36).offset(x: s * 0.27, y: s * 0.02).transition(.opacity) }
                if let lead { disc(lead, s * 0.52) }
            }
            .frame(width: s, height: s * 0.86)
            CoverLockup(label: String(localized: "Radio"), s: s, color: ink).padding(g.margin)
            CapText(text: name.uppercased(), font: CoverFont.title, size: size, color: ink)
                .padding(g.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(width: s, height: s)
        .clipped()
    }

    private func disc(_ p: CoverPortrait, _ d: CGFloat) -> some View {
        let box = CGSize(width: d, height: d)
        return FramedPortrait(image: p.image,
                              framing: CoverFraming(p, box: box, target: CGPoint(x: 0.5, y: 0.45), zoom: 1.45),
                              box: box)
            .clipShape(Circle())
            .padding(s * 0.012)
            .background(Circle().fill(Color(uiColor: field)))
    }
}
