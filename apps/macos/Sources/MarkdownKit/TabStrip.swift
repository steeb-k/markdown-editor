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

    /// Which ends of the strip have tabs beyond them: some are scrolled out on the left (the offset is
    /// positive), some lie past the right edge (the offset has not reached the end).
    static func overflow(count: Int, tabWidth: CGFloat, available: CGFloat, offset: CGFloat) -> (left: Bool, right: Bool) {
        let total = tabWidth * CGFloat(count)
        guard count > 0, total > available + 0.5 else { return (false, false) }
        return (offset > 0.5, offset < total - available - 0.5)
    }

    /// Where a tab's close button begins, from the tab's left edge.
    static let closeButtonInset: CGFloat = 6

    /// How much of the row a chevron covers when there is room for one at each end beside a whole tab, else
    /// nothing (the chevrons are then all there is to see of them, and the tabs keep to plain multiples).
    static func chevronWidth(tabWidth: CGFloat, available: CGFloat) -> CGFloat {
        available >= tabWidth + 2 * TabOverflowButton.width ? TabOverflowButton.width : 0
    }

    /// The offset at which tab `k` begins just right of the left chevron (the first tab: at the strip's start),
    /// so that its close button and title are never under the chevron's fade.
    static func stop(_ k: Int, tabWidth: CGFloat, chevron: CGFloat, maxOffset: CGFloat) -> CGFloat {
        k <= 0 ? 0 : min(maxOffset, CGFloat(k) * tabWidth - chevron)
    }

    /// The first tab whose close button is clear of the left chevron at this offset (a tab under the chevron
    /// is one of those it says are hidden).
    static func firstClearTab(offset: CGFloat, tabWidth: CGFloat, chevron: CGFloat) -> Int {
        let edge = offset > 0.5 ? offset + max(0, chevron - closeButtonInset) : offset
        return max(0, Int(((edge - 0.5) / max(tabWidth, 1)).rounded(.up)))
    }

    /// The offset after scrolling by `tabs` tabs (negative: to the left), kept within what there is. Each press
    /// brings one more tab out from under the chevron: the next tab then begins where the left chevron ends.
    static func scrolled(by tabs: Int, tabWidth: CGFloat, count: Int, available: CGFloat, chevron: CGFloat = 0, from offset: CGFloat) -> CGFloat {
        let maxOffset = max(0, tabWidth * CGFloat(count) - available)
        var e = min(max(0, offset), maxOffset)
        for _ in 0..<abs(tabs) {
            let first = firstClearTab(offset: e, tabWidth: tabWidth, chevron: chevron)
            e = stop(tabs > 0 ? first + 1 : first - 1, tabWidth: tabWidth, chevron: chevron, maxOffset: maxOffset)
        }
        return e
    }

    /// How far the strip is scrolled so that tab `index` is fully in view, and clear of the chevrons, given the
    /// offset now.
    static func scrollOffset(revealing index: Int, tabWidth: CGFloat, count: Int, available: CGFloat, chevron: CGFloat = 0, current: CGFloat) -> CGFloat {
        let total = tabWidth * CGFloat(count)
        let maxOffset = max(0, total - available)
        var offset = min(max(0, current), maxOffset)
        let left = tabWidth * CGFloat(index), right = left + tabWidth
        if index < firstClearTab(offset: offset, tabWidth: tabWidth, chevron: chevron) {
            offset = stop(index, tabWidth: tabWidth, chevron: chevron, maxOffset: maxOffset)
        } else if right > offset + available - (offset < maxOffset - 0.5 ? chevron : 0) + 0.5 {
            offset = right - available + chevron
        }
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
    /// The tabs sit in a clip view; its left edge is `leadingInset` from the strip's own (notes mode: the strip
    /// runs the width of the title bar, the tabs only above the editor, and what is scrolled out of the clip
    /// is cut off there, never drawn over the sidebar).
    private let clip = NSView()
    private let content = NSView()
    private var dragging: TabView?
    var leadingInset: CGFloat = 0 {
        didSet { if leadingInset != oldValue { needsLayout = true } }
    }
    /// ... and its right edge is `trailingInset` short of the strip's (the outline column's room: the tabs end
    /// where it begins).
    var trailingInset: CGFloat = 0 {
        didSet { if trailingInset != oldValue { needsLayout = true } }
    }
    /// The chevrons at the clip's two ends, over the tabs, each with the edge of the tab beneath faded out.
    let leftChevron = TabOverflowButton(direction: -1)
    let rightChevron = TabOverflowButton(direction: 1)
    /// What the tab's edge fades into: the window's colour behind the title row.
    var fadeColor: NSColor = .windowBackgroundColor {
        didSet { leftChevron.fadeColor = fadeColor; rightChevron.fadeColor = fadeColor }
    }
    /// Which ends have tabs beyond them (as of the last layout).
    private(set) var overflow: (left: Bool, right: Bool) = (false, false)
    /// The room the tabs have.
    var available: CGFloat { max(0, bounds.width - leadingInset - trailingInset) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        content.wantsLayer = true
        addSubview(clip)
        clip.addSubview(content)
        for chevron in [leftChevron, rightChevron] {
            chevron.isHidden = true
            chevron.onPress = { [weak self] direction in self?.scrollByOneTab(direction) }
            addSubview(chevron)
        }
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
        autoresizingMask = [.height]
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// A click on a tab of a window in the background selects it at once, as a title bar's
    /// own controls do (and a drag on the strip moves the window).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var tabWidth: CGFloat { TabStripModel.tabWidth(count: entries.count, available: available) }
    /// What a chevron covers of the tabs' room.
    var chevronWidth: CGFloat { TabStripModel.chevronWidth(tabWidth: tabWidth, available: available) }

    func setEntries(_ new: [TabEntry]) {
        guard new != entries || tabViews.count != new.count else { return }
        // Only another tab selected, or tabs added or closed, bring the selected tab into view: a title or an
        // edited dot that changes (an autosave, a rename) must not take away a scroll of the user's.
        let reveal = new.count != entries.count || new.first(where: \.selected)?.windowNumber != entries.first(where: \.selected)?.windowNumber
        entries = new
        while tabViews.count > new.count { tabViews.removeLast().removeFromSuperview() }
        while tabViews.count < new.count {
            let t = TabView(strip: self)
            content.addSubview(t)
            tabViews.append(t)
        }
        for (view, entry) in zip(tabViews, new) { view.entry = entry }
        if reveal { revealSelected() }
        needsLayout = true
        updateAccessibilityChildren()
    }

    /// The tabs, and the chevrons that show: an explicit list of children would otherwise leave the chevrons out of
    /// what VoiceOver can reach.
    private func updateAccessibilityChildren() {
        let left: [NSView] = leftChevron.isHidden ? [] : [leftChevron], right: [NSView] = rightChevron.isHidden ? [] : [rightChevron]
        setAccessibilityChildren(left + tabViews + right)
    }

    /// Scrolls so that the selected tab is in view.
    private func revealSelected() {
        guard let i = entries.firstIndex(where: \.selected) else { return }
        scrollOffset = TabStripModel.scrollOffset(revealing: i, tabWidth: tabWidth, count: entries.count, available: available,
                                                  chevron: chevronWidth, current: scrollOffset)
    }

    /// The room the tabs had at the last layout: when it changes (a window resized, the divider dragged) the
    /// selected tab is kept in view; a scroll of the user's own leaves where it is.
    private var laidOutAvailable: CGFloat = -1

    override func layout() {
        super.layout()
        if abs(available - laidOutAvailable) > 0.5 {
            laidOutAvailable = available
            revealSelected()
        }
        let w = tabWidth
        let total = w * CGFloat(entries.count)
        scrollOffset = min(max(0, scrollOffset), max(0, total - available))
        clip.frame = NSRect(x: leadingInset, y: 0, width: available, height: bounds.height)
        content.frame = NSRect(x: -scrollOffset, y: 0, width: max(total, available), height: bounds.height)
        updateChevrons()
        let h = min(bounds.height - 4, 24)
        for (i, t) in tabViews.enumerated() {
            t.frame = NSRect(x: CGFloat(i) * w, y: (bounds.height - h) / 2, width: w, height: h)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let total = tabWidth * CGFloat(entries.count)
        guard total > available else { return }
        scrollOffset = min(max(0, scrollOffset - delta), total - available)
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

    /// The chevrons show on the sides that have tabs beyond them, inside the strip's own width, at the clip's edges.
    private func updateChevrons() {
        overflow = TabStripModel.overflow(count: entries.count, tabWidth: tabWidth, available: available, offset: scrollOffset)
        let width = TabOverflowButton.width
        leftChevron.frame = NSRect(x: clip.frame.minX, y: 0, width: min(width, available), height: bounds.height)
        rightChevron.frame = NSRect(x: clip.frame.maxX - min(width, available), y: 0, width: min(width, available), height: bounds.height)
        if leftChevron.isHidden == overflow.left || rightChevron.isHidden == overflow.right {
            leftChevron.isHidden = !overflow.left
            rightChevron.isHidden = !overflow.right
            updateAccessibilityChildren()
        }
    }

    /// A press on a chevron: the tabs move by one tab towards that side.
    func scrollByOneTab(_ direction: Int) {
        let before = scrollOffset
        scrollOffset = TabStripModel.scrolled(by: direction, tabWidth: tabWidth, count: entries.count, available: available,
                                              chevron: chevronWidth, from: scrollOffset)
        if scrollOffset != before { needsLayout = true; layoutSubtreeIfNeeded() }
    }

    /// Scrolls to a fraction of the way (0: the first tab at the left edge, 1: the last at the right edge).
    func scroll(toFraction f: CGFloat) {
        let maxOffset = max(0, tabWidth * CGFloat(entries.count) - available)
        scrollOffset = min(max(0, f), 1) * maxOffset
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func index(at x: CGFloat) -> Int {
        let w = tabWidth
        return min(max(0, Int((x - leadingInset + scrollOffset) / max(w, 1))), max(0, entries.count - 1))
    }

    /// What can be seen of each tab, in the strip's own coordinates: the part inside the clip (a tab scrolled
    /// out on the left shows nothing, and so takes no clicks, left of where the tabs begin).
    var visibleTabFrames: [NSRect] {
        let area = clip.frame
        return tabViews.map { clip.convert($0.frame, from: content).offsetBy(dx: area.minX, dy: area.minY).intersection(area) }
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var closeRect: NSRect { NSRect(x: TabStripModel.closeButtonInset, y: (bounds.height - 16) / 2, width: 16, height: 16) }

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
        // In the middle, as Finder shortens file names: narrow tabs of "Untitled 2" to "Untitled 12"
        // all read "Untitle…" cut at the end.
        style.lineBreakMode = .byTruncatingMiddle
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

/// The mark that says there are more tabs beyond this edge of the strip: a chevron in the secondary colour on
/// a short fade of the strip's background, so that the tab under it does not end in a hard cut. Pressing it scrolls
/// by one tab.
final class TabOverflowButton: NSView {
    static let width: CGFloat = 30
    /// -1 at the left edge (earlier tabs), 1 at the right (later ones).
    let direction: Int
    var fadeColor: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var onPress: ((Int) -> Void)?

    init(direction: Int) {
        self.direction = direction
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(direction < 0 ? "Show earlier tabs" : "Show later tabs")
        toolTip = direction < 0 ? "Earlier tabs" : "Later tabs"
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // The fade: solid at the edge of the clip, clear where the tabs go on.
        let solid = fadeColor.withAlphaComponent(0.95), clear = fadeColor.withAlphaComponent(0)
        let g = direction < 0 ? NSGradient(colorsAndLocations: (solid, 0), (solid, 0.45), (clear, 1))
                              : NSGradient(colorsAndLocations: (clear, 0), (solid, 0.55), (solid, 1))
        g?.draw(in: bounds, angle: 0)
        let name = direction < 0 ? "chevron.left" : "chevron.right"
        // The secondary label colour as this view's appearance resolves it.
        var tint = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance { tint = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? tint }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = glyph.size
        let x = direction < 0 ? bounds.minX + 5 : bounds.maxX - size.width - 5
        glyph.draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) { onPress?(direction) }

    override func accessibilityPerformPress() -> Bool {
        onPress?(direction)
        return true
    }
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
    /// Told when this window joined, left or changed a tab group, or the group's windows changed.
    var onGroupChange: (() -> Void)?
    /// Where the tabs begin, as an x in the window: nil for the whole row (the strip starts after the window
    /// buttons), the editor pane's left edge in notes mode (the row above the sidebar is the sidebar's).
    var tabsBegin: (() -> CGFloat?)?
    /// Where the tabs end, as an x in the window: nil for the strip's own right edge, the outline column's left
    /// edge while it is shown.
    var tabsEnd: (() -> CGFloat?)?
    /// The strip shows even for a lone tab (notes mode: the window's title would otherwise be drawn over the
    /// sidebar).
    var showsSingleTab: (() -> Bool)?
    /// Told when the group's selected tab changed (every window of the group hears it).
    var onSelectedTabChange: (() -> Void)?
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
        // A tab's edited dot and title: its window's, which every strip of the group draws. They
        // change with no event to follow (a save finishing off the main thread, a script's edit).
        windowObservations.append(window.observe(\.isDocumentEdited, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshGroup() }
        })
        windowObservations.append(window.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshGroup() }
        })
        groupChanged()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func groupChanged() {
        groupObservations.removeAll()
        defer { onGroupChange?() }
        guard let group = window?.tabGroup else { refresh(); return }
        groupObservations.append(group.observe(\.windows, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onGroupChange?()
            }
        })
        groupObservations.append(group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onSelectedTabChange?()
            }
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
    ///
    /// Never re-entered: an earlier version toggled the bar from inside the tab group's observation,
    /// AppKit's answer fired the observation again, and the recursion overflowed the stack (a crash
    /// on 2026-10-02). Hiding an accessory does not touch the group, but a call that arrives while one
    /// is in progress is counted and dropped all the same.
    private func putNativeBarAway() {
        guard let window else { return }
        guard hidingDepth == 0 else { reentries += 1; return }
        hidingDepth += 1
        defer { hidingDepth -= 1 }
        for vc in window.titlebarAccessoryViewControllers where vc !== accessory && !vc.isHidden && Self.isNativeTabBar(vc.view) {
            vc.isHidden = true
            nativeBarHidden += 1
        }
    }

    private var hidingDepth = 0
    private var refreshDepth = 0
    /// Instrumentation: calls that arrived while the strip was already hiding the bar or refreshing
    /// (an observation fired by our own change). Zero in every test.
    private(set) var reentries = 0

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
        guard refreshDepth == 0 else { reentries += 1; return }
        refreshDepth += 1
        defer { refreshDepth -= 1 }
        putNativeBarAway()
        let entries = TabStripModel.entries(of: window)
        let shown = entries.count >= 2 || (showsSingleTab?() ?? false)
        if shown != isShown {
            isShown = shown
            accessory.isHidden = !shown
            strip.isHidden = !shown
            window.titleVisibility = shown ? .hidden : .visible
        }
        // The title's document icon and its versions menu stay behind when the title is hidden
        // (AppKit put them at the far right of the row, beside the strip): they go with the title.
        for kind in [NSWindow.ButtonType.documentIconButton, .documentVersionsButton] {
            if let b = window.standardWindowButton(kind), b.isHidden != shown { b.isHidden = shown }
        }
        // The strip fills the row between the window buttons and the trailing edge.
        let width = max(0, window.frame.width - Self.leadingClearance - Self.trailingClearance)
        if abs(strip.frame.width - width) >= 0.5 {
            strip.setFrameSize(NSSize(width: width, height: strip.frame.height))
        }
        // Where the strip itself starts, in the window (AppKit puts it after the window buttons).
        if let begin = tabsBegin?() {
            let left = strip.superview != nil ? strip.convert(NSPoint.zero, to: nil).x : Self.leadingClearance
            strip.leadingInset = max(0, (begin - left).rounded(.up))
        } else {
            strip.leadingInset = 0
        }
        if let end = tabsEnd?(), strip.superview != nil {
            let right = strip.convert(NSPoint(x: strip.bounds.maxX, y: 0), to: nil).x
            strip.trailingInset = max(0, (right - end).rounded(.up))
        } else {
            strip.trailingInset = 0
        }
        strip.setEntries(entries)
    }

    /// Every strip of the group (each window has its own; only the selected one is seen).
    func refreshGroup() {
        guard let window else { return }
        for w in window.tabGroup?.windows ?? [window] {
            if w === window { refresh() } else { (w.windowController as? EditorWindowController)?.tabs?.refresh() }
        }
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
