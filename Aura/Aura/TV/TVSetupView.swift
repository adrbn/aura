import SwiftUI

/// Connecting a server: address, username, password. The server is asked before it is saved,
/// so a wrong password keeps the form and says so.
struct TVSetupView: View {
    var onDone: (() -> Void)?

    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var failure: String?

    var body: some View {
        HStack(alignment: .center, spacing: 120) {
            VStack(alignment: .leading, spacing: 18) {
                Text("aura").auraDisplay(120)
                Text("Your library. Your server.\nNothing in between.")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Aura plays a Navidrome or Subsonic library you already host.")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 20)
            }
            .frame(maxWidth: 640, alignment: .leading)

            VStack(alignment: .leading, spacing: 28) {
                Text("Connect your server").font(.system(size: 44, weight: .bold))
                TextField("Server address", text: $url)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await connect() }
                } label: {
                    HStack(spacing: 14) {
                        if isTesting { ProgressView() }
                        Text(isTesting ? "Connecting…" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!canConnect || isTesting)
            }
            .frame(width: 760)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trimmed: String { url.trimmingCharacters(in: .whitespaces) }

    private var normalisedURL: String {
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
    }

    private var canConnect: Bool { !trimmed.isEmpty && !username.isEmpty && !password.isEmpty }

    private func connect() async {
        guard canConnect, !isTesting else { return }
        guard let host = URL(string: normalisedURL)?.host() else {
            failure = String(localized: "That address doesn't look right")
            return
        }
        isTesting = true
        failure = nil
        defer { isTesting = false }
        let candidate = ServerConfig(url: normalisedURL, username: username, password: password, friendlyName: host)
        do {
            guard try await SubsonicClient.shared.ping(server: candidate) else {
                failure = String(localized: "The server said no")
                return
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        let manager = ServerManager.shared
        manager.addServer(candidate)
        if manager.servers.count > 1 { manager.selectServer(candidate) }
        await manager.testConnection()
        LibraryIndex.shared.refreshIfNeeded()
        onDone?()
    }
}

/// Settings: which server, adding another, removing one.
struct TVSettingsView: View {
    @State private var manager = ServerManager.shared
    @State private var adding = false
    @AppStorage(TVHomeView.mixesPlacementKey) private var mixesPlacement = TVHomeView.MixesPlacement.first.rawValue

    var body: some View {
        List {
            Section("Servers") {
                ForEach(manager.servers) { server in
                    Button { manager.selectServer(server) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.friendlyName)
                                Text(server.url).font(.system(size: 22)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.id == manager.currentServer?.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.appAccent)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) { manager.removeServer(server) }
                    }
                }
                Button { adding = true } label: { Label("Add Server", systemImage: "plus") }
            }
            Section("Home") {
                Picker("Made For You", selection: $mixesPlacement) {
                    Text("First").tag(TVHomeView.MixesPlacement.first.rawValue)
                    Text("Last").tag(TVHomeView.MixesPlacement.last.rawValue)
                    Text("Off").tag(TVHomeView.MixesPlacement.off.rawValue)
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.shortVersion)
            }
        }
        .frame(maxWidth: 1100)
        .fullScreenCover(isPresented: $adding) {
            TVSetupView { adding = false }
                .background(TVBackground())
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }
}
