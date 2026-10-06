import AppKit
import MarkdownCore

/// What the session asks the core about the selection and the visible text, and applies: the focus range, the format
/// state and the table.
///
/// The core's `selectionState` is a pure query over the current analysis, so the session re-queries after every edit,
/// selection change and scroll that leaves the queried window; it never trusts an old answer after an edit. The
/// query is windowed (visible range plus a generous margin; the whole text when it is small). It goes through the
/// coordinator like every other core call: answered on the spot when the analysis queue is idle (the query itself is
/// microseconds), asked for asynchronously and applied when it arrives when the queue is busy.
extension EditorSession {
    /// Up to this length the whole text is queried at once; beyond it, a window around what is on
    /// screen (the visible text and 6,000 characters each side).
    static let wholeTextLimit = 32_000

    /// Editor, Split or Preview. The text view keeps its selection and scroll while it is not shown.
    public func setLayout(_ mode: LayoutMode) {
        guard mode != layout else { return }
        layout = mode
        onLayoutChange?()
    }

    // MARK: querying

    /// The text range to ask the core about: what is on screen and a margin around it.
    func queryWindow() -> NSRange {
        let length = storage.length
        if length <= Self.wholeTextLimit { return NSRange(location: 0, length: length) }
        let visible = visibleRange()
        let margin = max(6_000, visible.length * 2)
        let start = max(0, visible.location - margin)
        let end = min(length, NSMaxRange(visible) + margin)
        return NSRange(location: start, length: end - start)
    }

    /// The one question the session asks the analysis queue about the selection: the focus range (when focusing),
    /// the format state and the table, in a single call. Cheap when nothing changed (the overlay applies only the
    /// difference).
    ///
    /// `synchronous` answers on the spot even when the queue is busy (it waits for the analysis of the edits
    /// submitted so far): for text about to be shown, which must not be drawn with a range carried over from before
    /// the last edits.
    /// `selectionChange`: the selection just moved, so the format state and table are wanted too.
    func refreshState(synchronous: Bool = false, selectionChange: Bool = false) {
        guard let tv = textView else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { timeInStateQueries += CFAbsoluteTimeGetCurrent() - t0 }
        let scope: FocusScope? = focusEnabled && !isComposing() && !focusHeld ? focusScopeForCore : nil
        // Whatever was scheduled is answered by this call, even when there is nothing to ask.
        statePending = false
        guard scope != nil || selectionChange else { return }
        stateToken += 1
        let token = stateToken
        let selectionToken = self.selectionToken
        let window = queryWindow()
        let sel = tv.selectedRange()
        let selection = Utf16Range(start: UInt32(min(sel.location, storage.length)), end: UInt32(min(NSMaxRange(sel), storage.length)))
        let within = Utf16Range(start: UInt32(window.location), end: UInt32(NSMaxRange(window)))
        let coordinator = self.coordinator
        let query: (Document) -> SelectionState = { doc in
            doc.selectionState(selection: selection, within: within, conceal: false, focus: scope)
        }
        stateQueries += 1
        func finish(_ state: SelectionState, processed: Int) {
            let current = token == stateToken && processed == coordinator.latestSeq
            if current, scope != nil, focusEnabled {
                focusWindow = window
                applyFocus(state.focus)
            }
            if selectionChange, selectionToken == self.selectionToken, processed == coordinator.latestSeq {
                applyFormatState(state)
            }
            if current, scope != nil { onLayoutSettled?() }
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

    /// For edits that arrive inside the storage delegate: the selection is not final yet, so the query follows on
    /// the next turn (the selection change that normally follows an edit asks again anyway).
    func scheduleStateRefresh() {
        guard !statePending else { return }
        statePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, statePending else { return }
            refreshState()
        }
    }

    /// The visible area moved or changed size.
    func viewportChanged() {
        overlay.apply()
        if syntaxEnabled { pos.viewportChanged() }
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
            if NSIntersectionRange(needed, covered) != needed { refreshState(synchronous: true) }
        }
    }

    /// The text the selection query last covered, when scrolling can show text it did not: focus mode with a selection
    /// (the units a selection touches are worked out inside the query's window only, so text scrolled into view is
    /// asked about).
    private func queriedWindowForScrolling() -> NSRange? {
        if focusEnabled, let tv = textView, tv.selectedRange().length > 0 { return focusWindow }
        return nil
    }
}
