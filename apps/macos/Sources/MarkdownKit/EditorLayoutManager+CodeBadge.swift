import AppKit

/// The language badge of a fenced code block: the language's display name in a small pill at the
/// top-right inside the block's panel. It is drawn after the glyphs (by the text view's `draw`), so
/// the pill covers whatever code runs beneath it and the name stays legible, and it is hit-tested
/// from the same geometry (`codeBadges`), so what is drawn is what a click reaches. A block with no
/// language, or one the core does not know, has no `.markdownCodeLanguage` and so no badge.
struct CodeBadge {
    /// Container coordinates.
    var frame: NSRect
    var text: String
    /// The characters of the block's panel run; its start is where the block starts.
    var block: NSRange
    /// The panel's colour: the pill is filled with it.
    var fill: NSColor
    /// The block is outside the focus range.
    var dimmed: Bool
}

extension EditorLayoutManager {
    static let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let badgePadding = NSSize(width: 8, height: 2)
    /// From the panel's top and right edges to the pill's.
    static let badgeMargin = NSSize(width: 8, height: 4)
    /// How close to the pill the insertion point may be before the badge steps aside (see `codeBadges`).
    static let badgeCaretClearance: CGFloat = 6

    /// The badges of the blocks touching `glyphs`. The pill sits in the panel's top-right corner. A
    /// pill covers the code beneath it, and so it can cover the insertion point: while the caret is
    /// on the block's first line (the fence's) and within a few points of the pill's horizontal extent,
    /// the badge is left out, drawn and hit-tested alike, until the caret moves on. A caret further
    /// left on that line, or on any other line, leaves the badge where it is.
    /// `ignoringCaret`: all the badges there are, for redrawing the ones the caret's moving changes.
    func codeBadges(forGlyphRange glyphs: NSRange, ignoringCaret: Bool = false) -> [CodeBadge] {
        guard palette != nil else { return [] }
        let caret = firstTextView?.selectedRange()
        return blockPanels(forGlyphRange: glyphs).compactMap { panel in
            guard let text = panel.language else { return nil }
            let size = (text as NSString).size(withAttributes: [.font: Self.badgeFont])
            let w = ceil(size.width) + 2 * Self.badgePadding.width
            let h = ceil(size.height) + 2 * Self.badgePadding.height
            let frame = NSRect(x: (panel.rect.maxX - Self.badgeMargin.width - w).rounded(), y: (panel.rect.minY + Self.badgeMargin.height).rounded(),
                               width: w, height: h)
            if !ignoringCaret, let caret, caret.length == 0, let first = panel.firstLine,
               caret.location >= first.characters.location, caret.location <= NSMaxRange(first.characters),
               let x = caretX(at: caret.location, in: first.line, textEnd: first.textEnd, fragmentEnd: NSMaxRange(first.characters)),
               x >= frame.minX - Self.badgeCaretClearance, x <= frame.maxX + Self.badgeCaretClearance {
                return nil
            }
            return CodeBadge(frame: frame, text: text, block: panel.run, fill: panel.color, dimmed: overlay?.isDimmed(panel.run) ?? false)
        }
    }

    /// Where the insertion point at `location` is horizontally, on the line fragment `line` (container
    /// coordinates). At the end of the fragment it is after the last character: where a soft wrap breaks
    /// a line the caret is drawn there or at the start of the next line, so the end is assumed.
    private func caretX(at location: Int, in line: NSRect, textEnd: CGFloat, fragmentEnd: Int) -> CGFloat? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        if location >= fragmentEnd { return line.minX + textEnd }
        return line.minX + self.location(forGlyphAt: glyphIndexForCharacter(at: location)).x
    }

    /// The badge under `point` (container coordinates), if any.
    func codeBadge(at point: NSPoint, visibleGlyphs glyphs: NSRange) -> CodeBadge? {
        codeBadges(forGlyphRange: glyphs).first { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// Draws the badges that meet `clip` (container coordinates); `origin` is the container's origin in the view.
    func drawCodeBadges(in clip: NSRect, at origin: NSPoint) {
        guard let palette, let tc = textContainers.first, let storage = textStorage, storage.length > 0 else { return }
        let padded = clip.insetBy(dx: 0, dy: -Self.blockOutset.height - Self.badgeMargin.height)
        let glyphs = glyphRange(forBoundingRectWithoutAdditionalLayout: padded, in: tc)
        // Most redraws (typing in prose) have no badge in them: one attribute lookup says so, before any layout is asked.
        let chars = NSIntersectionRange(characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), NSRange(location: 0, length: storage.length))
        var run = NSRange(location: 0, length: 0)
        if chars.length == 0 || (storage.attribute(.markdownCodeLanguage, at: chars.location, longestEffectiveRange: &run, in: chars) == nil && NSMaxRange(run) >= NSMaxRange(chars)) { return }
        for badge in codeBadges(forGlyphRange: glyphs) where badge.frame.intersects(clip) {
            let frame = badge.frame.offsetBy(dx: origin.x, dy: origin.y)
            badge.fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.badgeFont,
                .foregroundColor: badge.dimmed ? palette.focusDim : palette.quote,
            ]
            (badge.text as NSString).draw(at: NSPoint(x: frame.minX + Self.badgePadding.width, y: frame.minY + Self.badgePadding.height), withAttributes: attrs)
        }
    }
}
