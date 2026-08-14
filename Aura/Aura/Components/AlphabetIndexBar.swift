import SwiftUI
import UIKit

/// Contacts-style fast-scroll rail pinned to the trailing edge of a long list.
/// Tap a letter or drag along the rail to jump; the host resolves the title to a row
/// and scrolls. Deliberately *not* a scrollbar: the rail is an index over the list's
/// sort key, so it only makes sense while that key is alphabetical.
///
/// The host owns the scrolling because only it knows how its rows are keyed and how
/// many are currently materialised — a paginated list has to widen its window before
/// the target row exists to scroll to.
struct AlphabetIndexBar: View {
    let titles: [String]
    var tint: Color = .accentColor
    let onSelect: (String) -> Void

    @State private var active: String?

    /// Tuned so a full A–Z plus "#" rail stays under ~380 pt — it still fits beside the
    /// list on the shortest supported screen without needing to scroll the rail itself.
    private let rowHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(active == title ? tint : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
            }
        }
        .frame(width: 18)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { select(atY: $0.location.y) }
                .onEnded { _ in active = nil }
        )
        .padding(.vertical, 8)
        .background {
            // Only materialises while in use, so the rail is a bare column of letters at rest.
            if active != nil {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
            }
        }
        .animation(.easeOut(duration: 0.15), value: active != nil)
        .overlay(alignment: .leading) {
            if let active {
                Text(active)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(tint))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .offset(x: -64)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Fast scroll index")
    }

    private func select(atY y: CGFloat) {
        guard !titles.isEmpty else { return }
        let raw = Int(y / rowHeight)
        let index = min(max(raw, 0), titles.count - 1)
        let title = titles[index]
        guard title != active else { return }
        active = title
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect(title)
    }
}

// MARK: - Index keys

enum AlphabetIndex {
    /// The rail bucket a string falls into: an unaccented A–Z initial, or "#" for
    /// digits, symbols and non-Latin scripts. Accents fold so "Étienne" files under E
    /// rather than being exiled to "#".
    static func key(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                     locale: Locale(identifier: "en_US"))
        guard let first = folded.uppercased().first, first.isLetter, first.isASCII else { return "#" }
        return String(first)
    }

    /// The rail for a set of values: "#" first (matching how `localizedCompare` sorts
    /// digits and symbols ahead of letters), then only the letters actually present —
    /// a rail full of dead letters is worse than a short accurate one.
    static func titles(for values: [String]) -> [String] {
        let present = Set(values.map(key(for:)))
        let letters = (65...90).compactMap { UnicodeScalar($0).map { String(Character($0)) } }
        return (present.contains("#") ? ["#"] : []) + letters.filter { present.contains($0) }
    }
}
