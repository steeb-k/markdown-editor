import AppKit
import MarkdownCore

/// What travels on the pasteboard beside the plain text when text is copied or cut inside the
/// app: the attribution of the copied range, so a plain Paste puts the marks back.
enum AuthorshipPasteboard {
    static let type = NSPasteboard.PasteboardType("io.github.steeb-k.Markdown.authorship")

    struct Payload: Codable {
        struct Person: Codable {
            var kind: String
            var name: String
        }
        struct Run: Codable {
            var start: Int
            var length: Int
            var author: Int
        }
        /// The copied text, to check that the pasteboard's string is still it.
        var text: String
        var people: [Person]
        /// Relative to the start of the copied text, UTF-16 units.
        var runs: [Run]

        var authors: [Author] {
            people.map { Author(kind: $0.kind == "ai" ? .ai : $0.kind == "reference" ? .reference : .human, name: $0.name) }
        }
    }

    static func kindName(_ k: AuthorKind) -> String {
        switch k {
        case .human: return "human"
        case .ai: return "ai"
        case .reference: return "reference"
        }
    }
}

/// Paste As, Mark As and the display toggle.
extension EditorTextView {
    // MARK: copy and cut

    public override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let session else { return }
        write(range, of: session, to: pasteboard)
    }

    public override func cut(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let session else { return }
        write(range, of: session, to: pasteboard)
        guard isEditable, !hasMarkedText() else { return }
        undoManager?.beginUndoGrouping()
        breakUndoCoalescing()
        if replaceThroughUndo(range: range, with: "", origin: .typed) {
            undoManager?.setActionName("Cut")
            setSelectedRange(NSRange(location: range.location, length: 0))
        }
        undoManager?.endUndoGrouping()
    }

    private func write(_ range: NSRange, of session: EditorSession, to pb: NSPasteboard) {
        let string = (session.storage.string as NSString).substring(with: range)
        pb.clearContents()
        pb.setString(string, forType: .string)
        guard session.authorship.hasMarks() else { return }
        let authors = session.authorship.authors()
        let runs = session.authorship.runs(within: Utf16Range(start: UInt32(range.location), end: UInt32(NSMaxRange(range))))
        let payload = AuthorshipPasteboard.Payload(
            text: string,
            people: authors.map { .init(kind: AuthorshipPasteboard.kindName($0.kind), name: $0.name) },
            runs: runs.map { .init(start: Int($0.range.start) - range.location, length: Int($0.range.end - $0.range.start), author: Int($0.authorIndex)) })
        if let data = try? JSONEncoder().encode(payload) {
            pb.addTypes([AuthorshipPasteboard.type], owner: nil)
            pb.setData(data, forType: AuthorshipPasteboard.type)
        }
    }

    // MARK: paste

    /// Paste: the user's own text, unless it was copied in this app with marks, which it keeps.
    func pasteText(from pb: NSPasteboard) {
        guard let string = pb.string(forType: .string) else { return }
        var carried: AuthorshipPasteboard.Payload?
        if let data = pb.data(forType: AuthorshipPasteboard.type),
           let payload = try? JSONDecoder().decode(AuthorshipPasteboard.Payload.self, from: data), payload.text == string {
            carried = payload
        }
        insertPasted(string, origin: carried == nil ? .typed : .unattributed, carrying: carried, actionName: "Paste")
    }

    /// Paste As: everything pasted belongs to `choice`, whatever it carried.
    func pasteText(from pb: NSPasteboard, as choice: AuthorChoice) {
        guard let string = pb.string(forType: .string), let session else { return }
        let author = session.author(for: choice)
        insertPasted(string, origin: choice == .me ? .typed : .pasteAs(author), carrying: nil, actionName: "Paste as \(choice.title)")
    }

    private func insertPasted(_ string: String, origin: EditOrigin, carrying: AuthorshipPasteboard.Payload?, actionName: String) {
        guard let session, isEditable, !hasMarkedText() else { return }
        let sel = selectedRange()
        undoManager?.beginUndoGrouping()
        breakUndoCoalescing()
        session.isApplyingEdit = true
        if replaceThroughUndo(range: sel, with: string, origin: origin) {
            let end = sel.location + (string as NSString).length
            setSelectedRange(NSRange(location: end, length: 0))
            if let carrying { session.applyCarried(carrying, at: sel.location) }
            undoManager?.setActionName(actionName)
        }
        session.isApplyingEdit = false
        undoManager?.endUndoGrouping()
        session.selectionChanged(in: self)
        scrollRangeToVisible(selectedRange())
    }

    @objc public func pasteAsMe(_ sender: Any?) { pasteText(from: pasteboard, as: .me) }
    @objc public func pasteAsAI(_ sender: Any?) { pasteText(from: pasteboard, as: .ai) }
    @objc public func pasteAsReference(_ sender: Any?) { pasteText(from: pasteboard, as: .reference) }

    // MARK: mark

    @objc public func markAsMe(_ sender: Any?) { session?.mark(selectedRange(), as: .me) }
    @objc public func markAsAI(_ sender: Any?) { session?.mark(selectedRange(), as: .ai) }
    @objc public func markAsReference(_ sender: Any?) { session?.mark(selectedRange(), as: .reference) }
    @objc public func markAsNoAuthor(_ sender: Any?) { session?.mark(selectedRange(), as: nil, actionName: "Mark as No Author") }

    /// Mark This Passage As (the context menu's): the whole run under the pointer, which the item carries, without
    /// selecting it; the selection the reader had is put back. Tag 0 to 2 is an `AuthorChoice`, 3 is No Author.
    @objc func markPassage(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? PassageTarget, let session else { return }
        let range = target.range, selection = target.selection
        let choice = AuthorChoice(rawValue: sender.tag)
        undoManager?.beginUndoGrouping()
        session.mark(range, as: choice, actionName: choice == nil ? "Mark as No Author" : nil)
        undoManager?.endUndoGrouping()
        if selectedRange() != selection { setSelectedRange(selection) }
    }

    /// The authored run holding the character at `index`: adjacent runs of one author count as one passage.
    func authoredPassage(at index: Int) -> NSRange? {
        guard let session, index >= 0, index < session.storage.length, session.authorship.hasMarks() else { return nil }
        let runs = session.authorship.runs(within: nil)
        guard let i = runs.firstIndex(where: { Int($0.range.start) <= index && index < Int($0.range.end) }) else { return nil }
        let author = runs[i].authorIndex
        var lo = i, hi = i
        while lo > 0, runs[lo - 1].authorIndex == author, runs[lo - 1].range.end == runs[lo].range.start { lo -= 1 }
        while hi + 1 < runs.count, runs[hi + 1].authorIndex == author, runs[hi + 1].range.start == runs[hi].range.end { hi += 1 }
        return NSRange(location: Int(runs[lo].range.start), length: Int(runs[hi].range.end - runs[lo].range.start))
    }

    // MARK: context menu

    /// The standard menu (Cut, Copy, Paste, spelling, Look Up, Services, as AppKit builds it) with Paste As and Mark As
    /// after Paste, and, over a passage that carries an author, Mark This Passage As for that whole run. The pointer's
    /// own position decides the passage; the caret moves only as AppKit moves it for a context menu.
    public override func menu(for event: NSEvent) -> NSMenu? {
        // What the reader had selected before AppKit makes its own choice for the click (it selects the word under
        // the pointer for Look Up and Services): Mark This Passage As puts that back.
        let selection = selectedRange()
        let menu = super.menu(for: event) ?? NSMenu()
        addAuthorshipItems(to: menu, atWindowPoint: event.locationInWindow, selection: selection)
        return menu
    }

    func addAuthorshipItems(to menu: NSMenu, atWindowPoint p: NSPoint, selection: NSRange) {
        var items: [NSMenuItem] = []
        for sub in [MainMenu.pasteAsMenu(), MainMenu.markAsMenu()] {
            for i in sub.items where !i.isSeparatorItem { i.target = self }
            let holder = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            items.append(holder)
        }
        if let range = passage(atWindowPoint: p) {
            let sub = NSMenu(title: "Mark This Passage As")
            for (title, tag) in [("Me", 0), ("AI", 1), ("Reference", 2)] { sub.addItem(passageItem(title, tag, range, selection)) }
            sub.addItem(.separator())
            sub.addItem(passageItem("No Author", 3, range, selection))
            let holder = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            items.append(holder)
        }
        if let paste = menu.items.firstIndex(where: { $0.action == #selector(NSText.paste(_:)) }) {
            for (n, i) in items.enumerated() { menu.insertItem(i, at: paste + 1 + n) }
        } else {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
    }

    /// What a Mark This Passage As item carries: the run, and the selection to leave as it was.
    final class PassageTarget: NSObject {
        let range: NSRange, selection: NSRange
        init(range: NSRange, selection: NSRange) { self.range = range; self.selection = selection }
    }

    private func passageItem(_ title: String, _ tag: Int, _ range: NSRange, _ selection: NSRange) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(markPassage(_:)), keyEquivalent: "")
        i.target = self
        i.tag = tag
        i.representedObject = PassageTarget(range: range, selection: selection)
        return i
    }

    /// The authored passage under a point of the window, if the point is on text that carries one.
    func passage(atWindowPoint p: NSPoint) -> NSRange? {
        guard let lm = layoutManager, let tc = textContainer, session != nil else { return nil }
        let local = convert(p, from: nil)
        let inContainer = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = lm.characterIndex(for: inContainer, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let glyph = lm.glyphIndexForCharacter(at: min(index, max(0, (string as NSString).length - 1)))
        guard lm.numberOfGlyphs > 0, lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).insetBy(dx: -1, dy: -1).contains(inContainer) else { return nil }
        return authoredPassage(at: index)
    }

    @objc public func toggleAuthorshipDisplay(_ sender: Any?) {
        guard let session else { return }
        session.setAuthorshipDisplay(!session.authorshipDisplay)
    }

    // MARK: validation

    /// The menu choice the whole selection is, if it is one.
    func selectionAuthorChoice() -> AuthorChoice? {
        guard let session else { return nil }
        let r = selectedRange()
        guard r.length > 0, let i = session.authorship.uniformAuthor(range: Utf16Range(start: UInt32(r.location), end: UInt32(NSMaxRange(r)))) else { return nil }
        return session.choice(ofAuthorAt: i, in: session.authorship.authors())
    }

    func validateAuthorshipAction(_ action: Selector?) -> (enabled: Bool, on: Bool)? {
        guard let action else { return nil }
        let editable = isEditable && !hasMarkedText()
        let hasText = pasteboard.string(forType: .string) != nil
        switch action {
        case #selector(pasteAsMe(_:)), #selector(pasteAsAI(_:)), #selector(pasteAsReference(_:)):
            return (editable && hasText, false)
        case #selector(markAsMe(_:)):
            return (editable && selectedRange().length > 0, selectionAuthorChoice() == .me)
        case #selector(markAsAI(_:)):
            return (editable && selectedRange().length > 0, selectionAuthorChoice() == .ai)
        case #selector(markAsReference(_:)):
            return (editable && selectedRange().length > 0, selectionAuthorChoice() == .reference)
        case #selector(markAsNoAuthor(_:)):
            return (editable && selectedRange().length > 0, false)
        case #selector(markPassage(_:)):
            return (editable, false)
        case #selector(toggleAuthorshipDisplay(_:)):
            return (true, session?.authorshipDisplay == true)
        default:
            return nil
        }
    }
}
