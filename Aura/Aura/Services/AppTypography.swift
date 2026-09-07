import SwiftUI

/// The display typeface — the aura wordmark, tab-root big titles, onboarding headlines
/// and section heads. Body copy always stays on the system font.
enum DisplayFont: String, Codable, CaseIterable, Identifiable {
    /// The app's typeface. Ours, SIL OFL 1.1 — the only face here that may ship.
    case vavinCondensed
    case vavinCondensedBold
    case system

    var id: String { rawValue }

    /// Decode unknown values to the app's own face instead of throwing.
    ///
    /// Settings are persisted as one JSON blob decoded with `try?`, so a face that
    /// no longer exists — Tuaf was a trial cut and was removed — would fail the
    /// whole decode and silently reset every other preference with it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DisplayFont(rawValue: raw) ?? .vavinCondensed
    }

    /// PostScript name of the embedded face; `nil` draws with a system font.
    ///
    var postScriptName: String? {
        switch self {
        case .system: return nil
        case .vavinCondensed: return "VavinCondensed-Regular"
        case .vavinCondensedBold: return "VavinCondensed-Bold"
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .vavinCondensed: return "Vavin Condensed"
        case .vavinCondensedBold: return "Vavin Condensed Bold"
        }
    }

    /// A face is offered only once its file is genuinely registered with the text system,
    /// so the picker can't advertise a choice that would silently render as the default.
    var isAvailable: Bool {
        guard let name = postScriptName else { return true }
        return PlatformFont(name: name, size: 12) != nil
    }

    /// Point-size multiplier so different faces read at the same visual size.
    ///
    /// Point size measures the em box, not the letters, so two faces at 40 pt can look
    /// nothing alike. The multipliers below were measured against a 0.714 em cap height
    /// 0.626 for ITC Garamond Light Condensed, whose 'n' is 444 units wide against
    /// an 809 unit ascender — nearly half. Matching cap heights alone would need ~1.14x; the extra
    /// allows for it being both condensed and Light, which reads lighter again.
    var opticalScale: CGFloat {
        switch self {
        case .system: return 1.0
        // Measured: cap height 0.649 em against that 0.714 asks ~1.10 on its own, and
        // Vavin Condensed is also half the width (n 418 vs 809), so it reads smaller again.
        // The Regular carries less ink than a Bold at the same size, hence the extra over
        // the Bold — the goal is equal presence, not equal cap height.
        case .vavinCondensed: return 1.30
        case .vavinCondensedBold: return 1.26
        }
    }

    /// Downward nudge as a fraction of the point size, to line the faces up vertically.
    ///
    /// Layout positions text from the ascender, and faces differ enormously: the baseline is
    /// 1.108 em with 0.394 of clear space above its capitals, a Garamond's is 0.703 em
    /// with only 0.077, so it sits noticeably higher in the same line box. Damped
    /// well below the raw 0.317 em difference — the goal is to look right, not to force
    /// two very different faces onto one baseline.
    var baselineNudge: CGFloat {
        switch self {
        case .system: return 0
        // Vavin inherits EB Garamond's vertical metrics — a shorter ascender than the baseline
        // 1.108 em — so it sits high in the same line box, though less markedly.
        case .vavinCondensed, .vavinCondensedBold: return 0.06
        }
    }

    /// Falls back when the stored face isn't bundled — font pulled, licence swapped,
    /// or an App Store build where the evaluation face is deliberately absent.
    var resolved: DisplayFont { isAvailable ? self : .vavinCondensed }

    /// What the picker lists. Every remaining face may ship: Vavin is ours under
    /// SIL OFL 1.1, and the system font needs no licence. The two evaluation faces
    /// that could not be distributed — a Tuaf trial and ITC Garamond, whose fsType
    /// is 4, "Preview & Print" — have been removed, so nothing needs excluding here.
    static var selectable: [DisplayFont] {
        allCases.filter(\.isAvailable)
    }
}

enum AppTypography {
    /// Read inside a `body` so SwiftUI's observation tracking re-renders every title
    /// when the face changes.
    private static var choice: DisplayFont { AppSettings.shared.displayFont.resolved }

    /// Display font for SwiftUI text. Named faces scale with Dynamic Type via
    /// `relativeTo:`; the system fallback is drawn at a fixed size, as a wordmark should be.
    static func display(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .largeTitle) -> Font {
        let face = choice
        let scaled = size * face.opticalScale
        guard let name = face.postScriptName, PlatformFont(name: name, size: scaled) != nil else {
            return .system(size: scaled, weight: .bold)
        }
        return .custom(name, size: scaled, relativeTo: textStyle)
    }

    /// Letter-spacing for a title drawn at `size`, in points.
    ///
    /// Tracking is size-specific or it is wrong somewhere: letters read as drifting apart
    /// the larger they get, so display sizes want to be pulled in, while body sizes want
    /// to be left alone. A single fixed value — or none at all, which is what this had —
    /// means the big titles sit loose and the face looks like a font that was chosen
    /// rather than a face that was set.
    ///
    /// Zero below 17pt, tightening steadily above it: about -0.6pt at a 40pt title.
    static func displayTracking(_ size: CGFloat) -> CGFloat {
        size <= 17 ? 0 : -(size - 17) * 0.025
    }

    /// Vertical correction for the current face, in points, for a title drawn at `size`.
    /// Apply as `.offset(y:)` where the face shares a row with other elements.
    static func displayBaselineOffset(_ size: CGFloat) -> CGFloat {
        size * choice.opticalScale * choice.baselineNudge
    }

    /// UIKit counterpart, for the navigation-bar appearance proxy. iOS only — the Mac app
    /// has no navigation bar to dress, and nothing else needs a concrete font object.
    #if canImport(UIKit)
    static func uiDisplay(_ size: CGFloat) -> UIFont {
        let face = choice
        let scaled = size * face.opticalScale
        guard let name = face.postScriptName, let font = UIFont(name: name, size: scaled) else {
            return .boldSystemFont(ofSize: scaled)
        }
        return font
    }
    #endif
}

extension View {
    /// Applies the display face **and** its per-face vertical correction together.
    ///
    /// These must travel as a pair. Applying only the font, separately, at each of the five
    /// tab titles is exactly how Home and Settings ended up sitting on a different line from
    /// Library and Playlists — four call sites, one of which had the offset. One modifier
    /// means a new title can't be added half-corrected.
    func auraDisplay(_ size: CGFloat, relativeTo textStyle: Font.TextStyle = .largeTitle) -> some View {
        let nudge = AppTypography.displayBaselineOffset(size)
        // Balanced padding, NOT `offset`. An offset is invisible to layout, so wherever the
        // container sizes itself from the text — Home's HStack with its chevron — the glyphs
        // moved but the box didn't, and each tab drifted by a different amount. Equal and
        // opposite padding shifts the text inside a box of unchanged total height, so every
        // title lands identically whatever it is nested in.
        return font(AppTypography.display(size, relativeTo: textStyle))
            .tracking(AppTypography.displayTracking(size))
            .padding(.top, nudge)
            .padding(.bottom, -nudge)
    }
}
