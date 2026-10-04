import AppKit
import MarkdownCore

/// The right-hand column: the outline with the document's headings, or the history of its versions (see
/// `EditorWindowController+History`), in every layout, never fading with the chrome. It sits beside the editor's pane
/// in a split view of its own, which takes the place of the editor's view (alone in the window, or right of the notes
/// sidebar). The column shows one of the two; each has its own toggle, its own width and its own controller.
extension EditorWindowController {
    @objc func toggleOutline(_ sender: Any?) { session.setOutlineShown(!session.outlineShown) }

    /// The view in the column, whichever it is.
    var columnView: NSView? { outline?.view ?? history?.view }

    /// Where the column starts, as an x in the window, or nil without one.
    var columnLeft: CGFloat? {
        guard let view = columnView, view.window != nil else { return nil }
        return view.convert(NSPoint.zero, to: nil).x
    }

    /// The column's width as the session has it for what it shows.
    private var wantedColumnWidth: CGFloat { session.historyShown ? session.historyWidth : session.outlineWidth }

    /// What the column adds to the window's narrowest: nothing without it.
    var outlineMinExtra: CGFloat { session.outlineShown || session.historyShown ? wantedColumnWidth + 1 : 0 }

    /// The window as the session says: with the outline, with the history, or without a column.
    func applyOutline() { applyColumn() }

    func applyColumn() {
        guard let window else { return }
        // Moving the editor's view into or out of the column's split view takes the keyboard from it: it goes back.
        let responder = window.firstResponder as? NSView
        let editorHadTheKeyboard = responder?.isDescendant(of: root) == true
        defer {
            if editorHadTheKeyboard, let responder, responder.window === window, window.firstResponder !== responder { window.makeFirstResponder(responder) }
        }
        let wantsOutline = session.outlineShown, wantsHistory = session.historyShown
        // What the column no longer shows goes, and the other takes its place in the same host.
        if !wantsOutline, let o = outline {
            o.view.removeFromSuperview()
            outline = nil
        }
        if !wantsHistory, let h = history {
            h.view.removeFromSuperview()
            h.service = nil
            history = nil
        }
        // The window is wide enough for the column before the column is in it: the editor's pane cannot be squeezed below
        // what its own constraints need (the formatting bar), and AppKit says so with an exception from the solver.
        window.minSize.width = baseMinWidth + (inNotesMode ? CGFloat(workspace?.sidebarWidth ?? 240) + 1 : 0) + outlineMinExtra
        if window.frame.width < window.minSize.width {
            var f = window.frame
            f.size.width = window.minSize.width
            window.setFrame(f, display: true)
        }
        if wantsOutline || wantsHistory { installColumn(in: window) } else { removeColumnHost(in: window) }
        updateFadeGeometry()
        if wantsOutline {
            outline?.update(session.outlineEntries)
            session.requestOutline()
            outlineLayoutChanged()
        }
        if wantsHistory { history?.reload() }
    }

    private func installColumn(in window: NSWindow) {
        if paneHost == nil {
            let host = NotesSplitView(frame: root.frame)
            host.isVertical = true
            host.dividerStyle = .thin
            host.delegate = self
            host.tint = session.appearance.palette.rule
            paneHost = host
            let frame = root.frame
            if let split = notesSplit, root.superview === split {
                root.removeFromSuperview()
                host.frame = frame
                split.addSubview(host)
            } else {
                window.contentView = host
            }
            host.addSubview(root)
        }
        guard let host = paneHost else { return }
        let newView: NSView
        if session.outlineShown {
            guard outline == nil else { return }
            let o = OutlineController(style: SidebarStyle(session.appearance.palette))
            o.onJump = { [weak self] entry in self?.jump(to: entry) }
            outline = o
            newView = o.view
        } else {
            guard history == nil else { return }
            let h = makeHistoryController()
            history = h
            newView = h.view
        }
        host.addSubview(newView)
        let w = min(max(wantedColumnWidth, 160), 480)
        let total = host.bounds.width
        root.frame = NSRect(x: 0, y: 0, width: max(0, total - w - 1), height: host.bounds.height)
        newView.frame = NSRect(x: total - w, y: 0, width: w, height: host.bounds.height)
        applyingOutlineWidth = true
        host.adjustSubviews()
        applyingOutlineWidth = false
        host.needsLayout = true
    }

    private func removeColumnHost(in window: NSWindow) {
        guard let host = paneHost else { return }
        paneHost = nil
        if let split = notesSplit, host.superview === split {
            let frame = host.frame
            host.removeFromSuperview()
            root.removeFromSuperview()
            root.frame = frame
            split.addSubview(root)
        } else {
            root.removeFromSuperview()
            window.contentView = root
            root.autoresizingMask = []
            root.frame = window.contentView?.bounds ?? root.frame
        }
        root.needsLayout = true
    }

    /// The divider moved: only the user's drag (an event in the mouse's hands) is a new width to remember.
    func outlineDividerMoved() {
        guard !applyingOutlineWidth, let view = columnView else { return }
        let type = NSApp.currentEvent?.type
        if type == .leftMouseDragged || type == .leftMouseUp {
            if session.historyShown {
                session.historyWidth = view.frame.width
                session.settings.historyWidth = Double(view.frame.width)
            } else {
                session.outlineWidth = view.frame.width
                session.settings.outlineWidth = Double(view.frame.width)
            }
            window?.minSize.width = baseMinWidth + (inNotesMode ? CGFloat(workspace?.sidebarWidth ?? 240) + 1 : 0) + outlineMinExtra
        }
    }

    // MARK: following the reader

    /// The headings arrived: the list shows them and marks where the reader is.
    func outlineArrived(_ entries: [OutlineEntry]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        outline?.update(entries)
        outlineLayoutChanged()
        lastOutlineArrival = CFAbsoluteTimeGetCurrent() - t0
    }

    /// The caret moved (the editor is showing): the heading it is in is marked.
    func outlineFollowCaret() {
        guard let outline, session.layout != .preview else { return }
        outline.mark(OutlineModel.index(containing: textView.selectedRange().location, in: session.outlineEntries))
    }

    /// The layout changed, or the headings did: in the Preview layout the heading at the top of the page is
    /// the one marked (by the editor's own top until the page reports), otherwise the caret's.
    func outlineLayoutChanged() {
        guard let outline else { return }
        if session.layout == .preview {
            let line = lastPageLine ?? previewController.editorReadingPosition() ?? 0
            outline.mark(OutlineModel.index(atLine: line, in: session.outlineEntries))
        } else {
            outlineFollowCaret()
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
        if let i = OutlineModel.index(containing: location, in: session.outlineEntries) { outline?.mark(i) }
        jumps += 1
    }
}
