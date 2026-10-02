import AppKit
import MarkdownCore
import UniformTypeIdentifiers

/// Format and Table menu actions. Every one asks the core; none contains Markdown logic.
extension EditorTextView {
    // MARK: Format

    @objc public func toggleStrong(_ sender: Any?) { perform(actionName: "Strong") { $0.format(command: .strong, selection: $1) } }
    @objc public func toggleEmphasis(_ sender: Any?) { perform(actionName: "Emphasis") { $0.format(command: .emphasis, selection: $1) } }
    @objc public func toggleStrikethrough(_ sender: Any?) { perform(actionName: "Strikethrough") { $0.format(command: .strikethrough, selection: $1) } }
    @objc public func toggleInlineCode(_ sender: Any?) { perform(actionName: "Code") { $0.format(command: .inlineCode, selection: $1) } }
    @objc public func insertLink(_ sender: Any?) { perform(actionName: "Link") { $0.format(command: .link, selection: $1) } }
    @objc public func toggleBlockQuote(_ sender: Any?) { perform(actionName: "Block Quote") { $0.format(command: .blockQuote, selection: $1) } }
    @objc public func toggleBulletList(_ sender: Any?) { perform(actionName: "Bulleted List") { $0.format(command: .bulletList, selection: $1) } }
    @objc public func toggleNumberedList(_ sender: Any?) { perform(actionName: "Numbered List") { $0.format(command: .orderedList, selection: $1) } }
    @objc public func toggleTaskList(_ sender: Any?) { perform(actionName: "Task List") { $0.format(command: .taskList, selection: $1) } }
    @objc public func toggleCodeBlock(_ sender: Any?) { perform(actionName: "Code Block") { $0.format(command: .codeBlock, selection: $1) } }

    /// Heading level in the sender's tag (0 = Body).
    @objc public func setHeadingLevel(_ sender: Any?) {
        let level: Int
        if let m = sender as? NSMenuItem { level = m.tag } else if let c = sender as? NSControl { level = c.tag } else { return }
        setHeading(level: level)
    }

    public func setHeading(level: Int) {
        perform(actionName: level == 0 ? "Body" : "Heading \(level)") {
            $0.format(command: .heading(level: UInt8(min(max(level, 0), 6))), selection: $1)
        }
    }

    @objc public func insertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.insertImage(fileURL: url)
        }
    }

    /// The path is relative to the document when it has been saved, absolute otherwise.
    public func insertImage(fileURL: URL) {
        let dest = DocumentFileAccess.path(of: fileURL, relativeTo: session?.documentURL())
        let alt = fileURL.deletingPathExtension().lastPathComponent
        perform(actionName: "Image") { $0.format(command: .image(destination: dest, alt: alt), selection: $1) }
    }

    // MARK: Table

    @objc public func insertTable(_ sender: Any?) {
        guard let window else { insertTable(rows: 2, columns: 3); return }
        let rows = NSTextField(string: "2"), cols = NSTextField(string: "3")
        let rowStep = NSStepper(), colStep = NSStepper()
        for (s, f, v) in [(rowStep, rows, 2.0), (colStep, cols, 3.0)] {
            s.minValue = 1; s.maxValue = f === rows ? 200 : 20; s.integerValue = Int(v); s.valueWraps = false
            f.alignment = .right; f.widthAnchor.constraint(equalToConstant: 48).isActive = true
            s.target = self
        }
        let link = TableSheetLinks(rows: rows, cols: cols, rowStep: rowStep, colStep: colStep)
        rowStep.target = link; rowStep.action = #selector(TableSheetLinks.stepped(_:))
        colStep.target = link; colStep.action = #selector(TableSheetLinks.stepped(_:))
        func row(_ label: String, _ f: NSTextField, _ s: NSStepper) -> NSStackView {
            let l = NSTextField(labelWithString: label); l.widthAnchor.constraint(equalToConstant: 120).isActive = true
            return NSStackView(views: [l, f, s])
        }
        let stack = NSStackView(views: [row("Body rows:", rows, rowStep), row("Columns:", cols, colStep)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: 56)
        let alert = NSAlert()
        alert.messageText = "Insert Table"
        alert.informativeText = "A header row, a delimiter row and the body rows you choose."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(link) {
                guard response == .alertFirstButtonReturn else { return }
                self?.insertTable(rows: max(1, rows.integerValue), columns: max(1, cols.integerValue))
            }
        }
    }

    public func insertTable(rows: Int, columns: Int) {
        perform(actionName: "Insert Table") {
            $0.tableCommand(command: .insert(rows: UInt32(rows), columns: UInt32(columns)), selection: $1)
        }
    }

    private func table(_ c: TableCommand, _ name: String) {
        perform(actionName: name) { $0.tableCommand(command: c, selection: $1) }
    }

    @objc public func tableAddRowAbove(_ sender: Any?) { table(.addRowAbove, "Add Row Above") }
    @objc public func tableAddRowBelow(_ sender: Any?) { table(.addRowBelow, "Add Row Below") }
    @objc public func tableAddColumnLeft(_ sender: Any?) { table(.addColumnLeft, "Add Column Left") }
    @objc public func tableAddColumnRight(_ sender: Any?) { table(.addColumnRight, "Add Column Right") }
    @objc public func tableDeleteRow(_ sender: Any?) { table(.deleteRow, "Delete Row") }
    @objc public func tableDeleteColumn(_ sender: Any?) { table(.deleteColumn, "Delete Column") }
    @objc public func tableRealign(_ sender: Any?) { table(.realign, "Align Table") }

    /// Alignment in the sender's tag: 0 none, 1 left, 2 center, 3 right.
    @objc public func tableSetAlignment(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? 0
        let a: ColumnAlignment = [.none, .left, .center, .right][min(max(tag, 0), 3)]
        table(.setAlignment(alignment: a), "Column Alignment")
    }

    // MARK: validation

    private static let formatActions: Set<Selector> = [
        #selector(toggleStrong(_:)), #selector(toggleEmphasis(_:)), #selector(toggleStrikethrough(_:)),
        #selector(toggleInlineCode(_:)), #selector(insertLink(_:)), #selector(toggleBlockQuote(_:)),
        #selector(toggleBulletList(_:)), #selector(toggleNumberedList(_:)), #selector(toggleTaskList(_:)),
        #selector(toggleCodeBlock(_:)), #selector(setHeadingLevel(_:)), #selector(insertImage(_:)),
        #selector(insertTable(_:)),
    ]
    private static let tableActions: Set<Selector> = [
        #selector(tableAddRowAbove(_:)), #selector(tableAddRowBelow(_:)), #selector(tableAddColumnLeft(_:)),
        #selector(tableAddColumnRight(_:)), #selector(tableDeleteRow(_:)), #selector(tableDeleteColumn(_:)),
        #selector(tableRealign(_:)), #selector(tableSetAlignment(_:)),
    ]

    /// Shared by menu items and toolbar buttons. Returns nil for actions that are not ours.
    func validateEditorAction(_ action: Selector?, tag: Int) -> (enabled: Bool, on: Bool)? {
        guard let action else { return nil }
        let editable = isEditable && !hasMarkedText()
        let s = session?.formatState ?? EditorSession.emptyFormatState
        if Self.tableActions.contains(action) {
            return (editable && s.inTable, false)
        }
        guard Self.formatActions.contains(action) else { return nil }
        let on: Bool
        switch action {
        case #selector(toggleStrong(_:)): on = s.strong
        case #selector(toggleEmphasis(_:)): on = s.emphasis
        case #selector(toggleStrikethrough(_:)): on = s.strikethrough
        case #selector(toggleInlineCode(_:)): on = s.inlineCode
        case #selector(insertLink(_:)): on = s.link
        case #selector(toggleBlockQuote(_:)): on = s.inQuote
        case #selector(toggleBulletList(_:)): on = s.list == .bullet
        case #selector(toggleNumberedList(_:)): on = s.list == .ordered
        case #selector(toggleTaskList(_:)): on = s.list == .task
        case #selector(toggleCodeBlock(_:)): on = s.inCodeBlock
        case #selector(setHeadingLevel(_:)): on = Int(s.headingLevel) == tag
        default: on = false
        }
        // Headings and lists make no sense inside a code block, but the core decides; stay enabled.
        return (editable, on)
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let r = validateEditorAction(item.action, tag: item.tag) {
            if let m = item as? NSMenuItem { m.state = r.on ? .on : .off }
            return r.enabled
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Keeps the two steppers of the Insert Table sheet in step with their text fields.
final class TableSheetLinks: NSObject {
    let rows, cols: NSTextField
    let rowStep, colStep: NSStepper
    init(rows: NSTextField, cols: NSTextField, rowStep: NSStepper, colStep: NSStepper) {
        self.rows = rows; self.cols = cols; self.rowStep = rowStep; self.colStep = colStep
    }
    @objc func stepped(_ sender: NSStepper) {
        (sender === rowStep ? rows : cols).integerValue = sender.integerValue
    }
}
