import AppKit
import MarkdownCore

/// The right-hand column: one column with a segmented header (Outline | History) and one content area, in every layout,
/// never fading with the chrome. It sits beside the editor's pane in a split view of its own, which takes the place of
/// the editor's view (alone in the window, or right of the notes sidebar). One width, one toggle: View > Side Column
/// (⌃⌘O) shows and hides it, View > Show History (⌃⌘H) shows it with History selected, or hides it when History is
/// what it already shows.
extension EditorWindowController {
    @objc func toggleSideColumn(_ sender: Any?) { session.toggleOutline() }

    @objc func showHistory(_ sender: Any?) { session.toggleHistory() }

    /// The outline pane, while it is the one showing (the column makes it then and lets it go with the other's turn).
    var outline: OutlineController? { sideColumn?.outline }

    /// The history pane, while it is the one showing.
    var history: HistoryController? { sideColumn?.history }

    /// The column's view, while it is shown.
    var columnView: NSView? { sideColumn?.view }

    /// Where the column starts, as an x in the window, or nil without one.
    var columnLeft: CGFloat? {
        guard let view = columnView, view.window != nil else { return nil }
        return view.convert(NSPoint.zero, to: nil).x
    }

    /// The column's width as the session has it, whatever it shows.
    private var wantedColumnWidth: CGFloat {
        min(max(session.columnWidth, CGFloat(Settings.sideColumnWidthRange.lowerBound)), CGFloat(Settings.sideColumnWidthRange.upperBound))
    }

    /// What the column adds to the window's narrowest: nothing without it.
    var outlineMinExtra: CGFloat { session.columnShown ? wantedColumnWidth + 1 : 0 }

    /// The window as the session says: with the column and the pane it shows, or without one.
    func applyColumn() {
        guard let window else { return }
        // Moving the editor's view into or out of the column's split view takes the keyboard from it: it goes back.
        let responder = window.firstResponder as? NSView
        let editorHadTheKeyboard = responder?.isDescendant(of: root) == true
        defer {
            if editorHadTheKeyboard, let responder, responder.window === window, window.firstResponder !== responder { window.makeFirstResponder(responder) }
        }
        let wanted = session.columnShown
        if !wanted, let column = sideColumn {
            column.tearDown()
            column.view.removeFromSuperview()
            sideColumn = nil
        }
        // The window is wide enough for the column before the column is in it: the editor's pane cannot be squeezed below
        // what its own constraints need (the formatting bar), and AppKit says so with an exception from the solver.
        window.minSize.width = baseMinWidth + (inNotesMode ? CGFloat(workspace?.sidebarWidth ?? 240) + 1 : 0) + outlineMinExtra
        if window.frame.width < window.minSize.width {
            var f = window.frame
            f.size.width = window.minSize.width
            window.setFrame(f, display: true)
        }
        if wanted { installColumn(in: window) } else { removeColumnHost(in: window) }
        updateFadeGeometry()
        if session.outlineShown {
            outline?.update(session.outlineEntries)
            session.requestOutline()
            outlineLayoutChanged()
        }
        if session.historyShown { history?.reload() }
    }

    private func makeSideColumn() -> SideColumnController {
        let column = SideColumnController(pane: session.columnPane, style: SidebarStyle(session.appearance.palette))
        // The controller owns its column, so it outlives what the column makes.
        column.makeOutline = { [unowned self] in
            let o = OutlineController(style: SidebarStyle(session.appearance.palette))
            o.onJump = { [weak self] entry in self?.jump(to: entry) }
            return o
        }
        column.makeHistory = { [unowned self] in makeHistoryController() }
        column.willDrop = { [unowned column] pane in if pane == .history { column.history?.service = nil } }
        column.onChoose = { [weak self] pane in self?.session.selectColumnPane(pane, remember: true) }
        return column
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
        if let column = sideColumn {
            // Already there: another pane takes the content area; the width and the frame stay.
            if column.pane != session.columnPane { column.show(session.columnPane) }
            return
        }
        let column = makeSideColumn()
        sideColumn = column
        host.addSubview(column.view)
        let w = wantedColumnWidth
        let total = host.bounds.width
        root.frame = NSRect(x: 0, y: 0, width: max(0, total - w - 1), height: host.bounds.height)
        column.view.frame = NSRect(x: total - w, y: 0, width: w, height: host.bounds.height)
        applyingOutlineWidth = true
        host.adjustSubviews()
        applyingOutlineWidth = false
        host.needsLayout = true
        column.show(session.columnPane)
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
            session.columnWidth = view.frame.width
            session.settings.sideColumnWidth = Double(view.frame.width)
            window?.minSize.width = baseMinWidth + (inNotesMode ? CGFloat(workspace?.sidebarWidth ?? 240) + 1 : 0) + outlineMinExtra
        }
    }

    /// The column's look: the theme's colours on the column and on what it shows.
    func styleSideColumn() {
        guard let column = sideColumn else { return }
        let style = SidebarStyle(session.appearance.palette)
        column.styleChanged(style)
        if let o = column.outline, style != o.view.style {
            o.view.style = style
            o.styleChanged()
        }
        column.history?.styleChanged(style: style, diffStyle: historyDiffStyle)
    }
}
