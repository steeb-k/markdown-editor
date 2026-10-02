import AppKit
import MarkdownCore

/// Live mode, session side: keeps the layout manager's concealment equal to the core's answer
/// for the current selection and the visible text.
///
/// The core's `concealment` is a pure query over the current analysis, so the session
/// re-queries after every applied analysis result, every selection change and every scroll that
/// leaves the queried window; it never trusts an old answer after an edit. The query is
/// windowed (visible range plus a generous margin; the whole text when it is small). It goes
/// through the coordinator like every other core call: answered on the spot when the analysis
/// queue is idle (the query itself is microseconds), asked for asynchronously and applied when
/// it arrives when the queue is busy. Applying happens in the same main-thread turn as the
/// restyle or selection change that caused it, so there is no frame in between.
extension EditorSession {
    static let wholeTextLimit = 150_000

    func configureLive() {
        layoutManager.palette = appearance.palette
        layoutManager.bodyFont = appearance.fonts.body
        layoutManager.imageBudget = { [weak self] in self?.imageBudget() ?? ImageController.Budget(width: 600, maxHeight: 400) }
        layoutManager.imageEntry = { [weak self] destination, budget in
            guard let self else { return ImageController.Entry(phase: .failed, image: nil, size: ImageController.placeholderSize(budget)) }
            return imageController.entry(for: destination, budget: budget, scale: textView?.window?.backingScaleFactor ?? 2)
        }
        imageController.documentURL = { [weak self] in self?.documentURL() }
        imageController.onUpdate = { [weak self] url in self?.imageArrived(url) }
    }

    /// The room an image may take: the column, and at most 60% of what the window shows.
    func imageBudget() -> ImageController.Budget {
        let width = max(80, container.size.width - 2 * container.lineFragmentPadding)
        let visible = textView?.enclosingScrollView?.contentSize.height ?? 600
        return ImageController.Budget(width: width, maxHeight: max(120, (visible * 0.6).rounded()))
    }

    /// The document was saved or moved: failures to resolve relative paths may be over.
    public func documentURLChanged() {
        imageController.forgetFailures()
        preloadImages()
        layoutManager.invalidateImages { _ in true }
        textView?.needsDisplay = true
    }

    private func imageArrived(_ url: URL) {
        let matches: (LiveDecoration) -> Bool = { [imageController] d in
            if case .image(let destination, _) = d.kind { return imageController.resolve(destination) == url }
            return false
        }
        // A picture above the viewport changes size when it arrives (placeholder -> real size):
        // what the reader is looking at must not move, so the scroll position follows the change.
        var heightsAbove: [(NSRange, CGFloat)] = []
        if let tv = textView, tv.enclosingScrollView != nil {
            let top = tv.visibleRect.minY - tv.textContainerOrigin.y
            for d in layoutManager.imageDecorations where matches(d) {
                let host = layoutManager.hostCharacter(of: d.range)
                guard host < storage.length else { continue }
                let g = layoutManager.glyphIndexForCharacter(at: host)
                let rect = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                if rect.maxY <= top { heightsAbove.append((NSRange(location: host, length: 1), rect.height)) }
            }
        }
        layoutManager.invalidateImages(where: matches)
        if let tv = textView, let scroll = tv.enclosingScrollView, !heightsAbove.isEmpty {
            var delta: CGFloat = 0
            for (r, old) in heightsAbove {
                layoutManager.ensureLayout(forCharacterRange: r)
                let g = layoutManager.glyphIndexForCharacter(at: r.location)
                delta += layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).height - old
            }
            if abs(delta) > 0.5 {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
                scroll.reflectScrolledClipView(clip)
            }
        }
        textView?.needsDisplay = true
    }

    // MARK: mode

    public func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        // Task items hang differently in Live mode: restyle everything (not a caret-time change).
        styler.liveMode = mode == .live
        restyleEverything()
        if mode == .live {
            refreshLive(force: true)
        } else {
            liveToken += 1
            liveWindow = NSRange(location: 0, length: 0)
            layoutManager.setLive(LiveState())
        }
        textView?.updateTrackingForLive()
        textView?.needsDisplay = true
        onViewModeChange?()
    }

    // MARK: querying

    /// The text range to ask the core about: what is on screen and a margin around it.
    func liveQueryWindow() -> NSRange {
        let length = storage.length
        if length <= Self.wholeTextLimit { return NSRange(location: 0, length: length) }
        let visible = visibleRange()
        let margin = max(6_000, visible.length * 2)
        let start = max(0, visible.location - margin)
        let end = min(length, NSMaxRange(visible) + margin)
        return NSRange(location: start, length: end - start)
    }

    /// Re-queries the concealment for the current selection and applies it. Cheap when nothing
    /// changed (the layout manager compares states and invalidates only what differs).
    public func refreshLive(force: Bool = false) {
        guard viewMode == .live, let tv = textView, !isComposing() else { return }
        livePending = false
        liveToken += 1
        let token = liveToken
        let window = liveQueryWindow()
        let sel = tv.selectedRange()
        let selection = Utf16Range(start: UInt32(min(sel.location, storage.length)), end: UInt32(min(NSMaxRange(sel), storage.length)))
        let within = Utf16Range(start: UInt32(window.location), end: UInt32(NSMaxRange(window)))
        let coordinator = self.coordinator
        let query: (Document) -> (Concealment, [ImageRef]) = { doc in
            let c = doc.concealment(selection: selection, within: within)
            let hasImage = c.decorations.contains { if case .image = $0.kind { return true } else { return false } }
            return (c, hasImage ? coordinator.cachedImages(of: doc) : [])
        }
        liveQueries += 1
        if coordinator.isIdle {
            let (c, images) = coordinator.sync(query)
            applyLive(c, images: images, window: window)
        } else {
            coordinator.async(query) { [weak self] result, processed in
                guard let self, token == liveToken, processed == coordinator.latestSeq, viewMode == .live else { return }
                applyLive(result.0, images: result.1, window: window)
            }
        }
    }

    /// For edits that arrive inside the storage delegate: the selection is not final yet and
    /// the layout manager must not be disturbed mid-edit, so the query follows on the next turn
    /// (the selection change that normally follows an edit asks again anyway).
    func scheduleLiveRefresh() {
        guard !livePending else { return }
        livePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, livePending else { return }
            refreshLive()
        }
    }

    private func applyLive(_ c: Concealment, images: [ImageRef], window: NSRange) {
        let new = LiveState(c, images: images)
        liveWindow = window
        let merged = LiveState.merged(old: layoutManager.live, new: new, window: window)
        layoutManager.setLive(merged)
        preloadImages()
    }

    /// Starts loading the pictures the concealment shows, without waiting for their lines to be
    /// laid out (a picture above the viewport would otherwise only be asked for once something
    /// scrolls to it).
    func preloadImages() {
        let budget = imageBudget()
        let scale = textView?.window?.backingScaleFactor ?? 2
        for d in layoutManager.imageDecorations {
            if case .image(let destination, _) = d.kind { _ = imageController.entry(for: destination, budget: budget, scale: scale) }
        }
    }

    /// Called when the text view scrolls or resizes: asks again once the visible text is
    /// close to the edge of what was queried.
    func visibleRangeChanged() {
        guard viewMode == .live, storage.length > Self.wholeTextLimit else { return }
        let visible = visibleRange()
        let slack = max(2_000, visible.length)
        let needed = NSRange(location: max(0, visible.location - slack), length: min(storage.length, NSMaxRange(visible) + slack) - max(0, visible.location - slack))
        if NSIntersectionRange(needed, liveWindow) != needed { refreshLive() }
    }

    // MARK: caret

    /// Keeps a caret out of text that is not drawn: a caret strictly inside concealed text (a
    /// click or a vertical move that landed on a hidden prefix) goes to the nearer edge in the
    /// direction it was heading, a caret on a collapsed line goes to the next visible line.
    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                         toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        guard viewMode == .live, newSelectedCharRange.length == 0, !layoutManager.live.isEmpty else { return newSelectedCharRange }
        // Undo and redo put the caret exactly where it was.
        if let um = textView.undoManager, um.isUndoing || um.isRedoing { return newSelectedCharRange }
        let live = layoutManager.live
        let p = newSelectedCharRange.location
        let forward = p >= oldSelectedCharRange.location
        if let line = live.collapsedLine(containing: p) {
            // A caret entering a collapsed fence goes to the first (or last) line of the code. One
            // that was on this line already (an edit just made it a delimiter, as when `  - `
            // typed under a list item turns into a setext underline) stays: the next query shows
            // the line again.
            if NSLocationInRange(oldSelectedCharRange.location, line) { return newSelectedCharRange }
            if forward, NSMaxRange(line) < storage.length { return NSRange(location: NSMaxRange(line), length: 0) }
            if !forward, line.location > 0 { return NSRange(location: line.location - 1, length: 0) }
            return newSelectedCharRange
        }
        if let h = RangeList.range(containing: live.atomic, p), p > h.location {
            return NSRange(location: forward ? NSMaxRange(h) : h.location, length: 0)
        }
        return newSelectedCharRange
    }
}

extension AnalysisCoordinator {
    /// The document's images, kept per revision. Call only from inside a query closure (on the
    /// analysis queue).
    func cachedImages(of doc: Document) -> [ImageRef] {
        let rev = doc.revision()
        if let c = imageCache, c.revision == rev { return c.images }
        let images = doc.images()
        imageCache = (rev, images)
        return images
    }
}
