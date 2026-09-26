import SwiftUI
import UIKit

// MARK: - About

struct AboutView: View {
    private var accent: Color { Color.appAccent }

    /// Single source of truth for outbound links — edit here when the repo goes public.
    private enum Links {
        static let github = URL(string: "https://github.com/adrbn")!
        static let privacy = URL(string: "https://adrbn.github.io/aura-site/privacy.html")!
    }

    /// "1.0 (1)" — marketing version + build, read live from the bundle (never hardcoded).
    private var versionString: String { SettingsView.appVersion }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                hero
                descriptionCard
                featureCard
                linksCard
                footer
            }
            .padding(.horizontal, 20)
            // Clear the floating mini-player + tab bar so the footer can scroll fully
            // into view and be read — otherwise the last line sits under the now-playing bar.
            .padding(.bottom, 150 + BottomChrome.shared.cardInset)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .navigationTitle("about")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 10) {
            // Use the loadable 1024px asset — NOT UIImage(named: "AppIcon"), which asserts
            // (crashes) when you try to instantiate the app-icon set directly. Mirrors Onboarding.
            if let icon = UIImage(named: "AppIconLarge") ?? Bundle.main.icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 23, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    // Soft accent halo — echoes the splash's aurora. As a *background* it
                    // glows behind the icon without inflating the layout box (the old ZStack
                    // was 150pt tall, leaving a dead gap under the icon). Keeps the icon
                    // tucked close to the wordmark below.
                    .background(
                        Circle()
                            .fill(accent.opacity(0.22))
                            .frame(width: 150, height: 150)
                            .blur(radius: 42)
                    )
                    .padding(.top, 24)
            }

            Text("aura")
                .font(AppTypography.display(44, relativeTo: .largeTitle))
                .foregroundStyle(.primary)

            Text("Your music. Your server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Tap to copy — makes it trivial to paste the exact build into a bug report.
            Button {
                UIPasteboard.general.string = "Aura \(versionString)"
                ToastManager.shared.show("Version copied", icon: "doc.on.doc")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.caption2)
                    Text("Version \(versionString)").font(.caption.weight(.medium))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    // MARK: Description

    private var descriptionCard: some View {
        card {
            Text("Aura is a native SwiftUI client for your own Navidrome or Subsonic library — an Apple Music-grade experience for the music you host yourself. No ads, no tracking, no cloud in between.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Features

    private var featureCard: some View {
        card(padding: 4) {
            VStack(spacing: 0) {
                featureRow(icon: "swift", title: "Native & fast",
                           subtitle: "Built entirely in SwiftUI for iOS 26.")
                rowDivider
                featureRow(icon: "externaldrive.connected.to.line.below", title: "Your server, your rules",
                           subtitle: "Streams straight from your Navidrome / Subsonic.")
                rowDivider
                featureRow(icon: "quote.bubble", title: "Synced lyrics",
                           subtitle: "Time-synced from your server, LRCLIB as backup.")
                rowDivider
                // CarPlay is implemented but NOT claimed here: it needs Apple's
                // `com.apple.developer.carplay-audio` entitlement, which hasn't been
                // granted, so the CarPlay scene is never created at runtime.
                featureRow(icon: "arrow.down.circle", title: "Offline downloads",
                           subtitle: "Keep your music for the road, no signal needed.")
            }
        }
    }

    // MARK: Links

    private var linksCard: some View {
        card(padding: 4) {
            VStack(spacing: 0) {
                linkRow(icon: "chevron.left.forwardslash.chevron.right",
                        title: "Source & updates", detail: "GitHub", url: Links.github)
                rowDivider
                linkRow(icon: "hand.raised.fill",
                        title: "Privacy Policy", detail: nil, url: Links.privacy)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 4) {
            Text("Crafted with care in Italy")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The OFL requires the licence to travel with the software. Vavin-OFL.txt ships
            // in the bundle; this is the visible acknowledgement that goes with it.
            Text("Typeset in Vavin — SIL Open Font License 1.1")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("© 2026 · Made for people who own their music")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: Building blocks

    private var rowDivider: some View {
        Divider()
            .overlay(Color.primary.opacity(0.06))
            .padding(.leading, 58)
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func linkRow(icon: String, title: String, detail: String?, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 14) {
                iconBadge(icon)
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconBadge(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(accent.opacity(0.15))
                .frame(width: 34, height: 34)
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
        }
    }

    private func card<Content: View>(padding: CGFloat = 18, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}
