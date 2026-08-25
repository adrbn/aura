import SwiftUI

/// What went wrong, in terms someone can act on.
///
/// A connection can fail in four quite different ways and the fix is different every time:
/// a host that isn't there, a certificate that isn't trusted, a password that's wrong, and
/// something that answered but isn't a Subsonic server at all. "Could not connect" covers
/// all four and helps with none.
enum SetupDiagnosis: Equatable {
    case badURL
    case unreachable(String)
    case tls(String)
    case credentials
    case notSubsonic
    case other(String)

    var symbol: String {
        switch self {
        case .badURL, .notSubsonic: return "questionmark.circle.fill"
        case .unreachable: return "wifi.exclamationmark"
        case .tls: return "lock.trianglebadge.exclamationmark.fill"
        case .credentials: return "person.crop.circle.badge.exclamationmark.fill"
        case .other: return "exclamationmark.triangle.fill"
        }
    }

    var headline: String {
        switch self {
        case .badURL: return "That address doesn't look right"
        case .unreachable: return "Couldn't reach the server"
        case .tls: return "The secure connection was refused"
        case .credentials: return "The server said no"
        case .notSubsonic: return "Something answered, but it isn't Subsonic"
        case .other: return "The connection failed"
        }
    }

    var detail: String {
        switch self {
        case .badURL:
            return "Give a host name or an IP, with or without https://."
        case .unreachable(let host):
            return "Nothing answered at \(host). Check the address and the port, and that you're on the right network or VPN."
        case .tls(let reason):
            return "\(reason) A self-signed certificate will do this — try http:// if the server is on your own network."
        case .credentials:
            return "The address is right and the server replied, but it rejected that username and password."
        case .notSubsonic:
            return "The address answered with something Aura couldn't read. It may be a different app, or a reverse proxy sitting in front of the wrong service."
        case .other(let message):
            return message
        }
    }
}

/// First run.
///
/// The Mac app is a separate application with its own defaults and its own keychain items,
/// so the server has to be named here even when the phone already knows it.
struct MacServerSetupView: View {
    private enum Field: Hashable { case url, username, password }

    @State private var serverManager = ServerManager.shared
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var diagnosis: SetupDiagnosis?
    @FocusState private var focus: Field?

    var body: some View {
        HStack(spacing: 0) {
            brand
            form
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = .url }
    }

    // MARK: Left — what this is

    private var brand: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("aura").auraDisplay(64)
            Text("Your library. Your server.\nNothing in between.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            Spacer()
            Text("Aura plays a Navidrome or Subsonic library you already host.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(34)
        .frame(width: 330)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                LinearGradient(
                    colors: [Color.appAccent.opacity(0.30), Color.appAccent.opacity(0.05), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // A single soft light source, so the panel has some depth rather than
                // reading as a flat coloured rectangle.
                RadialGradient(
                    colors: [Color.appAccent.opacity(0.22), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 420
                )
            }
            .background(Color.black.opacity(0.25))
            // Up under the traffic lights. The window hides its title bar, but the bar's
            // strip is still outside the safe area — leaving it uncovered put a black band
            // across the top of the panel.
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) { Divider() }
    }

    // MARK: Right — the form

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            Text("Connect your server").auraDisplay(30).padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 13) {
                field("Server address", $url, prompt: "music.example.com", field: .url)
                HStack(spacing: 12) {
                    field("Username", $username, prompt: "", field: .username)
                    field("Password", $password, prompt: "", field: .password, secure: true)
                }
            }

            if let diagnosis {
                banner(diagnosis).padding(.top, 16)
            }

            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 7) {
                    if isTesting { ProgressView().controlSize(.small) }
                    Text(isTesting ? "Connecting…" : "Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConnect || isTesting)
            .padding(.top, 20)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String,
                       field: Field, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Group {
                if secure {
                    SecureField("", text: text, prompt: Text(prompt))
                } else {
                    TextField("", text: text, prompt: Text(prompt))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focus == field ? Color.appAccent : .clear, lineWidth: 1.5)
            )
            .focused($focus, equals: field)
            .onSubmit(advance)
        }
    }

    private func banner(_ diagnosis: SetupDiagnosis) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: diagnosis.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(diagnosis.headline).font(.system(size: 12, weight: .semibold))
                Text(diagnosis.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.orange.opacity(0.30)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Behaviour

    private var trimmed: String { url.trimmingCharacters(in: .whitespaces) }

    /// The address as it will actually be dialled: a scheme if none was given, no trailing
    /// slash. `https` is assumed because a bare host on the open internet should be.
    private var normalisedURL: String {
        guard !trimmed.isEmpty else { return "" }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
    }

    /// The host, so an unnamed server still gets a label worth reading in the sidebar.
    private var derivedName: String {
        URL(string: normalisedURL)?.host() ?? ""
    }

    private var canConnect: Bool {
        !trimmed.isEmpty && !username.isEmpty && !password.isEmpty
    }

    private func advance() {
        switch focus {
        case .url: focus = .username
        case .username: focus = .password
        case .password: if canConnect { Task { await connect() } }
        default: focus = nil
        }
    }

    private func connect() async {
        guard canConnect, !isTesting else { return }
        isTesting = true
        withAnimation { diagnosis = nil }
        defer { isTesting = false }

        guard URL(string: normalisedURL)?.host() != nil else {
            withAnimation { diagnosis = .badURL }
            return
        }

        let candidate = ServerConfig(
            url: normalisedURL,
            username: username,
            password: password,
            friendlyName: derivedName.isEmpty ? "Server" : derivedName
        )

        // Probed BEFORE it is registered. Registering first flips the root view over to the
        // library, which tears this screen down — taking the typed fields and the error
        // message with it. That is why a wrong password used to blank the form and say
        // nothing at all.
        do {
            let ok = try await SubsonicClient.shared.ping(server: candidate)
            guard ok else {
                withAnimation { diagnosis = .credentials }
                focus = .password
                return
            }
        } catch {
            withAnimation { diagnosis = Self.classify(error, host: derivedName) }
            return
        }

        serverManager.addServer(candidate)
        await serverManager.testConnection()
    }

    private static func classify(_ error: Error, host: String) -> SetupDiagnosis {
        if error is DecodingError { return .notSubsonic }
        guard let urlError = error as? URLError else {
            return .other(error.localizedDescription)
        }
        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost, .timedOut,
             .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            return .unreachable(host.isEmpty ? "that address" : host)
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .tls(urlError.localizedDescription)
        case .cannotParseResponse, .badServerResponse:
            return .notSubsonic
        default:
            return .other(urlError.localizedDescription)
        }
    }
}
