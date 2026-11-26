import SwiftUI
import Intents

/// First launch: welcome, what Aura does, what iOS will ask, then the connection. Also the screen shown
/// whenever no server is set up (`startAtConnect`), so there is one way in, not two.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerManager.self) private var serverManager
    var startAtConnect = false
    var onComplete: () -> Void = {}

    @State private var currentPage = 0
    /// Set once the server answered: the "library found" screen shows its covers before the
    /// server is saved, so the app behind does not swap screens under it.
    @State private var connected: ServerConfig?

    // Server form fields (for final step)
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var friendlyName = ""
    @State private var isTesting = false
    @State private var isOpeningDemo = false
    @State private var serverError: String?
    @State private var demoError: String?
    @State private var showNoServer = false
    @State private var showPassword = false
    @State private var siriStatus = INPreferences.siriAuthorizationStatus()
    /// iOS never says whether the local network was allowed, only that it was asked.
    @AppStorage("localNetworkAsked") private var localNetworkAsked = false
    // Springs back with the same curve as the page turn when the finger lifts.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.5, dampingFraction: 1)))
    private var dragX: CGFloat = 0
    @FocusState private var focused: Field?

    private let totalPages = 4
    private var connectPage: Int { totalPages - 1 }

    private var formValid: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            if let connected {
                LibraryFoundView(server: connected) { finish(with: connected) }
                    .transition(.opacity)
            } else {
                pages.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: connected?.id)
        .onAppear { if startAtConnect { currentPage = connectPage } }
        .sheet(isPresented: $showNoServer) { noServerSheet }
        // Always dark, like the app's own ground. Pinned locally because this view is
        // presented as a fullScreenCover sibling of ContentView, so it does NOT inherit the
        // app-wide appearance setting — without this the keyboard/system chrome would go light.
        .preferredColorScheme(.dark)
    }

    private let pageAnimation = Animation.spring(response: 0.5, dampingFraction: 1)

    private func go(to page: Int) {
        focused = nil
        withAnimation(pageAnimation) { currentPage = page }
    }

    /// The buttons lead, and a horizontal swipe also turns the page.
    private var pages: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let pageX = -CGFloat(currentPage) * width + dragX
            ZStack(alignment: .topLeading) {
                // The wall belongs to the first page and leaves with it, sliding out to the left.
                CoverWall(active: currentPage == 0 && !showNoServer)
                    .ignoresSafeArea()
                    .offset(x: pageX)
                LinearGradient(colors: [Color(red: 1, green: 0.25, blue: 0.31).opacity(0.22), .clear],
                               startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
                    .opacity(currentPage == 0 ? 0 : 1)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        welcomePage.frame(width: width)
                        benefitsPage.frame(width: width)
                        permissionsPage.frame(width: width)
                        serverSetupPage.frame(width: width)
                    }
                    .offset(x: pageX)
                    .frame(width: width, alignment: .leading)
                    bottomControls
                }

            }
            .animation(pageAnimation, value: currentPage)
            .contentShape(Rectangle())
            .gesture(swipe(width: width))
        }
    }

    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragX) { value, state, _ in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                let atEdge = (dx > 0 && currentPage == 0) || (dx < 0 && currentPage == connectPage)
                state = atEdge ? dx / 4 : dx
            }
            .onEnded { value in
                let dx = value.predictedEndTranslation.width
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if dx < -width / 3, currentPage < connectPage { go(to: currentPage + 1) }
                else if dx > width / 3, currentPage > 0 { go(to: currentPage - 1) }
            }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            HStack(spacing: 10) {
                if let icon = UIImage(named: "AppIconLarge") ?? Bundle.main.icon {
                    Image(uiImage: icon).resizable().frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                }
                Text(verbatim: "Aura")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .combine)
            .padding(.bottom, 12)
            OnboardingTitle(key: "*Your* music, the streaming way")
            Text("Welcome to Aura, the app for your own Navidrome server.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }

    private var benefitsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let icon = UIImage(named: "AppIconLarge") ?? Bundle.main.icon {
                Image(uiImage: icon).resizable().frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                    .accessibilityHidden(true)
            }
            OnboardingTitle(key: "Everything a streaming app does")
                .padding(.top, 24)
            OnboardingTitle(key: "With the music *you* own.", size: 17, weight: .regular)
                .foregroundStyle(.white.opacity(0.64))
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 24) {
                benefit("music.note", "Music that finds you",
                        "Daily mixes, radio from any song, new releases from your artists, your Wrapped.")
                benefit("macbook.and.iphone", "Wherever you are",
                        "Offline downloads, CarPlay, Apple Watch, Mac and Apple TV. Synced lyrics.")
                benefit("lock.shield", "Yours, for good",
                        "Free, no subscription, no account, no tracking. Your music stays on your server.")
            }
            .padding(.top, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 72)
    }

    private func benefit(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color(red: 1, green: 0.25, blue: 0.31))
                .frame(width: 32, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Permissions

    /// What iOS will ask about, explained before it asks, each asked only when its button is
    /// tapped. Before the connection, because a server at home is what needs the local network.
    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingTitle(key: "Two things to *allow*")
                .padding(.top, 72)
            Text("iOS asks you about each one. Aura uses them for nothing else.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 16) {
                permission("wifi", "Local Network",
                           "To reach a server at home, and to play on your Mac or Apple TV.",
                           state: localNetworkAsked ? .asked : .ask) {
                    localNetworkAsked = true
                    RemoteLink.shared.start()
                }
                permission("waveform", "Siri",
                           "To ask for an artist, an album or a playlist out loud.",
                           state: siriStatus == .authorized ? .allowed
                                : siriStatus == .notDetermined ? .ask : .off) {
                    INPreferences.requestSiriAuthorization { status in
                        Task { @MainActor in withAnimation(.easeOut(duration: 0.25)) { siriStatus = status } }
                    }
                }
            }
            .padding(.top, 40)
            Text("You can change both later in the Settings app.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private enum PermissionState { case ask, asked, allowed, off }

    private var allowLabel: some View {
        Text("Allow")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Color.white, in: Capsule())
    }

    private func permission(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey,
                            state: PermissionState, request: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.25, blue: 0.31))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The slot keeps the button's width whatever it shows, so the text beside it
            // never re-wraps when the button turns into a tick.
            ZStack {
                allowLabel.hidden()
                switch state {
                case .ask:
                    Button(action: request) { allowLabel }
                        .buttonStyle(.plain)
                case .asked, .allowed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .accessibilityLabel(state == .allowed ? Text("Allowed") : Text("Asked"))
                case .off:
                    Text("Off")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: state)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Server Setup Page

    private enum Field: Hashable { case url, username, password, name }

    private var serverSetupPage: some View {
        // Scrolls, so the last field stays reachable once the keyboard and the Connect button
        // have taken the bottom half of the screen.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingTitle(key: "Connect *your* server")
                    .padding(.top, 72)
                Text("Add your Navidrome or Subsonic server.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.64))
                    .padding(.top, 8)

                // One grouped card, like Settings: four rows, hairlines between them.
                VStack(spacing: 0) {
                    formRow(icon: "link", field: .url) {
                        TextField("Server URL", text: $serverURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                    }
                    divider
                    formRow(icon: "person", field: .username) {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                    }
                    divider
                    formRow(icon: "lock", field: .password) {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(Text(showPassword ? "Hide password" : "Show password"))
                    }
                    divider
                    formRow(icon: "tag", field: .name) {
                        TextField("Friendly Name (optional)", text: $friendlyName)
                    }
                }
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.top, 32)

                Text("For example 192.168.1.20:4533, a Tailscale name or music.example.com")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if let err = serverError {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 24)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: serverError)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5).padding(.leading, 52)
    }

    private func formRow<Content: View>(icon: String, field: Field,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 52)
            content()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .tint(.white)
                .focused($focused, equals: field)
                .submitLabel(field == .name ? .go : .next)
                .onSubmit { submit(from: field) }
        }
        .frame(minHeight: 52)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture { focused = field }
    }

    private func submit(from field: Field) {
        switch field {
        case .url: focused = .username
        case .username: focused = .password
        case .password: focused = .name
        case .name:
            focused = nil
            if formValid && !isTesting { Task { await connectServer() } }
        }
    }

    // MARK: - No server

    private var noServerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingTitle(key: "No server yet?", size: 28)
                .padding(.bottom, 20)
            VStack(spacing: 8) {
                Button { Task { await tryDemo() } } label: {
                    optionRow(icon: "play.fill", title: "Try the Demo",
                              detail: "Listen to a sample library right now. Nothing to install.",
                              busy: isOpeningDemo)
                }
                .disabled(isOpeningDemo)
                Link(destination: URL(string: "https://www.navidrome.org/docs/installation/")!) {
                    optionRow(icon: "server.rack", title: "How to set up Navidrome",
                              detail: "Free and open source. Runs on a NAS, a Raspberry Pi or your computer.",
                              busy: false)
                }
            }
            .buttonStyle(.plain)
            if let err = demoError {
                Text(err).font(.footnote).foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                    .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(white: 0.1))
        .presentationCornerRadius(32)
    }

    private func optionRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, busy: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.25, blue: 0.31))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if busy { ProgressView().tint(.white) } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }

    private var bottomControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Capsule()
                        .fill(index == currentPage ? Color.white : Color.white.opacity(0.3))
                        .frame(width: index == currentPage ? 24 : 8, height: 8)
                }
            }
            .accessibilityHidden(true)

            let onConnect = currentPage == connectPage
            let enabled = !onConnect || (formValid && !isTesting)
            Button {
                if onConnect { Task { await connectServer() } } else { go(to: currentPage + 1) }
            } label: {
                ZStack {
                    if isTesting {
                        ProgressView().tint(.black)
                    } else {
                        Text(currentPage == 0 ? "Get Started" : onConnect ? "Connect" : "Continue")
                            .contentTransition(.opacity)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(enabled || isTesting ? Color.white : Color.white.opacity(0.2))
                .foregroundStyle(enabled ? .black : .white.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
            .disabled(!enabled)
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Group {
                if onConnect, let existing = serverManager.currentServer {
                    // Replaying the onboarding with a server already set up: keep it instead
                    // of retyping it.
                    Button {
                        onComplete()
                        dismiss()
                    } label: {
                        Text("Keep \(existing.friendlyName)")
                    }
                } else {
                    Button { demoError = nil; showNoServer = true } label: {
                        Text("I have no server")
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
            .frame(height: 32)
            .padding(.top, -8)
        }
        .padding(.bottom, 12)
    }

    /// Saves the server and opens the app on it, even when another one was already set up
    /// (Replay Welcome, or the demo tried from there).
    private func finish(with server: ServerConfig) {
        if let same = serverManager.servers.first(where: { $0.url == server.url && $0.username == server.username }) {
            serverManager.selectServer(same)
        } else {
            serverManager.addServer(server)
            serverManager.selectServer(server)
        }
        onComplete()
        dismiss()
    }

    /// The public Navidrome demo, so someone without a server of their own sees what Aura does.
    private func tryDemo() async {
        isOpeningDemo = true
        demoError = nil
        let demo = ServerConfig(url: "https://demo.navidrome.org", username: "demo",
                                password: "demo", friendlyName: "Navidrome Demo")
        if (try? await SubsonicClient.shared.ping(server: demo)) == true {
            // Through the same reveal as a server of one's own.
            showNoServer = false
            connected = demo
        } else {
            demoError = String(localized: "The demo server didn't answer. Try again in a moment.")
        }
        isOpeningDemo = false
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
        // Unnamed, a server is "Home", not an IP address nobody wants to read in the header.
        let name = typedName.isEmpty ? "Home" : typedName
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
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    connected = server
                    isTesting = false
                }
            } else {
                await MainActor.run {
                    serverError = String(localized: "Server rejected the connection — check your credentials")
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
                serverError = String(localized: "Connection failed: \(error.localizedDescription)")
                isTesting = false
            }
        }
    }

    private func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return String(localized: "No internet connection")
        case .cannotFindHost: return String(localized: "Server not found — check the address")
        case .cannotConnectToHost: return String(localized: "Cannot reach server — is it running?")
        case .timedOut: return String(localized: "Connection timed out — check the address")
        case .secureConnectionFailed: return String(localized: "SSL/TLS error — try http:// instead")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return String(localized: "Certificate not trusted — try http://")
        default: return String(localized: "Connection failed: \(error.localizedDescription)")
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
