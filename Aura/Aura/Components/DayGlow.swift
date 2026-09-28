import SwiftUI

/// The glow's base hue for a moment of the day, on the local clock. Shared with the watch,
/// whose idle screen wears the same glow as the phone's tab roots.
///
/// Anchored at a few hours and eased between them the short way round the wheel. All of it
/// sits between violet and amber, through red: with the glow's swing of forty degrees
/// either side, the warmest hour still stops short of yellow-green.
enum DayHue {
    /// (hour, hue as a fraction of the wheel). Hues past 1 are the reds and pinks just
    /// before it wraps, so neighbours differ by less than half a turn.
    private static let anchors: [(hour: Double, hue: Double)] = [
        (0, 0.74),     // violet
        (5, 0.80),     // purple before dawn
        (7, 0.96),     // rose
        (10, 1.06),    // amber
        (14, 1.04),    // orange
        (18, 1.01),    // red sunset
        (20.5, 0.93),  // magenta dusk
        (23, 0.78),    // violet
        (24, 0.74),
    ]

    static func hue(at date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        guard let after = anchors.firstIndex(where: { $0.hour > hour }), after > 0 else { return anchors[0].hue }
        let (from, to) = (anchors[after - 1], anchors[after])
        let t = (hour - from.hour) / (to.hour - from.hour)
        let eased = t * t * (3 - 2 * t)
        let hue = from.hue + (to.hue - from.hue) * eased
        return hue - hue.rounded(.down)
    }
}

/// One frame of the glow: a 3×3 mesh whose top row carries the colour, whose middle row
/// carries about half of it and whose bottom row none, so it fades into the page the way a
/// playlist page's tint does — but as a field of hues rather than a single one.
struct GlowField: View {
    let hue: Double
    let time: TimeInterval
    let isDark: Bool

    /// One full swing of the hues, in seconds.
    private static let cycle = 18.0
    /// How far each hue swings either side of the base: about forty degrees, enough to read
    /// as three colours without leaving the base's family.
    private static let spread = 0.11

    var body: some View {
        MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }

    private func wave(_ period: Double, _ phase: Double) -> Double {
        sin(time * 2 * .pi / period + phase)
    }

    /// Corners and edges stay pinned, or the field would slide rather than breathe; the top
    /// edge's middle and the whole middle row wander, each on its own clock, so the glow
    /// never settles into a loop you can see.
    private var points: [SIMD2<Float>] {
        func point(_ x: Double, _ y: Double) -> SIMD2<Float> { SIMD2(Float(x), Float(y)) }
        return [
            point(0, 0), point(0.5 + 0.18 * wave(17, 0), 0), point(1, 0),
            point(0, 0.42 + 0.08 * wave(13, 1.1)),
            point(0.5 + 0.15 * wave(19, 2.3), 0.5 + 0.07 * wave(11, 0.6)),
            point(1, 0.42 + 0.08 * wave(15, 3.9)),
            point(0, 1), point(0.5, 1), point(1, 1),
        ]
    }

    /// The middle row runs half a swing behind the top, so the colours cross over one
    /// another on their way down instead of pouring straight down in bands.
    private var colors: [Color] {
        let top = (0..<3).map { tone(slot: Double($0), strength: 1) }
        let middle = (0..<3).map { tone(slot: Double($0) + 1.5, strength: 0.5) }
        let bottom = (0..<3).map { tone(slot: Double($0) + 1.5, strength: 0) }
        return top + middle + bottom
    }

    /// A point's colour now. Every point swings around the base on the same slow clock, each
    /// a third of a turn behind its neighbour, so the hues travel across the field rather
    /// than pulsing in place; brightness breathes a little on a clock of its own.
    private func tone(slot: Double, strength: Double) -> Color {
        let turned = hue + Self.spread * sin(time * 2 * .pi / Self.cycle + slot * 2 * .pi / 3)
        let unit = turned - turned.rounded(.down)
        let breath = 0.045 * wave(11 + slot, slot * 2.1)
        // Dark and still coloured behind white text, as a page tint is; a pale wash in light.
        return isDark
            ? Color(hue: unit, saturation: 0.6, brightness: 0.42 + breath, opacity: strength * 0.95)
            : Color(hue: unit, saturation: 0.26, brightness: 0.98, opacity: strength * (0.85 + breath))
    }
}
