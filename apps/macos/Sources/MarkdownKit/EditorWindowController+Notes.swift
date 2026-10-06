import AppKit
import MarkdownCore

/// The window holding the sidebar and the editor side by side (notes mode). The divider is the theme's
/// rule colour, a hairline the user can drag.
final class NotesSplitView: NSSplitView {
    var tint: NSColor = .separatorColor { didSet { needsDisplay = true } }

    override var dividerColor: NSColor { tint }
}

/// Opening a file in the Finder, or recording that it was asked (the harness never opens a Finder window).
enum FileRevealer {
    nonisolated(unsafe) static var revealed: (([URL]) -> Bool)?

    static func reveal(_ urls: [URL]) {
        if let hook = revealed, hook(urls) { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

// MARK: - the workspace of a window

extension EditorWindowController {
    var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }
    var fileURL: URL? { markdownDocument?.fileURL }
    var inNotesMode: Bool { workspace?.notesMode == true }

    /// This window opens in notes mode, with a workspace of its own.
    func startNotesMode() {
        adopt(Workspace.make(settings: session.settings, notesMode: true))
    }

    func adopt(_ ws: Workspace) {
        guard workspace !== ws else { return }
        leaveWorkspace()
        workspace = ws
        ws.members.add(self)
        ws.observe(self) { [weak self] change in self?.workspaceChanged(change) }
        session.onLibraryTextChange = { [weak self] in
            guard let self, inNotesMode, let doc = markdownDocument else { return }
            workspace?.documentEdited(doc)
        }
        applyNotesMode()
    }

    /// The window no longer belongs to its workspace (it closed, or was given another).
    func leaveWorkspace(closing: Bool = false) {
        guard let ws = workspace else { return }
        ws.stopObserving(self)
        ws.members.remove(self)
        session.onLibraryTextChange = nil
        // A document closed with changes it did not save: what the library was told of them is wrong.
        if closing, let url = fileURL { ws.documentClosed(url: url, wasEdited: markdownDocument?.isDocumentEdited == true) }
        workspace = nil
        removeNotesSplit()
    }

    func workspaceChanged(_ change: Workspace.Change) {
        recordChanged()
        if change.contains(.mode) { applyNotesMode() }
        if change.contains(.layout) { applySidebarWidth() }
        sidebar?.workspaceChanged(change)
    }

    // MARK: showing the sidebar

    /// The window as the workspace says: the sidebar beside the editor, or the editor alone.
    func applyNotesMode() {
        guard let window else { return }
        let on = inNotesMode
        previewController.opensNotes = on
        previewController.onOpenNote = on ? { [weak self] target, _ in self?.openWikilink(target: target, heading: nil) } : nil
        if on {
            if notesSplit == nil { installNotesSplit(in: window) }
            window.minSize.width = baseMinWidth + CGFloat(workspace?.sidebarWidth ?? 240) + 1 + outlineMinExtra
            if window.frame.width < window.minSize.width {
                var f = window.frame
                f.size.width = window.minSize.width
                window.setFrame(f, display: true)
            }
            applySidebarWidth()
            documentBecameFront()
        } else {
            removeNotesSplit()
            window.minSize.width = baseMinWidth + outlineMinExtra
        }
        updateFadeGeometry()
        if window.isVisible || window.firstResponder != nil {
            window.makeFirstResponder(session.layout == .preview ? previewController.webView : textView)
        }
    }

    private func installNotesSplit(in window: NSWindow) {
        guard let workspace else { return }
        let split = NotesSplitView(frame: root.frame)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.tint = session.appearance.palette.rule
        // The window's content: the split view, with room over it for the palette (a view added to the split
        // view itself would become a third pane).
        let container = EditorRootView(frame: root.frame)
        container.onPointerMoved = { [weak self] in self?.chromeController.send(.pointerMoved) }
        split.frame = container.bounds
        split.autoresizingMask = [.width, .height]
        container.addSubview(split)
        let bar = SidebarController(workspace: workspace, controller: self, style: SidebarStyle(session.appearance.palette))
        sidebar = bar
        notesSplit = split
        notesContainer = container
        // The editor's own view (with the toolbar and fade over it) becomes the right-hand pane.
        window.contentView = container
        split.addSubview(bar.view)
        // The editor's pane: its own view, or the split that holds it beside the outline.
        let pane: NSView = paneHost ?? root
        split.addSubview(pane)
        let w = CGFloat(workspace.sidebarWidth)
        bar.view.frame = NSRect(x: 0, y: 0, width: w, height: split.bounds.height)
        pane.frame = NSRect(x: w + 1, y: 0, width: max(0, split.bounds.width - w - 1), height: split.bounds.height)
        split.adjustSubviews()
        workspace.requestSnapshot()
        bar.view.needsLayout = true
        refreshBacklinks()
    }

    func removeNotesSplit() {
        guard let window, let split = notesSplit else { return }
        sidebar?.view.removeFromSuperview()
        palette?.close()
        sidebar = nil
        notesSplit = nil
        let container = notesContainer
        notesContainer = nil
        let pane: NSView = paneHost ?? root
        if window.contentView === container { window.contentView = pane }
        _ = split
        pane.autoresizingMask = []
        pane.frame = window.contentView?.bounds ?? pane.frame
        pane.needsLayout = true
    }

    private func applySidebarWidth() {
        guard let split = notesSplit, let bar = sidebar?.view, let w = workspace?.sidebarWidth else { return }
        window?.minSize.width = baseMinWidth + w + 1 + outlineMinExtra
        guard abs(bar.frame.width - w) > 0.5 else { return }
        applyingSidebarWidth = true
        split.setPosition(w, ofDividerAt: 0)
        applyingSidebarWidth = false
    }

    // MARK: the document in front

    /// This window's document is the one in front: the sidebar selects its note, the backlinks panel shows
    /// what links to it.
    func documentBecameFront(force: Bool = false) {
        guard let ws = workspace, ws.notesMode else { return }
        refreshBacklinks()
        guard let url = fileURL, force || syncedSelectionURL != url else { return }
        syncedSelectionURL = url
        guard let ref = ws.library.ref(for: url) else { return }
        let id = LibraryNode.id(root: ref.root, path: ref.path)
        ws.reveal(id)
        ws.setSelection([id])
    }

    func refreshBacklinks() {
        guard let panel = sidebar?.view.backlinks, let ws = workspace else { return }
        guard ws.backlinksShown, let url = fileURL, let ref = ws.library.ref(for: url) else {
            panel.setLinks([])
            return
        }
        ws.library.backlinks(of: ref) { [weak self] links in self?.sidebar?.view.backlinks.setLinks(links) }
    }

    func focusEditor() {
        window?.makeFirstResponder(session.layout == .preview ? previewController.webView : textView)
    }

    // MARK: opening notes

    /// Opens a note: it takes the place of this window's document (which is saved and snapshotted first), or, with
    /// `newWindow`, opens in a window of its own (with a copy of this window's sidebar state). A note that is open
    /// in a window already brings that window forward. `range` or the request's cursor is selected in it.
    func openNote(_ request: NoteOpenRequest, newWindow: Bool = false, range: NSRange? = nil,
                  completion: ((MarkdownDocument?) -> Void)? = nil) {
        let place: (MarkdownDocument) -> Void = { doc in
            guard let tv = doc.session.textView else { return }
            let length = doc.session.storage.length
            if let range, NSMaxRange(range) <= length {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
            } else if let c = request.cursor, c <= length {
                tv.setSelectedRange(NSRange(location: c, length: 0))
                tv.scrollRangeToVisible(NSRange(location: c, length: 0))
            }
        }
        if let existing = NSDocumentController.shared.document(for: request.url) as? MarkdownDocument {
            bringForward(existing)
            place(existing)
            completion?(existing)
            return
        }
        guard let ws = workspace, ws.notesMode else {
            // Not in notes mode: a note opens as any file does.
            NSDocumentController.shared.openDocument(withContentsOf: request.url, display: true) { doc, _, error in
                if let error { NSAlert(error: error).runModal() }
                if let doc = doc as? MarkdownDocument { place(doc) }
                completion?(doc as? MarkdownDocument)
            }
            return
        }
        // An untitled document nobody has typed in is what a note replaces, as it would in any other app.
        let reuse = markdownDocument.map { $0.fileURL == nil && !$0.isDocumentEdited && $0.session.storage.length == 0 } ?? false
        let replace = !newWindow || reuse
        let start = { [self] in
            NSDocumentController.shared.openDocument(withContentsOf: request.url, display: false) { [self] doc, _, error in
                guard let doc = doc as? MarkdownDocument else {
                    if let error, let window { WorkspacePrompts.report(error, window: window) }
                    completion?(nil)
                    return
                }
                // The window takes this one's workspace (the sidebar stays as it was), or starts from a copy of it.
                doc.inheritedWorkspace = replace ? ws : ws.copy()
                doc.makeWindowControllers()
                guard let wc = doc.windowControllers.first as? EditorWindowController, let newWindow = wc.window else {
                    completion?(doc)
                    return
                }
                let leaving = replace ? markdownDocument : nil
                if leaving != nil { wc.takeOver(from: self) }
                doc.showWindows()
                newWindow.makeKeyAndOrderFront(nil)
                place(doc)
                wc.documentBecameFront()
                wc.sidebar?.consumePendingRename()
                if let leaving { wc.finishReplacing(leaving) }
                completion?(doc)
            }
        }
        if replace, let doc = markdownDocument {
            doc.settleForLeaving { ok in if ok { start() } else { completion?(nil) } }
        } else {
            start()
        }
    }

    /// This window stands in for the one `old` is in: the same place and size, the same workspace (so the sidebar is as it
    /// was), the same layout and column, and no animation, so that the document seems to change in the window.
    func takeOver(from old: EditorWindowController) {
        guard let window, let oldWindow = old.window else { return }
        window.animationBehavior = .none
        window.setFrame(oldWindow.frame, display: false)
        // What the window was showing it still shows: the layout, the tools.
        let was = old.session
        session.setLayout(was.layout)
        session.setFocusEnabled(was.focusEnabled)
        session.setSyntaxEnabled(was.syntaxEnabled)
        session.setAuthorshipDisplay(was.authorshipDisplay)
        // The column: its width first, then which pane and whether it shows (the pane without touching the default setting).
        session.columnWidth = was.columnWidth
        session.columnPane = was.columnPane
        if was.columnShown != session.columnShown { session.setColumnShown(was.columnShown) }
        else if session.columnShown { applyColumn() }
        replacedFullScreen = oldWindow.styleMask.contains(.fullScreen)
    }

    /// The old document's window closes (the document was settled before), and the new one is the window now.
    func finishReplacing(_ old: MarkdownDocument) {
        old.windowControllers.first?.window?.animationBehavior = .none
        // A key that reached the old window after it was settled (while the note was read, or while its own write was
        // finishing) is written and snapshotted too before it goes; closing would drop it.
        if old.isDocumentEdited || old.autosaveTimer?.isValid == true {
            old.settleForLeaving { ok in if ok { old.close() } }
        } else {
            old.close()
        }
        window?.makeKeyAndOrderFront(nil)
        window?.animationBehavior = .default
        if replacedFullScreen, window?.styleMask.contains(.fullScreen) == false { window?.toggleFullScreen(nil) }
        replacedFullScreen = false
    }

    /// Brings an open document's window to the front.
    func bringForward(_ doc: MarkdownDocument) {
        guard let w = doc.windowControllers.first?.window else {
            doc.showWindows()
            return
        }
        w.makeKeyAndOrderFront(nil)
        (w.windowController as? EditorWindowController)?.documentBecameFront(force: true)
    }

    func openBacklink(_ link: NoteBacklink, newWindow: Bool = false) {
        guard let url = workspace?.library.url(for: link.from) else { return }
        openNote(NoteOpenRequest(url: url), newWindow: newWindow, range: NSRange(location: Int(link.range.start), length: Int(link.range.end - link.range.start)))
    }

    // MARK: wikilinks

    /// Cmd-click on `[[target#heading]]` (or a click on one in the preview): the note it names replaces this
    /// window's document (Cmd-Option-click: opens in a window of its own); with no such note, the user is offered
    /// `target.md` beside this one.
    func openWikilink(target: String, heading: String?, newWindow: Bool = false) {
        let name = WikilinkResolver.name(of: target)
        let open: (URL) -> Void = { [self] url in
            if let ws = workspace, ws.notesMode {
                openNote(NoteOpenRequest(url: url), newWindow: newWindow) { [weak self] doc in
                    guard let heading, let doc, let self, let ref = ws.library.ref(for: url) else { return }
                    ws.library.meta(of: ref) { meta in
                        guard let h = meta?.headings.first(where: { $0.text.caseInsensitiveCompare(heading) == .orderedSame }),
                              let tv = doc.session.textView else { return }
                        let r = NSRange(location: Int(h.range.start), length: 0)
                        if r.location <= doc.session.storage.length { tv.setSelectedRange(r); tv.scrollRangeToVisible(r) }
                        _ = self
                    }
                }
            } else {
                LinkOpener.open(url)
            }
        }
        let missing: () -> Void = { [self] in offerToCreate(note: name) }
        if let ws = workspace, ws.notesMode, let from = referenceNote(in: ws) {
            ws.library.resolve(name, from: from) { [self] ref in
                if let ref, let url = ws.library.url(for: ref) { open(url) }
                else if let url = WikilinkResolver.resolve(name, besides: fileURL) { open(url) }
                else { _ = self; missing() }
            }
        } else if let url = WikilinkResolver.resolve(name, besides: fileURL) {
            open(url)
        } else {
            missing()
        }
    }

    /// The note links are resolved from: this window's, or the library's top when the document is not in it.
    private func referenceNote(in ws: Workspace) -> NoteRef? {
        if let url = fileURL, let ref = ws.library.ref(for: url) { return ref }
        return ws.primaryRoot.map { NoteRef(root: $0.id, path: "x.md") }
    }

    private func offerToCreate(note name: String) {
        guard !name.isEmpty, let file = NoteNaming.fileName(from: (name as NSString).lastPathComponent) else { NSSound.beep(); return }
        let folder = fileURL?.deletingLastPathComponent() ?? workspace?.primaryRoot?.url
        guard let folder else { NSSound.beep(); return }
        let base = (file as NSString).deletingPathExtension.isEmpty ? file : (DocumentFileAccess.isNote(URL(fileURLWithPath: file)) ? (file as NSString).deletingPathExtension : file)
        // A name Finder shows with a colon is a file with a dash: the note is there already.
        let existing = folder.appendingPathComponent(base).appendingPathExtension("md")
        if DocumentFileAccess.exists(existing) {
            if inNotesMode { openNote(NoteOpenRequest(url: existing)) } else { LinkOpener.open(existing) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Create \u{201C}\(base).md\u{201D}?"
        alert.informativeText = "No note called \u{201C}\(name)\u{201D} was found. It can be made next to this one."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let create: (NSApplication.ModalResponse) -> Void = { [self] r in
            guard r == .alertFirstButtonReturn else { return }
            do {
                let url = try DocumentFileAccess.writeNew(Data(), in: folder, name: base, ext: "md")
                workspace?.library.refresh([url])
                if inNotesMode { openNote(NoteOpenRequest(url: url)) } else { LinkOpener.open(url) }
            } catch {
                if let window { WorkspacePrompts.report(error, window: window) }
            }
        }
        if let window, window.isVisible, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: create) } else { create(alert.runModal()) }
    }

    // MARK: making, renaming, moving

    /// File > New in notes mode: an empty `Untitled.md` in the selected folder, opened, and named in the sidebar.
    @objc func newDocument(_ sender: Any?) {
        guard inNotesMode else { NSDocumentController.shared.newDocument(sender); return }
        newNote()
    }

    func newNote(fromTemplate template: URL? = nil) {
        guard let ws = workspace, ws.notesMode, ensureLibrary() else { return }
        do {
            let request = try template.map { try ws.newNote(fromTemplate: $0) } ?? NoteOpenRequest(url: try ws.createNote(), cursor: nil)
            if let ref = ws.library.ref(for: request.url) { ws.pendingRename = LibraryNode.id(root: ref.root, path: ref.path) }
            openNote(request)
        } catch {
            if let window { WorkspacePrompts.report(error, window: window) }
        }
    }

    /// There is a folder to put notes in; otherwise the sidebar's invitation to make one shows.
    private func ensureLibrary() -> Bool {
        guard let ws = workspace else { return false }
        if !ws.library.roots.isEmpty { return true }
        NSSound.beep()
        return false
    }

    @objc func newFolder(_ sender: Any?) {
        guard let ws = workspace, ws.notesMode, ensureLibrary() else { return }
        do {
            let url = try ws.createFolder()
            if let ref = ws.library.ref(for: url) {
                let id = LibraryNode.id(root: ref.root, path: ref.path)
                ws.pendingRename = id
                sidebar?.consumePendingRename()
            }
        } catch {
            if let window { WorkspacePrompts.report(error, window: window) }
        }
    }

    @objc func todaysNote(_ sender: Any?) {
        guard let ws = workspace, ws.notesMode, ensureLibrary() else { return }
        do { openNote(try ws.todaysNote()) } catch { if let window { WorkspacePrompts.report(error, window: window) } }
    }

    @objc func newFromTemplate(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        newNote(fromTemplate: url)
    }

    @objc func chooseTemplate(_ sender: Any?) {
        guard let ws = workspace, ws.notesMode, let style = sidebar?.style, let host = notesContainer else { return }
        let templates = ws.templates()
        palette?.close()
        let p = PaletteController(placeholder: "New from template", style: style, source: { query, deliver in
            let q = query.lowercased()
            let rows = templates.filter { q.isEmpty || $0.deletingPathExtension().lastPathComponent.lowercased().contains(q) }
                .map { PaletteRow(title: $0.deletingPathExtension().lastPathComponent, detail: $0.deletingLastPathComponent().lastPathComponent, key: $0.path) }
            deliver(rows)
        }, choose: { [weak self] row, _ in self?.newNote(fromTemplate: URL(fileURLWithPath: row.key)) })
        p.onClose = { [weak self] in self?.focusEditor(); self?.palette = nil }
        palette = p
        p.show(over: host)
    }

    @objc func renameSelection(_ sender: Any?) { sidebar?.beginRenameOfSelection() }

    /// Renames or moves a note or folder, asking about the links that point at it.
    func rename(_ node: LibraryNode, to typed: String, completion: @escaping () -> Void) {
        guard let ws = workspace, let new = NoteNaming.renamed(node.url, to: typed) else { completion(); return }
        ws.move(node.url, to: new, window: window) { [weak self] result in
            switch result {
            case .success(let url?):
                if let ref = ws.library.ref(for: url) { ws.setSelection([LibraryNode.id(root: ref.root, path: ref.path)]) }
            case .success(nil): break
            case .failure(let error):
                if let window = self?.window { WorkspacePrompts.report(error, window: window) }
            }
            completion()
        }
    }

    func moveItems(_ urls: [URL], into folder: URL) {
        guard let ws = workspace else { return }
        var queue = urls
        func next() {
            guard !queue.isEmpty else { return }
            let old = queue.removeFirst()
            let isDir = DocumentFileAccess.isDirectory(old)
            let target = DocumentFileAccess.uniqueName(in: folder, base: isDir ? old.lastPathComponent : old.deletingPathExtension().lastPathComponent,
                                                       ext: isDir ? "" : old.pathExtension)
            ws.move(old, to: target, window: window) { [weak self] result in
                if case .failure(let error) = result, let window = self?.window { WorkspacePrompts.report(error, window: window) }
                if case .success(let url?) = result, let ref = ws.library.ref(for: url) {
                    ws.setSelection([LibraryNode.id(root: ref.root, path: ref.path)])
                }
                next()
            }
        }
        next()
    }

    func copyItems(_ urls: [URL], into folder: URL) {
        workspace?.copyIn(urls, to: folder) { _ in }
    }

    @objc func duplicateSelection(_ sender: Any?) {
        guard let ws = workspace, let node = sidebar?.selectedNodes().first, node.kind != .root else { return }
        do {
            let url = try ws.duplicate(node)
            if let ref = ws.library.ref(for: url) { ws.setSelection([LibraryNode.id(root: ref.root, path: ref.path)]) }
        } catch {
            if let window { WorkspacePrompts.report(error, window: window) }
        }
    }

    @objc func trashSelection(_ sender: Any?) {
        guard let ws = workspace, let nodes = sidebar?.selectedNodes().filter({ $0.kind != .root }), !nodes.isEmpty else { return }
        ws.trash(nodes.map(\.url), window: window) { _ in }
    }

    /// The context menu's Move to Trash: the menu itself says what it acts on, so the keyboard's place does not matter.
    @objc func trashFromContextMenu(_ sender: Any?) { trashSelection(sender) }

    @objc func revealSelection(_ sender: Any?) {
        guard let nodes = sidebar?.selectedNodes(), !nodes.isEmpty else { return }
        FileRevealer.reveal(nodes.map(\.url))
    }

    // MARK: the library's folders

    func createDefaultLibrary() {
        guard let ws = workspace else { return }
        let url = DocumentFileAccess.defaultLibraryURL
        do {
            try DocumentFileAccess.ensureFolder(url)
            ws.setLibraryFolder(url)
        } catch {
            if let window { WorkspacePrompts.report(error, window: window) }
        }
    }

    @objc func chooseLibraryFolder(_ sender: Any?) {
        chooseFolder(message: "Choose the folder your notes live in.") { [weak self] url in self?.workspace?.setLibraryFolder(url) }
    }

    @objc func addFolderToLibrary(_ sender: Any?) {
        chooseFolder(message: "Choose a folder to add to the library.") { [weak self] url in self?.workspace?.addRoot(url) }
    }

    private func chooseFolder(message: String, _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        let handle: (NSApplication.ModalResponse) -> Void = { r in if r == .OK, let url = panel.url { done(url) } }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    @objc func removeSelectedFolderFromLibrary(_ sender: Any?) {
        guard let node = sidebar?.selectedNodes().first, node.kind == .root, node.root != LibraryRootInfo.libraryID else { return }
        workspace?.removeRoot(id: node.root)
    }

    // MARK: menu actions

    @objc func toggleNotesMode(_ sender: Any?) {
        if let ws = workspace {
            ws.setNotesMode(!ws.notesMode)
        } else {
            let ws = Workspace.make(settings: session.settings, notesMode: true)
            adopt(ws)
        }
    }

    @objc func toggleBacklinks(_ sender: Any?) {
        guard let ws = workspace, ws.notesMode else { return }
        ws.setBacklinksShown(!ws.backlinksShown)
    }

    @objc func searchLibrary(_ sender: Any?) {
        guard inNotesMode else { return }
        sidebar?.focusSearch()
    }

    @objc func sortNotesByName(_ sender: Any?) { workspace?.setSort(.name) }
    @objc func sortNotesByModified(_ sender: Any?) { workspace?.setSort(.modified) }

    /// ⇧⌘O: type a few letters of a note's title or path, arrow to it, Return.
    @objc func quickOpen(_ sender: Any?) {
        guard let ws = workspace, ws.notesMode, let style = sidebar?.style, let host = notesContainer else { return }
        if palette?.isOpen == true { palette?.close(); return }
        let p = PaletteController(placeholder: "Open note", style: style, source: { query, deliver in
            ws.library.quickOpen(query) { matches in
                deliver(matches.map { m in
                    PaletteRow(title: m.title, detail: m.note.path,
                               titleRanges: m.titleRanges.map { NSRange(location: Int($0.start), length: Int($0.end - $0.start)) },
                               detailRanges: m.pathRanges.map { NSRange(location: Int($0.start), length: Int($0.end - $0.start)) },
                               key: "\(m.note.root)\n\(m.note.path)")
                })
            }
        }, choose: { [weak self] row, alternate in
            let parts = row.key.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2, let url = ws.library.url(for: NoteRef(root: parts[0], path: parts[1])) else { return }
            self?.openNote(NoteOpenRequest(url: url), newWindow: alternate)
        })
        p.onClose = { [weak self] in self?.focusEditor(); self?.palette = nil }
        palette = p
        p.show(over: host)
    }

    /// Menu validation for the actions above.
    func validateNotesItem(_ item: NSMenuItem) -> Bool {
        let on = inNotesMode
        let selection = sidebar?.selectedNodes() ?? []
        switch item.action {
        case #selector(toggleNotesMode(_:)):
            item.state = on ? .on : .off
            return true
        case #selector(toggleBacklinks(_:)):
            item.title = workspace?.backlinksShown == true ? "Hide Backlinks" : "Show Backlinks"
            return on
        case #selector(sortNotesByName(_:)):
            item.state = workspace?.sort == .name ? .on : .off
            return on
        case #selector(sortNotesByModified(_:)):
            item.state = workspace?.sort == .modified ? .on : .off
            return on
        case #selector(newDocument(_:)):
            item.title = on ? "New Note" : "New"
            return true
        case #selector(newFolder(_:)), #selector(todaysNote(_:)), #selector(chooseTemplate(_:)), #selector(quickOpen(_:)), #selector(searchLibrary(_:)),
             #selector(addFolderToLibrary(_:)), #selector(chooseLibraryFolder(_:)):
            return on
        case #selector(renameSelection(_:)), #selector(duplicateSelection(_:)):
            return on && selection.count == 1 && selection[0].kind != .root
        case #selector(trashSelection(_:)):
            return on && selection.contains { $0.kind != .root }
        case #selector(trashFromContextMenu(_:)):
            return on && selection.contains { $0.kind != .root }
        case #selector(revealSelection(_:)):
            return on && !selection.isEmpty
        case #selector(removeSelectedFolderFromLibrary(_:)):
            return on && selection.count == 1 && selection[0].kind == .root && selection[0].root != LibraryRootInfo.libraryID
        case #selector(newFromTemplate(_:)):
            return on
        default:
            return true
        }
    }
}

// MARK: - the divider

extension EditorWindowController: NSSplitViewDelegate {
    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // The outline's divider: the editor's pane keeps its room, the column its 480 at most.
        if splitView === paneHost { return max(baseMinWidth, splitView.bounds.width - 1 - CGFloat(Settings.sideColumnWidthRange.upperBound)) }
        return 160
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // The column no narrower than a new window would start it (what the setting keeps).
        if splitView === paneHost { return max(baseMinWidth, splitView.bounds.width - 1 - CGFloat(Settings.sideColumnWidthRange.lowerBound)) }
        return min(480, max(160, splitView.bounds.width - 320))
    }

    /// A window's resize is the editor's: the sidebar and the outline keep their widths.
    public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        splitView === paneHost ? view !== columnView : view !== sidebar?.view
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        if (notification.object as? NSSplitView) === paneHost {
            outlineDividerMoved()
            return
        }
        guard !applyingSidebarWidth, let bar = sidebar?.view, let workspace else { return }
        // Only the user's drag of the divider (a window's resize leaves the sidebar's width alone).
        if NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .leftMouseUp {
            workspace.setSidebarWidth(bar.frame.width)
        }
    }
}

// MARK: - resolving wikilinks without a library

/// The names a wikilink can have, and, with no library (plain mode, or a note outside every root), the
/// note it names in the folder of the document it is written in.
public enum WikilinkResolver {
    /// What a link's target says without the `|label` and `#heading` the core already took off, and
    /// without the `./` the preview adds.
    public static func name(of target: String) -> String {
        var t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("./") { t.removeFirst(2) }
        return t
    }

    /// The note `name` is beside `document`: a file of that name (with any note extension, or already with
    /// one), compared without regard to case, in the document's folder; `folder/Name` goes down into folders.
    public static func resolve(_ name: String, besides document: URL?) -> URL? {
        guard let document, !name.isEmpty, !name.hasPrefix("/"), !name.contains("../") else { return nil }
        let parts = name.split(separator: "/").map(String.init)
        guard let last = parts.last else { return nil }
        var dir = document.deletingLastPathComponent()
        for p in parts.dropLast() {
            guard let next = match(p, in: dir, folders: true) else { return nil }
            dir = next
        }
        let stem = DocumentFileAccess.isNote(URL(fileURLWithPath: last)) ? (last as NSString).deletingPathExtension : last
        return match(stem, in: dir, folders: false)
    }

    private static func match(_ stem: String, in dir: URL, folders: Bool) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let want = stem.lowercased()
        // The exact name first, then any note extension, then another case.
        let candidates = names.sorted().filter { !DocumentFileAccess.isSkipped(name: $0) }
        for n in candidates {
            let u = dir.appendingPathComponent(n)
            if folders {
                if n.lowercased() == want, DocumentFileAccess.isDirectory(u) { return u }
            } else if DocumentFileAccess.isNote(u), (n as NSString).deletingPathExtension.lowercased() == want, !DocumentFileAccess.isDirectory(u) {
                return u
            }
        }
        return nil
    }
}

// MARK: - File > New from Template

/// Fills the submenu with the templates of the library the front window has.
final class TemplateMenuDelegate: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static let shared = TemplateMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The first item (Choose Template…) stays; the rest are the templates.
        while menu.items.count > 1 { menu.removeItem(at: menu.items.count - 1) }
        let front = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? EditorWindowController
        let templates = front?.workspace?.notesMode == true ? front?.workspace?.templates() ?? [] : []
        menu.addItem(.separator())
        if templates.isEmpty {
            let none = NSMenuItem(title: "No Templates", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for t in templates {
            let item = NSMenuItem(title: t.deletingPathExtension().lastPathComponent, action: #selector(EditorWindowController.newFromTemplate(_:)), keyEquivalent: "")
            item.representedObject = t
            menu.addItem(item)
        }
    }
}
