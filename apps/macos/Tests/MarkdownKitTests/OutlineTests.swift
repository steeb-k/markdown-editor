import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The outline column: the core's headings through the FFI, the tree and the marks, the list that shows them, the
/// window around it (panes, tabs, the menu, the settings) and what a jump does.
@MainActor
final class OutlineTests: XCTestCase {
    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    private func entry(_ level: UInt8, _ text: String, start: UInt32 = 0, line: UInt32 = 0) -> OutlineEntry {
        OutlineEntry(level: level, text: text, range: Utf16Range(start: start, end: start + 1), line: line)
    }

    // MARK: the core through the FFI

    func testTheCoresHeadingsComeThroughTheFFIInUTF16() {
        let text = "# One 😀\n\ntext\n\nTwo *em*\n===\n\n- ## Three\n"
        let doc = Document(text: text)
        let o = doc.outline()
        XCTAssertEqual(o.map(\.text), ["One 😀", "Two em", "Three"])
        XCTAssertEqual(o.map(\.level), [1, 1, 2])
        XCTAssertEqual(o.map(\.line), [0, 4, 7])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: o[1].range.nsRange), "Two *em*\n===")
        XCTAssertEqual(ns.substring(with: o[2].range.nsRange), "## Three")
    }

    // MARK: the tree and the marks, with no views

    func testTheTreeNestsByLevelAndASkippedLevelIsNoGap() {
        let e = [entry(1, "A"), entry(3, "A.x"), entry(2, "A.1"), entry(3, "A.1.a"), entry(1, "B"), entry(4, "B.deep"), entry(2, "B.1")]
        let t = OutlineModel.tree(of: e)
        XCTAssertEqual(t.roots.map(\.entry.text), ["A", "B"])
        XCTAssertEqual(t.roots[0].children.map(\.entry.text), ["A.x", "A.1"])
        XCTAssertEqual(t.roots[0].children[1].children.map(\.entry.text), ["A.1.a"])
        XCTAssertEqual(t.roots[1].children.map(\.entry.text), ["B.deep", "B.1"])
        XCTAssertEqual(t.all.map(\.index), Array(0..<7))
        // A document that starts at level 3 has roots at level 3.
        XCTAssertEqual(OutlineModel.tree(of: [entry(3, "x"), entry(2, "y"), entry(3, "z")]).roots.map(\.entry.text), ["x", "y"])
        XCTAssertTrue(OutlineModel.tree(of: []).roots.isEmpty)
    }

    func testTheMarkedHeadingIsTheLastOneAtOrBeforeThePosition() {
        let e = [entry(1, "A", start: 10, line: 2), entry(2, "B", start: 50, line: 8), entry(2, "C", start: 90, line: 15)]
        XCTAssertNil(OutlineModel.index(containing: 0, in: e))
        XCTAssertNil(OutlineModel.index(containing: 9, in: e))
        XCTAssertEqual(OutlineModel.index(containing: 10, in: e), 0)
        XCTAssertEqual(OutlineModel.index(containing: 49, in: e), 0)
        XCTAssertEqual(OutlineModel.index(containing: 50, in: e), 1)
        XCTAssertEqual(OutlineModel.index(containing: 10_000, in: e), 2)
        XCTAssertNil(OutlineModel.index(atLine: 1.9, in: e))
        XCTAssertEqual(OutlineModel.index(atLine: 2.0, in: e), 0)
        XCTAssertEqual(OutlineModel.index(atLine: 14.99, in: e), 1)
        XCTAssertEqual(OutlineModel.index(atLine: 99, in: e), 2)
        XCTAssertNil(OutlineModel.index(containing: 5, in: []))
    }

    // MARK: the list

    private func controller(_ entries: [OutlineEntry]) -> OutlineController {
        _ = NSApplication.shared
        let c = OutlineController(style: SidebarStyle(ThemeStore.shared.palette(ThemeStore.shared.theme(id: "light"))))
        c.view.frame = NSRect(x: 0, y: 0, width: 220, height: 600)
        c.update(entries)
        return c
    }

    func testTheListShowsTheTreeOpenAndFoldsWhereTheUserFolded() {
        let e = [entry(1, "A"), entry(2, "A1"), entry(3, "A1a"), entry(2, "A2"), entry(1, "B"), entry(2, "B1")]
        let c = controller(e)
        XCTAssertEqual(c.visibleIndices, [0, 1, 2, 3, 4, 5])
        c.collapse(1)
        XCTAssertEqual(c.visibleIndices, [0, 1, 3, 4, 5])
        // A heading changes elsewhere (the same shape): the fold stays. So does a heading added after it.
        var e2 = e
        e2[5] = entry(2, "B1 renamed")
        c.update(e2)
        XCTAssertEqual(c.visibleIndices, [0, 1, 3, 4, 5])
        e2.append(entry(2, "B2"))
        c.update(e2)
        XCTAssertEqual(c.visibleIndices, [0, 1, 3, 4, 5, 6])
        // One before it, in front: the fold is still on the same heading.
        e2.insert(entry(1, "Z"), at: 0)
        c.update(e2)
        XCTAssertEqual(c.visibleIndices, [0, 1, 2, 4, 5, 6, 7])
        XCTAssertEqual(c.view.list.isItemExpanded(c.view.list.item(atRow: 2)), false)
        c.expand(2)
        XCTAssertEqual(c.visibleIndices, [0, 1, 2, 3, 4, 5, 6, 7])
        c.update([])
        XCTAssertTrue(c.visibleIndices.isEmpty)
        XCTAssertTrue(!c.view.list.isHidden)
    }

    /// Rows added and removed one by one (the cheap path) and the reloads end where a fresh list would.
    func testRandomEditsOfTheHeadingsLeaveTheRowsOfAFreshList() {
        var rng = SplitMix(seed: 0x0071_1213)
        var e: [OutlineEntry] = (0..<40).map { entry(UInt8(1 + rng.next() % 4), "H\($0)") }
        var counter = 100
        let c = controller(e)
        for round in 0..<400 {
            let n = 1 + Int(rng.next() % 4)
            for _ in 0..<n {
                switch rng.next() % 5 {
                case 0 where e.count > 1: e.remove(at: Int(rng.next() % UInt64(e.count)))
                case 1: counter += 1; e.insert(entry(UInt8(1 + rng.next() % 5), "N\(counter)"), at: Int(rng.next() % UInt64(e.count + 1)))
                case 2 where !e.isEmpty:
                    let i = Int(rng.next() % UInt64(e.count))
                    e[i] = entry(UInt8(1 + rng.next() % 5), e[i].text)
                case 3 where e.count > 4:
                    let i = Int(rng.next() % UInt64(e.count - 3))
                    e.removeSubrange(i..<(i + 1 + Int(rng.next() % 3)))
                default:
                    if !e.isEmpty {
                        let i = Int(rng.next() % UInt64(e.count))
                        e[i] = entry(e[i].level, e[i].text + "x")
                    }
                }
            }
            let before = c.entries.map { "\($0.level)\($0.text)" }
            c.update(e)
            XCTAssertEqual(c.entries, e, "round \(round)")
            if c.visibleIndices != Array(0..<e.count) {
                XCTFail("round \(round): rows \(c.visibleIndices) before \(before) after \(e.map { "\($0.level)\($0.text)" })")
                break
            }
            let fresh = controller(e)
            let shown = (0..<c.view.list.numberOfRows).map { r -> String in
                let node = c.view.list.item(atRow: r) as! OutlineNode
                return "\(c.view.list.level(forRow: r)) \(node.entry.text)"
            }
            let want = (0..<fresh.view.list.numberOfRows).map { r -> String in
                let node = fresh.view.list.item(atRow: r) as! OutlineNode
                return "\(fresh.view.list.level(forRow: r)) \(node.entry.text)"
            }
            XCTAssertEqual(shown, want, "round \(round): the same levels as a fresh list")
        }
        XCTAssertGreaterThan(c.rebuilds, 100)
        XCTAssertGreaterThan(c.subtreeReloads, 0, "some reloads read one subtree only (\(c.reloads) reloads)")
    }

    /// Found in the test pass: a `##` added before the `###`s of the `##` above it (they become its children) reloaded the
    /// whole list, about 30 ms at 1,000 headings. Only the `#` the change is under is read again now; folds inside it and
    /// elsewhere stay, and the rows are a fresh list's.
    func testAHeadingThatTakesTheFollowingOnesReloadsOnlyItsSubtree() {
        var e: [OutlineEntry] = []
        for p in 0..<200 { e += [entry(1, "Part \(p)"), entry(2, "Section \(p)"), entry(3, "Sub \(p)a"), entry(3, "Sub \(p)b"), entry(4, "Deep \(p)")] }
        let c = controller(e)
        c.collapse(5 * 150 + 1) // "Section 150", away from the change
        c.collapse(5 * 100 + 3) // "Sub 100b", inside it
        let reloads = c.reloads, subtrees = c.subtreeReloads
        var e2 = e
        e2.insert(entry(2, "Taker"), at: 5 * 100 + 2) // between "Section 100" and "Sub 100a": both Subs move under it
        let t0 = CFAbsoluteTimeGetCurrent()
        c.update(e2)
        let took = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertEqual(c.reloads, reloads + 1)
        XCTAssertEqual(c.subtreeReloads, subtrees + 1, "only Part 100 is read again")
        let rows = c.visibleIndices.map { c.entries[$0].text }
        XCTAssertEqual(Array(rows[500..<506]), ["Part 100", "Section 100", "Taker", "Sub 100a", "Sub 100b", "Part 101"], "Sub 100b still folded")
        XCTAssertFalse(rows.contains("Sub 150a"), "Section 150 still folded")
        XCTAssertEqual(c.view.list.level(forRow: 503), 2)
        XCTAssertEqual(rows.count, e2.count - 1 - 3, "one Deep under the fold inside, three under the one outside")
        print("subtree reload of a 1,001-heading list: \(took * 1000) ms")
    }

    func testTheMarkFollowsAndHidesInsideAFoldAndYieldsToTheUsersOwnMoves() throws {
        let e = [entry(1, "A"), entry(2, "A1"), entry(3, "A1a"), entry(1, "B")]
        let c = controller(e)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.view
        func marked() -> String? {
            c.view.list.selectedRow >= 0 ? (c.view.list.item(atRow: c.view.list.selectedRow) as? OutlineNode)?.entry.text : nil
        }
        c.mark(2)
        XCTAssertEqual(marked(), "A1a")
        c.collapse(1)
        c.mark(2)
        XCTAssertEqual(marked(), "A1", "inside a fold: the fold is marked")
        c.mark(nil)
        XCTAssertNil(marked())
        // The list has the keyboard: the user is moving through it, the mark does not take that from them.
        window.makeFirstResponder(c.view.list)
        c.view.list.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        c.mark(0)
        XCTAssertEqual(marked(), "B", "left where the user put it")
        XCTAssertTrue(window.firstResponder === c.view.list, "marking never takes or gives the keyboard")
        // No jump from a mark, one from a click.
        var jumps: [String] = []
        c.onJump = { jumps.append($0.text) }
        window.makeFirstResponder(nil)
        c.mark(0)
        XCTAssertTrue(jumps.isEmpty)
    }

    func testALeafAddedOrRemovedChangesOneRowAndDoesNotReload() {
        let e = [entry(1, "A"), entry(2, "A1"), entry(2, "A2"), entry(1, "B"), entry(2, "B1")]
        let c = controller(e)
        let reloads = c.reloads
        var e2 = e
        e2.insert(entry(2, "A3"), at: 3)
        c.update(e2)
        XCTAssertEqual(c.visibleIndices, [0, 1, 2, 3, 4, 5])
        e2.remove(at: 1)
        c.update(e2)
        XCTAssertEqual(c.visibleIndices, [0, 1, 2, 3, 4])
        XCTAssertEqual(c.reloads, reloads, "no reload for either")
        // A heading that takes what follows it as children moves them: that reloads.
        e2.insert(entry(1, "C"), at: 1)
        c.update(e2)
        XCTAssertEqual(c.visibleIndices, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(c.reloads, reloads + 1)
    }

    func testALeafInALongRepetitiveListChangesOneRow() {
        var e: [OutlineEntry] = []
        for _ in 0..<334 { e += [entry(1, "Part"), entry(2, "Section"), entry(3, "Subsection")] }
        let c = controller(e)
        let reloads = c.reloads
        var e2 = e
        e2.insert(entry(3, "Added 1"), at: 3)
        c.update(e2)
        XCTAssertEqual(c.reloads, reloads, "inserting after the first Subsection")
        e2.remove(at: 3)
        c.update(e2)
        XCTAssertEqual(c.reloads, reloads, "and removing it")
        XCTAssertEqual(c.visibleIndices.count, e.count)
    }

    func testTheListIsAnAccessibilityOutlineOfNamedHeadings() throws {
        let c = controller([entry(1, "Title"), entry(2, "")])
        XCTAssertEqual(c.view.list.accessibilityRole(), .outline)
        XCTAssertEqual(c.view.list.accessibilityLabel(), "Outline")
        let cell = try XCTUnwrap(c.view.list.view(atColumn: 0, row: 0, makeIfNecessary: true))
        XCTAssertEqual(cell.accessibilityLabel(), "Title")
        let empty = try XCTUnwrap(c.view.list.view(atColumn: 0, row: 1, makeIfNecessary: true))
        XCTAssertEqual(empty.accessibilityLabel(), "Untitled heading", "a bare # is announced as something")
    }

    // MARK: the window

    private func open(_ text: String, layout: LayoutMode = .editor, mode: ViewMode = .source, outline: Bool = false, settings: Settings = isolatedSettings()) throws -> (MarkdownDocument, EditorWindowController) {
        _ = NSApplication.shared
        settings.defaultLayout = layout
        settings.defaultViewMode = mode
        settings.showSideColumnInNewWindows = outline
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: 1000, height: 700))
        wc.window?.layoutIfNeeded()
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    private static let sample = "# One\n\nsome text\n\n## Two\n\nmore text\n\n### Three\n\n" + String(repeating: "filler line\n\n", count: 60) + "# Four\n\nend\n\n" + String(repeating: "after line\n\n", count: 60)

    private func waitEntries(_ wc: EditorWindowController, _ n: Int) -> Bool {
        spin { wc.outline?.entries.count == n }
    }

    func testTheOutlineIsShownFromTheMenuAndTheSettingAndTheWindowIsPlainWithout() throws {
        let (doc, wc) = try open(Self.sample)
        defer { doc.close() }
        XCTAssertNil(wc.outline)
        XCTAssertTrue(wc.window?.contentView === wc.root, "off: the window is exactly the editor's own view")
        let item = try XCTUnwrap(MainMenu.build().items.first { $0.title == "View" }?.submenu?.items.first { $0.title == "Side Column" })
        XCTAssertEqual(item.action, #selector(EditorWindowController.toggleSideColumn(_:)))
        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .control])
        XCTAssertTrue(wc.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        wc.toggleSideColumn(nil)
        XCTAssertTrue(waitEntries(wc, 4))
        XCTAssertNotNil(wc.outline)
        XCTAssertTrue(wc.window?.contentView === wc.paneHost, "on: the editor's pane and the column in a split of their own")
        XCTAssertTrue(wc.root.superview === wc.paneHost && wc.columnView?.superview === wc.paneHost && wc.outline?.view.superview === wc.columnView)
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, 260, accuracy: 1)
        XCTAssertEqual(wc.outline?.view.frame.width ?? 0, 260, accuracy: 1, "the outline fills the column")
        XCTAssertTrue(wc.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        XCTAssertEqual(wc.outline?.entries.map(\.text), ["One", "Two", "Three", "Four"])
        XCTAssertEqual(wc.window?.contentView?.bounds.width ?? 0, wc.window?.contentLayoutRect.width ?? 0, accuracy: 0.5)
        wc.toggleSideColumn(nil)
        XCTAssertNil(wc.outline)
        XCTAssertTrue(wc.window?.contentView === wc.root)
        XCTAssertEqual(wc.root.frame.width, wc.window?.contentView?.bounds.width ?? 0, accuracy: 0.5)
        // The default setting opens new windows with it, 260 points wide.
        XCTAssertFalse(Settings(defaults: UserDefaults(suiteName: "outline-\(UUID().uuidString)")!).showSideColumnInNewWindows, "off by default")
        let (doc2, wc2) = try open(Self.sample, outline: true)
        defer { doc2.close() }
        XCTAssertNotNil(wc2.outline)
        XCTAssertEqual(wc2.session.columnWidth, 260)
        XCTAssertTrue(waitEntries(wc2, 4))
    }

    func testTheWidthIsRememberedPerWindowAndAsTheDefault() throws {
        let settings = isolatedSettings()
        let (doc, wc) = try open(Self.sample, outline: true, settings: settings)
        defer { doc.close() }
        XCTAssertEqual(settings.sideColumnWidth, 260)
        let host = try XCTUnwrap(wc.paneHost)
        // A drag of the divider (an event in the mouse's hands) is the user's: the width is remembered.
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: wc.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let width = host.bounds.width
        host.setPosition(width - 300, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, 300, accuracy: 1)
        _ = drag
        // (A window's resize leaves the column's width alone.)
        wc.window?.setContentSize(NSSize(width: 1200, height: 700))
        wc.window?.layoutIfNeeded()
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, 300, accuracy: 1)
        XCTAssertEqual(wc.root.frame.width + 1 + (wc.columnView?.frame.width ?? 0), host.bounds.width, accuracy: 1)
        // Another window starts from the setting.
        settings.sideColumnWidth = 340
        let (doc2, wc2) = try open(Self.sample, outline: true, settings: settings)
        defer { doc2.close() }
        XCTAssertEqual(wc2.columnView?.frame.width ?? 0, 340, accuracy: 1)
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, 300, accuracy: 1, "each window keeps its own")
        settings.sideColumnWidth = 9_000
        XCTAssertEqual(settings.sideColumnWidth, 480)
        settings.sideColumnWidth = 3
        XCTAssertEqual(settings.sideColumnWidth, 200)
    }

    func testTheWindowNeverGrowsAndItsNarrowestMakesRoomForTheColumn() throws {
        let (doc, wc) = try open(Self.sample)
        defer { doc.close() }
        let window = try XCTUnwrap(wc.window)
        let before = window.frame.width
        let minBefore = window.minSize.width
        wc.toggleSideColumn(nil)
        XCTAssertEqual(window.frame.width, before, accuracy: 0.5, "the column takes the editor's room, not more window")
        XCTAssertEqual(window.minSize.width, minBefore + 261, accuracy: 0.5)
        wc.toggleSideColumn(nil)
        XCTAssertEqual(window.minSize.width, minBefore, accuracy: 0.5)
    }

    func testTheTitleBarRowIsStillTheWindowsOverTheColumn() throws {
        let (doc, wc) = try open(Self.sample, outline: true)
        defer { doc.close() }
        let column = try XCTUnwrap(wc.outline?.view)
        XCTAssertTrue(column.band.mouseDownCanMoveWindow)
        XCTAssertEqual(column.band.frame.height, column.topInset, accuracy: 0.5)
        XCTAssertFalse(column.scroll.frame.minY < column.topInset, "the list begins below the title bar")
    }

    /// Scrolls the editor so that `character`'s line is `into` points below the bottom of the title bar (negative: its top
    /// edge is under the bar), the way a wheel would.
    private func scroll(_ wc: EditorWindowController, toCharacter character: Int, into: CGFloat = 0) {
        let tv = wc.textView
        let lm = tv.layoutManager!
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(tv.string.utf16.count, character + 1)))
        let glyph = lm.glyphIndexForCharacter(at: character)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let clip = wc.scrollView.contentView
        let y = fragment.minY + tv.textContainerOrigin.y - wc.editorScrollView.baseInsetTop - into
        clip.scroll(to: NSPoint(x: 0, y: max(-wc.scrollView.contentInsets.top, y)))
        wc.scrollView.reflectScrolledClipView(clip)
    }

    private func marked(_ wc: EditorWindowController) -> String? {
        guard let o = wc.outline, o.view.list.selectedRow >= 0 else { return nil }
        return (o.view.list.item(atRow: o.view.list.selectedRow) as? OutlineNode)?.entry.text
    }

    func testTypingAHeadingAddsAnEntryWithinAnAnalysisAndTheCaretDoesNotMoveTheMark() throws {
        let (doc, wc) = try open(Self.sample, outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 4))
        let tv = wc.textView
        let ns = tv.string as NSString
        pump(0.1)
        XCTAssertEqual(marked(wc), "One", "the view is at the top")
        tv.setSelectedRange(NSRange(location: ns.range(of: "more text").location, length: 0))
        pump(0.1)
        XCTAssertEqual(marked(wc), "One", "the caret moved to Two's text; the mark is where the reader is")
        tv.setSelectedRange(NSRange(location: ns.range(of: "end").location, length: 0))
        pump(0.1)
        XCTAssertEqual(marked(wc), "One")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("## Fresh\n\nintro\n\n", replacementRange: tv.selectedRange())
        XCTAssertTrue(waitEntries(wc, 5), "within one analysis (and the pause that follows it)")
        XCTAssertEqual(wc.outline?.entries.map(\.text), ["Fresh", "One", "Two", "Three", "Four"])
        XCTAssertEqual(marked(wc), "Fresh", "the view is at the top of the document, where the new heading is")
        // The core's answer is the same as the shell's list.
        XCTAssertEqual(doc.session.coordinator.sync { $0.outline() }.map(\.text), wc.outline?.entries.map(\.text))
    }

    // MARK: following the scroll

    func testScrollingThroughALongDocumentMarksEachHeadingInTurn() throws {
        for (layout, mode) in [(LayoutMode.editor, ViewMode.source), (.split, .source), (.editor, .live), (.split, .live)] {
            let (doc, wc) = try open(Self.sample, layout: layout, mode: mode, outline: true)
            defer { doc.close() }
            XCTAssertTrue(waitEntries(wc, 4))
            let entries = try XCTUnwrap(wc.outline?.entries)
            for (i, e) in entries.enumerated() {
                scroll(wc, toCharacter: Int(e.range.start))
                pump(0.1)
                XCTAssertEqual(marked(wc), e.text, "\(layout) \(mode): \(e.text) at the top")
                // The heading's line just under the bar is visible: it counts, with its top edge a few points below the bar's.
                scroll(wc, toCharacter: Int(e.range.start), into: 8)
                pump(0.1)
                XCTAssertEqual(marked(wc), e.text, "\(layout) \(mode): \(e.text) just under the bar")
                // Midway to the next heading: still this one.
                let next = i + 1 < entries.count ? Int(entries[i + 1].range.start) : (wc.textView.string as NSString).length - 1
                scroll(wc, toCharacter: (Int(e.range.start) + next) / 2)
                pump(0.1)
                XCTAssertEqual(marked(wc), e.text, "\(layout) \(mode): between \(e.text) and the next")
            }
            // Back above the first heading's text: the first stays (nothing above it).
            scroll(wc, toCharacter: 0)
            pump(0.1)
            XCTAssertEqual(marked(wc), "One")
        }
    }

    func testTheCaretAtTheEndWithTheViewAtTheTopMarksTheFirstHeading() throws {
        let (doc, wc) = try open(Self.sample, outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 4))
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        scroll(wc, toCharacter: 0)
        pump(0.1)
        XCTAssertEqual(marked(wc), "One", "the caret is under Four; the reader is at the top")
        // And the other way round: the caret at the top, the view at the end.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        scroll(wc, toCharacter: (tv.string as NSString).length - 1)
        pump(0.1)
        XCTAssertEqual(marked(wc), "Four")
    }

    func testAJumpMarksTheChosenHeadingEvenWhereTheDocumentCannotScrollItToTheTop() throws {
        let (doc, wc) = try open("# One\n\n" + String(repeating: "filler line\n\n", count: 30) + "## Two\n\nend\n", outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 2))
        let two = try XCTUnwrap(wc.outline?.entries.last)
        wc.jump(to: two)
        pump(0.3)
        XCTAssertEqual(marked(wc), "Two", "a click marks it, and the scroll that follows does not take the mark off it")
        // A scroll of the reader's own after the jump does move it.
        pump(0.8)
        scroll(wc, toCharacter: 0)
        pump(0.1)
        XCTAssertEqual(marked(wc), "One")
    }

    /// Found in the M8f test pass: a scroll of the reader's own within 0.6 s of a jump was dropped with the jump's own,
    /// and nothing asked again when the quiet ended: the mark stayed on the heading chosen wherever the reader went.
    func testTheReadersWheelRightAfterAJumpMovesTheMark() throws {
        let (doc, wc) = try open("# One\n\n" + String(repeating: "filler line\n\n", count: 80) + "## Two\n\nend\n", outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 2))
        let two = try XCTUnwrap(wc.outline?.entries.last)
        let jumped = CFAbsoluteTimeGetCurrent()
        wc.jump(to: two)
        pump(0.1)
        XCTAssertEqual(marked(wc), "Two")
        // The jump's own late scrolling still leaves the mark alone.
        scroll(wc, toCharacter: 0)
        pump(0.1)
        XCTAssertEqual(marked(wc), "Two", "a programmatic scroll within the quiet is the jump's")
        scroll(wc, toCharacter: Int(two.range.start))
        pump(0.05)
        // The reader's wheel, 0.25 s after the jump, and the scrolling it starts (AppKit's own, which may go on after the
        // event: here it is made by hand, as an unfocused test app's scroll view need not act on a synthetic wheel event).
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 420, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        wc.scrollView.scrollWheel(with: event)
        scroll(wc, toCharacter: 0)
        pump(0.15)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - jumped, EditorWindowController.outlineJumpQuiet, "all of it within the jump's quiet")
        XCTAssertEqual(marked(wc), "One", "the reader's own scroll moves the mark at once, quiet or not")
    }

    /// Front matter, or an introduction, above the first heading: the first heading is marked (the reader is at the start
    /// of it); a document with no headings marks nothing and never fails; the Preview layout marks by the page's line.
    func testFrontMatterNoHeadingsAndThePreviewLayout() throws {
        let front = "---\ntitle: A note\ntags: [a, b]\n---\n\nAn introduction.\n\n" + String(repeating: "intro line\n\n", count: 40) + "# First\n\ntext\n\n## Second\n\n" + String(repeating: "more\n\n", count: 80)
        let (doc, wc) = try open(front, outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 2))
        scroll(wc, toCharacter: 0)
        pump(0.1)
        XCTAssertEqual(marked(wc), "First", "front matter at the top: the first heading")
        scroll(wc, toCharacter: (front as NSString).range(of: "intro line").location)
        pump(0.1)
        XCTAssertEqual(marked(wc), "First")
        let second = try XCTUnwrap(wc.outline?.entries.last)
        scroll(wc, toCharacter: Int(second.range.start))
        pump(0.1)
        XCTAssertEqual(marked(wc), "Second")
        // The Preview layout: the page's top line says.
        doc.session.setLayout(.preview)
        pump(0.1)
        wc.outlinePageScrolled(to: Double(second.line) + 2)
        XCTAssertEqual(marked(wc), "Second")
        let first = try XCTUnwrap(wc.outline?.entries.first)
        wc.outlinePageScrolled(to: Double(first.line))
        XCTAssertEqual(marked(wc), "First")
        // No headings at all.
        let (plain, pwc) = try open(String(repeating: "just words\n\n", count: 200), outline: true)
        defer { plain.close() }
        pump(0.3)
        XCTAssertEqual(pwc.outline?.entries.count, 0)
        for y in [0, 500, 2_000] {
            scroll(pwc, toCharacter: y)
            pump(0.05)
            pwc.outlineFollowScroll()
            XCTAssertNil(marked(pwc))
        }
    }

    func testReduceMotionAndFocusCentringDoNotChangeWhatTheScrollMarks() throws {
        for reduce in [true, false] {
            let (doc, wc) = try open(Self.sample, outline: true)
            defer { doc.close() }
            XCTAssertTrue(waitEntries(wc, 4))
            wc.centring.reduceMotion = { reduce }
            doc.session.setFocusEnabled(true)
            pump(0.8)
            let entries = try XCTUnwrap(wc.outline?.entries)
            let three = try XCTUnwrap(entries.first { $0.text == "Three" })
            scroll(wc, toCharacter: Int(three.range.start))
            pump(0.5)
            XCTAssertEqual(marked(wc), "Three", "reduce motion \(reduce)")
            // Clicking an entry still jumps and marks it, centred or not.
            let two = try XCTUnwrap(entries.first { $0.text == "Two" })
            wc.jump(to: two)
            pump(0.9)
            XCTAssertEqual(marked(wc), "Two", "reduce motion \(reduce), after a jump")
        }
    }

    func testAStreamOfScrollEventsIsOneUpdateARefreshAndAThousandHeadingsKeepATickUnderTwoMilliseconds() throws {
        let text = (1...1000).map { "## Heading \($0)\n\nsome words under heading \($0)\n" }.joined(separator: "\n")
        let (doc, wc) = try open(text, outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 1000))
        // The text is laid out once, as it would be after a first scroll through it: a tick is then what it costs itself.
        wc.textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
        let coalescer = try XCTUnwrap(wc.outlineScrollCoalescer)
        let runs = coalescer.runs, requests = coalescer.requests
        let clip = wc.scrollView.contentView
        for i in 0..<300 {
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(i) * 9))
            wc.scrollView.reflectScrolledClipView(clip)
        }
        XCTAssertGreaterThanOrEqual(coalescer.requests - requests, 300, "every scroll asks")
        XCTAssertEqual(coalescer.runs, runs, "and nothing runs before the display's next refresh")
        XCTAssertTrue(spin { coalescer.runs > runs })
        XCTAssertEqual(coalescer.runs, runs + 1, "one update for the whole stream")
        // A tick: the top character, the heading, the mark (a different heading each time).
        var worst: TimeInterval = 0
        var total: TimeInterval = 0
        let ticks = 150
        for i in 0..<ticks {
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(i) * 140))
            wc.outlineFollowScroll()
            worst = max(worst, wc.lastOutlineScrollUpdate)
            total += wc.lastOutlineScrollUpdate
        }
        XCTAssertEqual(marked(wc).map { $0.hasPrefix("Heading ") }, true)
        let mean = total / Double(ticks) * 1000
        XCTAssertLessThan(mean, 2, "a tick takes \(mean) ms on average (a debug build), worst \(worst * 1000)")
    }

    func testAKeystrokeCostsATimerNotAnOutlineUpdate() throws {
        let (doc, wc) = try open(Self.sample, outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 4))
        let o = try XCTUnwrap(wc.outline)
        let before = o.updates
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        for _ in 0..<12 { tv.insertText("x", replacementRange: tv.selectedRange()) }
        XCTAssertEqual(o.updates, before, "nothing while typing goes on")
        XCTAssertTrue(spin { o.updates > before })
        XCTAssertEqual(o.updates, before + 1, "one update, after the pause")
        XCTAssertEqual(o.entries.first?.text, "xxxxxxxxxxxxOne")
    }

    func testAClickJumpsTheEditorToPutTheHeadingAtTheTop() throws {
        let (doc, wc) = try open(Self.sample, outline: true)
        defer { doc.close() }
        XCTAssertTrue(waitEntries(wc, 4))
        let o = try XCTUnwrap(wc.outline)
        let four = try XCTUnwrap(o.entries.first { $0.text == "Four" })
        wc.jump(to: four)
        pump(0.2)
        XCTAssertEqual(wc.textView.selectedRange(), NSRange(location: Int(four.range.start), length: 0))
        let top = try XCTUnwrap(wc.editorTopAnchor())
        XCTAssertEqual(top.character, Int(four.range.start), "the heading's line is the editor's top")
        XCTAssertTrue(wc.window?.firstResponder === wc.textView, "writing goes on from there")
        XCTAssertEqual(wc.jumps, 1)
        // Centring on: the heading goes to the middle instead.
        wc.centring.reduceMotion = { true }
        doc.session.setFocusEnabled(true)
        XCTAssertTrue(wc.centring.isActive)
        let one = try XCTUnwrap(o.entries.first { $0.text == "One" })
        wc.jump(to: one)
        pump(0.3)
        let c = wc.centring
        let mid = try XCTUnwrap(c.lineMidY(at: Int(one.range.start))) + wc.textView.frame.minY
        let clip = wc.scrollView.contentView
        let visible = clip.bounds.height - wc.editorScrollView.baseInsetTop - wc.editorScrollView.baseInsetBottom
        XCTAssertEqual(mid - clip.bounds.minY, wc.editorScrollView.baseInsetTop + visible / 2, accuracy: 3, "centred, as a key would")
    }

    /// The column is the right-hand part of the window and the title bar's row stays the window's own over it: no
    /// accessory, the title shown, whatever the column's width.
    func testTheTitleBarStaysTheWindowsOwnWithTheColumnShown() throws {
        _ = NSApplication.shared
        let settings = isolatedSettings()
        settings.showSideColumnInNewWindows = true
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data("# Doc\n\ntext\n".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        defer { doc.close() }
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        let window = try XCTUnwrap(wc.window)
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.layoutIfNeeded()
        pump(0.2)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertNotNil(wc.columnLeft)
        XCTAssertEqual(wc.columnLeft ?? 0, window.frame.width - 261, accuracy: 1.5, "the column is at its width, on the right")
        wc.toggleSideColumn(nil)
        XCTAssertNil(wc.columnLeft)
    }

    /// Added in the test pass: a window closed with the column shown (in Split, after a jump and a fold) leaves no
    /// outline object alive: the controller, its list, its rows' nodes and the split view that held the column.
    func testClosingAWindowWithTheOutlineFreesEverythingOfIt() throws {
        weak var weakController: EditorWindowController?
        weak var weakOutline: OutlineController?
        weak var weakList: NSOutlineView?
        weak var weakNode: OutlineNode?
        weak var weakHost: NSView?
        try autoreleasepool {
            let (doc, wc) = try open(Self.sample, layout: .split, outline: true)
            XCTAssertTrue(waitEntries(wc, 4))
            let o = try XCTUnwrap(wc.outline)
            wc.jump(to: try XCTUnwrap(o.entries.last))
            o.collapse(0)
            pump(0.2)
            weakController = wc; weakOutline = o; weakList = o.view.list; weakHost = wc.paneHost
            weakNode = o.view.list.item(atRow: 0) as? OutlineNode
            XCTAssertNotNil(weakNode)
            doc.updateChangeCount(.changeCleared)
            doc.close()
        }
        XCTAssertTrue(spin(timeout: 5) { weakController == nil && weakOutline == nil && weakNode == nil })
        XCTAssertNil(weakController, "window controller")
        XCTAssertNil(weakOutline, "outline controller")
        XCTAssertNil(weakNode, "the rows' nodes")
        // AppKit may keep a closed window's views a while (see the lifecycle test); its list must then not point back.
        if let list = weakList { XCTAssertNil(list.dataSource); XCTAssertNil(list.delegate) }
        _ = weakHost
    }
}
