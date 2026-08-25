import SwiftUI

/// How big the artwork is drawn, everywhere it is drawn in a grid or a shelf.
enum MacCoverSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Grids are adaptive rather than a fixed column count, so a size is a *range*: the
    /// window decides how many fit, and this decides how big they may get. A window is
    /// resizable, and pinning the columns would either waste an ultrawide or crush a
    /// half-screen split.
    var gridMinimum: CGFloat {
        switch self {
        case .small: return 112
        case .medium: return 148
        case .large: return 208
        }
    }

    var gridMaximum: CGFloat {
        switch self {
        case .small: return 150
        case .medium: return 210
        case .large: return 290
        }
    }

    /// Shelves scroll horizontally, so their cards take one exact width.
    var shelfWidth: CGFloat {
        switch self {
        case .small: return 128
        case .medium: return 164
        case .large: return 212
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .small: return "1"
        case .medium: return "2"
        case .large: return "3"
        }
    }
}

/// Mac-only preferences.
///
/// Kept out of `AppSettings` on purpose: that model is shared with iOS and carries a hand-
/// written `Codable` mirror, so every field added to it has to be threaded through four
/// places. Nothing here has any meaning on a phone.
@MainActor
@Observable
final class MacPreferences {
    static let shared = MacPreferences()

    var coverSize: MacCoverSize {
        didSet { UserDefaults.standard.set(coverSize.rawValue, forKey: Self.coverSizeKey) }
    }

    private static let coverSizeKey = "aura_mac_cover_size"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.coverSizeKey)
        coverSize = stored.flatMap(MacCoverSize.init(rawValue:)) ?? .large
    }
}
