import SwiftUI
import UIKit

// MARK: - Tab-root big title (in-content, scrolls away — exactly like Home)

/// Chrome for a tab root whose big title is placed as the FIRST scrolling row (via
/// `TabTitleRow`). Hides the native nav bar (no large-title gap), lets content scroll under
/// the status bar, and fades in a `TopEdgeVeil` at the very top on scroll — like Home.
/// Because the title is part of the scroll content, content can never overlap it and any
/// trailing control (e.g. a `Menu`) lives in the real hierarchy, so it works normally.
/// Shared top-inset metrics for tab roots.
///
/// Tab roots deliberately opt OUT of the top safe area (`.ignoresSafeArea(.container,
/// edges: .top)`) so content dissolves under the glass strip, then re-add the space by
/// hand via `contentMargins`. A consequence that cost us two wrong fixes: a
/// `.safeAreaInset` for the ConnectionBanner — whether applied outside the TabView or
/// inside a tab — is simply ignored by these views. The banner floats as an overlay, so
/// tab roots must reserve its height HERE or it covers their big title.
///
/// Read these from a view body: they touch @Observable state, so the layout follows the
/// banner appearing/disappearing.
enum TabChrome {
    /// The window's own top safe area (status bar / island).
    static var windowSafeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top) ?? 59
    }

    /// The window's own bottom safe area (home indicator).
    static var windowSafeBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom) ?? 34
    }

    /// Height to reserve for the floating ConnectionBanner (0 when it's hidden).
    static var bannerInset: CGFloat { ConnectionBanner.isVisible ? 44 : 0 }

    /// What a tab root should pass to `contentMargins(.top:)`.
    static var contentTop: CGFloat { windowSafeTop + bannerInset }
}

/// The fetch card's room above the mini player, 0 while it's hidden. Pages ignore a bottom
/// inset set around the tabs just as they ignore a top one, so each list ends this much
/// higher by itself, through `ListEndSpacer`.
@MainActor
@Observable
final class BottomChrome {
    static let shared = BottomChrome()
    var cardInset: CGFloat = 0
}

/// The end of a page's list: room for the mini player, and for the fetch card while it shows.
struct ListEndSpacer: View {
    var height: CGFloat = 80

    var body: some View {
        Color.clear.frame(height: height + BottomChrome.shared.cardInset)
    }
}

extension View {
    /// The same room as `ListEndSpacer`, for a page that can't end on a row of its own — a
    /// `List(data)`, a grouped settings list, a scroll view of cards.
    func endsAboveBottomChrome(_ height: CGFloat = 80) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { ListEndSpacer(height: height) }
    }
}

/// What every pull-to-refresh in the app does, so the gesture means the same thing on
/// every screen: re-check the server, let stuck artwork try again, reload the content,
/// then confirm with a haptic.
///
/// Order matters. Re-pinging comes first because it's what restores `isConnected` and
/// leaves auto-offline mode; the artwork retry and the reload both depend on the app
/// believing it's online. And the artwork retry has to be explicit — covers that failed
/// on a bad link are never re-requested on their own, so this gesture is the user's way
/// of saying "try again" without relaunching.
@MainActor
func refreshTabContent(_ reload: () async -> Void) async {
    await ServerManager.shared.testConnection()
    ArtworkRetry.shared.requestRetry()
    await reload()
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
}

/// Where scrolled content meets the top of the screen, on every tab root.
///
/// A fade of the page's own colour rather than a band of Liquid Glass. The glass read as a
/// frosted slab laid across the top of the screen — an object with an edge — when all that
/// is wanted is for content to thin out before it reaches the clock. A gradient of the page
/// colour does exactly that: no material, no edge, and in light mode it fades to white
/// instead of tinting the top of the screen grey.
///
/// Dense at the very top, where the clock sits over whatever happens to be scrolling past,
/// and gone by the bottom. Invisible at rest, when nothing is under the status bar, and
/// faded in over the first few points of scroll.
///
/// One view for every tab root: Home and Search each used to carry their own copy of the
/// glass band.
struct TopEdgeVeil: View {
    let scrollY: CGFloat

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.themeBg.opacity(0.92), location: 0),
                .init(color: Color.themeBg.opacity(0.6), location: 0.5),
                .init(color: Color.themeBg.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: TabChrome.windowSafeTop + 34)
        .opacity(min(max(scrollY / 16, 0), 1))
        .allowsHitTesting(false)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The page's own colour, rising behind the tab bar and the mini player.
///
/// Both are Liquid Glass, but only the mini player is ours: the tab bar is the system's,
/// which reads the content under it lighter and takes no tint — iOS 26 ignores both the
/// appearance proxy and `toolbarBackground` on it. So the two bars looked like different
/// materials over a bright cover. Darkening what the tab bar sees is the one lever left,
/// and it makes the pair read as one: dense under the bars, gone above the mini player.
///
/// Eased, not linear: a straight ramp starts on a visible line, which over a white cover
/// reads as a grey band laid above the mini player. This one leaves the page at zero slope
/// well above the mini player, climbs mostly behind its glass, and levels off at the top
/// of the tab bar — no edge anywhere a cover can show it.
struct BottomEdgeVeil: View {
    /// Whether the mini player sits above the tab bar, and needs covering too.
    let coversMiniPlayer: Bool

    private static let density = 0.85
    /// The tab bar's top, above the home indicator.
    private static let tabBarHeight: CGFloat = 48
    /// The mini player's top, above the home indicator.
    private static let miniPlayerTop: CGFloat = 124
    /// How far above the highest bar the fade begins.
    private static let lead: CGFloat = 72
    private static let stopCount = 16

    var body: some View {
        let bottom = TabChrome.windowSafeBottom
        let height = bottom + (coversMiniPlayer ? Self.miniPlayerTop : Self.tabBarHeight) + Self.lead
        // Measured from the foot of the screen. Inside a tab the safe area ends at the top of
        // the tab bar, and a fixed-height view only aligns to that; filling the whole screen
        // first is what puts the fade where the bars actually are.
        Color.clear
            .overlay(alignment: .bottom) {
                LinearGradient(stops: Self.stops(height: height, rampEnd: height - bottom - Self.tabBarHeight),
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
            }
            .allowsHitTesting(false)
            // Keyboard included: it stays down behind the keyboard rather than riding up on it.
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: coversMiniPlayer)
    }

    /// Smoothstep, squared so the start is gentler still, from the top to `rampEnd`; flat below.
    private static func stops(height: CGFloat, rampEnd: CGFloat) -> [Gradient.Stop] {
        (0...stopCount).map { index in
            let location = CGFloat(index) / CGFloat(stopCount)
            let t = min(location * height / rampEnd, 1)
            let eased = t * t * (3 - 2 * t)
            return .init(color: Color.themeBg.opacity(density * eased * eased), location: location)
        }
    }
}

struct TabRootGlass: ViewModifier {
    @Binding var scrollY: CGFloat

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: .top)
            .contentMargins(.top, TabChrome.contentTop, for: .scrollContent)
            .overlay(alignment: .top) { TopEdgeVeil(scrollY: scrollY) }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
            .background(Color.themeBg)
            .toolbar(.hidden, for: .navigationBar)
    }
}

extension View {
    func tabRootGlass(scrollY: Binding<CGFloat>) -> some View { modifier(TabRootGlass(scrollY: scrollY)) }

    /// A `List` row with no insets, no separator and a clear background — for custom
    /// rows (titles, search fields, grids, footnotes) inside a tab-root `List`.
    func clearRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// The big, left-aligned title to drop in as the FIRST row of a tab root's List/ScrollView.
/// Being part of the scroll content, it scrolls away naturally (no overlap, no gap), and its
/// optional `trailing` control sits in the normal hierarchy so menus/buttons work.
struct TabTitleRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(title)
                .auraDisplay(40)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Reusable search field (for tabs with a custom big title)

/// A styled search box used where the native `.searchable` can't live (custom
/// headers hide the nav bar). Binds to a query string.
struct SearchFieldBar: View {
    @Binding var text: String
    var prompt: String = "Search"

    @Environment(\.appAccentColor) private var accentColor
    /// The whole box focuses the field, not just the glyphs in it — see `body`.
    @FocusState private var isFocused: Bool
    /// One height, typing or not. Sized by padding, the box grew by a third as soon as the
    /// Clear button — taller than a line of text — appeared with the first letter.
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 46

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused($isFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                // A word, not the 16pt system ⓧ. That glyph is a ~22pt target inside a
                // 44pt row — small enough to miss, and repeatedly — where a label reads
                // at a glance, translates with the rest of the UI and is twice as wide.
                // Clearing keeps the keyboard up: emptying the field is the start of the
                // next search, not the end of this one.
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Text("Clear")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accentColor)
                        .padding(.leading, 10)
                        // The box's full height is its target, without making the box taller.
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 12))
        // Only the text itself used to take a tap: the magnifier, the padding and every
        // gap between them were dead, so aiming at the box could leave the keyboard shut.
        // The whole box is one target, focused or not, and it clears 44pt tall.
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { isFocused = true }
        .padding(.horizontal, 16)
    }
}
