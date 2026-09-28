import SwiftUI

/// The artists taken off the radar, each one a tap from being followed again.
struct UnfollowedArtistsView: View {
    private var radar: RadarService { .shared }

    var body: some View {
        List {
            Section {
                ForEach(radar.unfollowed) { artist in
                    HStack {
                        Text(artist.name)
                        Spacer()
                        Button("Follow") { withAnimation { radar.follow(artist) } }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
            } footer: {
                Text("Their new releases come back to the radar at its next daily pass.")
            }
        }
        .navigationTitle("Unfollowed Artists")
        .navigationBarTitleDisplayMode(.inline)
    }
}
