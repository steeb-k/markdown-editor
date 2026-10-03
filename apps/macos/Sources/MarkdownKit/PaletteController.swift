import AppKit
import MarkdownCore

/// One line of the palette: a title, where it is, and which letters of each matched.
struct PaletteRow: Equatable {
    var title: String
    var detail: String
    var titleRanges: [NSRange] = []
    var detailRanges: [NSRange] = []
    /// What the row stands for (a note's reference, a template's file).
    var key: String
}

/// A palette over a window: a field, and under it a list that follows what is typed. Arrow keys
/// move, Return chooses (Option-Return in a new place: see the caller), Escape closes. It is a view
/// in the window, not a window of its own, so it needs no focus juggling and appears in snapshots.
final class PaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let panel = PalettePanelView()
    private(set) var rows: [PaletteRow] = []
    private let source: (String, @escaping ([PaletteRow]) -> Void) -> Void
    private let choose: (PaletteRow, _ alternate: Bool) -> Void
    private weak var host: NSView?
    private var generation = 0
    var onClose: (() -> Void)?
    var isOpen: Bool { panel.superview != nil }

    /// `source` is asked for the rows of a query, and answers (on the main thread) when it has them; `choose`
    /// is told which row was chosen, and whether Option was held.
    init(placeholder: String, style: SidebarStyle,
         source: @escaping (String, @escaping ([PaletteRow]) -> Void) -> Void,
         choose: @escaping (PaletteRow, Bool) -> Void) {
        self.source = source
        self.choose = choose
        super.init()
        panel.style = style
        panel.field.placeholderString = placeholder
        // Named for what it does (Quick Open, a template), for VoiceOver.
        panel.field.setAccessibilityLabel(placeholder)
        panel.setAccessibilityLabel(placeholder)
        panel.field.delegate = self
        panel.table.dataSource = self
        panel.table.delegate = self
        panel.table.target = self
        panel.table.action = #selector(clicked(_:))
        panel.onBackgroundClick = { [weak self] in self?.close() }
    }

    func show(over host: NSView) {
        guard !isOpen else { return }
        self.host = host
        panel.frame = host.bounds
        panel.autoresizingMask = [.width, .height]
        host.addSubview(panel)
        panel.needsLayout = true
        host.window?.makeFirstResponder(panel.field)
        query("")
    }

    func close() {
        guard isOpen else { return }
        let window = panel.window
        panel.removeFromSuperview()
        onClose?()
        _ = window
    }

    private func query(_ text: String) {
        generation += 1
        let g = generation
        source(text) { [weak self] rows in
            guard let self, g == generation else { return }
            setRows(rows)
        }
    }

    func setRows(_ new: [PaletteRow]) {
        rows = new
        panel.table.reloadData()
        if !rows.isEmpty { panel.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        panel.resultCount = rows.count
        panel.needsLayout = true
    }

    /// Types into the field and asks for the rows (the harness's way of typing a query).
    func type(_ text: String) {
        panel.field.stringValue = text
        query(text)
    }

    func chooseSelected(alternate: Bool) {
        let r = panel.table.selectedRow
        guard r >= 0, r < rows.count else { return }
        let row = rows[r]
        close()
        choose(row, alternate)
    }

    // MARK: field

    func controlTextDidChange(_ obj: Notification) { query(panel.field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected(alternate: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
            return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let r = min(max(0, panel.table.selectedRow + delta), rows.count - 1)
        panel.table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        panel.table.scrollRowToVisible(r)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("paletteCell"), owner: nil) as? PaletteCell) ?? PaletteCell()
        cell.identifier = NSUserInterfaceItemIdentifier("paletteCell")
        cell.configure(rows[row], style: panel.style)
        return cell
    }

    @objc private func clicked(_ sender: Any?) {
        guard panel.table.clickedRow >= 0 else { return }
        chooseSelected(alternate: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }
}

/// The palette's look: a rounded panel near the top of the window over a dimmed page.
final class PalettePanelView: NSView {
    let field = NSTextField()
    let scroll = NSScrollView()
    let table = NSTableView()
    let card = NSVisualEffectView()
    /// The card's contents, laid out from the top.
    private let content = FlippedView()
    var style = SidebarStyle(ThemeStore.shared.palette(ThemeStore.shared.theme(id: "light"))) { didSet { restyle() } }
    var onBackgroundClick: (() -> Void)?
    var resultCount = 0
    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 38

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.material = .menu
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Quick Open")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("palette"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        content.autoresizingMask = [.width, .height]
        card.addSubview(content)
        content.addSubview(field)
        content.addSubview(scroll)
        addSubview(card)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Quick Open")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private func restyle() {
        field.textColor = style.text
        table.reloadData()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let w = min(Self.width, max(240, bounds.width - 40))
        let visible = min(max(resultCount, 1), 8)
        let listH = CGFloat(visible) * Self.rowHeight
        let h = 52 + (resultCount > 0 ? listH + 6 : 0)
        let top = max(60, bounds.height * 0.14)
        card.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: top, width: w, height: h)
        content.frame = card.bounds
        field.frame = NSRect(x: 16, y: 12, width: w - 32, height: 28)
        scroll.frame = NSRect(x: 0, y: 52, width: w, height: resultCount > 0 ? listH + 6 : 0)
        scroll.isHidden = resultCount == 0
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
        // A hairline round the card.
        let r = card.frame.insetBy(dx: -0.5, dy: -0.5)
        style.rule.setStroke()
        NSBezierPath(roundedRect: r, xRadius: 10.5, yRadius: 10.5).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onBackgroundClick?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) ?? self }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PaletteCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private var shown: (row: PaletteRow, style: SidebarStyle)?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if let shown { render(shown.row, shown.style) } }
    }

    func configure(_ row: PaletteRow, style: SidebarStyle) {
        shown = (row, style)
        render(row, style)
    }

    private func render(_ row: PaletteRow, _ style: SidebarStyle) {
        // On the selection's colour the text is the system's selected-text colour.
        let selected = backgroundStyle == .emphasized
        let main: NSColor = selected ? .alternateSelectedControlTextColor : style.text
        let second: NSColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : style.secondary
        let accent: NSColor = selected ? .alternateSelectedControlTextColor : style.accent
        title.attributedStringValue = Self.styled(row.title, row.titleRanges, size: 14, base: main, accent: accent)
        detail.attributedStringValue = Self.styled(row.detail, row.detailRanges, size: 11, base: second, accent: accent)
        setAccessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)")
        needsLayout = true
    }

    /// `text` with the matched letters bold and in the accent colour.
    static func styled(_ text: String, _ ranges: [NSRange], size: CGFloat, base: NSColor, accent: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: base])
        for r in ranges where NSMaxRange(r) <= out.length {
            out.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: accent], range: r)
        }
        return out
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 16, y: 3, width: max(0, bounds.width - 32), height: 18)
        detail.frame = NSRect(x: 16, y: 21, width: max(0, bounds.width - 32), height: 14)
    }
}
