import SwiftUI

/// The server, its state, and the way between servers — at the foot of the sidebar, where a
/// Mac app puts the account it is signed into.
struct MacServerPicker: View {
    @State private var serverManager = ServerManager.shared
    @State private var isRenaming = false
    @State private var isAdding = false
    @State private var draftName = ""

    var body: some View {
        Menu {
            if serverManager.servers.count > 1 {
                ForEach(serverManager.servers) { server in
                    Button {
                        serverManager.selectServer(server)
                        Task { await serverManager.testConnection() }
                    } label: {
                        Label(server.friendlyName,
                              systemImage: server.id == serverManager.currentServer?.id ? "checkmark" : "")
                    }
                }
                Divider()
            }
            Button("Rename…") {
                draftName = serverManager.currentServer?.friendlyName ?? ""
                isRenaming = true
            }
            Button("Add Server…") { isAdding = true }
            if serverManager.servers.count > 1, let current = serverManager.currentServer {
                Divider()
                Button("Remove \(current.friendlyName)", role: .destructive) {
                    serverManager.removeServer(current)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(serverManager.isConnected ? Color.green : .orange)
                    .frame(width: 7, height: 7)
                Text(serverManager.currentServer?.friendlyName ?? String(localized: "No server"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert("Rename server", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { rename() }
        } message: {
            Text("What this server is called in the sidebar.")
        }
        .sheet(isPresented: $isAdding) {
            MacServerSetupView { isAdding = false }
                .frame(width: 820, height: 520)
        }
    }

    /// `ServerConfig` is a value type, so renaming means replacing it — in the list, and as
    /// the current selection, or the sidebar would keep showing the old name until relaunch.
    private func rename() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, var server = serverManager.currentServer else { return }
        server.friendlyName = name
        if let index = serverManager.servers.firstIndex(where: { $0.id == server.id }) {
            serverManager.servers[index] = server
        }
        serverManager.currentServer = server
        serverManager.saveServers()
        serverManager.saveCurrentServer()
    }
}
