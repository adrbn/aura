import SwiftUI

/// A cutting mat under Home: a fine grid, every fifth line a little firmer — enough to give
/// the grey a surface, not enough to compete with the covers on it. Its cells fall on the
/// page's 16-point margin, so the lines run along the content's edges.
struct WorkshopGrid: View {
    var cell: CGFloat = 16
    var major = 5

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        Canvas { context, size in
            let hair = 1 / scale
            var fine = Path()
            var firm = Path()
            for (index, x) in stride(from: CGFloat(0), through: size.width, by: cell).enumerated() {
                // Half a pixel in, so a hairline lands on one row of pixels, not across two.
                let line = Path { path in
                    path.move(to: CGPoint(x: x + hair / 2, y: 0))
                    path.addLine(to: CGPoint(x: x + hair / 2, y: size.height))
                }
                if index % major == 0 { firm.addPath(line) } else { fine.addPath(line) }
            }
            for (index, y) in stride(from: CGFloat(0), through: size.height, by: cell).enumerated() {
                let line = Path { path in
                    path.move(to: CGPoint(x: 0, y: y + hair / 2))
                    path.addLine(to: CGPoint(x: size.width, y: y + hair / 2))
                }
                if index % major == 0 { firm.addPath(line) } else { fine.addPath(line) }
            }
            let ink: Color = scheme == .dark ? .white : .black
            context.stroke(fine, with: .color(ink.opacity(0.045)), lineWidth: hair)
            context.stroke(firm, with: .color(ink.opacity(0.085)), lineWidth: hair)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
