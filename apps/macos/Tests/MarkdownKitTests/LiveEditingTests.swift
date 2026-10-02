import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Caret, selection, mouse and pasteboard behavior in Live mode.
final class LiveEditingTests: XCTestCase {
    /// Where the caret at character index `i` is drawn: the line fragment and x of its glyph.
    private func caretPoint(_ e: Editor, _ i: Int) -> NSPoint {
        let lm = e.lm
        let length = e.session.storage.length
        let ci = min(i, max(0, length - 1))
        let g = lm.glyphIndexForCharacter(at: ci)
        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        var x = line.minX + lm.location(forGlyphAt: g).x
        if i >= length, length > 0 { x = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil).maxX }
        return NSPoint(x: x.rounded(), y: line.minY.rounded())
    }

    private func walk(_ e: Editor, _ command: Selector, steps: Int, file: StaticString = #filePath, line: UInt = #line) -> [Int] {
        var positions = [e.tv.selectedRange().location]
        for _ in 0..<steps {
            e.tv.doCommand(by: command)
            e.settle()
            positions.append(e.tv.selectedRange().location)
            if positions.count > 1, positions.last == positions[positions.count - 2] { break }
        }
        return positions
    }

    // MARK: arrow keys

    /// Every press of an arrow key passes over something the user can see (or jumps a whole
    /// concealed unit, such as a task item's checkbox, in one press): no press moves the caret
    /// through hidden text alone. (Text may shift under the caret when an element it left is
    /// concealed again; that is the nature of showing markup at the caret.)
    func testEveryArrowPressPassesVisibleTextOrAWholeConcealedUnit() {
        let text = "Some *em* and **bold** with `code` and [link](http://a.b/c \"t\") and \\* star.\n\n# Head\n\n> quote **b**\n> second\n\n- [ ] task one\n- [x] task two\n- plain\n\n---\n\n```\ncode\n```\n\n![i](p.png)\n\nend\n"
        let ns = text as NSString
        for (command, name, start) in [(#selector(NSResponder.moveRight(_:)), "right", 0), (#selector(NSResponder.moveLeft(_:)), "left", ns.length)] {
            let e = Editor.live(text, caret: start)
            var path = [start]
            for _ in 0..<(ns.length + 20) {
                let before = e.tv.selectedRange().location
                let live = e.lm.live
                e.tv.doCommand(by: command)
                e.settle()
                let after = e.tv.selectedRange().location
                if after == before { break }
                path.append(after)
                let passed = NSRange(location: min(before, after), length: abs(after - before))
                let allHidden = passed.length > 0 && (passed.location..<NSMaxRange(passed)).allSatisfy { live.isHidden($0) }
                if allHidden {
                    // Allowed only as one whole hidden range (a prefix jumped in one press).
                    let whole = live.atomic.contains { NSEqualRanges($0, passed) || NSLocationInRange(passed.location, $0) && NSMaxRange(passed) <= NSMaxRange($0) && passed.length >= $0.length - 1 }
                    XCTAssertTrue(whole && passed.length > 1, "\(name): a press moved through hidden text only: \(passed) \(ns.substring(with: passed).debugDescription)")
                }
            }
            XCTAssertEqual(path.last, command == #selector(NSResponder.moveRight(_:)) ? ns.length : 0, "\(name) reaches the end")
            XCTAssertGreaterThan(path.count, 60, name)
        }
    }

    func testCaretRestsOnlyWhereItCanBeSeen() {
        let text = "# Head\n\n- [ ] task\n\n```\ncode\n```\n\nend"
        let ns = text as NSString
        let e = Editor.live(text, caret: ns.length)
        let s = e.session
        func change(from old: Int, to new: Int) -> Int {
            s.textView(e.tv, willChangeSelectionFromCharacterRange: NSRange(location: old, length: 0), toCharacterRange: NSRange(location: new, length: 0)).location
        }
        // "# " is hidden now, but shown once the caret is on its line: the caret stays put.
        XCTAssertEqual(change(from: 20, to: 1), 1)
        XCTAssertEqual(change(from: 0, to: 1), 1)
        // A task item's prefix stays hidden with the caret beside it; its start and its end are
        // the same place on screen, and only the end is a place to rest.
        let task = ns.range(of: "- [ ] ")
        for p in task.location..<NSMaxRange(task) {
            XCTAssertEqual(change(from: 0, to: p), NSMaxRange(task), "from above to \(p)")
            XCTAssertEqual(change(from: 40, to: p), NSMaxRange(task), "from below to \(p) (a click, a vertical move)")
        }
        // A caret landing on a collapsed fence line stays there: the fence is shown.
        let open = ns.range(of: "```\ncode")
        XCTAssertEqual(change(from: 0, to: open.location + 1), open.location + 1)
        let close = ns.range(of: "```\n\nend")
        XCTAssertEqual(change(from: ns.length, to: close.location + 1), close.location + 1)
        // Selections made by the mouse or by Find are left alone.
        XCTAssertEqual(s.textView(e.tv, willChangeSelectionFromCharacterRange: NSRange(location: 0, length: 0), toCharacterRange: NSRange(location: 0, length: 5)), NSRange(location: 0, length: 5))
        // Source mode never moves the caret.
        s.setViewMode(.source)
        XCTAssertEqual(change(from: 20, to: task.location + 1), task.location + 1)
    }

    func testVerticalMoveIntoAHeadingLandsAfterItsPrefixAndRevealsIt() {
        let text = "Some paragraph text\n\n# Heading line\n\nend"
        let ns = text as NSString
        let e = Editor.live(text, caret: 5)
        e.tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        e.settle()
        XCTAssertEqual(e.tv.selectedRange().location, ns.range(of: "# Heading").location - 1, "the blank line above the heading is visited")
        XCTAssertTrue(e.isNull(ns.range(of: "# Heading").location), "its prefix is still hidden")
        e.tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        e.settle()
        let caret = e.tv.selectedRange().location
        let heading = ns.range(of: "# Heading")
        XCTAssertTrue(caret >= heading.location + 2 && caret <= NSMaxRange(heading), "in the heading's text, not in its prefix: \(caret)")
        XCTAssertFalse(e.isNull(heading.location), "the prefix is revealed")
        XCTAssertFalse(e.isNull(heading.location + 1))
    }

    func testVerticalMoveIntoAPictureLandsAtTheStartOfItsSource() {
        let text = "Some paragraph text\n\n![a long description of the picture](missing/picture.png)\n\nend"
        let ns = text as NSString
        let e = Editor.live(text, caret: 5)
        e.tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        e.settle()
        XCTAssertEqual(e.tv.selectedRange().location, ns.range(of: "\n\n![").location + 1, "the blank line above the picture is visited")
        e.tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        e.settle()
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: ns.range(of: "![a long").location, length: 0), "at the start of the picture's source line")
        XCTAssertFalse(e.isNull(ns.range(of: "![a long").location), "the source is shown while the caret is on it")
    }

    func testMovingAcrossACollapsedFenceEntersTheCode() {
        let text = "before\n\n```\ncode line\n```\n\nafter"
        let ns = text as NSString
        let e = Editor.live(text, caret: ns.range(of: "before").location + 2)
        e.tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        e.settle()
        XCTAssertEqual(e.tv.selectedRange().location, ns.range(of: "\n\n```").location + 1, "the blank line above the fence is visited")
        e.tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
        e.settle()
        let caret = e.tv.selectedRange().location
        let code = ns.range(of: "code line")
        XCTAssertTrue(NSLocationInRange(caret, NSRange(location: code.location - 1, length: code.length + 2)), "caret \(caret) is in the code, not on a hidden fence")
        XCTAssertTrue(e.lm.live.collapsed.isEmpty, "the fences are shown while the caret is in the block")
    }

    func testTypingBackspaceAndDeleteActOnTheRealText() {
        let e = Editor.live("a **bold** b\n\nz", caret: 0)
        let ns = e.string as NSString
        // Backspace at the start of the bold text: the caret touches the element, so the user
        // sees what is deleted (the markup).
        e.select(ns.range(of: "bold").location)
        e.settle()
        XCTAssertTrue(e.hiddenText.isEmpty || !e.hiddenText.contains("**") || e.lm.live.hidden.allSatisfy { !NSLocationInRange($0.location, NSRange(location: 2, length: 8)) })
        XCTAssertFalse(e.isNull(2), "the opening ** is shown")
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        e.settle()
        XCTAssertEqual(e.string, "a *bold** b\n\nz")
        e.um.undo()
        XCTAssertEqual(e.string, "a **bold** b\n\nz")
        // Forward delete at the end of the element.
        e.select(ns.range(of: "bold").location + 4)
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.deleteForward(_:))) }
        e.settle()
        XCTAssertEqual(e.string, "a **bold* b\n\nz")
    }

    func testDoubleClickWordNextToHiddenMarkup() {
        let e = Editor.live("see **bold** and [link](http://a.b) end\n\nz", caret: 0)
        let ns = e.string as NSString
        let word = ns.range(of: "bold")
        let proposed = e.tv.selectionRange(forProposedRange: NSRange(location: word.location + 1, length: 0), granularity: .selectByWord)
        XCTAssertEqual(ns.substring(with: proposed), "bold", "hidden markup next to the word is not part of it")
        e.select(proposed.location, proposed.length)
        e.settle()
        XCTAssertFalse(e.isNull(word.location - 1), "selecting the word reveals the markup around it")
    }

    func testShiftSelectionAcrossHiddenRangesRevealsEverythingItCovers() {
        let text = "a **b** c [d](u) e\n\nz"
        let e = Editor.live(text, caret: 0)
        e.select(0, 0)
        e.settle()
        XCTAssertFalse(e.nullCharacters().isEmpty)
        for _ in 0..<14 { e.tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:))) }
        e.settle()
        let sel = e.tv.selectedRange()
        XCTAssertGreaterThanOrEqual(sel.length, 14)
        for i in sel.location..<NSMaxRange(sel) { XCTAssertFalse(e.isNull(i), "character \(i) inside the selection is hidden") }
    }

    func testCopyCopiesTheRealMarkdown() {
        let e = Editor.live("a **b** [c](http://d.e) f\n\nz", caret: 0)
        e.select(0, 24)
        e.settle()
        // Save and restore the user's clipboard around the real copy command.
        let general = NSPasteboard.general
        let saved = general.pasteboardItems?.map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        defer {
            general.clearContents()
            for item in saved ?? [] {
                let new = NSPasteboardItem()
                for (t, d) in item { new.setData(d, forType: t) }
                general.writeObjects([new])
            }
        }
        e.tv.copy(nil)
        XCTAssertEqual(general.string(forType: .string), "a **b** [c](http://d.e) ")
    }

    func testSelectingInsideAHiddenDestinationRevealsIt() {
        let text = "x [link](http://hidden.example/path) y\n\nz"
        let e = Editor.live(text, caret: (text as NSString).length)
        let ns = text as NSString
        XCTAssertTrue(e.isNull(ns.range(of: "http").location))
        // What Find does: select the match.
        e.tv.setSelectedRange(ns.range(of: "hidden.example"))
        e.settle()
        XCTAssertFalse(e.isNull(ns.range(of: "http").location))
        XCTAssertFalse(e.isNull(ns.range(of: "](").location))
    }

    /// Return, Tab and typing under a list item: for a moment `  - ` is a setext underline (an
    /// empty item cannot interrupt a paragraph), a collapsed line holding the caret.
    func testReturnTabAndTypingInAListWorkInLiveMode() {
        let e = Editor.live("# T\n\n- A short item.\n- Next one\n\nend", caret: 0)
        let ns = e.string as NSString
        e.select(NSMaxRange(ns.range(of: "- A short item.")))
        e.settle()
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertTab(_:))) }
        for ch in "child" { e.grouped { e.tv.insertText(String(ch), replacementRange: e.tv.selectedRange()) } }
        e.settle()
        XCTAssertEqual(e.string, "# T\n\n- A short item.\n  - child\n- Next one\n\nend")
        XCTAssertEqual(e.tv.selectedRange().location, (e.string as NSString).range(of: "child").location + 5)
    }

    func testConcealmentFollowsTypingWithoutAnExtraStep() {
        let e = Editor.live("plain\n\nend", caret: 5)
        for ch in " **bold" { e.grouped { e.tv.insertText(String(ch), replacementRange: e.tv.selectedRange()) } }
        e.settle()
        XCTAssertTrue(e.nullCharacters().isEmpty, "the caret is inside the unclosed/just-closed markup")
        for ch in "** more" { e.grouped { e.tv.insertText(String(ch), replacementRange: e.tv.selectedRange()) } }
        e.settle()
        XCTAssertEqual(e.string, "plain **bold** more\n\nend")
        XCTAssertEqual(e.hiddenText, ["**", "**"], "the caret has left the bold text")
        // Back into it: both shown at once.
        e.select(10)
        e.settle()
        XCTAssertEqual(e.hiddenText, [])
    }

    // MARK: checkbox

    func testCheckboxClickTogglesOnceKeepsTheCaretAndIsOneUndoStep() throws {
        let text = "intro\n\n- [ ] first\n- [x] second\n\nend"
        let ns = text as NSString
        let e = Editor.live(text, caret: ns.range(of: "intro").location + 2)
        let tc = try XCTUnwrap(e.tv.textContainer)
        let boxes = e.lm.live.decorations.filter { if case .checkbox = $0.kind { return true } else { return false } }
        XCTAssertEqual(boxes.count, 2)
        let frame = try XCTUnwrap(e.lm.checkboxFrame(of: boxes[0], in: tc))
        let origin = e.tv.textContainerOrigin
        let point = NSPoint(x: frame.midX + origin.x, y: frame.midY + origin.y)
        let caret = e.tv.selectedRange()
        e.um.groupsByEvent = false
        e.grouped { XCTAssertTrue(e.tv.handleCheckboxClick(at: point)) }
        e.settle()
        XCTAssertEqual(e.string, "intro\n\n- [x] first\n- [x] second\n\nend")
        XCTAssertEqual(e.tv.selectedRange(), caret, "the caret did not move")
        XCTAssertEqual(e.um.undoActionName, "Toggle Task")
        e.um.undo()
        XCTAssertEqual(e.string, text, "one undo step")
        XCTAssertFalse(e.um.canUndo)
        e.um.redo()
        XCTAssertEqual(e.string, "intro\n\n- [x] first\n- [x] second\n\nend")
        // A click elsewhere is not handled.
        XCTAssertFalse(e.tv.handleCheckboxClick(at: NSPoint(x: origin.x + 300, y: origin.y + 2)))
        // Source mode has no checkboxes to click.
        e.session.setViewMode(.source)
        XCTAssertFalse(e.tv.handleCheckboxClick(at: point))
    }

    func testToggleTaskGoesThroughTheCore() {
        let e = Editor.live("- [ ] a\n- b\n\nz", caret: 12)
        e.grouped { e.tv.toggleTask(at: 3) }
        XCTAssertEqual(e.string, "- [x] a\n- b\n\nz")
    }

    // MARK: links

    func testLinkOpenerResolvesDestinations() {
        let doc = URL(fileURLWithPath: "/docs/sub/note.md")
        func url(_ d: String, _ doc: URL? = doc) -> String? { LinkOpener.url(for: d, documentURL: doc)?.absoluteString }
        XCTAssertEqual(url("https://example.com/a?b=1#c"), "https://example.com/a?b=1#c")
        XCTAssertEqual(url("mailto:me@example.com"), "mailto:me@example.com")
        XCTAssertEqual(url("www.example.com/x"), "http://www.example.com/x")
        XCTAssertEqual(url("other.md"), "file:///docs/sub/other.md")
        XCTAssertEqual(url("../img/a%20b.png"), "file:///docs/img/a%20b.png")
        XCTAssertEqual(url("img/a b.png"), "file:///docs/sub/img/a%20b.png")
        XCTAssertEqual(url("/abs/file.txt"), "file:///abs/file.txt")
        XCTAssertEqual(url("other.md#section"), "file:///docs/sub/other.md")
        XCTAssertNil(url("#anchor"))
        XCTAssertNil(url("relative.md", nil), "no folder to resolve against")
        XCTAssertNil(url("javascript:alert(1)"))
        XCTAssertNil(url(""))
    }

    func testCommandClickOpensLinksAndBareURLs() throws {
        let text = "see [the site](https://example.com/page \"t\") and https://bare.example/x_y and [doc](notes/other.md) and [ref][r] z\n\n[r]: https://ref.example/\n"
        let e = Editor.live(text, caret: (text as NSString).length)
        e.session.documentURL = { URL(fileURLWithPath: "/docs/note.md") }
        let ns = text as NSString
        var opened: [String] = []
        LinkOpener.opened = { opened.append($0.absoluteString); return true }
        defer { LinkOpener.opened = nil }
        func click(on needle: String) throws -> Bool {
            let i = ns.range(of: needle).location
            let g = e.lm.glyphIndexForCharacter(at: i)
            let r = e.lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: try XCTUnwrap(e.tv.textContainer))
            let o = e.tv.textContainerOrigin
            return e.tv.openLink(at: NSPoint(x: r.midX + o.x, y: r.midY + o.y))
        }
        XCTAssertTrue(try click(on: "the site"))
        XCTAssertTrue(try click(on: "bare.example"))
        XCTAssertTrue(try click(on: "doc]"))
        XCTAssertTrue(try click(on: "ref]"))
        XCTAssertEqual(opened, ["https://example.com/page", "https://bare.example/x_y", "file:///docs/notes/other.md", "https://ref.example/"])
        XCTAssertFalse(try click(on: "see"), "plain text is not a link")
    }

    func testThePointingHandComesAndGoesWithCommandOverALink() throws {
        let text = "see [the site](https://example.com/page) and plain\n\nz"
        let e = Editor.live(text, caret: (text as NSString).length)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = e.tv
        defer { window.contentView = nil }
        let ns = text as NSString
        func point(_ needle: String) throws -> NSPoint {
            let g = e.lm.glyphIndexForCharacter(at: ns.range(of: needle).location)
            let r = e.lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: try XCTUnwrap(e.tv.textContainer))
            return NSPoint(x: r.midX + e.tv.textContainerOrigin.x, y: r.midY + e.tv.textContainerOrigin.y)
        }
        XCTAssertTrue(e.tv.updateLinkCursor(modifiers: .command, at: try point("the site")))
        XCTAssertTrue(e.tv.showsLinkCursor)
        XCTAssertFalse(e.tv.updateLinkCursor(modifiers: [], at: try point("the site")), "Command released")
        XCTAssertFalse(e.tv.showsLinkCursor)
        XCTAssertFalse(e.tv.updateLinkCursor(modifiers: .command, at: try point("plain")), "not a link")
    }

    // MARK: menus

    func testViewMenuHasModeItemsWithKeyEquivalents() throws {
        _ = NSApplication.shared
        let main = MainMenu.build()
        let view = try XCTUnwrap(main.items.first { $0.title == "View" }?.submenu)
        let source = try XCTUnwrap(view.items.first { $0.title == "Source" })
        let live = try XCTUnwrap(view.items.first { $0.title == "Live" })
        XCTAssertEqual(source.keyEquivalent, "1")
        XCTAssertEqual(source.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(live.keyEquivalent, "2")
        XCTAssertEqual(live.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(source.action, #selector(EditorTextView.showSourceMode(_:)))
        XCTAssertEqual(live.action, #selector(EditorTextView.showLiveMode(_:)))
        // Both reach the text view and show the current mode as checked.
        let e = Editor(text: "x")
        XCTAssertTrue(e.tv.validateUserInterfaceItem(source) && source.state == .on && live.state == .off)
        e.tv.showLiveMode(nil)
        XCTAssertEqual(e.session.viewMode, .live)
        XCTAssertTrue(e.tv.validateUserInterfaceItem(live) && e.tv.validateUserInterfaceItem(source))
        XCTAssertEqual([live.state, source.state], [.on, .off])
        e.tv.showSourceMode(nil)
        XCTAssertEqual(e.session.viewMode, .source)
    }

    func testModeSwitchControlFollowsTheSession() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        XCTAssertEqual(wc.modeSwitch.selectedSegment, 0)
        XCTAssertEqual(wc.modeSwitch.label(forSegment: 0), "Source")
        XCTAssertEqual(wc.modeSwitch.label(forSegment: 1), "Live")
        doc.session.setViewMode(.live)
        XCTAssertEqual(wc.modeSwitch.selectedSegment, 1)
        wc.modeSwitch.selectedSegment = 0
        _ = wc.modeSwitch.sendAction(wc.modeSwitch.action, to: wc.modeSwitch.target)
        XCTAssertEqual(doc.session.viewMode, .source)
        XCTAssertTrue(wc.titlebarControls.contains { $0.subviews.contains(wc.modeSwitch) }, "the switch fades with the chrome")
        doc.close()
    }

    // MARK: windowed queries

    /// A query for a window compares and invalidates only that window, and text the reader
    /// returns to (unchanged) needs no new glyphs: jumping around a long document does not get
    /// slower with everything seen before, and coming back costs no layout.
    func testWindowedQueriesTouchOnlyTheirWindow() {
        let para = "Paragraph with *emphasis* and **strong** text and a [link](http://x.y) end.\n\n```\ncode\n```\n\n"
        let text = String(repeating: para, count: 2_500)
        let e = Editor(text: text)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = e.tv
        e.tv.setFrameSize(NSSize(width: 800, height: 600))
        e.session.setViewMode(.live)
        e.select(0)
        e.settle()
        func jump(to location: Int) {
            e.tv.scrollRangeToVisible(NSRange(location: location, length: 0))
            e.session.visibleRangeChanged()
            let turn = expectation(description: "turn")
            DispatchQueue.main.async { turn.fulfill() }
            wait(for: [turn], timeout: 5)
        }
        e.lm.recordsInvalidations = true
        let length = e.session.storage.length
        for fraction in [0.3, 0.5, 0.4, 0.55] {
            e.lm.invalidatedRanges.removeAll()
            jump(to: Int(Double(length) * fraction))
            let w = e.session.liveWindow
            XCTAssertTrue(e.lm.invalidatedRanges.allSatisfy { $0.location >= w.location - 200 && NSMaxRange($0) <= NSMaxRange(w) + 200 },
                          "only the window is laid out again: \(e.lm.invalidatedRanges) for \(w)")
        }
        // Back to a region seen before (within `keptWindows` of the last): nothing changed
        // there, nothing is invalidated (but a paragraph at the edge of a window, half known
        // before).
        e.lm.invalidatedRanges.removeAll()
        jump(to: Int(Double(length) * 0.3))
        XCTAssertLessThan(e.lm.invalidatedRanges.reduce(0) { $0 + $1.length }, 600, "\(e.lm.invalidatedRanges) of a \(e.session.liveWindow.length)-character window")
    }

    func testBigDocumentsAreQueriedByWindowAndRequeriedOnScroll() {
        let para = "Paragraph with *emphasis* and **strong** text and a [link](http://x.y) end.\n\n"
        let text = String(repeating: para, count: 3_000) // ~225k characters
        let e = Editor(text: text)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = e.tv
        e.tv.setFrameSize(NSSize(width: 800, height: 600))
        e.session.setViewMode(.live)
        e.select(0)
        e.settle()
        let w = e.session.liveQueryWindow()
        XCTAssertLessThan(w.length, e.session.storage.length / 4, "windowed")
        XCTAssertEqual(w.location, 0)
        let queries = e.session.liveQueries
        // Scrolling far leaves the window: one more query, near the new position.
        let far = e.session.storage.length * 2 / 3
        e.tv.scrollRangeToVisible(NSRange(location: far, length: 0))
        e.session.visibleRangeChanged()
        let asked = expectation(description: "one main-queue turn")
        DispatchQueue.main.async { asked.fulfill() }
        wait(for: [asked], timeout: 5)
        XCTAssertGreaterThan(e.session.liveQueries, queries)
        e.settle()
        XCTAssertTrue(e.session.liveWindow.location > 0)
        XCTAssertFalse(e.lm.live.hidden.isEmpty)
        // What the first window said is let go this far away (it is asked again before being
        // shown), and its glyphs are marked to be made again then.
        XCTAssertFalse(e.lm.live.hidden.contains { $0.location < 500 })
        XCTAssertTrue(e.lm.staleRanges.contains { $0.location < 500 })
        // Text scrolled into view right after an edit (the analysis queue still busy) is queried
        // before it is drawn: nothing carried over from before the edit is shown there.
        e.session.coordinator.artificialDelay = 0.05
        e.edit(range: NSRange(location: 0, length: 0), with: "x")
        XCTAssertFalse(e.session.coordinator.isIdle)
        let back = e.session.storage.length / 3
        e.tv.scrollRangeToVisible(NSRange(location: back, length: 0))
        e.session.visibleRangeChanged()
        // One main-queue turn (before the run loop draws): asked and applied by then.
        let turn = expectation(description: "one main-queue turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 5)
        XCTAssertTrue(NSLocationInRange(back, e.session.liveWindow), "queried before drawing, not when the queue gets to it")
        e.session.coordinator.artificialDelay = 0
        e.settle()
        // What is applied inside the window is what the core says for it now.
        let applied = e.session.liveWindow, sel = e.tv.selectedRange()
        let fresh = e.session.coordinator.sync { doc in
            LiveState(doc.concealment(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))),
                                      within: Utf16Range(start: UInt32(applied.location), end: UInt32(NSMaxRange(applied)))), images: [])
        }
        XCTAssertEqual(RangeList.normalized(e.lm.live.hidden.map { NSIntersectionRange($0, applied) }), fresh.hidden)
    }
}
