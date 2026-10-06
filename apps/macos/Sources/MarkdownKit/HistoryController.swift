import AppKit
import MarkdownCore

/// What the history panel shows, worked out with no views: the versions grouped by day, the words of a row, and the
/// diff as coloured text.
enum HistoryModel {
    struct Section: Equatable {
        let title: String
        let versions: [HistoryVersion]
    }

    /// The versions (newest first, as the core lists them) in a section for each calendar day, titled "Today",
    /// "Yesterday" or the date.
    static func sections(_ versions: [HistoryVersion], now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> [Section] {
        // Grouped first and made into sections after: a day with thousands of versions is one append each, not a copy
        // of the day so far (a section is a value, and adding to the one in `out` copied its array every time).
        var days: [(title: String, versions: [HistoryVersion])] = []
        var currentDay: Date?
        for v in versions {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(v.time)))
            if day != currentDay {
                currentDay = day
                days.append((dayTitle(day, now: now, calendar: calendar, locale: locale), []))
            }
            days[days.count - 1].versions.append(v)
        }
        return days.map { Section(title: $0.title, versions: $0.versions) }
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        // By the day, not by its first instant: where the clocks change at midnight a day starts at 01:00, and the day
        // before at 00:00, so "a day before today's start" is not yesterday's start.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: day) == calendar.component(.year, from: today) ? "EEEEdMMMM" : "EEEEdMMMMyyyy")
        return f.string(from: day)
    }

    static func timeText(_ v: HistoryVersion, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(v.time)))
    }

    static func reasonText(_ r: HistoryReason) -> String {
        switch r {
        case .pause: return "Pause"
        case .close: return "Close"
        case .save: return "Save"
        case .restore: return "Restore"
        case .draft: return "Draft"
        case .recovered: return "Recovered"
        }
    }

    /// `+3 −1`: the lines added and removed since the version before it.
    static func summary(_ v: HistoryVersion) -> String {
        var parts: [String] = []
        if v.added > 0 { parts.append("+\(v.added)") }
        if v.removed > 0 { parts.append("\u{2212}\(v.removed)") }
        return parts.isEmpty ? "no change" : parts.joined(separator: " ")
    }

    /// What VoiceOver says of a row.
    static func accessibilityLabel(_ v: HistoryVersion, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var s = "\(timeText(v, calendar: calendar, locale: locale)), \(reasonText(v.reason).lowercased())"
        if v.added > 0 { s += ", \(v.added) \(v.added == 1 ? "line" : "lines") added" }
        if v.removed > 0 { s += ", \(v.removed) \(v.removed == 1 ? "line" : "lines") removed" }
        if let m = v.message, !m.isEmpty { s += ", \(m)" }
        return s
    }

    // MARK: the diff

    /// How the diff is coloured: removed lines in the theme's reference colour, added lines in its AI colour, each
    /// muted (the text is a little lighter than the colour and the line has a faint wash of it), and the lines
    /// that did not change in the secondary colour.
    struct DiffStyle {
        let removed: NSColor
        let added: NSColor
        let equal: NSColor
        let font: NSFont
        static let wash: CGFloat = 0.14
        static let mute: CGFloat = 0.85

        init(palette: ThemePalette, secondary: NSColor, font: NSFont) {
            removed = palette.authorReference
            added = palette.authorAI
            equal = secondary
            self.font = font
        }
    }

    /// The unchanged lines kept on each side of a change; a longer stretch shows how many lines it hides.
    static let diffContext = 2

    /// The diff as text, one line each, `+ ` and `\u{2212} ` in front of what changed. The lines of a hunk go in as one
    /// run with its attributes made once, and of a long unchanged stretch only the lines shown are taken out of it (a
    /// one-line change in a megabyte is four lines of text, not the megabyte split into lines on the main thread).
    static func diffText(_ hunks: [HistoryHunk], style: DiffStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func attributes(_ color: NSColor, background: NSColor? = nil, italic: Bool = false) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: italic ? NSFontManager.shared.convert(style.font, toHaveTrait: .italicFontMask) : style.font,
                                                    .foregroundColor: color]
            if let background { a[.backgroundColor] = background }
            return a
        }
        let removed = attributes(style.removed.withAlphaComponent(DiffStyle.mute), background: style.removed.withAlphaComponent(DiffStyle.wash))
        let added = attributes(style.added.withAlphaComponent(DiffStyle.mute), background: style.added.withAlphaComponent(DiffStyle.wash))
        let equal = attributes(style.equal)
        let hiddenNote = attributes(style.equal.withAlphaComponent(0.7), italic: true)
        func append<S: Sequence>(_ lines: S, prefix: String, _ attrs: [NSAttributedString.Key: Any]) where S.Element: StringProtocol {
            var run = ""
            for l in lines {
                run += prefix
                run += l.contains("\r") ? l.replacingOccurrences(of: "\r", with: "") : String(l)
                run += "\n"
            }
            if !run.isEmpty { out.append(NSAttributedString(string: run, attributes: attrs)) }
        }
        for (i, h) in hunks.enumerated() {
            switch h.kind {
            case .removed: append(lines(h.text), prefix: "\u{2212} ", removed)
            case .added: append(lines(h.text), prefix: "+ ", added)
            case .equal:
                let c = diffContext
                let head = i == 0 ? 0 : c, tail = i == hunks.count - 1 ? 0 : c
                let count = lineCount(h.text)
                if count <= head + tail + 1 {
                    append(lines(h.text), prefix: "  ", equal)
                } else {
                    append(firstLines(h.text, head), prefix: "  ", equal)
                    let hidden = count - head - tail
                    append(["\u{22EF} \(hidden) unchanged \(hidden == 1 ? "line" : "lines")"], prefix: "  ", hiddenNote)
                    append(lastLines(h.text, tail), prefix: "  ", equal)
                }
            }
        }
        return out
    }

    /// The lines of a hunk's text, without their terminators (a final line ending gives no empty line after it). Split on
    /// the byte: a Swift `Character` holds "\r\n" whole, so splitting the characters on "\n" would miss every CRLF line.
    static func lines(_ text: String) -> [String] {
        var l = text.utf8.split(separator: 10, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if l.last == "" { l.removeLast() }
        return l
    }

    /// How many lines `lines` would give, counted without making them.
    static func lineCount(_ text: String) -> Int {
        var text = text
        return text.withUTF8 { buf -> Int in
            guard let base = buf.baseAddress, buf.count > 0 else { return 0 }
            var n = 0
            var p = UnsafeRawPointer(base)
            let end = p + buf.count
            while p < end, let hit = memchr(p, 10, end - p) {
                n += 1
                p = UnsafeRawPointer(hit) + 1
            }
            return buf[buf.count - 1] == 10 ? n : n + 1
        }
    }

    /// The first `n` lines (n below the count).
    static func firstLines(_ text: String, _ n: Int) -> [String] {
        guard n > 0 else { return [] }
        let u = text.utf8
        var seen = 0
        var end = u.endIndex
        var i = u.startIndex
        while i < u.endIndex {
            if u[i] == 10 {
                seen += 1
                if seen == n { end = i; break }
            }
            i = u.index(after: i)
        }
        // Everything before the n-th line ending: n lines, the last of them possibly empty.
        return u[..<end].split(separator: 10, omittingEmptySubsequences: false).prefix(n).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The last `n` lines (n below the count).
    static func lastLines(_ text: String, _ n: Int) -> [String] {
        guard n > 0 else { return [] }
        let u = text.utf8
        var start = u.startIndex
        var seen = 0
        var i = u.endIndex
        // A final line ending closes the last line; it does not start one.
        if let last = u.last, last == 10 { i = u.index(before: i) }
        while i > u.startIndex {
            let j = u.index(before: i)
            if u[j] == 10 {
                seen += 1
                if seen == n { start = i; break }
            }
            i = j
        }
        return Array(lines(String(decoding: u[start...], as: UTF8.self)).suffix(n))
    }
}

// MARK: - the views

/// A day's title in the list.
private final class HistoryDayRow: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: max(0, bounds.width - 20), height: 14)
    }
}

/// One version: the time, the reason and the summary, and the message under them when there is one.
final class HistoryRowView: NSTableCellView {
    let time = NSTextField(labelWithString: "")
    let reason = NSTextField(labelWithString: "")
    let summary = NSTextField(labelWithString: "")
    let message = NSTextField(labelWithString: "")
    private(set) var hasMessage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        reason.font = .systemFont(ofSize: 11)
        summary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summary.alignment = .right
        message.font = .systemFont(ofSize: 11)
        message.lineBreakMode = .byTruncatingTail
        for v in [time, reason, summary, message] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    static let plainHeight: CGFloat = 24
    static let messageHeight: CGFloat = 40

    func configure(_ v: HistoryVersion, style: SidebarStyle, selected: Bool) {
        time.stringValue = HistoryModel.timeText(v)
        reason.stringValue = HistoryModel.reasonText(v.reason)
        summary.stringValue = HistoryModel.summary(v)
        message.stringValue = v.message ?? ""
        hasMessage = !(v.message ?? "").isEmpty
        message.isHidden = !hasMessage
        let strong: NSColor = selected ? .alternateSelectedControlTextColor : style.text
        let weak: NSColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : style.secondary
        time.textColor = strong
        reason.textColor = weak
        summary.textColor = weak
        message.textColor = weak
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(HistoryModel.accessibilityLabel(v))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // (Not flipped: y runs up. The first line is at the top, the message under it.)
        let rowY: CGFloat = hasMessage ? bounds.height - 6 - 16 : (bounds.height - 16) / 2
        time.sizeToFit()
        time.frame = NSRect(x: 10, y: rowY, width: time.frame.width, height: 16)
        summary.sizeToFit()
        let sw = summary.frame.width
        summary.frame = NSRect(x: w - sw - 10, y: rowY, width: sw, height: 16)
        reason.sizeToFit()
        reason.frame = NSRect(x: time.frame.maxX + 8, y: rowY, width: max(0, min(reason.frame.width, summary.frame.minX - time.frame.maxX - 12)), height: 16)
        message.frame = NSRect(x: 10, y: 5, width: max(0, w - 20), height: 14)
    }
}

/// Rows with a selection that reads in the theme's own colours (the system's blue would not).
private final class HistoryTableRow: NSTableRowView {
    var tint: NSColor = .selectedContentBackgroundColor
    override func drawSelection(in dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// The list takes Return as Restore would not (it only moves) and never the keyboard from the editor on its own.
final class HistoryListView: NSTableView {}

/// The history column: the versions below the title bar (which it runs under, like the sidebar and the outline), the
/// diff of the selected one against the text as it is now below them, and the buttons.
final class HistoryView: NSView {
    let scroll = NSScrollView()
    let list = HistoryListView()
    let diffScroll = NSScrollView()
    let diff = NSTextView()
    let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let band = TitlebarBandView()
    private let empty = NSTextField(labelWithString: "No versions yet")
    private let hint = NSTextField(labelWithString: "Select a version to see what changed.")
    var style: SidebarStyle { didSet { apply() } }
    var diffStyle: HistoryModel.DiffStyle

    static let buttonBar: CGFloat = 40

    init(style: SidebarStyle, diffStyle: HistoryModel.DiffStyle) {
        self.style = style
        self.diffStyle = diffStyle
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        list.addTableColumn(column)
        list.headerView = nil
        list.style = .sourceList
        list.rowSizeStyle = .default
        list.floatsGroupRows = false
        list.allowsMultipleSelection = false
        list.allowsEmptySelection = true
        list.backgroundColor = .clear
        list.setAccessibilityLabel("History")
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        diff.isEditable = false
        diff.isSelectable = true
        diff.isRichText = true
        diff.drawsBackground = false
        diff.textContainerInset = NSSize(width: 8, height: 8)
        diff.isHorizontallyResizable = false
        diff.isVerticallyResizable = true
        diff.autoresizingMask = [.width]
        diff.textContainer?.widthTracksTextView = true
        diff.setAccessibilityLabel("Changes in the selected version")
        diffScroll.documentView = diff
        diffScroll.hasVerticalScroller = true
        diffScroll.autohidesScrollers = true
        diffScroll.scrollerStyle = .overlay
        diffScroll.drawsBackground = false
        diffScroll.borderType = .noBorder
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.isHidden = true
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 11)
        for b in [restoreButton, copyButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.isEnabled = false
        }
        restoreButton.setAccessibilityLabel("Restore this version")
        copyButton.setAccessibilityLabel("Copy this version's text")
        for v in [scroll, diffScroll, empty, hint, restoreButton, copyButton, band] as [NSView] { addSubview(v) }
        band.isHidden = embedded
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    var showsEmptyState = false { didSet { empty.isHidden = !showsEmptyState; needsLayout = true } }
    /// Whether a version is selected (the hint shows when none is).
    var showsHint = true { didSet { hint.isHidden = !showsHint } }

    /// In the side column, which has the title bar's row and the header above its panes: this view starts where its room
    /// does, and has no band of its own.
    var embedded = true { didSet { band.isHidden = embedded; needsLayout = true } }

    /// What the title bar takes from the top (the view runs under it when it is the window's own column).
    var topInset: CGFloat {
        if embedded { return 0 }
        guard let w = window else { return 28 }
        return max(0, w.frame.height - w.contentLayoutRect.height)
    }

    /// Where the list ends and the diff begins.
    var listBottom: CGFloat {
        let top = topInset + 6
        let room = max(0, bounds.height - top - Self.buttonBar)
        return top + (room * 0.45).rounded()
    }

    private func apply() {
        empty.textColor = style.secondary
        hint.textColor = style.secondary
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let top = topInset
        band.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        let split = listBottom
        scroll.frame = NSRect(x: 0, y: top + 6, width: bounds.width, height: max(0, split - top - 6))
        let diffTop = split + 1
        diffScroll.frame = NSRect(x: 0, y: diffTop, width: bounds.width, height: max(0, bounds.height - Self.buttonBar - diffTop))
        hint.frame = NSRect(x: 8, y: diffTop + 16, width: max(0, bounds.width - 16), height: 16)
        empty.frame = NSRect(x: 8, y: top + 24, width: max(0, bounds.width - 16), height: 18)
        let by = bounds.height - Self.buttonBar + 8
        restoreButton.sizeToFit()
        copyButton.sizeToFit()
        copyButton.frame.origin = NSPoint(x: bounds.width - copyButton.frame.width - 10, y: by)
        restoreButton.frame.origin = NSPoint(x: copyButton.frame.minX - restoreButton.frame.width - 6, y: by)
    }

    override func draw(_ dirtyRect: NSRect) {
        style.background.setFill()
        bounds.fill()
        style.rule.setFill()
        NSRect(x: 0, y: listBottom, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - Self.buttonBar, width: bounds.width, height: 1).fill()
    }
}

// MARK: - the controller

/// The history column's list of versions of the document in its window: asked of the core's store off the main thread,
/// updated when a snapshot is recorded. It never decides what a restore does (the window does) and never takes the
/// keyboard by itself.
@MainActor
final class HistoryController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Item: Equatable {
        case day(String)
        case version(HistoryVersion)
    }

    let view: HistoryView
    private(set) var items: [Item] = []
    private(set) var versions: [HistoryVersion] = []
    private(set) var selectedID: UInt64?
    private var observer: NSObjectProtocol?
    private var generation = 0

    /// What the panel shows history of: the service, the document's key, and the text as it is now.
    var service: HistoryService? { didSet { if service !== oldValue { rebind() } } }
    var key: String? { didSet { if key != oldValue { selectedID = nil; reload() } } }
    var currentText: () -> String = { "" }
    /// The user pressed Restore on a version, with its text.
    var onRestore: ((HistoryVersion, String) -> Void)?
    /// Instrumentation: reloads, and diffs shown.
    private(set) var reloads = 0
    private(set) var diffsShown = 0

    init(style: SidebarStyle, diffStyle: HistoryModel.DiffStyle) {
        view = HistoryView(style: style, diffStyle: diffStyle)
        super.init()
        view.list.dataSource = self
        view.list.delegate = self
        view.restoreButton.target = self
        view.restoreButton.action = #selector(restore(_:))
        view.copyButton.target = self
        view.copyButton.action = #selector(copy(_:))
        observer = NotificationCenter.default.addObserver(forName: .historyDidRecord, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as AnyObject?) === self.service, note.userInfo?["key"] as? String == self.key else { return }
                self.reload()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func rebind() { reload() }

    func styleChanged(style: SidebarStyle, diffStyle: HistoryModel.DiffStyle) {
        view.style = style
        view.diffStyle = diffStyle
        view.list.reloadData()
        restoreSelection()
        refreshDiff()
    }

    // MARK: the versions

    /// Asks the store for the versions of the document (the answer comes back on the main thread); the selected
    /// version stays selected when it is still there.
    func reload() {
        generation += 1
        let mine = generation
        guard let service, let key else {
            apply([])
            return
        }
        service.versions(key: key) { [weak self] v in
            guard let self, mine == generation else { return }
            reloads += 1
            apply(v)
        }
    }

    /// Shows `v` (newest first) without asking the store (tests).
    func apply(_ v: [HistoryVersion]) {
        versions = v
        items = []
        for s in HistoryModel.sections(v) {
            items.append(.day(s.title))
            items += s.versions.map(Item.version)
        }
        if let id = selectedID, !v.contains(where: { $0.id == id }) { selectedID = nil }
        view.list.reloadData()
        view.showsEmptyState = v.isEmpty
        restoreSelection()
        refreshDiff()
    }

    private func restoreSelection() {
        guard let id = selectedID, let row = items.firstIndex(where: { if case .version(let x) = $0 { return x.id == id } else { return false } }) else {
            view.list.deselectAll(nil)
            return
        }
        if view.list.selectedRow != row { view.list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    var selectedVersion: HistoryVersion? { versions.first { $0.id == selectedID } }

    /// Selects a version by its id (what a click on its row does).
    func select(id: UInt64?) {
        selectedID = id
        restoreSelection()
        refreshDiff()
    }

    // MARK: the diff

    /// The selected version against the text as it is now, worked out by the store off the main thread.
    func refreshDiff() {
        let selected = selectedVersion
        view.restoreButton.isEnabled = selected != nil
        view.copyButton.isEnabled = selected != nil
        view.showsHint = selected == nil
        guard let selected, let service, let key else {
            view.diff.textStorage?.setAttributedString(NSAttributedString())
            return
        }
        let id = selected.id
        let style = view.diffStyle
        service.diff(key: key, id: id, current: currentText()) { [weak self] hunks in
            guard let self, selectedID == id else { return }
            let text: NSAttributedString
            if let hunks, hunks.allSatisfy({ $0.kind == .equal }) {
                text = NSAttributedString(string: "Same as the text now.", attributes: [.font: style.font, .foregroundColor: style.equal])
            } else if let hunks {
                text = HistoryModel.diffText(hunks, style: style)
            } else {
                text = NSAttributedString(string: "This version's text is gone.", attributes: [.font: style.font, .foregroundColor: style.equal])
            }
            view.diff.textStorage?.setAttributedString(text)
            diffsShown += 1
        }
    }

    // MARK: Restore and Copy

    @objc private func restore(_ sender: Any?) { restoreSelected() }
    @objc private func copy(_ sender: Any?) { copySelected() }

    func restoreSelected() {
        guard let v = selectedVersion, let service, let key else { return }
        service.text(key: key, id: v.id) { [weak self] text in
            guard let text else { NSSound.beep(); return }
            self?.onRestore?(v, text)
        }
    }

    func copySelected(to pasteboard: NSPasteboard = .general, done: (() -> Void)? = nil) {
        guard let v = selectedVersion, let service, let key else { return }
        service.text(key: key, id: v.id) { text in
            guard let text else { NSSound.beep(); return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            done?()
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .day = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .version = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .day: return 22
        case .version(let v): return (v.message ?? "").isEmpty ? HistoryRowView.plainHeight : HistoryRowView.messageHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = HistoryTableRow()
        r.tint = view.style.accent.withAlphaComponent(0.85)
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .day(let title):
            let cell = HistoryDayRow()
            cell.label.stringValue = title
            cell.label.textColor = view.style.secondary
            cell.setAccessibilityLabel(title)
            return cell
        case .version(let v):
            let cell = HistoryRowView()
            cell.configure(v, style: view.style, selected: v.id == selectedID)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = view.list.selectedRow
        let id: UInt64?
        if row >= 0, row < items.count, case .version(let v) = items[row] { id = v.id } else { id = nil }
        guard id != selectedID else { return }
        let old = selectedID
        selectedID = id
        // The selected row's text turns light on the selection.
        for r in [old, id].compactMap({ $0 }) {
            if let i = items.firstIndex(where: { if case .version(let x) = $0 { return x.id == r } else { return false } }), case .version(let v) = items[i],
               let cell = view.list.view(atColumn: 0, row: i, makeIfNecessary: false) as? HistoryRowView {
                cell.configure(v, style: view.style, selected: r == id)
            }
        }
        refreshDiff()
    }
}
