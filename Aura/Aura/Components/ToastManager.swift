import SwiftUI

@Observable
final class ToastManager {
    static let shared = ToastManager()

    var currentToast: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    struct ToastMessage: Equatable {
        let text: String
        let icon: String
        /// A button at the toast's end, e.g. Undo; tapping it runs the handler and hides the toast.
        var action: (title: String, handler: () -> Void)? = nil
        let id = UUID()

        static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
            lhs.id == rhs.id
        }
    }

    func show(_ text: String, icon: String = "checkmark.circle.fill",
              duration: Double = 2.5, action: (title: String, handler: () -> Void)? = nil) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentToast = ToastMessage(text: text, icon: icon, action: action)
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                currentToast = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { currentToast = nil }
    }
}

struct ToastOverlay: View {
    @State private var toast = ToastManager.shared

    var body: some View {
        if let message = toast.currentToast {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: message.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                    Text(message.text)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let action = message.action {
                        Button {
                            action.handler()
                            toast.dismiss()
                        } label: {
                            Text(action.title)
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.appAccent)
                                .padding(.leading, 6)
                                .frame(minHeight: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .padding(.top, 8)

                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(message.action != nil)
        }
    }
}
