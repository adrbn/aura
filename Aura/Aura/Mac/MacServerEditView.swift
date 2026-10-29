import SwiftUI

/// The phone's server details, as a sheet: the name, a home address used while it answers,
/// the custom headers, and a connection test.
struct MacServerEditView: View {
    let server: ServerConfig
    var onDone: () -> Void

    @State private var serverManager = ServerManager.shared
    @State private var name = ""
    @State private var localURL = ""
    @State private var headers = ""
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Server Info") {
                    TextField("Display Name", text: $name)
                    LabeledContent("URL") { Text(server.url).textSelection(.enabled) }
                    LabeledContent("Username") { Text(server.username).textSelection(.enabled) }
                }
                Section {
                    TextField("Home Address", text: $localURL, prompt: Text(verbatim: "http://192.168.1.10:4533"))
                } header: {
                    Text("Home Address")
                } footer: {
                    Text("Optional. While this address answers, on your home network, Aura uses it instead of the main one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField("Custom Headers", text: $headers, prompt: Text("Name: value, one per line"), axis: .vertical)
                        .lineLimit(1...6)
                        .font(.callout.monospaced())
                } header: {
                    Text("Custom Headers")
                } footer: {
                    Text("Optional. Sent with every request to this server, for a reverse proxy or a sign-in gateway in front of it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Connection") {
                    LabeledContent("Status") {
                        Text(serverManager.isConnected ? "Online" : "Offline")
                            .foregroundStyle(serverManager.isConnected ? .green : .red)
                    }
                    Button {
                        isTesting = true
                        Task { await serverManager.testConnection(); isTesting = false }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Test Connection")
                            if isTesting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isTesting || serverManager.currentServer?.id != server.id)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Changes") { save(); onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .onAppear {
            name = server.friendlyName
            localURL = server.localURL ?? ""
            headers = ServerHeaders.text(server.headers)
        }
    }

    /// As the phone saves: the list entry, and the current selection too when it is this
    /// server, so the new address and headers take effect without a relaunch.
    private func save() {
        guard let index = serverManager.servers.firstIndex(where: { $0.id == server.id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let local = Self.cleanLocalURL(localURL)
        let parsed = ServerHeaders.parse(headers)
        var updated = serverManager.servers[index]
        if !trimmedName.isEmpty { updated.friendlyName = trimmedName }
        updated.localURL = local
        updated.headers = parsed
        serverManager.servers[index] = updated
        serverManager.saveServers()
        if serverManager.currentServer?.id == server.id {
            serverManager.currentServer = updated
            serverManager.saveCurrentServer()
            Task { await serverManager.testConnection() }
        }
    }

    /// An http(s) address with a host, or nil to clear it; a bare host gets http://, as
    /// a home server rarely has a certificate. The phone's rule.
    private static func cleanLocalURL(_ text: String) -> String? {
        var url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "http://\(url)" }
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return url
    }
}
