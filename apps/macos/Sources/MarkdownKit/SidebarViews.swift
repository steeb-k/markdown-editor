import AppKit
import MarkdownCore

/// How the sidebar is coloured: the theme's own colours, a shade apart from the page.
struct SidebarStyle: Equatable {
    var background: NSColor
    var text: NSColor
    var secondary: NSColor
    var rule: NSColor
    var accent: NSColor

    static func == (a: SidebarStyle, b: SidebarStyle) -> Bool {
        a.background.isEqual(b.background) && a.text.isEqual(b.text) && a.secondary.isEqual(b.secondary)
            && a.rule.isEqual(b.rule) && a.accent.isEqual(b.accent)
    }

    init(_ p: ThemePalette) {
        background = p.background.blended(withFraction: p.isDark ? 0.07 : 0.04, of: p.text) ?? p.background
        text = p.text
        secondary = p.quote
        rule = p.rule
        accent = p.link
    }
}

/// The sidebar of a window in notes mode: a search field, the library's outline, and under it the
/// backlinks of the document. Laid out by frames below the title bar, which it runs under (the
/// window's content view is full size).
final class SidebarView: NSView {
    let searchField = NSSearchField()
    let scroll = NSScrollView()
    let outline = SidebarOutlineView()
    let backlinks = BacklinksPanel()
    let emptyState = EmptyLibraryView()
    var style: SidebarStyle { didSet { apply() } }
    var showsBacklinks = false { didSet { needsLayout = true; backlinks.isHidden = !showsBacklinks } }
    var showsEmptyState = false { didSet { emptyState.isHidden = !showsEmptyState; scroll.isHidden = showsEmptyState; searchField.isHidden = showsEmptyState; needsLayout = true } }
    static let backlinksHeight: CGFloat = 190

    init(style: SidebarStyle) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("Search the library")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 14
        outline.backgroundColor = .clear
        outline.setAccessibilityLabel("Library")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        backlinks.isHidden = true
        emptyState.isHidden = true
        for v in [scroll, searchField, backlinks, emptyState] as [NSView] { addSubview(v) }
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// What the title bar takes from the top (the sidebar runs under it).
    var topInset: CGFloat {
        guard let w = window else { return 28 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }

    private func apply() {
        emptyState.style = style
        backlinks.style = style
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let top = topInset
        let w = bounds.width
        searchField.frame = NSRect(x: 10, y: top + 6, width: max(0, w - 20), height: 26)
        let listTop = top + 6 + 26 + 6
        let bottom = showsBacklinks ? min(Self.backlinksHeight, max(80, bounds.height * 0.4)) : 0
        scroll.frame = NSRect(x: 0, y: listTop, width: w, height: max(0, bounds.height - listTop - bottom))
        backlinks.frame = NSRect(x: 0, y: bounds.height - bottom, width: w, height: bottom)
        emptyState.frame = NSRect(x: 0, y: top, width: w, height: max(0, bounds.height - top))
    }

    override func draw(_ dirtyRect: NSRect) {
        style.background.setFill()
        bounds.fill()
        // The edge against the editor.
        style.rule.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        if showsBacklinks {
            let y = backlinks.frame.minY
            NSRect(x: 0, y: y, width: bounds.width - 1, height: 1).fill()
        }
    }
}

/// A row that draws its own selection in the theme's colours: the system's source-list highlight depends
/// on the vibrancy of the sidebar behind it, which a themed sidebar does not have.
final class SidebarRowView: NSTableRowView {
    var style: SidebarStyle

    init(style: SidebarStyle) {
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let r = bounds.insetBy(dx: 6, dy: 1)
        (isEmphasized ? NSColor.controlAccentColor : style.text.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
    }
}

/// The outline: Return renames, the context menu selects the row it opens on.
final class SidebarOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return (or Enter) renames what is selected.
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// One row: an icon and a name; a count for a tag; a snippet under the title for a search hit.
final class SidebarCellView: NSTableCellView {
    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    var style: SidebarStyle
    private(set) var item: SidebarItem?
    private var dimmed = false
    private var tagActive = false

    init(style: SidebarStyle) {
        self.style = style
        super.init(frame: .zero)
        iconView.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.font = .systemFont(ofSize: 13)
        detail.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 2
        detail.cell?.wraps = true
        textField = label
        imageView = iconView
        for v in [iconView, label, detail] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { recolour() }
    }

    func configure(_ item: SidebarItem, style: SidebarStyle, tagActive: Bool, workspace: Workspace) {
        self.item = item
        self.style = style
        self.tagActive = tagActive
        label.stringValue = item.title
        detail.stringValue = ""
        detail.attributedStringValue = NSAttributedString()
        label.font = .systemFont(ofSize: 13)
        dimmed = false
        var symbol = "doc.text"
        switch item.kind {
        case .node(let n):
            switch n.kind {
            case .root: symbol = n.id == LibraryNode.id(root: LibraryRootInfo.libraryID, path: "") ? "books.vertical" : "folder"
            case .folder: symbol = "folder"
            case .note: symbol = "doc.text"
            case .other: symbol = "doc"; dimmed = true
            }
            if n.kind == .root { label.font = .systemFont(ofSize: 13, weight: .semibold) }
        case .tag(_, let count):
            symbol = "number"
            detail.stringValue = "\(count)"
            label.stringValue = String(item.title.dropFirst())
            label.font = .systemFont(ofSize: 13, weight: tagActive ? .semibold : .regular)
        case .hit(let h):
            symbol = "doc.text.magnifyingglass"
            detail.attributedStringValue = Self.snippet(h, style: style)
            label.font = .systemFont(ofSize: 13, weight: .medium)
        case .message:
            symbol = ""
            dimmed = true
        case .tagsHeader:
            symbol = ""
        }
        iconView.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        setAccessibilityLabel(item.title)
        recolour()
        needsLayout = true
    }

    /// The snippet with the matched words in bold.
    static func snippet(_ hit: SearchHit, style: SidebarStyle) -> NSAttributedString {
        let out = NSMutableAttributedString(string: hit.snippet, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: style.secondary,
        ])
        for r in hit.highlights {
            let range = NSRange(location: Int(r.start), length: Int(r.end - r.start))
            if NSMaxRange(range) <= out.length {
                out.addAttributes([.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: style.text], range: range)
            }
        }
        return out
    }

    private func recolour() {
        let selected = backgroundStyle == .emphasized
        let main: NSColor = selected ? .alternateSelectedControlTextColor : (dimmed ? style.secondary.withAlphaComponent(0.7) : style.text)
        label.textColor = tagActive && !selected ? style.accent : main
        iconView.contentTintColor = selected ? .alternateSelectedControlTextColor : (tagActive ? style.accent : style.secondary)
        if case .hit = item?.kind {
            // The snippet carries its own colours; a selected row turns them white.
            if selected { detail.textColor = .alternateSelectedControlTextColor }
        } else {
            detail.textColor = selected ? .alternateSelectedControlTextColor : style.secondary
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let hasIcon = iconView.image != nil
        let iconW: CGFloat = hasIcon ? 18 : 0
        iconView.frame = NSRect(x: 0, y: hasIcon ? (isHit ? 5 : (h - 16) / 2) : 0, width: iconW, height: 16)
        let x = iconW + (hasIcon ? 4 : 0)
        if isHit {
            label.frame = NSRect(x: x, y: 4, width: max(0, bounds.width - x), height: 17)
            detail.frame = NSRect(x: x, y: 21, width: max(0, bounds.width - x), height: max(0, h - 24))
        } else if case .tag = item?.kind {
            let countW = ceil((detail.stringValue as NSString).size(withAttributes: [.font: detail.font ?? .systemFont(ofSize: 11)]).width) + 2
            detail.frame = NSRect(x: max(x, bounds.width - countW - 10), y: (h - 14) / 2, width: countW, height: 14)
            label.frame = NSRect(x: x, y: (h - 17) / 2, width: max(0, detail.frame.minX - x - 4), height: 17)
        } else {
            label.frame = NSRect(x: x, y: (h - 17) / 2, width: max(0, bounds.width - x), height: 17)
            detail.frame = .zero
        }
    }

    private var isHit: Bool { if case .hit = item?.kind { return true } else { return false } }
    override var isFlipped: Bool { true }
}

/// "Tags" and a way to clear the filter.
final class SidebarHeaderView: NSTableCellView {
    let label = NSTextField(labelWithString: "TAGS")
    let clear = NSButton(title: "Clear", target: nil, action: nil)
    var style: SidebarStyle { didSet { recolour() } }

    init(style: SidebarStyle) {
        self.style = style
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 11)
        clear.setAccessibilityLabel("Clear tag filter")
        addSubview(label)
        addSubview(clear)
        recolour()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func recolour() {
        label.textColor = style.secondary
        clear.contentTintColor = style.accent
        clear.attributedTitle = NSAttributedString(string: "Clear", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: style.accent])
    }

    override func layout() {
        super.layout()
        let size = clear.fittingSize
        clear.frame = NSRect(x: bounds.width - size.width - 4, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        label.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: max(0, clear.frame.minX - 4), height: 14)
    }
}

/// What the sidebar shows before there is a library: where to make one.
final class EmptyLibraryView: NSView {
    let title = NSTextField(wrappingLabelWithString: "Where do your notes live?")
    let detail = NSTextField(wrappingLabelWithString: "Notes mode shows a folder of Markdown files. Make a folder for them in Documents, or choose one you already have.")
    let make = NSButton(title: "Create \u{201C}Markdown Notes\u{201D}", target: nil, action: nil)
    let choose = NSButton(title: "Choose Folder\u{2026}", target: nil, action: nil)
    var style: SidebarStyle? { didSet { recolour() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        make.bezelStyle = .rounded
        choose.bezelStyle = .rounded
        for v in [title, detail, make, choose] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func recolour() {
        title.textColor = style?.text
        detail.textColor = style?.secondary
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = max(0, bounds.width - 32)
        title.frame = NSRect(x: 16, y: 24, width: w, height: 20)
        let dh = detail.sizeThatFits(NSSize(width: w, height: 1000)).height
        detail.frame = NSRect(x: 16, y: 48, width: w, height: dh)
        make.frame = NSRect(x: 16, y: 48 + dh + 12, width: w, height: 28)
        choose.frame = NSRect(x: 16, y: 48 + dh + 46, width: w, height: 28)
    }
}

/// The notes that link to the front document, each with the sentence around the link.
final class BacklinksPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let header = NSTextField(labelWithString: "Backlinks")
    let scroll = NSScrollView()
    let table = NSTableView()
    private(set) var links: [NoteBacklink] = []
    var onOpen: ((NoteBacklink) -> Void)?
    var style: SidebarStyle? { didSet { recolour() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("backlink"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Backlinks")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(header)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private func recolour() {
        header.textColor = style?.secondary
        table.reloadData()
    }

    func setLinks(_ new: [NoteBacklink]) {
        guard new != links else { return }
        links = new
        header.stringValue = new.isEmpty ? "Backlinks" : "Backlinks (\(new.count))"
        table.reloadData()
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 12, y: 8, width: max(0, bounds.width - 24), height: 14)
        scroll.frame = NSRect(x: 0, y: 26, width: bounds.width, height: max(0, bounds.height - 26))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { links.isEmpty ? 1 : links.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { links.isEmpty ? 28 : 56 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !links.isEmpty }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("backlinkCell"), owner: nil) as? BacklinkCell) ?? BacklinkCell()
        cell.identifier = NSUserInterfaceItemIdentifier("backlinkCell")
        if links.isEmpty {
            cell.configure(title: "No notes link here", context: nil, style: style)
        } else {
            cell.configure(title: links[row].fromTitle, context: links[row].context, style: style)
        }
        return cell
    }

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < links.count else { return }
        onOpen?(links[row])
    }
}

final class BacklinkCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let context = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        context.font = .systemFont(ofSize: 11)
        context.maximumNumberOfLines = 2
        context.lineBreakMode = .byWordWrapping
        context.cell?.truncatesLastVisibleLine = true
        addSubview(title)
        addSubview(context)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    func configure(title t: String, context c: String?, style: SidebarStyle?) {
        title.stringValue = t
        context.stringValue = c.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
        title.textColor = c == nil ? style?.secondary : style?.text
        context.textColor = style?.secondary
        setAccessibilityLabel(c == nil ? t : "\(t): \(c ?? "")")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 4, y: 4, width: max(0, bounds.width - 8), height: 16)
        context.frame = NSRect(x: 4, y: 21, width: max(0, bounds.width - 8), height: max(0, bounds.height - 23))
    }
}
