import AppKit
import XCTest
@testable import MarkdownKit

/// Tabs that run past either end of the strip say so: a chevron on that side, inside the strip's own width, that
/// scrolls by one tab, and nothing when nothing is hidden.
@MainActor
final class TabOverflowTests: XCTestCase {
    // MARK: the model

    func testWhichEndsHaveTabsBeyondThem() {
        func o(_ count: Int, _ width: CGFloat, _ available: CGFloat, _ offset: CGFloat) -> String {
            let r = TabStripModel.overflow(count: count, tabWidth: width, available: available, offset: offset)
            return "\(r.left ? "<" : "-")\(r.right ? ">" : "-")"
        }
        XCTAssertEqual(o(3, 100, 400, 0), "--", "everything fits")
        XCTAssertEqual(o(4, 100, 400, 0), "--", "exactly fits")
        XCTAssertEqual(o(5, 100, 400, 0), "-" + ">", "one tab too many: more on the right")
        XCTAssertEqual(o(15, 96, 600, 0), "->", "at the start")
        XCTAssertEqual(o(15, 96, 600, 420), "<>", "in the middle: both")
        XCTAssertEqual(o(15, 96, 600, 840), "<-", "at the end (1440 - 600)")
        XCTAssertEqual(o(15, 96, 600, 0.4), "->", "a hair of offset is not a tab hidden")
        XCTAssertEqual(o(15, 96, 600, 839.7), "<-")
        XCTAssertEqual(o(15, 96, 600, 838), "<>", "two points short of the end: a tab edge is still clipped")
        XCTAssertEqual(o(0, 96, 600, 0), "--")
        XCTAssertEqual(o(2, 96, 0, 0), "->", "no room at all")
    }

    func testScrollingByATabStaysWithinWhatThereIs() {
        func s(_ tabs: Int, _ offset: CGFloat) -> CGFloat { TabStripModel.scrolled(by: tabs, tabWidth: 96, count: 15, available: 600, from: offset) }
        XCTAssertEqual(s(1, 0), 96)
        XCTAssertEqual(s(-1, 96), 0)
        XCTAssertEqual(s(-1, 10), 0, "not past the first tab")
        XCTAssertEqual(s(1, 800), 840, "not past the last tab")
        XCTAssertEqual(s(3, 100), 480, "from a scroll of the wheel: three tabs on from the first one wholly in view (at 192)")
        XCTAssertEqual(TabStripModel.scrolled(by: 1, tabWidth: 96, count: 2, available: 600, from: 0), 0, "nothing to scroll")
    }

    /// With the chevrons: a press brings the next tab out from under the left chevron, and it begins where the
    /// chevron ends, so its close button and title are never under the fade.
    func testAPressLeavesTheFirstTabClearOfTheChevron() {
        let c = TabOverflowButton.width
        XCTAssertEqual(TabStripModel.chevronWidth(tabWidth: 96, available: 600), c)
        XCTAssertEqual(TabStripModel.chevronWidth(tabWidth: 96, available: 150), 0, "no room for both and a tab: plain multiples")
        func s(_ tabs: Int, _ offset: CGFloat) -> CGFloat { TabStripModel.scrolled(by: tabs, tabWidth: 96, count: 15, available: 600, chevron: c, from: offset) }
        func first(_ offset: CGFloat) -> Int { TabStripModel.firstClearTab(offset: offset, tabWidth: 96, chevron: c) }
        XCTAssertEqual(s(1, 0), 96 - c, "the second tab begins at the chevron's edge")
        XCTAssertEqual(first(96 - c), 1)
        XCTAssertEqual(s(1, 96 - c), 2 * 96 - c, "then a whole tab a press")
        XCTAssertEqual(s(-1, 2 * 96 - c), 96 - c)
        XCTAssertEqual(s(-1, 96 - c), 0, "back at the start: the first tab, no chevron")
        // From the end (840): the tab partly under the chevron (at 24) counts as shown; a press shows the one before.
        XCTAssertEqual(first(840), 9)
        XCTAssertEqual(s(-1, 840), 8 * 96 - c)
        XCTAssertEqual(s(1, 8 * 96 - c), 9 * 96 - c)
        XCTAssertEqual(s(1, 9 * 96 - c), 840, "the last press reaches the end")
        XCTAssertEqual(s(1, 840), 840)
        // Every stop short of the end leaves tab `first` beginning exactly at the chevron's edge.
        var e: CGFloat = 0
        for _ in 0..<12 {
            e = s(1, e)
            guard e < 840 else { break }
            XCTAssertEqual(CGFloat(first(e)) * 96 - e, c, "at \(e)")
        }
        // Revealing a tab scrolled out on the left puts it at the chevron's edge; one past the right edge, clear of
        // the right chevron.
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 3, tabWidth: 96, count: 15, available: 600, chevron: c, current: 500), 3 * 96 - c)
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 0, tabWidth: 96, count: 15, available: 600, chevron: c, current: 500), 0)
        let right = TabStripModel.scrollOffset(revealing: 9, tabWidth: 96, count: 15, available: 600, chevron: c, current: 0)
        XCTAssertEqual(right, 10 * 96 - 600 + c)
        XCTAssertLessThanOrEqual(10 * 96 - right, 600 - c, "its right edge is left of the right chevron")
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 14, tabWidth: 96, count: 15, available: 600, chevron: c, current: 0), 840)
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 2, tabWidth: 96, count: 15, available: 600, chevron: c, current: 96 - c), 96 - c, "in view: no scroll")
    }

    // MARK: the view

    private func strip(tabs: Int, width: CGFloat = 700, inset: CGFloat = 100, selected: Int = 0) -> TabStripView {
        let s = TabStripView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        s.leadingInset = inset
        s.setEntries((0..<tabs).map { TabEntry(windowNumber: 100 + $0, title: "Tab \($0)", edited: false, selected: $0 == selected) })
        s.layoutSubtreeIfNeeded()
        return s
    }

    private func state(_ s: TabStripView) -> String { "\(s.leftChevron.isHidden ? "-" : "<")\(s.rightChevron.isHidden ? "-" : ">")" }

    func testTheChevronsShowWhereTabsAreHidden() {
        let s = strip(tabs: 15)
        XCTAssertEqual(s.available, 600)
        XCTAssertEqual(s.tabWidth, TabStripModel.minimumTabWidth, "as narrow as a tab gets before the strip scrolls")
        XCTAssertEqual(state(s), "->", "the first tab is selected: more lie to the right")
        s.scroll(toFraction: 0.5)
        XCTAssertEqual(state(s), "<>")
        s.scroll(toFraction: 1)
        XCTAssertEqual(state(s), "<-")
        s.scroll(toFraction: 0)
        XCTAssertEqual(state(s), "->")
        XCTAssertEqual(s.overflow.left, false)
        XCTAssertEqual(s.overflow.right, true)
    }

    func testNothingIsShownWhenEverythingFits() {
        XCTAssertEqual(state(strip(tabs: 3)), "--")
        XCTAssertEqual(state(strip(tabs: 6, width: 700, inset: 0)), "--", "six tabs of 96 in 700")
        XCTAssertEqual(state(strip(tabs: 2, inset: 0)), "--")
        let s = strip(tabs: 1)
        XCTAssertEqual(state(s), "--")
    }

    func testTheChevronsStayInsideTheTabsOwnRoom() {
        let s = strip(tabs: 15)
        s.scroll(toFraction: 0.5)
        let room = NSRect(x: s.leadingInset, y: 0, width: s.available, height: s.bounds.height)
        XCTAssertTrue(room.contains(s.leftChevron.frame), "\(s.leftChevron.frame) in \(room)")
        XCTAssertTrue(room.contains(s.rightChevron.frame))
        XCTAssertGreaterThanOrEqual(s.leftChevron.frame.minX, s.leadingInset, "never over the sidebar's part of the row")
        XCTAssertEqual(s.rightChevron.frame.maxX, s.bounds.width, accuracy: 0.5, "the right one sits at the strip's end")
        XCTAssertTrue(s.bounds.contains(s.rightChevron.frame))
        // Hardly any room: they still do not leave it.
        let tiny = strip(tabs: 15, width: 160, inset: 100)
        XCTAssertEqual(tiny.available, 60)
        tiny.scroll(toFraction: 0.5)
        let tinyRoom = NSRect(x: 100, y: 0, width: 60, height: 28)
        XCTAssertTrue(tinyRoom.contains(tiny.leftChevron.frame) && tinyRoom.contains(tiny.rightChevron.frame))
    }

    func testAPressScrollsByOneTabAndTheChevronGoesWhenThereIsNothingMore() {
        let s = strip(tabs: 15)
        let w = s.tabWidth
        let c = s.chevronWidth
        XCTAssertEqual(c, TabOverflowButton.width)
        XCTAssertEqual(s.scrollOffset, 0)
        s.rightChevron.onPress?(1)
        XCTAssertEqual(s.scrollOffset, w - c, "the second tab begins where the chevron ends")
        XCTAssertEqual(state(s), "<>")
        // The second tab's close button is clear of the chevron that now shows.
        let second = s.visibleTabFrames[1]
        XCTAssertEqual(second.width, w, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(second.minX + TabStripModel.closeButtonInset, s.leftChevron.frame.maxX)
        s.leftChevron.onPress?(-1)
        XCTAssertEqual(s.scrollOffset, 0)
        XCTAssertEqual(state(s), "->")
        s.scroll(toFraction: 1)
        let end = s.scrollOffset
        s.rightChevron.onPress?(1)
        XCTAssertEqual(s.scrollOffset, end, "not past the end")
        for _ in 0..<20 { s.leftChevron.onPress?(-1) }
        XCTAssertEqual(s.scrollOffset, 0)
        XCTAssertEqual(state(s), "->")
        // Pressing it with the pointer, as a person would.
        s.rightChevron.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                          eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertEqual(s.scrollOffset, w - c)
    }

    func testTheStateFollowsTheTabsTheRoomAndTheSelection() {
        let s = strip(tabs: 15)
        XCTAssertEqual(state(s), "->")
        // A tab is selected far to the right: the strip scrolls to show it, and says what is behind it.
        s.setEntries((0..<15).map { TabEntry(windowNumber: 100 + $0, title: "Tab \($0)", edited: false, selected: $0 == 14) })
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(state(s), "<-")
        // A tab in the middle: both sides.
        s.setEntries((0..<15).map { TabEntry(windowNumber: 100 + $0, title: "Tab \($0)", edited: false, selected: $0 == 7) })
        s.scroll(toFraction: 0.5)
        XCTAssertEqual(state(s), "<>")
        // Tabs closed down to a few: nothing is hidden any more.
        s.setEntries((0..<4).map { TabEntry(windowNumber: 100 + $0, title: "Tab \($0)", edited: false, selected: $0 == 1) })
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(state(s), "--")
        XCTAssertEqual(s.scrollOffset, 0)
        // A tab added back: the right side again, with the new one selected.
        s.setEntries((0..<15).map { TabEntry(windowNumber: 100 + $0, title: "Tab \($0)", edited: false, selected: $0 == 14) })
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(state(s), "<-")
        // The strip made wider (a window resized): room for all, nothing hidden.
        s.setFrameSize(NSSize(width: 1800, height: 28))
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(state(s), "--")
        s.setFrameSize(NSSize(width: 700, height: 28))
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(state(s), "<-", "narrow again: the tabs scroll to keep the selected one")
        // The divider dragged: the room shrinks, or grows.
        s.leadingInset = 400
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(s.available, 300)
        XCTAssertTrue(s.overflow.left || s.overflow.right)
        s.leadingInset = 0
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(s.available, 700)
        XCTAssertEqual(s.leftChevron.frame.minX, 0)
    }

    /// A scroll of the user's stays while tabs change their titles or edited dots (an autosave, a rename in the
    /// background); another tab selected, or one added, brings the selected one into view.
    func testATitleThatChangesDoesNotUndoAScroll() {
        func entries(selected: Int, count: Int = 15, edited: Int = -1, title: String = "Tab") -> [TabEntry] {
            (0..<count).map { TabEntry(windowNumber: 100 + $0, title: "\(title) \($0)", edited: $0 == edited, selected: $0 == selected) }
        }
        let s = strip(tabs: 15, selected: 12)
        XCTAssertGreaterThan(s.scrollOffset, 0, "the selected tab was brought into view")
        s.scroll(toFraction: 0)
        s.setEntries(entries(selected: 12, edited: 3))
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(s.scrollOffset, 0, "an edited dot")
        s.setEntries(entries(selected: 12, edited: 3, title: "Renamed"))
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(s.scrollOffset, 0, "titles")
        XCTAssertEqual(state(s), "->")
        s.setEntries(entries(selected: 13, edited: 3, title: "Renamed"))
        s.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(s.scrollOffset, 0, "another tab selected: it is shown")
        s.scroll(toFraction: 0)
        s.setEntries(entries(selected: 13, count: 16))
        s.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(s.scrollOffset, 0, "a tab added: the selected one is shown")
    }

    func testAScrollWheelMovesThemToo() {
        let s = strip(tabs: 15)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -200, wheel3: 0).flatMap { NSEvent(cgEvent: $0) }
        s.scrollWheel(with: try! XCTUnwrap(event))
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(s.scrollOffset, 200, "the strip moved")
        XCTAssertEqual(state(s), "<>")
    }

    func testTheChevronsAreLabelledButtons() {
        let s = strip(tabs: 15)
        XCTAssertEqual(s.leftChevron.accessibilityRole(), .button)
        XCTAssertEqual(s.rightChevron.accessibilityRole(), .button)
        XCTAssertEqual(s.leftChevron.accessibilityLabel(), "Show earlier tabs")
        XCTAssertEqual(s.rightChevron.accessibilityLabel(), "Show later tabs")
        XCTAssertTrue(s.rightChevron.isAccessibilityElement())
        XCTAssertTrue(s.rightChevron.accessibilityPerformPress())
        XCTAssertEqual(s.scrollOffset, s.tabWidth - s.chevronWidth, "the accessibility press does what the click does")
    }

    /// VoiceOver reaches the chevrons that show, beside the tabs, and none that do not.
    func testTheChevronsThatShowAreInTheAccessibilityTree() {
        let s = strip(tabs: 15)
        func children() -> [String] { (s.accessibilityChildren() ?? []).compactMap { ($0 as? NSView)?.accessibilityLabel() } }
        XCTAssertEqual(children().first, "Tab 0")
        XCTAssertEqual(children().last, "Show later tabs")
        XCTAssertFalse(children().contains("Show earlier tabs"))
        s.scroll(toFraction: 0.5)
        XCTAssertEqual(children().first, "Show earlier tabs")
        XCTAssertEqual(children().last, "Show later tabs")
        XCTAssertEqual(children().count, 17)
        s.setEntries((0..<3).map { TabEntry(windowNumber: 100 + $0, title: "Tab \($0)", edited: false, selected: $0 == 0) })
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(children(), ["Tab 0", "Tab 1", "Tab 2"])
    }

    func testAFadedStripTakesNoClicksOnItsChevrons() {
        let s = strip(tabs: 15)
        let point = NSPoint(x: s.rightChevron.frame.midX, y: s.rightChevron.frame.midY)
        s.isFaded = true
        XCTAssertTrue(s.hitTest(point) === s, "invisible: the title bar's own")
        s.isFaded = false
        XCTAssertTrue(s.hitTest(point) === s.rightChevron || s.hitTest(point) is TabOverflowButton)
    }

    func testTheFadeFollowsTheThemeColour() {
        let s = strip(tabs: 15)
        s.fadeColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(s.leftChevron.fadeColor, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(s.rightChevron.fadeColor, s.leftChevron.fadeColor)
    }

    // MARK: in a window of notes mode

    func testTheStripOfAWindowInNotesModeShowsThemOnlyWithinThePane() throws {
        let lib = try TempLibrary(["a.md": "# a\n"])
        defer { lib.remove() }
        let controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
        let ws = Workspace(library: controller, settings: isolatedSettings(), notesMode: true)
        var docs: [MarkdownDocument] = []
        var controllers: [EditorWindowController] = []
        defer { for d in docs { d.updateChangeCount(.changeCleared); d.close() } }
        for i in 0..<15 {
            let doc = MarkdownDocument(settings: isolatedSettings())
            try doc.read(from: Data("# \(i)\n".utf8), ofType: "net.daringfireball.markdown")
            doc.makeWindowControllers()
            docs.append(doc)
            controllers.append(try XCTUnwrap(doc.windowControllers.first as? EditorWindowController))
        }
        let first = try XCTUnwrap(controllers[0].window)
        controllers[0].adopt(ws)
        for c in controllers.dropFirst() { first.addTabbedWindow(try XCTUnwrap(c.window), ordered: .above) }
        for c in controllers {
            c.tabs.refresh()
            c.tabs.strip.layoutSubtreeIfNeeded()
            let strip = c.tabs.strip
            XCTAssertEqual(strip.leadingInset > 0, true)
            XCTAssertTrue(strip.overflow.right || strip.overflow.left, "fifteen tabs do not fit beside a 240 pt sidebar")
            let pane = c.root.convert(c.root.bounds, to: nil).minX
            for chevron in [strip.leftChevron, strip.rightChevron] where !chevron.isHidden {
                XCTAssertGreaterThanOrEqual(strip.convert(chevron.frame, to: nil).minX, pane - 0.5, "a chevron over the sidebar")
            }
        }
        // Out of notes mode the strip has the whole row: fifteen tabs still overflow, now from the buttons on.
        ws.setNotesMode(false)
        for c in controllers {
            c.tabs.refresh()
            c.tabs.strip.layoutSubtreeIfNeeded()
            XCTAssertEqual(c.tabs.strip.leadingInset, 0)
            XCTAssertEqual(c.tabs.strip.leftChevron.frame.minX == 0 || c.tabs.strip.leftChevron.isHidden, true)
        }
        for c in controllers { c.leaveWorkspace() }
    }
}
