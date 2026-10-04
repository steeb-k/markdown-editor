import AppKit
import MarkdownCore

/// The outline column: a third column on the right with the document's headings, in every layout, never
/// fading with the chrome. It sits beside the editor's pane in a split view of its own, which takes the
/// place of the editor's view (alone in the window, or right of the notes sidebar).
extension EditorWindowController {
    @objc func toggleOutline(_ sender: Any?) { session.setOutlineShown(!session.outlineShown) }

    /// Where the outline column starts, as an x in the window (the tabs end there), or nil without one.
    var outlineLeft: CGFloat? {
        guard let view = outline?.view, view.window != nil else { return nil }
        return view.convert(NSPoint.zero, to: nil).x
    }

    /// What the column adds to the window's narrowest: nothing without it.
    var outlineMinExtra: CGFloat { session.outlineShown ? session.outlineWidth + 1 : 0 }

    /// The window as the session says: with the column, or without.
    func applyOutline() {
        guard let window else { return }
        if session.outlineShown { installOutline(in: window) } else { removeOutline(in: window) }
        window.minSize.width = baseMinWidth + (inNotesMode ? CGFloat(workspace?.sidebarWidth ?? 240) + 1 : 0) + outlineMinExtra
        if window.frame.width < window.minSize.width {
            var f = window.frame
            f.size.width = window.minSize.width
            window.setFrame(f, display: true)
        }
        updateFadeGeometry()
        tabs.refresh()
        if session.outlineShown {
            outline?.update(session.outlineEntries)
            session.requestOutline()
            outlineLayoutChanged()
        }
    }

    private func installOutline(in window: NSWindow) {
        guard outline == nil else { return }
        let o = OutlineController(style: SidebarStyle(session.appearance.palette))
        o.onJump = { [weak self] entry in self?.jump(to: entry) }
        outline = o
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
        host.addSubview(o.view)
        let w = min(max(session.outlineWidth, 160), 480)
        let total = host.bounds.width
        root.frame = NSRect(x: 0, y: 0, width: max(0, total - w - 1), height: host.bounds.height)
        o.view.frame = NSRect(x: total - w, y: 0, width: w, height: host.bounds.height)
        applyingOutlineWidth = true
        host.adjustSubviews()
        applyingOutlineWidth = false
        host.needsLayout = true
    }

    private func removeOutline(in window: NSWindow) {
        guard let host = paneHost, let o = outline else { return }
        o.view.removeFromSuperview()
        outline = nil
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
        guard !applyingOutlineWidth, let o = outline else { return }
        let type = NSApp.currentEvent?.type
        if type == .leftMouseDragged || type == .leftMouseUp {
            session.outlineWidth = o.view.frame.width
            session.settings.outlineWidth = Double(o.view.frame.width)
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
