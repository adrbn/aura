import SwiftUI
import UIKit

// MARK: - About

struct AboutView: View {
    private var accentColor: Color { Color.appAccent }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let icon = UIImage(named: "AppIcon") ?? Bundle.main.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .padding(.top, 40)
                }

                Text("Aura")
                    .font(.title.bold())

                Text("Version \(SettingsView.appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("About")
                        .font(.headline)

                    Text("Aura is a Navidrome/Subsonic music client built with SwiftUI. It aims to provide a native Apple Music-like experience for self-hosted music libraries.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Links")
                        .font(.headline)

                    Link(destination: URL(string: "https://github.com/adrbn")!) {
                        Label("View on GitHub", systemImage: "link")
                    }
                    .foregroundStyle(accentColor)
                }
                .padding()

                Spacer()
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("about")
        .navigationBarTitleDisplayMode(.inline)
    }
}
