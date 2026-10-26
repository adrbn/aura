import SwiftUI

// MARK: - Server Detail View

struct ServerDetailView: View {
    let server: ServerConfig
    @Environment(ServerManager.self) private var serverManager
    @State private var editedName: String = ""
    @State private var editedURL: String = ""
    @State private var editedLocalURL: String = ""
    @State private var editedHeaders: String = ""
    private var accentColor: Color { Color.appAccent }

    var body: some View {
        List {
            Section("Server Info") {
                HStack {
                    Text("Display Name")
                    Spacer()
                    TextField("Name", text: $editedName)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("URL")
                    Spacer()
                    Text(server.url).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Text("Username")
                    Spacer()
                    Text(server.username).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section {
                TextField("http://192.168.1.10:4533", text: $editedLocalURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("Home Address")
            } footer: {
                Text("Optional. While this address answers, on your home network, Aura uses it instead of the main one.")
            }

            Section {
                TextField("Name: value, one per line", text: $editedHeaders, axis: .vertical)
                    .lineLimit(1...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
            } header: {
                Text("Custom Headers")
            } footer: {
                Text("Optional. Sent with every request to this server, for a reverse proxy or a sign-in gateway in front of it.")
            }

            Section("Connection") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(serverManager.isConnected ? "Online" : "Offline")
                        .foregroundStyle(serverManager.isConnected ? .green : .red)
                }

                Button("Test Connection") {
                    Task { await serverManager.testConnection() }
                }
                .foregroundStyle(accentColor)
            }

            Section {
                Button("Save Changes") {
                    if let idx = serverManager.servers.firstIndex(where: { $0.id == server.id }) {
                        let local = Self.cleanLocalURL(editedLocalURL)
                        let headers = ServerHeaders.parse(editedHeaders)
                        serverManager.servers[idx].friendlyName = editedName
                        serverManager.servers[idx].localURL = local
                        serverManager.servers[idx].headers = headers
                        serverManager.saveServers()
                        if serverManager.currentServer?.id == server.id {
                            serverManager.currentServer?.friendlyName = editedName
                            serverManager.currentServer?.localURL = local
                            serverManager.currentServer?.headers = headers
                            serverManager.saveCurrentServer()
                            Task { await serverManager.testConnection() }
                        }
                    }
                }
                .foregroundStyle(accentColor)
            }
        }
        .endsAboveBottomChrome()
        .scrollIndicators(.hidden)
        .navigationTitle("server details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editedName = server.friendlyName
            editedURL = server.url
            editedLocalURL = server.localURL ?? ""
            editedHeaders = ServerHeaders.text(server.headers)
        }
    }

    /// An http(s) address with a host, or nil to clear it; a bare host gets http://, as
    /// a home server rarely has a certificate.
    private static func cleanLocalURL(_ text: String) -> String? {
        var url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "http://\(url)" }
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return url
    }
}
