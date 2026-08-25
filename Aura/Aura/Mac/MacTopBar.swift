import SwiftUI

/// Search and options, drawn as content rather than as a toolbar.
///
/// A real `NSToolbar` always paints its own backdrop — a translucent grey strip that no
/// amount of `toolbarBackground(.hidden:)` fully removes once it holds controls. Since the
/// whole point is a window with one surface from top to bottom, the controls live in the
/// content instead, and the window keeps nothing of its own.
struct MacTopBar: View {
    @Binding var query: String
    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text("Search your library"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(searching ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(searching ? Color.appAccent.opacity(0.7) : .clear)
            )
            .frame(maxWidth: 360)

            Spacer(minLength: 0)
            MacOptionsMenu()
        }
        .padding(.horizontal, 22)
        // Clears the traffic lights, which the hidden title bar leaves floating over the
        // content.
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}
