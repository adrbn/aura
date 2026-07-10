import SwiftUI

// MARK: - Buffered Progress Bar

struct BufferedProgressBar: View {
    let progress: Double
    let buffer: Double
    var accentColor: Color = .white
    let onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private let barHeight: CGFloat = 7
    private let thumbSize: CGFloat = 22
    private let thumbSizeDragging: CGFloat = 32
    var displayProgress: Double { isDragging ? dragValue : progress }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let currentThumb = isDragging ? thumbSizeDragging : thumbSize
            ZStack(alignment: .leading) {
                // Track background with glass effect
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(height: barHeight)
                // Buffer indicator
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(width: max(0, w * min(buffer, 1.0)), height: barHeight)
                    .animation(.linear(duration: 0.3), value: buffer)
                // Progress fill
                Capsule()
                    .fill(accentColor)
                    .frame(width: max(0, w * min(displayProgress, 1.0)), height: barHeight)
                // Thumb — Liquid Glass. Hidden at rest; only appears while the user is
                // actively scrubbing, so the bar reads as a clean line the rest of the time.
                Circle()
                    .fill(.clear)
                    .frame(width: currentThumb, height: currentThumb)
                    .glassEffect(.regular, in: .circle)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .overlay(
                        Circle().fill(accentColor.opacity(0.6))
                            .frame(width: currentThumb * 0.4, height: currentThumb * 0.4)
                    )
                    .offset(x: max(0, w * min(displayProgress, 1.0) - currentThumb / 2))
                    .opacity(isDragging ? 1 : 0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
            }
            .frame(height: max(barHeight, thumbSizeDragging))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragValue = max(0, min(1, value.location.x / w))
                    }
                    .onEnded { value in
                        let final = max(0, min(1, value.location.x / w))
                        onSeek(final)
                        isDragging = false
                    }
            )
        }
        .frame(height: thumbSizeDragging)
    }
}
