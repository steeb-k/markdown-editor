import AppKit
import MarkdownCore

/// The language badge of a fenced code block, from the text view's side: drawing it on top of the
/// text, hit-testing a click, the menu of languages and the one undoable edit a choice makes, and the
/// badge as an accessibility element. The geometry is the layout manager's (`codeBadges`).
extension EditorTextView {
    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let lm = layoutManager as? EditorLayoutManager else { return }
        let origin = textContainerOrigin
        lm.drawCodeBadges(in: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), at: origin)
    }

    /// The badges in the part of the text the view shows (all of them, whether or not the caret hides one).
    func visibleCodeBadges(ignoringCaret: Bool = false) -> [CodeBadge] {
        guard let lm = layoutManager as? EditorLayoutManager, let tc = textContainer else { return [] }
        let local = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: local, in: tc)
        return lm.codeBadges(forGlyphRange: glyphs, ignoringCaret: ignoringCaret)
    }

    /// The badge under `viewPoint`, if the pill is showing there.
    func codeBadge(at viewPoint: NSPoint) -> CodeBadge? {
        guard let lm = layoutManager as? EditorLayoutManager, let tc = textContainer else { return nil }
        let p = containerPoint(viewPoint)
        let band = NSRect(x: 0, y: p.y - 40, width: tc.size.width + 2 * EditorLayoutManager.blockOutset.width, height: 80)
        return lm.codeBadge(at: p, visibleGlyphs: lm.glyphRange(forBoundingRectWithoutAdditionalLayout: band, in: tc))
    }

    /// The badge's frame in view coordinates.
    func viewFrame(of badge: CodeBadge) -> NSRect {
        badge.frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The caret moved: a badge it hides, or no longer hides, is drawn again.
    func codeBadgeCaretMoved() {
        let location = selectedRange().location
        defer { lastBadgeCaret = location }
        guard let storage = textStorage, storage.length > 0, let lm = layoutManager as? EditorLayoutManager else { return }
        for loc in Set([lastBadgeCaret ?? location, location]) {
            let at = min(max(0, loc), storage.length - 1)
            guard storage.attribute(.markdownCodeLanguage, at: at, effectiveRange: nil) != nil else { continue }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: at, length: 1), actualCharacterRange: nil)
            for badge in lm.codeBadges(forGlyphRange: glyphs, ignoringCaret: true) {
                setNeedsDisplay(viewFrame(of: badge).insetBy(dx: -3, dy: -3))
            }
        }
    }

    // MARK: click and menu

    /// A click on a badge opens the language menu (and goes no further: the caret stays).
    @discardableResult
    func handleBadgeClick(at viewPoint: NSPoint) -> Bool {
        guard session != nil, isEditable, !hasMarkedText(), let badge = codeBadge(at: viewPoint) else { return false }
        presentCodeLanguageMenu(forBlock: badge.block)
        return true
    }

    /// The menu of languages for the block at `block`: the common ones, a separator, then "All" as a
    /// submenu grouped by first letter. The block's current language is checked.
    func codeLanguageMenu(current: String?) -> NSMenu {
        let choices = codeLanguageChoiceList
        let menu = NSMenu(title: "Language")
        menu.autoenablesItems = false
        func item(_ c: CodeLanguageChoice) -> NSMenuItem {
            let i = NSMenuItem(title: c.display, action: #selector(chooseCodeLanguage(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = c.token
            i.state = c.display == current ? .on : .off
            return i
        }
        for c in choices where c.common { menu.addItem(item(c)) }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "All", action: nil, keyEquivalent: "")
        let allMenu = NSMenu(title: "All")
        allMenu.autoenablesItems = false
        var groups: [(letter: String, items: [NSMenuItem])] = []
        for c in choices.sorted(by: { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }) {
            let first = c.display.first.map { String($0).uppercased() } ?? "#"
            let letter = first.first?.isLetter == true ? first : "#"
            if groups.last?.letter == letter { groups[groups.count - 1].items.append(item(c)) } else { groups.append((letter, [item(c)])) }
        }
        for g in groups {
            let sub = NSMenuItem(title: g.letter, action: nil, keyEquivalent: "")
            let subMenu = NSMenu(title: g.letter)
            subMenu.autoenablesItems = false
            g.items.forEach(subMenu.addItem)
            sub.submenu = subMenu
            allMenu.addItem(sub)
        }
        all.submenu = allMenu
        menu.addItem(all)
        return menu
    }

    /// Opens the menu under the badge of the block at `block`. Where tests and the UI scripts do not
    /// want a menu that tracks the mouse, `codeMenuPresenter` takes it instead.
    @discardableResult
    func presentCodeLanguageMenu(forBlock block: NSRange) -> Bool {
        guard let badge = visibleCodeBadges(ignoringCaret: true).first(where: { $0.block.location == block.location }) ?? codeBadgeForBlock(at: block.location) else { return false }
        let menu = codeLanguageMenu(current: badge.text)
        codeMenuBlock = badge.block
        let frame = viewFrame(of: badge)
        let at = NSPoint(x: frame.minX, y: frame.maxY + 2)
        if let codeMenuPresenter { codeMenuPresenter(menu, at) } else { menu.popUp(positioning: nil, at: at, in: self) }
        return true
    }

    /// The badge of the block starting at `location` wherever it is (a block scrolled out of view).
    private func codeBadgeForBlock(at location: Int) -> CodeBadge? {
        guard let lm = layoutManager as? EditorLayoutManager, let storage = textStorage, location < storage.length else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        return lm.codeBadges(forGlyphRange: glyphs, ignoringCaret: true).first
    }

    @objc func chooseCodeLanguage(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, let block = codeMenuBlock else { return }
        setCodeLanguage(token, inBlock: block)
    }

    /// Gives the fenced block at `block` the language `token` through the core, as one undo step that
    /// leaves the selection where it was (shifted past the change).
    public func setCodeLanguage(_ token: String, inBlock block: NSRange) {
        guard let session, isEditable, !hasMarkedText() else { return }
        let b = Utf16Range(start: UInt32(block.location), end: UInt32(NSMaxRange(block)))
        guard let edit = session.coordinator.sync({ $0.setCodeLanguage(block: b, token: token) }) else { return }
        let range = NSRange(location: Int(edit.range.start), length: Int(edit.range.end - edit.range.start))
        guard NSMaxRange(range) <= session.storage.length,
              (session.storage.mutableString as NSString).substring(with: range) != edit.replacement else { return }
        let sel = selectedRange()
        // An event is already one undo group; called from anywhere else (a script, a test) this makes one.
        let group = undoManager.map { $0.groupingLevel == 0 } ?? false
        if group { undoManager?.beginUndoGrouping() }
        breakUndoCoalescing()
        session.isApplyingEdit = true
        if replaceThroughUndo(range: range, with: edit.replacement) {
            undoManager?.setActionName("Change Code Language")
            let change = TextChange(old: range, newLength: (edit.replacement as NSString).length)
            let a = RangeMath.shiftPoint(sel.location, through: change)
            let e = RangeMath.shiftPoint(NSMaxRange(sel), through: change)
            if selectedRange() != NSRange(location: a, length: e - a) { setSelectedRange(NSRange(location: a, length: e - a)) }
        }
        session.isApplyingEdit = false
        if group { undoManager?.endUndoGrouping() }
        session.selectionChanged(in: self)
    }

    // MARK: cursor

    func addBadgeCursorRects() {
        for badge in visibleCodeBadges() {
            addCursorRect(viewFrame(of: badge).insetBy(dx: -2, dy: -2), cursor: .arrow)
        }
    }

    // MARK: accessibility

    /// The text area's own children plus one button per badge in view: "Language: Rust", which
    /// performs press by opening the menu.
    public override func accessibilityChildren() -> [Any]? {
        let badges = visibleCodeBadges(ignoringCaret: true)
        guard !badges.isEmpty else { return super.accessibilityChildren() }
        let elements: [Any] = badges.map { CodeBadgeElement(textView: self, block: $0.block, display: $0.text) }
        return (super.accessibilityChildren() ?? []) + elements
    }
}

/// A badge for assistive technology.
final class CodeBadgeElement: NSAccessibilityElement {
    private weak var textView: EditorTextView?
    let block: NSRange
    let display: String

    init(textView: EditorTextView, block: NSRange, display: String) {
        self.textView = textView
        self.block = block
        self.display = display
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Language: \(display)" }
    override func accessibilityParent() -> Any? { textView }
    override func accessibilityFrame() -> NSRect {
        guard let tv = textView, let window = tv.window,
              let badge = tv.visibleCodeBadges(ignoringCaret: true).first(where: { $0.block.location == block.location }) else { return .zero }
        return window.convertToScreen(tv.convert(tv.viewFrame(of: badge), to: nil))
    }
    override func accessibilityPerformPress() -> Bool { textView?.presentCodeLanguageMenu(forBlock: block) ?? false }
}

/// The languages the menu offers, from the core (once).
private let codeLanguageChoiceList = MarkdownCore.codeLanguageChoices()
