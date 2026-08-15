import SwiftUI

/// Marks one word of a lyric line so it can be found again in the laid-out text.
///
/// It does two jobs. It carries the word's position for `KaraokeTextRenderer` — and, because
/// runs carrying identical attributes get coalesced by the text engine, it is also what keeps
/// the words in separate glyph runs. An earlier attempt at this fill counted runs instead of
/// tagging them, and the coalescing meant one "word" per line: the fill swept across whole
/// lines at once, with no regard for word timings.
struct KaraokeWord: TextAttribute {
    let index: Int
}

/// Fills each word of a lyric line from left to right as it is sung.
///
/// It works on the text's own layout, so wrapping is untouched: the line is still one `Text`
/// built by concatenation, and this only decides how each glyph run is *painted*. Nothing
/// here changes how a line is laid out — which is what would re-wrap a phrase mid-song and
/// reshuffle its words.
struct KaraokeTextRenderer: TextRenderer, Animatable {
    /// The fill front, as a fractional word index: 3.4 means word 3 is 40% filled.
    var front: Double

    /// What a word keeps before the front reaches it. Not zero — the point of a karaoke
    /// sheet is that you can read what you haven't sung yet.
    var unsungOpacity: Double = 0.35

    /// Half-width of the soft edge, as a fraction of a word. At 0 this is a hard wipe; a
    /// little blur is what makes it read as ink soaking in rather than a shutter passing.
    var edgeSoftness: Double = 0.13

    /// Stands in for "this whole line is behind us". Finite on purpose: the front is
    /// interpolated between playback ticks, and infinity would interpolate to NaN and blank
    /// the line. Large enough that the jump back, when a line becomes the current one, is
    /// over long before any of it could be on screen.
    static let filled: Double = 1_000_000

    /// Lets SwiftUI interpolate the front between playback ticks. The time observer fires
    /// every 100ms, which on its own would step the fill across a word in three or four
    /// jumps; animating the renderer hands the frames in between to the display link.
    var animatableData: Double {
        get { front }
        set { front = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                // No tag means this isn't a karaoke line — unsynced lyrics, highlighting
                // off, or a line nobody is singing. Draw it exactly as it asked to be drawn.
                guard let word = run[KaraokeWord.self] else {
                    context.draw(run)
                    continue
                }

                let progress = front - Double(word.index)
                if progress >= 1 {
                    context.draw(run)
                    continue
                }

                // The unsung state goes down first, before any of the fill maths is
                // trusted. If the front is ever wrong the words are all still there —
                // uniformly dim, never missing.
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

    /// The run's box, opened up vertically so ascenders and descenders can't be shaved off.
    /// The mask only ever needs to be exact horizontally.
    private func maskRect(for run: Text.Layout.Run) -> CGRect {
        let rect = run.typographicBounds.rect
        return rect.insetBy(dx: 0, dy: -rect.height)
    }

    private func shading(for run: Text.Layout.Run, progress: Double) -> GraphicsContext.Shading {
        let rect = run.typographicBounds.rect
        // Clamped and forced to increase: a gradient whose stops touch or invert is
        // undefined, and `progress` sits exactly on 0 and 1 at every word boundary.
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
