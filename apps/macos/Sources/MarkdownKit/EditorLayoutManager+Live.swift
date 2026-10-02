import AppKit

/// Live mode's concealer. The core says which ranges are not drawn; this turns that into
///
/// * null glyphs for hidden characters (`shouldGenerateGlyphs`), except for the leading
///   markup of an indented paragraph (a quote's `> `, a task item's dash), which keeps its
///   width as blank space so wrapped lines still hang under the text;
/// * collapsed lines and image-sized lines (`shouldSetLineFragmentRect`), by overriding the
///   height of the line fragments the typesetter produced;
/// * markers (list dashes, task boxes) whose glyphs are laid out but not drawn, because a
///   bullet or checkbox is drawn over them (`drawGlyphs`).
///
/// None of it touches the text storage or its attributes.
extension EditorLayoutManager: NSLayoutManagerDelegate {
    // MARK: applying a state

    /// Installs `new` and invalidates glyphs and layout only for the paragraphs whose
    /// concealment actually changed.
    func setLive(_ new: LiveState) {
        let old = live
        guard new != old || !staleRanges.isEmpty else { return }
        live = new
        derive(from: new)
        guard let storage = textStorage else { return }
        let length = storage.length
        var changed = RangeList.symmetricDifference(old.hidden, new.hidden)
        changed += RangeList.symmetricDifference(old.collapsed, new.collapsed)
        for d in Set(old.decorations).symmetricDifference(Set(new.decorations)) { changed.append(d.range) }
        changed += staleRanges
        staleRanges = []
        let ns = storage.mutableString as NSString
        var paragraphs = RangeList.normalized(changed.compactMap { r in
            let c = RangeMath.clamp(r, toLength: length)
            guard length > 0 else { return nil }
            return ns.paragraphRange(for: NSRange(location: min(c.location, length - 1), length: c.length))
        })
        // A quote bar or a rule spans lines whose own concealment did not change.
        paragraphs = RangeList.normalized(paragraphs)
        if recordsInvalidations { invalidatedRanges += paragraphs }
        for p in paragraphs {
            invalidateGlyphs(forCharacterRange: p, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: p, actualCharacterRange: nil)
            invalidateDisplay(forCharacterRange: p)
        }
    }

    /// The layout of everything concealed is stale (width, font or budget changed).
    func relayoutLive() {
        guard let storage = textStorage, storage.length > 0, !live.isEmpty else { return }
        let all = NSRange(location: 0, length: storage.length)
        invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
    }

    /// Re-lays out (and redraws) the image paragraphs, e.g. when an image has just loaded.
    func invalidateImages(where matches: (LiveDecoration) -> Bool) {
        guard let storage = textStorage else { return }
        for d in imageDecorations where matches(d) {
            let r = RangeMath.clamp(d.range, toLength: storage.length)
            guard r.length > 0 else { continue }
            invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
            invalidateDisplay(forCharacterRange: r)
        }
    }

    /// An edit happened: ranges move with their text before anything is laid out again.
    func shiftLive(through change: TextChange) {
        guard !live.isEmpty else { return }
        let (shifted, dropped) = live.shifted(through: change)
        live = shifted
        staleRanges = RangeList.normalized(staleRanges.compactMap { LiveState.shift($0, through: change) } + dropped)
        derive(from: shifted)
    }

    /// What the delegate methods and drawing look up, derived from the state.
    private func derive(from state: LiveState) {
        markerRanges = RangeList.normalized(state.decorations.compactMap {
            if case .bullet = $0.kind { return $0.range } else { return nil }
        })
        imageDecorations = state.decorations.filter { if case .image = $0.kind { return true } else { return false } }
        // The null prefix of a task item runs from its list marker to the end of the hidden range
        // that holds the `[ ]` (hidden ranges merge, so it may also hold a quote's `> ` before it).
        guard let storage = textStorage else { taskPrefixes = []; return }
        let ns = storage.mutableString as NSString
        taskPrefixes = state.decorations.compactMap { d in
            guard case .checkbox = d.kind, let h = RangeList.range(containing: state.hidden, d.range.location),
                  NSMaxRange(h) <= ns.length else { return nil }
            var i = d.range.location
            while i > h.location, ns.character(at: i - 1) == 0x20 || ns.character(at: i - 1) == 0x09 { i -= 1 }
            if i > h.location { i -= 1 } // the list marker itself
            return NSRange(location: max(h.location, i), length: NSMaxRange(h) - max(h.location, i))
        }
    }

    // MARK: glyphs

    public func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                              forGlyphRange glyphRange: NSRange) -> Int {
        let hidden = live.hidden
        let n = glyphRange.length
        guard !hidden.isEmpty, n > 0 else { return 0 }
        let first = charIndexes[0], last = charIndexes[n - 1]
        let i = RangeList.firstIndex(endingAfter: min(first, last), in: hidden)
        guard i < hidden.count, hidden[i].location <= max(first, last) else { return 0 }
        var out = Array(UnsafeBufferPointer(start: props, count: n))
        for g in 0..<n {
            let ci = charIndexes[g]
            guard RangeList.contains(hidden, ci) else { continue }
            out[g] = isLeadingMarkup(at: ci) ? .controlCharacter : .null
        }
        out.withUnsafeBufferPointer { buf in
            lm.setGlyphs(glyphs, properties: buf.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return n
    }

    /// Is the hidden character at `ci` part of the markup that starts its paragraph (`# `, `> `,
    /// a code fence, an opening `**`)? A true null glyph at the start of a paragraph is placed by
    /// the typesetter on the *previous* line fragment, which loses the paragraph's own spacing,
    /// puts the caret on the wrong line when moving vertically and leaves a hidden fence without
    /// a fragment of its own. These characters are zero-advance control glyphs instead: still
    /// not drawn, still taking no room, but staying in their own line.
    func isLeadingMarkup(at ci: Int) -> Bool {
        guard let storage = textStorage, ci < storage.length else { return false }
        let ns = storage.mutableString as NSString
        var i = ci - 1
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x0A || c == 0x0D { return true }
            if c != 0x20 && c != 0x09 && !live.isHidden(i) && !RangeList.contains(markerRanges, i) { return false }
            i -= 1
        }
        return true
    }

    /// Does a hidden leading character keep its width? In a hanging paragraph (a quote line, a
    /// list item) wrapped lines are indented by the width of the whole prefix, so the first line
    /// must not lose it. A task item's `- [ ] ` is the exception: its checkbox takes the bullet's
    /// place and the paragraph style already accounts for that.
    private func keepsWidth(at ci: Int) -> Bool {
        guard let storage = textStorage, ci < storage.length, !RangeList.contains(taskPrefixes, ci),
              let style = storage.attribute(.paragraphStyle, at: ci, effectiveRange: nil) as? NSParagraphStyle,
              style.headIndent > 0 else { return false }
        // Only the quote markers and the blanks after them: the `# ` of a heading in a quote is
        // zero width, as everywhere.
        let ns = storage.mutableString as NSString
        var i = ci
        while i >= 0 {
            let c = ns.character(at: i)
            if c == 0x3E { return true }
            if c != 0x20 && c != 0x09 { return false }
            i -= 1
        }
        return false
    }

    public func layoutManager(_ lm: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                              forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        live.isHidden(charIndex) ? .whitespace : action
    }

    public func layoutManager(_ lm: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                              proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let storage = textStorage, charIndex < storage.length, live.isHidden(charIndex), keepsWidth(at: charIndex) else {
            return NSRect(x: 0, y: 0, width: 0, height: proposedRect.height)
        }
        let font = (storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont) ?? bodyFont
        let s = (storage.mutableString as NSString).substring(with: NSRange(location: charIndex, length: 1))
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: 0, y: 0, width: w, height: proposedRect.height)
    }

    // MARK: line fragments

    // A fully hidden paragraph (a fence line, an image's source, a rule) is one line fragment
    // holding its zero-width control glyphs and its terminator. That fragment is the one resized
    // and drawn on; these helpers find it.

    private func isTerminator(_ i: Int) -> Bool {
        guard let storage = textStorage, i >= 0, i < storage.length else { return false }
        let c = (storage.mutableString as NSString).character(at: i)
        return c == 0x0A || c == 0x0D
    }

    /// The collapsed line whose terminator is in the fragment covering `chars`.
    func collapsedLine(inFragment chars: NSRange) -> NSRange? {
        var i = RangeList.firstIndex(endingAfter: chars.location, in: live.collapsed)
        while i < live.collapsed.count, live.collapsed[i].location < NSMaxRange(chars) {
            let line = live.collapsed[i]
            let t = NSMaxRange(line) - 1
            if t >= chars.location, t < NSMaxRange(chars), isTerminator(t) { return line }
            i += 1
        }
        return nil
    }

    /// The character whose fragment carries a rule or an image: the one after its source (the
    /// terminator), or the last source character when the text ends there.
    func hostCharacter(of range: NSRange) -> Int {
        let length = textStorage?.length ?? 0
        return NSMaxRange(range) < length ? NSMaxRange(range) : max(0, length - 1)
    }

    func imageDecoration(hostedIn chars: NSRange) -> LiveDecoration? {
        imageDecorations.first { d in
            let host = hostCharacter(of: d.range)
            return host >= chars.location && host < NSMaxRange(chars)
        }
    }

    public func layoutManager(_ lm: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                              lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                              in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, !live.isEmpty else { return false }
        let chars = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var height: CGFloat?
        if let line = collapsedLine(inFragment: chars) {
            height = collapsedHeight(of: line)
        } else if let d = imageDecoration(hostedIn: chars), case .image(let destination, _) = d.kind {
            let budget = imageBudget()
            let size = imageEntry?(destination, budget).size ?? ImageController.placeholderSize(budget)
            height = size.height + 2 * Self.imagePadding
        }
        guard let h = height else {
            return false
        }
        lineFragmentRect.pointee.size.height = h
        lineFragmentUsedRect.pointee.size.height = h
        lineFragmentUsedRect.pointee.origin.y = lineFragmentRect.pointee.origin.y
        baselineOffset.pointee = min(baselineOffset.pointee, h)
        return true
    }

    /// Fences get a little air (the panel is drawn around the code, not around the fences);
    /// everything else collapses to a sliver.
    private func collapsedHeight(of line: NSRange) -> CGFloat {
        guard let storage = textStorage, line.location < storage.length else { return Self.collapsedHeight }
        return storage.attribute(.markdownBlockBackground, at: line.location, effectiveRange: nil) != nil
            ? Self.fenceCollapsedHeight : Self.collapsedHeight
    }

    // MARK: drawing

    /// Glyphs that a decoration stands for are laid out but not drawn.
    public override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !markerRanges.isEmpty else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var pieces = [chars]
        var i = RangeList.firstIndex(endingAfter: chars.location, in: markerRanges)
        while i < markerRanges.count, markerRanges[i].location < NSMaxRange(chars) {
            let m = markerRanges[i]
            pieces = pieces.flatMap { RangeList.subtract([$0], m) }
            i += 1
        }
        if pieces == [chars] {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        for p in pieces where p.length > 0 {
            super.drawGlyphs(forGlyphRange: glyphRange(forCharacterRange: p, actualCharacterRange: nil), at: origin)
        }
    }
}

// MARK: backgrounds, strikethrough and underline around hidden glyphs

/// A run of attributed text that starts or ends with hidden characters (the backticks of an
/// inline code span, the tildes of strikethrough) gets rectangles from AppKit that run to the end
/// of the line, and strikes drawn in the wrong place. These overrides draw only the visible
/// glyphs of a run.
extension EditorLayoutManager {
    /// Glyph ranges within `range` that are not null glyphs.
    private func visibleGlyphRuns(in range: NSRange) -> [NSRange] {
        var runs: [NSRange] = []
        var start: Int?
        for g in range.location..<NSMaxRange(range) {
            let hidden = propertyForGlyph(at: g).contains(.null) || live.isHidden(characterIndexForGlyph(at: g))
            if hidden {
                if let s = start { runs.append(NSRange(location: s, length: g - s)); start = nil }
            } else if start == nil {
                start = g
            }
        }
        if let s = start { runs.append(NSRange(location: s, length: NSMaxRange(range) - s)) }
        return runs
    }

    /// Horizontal extent of the glyphs `run` (within one line fragment), from where the first one
    /// is placed to where the glyph after the run is (or the end of the line). `boundingRect`
    /// answers wrongly for runs next to null glyphs.
    private func xRange(of run: NSRange, fragment fragGlyphs: NSRange, line: NSRect, used: NSRect) -> ClosedRange<CGFloat> {
        let start = line.minX + location(forGlyphAt: run.location).x
        let end = NSMaxRange(run) < NSMaxRange(fragGlyphs) ? line.minX + location(forGlyphAt: NSMaxRange(run)).x : used.maxX
        return start...max(start, end)
    }

    public override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawOrigin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    public override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                                 forCharacterRange charRange: NSRange, color: NSColor) {
        let hiddenHere = RangeList.firstIndex(endingAfter: charRange.location, in: live.hidden)
        guard hiddenHere < live.hidden.count, live.hidden[hiddenHere].location < NSMaxRange(charRange), textContainers.first != nil else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // `glyphRange(forCharacterRange:)` of a range that starts with a null glyph reaches back
        // to the glyph before it (a null glyph belongs to the cluster of its predecessor), which is
        // what stretched the default rectangles. Ask about the visible pieces instead.
        color.setFill()
        var pieces = [charRange]
        for h in live.hidden[hiddenHere...] where h.location < NSMaxRange(charRange) {
            pieces = pieces.flatMap { RangeList.subtract([$0], h) }
        }
        for piece in pieces where piece.length > 0 {
            let run = glyphRange(forCharacterRange: piece, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: run) { [self] line, used, _, fragGlyphs, _ in
                var sub = NSIntersectionRange(fragGlyphs, run)
                // Trailing null glyphs have no width; leave them out of the measurement.
                while sub.length > 0, live.isHidden(characterIndexForGlyph(at: NSMaxRange(sub) - 1)) { sub.length -= 1 }
                while sub.length > 0, live.isHidden(characterIndexForGlyph(at: sub.location)) { sub.location += 1; sub.length -= 1 }
                guard sub.length > 0 else { return }
                let x = xRange(of: sub, fragment: fragGlyphs, line: line, used: used)
                NSRect(x: x.lowerBound + drawOrigin.x, y: line.minY + drawOrigin.y, width: x.upperBound - x.lowerBound, height: line.height).fill()
            }
        }
    }

    /// Draws the strike itself: AppKit's, handed a run next to null glyphs, put it at the end of
    /// the line.
    public override func drawStrikethrough(forGlyphRange glyphRange: NSRange, strikethroughType strikethroughVal: NSUnderlineStyle,
                                           baselineOffset: CGFloat, lineFragmentRect lineRect: NSRect,
                                           lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: NSPoint) {
        guard !live.hidden.isEmpty, let storage = textStorage else {
            super.drawStrikethrough(forGlyphRange: glyphRange, strikethroughType: strikethroughVal, baselineOffset: baselineOffset,
                                    lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
            return
        }
        for run in visibleGlyphRuns(in: NSIntersectionRange(glyphRange, lineGlyphRange)) {
            let ci = characterIndexForGlyph(at: run.location)
            guard ci < storage.length else { continue }
            let attrs = storage.attributes(at: ci, effectiveRange: nil)
            let font = (attrs[.font] as? NSFont) ?? bodyFont
            let color = (attrs[.strikethroughColor] as? NSColor) ?? (attrs[.foregroundColor] as? NSColor) ?? .textColor
            let x = xRange(of: run, fragment: lineGlyphRange, line: lineRect, used: lineFragmentUsedRect(forGlyphAt: run.location, effectiveRange: nil))
            let baseline = lineRect.minY + location(forGlyphAt: run.location).y
            let y = (baseline - font.xHeight * 0.5).rounded() + 0.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x.lowerBound + containerOrigin.x, y: y + containerOrigin.y))
            path.line(to: NSPoint(x: x.upperBound + containerOrigin.x, y: y + containerOrigin.y))
            path.lineWidth = max(1, (font.pointSize / 16).rounded())
            color.setStroke()
            path.stroke()
        }
    }

    public override func drawUnderline(forGlyphRange glyphRange: NSRange, underlineType underlineVal: NSUnderlineStyle,
                                       baselineOffset: CGFloat, lineFragmentRect lineRect: NSRect,
                                       lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: NSPoint) {
        guard !live.hidden.isEmpty else {
            super.drawUnderline(forGlyphRange: glyphRange, underlineType: underlineVal, baselineOffset: baselineOffset,
                                lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
            return
        }
        for run in visibleGlyphRuns(in: glyphRange) {
            super.drawUnderline(forGlyphRange: run, underlineType: underlineVal, baselineOffset: baselineOffset,
                                lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
        }
    }
}
