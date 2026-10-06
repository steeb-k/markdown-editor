import AppKit

/// The layout manager's delegate, and the backgrounds drawn under focus mode's dimming.
extension EditorLayoutManager: NSLayoutManagerDelegate {
    public func layoutManager(_ lm: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        layoutCompletions += 1
    }

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawOrigin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    public override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                                 forCharacterRange charRange: NSRange, color original: NSColor) {
        var color = original
        let selection = isSelectionHighlight(charRange, color: original)
        // Focus mode: an inline-code chip outside the focus range recedes with its text (the
        // temporary colours AppKit uses for glyphs do not reach backgrounds). A run that the
        // focus range cuts is drawn in its pieces. The selection highlight is not a chip: it is
        // drawn whole and at full strength over dimmed text too (it was drawn in pieces placed
        // without the text container's origin, a margin to the left and the top inset above the
        // selected text, and at 40% over dimmed lines, where it all but disappeared).
        if let o = overlay, o.isFocusing, !selection {
            let parts = o.pieces(of: charRange)
            if parts.count > 1, let tc = textContainers.first {
                for part in parts {
                    var n = 0
                    guard let rects = self.rectArray(forCharacterRange: part.range, withinSelectedCharacterRange: NSRange(location: NSNotFound, length: 0),
                                                in: tc, rectCount: &n), n > 0 else { continue }
                    // (Container coordinates; what is filled here is in the view's, from the origin being drawn at.)
                    let placed = (0..<n).map { rects[$0].offsetBy(dx: drawOrigin.x, dy: drawOrigin.y) }
                    placed.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        fillBackgroundRectArray(base, count: n, forCharacterRange: part.range, color: original)
                    }
                }
                return
            }
            if parts.first?.dimmed == true { color = color.withAlphaComponent(color.alphaComponent * Self.dimmedBackgroundStrength) }
        }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    /// The text view's selection highlight is being filled (not a background colour of the text): `range` is inside
    /// the selection and `color` is the highlight's (the view's own, or AppKit's when the window is not key).
    private func isSelectionHighlight(_ range: NSRange, color: NSColor) -> Bool {
        guard range.length > 0, let tv = firstTextView else { return false }
        let selected = tv.selectedRanges.map(\.rangeValue)
        guard selected.contains(where: { NSIntersectionRange($0, range) == range }) else { return false }
        let own = tv.selectedTextAttributes[.backgroundColor] as? NSColor
        return [own, NSColor.selectedTextBackgroundColor, NSColor.unemphasizedSelectedTextBackgroundColor].contains { $0 == color }
    }
}
