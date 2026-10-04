import AppKit
import MarkdownCore

/// The outline pane of the side column (see `EditorWindowController+SideColumn`): what the window does with the headings
/// the core gives, and where the reader is.
extension EditorWindowController {
    // MARK: following the reader

    /// The headings arrived: the list shows them and marks where the reader is.
    func outlineArrived(_ entries: [OutlineEntry]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        outline?.update(entries)
        outlineLayoutChanged()
        lastOutlineArrival = CFAbsoluteTimeGetCurrent() - t0
    }

    /// The editor scrolled (or was laid out again at another size): the mark follows, once a display refresh, however
    /// many wheel events came before it. Never per event.
    func outlineScrolled() {
        guard outline != nil, session.layout != .preview else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now < outlineScrollQuietUntil {
            // A jump's own scrolling leaves its mark alone; the reader's wheel after the jump does not wait for the quiet
            // to end (it was dropped, and the mark stayed on the heading chosen wherever the reader went).
            guard editorScrollView.lastUserScroll > outlineScrollQuietUntil - Self.outlineJumpQuiet else { return }
            outlineScrollQuietUntil = 0
        }
        outlineScrollCoalescer?.request()
    }

    /// How long a jump's own scrolling (its second pass, a centring slide) keeps the mark on the heading chosen.
    static let outlineJumpQuiet: CFAbsoluteTime = 0.6

    static let outlineTopSlack: CGFloat = 12

    /// The character at the top of what the reader sees: the first line below the title bar (a heading whose line is
    /// just under the bar is visible, one partly under it is the top line), the text container's own y.
    func visibleTopCharacter() -> Int? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, session.storage.length > 0 else { return nil }
        // A dozen points in, so that a heading whose line starts just under the bar (the paragraph's spacing above it
        // being all that is between) is the top one, as the reader sees it, and one whose edge is at the bar's is too.
        let y = scrollView.contentView.bounds.minY + scrollView.editorBaseInsetTop - textView.textContainerOrigin.y + Self.outlineTopSlack
        if y <= 0 { return 0 }
        lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: y, width: tc.size.width, height: 1), in: tc)
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc)
        guard glyph < lm.numberOfGlyphs else { return session.storage.length }
        return lm.characterIndexForGlyph(at: glyph)
    }

    /// The heading at, or the last one above, the top of the visible text is the one marked: where the reader is.
    func outlineFollowScroll() {
        guard let outline, session.layout != .preview else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { lastOutlineScrollUpdate = CFAbsoluteTimeGetCurrent() - t0; outlineScrollUpdates += 1 }
        let entries = session.outlineEntries
        // With nothing at or above the top (front matter, an introduction) the reader is at the start of the first section.
        let index = OutlineModel.index(containing: visibleTopCharacter() ?? 0, in: entries) ?? (entries.isEmpty ? nil : 0)
        if index != outline.markedIndex { outline.mark(index) }
    }

    /// The layout changed, or the headings did: in the Preview layout the heading at the top of the page is
    /// the one marked (by the editor's own top until the page reports), otherwise the one at the top of the editor.
    func outlineLayoutChanged() {
        guard let outline else { return }
        if session.layout == .preview {
            let line = lastPageLine ?? previewController.editorReadingPosition() ?? 0
            outline.mark(OutlineModel.index(atLine: line, in: session.outlineEntries))
        } else {
            outlineFollowScroll()
        }
    }

    /// The page scrolled (the reader did, or a jump did): in the Preview layout that moves the mark.
    func outlinePageScrolled(to line: Double) {
        lastPageLine = line
        guard let outline, session.layout == .preview else { return }
        outline.mark(OutlineModel.index(atLine: line, in: session.outlineEntries))
    }

    // MARK: jumping

    /// A click or Return on a heading: the caret goes to it and the editor scrolls so it is at the top (in the
    /// middle when focus mode is centring); the preview, if it is showing, to the same heading by its line. The
    /// keyboard goes to what shows the text, so writing goes on from there.
    func jump(to entry: OutlineEntry) {
        let length = session.storage.length
        let location = min(Int(entry.range.start), length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        centring.requestDespiteMouse(NSRange(location: location, length: 0))
        let anchor = EditorTopAnchor(character: location, intoLine: 0)
        if session.layout == .preview {
            hiddenEditorTop = anchor
            lastPageLine = Double(entry.line)
            previewController.scrollPage(toLine: Double(entry.line))
            window?.makeFirstResponder(previewController.webView)
        } else {
            if !centring.isActive { restoreEditorTop(anchor) }
            window?.makeFirstResponder(textView)
        }
        // The jump's own scrolling (and its second pass, and a centring slide) does not move the mark off the heading
        // chosen: the last headings of a document cannot reach the top, and are still the one the reader chose.
        outlineScrollQuietUntil = CFAbsoluteTimeGetCurrent() + Self.outlineJumpQuiet
        outlineScrollCoalescer?.cancel()
        if let i = OutlineModel.index(containing: location, in: session.outlineEntries) { outline?.mark(i) }
        jumps += 1
    }
}
