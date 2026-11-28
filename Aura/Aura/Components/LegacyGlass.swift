import SwiftUI

/// iOS 26 glass has no exact iOS 18 counterpart. These helpers keep the call sites in one
/// shape: on iOS 26 (and on the other 26 platforms) they use the real effect; on iOS 18 they
/// fall back to a translucent material with a hairline edge, so the same chrome still reads as
/// a floating surface.
extension View {
    @ViewBuilder
    func auraGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            glass(in: shape, tint: tint, interactive: interactive)
        } else {
            legacyGlass(in: shape, tint: tint)
        }
        #else
        glass(in: shape, tint: tint, interactive: interactive)
        #endif
    }

    /// The iOS 26 glass button style, with a plain material-backed button on iOS 18.
    /// `padding` is only applied to the fallback, where the system style no longer supplies it.
    @ViewBuilder
    func auraGlassButton<S: Shape>(
        in shape: S,
        padding: EdgeInsets = EdgeInsets()
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.plain)
                .padding(padding)
                .background {
                    shape.fill(.ultraThinMaterial)
                    shape.stroke(.white.opacity(0.16), lineWidth: 0.5)
                }
        }
        #else
        buttonStyle(.glass)
        #endif
    }

    #if os(iOS)
    /// iOS 26 can hide the system's top scroll edge effect; older systems simply keep theirs.
    @ViewBuilder
    func auraScrollEdgeEffectHidden(_ hidden: Bool) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(hidden, for: .top)
        } else {
            self
        }
    }
    #endif

    @available(iOS 26.0, *)
    @ViewBuilder
    private func glass<S: Shape>(
        in shape: S,
        tint: Color?,
        interactive: Bool
    ) -> some View {
        if interactive {
            if let tint {
                glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                glassEffect(.regular.interactive(), in: shape)
            }
        } else if let tint {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            glassEffect(.regular, in: shape)
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        background {
            shape.fill(.ultraThinMaterial)
            if let tint {
                shape.fill(tint.opacity(0.14))
            }
            shape.stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
    }
    #endif
}
