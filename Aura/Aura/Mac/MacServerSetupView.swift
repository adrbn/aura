import SwiftUI

/// First run. The Mac app is a separate application with its own defaults and its own
/// keychain items, so the server has to be named here even if the phone already knows it.
struct MacServerSetupView: View {
    @State private var serverManager = ServerManager.shared
    @State private var name = ""
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var failure: String?

    private var canConnect: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("aura").auraDisplay(52)
                Text("Point it at a Navidrome or Subsonic server you own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                TextField("Server URL", text: $url, prompt: Text("https://music.example.com"))
                TextField("Name", text: $name, prompt: Text("My server"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 360)

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 360)
            }

            Button(isTesting ? "Connecting…" : "Connect") { Task { await connect() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect || isTesting)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() async {
        isTesting = true
        failure = nil
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let server = ServerConfig(
            url: trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)",
            username: username,
            password: password,
            friendlyName: name.isEmpty ? "Server" : name
        )
        serverManager.addServer(server)
        await serverManager.testConnection()
        isTesting = false
        // A failed connection would otherwise leave a server the app can't use, and no way
        // back to this screen to correct the typo.
        if !serverManager.isConnected {
            failure = serverManager.connectionError ?? "Could not reach that server."
            serverManager.removeServer(server)
        }
    }
}
