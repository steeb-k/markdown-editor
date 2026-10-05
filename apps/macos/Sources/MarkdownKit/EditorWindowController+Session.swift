import AppKit

/// The window's part of the session record (see `SessionRecord`): what it is now, and putting it back.
extension EditorWindowController {
    /// Something the record holds changed in this window.
    func recordChanged() {
        SessionRecorder.current?.noteChange()
    }

    /// The window as the record keeps it; nil for a window that is not recorded: a Help page, and an untitled document
    /// with nothing in it (a launch makes one of those itself).
    func sessionState() -> SessionRecord.Window? {
        guard let window, let doc = markdownDocument, !doc.isBundled else { return nil }
        var w = SessionRecord.Window()
        if let url = doc.fileURL {
            w.file = DocumentFileAccess.makeFileRef(url)
        } else {
            guard !session.text.isEmpty else { return nil }
            w.untitledText = session.storage.length <= SessionRecord.untitledTextLimit ? session.text : ""
        }
        let full = window.styleMask.contains(.fullScreen)
        let frame = (full ? windowedFrame : nil) ?? window.frame
        w.frame = [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
        w.screen = window.screen?.localizedName
        w.fullScreen = full
        w.layout = session.layout.rawValue
        w.viewMode = session.viewMode.rawValue
        w.focus = session.focusEnabled
        w.syntax = session.syntaxEnabled
        w.authorship = session.authorshipDisplay
        if let ws = workspace, ws.notesMode {
            var n = SessionRecord.Notes()
            n.selection = ws.selection
            n.expanded = ws.expanded.sorted()
            n.tags = ws.selectedTags
            n.search = ws.searchText
            n.sort = ws.sort.rawValue
            n.backlinks = ws.backlinksShown
            n.tagsCollapsed = ws.collapsedTags
            n.sidebarWidth = Double(ws.sidebarWidth)
            n.scroll = Double(ws.scrollOffset)
            w.notes = n
        }
        var c = SessionRecord.Column()
        c.shown = session.columnShown
        c.pane = session.columnPane.rawValue
        c.width = Double(session.columnWidth)
        w.column = c
        let selection = textView.selectedRange()
        w.caret = [selection.location, selection.length]
        if let top = scrollView.isHidden ? hiddenEditorTop : keptTopAnchor() {
            w.scrollCharacter = top.character
            w.scrollInto = Double(top.intoLine)
        }
        return w
    }

    /// Puts the window as the record had it: the modes, the column, the sidebar and its workspace, the frame. Done before
    /// the window is shown, so nothing jumps; the caret and the scroll wait for the layout (`restoreView`) and full screen
    /// comes last (`restoreFullScreen`).
    func restore(_ w: SessionRecord.Window) {
        guard let window else { return }
        // The frame first: the window is as large as it was before anything is put in it.
        if let f = w.frame, f.count == 4, f[2] > 0, f[3] > 0 {
            let screen = NSScreen.screens.first { $0.localizedName == w.screen } ?? window.screen ?? NSScreen.main
            var frame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if let screen { frame = window.constrainFrameRect(frame, to: screen) }
            frame.size.width = max(frame.width, window.minSize.width)
            window.setFrame(frame, display: false)
            windowedFrame = frame
        }
        if let m = w.viewMode.flatMap(ViewMode.init(rawValue:)) { session.setViewMode(m) }
        if let l = w.layout.flatMap(LayoutMode.init(rawValue:)) { session.setLayout(l) }
        if let on = w.focus { session.setFocusEnabled(on) }
        if let on = w.syntax { session.setSyntaxEnabled(on) }
        if let on = w.authorship { session.setAuthorshipDisplay(on) }
        // The column: its width first, then which pane and whether it shows (as a window taking over from another does).
        if let width = w.column?.width { session.columnWidth = CGFloat(width) }
        if let pane = w.column?.pane.flatMap(SideColumnPane.init(rawValue:)) { session.columnPane = pane }
        let shown = w.column?.shown ?? session.columnShown
        if shown != session.columnShown { session.setColumnShown(shown) } else if shown { applyColumn() }
        // The sidebar and what it shows, from the record rather than from the defaults.
        if let notes = w.notes {
            let ws = Workspace.make(settings: session.settings, notesMode: true)
            ws.restore(notes)
            adopt(ws)
            // The sidebar keeps the selection the record had; it follows the document only when the document changes.
            syncedSelectionURL = fileURL
        } else if inNotesMode {
            workspace?.setNotesMode(false)
        }
    }

    /// The caret and the scroll position, once the window has laid itself out.
    func restoreView(_ w: SessionRecord.Window, caret: Bool = true) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let length = session.storage.length
        if caret, let c = w.caret, c.count == 2 {
            let location = min(max(0, c[0]), length)
            textView.setSelectedRange(NSRange(location: location, length: min(max(0, c[1]), length - location)))
        }
        guard let character = w.scrollCharacter else { return }
        let anchor = EditorTopAnchor(character: character, intoLine: CGFloat(w.scrollInto ?? 0))
        // In the Preview layout the editor is hidden: its place is kept for when it is shown.
        if scrollView.isHidden {
            hiddenEditorTop = anchor
        } else {
            restoreEditorTop(anchor)
            let now = CFAbsoluteTimeGetCurrent()
            holdScroll(anchor, until: now + 3, since: now)
        }
    }

    /// The text above the viewport is styled after the window is up (Live mode's concealment changes the height of the
    /// lines there), which moves what is at the top: the position is taken again, every tenth of a second for a few
    /// seconds, until the person scrolls by hand or focus mode takes the scroll.
    private func holdScroll(_ anchor: EditorTopAnchor, until end: CFAbsoluteTime, since: CFAbsoluteTime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, CFAbsoluteTimeGetCurrent() < end, editorScrollView.lastUserScroll < since,
                  !scrollView.isHidden, !centring.isActive else { return }
            if let top = editorTopAnchor(), top.character != anchor.character || abs(top.intoLine - anchor.intoLine) > 2 { restoreEditorTop(anchor) }
            holdScroll(anchor, until: end, since: since)
        }
    }

    /// Full screen, last of all: the window is where it will return to when it leaves it.
    func restoreFullScreen(_ w: SessionRecord.Window) {
        guard w.fullScreen == true, let window, !window.styleMask.contains(.fullScreen) else { return }
        windowedFrame = window.frame
        window.toggleFullScreen(nil)
    }

    // MARK: the window's frame

    public func windowDidMove(_ notification: Notification) {
        noteWindowedFrame()
        recordChanged()
    }

    /// The frame a full-screen window goes back to is kept while it is not full screen.
    func noteWindowedFrame() {
        guard let window, !window.styleMask.contains(.fullScreen), !inFullScreenTransition else { return }
        windowedFrame = window.frame
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        if let window { windowedFrame = window.frame }
        inFullScreenTransition = true
    }

    public func windowWillExitFullScreen(_ notification: Notification) { inFullScreenTransition = true }
}
