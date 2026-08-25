import SwiftUI

/// The window's ground: a mesh gradient, drifting slowly.
///
/// A mesh rather than a linear gradient because a linear one always reads as a *direction*,
/// and this should read as light in a room. The drift is deliberately slow and small — it is
/// meant to be noticed only when you look for it, not to compete with the artwork.
struct MacBackground: View {
    /// Twenty frames a second, not sixty. The motion is measured in tens of seconds, so the
    /// extra frames would cost real power to render a difference nobody can see.
    private let fps = 1.0 / 20.0

    var body: some View {
        TimelineView(.animation(minimumInterval: fps)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: points(at: t),
                colors: colors
            )
            .opacity(0.55)
            // Well past the point of resolving any structure: the mesh is a colour field,
            // and the blur is what stops its control points reading as blobs.
            .blur(radius: 70)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    /// Only the four interior-ish points move, and only by a few percent. The corners are
    /// pinned, or the field would visibly slide rather than breathe.
    private func points(at t: TimeInterval) -> [SIMD2<Float>] {
        func drift(_ base: Float, _ phase: Double, _ amount: Float = 0.05) -> Float {
            base + amount * Float(sin(t / 11 + phase))
        }
        return [
            .init(0, 0), .init(0.5, 0), .init(1, 0),
            .init(0, drift(0.5, 0.0)), .init(drift(0.5, 1.7), drift(0.5, 3.1)), .init(1, drift(0.5, 4.4)),
            .init(0, 1), .init(0.5, 1), .init(1, 1),
        ]
    }

    /// Anchored to the app's accent, so the ground shifts with the theme rather than being a
    /// second, competing colour scheme. Kept very dark: this sits under text.
    private var colors: [Color] {
        let accent = Color.appAccent
        return [
            .black, accent.opacity(0.30), .black,
            accent.opacity(0.16), .black, accent.opacity(0.22),
            .black, accent.opacity(0.12), .black,
        ]
    }
}
