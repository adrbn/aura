import SwiftUI
import UIKit

// MARK: - Tab-root big title (in-content, scrolls away — exactly like Home)

/// Chrome for a tab root whose big title is placed as the FIRST scrolling row (via
/// `TabTitleRow`). Hides the native nav bar (no large-title gap), lets content scroll under
/// the status bar, and fades in a Liquid Glass strip at the very top on scroll — like Home.
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

    /// Height to reserve for the floating ConnectionBanner (0 when it's hidden).
    static var bannerInset: CGFloat { ConnectionBanner.isVisible ? 44 : 0 }

    /// What a tab root should pass to `contentMargins(.top:)`.
    static var contentTop: CGFloat { windowSafeTop + bannerInset }
}

struct TabRootGlass: ViewModifier {
    @Binding var scrollY: CGFloat

    private var safeTop: CGFloat { TabChrome.windowSafeTop }

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: .top)
            .contentMargins(.top, TabChrome.contentTop, for: .scrollContent)
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: safeTop + 26)
                    .glassEffect(.regular, in: Rectangle())
                    .mask(LinearGradient(colors: [Color.black, Color.black, Color.black.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(min(max(scrollY / 16, 0), 1))
                    .allowsHitTesting(false)
                    .ignoresSafeArea(.container, edges: .top)
            }
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
                .font(.custom("TuafTrial-Bold", size: 40, relativeTo: .largeTitle))
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.themeSecondaryBg, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}
