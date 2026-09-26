import SwiftUI

// MARK: - Server Detail View

struct ServerDetailView: View {
    let server: ServerConfig
    @Environment(ServerManager.self) private var serverManager
    @State private var editedName: String = ""
    @State private var editedURL: String = ""
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
                        serverManager.servers[idx].friendlyName = editedName
                        serverManager.saveServers()
                        if serverManager.currentServer?.id == server.id {
                            serverManager.currentServer?.friendlyName = editedName
                            serverManager.saveCurrentServer()
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
        }
    }
}
