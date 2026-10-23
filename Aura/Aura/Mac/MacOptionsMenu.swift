import SwiftUI

/// The sidebar's gear: brings up the settings panel, Aura's own, rather than a long system menu.
struct MacOptionsMenu: View {
    var body: some View {
        Button { MacSettingsPanel.shared.isShown.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Settings")
    }
}
