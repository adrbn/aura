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
        guard let name = choice.postScriptName, UIFont(name: name, size: size) != nil else {
            return .system(size: size, weight: .bold)
        }
        return .custom(name, size: size, relativeTo: textStyle)
    }

    /// UIKit counterpart, for the navigation-bar appearance proxy.
    static func uiDisplay(_ size: CGFloat) -> UIFont {
        guard let name = choice.postScriptName, let font = UIFont(name: name, size: size) else {
            return .boldSystemFont(ofSize: size)
        }
        return font
    }
}
