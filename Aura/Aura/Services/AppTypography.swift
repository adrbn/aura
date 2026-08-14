import SwiftUI
import UIKit

/// The display typeface — the aura wordmark, tab-root big titles, onboarding headlines
/// and section heads. Body copy always stays on the system font.
enum DisplayFont: String, Codable, CaseIterable, Identifiable {
    case tuaf
    case system
    /// LOCAL EVALUATION ONLY — see the licensing note on `postScriptName`.
    case garamond

    var id: String { rawValue }

    /// PostScript name of the embedded face; `nil` draws with a system font.
    ///
    /// The licensed Tuaf ships under a different PostScript name than the trial (no
    /// "Trial" suffix), and the name lives in the font's own `name` table — renaming the
    /// file changes nothing. When the licensed `.otf` lands, update this one string.
    var postScriptName: String? {
        switch self {
        case .tuaf: return "TuafTrial-Bold"
        case .system: return nil
        case .garamond: return "ITCGaramondStd-LtCond"
        }
    }

    var label: String {
        switch self {
        case .tuaf: return "Tuaf"
        case .system: return "System"
        case .garamond: return "ITC Garamond"
        }
    }

    /// A face is offered only once its file is genuinely registered with the text system,
    /// so the picker can't advertise a choice that would silently render as the default.
    var isAvailable: Bool {
        guard let name = postScriptName else { return true }
        return UIFont(name: name, size: 12) != nil
    }

    /// Point-size multiplier so different faces read at the same visual size.
    ///
    /// Point size measures the em box, not the letters, so two faces at 40 pt can look
    /// nothing alike. Measured from the files: cap height is 0.714 em for Tuaf against
    /// 0.626 for ITC Garamond Light Condensed, and Garamond's 'n' is 444 units wide against
    /// Tuaf's 809 — nearly half. Matching cap heights alone would need ~1.14x; the extra
    /// allows for it being both condensed and Light, which reads lighter again.
    var opticalScale: CGFloat {
        switch self {
        case .tuaf, .system: return 1.0
        case .garamond: return 1.22
        }
    }

    /// Downward nudge as a fraction of the point size, to line the faces up vertically.
    ///
    /// Layout positions text from the ascender, and the two differ enormously: Tuaf's is
    /// 1.108 em with 0.394 of clear space above its capitals, Garamond's is 0.703 em with
    /// only 0.077. Garamond therefore sits noticeably higher in the same line box. Damped
    /// well below the raw 0.317 em difference — the goal is to look right, not to force
    /// two very different faces onto one baseline.
    var baselineNudge: CGFloat {
        switch self {
        case .tuaf, .system: return 0
        case .garamond: return 0.09
        }
    }

    /// Falls back when the stored face isn't bundled — font pulled, licence swapped,
    /// or an App Store build where the evaluation face is deliberately absent.
    var resolved: DisplayFont { isAvailable ? self : .tuaf }

    /// What the picker lists.
    ///
    /// ITC Garamond is excluded from App Store builds in code as well as in the build
    /// phase. Its `fsType` is 4 — "Preview & Print" — which does NOT permit embedding in
    /// an application; it is here purely so the look can be judged on-device before
    /// committing to a licensed face. Do not ship it.
    static var selectable: [DisplayFont] {
        allCases.filter { face in
            #if APPSTORE_BUILD
            if face == .garamond { return false }
            #endif
            return face.isAvailable
        }
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
        guard let name = face.postScriptName, UIFont(name: name, size: scaled) != nil else {
            return .system(size: scaled, weight: .bold)
        }
        return .custom(name, size: scaled, relativeTo: textStyle)
    }

    /// Vertical correction for the current face, in points, for a title drawn at `size`.
    /// Apply as `.offset(y:)` where the face shares a row with other elements.
    static func displayBaselineOffset(_ size: CGFloat) -> CGFloat {
        size * choice.opticalScale * choice.baselineNudge
    }

    /// UIKit counterpart, for the navigation-bar appearance proxy.
    static func uiDisplay(_ size: CGFloat) -> UIFont {
        let face = choice
        let scaled = size * face.opticalScale
        guard let name = face.postScriptName, let font = UIFont(name: name, size: scaled) else {
            return .boldSystemFont(ofSize: scaled)
        }
        return font
    }
}
