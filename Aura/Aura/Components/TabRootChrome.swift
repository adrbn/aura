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
/// The rhythm of a page that opens on its artwork and lists songs — album, playlist, mix,
/// radar release: the first song sits as far below the buttons as the closing line sits
/// below the last song.
enum DetailListLayout {
    static let gap: CGFloat = 12
}

/// The line that closes a page's list — "2026 · 9 songs · 40 min" — as the back of a record
/// sleeve does, `DetailListLayout.gap` below the last song.
///
/// A list row is at least 44 points tall and centres anything shorter, which let these
/// words drift down. Lowering the list's minimum row height fixed that but squashed every
/// song row on the page with it, so the list keeps its minimum and the words are pinned
/// to the top of their row instead.
struct ListSummaryRow: View {
    let text: String

    /// A plain list's default minimum row height.
    private static let listRowMinimum: CGFloat = 44

    /// "2024 · 12 songs · 48 min" — whichever of them is known. The same words close every
    /// list, online or not.
    static func text(year: Int? = nil, songs: [Song], seconds: Int? = nil) -> String {
        let length = seconds ?? songs.compactMap(\.duration).reduce(0, +)
        return [
            year.map(String.init),
            songs.count == 1 ? String(localized: "1 song") : String(localized: "\(songs.count) songs"),
            length > 0 ? Duration.seconds(max(length, 60))
                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, DetailListLayout.gap)
            .frame(maxWidth: .infinity, minHeight: Self.listRowMinimum, alignment: .topLeading)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

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
    /// How far below the status bar it reaches: the clock's height on a tab root, the
    /// navigation bar's on a pushed page.
    var depth: CGFloat = 34

    /// Down past the back button and the bar's title on a pushed page.
    static let barDepth: CGFloat = 70

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.themeBg.opacity(0.92), location: 0),
                .init(color: Color.themeBg.opacity(0.6), location: 0.5),
                .init(color: Color.themeBg.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: TabChrome.windowSafeTop + depth)
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
/// well above the highest bar, climbs mostly behind its glass, and levels off at the foot
/// of that bar — no edge anywhere a cover can show it.
///
/// The Get It card counts as a bar while it shows: it rises on top of the mini player, and
/// the fade rises with it, so its glass reads the same dark page as the mini player's.
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
        let card = BottomChrome.shared.cardInset
        let barsTop = (coversMiniPlayer ? Self.miniPlayerTop : Self.tabBarHeight) + card
        // The highest bar alone: the ramp has run its course by its foot, whatever sits below.
        let highestBar = card > 0 ? card : (coversMiniPlayer ? Self.miniPlayerTop - Self.tabBarHeight : 0)
        let height = bottom + barsTop + Self.lead
        // Measured from the foot of the screen. Inside a tab the safe area ends at the top of
        // the tab bar, and a fixed-height view only aligns to that; filling the whole screen
        // first is what puts the fade where the bars actually are.
        Color.clear
            .overlay(alignment: .bottom) {
                LinearGradient(stops: Self.stops(height: height, rampEnd: Self.lead + highestBar),
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
            }
            .allowsHitTesting(false)
            // Keyboard included: it stays down behind the keyboard rather than riding up on it.
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: coversMiniPlayer)
            .animation(.easeInOut(duration: 0.3), value: card)
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

// MARK: - Tab-root glow

/// The top of a tab root in colour, and alive.
///
/// Album, playlist and mix pages open in the light of their artwork (`TintedCanvas`); the
/// tab roots have no artwork of their own and opened on the bare canvas, which made the
/// app's front doors its dullest screens. This gives them the same wash — colour at the
/// top, gone into the page well before the middle of the screen — made of three
/// neighbouring hues that slowly trade places and breathe, so the page reads as lit
/// rather than switched off.
///
/// The hues follow the time of day (`DayHue`): violet in the small hours, rose at dawn,
/// amber through the morning, orange into a red sunset, magenta at dusk, back to violet.
/// They used to come from the cover playing, which could turn the front doors green or
/// brown on a song's say; the warm end was the one worth keeping, so the day keeps to it
/// and never passes through green. The colour moves with the clock, a few degrees an
/// hour, so nothing is ever seen changing.
///
/// Kept quiet on purpose: dark and only moderately saturated behind white text, a pale
/// wash in light mode, one slow swing every eighteen seconds, nothing that flashes. It
/// holds still under Reduce Motion, and stops drawing whenever nobody can see it — another
/// tab, a page pushed over it, Now Playing on top, or scrolled out of sight.
struct TabRootGlow: View {
    /// How far the page has scrolled from rest. The glow travels up with the content, as
    /// the title in front of it does, and leaves the top veil to darken whatever remains.
    let scrolled: CGFloat

    /// Behind the title, the search field and the first rows, and faded out well before the
    /// middle of the screen: about the depth of a playlist page's tint.
    static let height: CGFloat = 420
    /// Thirty frames a second. The motion is measured in seconds, so sixty would spend power
    /// on a difference nobody can see.
    private static let frameInterval = 1.0 / 30

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOnScreen = false

    private var player: AudioPlayer { AudioPlayer.shared }

    var body: some View {
        let paused = reduceMotion || !isOnScreen || player.isShowingNowPlaying || scrolled >= Self.height
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: paused)) { context in
            // Paused, the timeline hands back the moment it stopped; the hour is read afresh.
            let now = paused ? Date() : context.date
            GlowField(hue: DayHue.hue(at: now),
                      time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate,
                      isDark: scheme == .dark)
        }
        .frame(height: Self.height)
        .offset(y: -scrolled)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }
}

/// The ground of a tab root: the page colour, `TabRootGlow` over its top and, on Home, the
/// cutting mat over both, so the grid runs through the glow rather than being washed out.
struct TabRootCanvas: ViewModifier {
    let page: Color
    let grid: Bool
    /// How far the page has scrolled from rest, held between zero and the glow's height:
    /// pulling down leaves the glow where it is, and once it has scrolled out of sight
    /// further scrolling stops redrawing it.
    @State private var scrolled: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Offset plus inset, as the artist hero reads it, so rest is zero whatever top
            // margin the page keeps for the status bar, the banner or a pinned search field.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), TabRootGlow.height)
            } action: { _, distance in
                scrolled = distance
            }
            .background {
                ZStack(alignment: .top) {
                    page
                    TabRootGlow(scrolled: scrolled)
                    if grid { WorkshopGrid() }
                }
                .ignoresSafeArea()
            }
    }
}

struct TabRootGlass: ViewModifier {
    @Binding var scrollY: CGFloat
    /// The page under the glow: the canvas, or Settings' grouped grey.
    var page: Color = .themeBg

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: .top)
            .contentMargins(.top, TabChrome.contentTop, for: .scrollContent)
            .overlay(alignment: .top) { TopEdgeVeil(scrollY: scrollY) }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                scrollY = y
            }
            .tabRootCanvas(page)
            .toolbar(.hidden, for: .navigationBar)
    }
}

extension View {
    func tabRootGlass(scrollY: Binding<CGFloat>, page: Color = .themeBg) -> some View {
        modifier(TabRootGlass(scrollY: scrollY, page: page))
    }

    /// The page colour with the tab-root glow at its top, behind a tab root's scroll view.
    /// For tab roots that draw their own chrome instead of using `tabRootGlass`; the view
    /// it's applied to must not paint an opaque background of its own, or it hides the glow.
    func tabRootCanvas(_ page: Color = .themeBg, grid: Bool = false) -> some View {
        modifier(TabRootCanvas(page: page, grid: grid))
    }

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
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
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
    var prompt: LocalizedStringKey = "Search"

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
