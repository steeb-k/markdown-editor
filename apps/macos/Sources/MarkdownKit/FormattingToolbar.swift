import AppKit
import MarkdownCore

/// The slim formatting bar along the bottom of the window (PLAN 3.2a). It floats over the
/// text column's bottom margin and never takes layout space. Buttons send the same actions
/// as the menus to the first responder (the text view) and reflect the core's format state.
public final class FormattingToolbar: NSVisualEffectView {
    struct Item {
        let symbol: String
        let label: String
        let action: Selector
        let tag: Int
    }

    private var buttons: [(button: NSButton, item: Item)] = []
    private let headingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stack = NSStackView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        add(Item(symbol: "bold", label: "Strong", action: #selector(EditorTextView.toggleStrong(_:)), tag: 0))
        add(Item(symbol: "italic", label: "Emphasis", action: #selector(EditorTextView.toggleEmphasis(_:)), tag: 0))
        add(Item(symbol: "strikethrough", label: "Strikethrough", action: #selector(EditorTextView.toggleStrikethrough(_:)), tag: 0))
        addHeadingPopUp()
        separator()
        add(Item(symbol: "list.bullet", label: "Bulleted List", action: #selector(EditorTextView.toggleBulletList(_:)), tag: 0))
        add(Item(symbol: "list.number", label: "Numbered List", action: #selector(EditorTextView.toggleNumberedList(_:)), tag: 0))
        add(Item(symbol: "checklist", label: "Task List", action: #selector(EditorTextView.toggleTaskList(_:)), tag: 0))
        separator()
        add(Item(symbol: "text.quote", label: "Block Quote", action: #selector(EditorTextView.toggleBlockQuote(_:)), tag: 0))
        add(Item(symbol: "chevron.left.forwardslash.chevron.right", label: "Code", action: #selector(EditorTextView.toggleInlineCode(_:)), tag: 0))
        add(Item(symbol: "link", label: "Link", action: #selector(EditorTextView.insertLink(_:)), tag: 0))
        add(Item(symbol: "photo", label: "Image", action: #selector(EditorTextView.insertImage(_:)), tag: 0))
        add(Item(symbol: "tablecells", label: "Table", action: #selector(EditorTextView.insertTable(_:)), tag: 0))
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    private func add(_ item: Item) {
        let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.label)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let b = NSButton(image: image, target: nil, action: item.action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.toolTip = item.label
        b.setAccessibilityLabel(item.label)
        b.refusesFirstResponder = true
        b.tag = item.tag
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        b.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(b)
        buttons.append((b, item))
    }

    private func addHeadingPopUp() {
        headingPopUp.addItem(withTitle: "Body")
        headingPopUp.lastItem?.tag = 0
        for level in 1...6 {
            headingPopUp.addItem(withTitle: "Heading \(level)")
            headingPopUp.lastItem?.tag = level
        }
        headingPopUp.isBordered = false
        headingPopUp.font = .systemFont(ofSize: 12)
        headingPopUp.refusesFirstResponder = true
        headingPopUp.target = self
        headingPopUp.action = #selector(headingPicked(_:))
        headingPopUp.toolTip = "Heading level"
        headingPopUp.setAccessibilityLabel("Heading level")
        stack.addArrangedSubview(headingPopUp)
    }

    private func separator() {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(box)
    }

    @objc private func headingPicked(_ sender: NSPopUpButton) {
        let item = NSMenuItem()
        item.tag = sender.selectedTag()
        NSApp.sendAction(#selector(EditorTextView.setHeadingLevel(_:)), to: nil, from: item)
    }

    /// Lights buttons for the format at the selection.
    public func update(_ s: FormatState) {
        func lit(_ action: Selector) -> Bool {
            switch action {
            case #selector(EditorTextView.toggleStrong(_:)): return s.strong
            case #selector(EditorTextView.toggleEmphasis(_:)): return s.emphasis
            case #selector(EditorTextView.toggleStrikethrough(_:)): return s.strikethrough
            case #selector(EditorTextView.toggleInlineCode(_:)): return s.inlineCode
            case #selector(EditorTextView.insertLink(_:)): return s.link
            case #selector(EditorTextView.toggleBlockQuote(_:)): return s.inQuote
            case #selector(EditorTextView.toggleBulletList(_:)): return s.list == .bullet
            case #selector(EditorTextView.toggleNumberedList(_:)): return s.list == .ordered
            case #selector(EditorTextView.toggleTaskList(_:)): return s.list == .task
            case #selector(EditorTextView.insertTable(_:)): return s.inTable
            default: return false
            }
        }
        for (b, item) in buttons {
            let on = lit(item.action)
            b.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            b.state = on ? .on : .off
        }
        headingPopUp.selectItem(withTag: Int(s.headingLevel))
    }

    /// Invisible chrome must not eat clicks.
    public override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.5 ? nil : super.hitTest(point) }

    var litButtonLabels: [String] { buttons.filter { $0.button.state == .on }.map { $0.item.label } }
    var headingTitle: String? { headingPopUp.titleOfSelectedItem }
}
