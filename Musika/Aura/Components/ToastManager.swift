import SwiftUI

@Observable
final class ToastManager {
    static let shared = ToastManager()

    var currentToast: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    struct ToastMessage: Equatable {
        let text: String
        let icon: String
        let id = UUID()

        static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
            lhs.id == rhs.id
        }
    }

    func show(_ text: String, icon: String = "checkmark.circle.fill") {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentToast = ToastMessage(text: text, icon: icon)
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                currentToast = nil
            }
        }
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .padding(.top, 8)

                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }
}
