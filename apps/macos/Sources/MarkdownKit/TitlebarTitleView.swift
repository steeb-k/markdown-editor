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
        // Never drawn outside its row (a row of no height, before the first layout or in full screen, drew the name over
        // the text below it).
        clipsToBounds = true
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
        // Narrower than "Edited" alone (a row hardly wider than its margins): that is cut too, never wider than the room.
        if p.total > availableWidth { p.status = max(0, availableWidth - Self.gap) }
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

    /// The folders the file is in, the nearest first, up to and including its volume, each of which shows in the Finder
    /// when chosen (nil without a file). Named as the Finder names them (the startup disk is "Macintosh HD", not "/",
    /// and a file on another disk ends at that disk, not at "Volumes" and "/").
    func pathMenu() -> NSMenu? {
        guard let url = fileURL else { return nil }
        let menu = NSMenu(title: name)
        for folder in Self.enclosingFolders(of: url) {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: folder.path), action: #selector(revealFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            item.image = NSWorkspace.shared.icon(forFile: folder.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        return menu
    }

    /// The folders `url` is in, the nearest first, ending with the volume's root.
    static func enclosingFolders(of url: URL) -> [URL] {
        var folders: [URL] = []
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while true {
            folders.append(folder)
            let isVolume = (try? folder.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
            let parent = folder.deletingLastPathComponent()
            if isVolume || folder.path == "/" || parent.path == folder.path { break }
            folder = parent
        }
        return folders
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

/// Renaming from the title: a popover under the name with the name in a field (the part before the extension
/// selected), Return renames, Escape or a click elsewhere leaves it. AppKit's own (`NSDocument.rename`) anchors to its
/// title views, which are hidden while the app draws its own title: it showed nothing at all (found in the M8f test pass).
/// The file is moved by `NSDocument.move(to:)`, as AppKit's rename does, so the history follows (`fileURL`'s `didSet`).
@MainActor
final class TitleRenamer: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    let popover = NSPopover()
    let field = NSTextField(string: "")
    private let original: String
    private let commit: (String) -> Void
    private var done = false
    /// The popover closed (renamed or not).
    var onClose: (() -> Void)?

    init(name: String, commit: @escaping (String) -> Void) {
        original = name
        self.commit = commit
        super.init()
        field.stringValue = name
        field.font = TitlebarTitleView.titleFont
        field.alignment = .center
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel("Name")
        field.setAccessibilityIdentifier("rename-field")
        let label = NSTextField(labelWithString: "Name:")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        label.frame = NSRect(x: 14, y: 34, width: 252, height: 16)
        field.frame = NSRect(x: 14, y: 10, width: 252, height: 22)
        view.addSubview(label)
        view.addSubview(field)
        let vc = NSViewController()
        vc.view = view
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(field)
        // The name without its extension selected, as the Finder does.
        let stem = (original as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(rename: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(rename: false)
            return true
        default:
            return false
        }
    }

    func finish(rename: Bool) {
        guard !done else { return }
        done = true
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        popover.close()
        closed()
        if rename, !name.isEmpty, name != original { commit(name) }
    }

    func popoverDidClose(_ notification: Notification) {
        done = true
        closed()
    }

    /// Said once, whichever way it closed.
    private func closed() {
        let close = onClose
        onClose = nil
        close?()
    }

    /// Where a document called `original` goes when renamed `typed`: in the same folder, with the old extension if none
    /// was typed. Nil for a name that cannot be a file's (empty, a slash, a leading dot, too long).
    static func destination(for url: URL, typed: String) -> URL? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name.utf8.count <= 255 else { return nil }
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
}
