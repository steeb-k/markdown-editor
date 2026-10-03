import AppKit

/// What the window's title-bar double-click does, as the user set it in System Settings
/// (Desktop & Dock, "Double-click a window's title bar to"): zoom (the default), minimize or nothing.
enum TitlebarDoubleClick {
    case zoom, minimize, nothing

    /// `AppleActionOnDoubleClick` in the global domain: "Maximize" (when unset), "Minimize" or "None".
    /// (Older systems kept a Boolean, `AppleMiniaturizeOnDoubleClick`.)
    static func setting(_ defaults: UserDefaults = .standard) -> TitlebarDoubleClick {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .nothing
        case "Maximize", "Fill": return .zoom
        default: return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? .minimize : .zoom
        }
    }

    @MainActor
    func perform(on window: NSWindow?) {
        switch self {
        case .zoom: window?.performZoom(nil)
        case .minimize: window?.performMiniaturize(nil)
        case .nothing: break
        }
    }
}

// MARK: model

/// One tab as the strip shows it.
struct TabEntry: Equatable {
    let windowNumber: Int
    let title: String
    let edited: Bool
    let selected: Bool
}

enum TabStripModel {
    static let minimumTabWidth: CGFloat = 96
    static let maximumTabWidth: CGFloat = 220

    /// The name a tab carries: the document's, as the title bar would show it.
    static func title(of window: NSWindow) -> String {
        (window.windowController?.document as? NSDocument)?.displayName ?? window.title
    }

    /// The tabs of `window`'s group, in the group's order (a lone window is one tab).
    static func entries(of window: NSWindow) -> [TabEntry] {
        let windows = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window
        return (windows.isEmpty ? [window] : windows).map {
            TabEntry(windowNumber: $0.windowNumber, title: title(of: $0),
                     edited: (($0.windowController?.document as? NSDocument)?.isDocumentEdited ?? $0.isDocumentEdited), selected: $0 === selected)
        }
    }

    /// Each tab's width: an equal share of the room, between the least that shows a title and
    /// the most a title needs; beyond that the strip scrolls.
    static func tabWidth(count: Int, available: CGFloat) -> CGFloat {
        guard count > 0 else { return maximumTabWidth }
        return min(maximumTabWidth, max(minimumTabWidth, (available / CGFloat(count)).rounded(.down)))
    }

    /// How far the strip is scrolled so that tab `index` is fully in view, given the offset now.
    static func scrollOffset(revealing index: Int, tabWidth: CGFloat, count: Int, available: CGFloat, current: CGFloat) -> CGFloat {
        let total = tabWidth * CGFloat(count)
        let maxOffset = max(0, total - available)
        var offset = min(max(0, current), maxOffset)
        let left = tabWidth * CGFloat(index), right = left + tabWidth
        if left < offset { offset = left } else if right > offset + available { offset = right - available }
        return min(max(0, offset), maxOffset)
    }
}

// MARK: views

/// The compact tab strip that lives in the title-bar row, in place of the window title, when a
/// window has two or more tabs. It never grows the title bar: it is as high as the row.
final class TabStripView: NSView {
    private(set) var entries: [TabEntry] = []
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// A tab was dragged to another place: its window number and the index it now has.
    var onMove: ((Int, Int) -> Void)?
    /// The window is asked to do what a double-click on an empty title bar does.
    var onTitlebarClick: ((NSEvent) -> Void)?
    /// The chrome has faded: the tabs are invisible and take no clicks, but the strip is still a title bar.
    var isFaded = false {
        didSet { if isFaded != oldValue { window?.invalidateCursorRects(for: self); tabViews.forEach { $0.updateHover(false) } } }
    }
    private(set) var tabViews: [TabView] = []
    private(set) var scrollOffset: CGFloat = 0
    private let content = NSView()
    private var dragging: TabView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        content.wantsLayer = true
        addSubview(content)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        autoresizingMask = [.height]
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    var tabWidth: CGFloat { TabStripModel.tabWidth(count: entries.count, available: bounds.width) }

    func setEntries(_ new: [TabEntry]) {
        guard new != entries || tabViews.count != new.count else { return }
        entries = new
        while tabViews.count > new.count { tabViews.removeLast().removeFromSuperview() }
        while tabViews.count < new.count {
            let t = TabView(strip: self)
            content.addSubview(t)
            tabViews.append(t)
        }
        for (view, entry) in zip(tabViews, new) { view.entry = entry }
        if let i = new.firstIndex(where: \.selected) {
            scrollOffset = TabStripModel.scrollOffset(revealing: i, tabWidth: tabWidth, count: new.count, available: bounds.width, current: scrollOffset)
        }
        needsLayout = true
        setAccessibilityChildren(tabViews)
    }

    override func layout() {
        super.layout()
        let w = tabWidth
        let total = w * CGFloat(entries.count)
        scrollOffset = min(max(0, scrollOffset), max(0, total - bounds.width))
        content.frame = NSRect(x: -scrollOffset, y: 0, width: max(total, bounds.width), height: bounds.height)
        let h = min(bounds.height - 4, 24)
        for (i, t) in tabViews.enumerated() {
            t.frame = NSRect(x: CGFloat(i) * w, y: (bounds.height - h) / 2, width: w, height: h)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let total = tabWidth * CGFloat(entries.count)
        guard total > bounds.width else { return }
        scrollOffset = min(max(0, scrollOffset - delta), total - bounds.width)
        needsLayout = true
    }

    // A faded strip is just title bar: clicks on its tabs are the title bar's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return isFaded ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onTitlebarClick?(event)
        } else {
            window?.performDrag(with: event)
        }
    }

    func index(at x: CGFloat) -> Int {
        let w = tabWidth
        return min(max(0, Int((x + scrollOffset) / max(w, 1))), max(0, entries.count - 1))
    }

    // MARK: from the tabs

    func tabPressed(_ tab: TabView) {
        guard let e = tab.entry else { return }
        onSelect?(e.windowNumber)
    }

    func tabDragged(_ tab: TabView, event: NSEvent) {
        guard let e = tab.entry, let from = entries.firstIndex(where: { $0.windowNumber == e.windowNumber }) else { return }
        let to = index(at: convert(event.locationInWindow, from: nil).x)
        if to != from { onMove?(e.windowNumber, to) }
    }

    func tabCloseRequested(_ tab: TabView) {
        guard let e = tab.entry else { return }
        onClose?(e.windowNumber)
    }
}

/// One tab: the title, the edited dot, a close button while the pointer is over it.
final class TabView: NSView {
    weak var strip: TabStripView?
    var entry: TabEntry? {
        didSet {
            guard entry != oldValue else { return }
            needsDisplay = true
            setAccessibilityLabel(entry?.title)
            setAccessibilityValue(entry?.selected == true ? 1 : 0)
        }
    }
    private(set) var hovering = false
    private var area: NSTrackingArea?
    private var dragged = false

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)
        setAccessibilityRole(.radioButton)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private var closeRect: NSRect { NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16) }

    func updateHover(_ on: Bool) {
        let value = on && strip?.isFaded != true
        guard value != hovering else { return }
        hovering = value
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { updateHover(true) }
    override func mouseExited(with event: NSEvent) { updateHover(false) }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let body = bounds.insetBy(dx: 2, dy: 0)
        if entry.selected || hovering {
            NSColor.labelColor.withAlphaComponent(entry.selected ? 0.10 : 0.05).setFill()
            NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6).fill()
        }
        let marker = closeRect
        if hovering {
            let glyph = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
            NSColor.secondaryLabelColor.set()
            if let glyph {
                let size = glyph.size
                glyph.tinted(.secondaryLabelColor).draw(in: NSRect(x: marker.midX - size.width / 2, y: marker.midY - size.height / 2, width: size.width, height: size.height))
            }
        } else if entry.edited {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: marker.midX - 3, y: marker.midY - 3, width: 6, height: 6)).fill()
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center
        let font = NSFont.systemFont(ofSize: 12, weight: entry.selected ? .medium : .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: style,
            .foregroundColor: entry.selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        let height = ("Ag" as NSString).size(withAttributes: attributes).height
        let titleRect = NSRect(x: 24, y: (bounds.height - height) / 2, width: max(0, bounds.width - 48), height: height)
        (entry.title as NSString).draw(in: titleRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard strip?.isFaded != true else { strip?.mouseDown(with: event); return }
        dragged = false
        let p = convert(event.locationInWindow, from: nil)
        if (hovering || entry?.edited == true), closeRect.insetBy(dx: -2, dy: -4).contains(p) {
            strip?.tabCloseRequested(self)
            return
        }
        strip?.tabPressed(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard strip?.isFaded != true else { return }
        dragged = true
        strip?.tabDragged(self, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { strip?.tabCloseRequested(self) }
    }

    override func accessibilityPerformPress() -> Bool {
        strip?.tabPressed(self)
        return true
    }

    override func resetCursorRects() {}
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: controller

/// Puts a window's tabs in its title-bar row. The native tab bar (a second strip under the title
/// bar) is kept hidden whenever AppKit shows it; the tabs themselves stay native (`NSWindowTabGroup`:
/// Command-T, Show Next Tab, Merge All Windows, the Window menu) and this strip is only how they look.
@MainActor
final class TabStripController: NSObject {
    private weak var window: NSWindow?
    let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
    private let accessory = NSTitlebarAccessoryViewController()
    private var observers: [NSObjectProtocol] = []
    private var groupObservations: [NSKeyValueObservation] = []
    private var windowObservations: [NSKeyValueObservation] = []
    /// The strip shows the tabs: two or more.
    private(set) var isShown = false
    /// Instrumentation: how often the native tab bar had to be put away again.
    private(set) var nativeBarHidden = 0
    /// Space from the window's leading edge to the strip's (the three window buttons) and from its
    /// trailing edge.
    static let leadingClearance: CGFloat = 78
    static let trailingClearance: CGFloat = 10

    init(window: NSWindow) {
        self.window = window
        super.init()
        accessory.view = strip
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
        accessory.isHidden = true
        strip.isHidden = true
        strip.onSelect = { [weak self] number in self?.select(number) }
        strip.onClose = { [weak self] number in self?.close(number) }
        strip.onMove = { [weak self] number, index in self?.move(number, to: index) }
        strip.onTitlebarClick = { [weak self] _ in TitlebarDoubleClick.setting().perform(on: self?.window) }
        let nc = NotificationCenter.default
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        windowObservations.append(window.observe(\.tabGroup, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.groupChanged() }
        })
        groupChanged()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func groupChanged() {
        groupObservations.removeAll()
        guard let group = window?.tabGroup else { refresh(); return }
        groupObservations.append(group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        groupObservations.append(group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        groupObservations.append(group.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.putNativeBarAway() }
        })
        refresh()
    }

    /// AppKit shows its own tab bar each time a window joins a group: the user asked for the tabs
    /// to live in the title bar, so it is switched off again.
    /// AppKit shows its own tab bar (a second strip under the title bar: it is an accessory view
    /// controller like ours) each time a window joins a group. The user asked for the tabs to live
    /// in the title bar, so it is hidden whenever it shows: `toggleTabBar(_:)` does not stay
    /// (AppKit puts the bar back at once), hiding the accessory does.
    private func putNativeBarAway() {
        guard let window else { return }
        for vc in window.titlebarAccessoryViewControllers where vc !== accessory && !vc.isHidden && Self.isNativeTabBar(vc.view) {
            vc.isHidden = true
            nativeBarHidden += 1
        }
    }

    /// AppKit's own tab bar is on screen under the title bar.
    var nativeBarShowing: Bool {
        window?.titlebarAccessoryViewControllers.contains { $0 !== accessory && !$0.isHidden && Self.isNativeTabBar($0.view) } ?? false
    }

    static func isNativeTabBar(_ view: NSView, depth: Int = 0) -> Bool {
        if "\(type(of: view))".contains("TabBar") { return true }
        guard depth < 5 else { return false }
        return view.subviews.contains { isNativeTabBar($0, depth: depth + 1) }
    }

    func refresh() {
        guard let window else { return }
        putNativeBarAway()
        let entries = TabStripModel.entries(of: window)
        let shown = entries.count >= 2
        if shown != isShown {
            isShown = shown
            accessory.isHidden = !shown
            strip.isHidden = !shown
            window.titleVisibility = shown ? .hidden : .visible
        }
        // The strip fills the row between the window buttons and the trailing edge.
        let width = max(0, window.frame.width - Self.leadingClearance - Self.trailingClearance)
        if abs(strip.frame.width - width) >= 0.5 {
            strip.setFrameSize(NSSize(width: width, height: strip.frame.height))
        }
        strip.setEntries(entries)
    }

    private func tabWindow(_ number: Int) -> NSWindow? {
        (window?.tabGroup?.windows ?? []).first { $0.windowNumber == number }
    }

    func select(_ number: Int) {
        guard let target = tabWindow(number) else { return }
        window?.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    /// Closes a tab. A document with unsaved changes asks first, in its own window, which is brought
    /// forward for it; one without is simply closed (a window that is not the front one of its group
    /// is hidden, and AppKit's own close of it would only beep).
    func close(_ number: Int) {
        guard let target = tabWindow(number) else { return }
        if let doc = target.windowController?.document as? NSDocument, !doc.isDocumentEdited {
            doc.close()
        } else {
            select(number)
            target.performClose(nil)
        }
    }

    func move(_ number: Int, to index: Int) {
        guard let group = window?.tabGroup, let target = tabWindow(number) else { return }
        group.removeWindow(target)
        group.insertWindow(target, at: min(max(0, index), group.windows.count))
        group.selectedWindow = target
        refresh()
    }

    /// Fades with the chrome: invisible tabs must not take clicks.
    func setFaded(_ faded: Bool) { strip.isFaded = faded }
}
