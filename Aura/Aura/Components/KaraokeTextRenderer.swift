import SwiftUI

/// Paints a lyric line with a fill front that travels through it, instead of flipping each
/// word from grey to white in a single frame.
///
/// It works on the text's own layout, so wrapping is untouched: the line is still one `Text`
/// built by concatenation, and this only decides how each glyph run is *painted*. That
/// distinction is the whole design — anything that changed the layout per word would re-wrap
/// the phrase as the song moved through it, which is the reshuffling that was deliberately
/// taken out of the sheet.
///
/// One run per word, which holds because `lyricLineText` concatenates one `Text` per word.
/// If the text engine ever splits a run — font fallback, bidi — the extra runs simply read as
/// later words. Every run is drawn unconditionally either way, so the worst case is a fill
/// that runs slightly ahead or behind, never missing text.
struct KaraokeTextRenderer: TextRenderer, Animatable {
    /// Position of the fill front as a fractional run index: 3.4 means run 3 is 40% filled.
    var front: Double

    /// How much of the line's colour a word keeps before the front reaches it. Not zero —
    /// the point of a karaoke sheet is that you can read the words you haven't sung yet.
    var unsungOpacity: Double = 0.35

    /// Half-width of the soft edge, in fractions of a word. At 0 this is a hard wipe; the
    /// blur of a few tenths of a word is what makes it read as ink soaking in rather than
    /// as a shutter passing over.
    var edgeSoftness: Double = 0.22

    /// Stands in for "this whole line is behind us". Finite on purpose: the front is
    /// interpolated between playback ticks, and infinity would interpolate to NaN and blank
    /// the line. Large enough that the reverse jump, when a line becomes the current one, is
    /// over long before any of it is on screen.
    static let filled: Double = 1_000_000

    /// Lets SwiftUI interpolate the front between playback ticks. The time observer fires
    /// every 100 ms, which on its own would step the fill three or four times across a word;
    /// animating the renderer itself hands the in-between frames back to the display link.
    var animatableData: Double {
        get { front }
        set { front = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var runIndex = 0
        for line in layout {
            for run in line {
                defer { runIndex += 1 }
                let progress = front - Double(runIndex)

                // Wholly behind the front: nothing to mask, draw it once at full strength.
                if progress >= 1 {
                    context.draw(run)
                    continue
                }

                // The unsung state goes down first, for every run, before any of the fill
                // maths is trusted. If the front is ever wrong the words are all still
                // there — uniformly dim, never missing.
                var unsung = context
                unsung.opacity = unsungOpacity
                unsung.draw(run)

                guard progress > 0 else { continue }

                // The sung part is the same glyphs painted again at full strength through a
                // gradient mask, so the two states meet in a soft edge rather than a seam.
                var sung = context
                sung.clipToLayer { mask in
                    mask.fill(Path(maskRect(for: run)), with: shading(for: run, progress: progress))
                }
                sung.draw(run)
            }
        }
    }

    /// The run's box, opened up vertically so ascenders and descenders can't be shaved off
    /// by the mask — the gradient only ever needs to be exact horizontally.
    private func maskRect(for run: Text.Layout.Run) -> CGRect {
        let rect = run.typographicBounds.rect
        return rect.insetBy(dx: 0, dy: -rect.height)
    }

    private func shading(for run: Text.Layout.Run, progress: Double) -> GraphicsContext.Shading {
        let rect = run.typographicBounds.rect
        // Clamped and forced to increase: a gradient whose stops touch or invert is
        // undefined, and `progress` sits right at 0 and 1 on every word boundary.
        let leading = min(max(progress - edgeSoftness, 0), 1)
        let trailing = min(max(progress + edgeSoftness, leading + 0.0001), 1)
        return .linearGradient(
            Gradient(stops: [
                .init(color: .white, location: leading),
                .init(color: .clear, location: trailing),
            ]),
            startPoint: CGPoint(x: rect.minX, y: rect.midY),
            endPoint: CGPoint(x: rect.maxX, y: rect.midY)
        )
    }
}
