import SwiftUI

/// The window's permanent navigation, and where the server identity lives.
struct MacSidebar: View {
    @Binding var section: MacSection?
    @State private var serverManager = ServerManager.shared

    var body: some View {
        List(selection: $section) {
            ForEach([MacSection.home, .mixes]) { item in
                Label(item.label, systemImage: item.symbol).tag(item)
            }
            Section("Library") {
                ForEach([MacSection.songs, .playlists, .albums, .artists]) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        .safeAreaInset(edge: .top, spacing: 0) { wordmark }
        .safeAreaInset(edge: .bottom, spacing: 0) { MacServerPicker() }
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
}
