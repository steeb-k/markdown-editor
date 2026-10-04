import AppKit

/// The window's title, drawn by the app instead of AppKit: the document's name and, while it has an edit not yet
/// written, "Edited", centred over the editor's pane (AppKit centres a title in the whole window, so with the notes
/// sidebar or the right column shown it ran across their edges). There is no document icon: this is a Markdown
/// editor and the name says `.md`. It fills the title-bar row of the pane it is in, takes the row's clicks as
/// `TitlebarBandView` does (a press drags the window, a double-click on the blank part zooms it) and adds the
/// title's own: a double-click on the name renames the document, and a Command-click shows the path (the folders the
/// file is in, each of which shows in the Finder when chosen) as AppKit's title does. The window's `title` and
/// `representedURL` stay set, for the Dock, Mission Control, the Window menu and VoiceOver, and AppKit's own title
/// views stay hidden (`SystemTitle`). What the icon gave and this does not: dragging the file from the title bar.
final class TitlebarTitleView: NSView {
    var name = "" { didSet { if name != oldValue { refresh() } } }
    var fileURL: URL? { didSet { if fileURL != oldValue { refresh() } } }
    var edited = false { didSet { if edited != oldValue { refresh() } } }
    /// A double-click on the name: set by the window's controller, which knows whether the document can be renamed.
    var onRename: (() -> Void)?
    /// Whether a double-click on the title may rename (false while the chrome is faded: the title is not there).
    var canRename: () -> Bool = { true }
    /// The room to keep clear on the left of the row (the window buttons, where the pane is under them), in points
    /// from the view's own left edge.
    var leadingClearance: CGFloat = 0 { didSet { if leadingClearance != oldValue { needsLayout = true } } }

    private let label = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var active = true { didSet { updateColours() } }
    private var observers: [NSObjectProtocol] = []

    static let gap: CGFloat = 5
    static let sideMargin: CGFloat = 12
    /// What choosing a folder in the path menu does (the Finder opens it; tests record it).
    nonisolated(unsafe) static var openFolder: (URL) -> Void = { NSWorkspace.shared.open($0) }
    nonisolated(unsafe) static var statusText = "\u{2014} Edited"

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Self.titleFont
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        status.font = Self.titleFont
        status.lineBreakMode = .byClipping
        for v in [label, status] as [NSView] { addSubview(v) }
        // One element for VoiceOver, with what the system's title had: the name, and that it is edited.
        for v in [label, status] as [NSView] { v.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("window-title")
        updateColours()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// What a label needs (its cell's size: the intrinsic size leaves out the cell's own margins, and the text came out cut).
    static func width(of field: NSTextField) -> CGFloat { ceil(field.cell?.cellSize.width ?? field.intrinsicContentSize.width) }
    static func height(of field: NSTextField) -> CGFloat { ceil(field.cell?.cellSize.height ?? field.intrinsicContentSize.height) }

    static var titleFont: NSFont { NSFont.titleBarFont(ofSize: 0) }

    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        active = window.isMainWindow || window.isKeyWindow
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignMainNotification, NSWindow.didResignKeyNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = self?.window.map { $0.isMainWindow || $0.isKeyWindow } ?? true }
            })
        }
    }

    // MARK: content

    private func refresh() {
        label.stringValue = name
        status.stringValue = edited ? Self.statusText : ""
        status.isHidden = !edited
        setAccessibilityLabel(edited ? "\(name), edited" : name)
        needsLayout = true
    }

    private func updateColours() {
        label.textColor = active ? .windowFrameTextColor : .disabledControlTextColor
        status.textColor = active ? .secondaryLabelColor : .disabledControlTextColor
    }

    // MARK: layout

    /// The widths the three parts take: the name is cut in the middle when all do not fit.
    struct Parts: Equatable {
        var name: CGFloat, status: CGFloat
        var total: CGFloat { name + (status > 0 ? TitlebarTitleView.gap : 0) + status }
    }

    /// What can be used: the row less its margins, and symmetric about the centre so that the title stays centred.
    var availableWidth: CGFloat {
        let side = max(Self.sideMargin, leadingClearance)
        return max(0, bounds.width - 2 * side)
    }

    var fullNameWidth: CGFloat { Self.width(of: label) }

    var parts: Parts {
        let statusWidth = edited ? Self.width(of: status) : 0
        let wanted = Self.width(of: label)
        var p = Parts(name: wanted, status: statusWidth)
        let over = p.total - availableWidth
        if over > 0 { p.name = max(0, wanted - over) }
        return p
    }

    /// Where the name (and "Edited") sit, in the view's coordinates: the clickable part of the title.
    var titleFrame: NSRect {
        let p = parts
        let h = Self.height(of: label)
        return NSRect(x: ((bounds.width - p.total) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: p.total, height: h)
    }

    /// Keeps the title off the window buttons when the pane is under them (the window without a sidebar).
    private func updateClearance() {
        guard let window, let zoom = window.standardWindowButton(.zoomButton), zoom.window === window, !zoom.isHidden else {
            leadingClearance = 0
            return
        }
        leadingClearance = max(0, convert(zoom.bounds, from: zoom).maxX + 8)
    }

    override func layout() {
        super.layout()
        updateClearance()
        let p = parts, f = titleFrame
        var x = f.minX
        let lh = Self.height(of: label)
        label.frame = NSRect(x: x, y: f.minY + (f.height - lh) / 2, width: p.name, height: lh)
        x += p.name + Self.gap
        status.frame = NSRect(x: x, y: label.frame.minY, width: p.status, height: lh)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: the row's clicks

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let onTitle = titleFrame.insetBy(dx: -4, dy: -4).contains(p)
        if event.clickCount == 2 {
            if onTitle, canRename(), let onRename { onRename() } else { TitlebarDoubleClick.setting().perform(on: window) }
            return
        }
        // Command-click on the name: the path, as AppKit's title shows it.
        if onTitle, event.modifierFlags.contains(.command), let menu = pathMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        window?.performDrag(with: event)
    }

    /// The folders the file is in, the nearest first, each of which shows in the Finder when chosen (nil without a file).
    func pathMenu() -> NSMenu? {
        guard let url = fileURL else { return nil }
        let menu = NSMenu(title: name)
        var folder = url.deletingLastPathComponent()
        while true {
            let item = NSMenuItem(title: folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent, action: #selector(revealFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            item.image = NSWorkspace.shared.icon(forFile: folder.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path || folder.path == "/" { break }
            folder = parent
        }
        return menu
    }

    @objc private func revealFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        Self.openFolder(folder)
    }
}

/// AppKit's own title views (the title, its icon, the "Edited" button and the dash before it) are kept hidden
/// while the app draws its own: `titleVisibility = .hidden` takes only the first two, and AppKit adds the others as the
/// document becomes edited and clean.
enum SystemTitle {
    static func isSystemTitleView(_ v: NSView) -> Bool {
        if v is NSTextField { return true }
        let name = "\(type(of: v))"
        return name.hasPrefix("NSThemeAutosave") || name.hasPrefix("NSThemeDocument") || name.hasPrefix("NSButtonTextField")
    }

    /// The views in the window's title bar that are AppKit's title, shown or not.
    static func views(in window: NSWindow) -> [NSView] {
        guard let bar = window.standardWindowButton(.closeButton)?.superview else { return [] }
        return bar.subviews.filter(isSystemTitleView)
    }

    /// Hides them; returns whether any was showing.
    @discardableResult
    static func hide(in window: NSWindow) -> Bool {
        var changed = false
        for v in views(in: window) where !v.isHidden {
            v.isHidden = true
            changed = true
        }
        return changed
    }
}
