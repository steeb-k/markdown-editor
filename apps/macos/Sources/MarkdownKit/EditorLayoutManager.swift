import AppKit

/// TextKit 1 layout manager. Knows where block backgrounds (code blocks) go: one continuous
/// panel across the text column. M3 adds glyph concealment here.
public final class EditorLayoutManager: NSLayoutManager {
    /// How far a block panel reaches into the margins, and above/below its text.
    static let blockOutset = NSSize(width: 12, height: 6)
    static let blockCornerRadius: CGFloat = 6

    /// The panel rectangles (container coordinates) of the blocks touching `glyphs`.
    func blockBackgroundRects(forGlyphRange glyphs: NSRange) -> [(NSRect, NSColor)] {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return [] }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var out: [(NSRect, NSColor)] = []
        // A little past both ends: a panel reaches beyond its lines, into a neighbour's redraw.
        var loc = max(0, chars.location - 2)
        let end = min(NSMaxRange(chars) + 2, storage.length)
        while loc < end {
            var run = NSRange(location: 0, length: 0)
            // Always the whole block, even when only part of it is redrawn: corners belong at
            // its real ends, not at the edge of the dirty rectangle.
            let limit = NSRange(location: max(0, loc - 50_000), length: min(storage.length, loc + 50_000) - max(0, loc - 50_000))
            let value = storage.attribute(.markdownBlockBackground, at: loc, longestEffectiveRange: &run, in: limit)
            defer { loc = max(loc + 1, NSMaxRange(run)) }
            guard let color = value as? NSColor, run.length > 0 else { continue }
            let g = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            var rect = NSRect.null
            var lastLine = NSRect.null
            enumerateLineFragments(forGlyphRange: g) { line, _, _, _, _ in
                rect = rect.union(line)
                lastLine = line
            }
            guard !rect.isNull else { continue }
            // The line spacing under the last line is not part of the block: it ends where the
            // last line's glyphs do, so the padding is the same above and below.
            if let font = storage.attribute(.font, at: NSMaxRange(run) - 1, effectiveRange: nil) as? NSFont {
                rect.size.height = min(rect.height, lastLine.minY + defaultLineHeight(for: font) - rect.minY)
            }
            rect.origin.x = 0
            rect.size.width = container.size.width
            out.append((rect.insetBy(dx: -Self.blockOutset.width, dy: -Self.blockOutset.height), color))
        }
        return out
    }

    /// Called by the text view after it has drawn its background and before the text (an
    /// override of `drawBackground(forGlyphRange:at:)` is painted over by the view background).
    func drawBlockBackgrounds(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        for (rect, color) in blockBackgroundRects(forGlyphRange: glyphs) {
            color.setFill()
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y),
                         xRadius: Self.blockCornerRadius, yRadius: Self.blockCornerRadius).fill()
        }
    }
}
