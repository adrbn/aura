import SwiftUI

/// The window's permanent navigation, and where the server identity lives.
struct MacSidebar: View {
    @Binding var section: MacSection?
    @State private var serverManager = ServerManager.shared

    var body: some View {
        List(selection: $section) {
            Section {
                ForEach(MacSection.allCases) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            } header: {
                Text("Library")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        .safeAreaInset(edge: .top, spacing: 0) { wordmark }
        .safeAreaInset(edge: .bottom, spacing: 0) { serverStatus }
    }

    /// Sits in the space the hidden title bar frees up, so the window opens on the app's
    /// own name rather than on an empty chrome strip.
    private var wordmark: some View {
        HStack {
            Text("aura")
                .auraDisplay(30)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    private var serverStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(serverManager.isConnected ? Color.green : .orange)
                .frame(width: 7, height: 7)
            Text(serverManager.currentServer?.friendlyName ?? "No server")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
