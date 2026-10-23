import SwiftUI

/// The phone as a remote for Aura on a Mac on the same Wi-Fi.
struct MacRemoteView: View {
    @Environment(\.dismiss) private var dismiss
    private var link: RemoteLink { RemoteLink.shared }
    @State private var scrub: Double?
    @State private var volume: Double?

    var body: some View {
        NavigationStack {
            Group {
                if let state = link.state, link.connected != nil {
                    remote(state)
                } else if link.connected != nil {
                    ProgressView()
                } else if link.macs.isEmpty {
                    ContentUnavailableView("Looking for a Mac", systemImage: "macbook",
                                           description: Text("Open Aura on a Mac on the same Wi-Fi, signed into the same server."))
                } else {
                    List(link.macs, id: \.self) { mac in
                        Button { link.connect(to: mac) } label: {
                            Label(mac.displayName, systemImage: "macbook")
                        }
                    }
                }
            }
            .navigationTitle("Control Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if link.connected != nil {
                    ToolbarItem(placement: .primaryAction) { Button("Disconnect") { link.disconnect() } }
                }
            }
        }
        .onAppear { link.browse() }
        .onDisappear { link.stopBrowsing() }
    }

    private func remote(_ state: RemoteLink.State) -> some View {
        VStack(spacing: 20) {
            CoverArtImage(coverArt: state.coverArt, size: 260, cornerRadius: 12)
            VStack(spacing: 4) {
                Text(state.title ?? String(localized: "Nothing playing")).font(.title3.bold()).lineLimit(1)
                Text(state.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            Slider(value: Binding(get: { scrub ?? state.currentTime }, set: { scrub = $0 }),
                   in: 0...max(state.duration, 1)) { editing in
                if !editing, let scrub { link.send(.seek(scrub)); self.scrub = nil }
            }
            HStack(spacing: 44) {
                Button { link.send(.previous) } label: { Image(systemName: "backward.fill") }
                Button { link.send(.playPause) } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                }
                Button { link.send(.next) } label: { Image(systemName: "forward.fill") }
            }
            .font(.title)
            .foregroundStyle(.primary)
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: Binding(get: { volume ?? state.volume }, set: { volume = $0 })) { editing in
                    if !editing, let volume { link.send(.volume(volume)); self.volume = nil }
                }
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
