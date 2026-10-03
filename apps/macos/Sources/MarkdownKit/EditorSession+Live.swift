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
    /// Up to this length the whole text is queried at once; beyond it, a window around what is on
    /// screen. Measured in a release build: the whole-text query and its application cost about
    /// 0.07 ms per thousand characters on every caret move and keystroke (18 ms at 150k), so the
    /// limit is about the size of a window (which is the visible text and 6,000 characters each
    /// side), where both cost the same.
    static let wholeTextLimit = 32_000
    /// How many windows' worth of concealment is kept on either side of the current one.
    static let keptWindows = 6

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

    /// Editor, Split or Preview. The text view keeps its selection and scroll while it is not shown.
    public func setLayout(_ mode: LayoutMode) {
        guard mode != layout else { return }
        layout = mode
        onLayoutChange?()
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

    /// Re-queries what depends on the selection and the text and applies it: the concealment
    /// (Live mode) and the focus range (focus mode). Cheap when nothing changed (the layout
    /// manager compares states and invalidates only what differs; the overlay applies only the
    /// difference).
    ///
    /// `synchronous` answers on the spot even when the queue is busy (it waits for the analysis
    /// of the edits submitted so far): for text about to be shown, which must not be drawn with
    /// concealment carried over from before the last edits.
    public func refreshLive(force: Bool = false, synchronous: Bool = false) {
        refreshState(synchronous: synchronous)
    }

    /// The one question the session asks the analysis queue about the selection: concealment (when
    /// Live), focus range (when focusing), the format state and the table, in a single call.
    /// `selectionChange`: the selection just moved, so the format state and table are wanted too.
    func refreshState(synchronous: Bool = false, selectionChange: Bool = false) {
        guard let tv = textView else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeInStateQueries += CFAbsoluteTimeGetCurrent() - t0 }
        let composing = isComposing()
        let live = viewMode == .live && !composing
        let scope: FocusScope? = focusEnabled && !composing ? focusScopeForCore : nil
        // Whatever was scheduled is answered by this call, even when there is nothing to ask.
        livePending = false
        guard live || scope != nil || selectionChange else { return }
        liveToken += 1
        let token = liveToken
        let selectionToken = self.selectionToken
        let window = liveQueryWindow()
        let sel = tv.selectedRange()
        let selection = Utf16Range(start: UInt32(min(sel.location, storage.length)), end: UInt32(min(NSMaxRange(sel), storage.length)))
        let within = Utf16Range(start: UInt32(window.location), end: UInt32(NSMaxRange(window)))
        let coordinator = self.coordinator
        let query: (Document) -> (SelectionState, [ImageRef]) = { doc in
            let state = doc.selectionState(selection: selection, within: within, conceal: live, focus: scope)
            let hasImage = state.concealment?.decorations.contains { if case .image = $0.kind { return true } else { return false } } ?? false
            return (state, hasImage ? coordinator.cachedImages(of: doc) : [])
        }
        stateQueries += 1
        if live { liveQueries += 1 }
        func finish(_ result: (SelectionState, [ImageRef]), processed: Int) {
            let (state, images) = result
            let current = token == liveToken && processed == coordinator.latestSeq
            if current, live, viewMode == .live, let c = state.concealment {
                applyLive(c, images: images, window: window)
            }
            if current, scope != nil, focusEnabled {
                focusWindow = window
                applyFocus(state.focus)
            }
            if selectionChange, selectionToken == self.selectionToken, processed == coordinator.latestSeq {
                applyFormatState(state)
            }
            if current, live || scope != nil { onLayoutSettled?() }
        }
        if coordinator.isIdle || synchronous {
            finish(coordinator.sync(query), processed: coordinator.latestSeq)
        } else {
            stateQueriesInFlight += 1
            coordinator.async(query) { [weak self] result, processed in
                guard let self else { return }
                stateQueriesInFlight -= 1
                finish(result, processed: processed)
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
        // What earlier windows said about the text around this one is kept (it is asked again
        // before it is shown, see `visibleRangeChanged`): text the reader returns to then needs no
        // new glyphs when nothing changed there. Beyond `keptWindows` windows it is let go, so the
        // cost of each query and edit stays bounded; the glyphs made for it are regenerated when
        // a window reaches that text again. Only the window is compared.
        var old = layoutManager.live
        if window.length < storage.length {
            let reach = window.length * Self.keptWindows
            let from = max(0, window.location - reach), to = min(storage.length, NSMaxRange(window) + reach)
            let (kept, dropped) = old.limited(to: NSRange(location: from, length: to - from))
            if !dropped.isEmpty {
                old = kept
                layoutManager.markStale(dropped)
            }
        }
        let merged = LiveState.merged(old: old, new: new, window: window)
        layoutManager.setLive(merged, changedWithin: window.length >= storage.length ? nil : window)
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

    /// The visible area moved or changed size. A picture's room depends on the window's height
    /// (at most 60% of what it shows): when that changes, the picture lines are laid out again,
    /// or they would keep the old room while being drawn at the new size.
    func viewportChanged() {
        overlay.apply()
        if syntaxEnabled { pos.viewportChanged() }
        let budget = imageBudget()
        if budget != lastImageBudget {
            lastImageBudget = budget
            if viewMode == .live, !layoutManager.imageDecorations.isEmpty {
                layoutManager.invalidateImages { _ in true }
                preloadImages()
            }
        }
        visibleRangeChanged()
    }

    /// Called when the text view scrolls or resizes: asks again once the visible text is
    /// close to the edge of what was queried.
    func visibleRangeChanged() {
        guard storage.length > Self.wholeTextLimit, let covered = queriedWindowForScrolling() else { return }
        let visible = visibleRange()
        let slack = max(2_000, visible.length)
        let needed = NSRange(location: max(0, visible.location - slack), length: min(storage.length, NSMaxRange(visible) + slack) - max(0, visible.location - slack))
        guard NSIntersectionRange(needed, covered) != needed, !scrollRefreshPending else { return }
        // Asked once the scroll that brought the text into view has finished (asked from inside
        // it, the new layout moved the text the scroll was aiming for), and before the text is
        // drawn: main-queue blocks run before the run loop's display pass. Answered on the spot
        // even if edits are still being analyzed, so nothing carried over is shown.
        scrollRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scrollRefreshPending = false
            guard let covered = queriedWindowForScrolling() else { return }
            let visible = visibleRange()
            let slack = max(2_000, visible.length)
            let needed = NSRange(location: max(0, visible.location - slack), length: min(storage.length, NSMaxRange(visible) + slack) - max(0, visible.location - slack))
            if NSIntersectionRange(needed, covered) != needed { refreshLive(synchronous: true) }
        }
    }

    /// The text the selection query last covered, when scrolling can show text it did not: Live
    /// mode's concealment, and focus mode with a selection (the units a selection touches are
    /// worked out inside the query's window only, so text scrolled into view is asked about).
    private func queriedWindowForScrolling() -> NSRange? {
        if viewMode == .live { return liveWindow }
        if focusEnabled, let tv = textView, tv.selectedRange().length > 0 { return focusWindow }
        return nil
    }

    // MARK: caret

    /// Keeps the caret (and the moving end of a selection being extended from the keyboard) where
    /// the user can see it. The rules, judged against what will be concealed once the caret is
    /// there (touching an element reveals its markup, so most positions next to markup are fine
    /// as they are):
    ///
    /// * a caret never rests inside, or at the start of, text that stays hidden with the caret
    ///   beside it (a task item's `- [ ] `, drawn as a checkbox): its start and its end are the
    ///   same place on screen, so the caret goes to its end; a step back from there (Left) goes
    ///   past it to the character before, so every press moves the caret on screen;
    /// * anything else lands where it was asked to (a fence line, a heading prefix: they are
    ///   shown once the caret is there).
    ///
    /// The concealment for the proposed caret is asked of the core (one paragraph, so it is
    /// cheap) only when the current one hides something at that position. When the analysis
    /// queue is busy the current concealment is used instead: a caret strictly inside hidden text
    /// goes to the nearer edge in the direction it was heading, one on a collapsed line to the
    /// next visible line.
    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                         toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        guard viewMode == .live, !layoutManager.live.isEmpty else { return newSelectedCharRange }
        // Undo and redo put the caret exactly where it was.
        if let um = textView.undoManager, um.isUndoing || um.isRedoing { return newSelectedCharRange }
        let command = (textView as? EditorTextView)?.currentCommand
        if newSelectedCharRange.length == 0 {
            let p = restingPlace(for: newSelectedCharRange.location, from: oldSelectedCharRange, command: command)
            return NSRange(location: p, length: 0)
        }
        // A selection extended from the keyboard: its moving end follows the same rules.
        guard let command, EditorTextView.selectionExtensions.contains(command) else { return newSelectedCharRange }
        let old = oldSelectedCharRange, new = newSelectedCharRange
        let anchor: Int, moving: Int
        if new.location == old.location {
            (anchor, moving) = (new.location, NSMaxRange(new))
        } else if NSMaxRange(new) == NSMaxRange(old) {
            (anchor, moving) = (NSMaxRange(new), new.location)
        } else {
            return new
        }
        let previousEnd = moving > anchor ? (old.length == 0 ? old.location : NSMaxRange(old)) : old.location
        let p = restingPlace(for: moving, anchor: anchor, from: NSRange(location: previousEnd, length: 0), command: command)
        return NSRange(location: min(anchor, p), length: abs(p - anchor))
    }

    /// Where a caret asked for at `p` comes to rest (see the delegate method above); with an
    /// `anchor`, where the moving end of the selection from `anchor` to `p` does.
    func restingPlace(for p: Int, anchor: Int? = nil, from old: NSRange, command: Selector?) -> Int {
        let live = layoutManager.live
        guard RangeList.range(containing: live.hidden, p) != nil || live.collapsedLine(containing: p) != nil else { return p }
        let previous = old.location
        let forward = p >= previous
        if coordinator.isIdle {
            let ns = storage.mutableString as NSString
            let length = ns.length
            let para = ns.paragraphRange(for: NSRange(location: min(p, max(0, length - 1)), length: 0))
            let a = UInt32(anchor ?? p), u = UInt32(p)
            let c = coordinator.sync { $0.concealment(selection: Utf16Range(start: min(a, u), end: max(a, u)),
                                                      within: Utf16Range(start: UInt32(para.location), end: UInt32(NSMaxRange(para)))) }
            let after = LiveState(c, images: [])
            guard let h = RangeList.range(containing: after.hidden, p) else { return p }
            if let anchor, p == h.location, p > anchor {
                // A selection that ends right before hidden text: one more step takes that text
                // in, which shows it, unless it stays hidden whatever is selected (a checkbox).
                let e = UInt32(NSMaxRange(h))
                let wider = coordinator.sync { $0.concealment(selection: Utf16Range(start: a, end: e),
                                                              within: Utf16Range(start: UInt32(para.location), end: UInt32(NSMaxRange(para)))) }
                if !LiveState(wider, images: []).isHidden(p) { return p }
            }
            let characterStep = command.map { EditorTextView.characterMoves.contains($0) } ?? false
            if characterStep, !forward, previous >= NSMaxRange(h) {
                return h.location > 0 ? EditorTextView.character(in: ns, at: h.location - 1).location : NSMaxRange(h)
            }
            return NSMaxRange(h)
        }
        if let line = live.collapsedLine(containing: p) {
            // A caret entering a collapsed fence goes to the first (or last) line of the code. One
            // that was on this line already (an edit just made it a delimiter, as when `  - `
            // typed under a list item turns into a setext underline) stays: the next query shows
            // the line again.
            if NSLocationInRange(previous, line) { return p }
            if forward, NSMaxRange(line) < storage.length { return NSMaxRange(line) }
            if !forward, line.location > 0 { return line.location - 1 }
            return p
        }
        if let h = RangeList.range(containing: live.atomic, p), p > h.location {
            return forward ? NSMaxRange(h) : h.location
        }
        return p
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
