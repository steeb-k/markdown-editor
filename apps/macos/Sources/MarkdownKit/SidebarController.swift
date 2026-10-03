import AppKit
import MarkdownCore

/// Draws a window's sidebar from its workspace and turns what the user does there into workspace
/// and window changes. Each window of a tab group has one; they all read the same `Workspace`, so
/// they look alike at every moment.
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate,
                               NSMenuDelegate, NSTextFieldDelegate {
    let view: SidebarView
    private(set) var workspace: Workspace
    private weak var controller: EditorWindowController?

    private var items: [SidebarItem] = []
    private var index: [String: SidebarItem] = [:]
    private var drawn: LibrarySnapshot?
    private var isReloading = false
    private var isSyncing = false
    private var applyingScroll = false
    private var renaming: (item: SidebarItem, cell: SidebarCellView, thenEditor: Bool)?
    private var scrollObserver: NSObjectProtocol?
    private var reloadWaiting = false

    /// Instrumentation: how many times the outline was reloaded and how many snapshots changed
    /// nothing it draws (the harness reports them).
    private(set) var reloads = 0
    private(set) var skippedReloads = 0

    var outline: SidebarOutlineView { view.outline }
    var style: SidebarStyle { view.style }

    init(workspace: Workspace, controller: EditorWindowController, style: SidebarStyle) {
        self.workspace = workspace
        self.controller = controller
        view = SidebarView(style: style)
        super.init()
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.onReturn = { [weak self] in self?.beginRenameOfSelection() }
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        view.searchField.delegate = self
        view.emptyState.make.target = self
        view.emptyState.make.action = #selector(createDefaultLibrary(_:))
        view.emptyState.choose.target = self
        view.emptyState.choose.action = #selector(chooseLibraryFolder(_:))
        view.backlinks.onOpen = { [weak self] link in self?.controller?.openBacklink(link) }
        let clip = view.scroll.contentView
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            guard let self, !applyingScroll, !isReloading else { return }
            workspace.setScrollOffset(view.scroll.contentView.bounds.minY)
        }
        view.showsBacklinks = workspace.backlinksShown
        reload(force: true)
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func setWorkspace(_ w: Workspace) {
        workspace = w
        view.showsBacklinks = w.backlinksShown
        reload(force: true)
    }

    // MARK: following the workspace

    func workspaceChanged(_ change: Workspace.Change) {
        if change.contains(.snapshot) { reload() }
        if change.contains(.expansion) { applyExpansion() }
        if change.contains(.selection) { applySelection() }
        if change.contains(.filters) { applyFilters() }
        if change.contains(.layout) {
            view.showsBacklinks = workspace.backlinksShown
            view.needsLayout = true
        }
        if change.contains(.scroll) { applyScroll() }
        if change.contains(.backlinks) { controller?.refreshBacklinks() }
    }

    private func applyFilters() {
        if view.window?.firstResponder !== view.searchField.currentEditor(), view.searchField.stringValue != workspace.searchText {
            view.searchField.stringValue = workspace.searchText
        }
    }

    private func applyScroll() {
        let clip = view.scroll.contentView
        guard abs(clip.bounds.minY - workspace.scrollOffset) > 0.5 else { return }
        applyingScroll = true
        clip.scroll(to: NSPoint(x: 0, y: workspace.scrollOffset))
        view.scroll.reflectScrolledClipView(clip)
        applyingScroll = false
    }

    /// The theme changed: every row is drawn again in the new colours.
    func styleChanged() {
        view.emptyState.style = style
        view.backlinks.style = style
        reload(force: true)
    }

    // MARK: reloading

    /// Draws the workspace's snapshot: the rows, what is open, what is selected, where the list is
    /// scrolled. A snapshot that draws as the last one did changes nothing.
    func reload(force: Bool = false) {
        let snapshot = workspace.snapshot
        view.showsEmptyState = workspace.library.roots.isEmpty && !workspace.library.isLoading
        // A name being typed is not taken away by a reload: the tree is drawn when the edit ends.
        if renaming != nil, !force { reloadWaiting = true; return }
        if !force, let drawn, drawn.drawsSameAs(snapshot) { skippedReloads += 1; return }
        drawn = snapshot
        reloads += 1
        let scrollY = workspace.scrollOffset
        isReloading = true
        items = SidebarModel.items(for: snapshot, reuse: index)
        index = SidebarModel.index(items)
        outline.reloadData()
        expandOpenFolders()
        isReloading = false
        applySelection()
        applyingScroll = true
        let clip = view.scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: scrollY))
        view.scroll.reflectScrolledClipView(clip)
        applyingScroll = false
        DispatchQueue.main.async { [weak self] in self?.consumePendingRename() }
    }

    /// A note or folder the user just made starts being renamed in the sidebar of the window in front.
    func consumePendingRename() {
        guard let id = workspace.pendingRename, index[id] != nil, let window = view.window,
              window.tabGroup?.selectedWindow == nil || window.tabGroup?.selectedWindow === window else { return }
        workspace.pendingRename = nil
        beginRename(id: id, thenEditor: true)
    }

    /// Everything is open while the tree is filtered or searched (the matches are the point); otherwise
    /// what the user opened.
    private func shouldBeOpen(_ item: SidebarItem) -> Bool {
        switch item.kind {
        case .node(let n):
            if n.kind == .root { return workspace.expanded.contains(n.id) || !workspace.selectedTags.isEmpty }
            return workspace.expanded.contains(n.id) || !workspace.selectedTags.isEmpty
        case .tagsHeader: return !workspace.collapsedTags
        default: return false
        }
    }

    private func expandOpenFolders() {
        func walk(_ list: [SidebarItem]) {
            for i in list where i.isExpandable {
                if shouldBeOpen(i) {
                    if !outline.isItemExpanded(i) { outline.expandItem(i) }
                    walk(i.children)
                } else if outline.isItemExpanded(i) {
                    outline.collapseItem(i)
                }
            }
        }
        walk(items)
    }

    private func applyExpansion() {
        isReloading = true
        expandOpenFolders()
        isReloading = false
        applySelection()
    }

    private func applySelection() {
        var rows = IndexSet()
        for id in workspace.selection {
            if let item = index[id] {
                let r = outline.row(forItem: item)
                if r >= 0 { rows.insert(r) }
            }
        }
        guard rows != outline.selectedRowIndexes else { return }
        isSyncing = true
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        isSyncing = false
        if let first = rows.first, rows.count == 1 { outline.scrollRowToVisible(first) }
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? items.count
    }

    func outlineView(_ outlineView: NSOutlineView, child i: Int, ofItem item: Any?) -> Any {
        (item as? SidebarItem)?.children[i] ?? items[i]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SidebarItem)?.isExpandable ?? false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let i = item as? SidebarItem else { return 24 }
        if case .hit = i.kind { return 50 }
        if case .tagsHeader = i.kind { return 26 }
        return 24
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SidebarItem)?.isSelectable ?? false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("row"), owner: nil) as? SidebarRowView) ?? SidebarRowView(style: style)
        row.identifier = NSUserInterfaceItemIdentifier("row")
        row.style = style
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let i = item as? SidebarItem else { return nil }
        if case .tagsHeader = i.kind {
            let h = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("header"), owner: nil) as? SidebarHeaderView) ?? SidebarHeaderView(style: style)
            h.identifier = NSUserInterfaceItemIdentifier("header")
            h.style = style
            h.clear.target = self
            h.clear.action = #selector(clearTags(_:))
            h.clear.isHidden = workspace.selectedTags.isEmpty
            return h
        }
        let cell = (outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? SidebarCellView) ?? SidebarCellView(style: style)
        cell.identifier = NSUserInterfaceItemIdentifier("cell")
        var active = false
        if case .tag(let name, _) = i.kind { active = workspace.selectedTags.contains(name) }
        cell.configure(i, style: style, tagActive: active, workspace: workspace)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, !isSyncing else { return }
        let ids = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
        workspace.setSelection(ids)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading, let i = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        if case .tagsHeader = i.kind { workspace.setTagsCollapsed(false) } else if let n = i.node { workspace.setExpanded(n.id, true) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading, let i = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        if case .tagsHeader = i.kind { workspace.setTagsCollapsed(true) } else if let n = i.node { workspace.setExpanded(n.id, false) }
    }

    // MARK: clicks

    @objc private func rowClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        activate(item, replacing: mods.contains(.option), extending: !mods.intersection([.command, .shift]).isEmpty)
    }

    /// What a click on a row does: a note opens (in a new tab, or replacing the current tab's document with
    /// Option), a folder opens or closes, a tag filters, another file opens in its own app.
    func activate(_ item: SidebarItem, replacing: Bool = false, extending: Bool = false) {
        switch item.kind {
        case .tag(let name, _):
            workspace.toggleTag(name)
        case .tagsHeader:
            if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        case .hit(let h):
            guard !extending, let url = workspace.library.url(for: h.note) else { return }
            controller?.openNote(NoteOpenRequest(url: url), replacing: replacing)
        case .node(let n):
            guard !extending else { return }
            switch n.kind {
            case .note: controller?.openNote(NoteOpenRequest(url: n.url), replacing: replacing)
            case .other: LinkOpener.open(n.url)
            case .root, .folder: if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
            }
        case .message: break
        }
    }

    @objc private func clearTags(_ sender: Any?) { workspace.clearTags() }

    @objc private func createDefaultLibrary(_ sender: Any?) { controller?.createDefaultLibrary() }
    @objc private func chooseLibraryFolder(_ sender: Any?) { controller?.chooseLibraryFolder(sender) }

    // MARK: selection

    /// The nodes (folders, notes, files) selected, in the list's order.
    func selectedNodes() -> [LibraryNode] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.node }
    }

    func selectedHitNotes() -> [NoteRef] {
        outline.selectedRowIndexes.compactMap { row in
            if case .hit(let h)? = (outline.item(atRow: row) as? SidebarItem)?.kind { return h.note }
            return nil
        }
    }

    // MARK: search

    func focusSearch() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view.searchField)
        view.searchField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === view.searchField else { return }
        workspace.setSearch(view.searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === view.searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape: the search is cleared; a second Escape leaves the field.
            if view.searchField.stringValue.isEmpty {
                controller?.focusEditor()
            } else {
                view.searchField.stringValue = ""
                workspace.setSearch("")
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Return opens the best hit.
            if let first = items.first, case .hit = first.kind { activate(first) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if items.contains(where: \.isSelectable) {
                view.window?.makeFirstResponder(outline)
                if let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? SidebarItem)?.isSelectable == true }) {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
            return true
        default: return false
        }
    }

    // MARK: renaming

    func beginRenameOfSelection() {
        guard let node = selectedNodes().first, node.kind != .root else { return }
        beginRename(id: node.id, thenEditor: false)
    }

    func beginRename(id: String, thenEditor: Bool) {
        guard let item = index[id], let node = item.node, node.kind != .root, let window = view.window else { return }
        workspace.reveal(id)
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView else { return }
        renaming = (item, cell, thenEditor)
        cell.label.isEditable = true
        cell.label.isSelectable = true
        cell.label.delegate = self
        cell.label.focusRingType = .default
        window.makeFirstResponder(cell.label)
        cell.label.currentEditor()?.selectAll(nil)
    }

    var isRenaming: Bool { renaming != nil }

    /// Ends the edit as if the user pressed Return with `text` typed (the harness's way of typing a name).
    func commitRename(_ text: String) {
        guard let r = renaming else { return }
        r.cell.label.stringValue = text
        finishRename(commit: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let r = renaming, field === r.cell.label else { return }
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        finishRename(commit: movement != .cancel)
    }

    private func finishRename(commit: Bool) {
        guard let r = renaming else { return }
        renaming = nil
        defer { if reloadWaiting { reloadWaiting = false; DispatchQueue.main.async { [weak self] in self?.reload() } } }
        let typed = r.cell.label.stringValue
        r.cell.label.isEditable = false
        r.cell.label.delegate = nil
        guard let node = r.item.node else { return }
        // The row says what it said before until the rename has happened.
        r.cell.label.stringValue = node.name
        let focusAfter = { [weak self] in
            guard let self else { return }
            if r.thenEditor { controller?.focusEditor() } else { view.window?.makeFirstResponder(outline) }
        }
        guard commit, typed != node.name, !typed.isEmpty else { focusAfter(); return }
        controller?.rename(node, to: typed) { [weak self] in
            self?.view.window?.makeFirstResponder(nil)
            focusAfter()
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let c = controller else { return }
        let nodes = selectedNodes()
        func add(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = c
            menu.addItem(i)
        }
        if let first = nodes.first, nodes.count == 1, first.kind == .note {
            let open = NSMenuItem(title: "Open", action: #selector(openFromMenu(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = first.id
            menu.addItem(open)
            menu.addItem(.separator())
        }
        if let first = nodes.first, nodes.count == 1, first.kind == .root, first.root != LibraryRootInfo.libraryID {
            add("Remove from Library", #selector(EditorWindowController.removeSelectedFolderFromLibrary(_:)))
            menu.addItem(.separator())
        }
        if nodes.isEmpty || nodes.allSatisfy({ $0.isFolder || $0.kind == .note }) {
            add("New Note", #selector(EditorWindowController.newDocument(_:)))
            add("New Folder", #selector(EditorWindowController.newFolder(_:)))
            if !nodes.isEmpty { menu.addItem(.separator()) }
        }
        if !nodes.isEmpty {
            if nodes.count == 1, nodes[0].kind != .root { add("Rename", #selector(EditorWindowController.renameSelection(_:))) }
            if nodes.count == 1, nodes[0].kind != .root { add("Duplicate", #selector(EditorWindowController.duplicateSelection(_:))) }
            add("Reveal in Finder", #selector(EditorWindowController.revealSelection(_:)))
            if nodes.contains(where: { $0.kind != .root }) {
                menu.addItem(.separator())
                add("Move to Trash", #selector(EditorWindowController.trashFromContextMenu(_:)))
            }
        }
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let n = index[id]?.node else { return }
        controller?.openNote(NoteOpenRequest(url: n.url), replacing: false)
    }

    // MARK: dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let i = item as? SidebarItem, case .node(let n) = i.kind, n.kind != .root else { return nil }
        return n.url as NSURL
    }

    private func dropFolder(for item: Any?) -> SidebarItem? {
        guard var target = item as? SidebarItem else { return nil }
        if target.node?.isFolder != true {
            guard let parent = outline.parent(forItem: target) as? SidebarItem else { return nil }
            target = parent
        }
        return target.node?.isFolder == true ? target : nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard !workspace.query.isSearching, let folder = dropFolder(for: item), let target = folder.node else { return [] }
        outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let local = (info.draggingSource as? NSOutlineView) === outlineView
        if local {
            // Not into itself or where it already is.
            let urls = droppedURLs(info.draggingPasteboard)
            let canonicalTarget = DocumentFileAccess.canonical(target.url).path
            for u in urls {
                let c = DocumentFileAccess.canonical(u)
                if c.deletingLastPathComponent().path == canonicalTarget { return [] }
                if canonicalTarget == c.path || canonicalTarget.hasPrefix(c.path + "/") { return [] }
            }
            return .move
        }
        return .copy
    }

    private func droppedURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = dropFolder(for: item), let target = folder.node else { return false }
        let urls = droppedURLs(info.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        if (info.draggingSource as? NSOutlineView) === outlineView {
            controller?.moveItems(urls, into: target.url)
        } else {
            controller?.copyItems(urls, into: target.url)
        }
        return true
    }
}

// MARK: - for tests and the UI harness

extension SidebarController {
    func item(withID id: String) -> SidebarItem? { index[id] }

    /// What the outline shows, row by row.
    var visibleRowTitles: [String] { (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarItem)?.title } }
    var visibleRowIDs: [String] { (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id } }

    /// Where a row is, in the sidebar view's coordinates.
    func rowFrame(forID id: String) -> NSRect? {
        guard let item = index[id] else { return nil }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return nil }
        return view.convert(outline.rect(ofRow: row), from: outline)
    }

    var selectedRowIDs: [String] { outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id } }
}
