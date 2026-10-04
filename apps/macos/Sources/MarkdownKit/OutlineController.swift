import AppKit
import MarkdownCore

/// One heading in the outline's tree: the headings below it, up to the next of its own level or higher.
final class OutlineNode: NSObject {
    var entry: OutlineEntry
    /// Position in the document's list of headings.
    var index: Int
    weak var parent: OutlineNode?
    var children: [OutlineNode] = []

    init(_ entry: OutlineEntry, index: Int) { self.entry = entry; self.index = index; super.init() }
}

/// What the outline shows, worked out with no views: the tree of headings, and which one a position belongs to.
enum OutlineModel {
    /// The headings as a tree: a heading is a child of the nearest one before it with a lower level (a level
    /// skipped, `#` then `###`, is no gap: it is simply a child). Returns the roots and every node in order.
    /// Nodes of `old` that the new list still has at its start and its end (the same level and text) are kept
    /// as the same objects, so the list remembers what was folded and a change in the middle of a long
    /// document is a change of a few rows; `added` are the nodes that are new.
    static func tree(of entries: [OutlineEntry], reusing old: [OutlineNode] = []) -> (roots: [OutlineNode], all: [OutlineNode], added: [OutlineNode], oldIndex: [Int?]) {
        func same(_ a: OutlineEntry, _ b: OutlineEntry) -> Bool { a.level == b.level && a.text == b.text }
        var prefix = 0
        while prefix < min(old.count, entries.count), same(old[prefix].entry, entries[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, entries.count) - prefix, same(old[old.count - 1 - suffix].entry, entries[entries.count - 1 - suffix]) { suffix += 1 }
        var roots: [OutlineNode] = []
        var all: [OutlineNode] = []
        var added: [OutlineNode] = []
        var oldIndex: [Int?] = []
        all.reserveCapacity(entries.count)
        var stack: [OutlineNode] = []
        for (i, e) in entries.enumerated() {
            let node: OutlineNode
            if i < prefix {
                node = old[i]
                node.entry = e
                oldIndex.append(i)
            } else if i >= entries.count - suffix {
                node = old[old.count - (entries.count - i)]
                node.entry = e
                oldIndex.append(old.count - (entries.count - i))
            } else {
                node = OutlineNode(e, index: i)
                added.append(node)
                oldIndex.append(nil)
            }
            node.index = i
            node.parent = nil
            node.children = []
            while let top = stack.last, top.entry.level >= e.level { stack.removeLast() }
            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
            all.append(node)
        }
        return (roots, all, added, oldIndex)
    }

    /// The heading a caret at `location` is in: the last one that starts at or before it (nil above the first).
    static func index(containing location: Int, in entries: [OutlineEntry]) -> Int? {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(entries[mid].range.start) <= location { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// The heading at the top of the preview when its top is source line `line` (a fraction counts: the line
    /// being read): the last heading on or before that line (nil above the first).
    static func index(atLine line: Double, in entries: [OutlineEntry]) -> Int? {
        let whole = Int(line.rounded(.down))
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(entries[mid].line) <= whole { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }
}

/// The list: Return jumps (the arrow keys move and fold as an outline's do).
final class OutlineListView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.isEmpty, event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }
}

/// The outline column: a list of the document's headings below the title bar (which it runs under, like the
/// sidebar), in the theme's colours.
final class OutlineView: NSView {
    let scroll = NSScrollView()
    let list = OutlineListView()
    let band = TitlebarBandView()
    private let empty = NSTextField(labelWithString: "No headings")
    var style: SidebarStyle { didSet { apply() } }

    init(style: SidebarStyle) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.outlineTableColumn = column
        list.headerView = nil
        list.style = .sourceList
        list.rowSizeStyle = .default
        list.floatsGroupRows = false
        list.allowsMultipleSelection = false
        list.allowsEmptySelection = true
        list.autoresizesOutlineColumn = false
        list.indentationPerLevel = 14
        list.backgroundColor = .clear
        list.setAccessibilityLabel("Outline")
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.isHidden = true
        for v in [scroll, empty, band] as [NSView] { addSubview(v) }
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    var showsEmptyState = false { didSet { empty.isHidden = !showsEmptyState; needsLayout = true } }

    /// What the title bar takes from the top (the column runs under it).
    var topInset: CGFloat {
        guard let w = window else { return 28 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }

    private func apply() {
        empty.textColor = style.secondary
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let top = topInset
        band.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        scroll.frame = NSRect(x: 0, y: top + 6, width: bounds.width, height: max(0, bounds.height - top - 6))
        empty.frame = NSRect(x: 8, y: top + 24, width: max(0, bounds.width - 16), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        style.background.setFill()
        bounds.fill()
    }
}

/// The outline column's list of headings: the document's, from the core, marked where the reader is.
/// It never decides where the reader is (the window does) and never takes the keyboard by itself.
@MainActor
final class OutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let view: OutlineView
    private(set) var entries: [OutlineEntry] = []
    private var roots: [OutlineNode] = []
    private var nodes: [OutlineNode] = []
    /// The user chose a heading (a click, or Return on the selected one).
    var onJump: ((OutlineEntry) -> Void)?
    /// The entry marked as where the reader is (not the user's own choice of a row), or nil.
    private(set) var markedIndex: Int?

    // Instrumentation: main-thread time of the last update and how many were full rebuilds.
    private(set) var lastUpdateTime: TimeInterval = 0
    private(set) var rebuilds = 0
    /// Of the rebuilds, how many were reloads (the rest changed rows one by one).
    private(set) var reloads = 0
    private(set) var updates = 0

    init(style: SidebarStyle) {
        view = OutlineView(style: style)
        super.init()
        view.list.dataSource = self
        view.list.delegate = self
        view.list.target = self
        view.list.action = #selector(clicked(_:))
        view.list.onReturn = { [weak self] in self?.jumpToSelection() }
    }

    func styleChanged() {
        view.list.reloadData()
        expandAll()
        restoreMark()
    }

    // MARK: the entries

    /// The headings changed (an analysis answered). Only what differs is touched: the same shape (the levels in
    /// order) with other text redraws those rows, a new shape rebuilds the tree and keeps what was folded.
    func update(_ new: [OutlineEntry]) {
        guard new != entries else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { lastUpdateTime = CFAbsoluteTimeGetCurrent() - t0; updates += 1 }
        let sameShape = new.count == entries.count && zip(new, entries).allSatisfy { $0.level == $1.level }
        if sameShape {
            for (i, node) in nodes.enumerated() where node.entry.text != new[i].text {
                node.entry = new[i]
                view.list.reloadItem(node)
            }
            for (i, node) in nodes.enumerated() { node.entry = new[i] }
            entries = new
        } else {
            rebuild(new)
        }
        view.showsEmptyState = new.isEmpty
        restoreMark()
    }

    /// The headings changed shape. When every heading that stays keeps its parent (a heading added or removed
    /// with what is under it, a block pasted in), the rows are inserted and removed one by one: reloading a
    /// long document's tree costs tens of milliseconds, a row about one. Anything else reloads, keeping what was
    /// folded (the kept headings are the same objects).
    private func rebuild(_ new: [OutlineEntry]) {
        let old = nodes
        // Where each old heading was: its parent's index and its place among that parent's children.
        var oldParent = [Int?](repeating: nil, count: old.count)
        var oldPlace = [Int](repeating: 0, count: old.count)
        for (j, n) in old.enumerated() { for (k, c) in n.children.enumerated() { oldParent[c.index] = j; oldPlace[c.index] = k } }
        for (k, r) in roots.enumerated() { oldPlace[r.index] = k }
        let wasExpandable = Set(old.filter { !$0.children.isEmpty }.map(ObjectIdentifier.init))
        let wasChildless = Set(old.filter { $0.children.isEmpty }.map(ObjectIdentifier.init))
        entries = new
        let built = OutlineModel.tree(of: new, reusing: old)
        (roots, nodes) = (built.roots, built.all)
        rebuilds += 1
        let list = view.list
        if built.added.count == nodes.count || old.isEmpty {
            reloads += 1
            list.reloadData()
            expandAll()
            return
        }
        // Does every kept heading have the parent it had?
        var simple = true
        for (i, node) in nodes.enumerated() {
            guard let j = built.oldIndex[i] else { continue }
            let parentOld = node.parent.flatMap { p in built.oldIndex[p.index] }
            if (node.parent == nil) != (oldParent[j] == nil) || (node.parent != nil && parentOld != oldParent[j]) { simple = false; break }
        }
        guard simple else {
            reloads += 1
            // A kept heading that moved to another parent comes back from a reload folded, so everything is opened
            // again, and what was folded before is folded.
            let folded = old.filter { !wasChildless.contains(ObjectIdentifier($0)) && !list.isItemExpanded($0) }
            list.reloadData()
            expandAll()
            for node in folded where !node.children.isEmpty { list.collapseItem(node) }
            return
        }
        let kept = Set(built.oldIndex.compactMap { $0 })
        // Removed: the old headings not kept whose parent is kept (or the root), by place.
        var removed: [Int?: IndexSet] = [:]
        for j in 0..<old.count where !kept.contains(j) && (oldParent[j].map(kept.contains) ?? true) { removed[oldParent[j], default: IndexSet()].insert(oldPlace[j]) }
        // Added: the new headings whose parent is kept (or the root), by place.
        var inserted: [(parent: OutlineNode?, places: IndexSet)] = []
        var byParent: [ObjectIdentifier?: Int] = [:]
        var tops: [OutlineNode] = []
        for node in built.added where node.parent.map({ p in !built.added.contains { $0 === p } }) ?? true { tops.append(node) }
        for node in tops {
            let siblings = node.parent?.children ?? roots
            let place = siblings.firstIndex { $0 === node } ?? 0
            let key = node.parent.map(ObjectIdentifier.init)
            if let at = byParent[key] { inserted[at].places.insert(place) } else { byParent[key] = inserted.count; inserted.append((node.parent, IndexSet(integer: place))) }
        }
        // A heading replaced by another at the same place is not taken in by the list's own bookkeeping (the new row
        // closed, its children missing): that, like a move, is reloaded.
        if !removed.isEmpty && !inserted.isEmpty {
            reloads += 1
            let folded = old.filter { !wasChildless.contains(ObjectIdentifier($0)) && !list.isItemExpanded($0) }
            list.reloadData()
            expandAll()
            for node in folded where !node.children.isEmpty { list.collapseItem(node) }
            return
        }
        list.beginUpdates()
        defer { list.endUpdates() }
        for (parent, places) in removed { list.removeItems(at: places, inParent: parent.map { old[$0] }, withAnimation: []) }
        for (parent, places) in inserted { list.insertItems(at: places, inParent: parent, withAnimation: []) }
        // What is new and has headings under it is open; so is a heading that had none and now has.
        for node in tops where !node.children.isEmpty { open(node); expandBelow(node) }
        for (parent, _) in inserted { if let parent, !wasExpandable.contains(ObjectIdentifier(parent)), !list.isItemExpanded(parent) { open(parent) } }
    }

    /// Opens the headings under `node` (a block that was just inserted comes in folded).
    private func expandBelow(_ node: OutlineNode) {
        for child in node.children where !child.children.isEmpty {
            open(child)
            expandBelow(child)
        }
    }

    /// Opens `node`. A row that has just taken the place of one removed does not always open at the first ask
    /// (the list has not yet taken it in), so it is read again first.
    private func open(_ node: OutlineNode) {
        let list = view.list
        list.expandItem(node)
        if !list.isItemExpanded(node) {
            list.reloadItem(node, reloadChildren: true)
            list.expandItem(node)
        }
    }

    private func expandAll() {
        view.list.expandItem(nil, expandChildren: true)
    }

    // MARK: marking where the reader is

    /// Marks heading `index` (nil: none) as where the reader is, and keeps it in view. A heading inside a folded
    /// one marks the fold. Nothing is marked while the list has the keyboard: the user is moving through it.
    func mark(_ index: Int?) {
        markedIndex = index
        if view.window?.firstResponder === view.list { return }
        applyMark()
    }

    private func restoreMark() {
        if view.window?.firstResponder === view.list { return }
        applyMark()
    }

    private func applyMark() {
        guard let i = markedIndex, i < nodes.count else {
            if view.list.selectedRow >= 0 { select(row: nil) }
            return
        }
        var node: OutlineNode? = nodes[i]
        var row = view.list.row(forItem: node)
        while row < 0, let parent = node?.parent {
            node = parent
            row = view.list.row(forItem: parent)
        }
        select(row: row >= 0 ? row : nil)
    }

    private func select(row: Int?) {
        if let row {
            if view.list.selectedRow != row { view.list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            view.list.scrollRowToVisible(row)
        } else {
            view.list.deselectAll(nil)
        }
    }

    /// The rows showing, in order: their indices in the document's list of headings.
    var visibleIndices: [Int] {
        (0..<view.list.numberOfRows).compactMap { (view.list.item(atRow: $0) as? OutlineNode)?.index }
    }

    /// The row of heading `index` as drawn (nil when it is folded away).
    func row(of index: Int) -> Int? {
        guard index < nodes.count else { return nil }
        let r = view.list.row(forItem: nodes[index])
        return r >= 0 ? r : nil
    }

    func collapse(_ index: Int) { if index < nodes.count { view.list.collapseItem(nodes[index]) } }
    func expand(_ index: Int) { if index < nodes.count { view.list.expandItem(nodes[index]) } }

    // MARK: choosing

    @objc private func clicked(_ sender: Any?) {
        let row = view.list.clickedRow
        guard row >= 0, let node = view.list.item(atRow: row) as? OutlineNode else { return }
        onJump?(node.entry)
    }

    private func jumpToSelection() {
        guard let node = view.list.item(atRow: view.list.selectedRow) as? OutlineNode else { return }
        onJump?(node.entry)
    }

    // MARK: data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? OutlineNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? OutlineNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? OutlineNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView(style: view.style)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OutlineNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("outlineCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            c.addSubview(field)
            c.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let empty = node.entry.text.isEmpty
        cell.textField?.stringValue = empty ? "Untitled" : node.entry.text
        cell.textField?.font = .systemFont(ofSize: 12, weight: node.entry.level == 1 ? .semibold : .regular)
        cell.textField?.textColor = empty || node.entry.level > 2 ? view.style.secondary : view.style.text
        cell.setAccessibilityLabel(empty ? "Untitled heading" : node.entry.text)
        cell.setAccessibilityHelp("Heading level \(node.entry.level)")
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { true }
}
