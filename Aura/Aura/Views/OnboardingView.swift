import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerManager.self) private var serverManager
    var onComplete: () -> Void = {}

    @State private var currentPage = 0
    @State private var appeared = false

    // Server form fields (for final step)
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var friendlyName = ""
    @State private var isTesting = false
    @State private var serverError: String?

    private let totalPages = 5

    private var formValid: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    var body: some View {
        ZStack {
            // Aurora background — shifts colours per page
            auroraBackground
                .ignoresSafeArea()

            // Film grain overlay
            GrainOverlay(animated: true)
                .opacity(0.06)
                .blendMode(.overlay)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Content area
                TabView(selection: $currentPage) {
                    welcomePage.tag(0)
                    featurePage(
                        icon: "waveform.path",
                        title: "Stream Everything",
                        subtitle: "Your entire library at your fingertips.\nLossless or transcoded, your choice.",
                        detail: "FLAC · MP3 · AAC · OGG"
                    ).tag(1)
                    featurePage(
                        icon: "text.quote",
                        title: "Live Lyrics",
                        subtitle: "Time-synced lyrics scroll in real time.\nTap any line to jump to that moment.",
                        detail: "Powered by LRCLIB"
                    ).tag(2)
                    featurePage(
                        icon: "arrow.down.circle",
                        title: "Offline Mode",
                        subtitle: "Download songs, albums, or your entire library.\nListen anywhere without a connection.",
                        detail: "No limits"
                    ).tag(3)
                    serverSetupPage.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.4), value: currentPage)

                // Bottom controls
                bottomControls
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) { appeared = true }
        }
        // Hand-authored aurora background is always dark. Pinned locally because this view is
        // presented as a fullScreenCover sibling of ContentView, so it does NOT inherit the
        // app-wide appearance setting — without this the keyboard/system chrome would go light.
        .preferredColorScheme(.dark)
    }

    // MARK: - Aurora Background

    private var auroraBackground: some View {
        ZStack {
            Color.black

            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let colors = auroraColors(for: currentPage)

                ZStack {
                    // Primary blob
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [colors.0.opacity(0.7), colors.0.opacity(0.2), .clear],
                                center: .center, startRadius: 20, endRadius: 220
                            )
                        )
                        .frame(width: 440, height: 440)
                        .offset(
                            x: -80 + CGFloat(sin(t * 0.4)) * 30,
                            y: -200 + CGFloat(cos(t * 0.3)) * 25
                        )
                        .scaleEffect(appeared ? 1.15 + CGFloat(sin(t * 0.5)) * 0.05 : 0.6)

                    // Secondary blob
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [colors.1.opacity(0.5), colors.1.opacity(0.15), .clear],
                                center: .center, startRadius: 30, endRadius: 200
                            )
                        )
                        .frame(width: 380, height: 380)
                        .offset(
                            x: 100 + CGFloat(cos(t * 0.35)) * 25,
                            y: 50 + CGFloat(sin(t * 0.45)) * 30
                        )
                        .scaleEffect(appeared ? 1.1 + CGFloat(cos(t * 0.4)) * 0.05 : 0.6)

                    // Tertiary blob
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [colors.2.opacity(0.4), colors.2.opacity(0.1), .clear],
                                center: .center, startRadius: 10, endRadius: 180
                            )
                        )
                        .frame(width: 360, height: 360)
                        .offset(
                            x: -40 + CGFloat(sin(t * 0.5)) * 20,
                            y: 250 + CGFloat(cos(t * 0.35)) * 20
                        )
                        .scaleEffect(appeared ? 1.2 + CGFloat(sin(t * 0.3)) * 0.06 : 0.6)

                    // Highlight
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.15), .clear],
                                center: .center, startRadius: 10, endRadius: 150
                            )
                        )
                        .frame(width: 300, height: 300)
                        .offset(
                            x: CGFloat(cos(t * 0.6)) * 60,
                            y: -50 + CGFloat(sin(t * 0.4)) * 50
                        )
                        .scaleEffect(appeared ? 1.0 : 0.4)
                }
                .blur(radius: 65)
            }
            .animation(.easeInOut(duration: 1.5), value: currentPage)
        }
    }

    /// Returns three colours that shift based on the current page
    private func auroraColors(for page: Int) -> (Color, Color, Color) {
        switch page {
        case 0: // Welcome — the app icon's pink-red (AppIcon.icon uses p3 1.0/0.248/0.307)
            return (
                Color(red: 1.0, green: 0.25, blue: 0.31),
                Color(red: 0.82, green: 0.16, blue: 0.26),
                Color(red: 1.0, green: 0.45, blue: 0.48)
            )
        case 1: // Streaming — deep purple/blue
            return (
                Color(red: 0.5, green: 0.3, blue: 0.9),
                Color(red: 0.35, green: 0.2, blue: 0.75),
                Color(red: 0.6, green: 0.4, blue: 0.95)
            )
        case 2: // Lyrics — cyan/teal
            return (
                Color(red: 0.1, green: 0.7, blue: 0.8),
                Color(red: 0.15, green: 0.55, blue: 0.7),
                Color(red: 0.2, green: 0.8, blue: 0.75)
            )
        case 3: // Offline — green/emerald
            return (
                Color(red: 0.2, green: 0.75, blue: 0.4),
                Color(red: 0.15, green: 0.6, blue: 0.35),
                Color(red: 0.3, green: 0.8, blue: 0.5)
            )
        case 4: // Server setup — back to the icon's pink-red, bookending the flow
            return (
                Color(red: 1.0, green: 0.25, blue: 0.31),
                Color(red: 0.82, green: 0.16, blue: 0.26),
                Color(red: 1.0, green: 0.45, blue: 0.48)
            )
        default:
            return (.white, .white, .white)
        }
    }

    // MARK: - Welcome Page

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer()
            Spacer()

            // App icon. AppIconLarge is a 1024px copy of the icon's Default appearance:
            // the CFBundleIcons fallback only exposes AppIcon60x60 (120px), which upscales
            // to mush in this 100pt frame.
            if let icon = UIImage(named: "AppIconLarge") ?? UIImage(named: "AppIcon") ?? Bundle.main.icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            }

            Text("aura")
                .font(AppTypography.display(48, relativeTo: .largeTitle))
                .foregroundStyle(
                    // Echoes the icon itself: its pink triangle resolving into white glass.
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.38, blue: 0.44),
                            Color(red: 1.0, green: 0.25, blue: 0.31),
                            .white.opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Your music, everywhere.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            VStack(spacing: 8) {
                featurePill(icon: "antenna.radiowaves.left.and.right", text: "Navidrome & Subsonic")
                featurePill(icon: "waveform.path", text: "Lossless Streaming")
                featurePill(icon: "text.quote", text: "Live Synced Lyrics")
                featurePill(icon: "arrow.down.circle", text: "Offline Downloads")
                featurePill(icon: "dial.medium", text: "Smart Radio Mixes")
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private func featurePill(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Feature Page

    private func featurePage(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 0) {
            Spacer()

            // Large icon with glow
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.15))
                    .blur(radius: 12)
                    .scaleEffect(1.3)

                Image(systemName: icon)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 40)

            Text(title)
                .font(AppTypography.display(32, relativeTo: .title))
                .foregroundStyle(.white)
                .padding(.bottom, 12)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 16)

            Text(detail)
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.35))

            Spacer()
            Spacer()
        }
    }

    // MARK: - Server Setup Page

    private var serverSetupPage: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)

            Text("Connect")
                .font(AppTypography.display(32, relativeTo: .title))
                .foregroundStyle(.white)
                .padding(.bottom, 6)

            Text("Add your Navidrome server to get started.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)

            VStack(spacing: 14) {
                serverField(placeholder: "Server URL", text: $serverURL, icon: "link", keyboard: .URL)
                serverField(placeholder: "Username", text: $username, icon: "person", keyboard: .default)
                serverSecureField(placeholder: "Password", text: $password, icon: "lock")
                serverField(placeholder: "Friendly Name (optional)", text: $friendlyName, icon: "tag", keyboard: .default)
            }
            .padding(.horizontal, 32)

            if isTesting {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Connecting...")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 20)
            }

            if let err = serverError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
            }

            Spacer()
        }
    }

    private func serverField(placeholder: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .foregroundStyle(.white)
                .tint(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func serverSecureField(placeholder: String, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20)
            SecureField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .tint(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Page indicators — hidden on the final (form) page so they can't
            // collide with the fields when the keyboard pushes the controls up.
            if currentPage < totalPages - 1 {
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPage ? Color.white : Color.white.opacity(0.3))
                            .frame(width: index == currentPage ? 24 : 8, height: 8)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                    }
                }
                .padding(.bottom, 20)
            }

            // Main button
            if currentPage == totalPages - 1 {
                // Server setup page — connect button
                Button {
                    Task { await connectServer() }
                } label: {
                    Text("Connect")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(formValid && !isTesting ? Color.white : Color.white.opacity(0.2))
                        .foregroundStyle(formValid && !isTesting ? .black : .white.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!formValid || isTesting)
                .padding(.horizontal, 40)
            } else {
                Button {
                    withAnimation { currentPage += 1 }
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white.opacity(0.15))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 40)
            }

            // Skip
            if currentPage < totalPages - 1 {
                Button {
                    withAnimation { currentPage = totalPages - 1 }
                } label: {
                    Text("Skip to setup")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.bottom, 20)
            } else if let existing = serverManager.currentServer {
                // Replaying the onboarding with a server already set up: the form is empty,
                // so "Connect" is disabled and there was no way forward. Offer to keep what
                // is already configured instead of making the user retype it.
                Button {
                    onComplete()
                } label: {
                    Text("Keep \(existing.friendlyName)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.bottom, 20)
            } else {
                Color.clear.frame(height: 44)
            }
        }
    }

    // MARK: - Server Connection

    private func connectServer() async {
        isTesting = true
        serverError = nil

        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://\(url)"
        }
        let typedName = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typedName.isEmpty ? (URL(string: url)?.host ?? "My Server") : typedName
        let server = ServerConfig(url: url, username: username, password: password, friendlyName: name)

        do {
            let ok = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await SubsonicClient.shared.ping(server: server)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw URLError(.timedOut)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            if ok {
                await MainActor.run {
                    serverManager.addServer(server)
                    onComplete()
                    dismiss()
                }
            } else {
                await MainActor.run {
                    serverError = "Server rejected the connection — check your credentials"
                    isTesting = false
                }
            }
        } catch let urlError as URLError {
            await MainActor.run {
                serverError = friendlyMessage(for: urlError)
                isTesting = false
            }
        } catch {
            await MainActor.run {
                serverError = "Connection failed: \(error.localizedDescription)"
                isTesting = false
            }
        }
    }

    private func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "No internet connection"
        case .cannotFindHost: return "Server not found — check the address"
        case .cannotConnectToHost: return "Cannot reach server — is it running?"
        case .timedOut: return "Connection timed out — check the address"
        case .secureConnectionFailed: return "SSL/TLS error — try http:// instead"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "Certificate not trusted — try http://"
        default: return "Connection failed: \(error.localizedDescription)"
        }
    }
}

// Bundle.icon helper (also used by SettingsView)
extension Bundle {
    var icon: UIImage? {
        if let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last {
            return UIImage(named: last)
        }
        return nil
    }
}
