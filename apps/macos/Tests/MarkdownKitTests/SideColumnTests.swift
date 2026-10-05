import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// M8f: one right column with a segmented header (Outline | History), one width and one toggle.
@MainActor
final class SideColumnTests: XCTestCase {
    private var docs: [MarkdownDocument] = []

    override func tearDown() {
        for d in docs { d.updateChangeCount(.changeCleared); d.close() }
        docs = []
        super.tearDown()
    }

    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    private static let sample = "# One\n\nsome text\n\n## Two\n\nmore text\n\n### Three\n\n" + String(repeating: "filler line\n\n", count: 30) + "# Four\n\nend\n"

    private func open(_ given: String? = nil, settings: Settings = isolatedSettings(), column: Bool = false, bundled: Bool = false) throws -> (MarkdownDocument, EditorWindowController) {
        _ = NSApplication.shared
        let text = given ?? Self.sample
        settings.showSideColumnInNewWindows = column
        let doc = MarkdownDocument(settings: settings)
        doc.isBundled = bundled
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        docs.append(doc)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: 1100, height: 700))
        wc.window?.layoutIfNeeded()
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    private func menuItem(_ title: String) throws -> NSMenuItem {
        try XCTUnwrap(MainMenu.build().items.first { $0.title == "View" }?.submenu?.items.first { $0.title == title })
    }

    // MARK: the controller

    func testSwitchingTheSegmentKeepsTheWidthAndEachPaneIsAliveOnlyWhileShown() throws {
        let (_, wc) = try open(column: true)
        let column = try XCTUnwrap(wc.sideColumn)
        XCTAssertEqual(column.pane, .outline)
        XCTAssertNotNil(wc.outline)
        XCTAssertNil(wc.history, "the history is not made until it is shown")
        XCTAssertEqual(column.madePanes, 1)
        let width = try XCTUnwrap(wc.columnView).frame.width
        let left = try XCTUnwrap(wc.columnLeft)
        for round in 0..<3 {
            wc.session.selectColumnPane(.history)
            wc.window?.layoutIfNeeded()
            XCTAssertNil(wc.outline, "round \(round): the outline is gone while the history shows")
            XCTAssertNotNil(wc.history)
            XCTAssertTrue(wc.sideColumn === column, "the column itself stays")
            XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, width, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(wc.columnLeft), left, accuracy: 0.5)
            XCTAssertTrue(column.view.content === wc.history?.view)
            XCTAssertEqual(column.view.header.selectedSegment, 1)
            wc.session.selectColumnPane(.outline)
            wc.window?.layoutIfNeeded()
            XCTAssertNil(wc.history)
            XCTAssertNotNil(wc.outline)
            XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, width, accuracy: 0.5)
            XCTAssertTrue(column.view.content === wc.outline?.view)
            XCTAssertEqual(column.view.header.selectedSegment, 0)
        }
        XCTAssertEqual(column.madePanes, 7, "a pane is made again each time it is shown, and never kept")
    }

    func testThePanesAreFreedWhenTheyLeaveAndWhenTheColumnDoes() throws {
        weak var weakOutline: OutlineController?
        weak var weakHistory: HistoryController?
        weak var weakColumn: SideColumnController?
        weak var weakList: NSOutlineView?
        var wcRef: EditorWindowController?
        // (Autoreleased references made by the calls below live until the pool drains, as they would not in a run loop.)
        try autoreleasepool {
            let (_, wc) = try open(column: true)
            wcRef = wc
            XCTAssertTrue(spin { wc.outline?.entries.count == 4 })
            weakOutline = wc.outline
            weakList = wc.outline?.view.list
            weakColumn = wc.sideColumn
            XCTAssertNotNil(weakOutline)
            wc.session.selectColumnPane(.history)
            weakHistory = wc.history
            XCTAssertNotNil(weakHistory)
        }
        XCTAssertTrue(spin(timeout: 5) { weakOutline == nil && weakList == nil }, "the outline and its list are freed when the history takes the content area")
        let wc = try XCTUnwrap(wcRef)
        autoreleasepool { wc.session.setColumnShown(false) }
        XCTAssertNil(wc.sideColumn)
        XCTAssertTrue(spin(timeout: 5) { weakHistory == nil && weakColumn == nil }, "and the history and the column when the column is hidden")
        XCTAssertNil(wc.paneHost)
        XCTAssertTrue(wc.window?.contentView === wc.root)
    }

    func testTheUsersSegmentClickSwitchesAndIsRememberedPerWindowAndAsTheDefault() throws {
        let settings = isolatedSettings()
        let (doc, wc) = try open(settings: settings, column: true)
        XCTAssertEqual(settings.sideColumnPane, .outline)
        let header = try XCTUnwrap(wc.sideColumn?.view.header)
        header.selectedSegment = 1
        _ = NSApp.sendAction(try XCTUnwrap(header.action), to: header.target, from: header)
        XCTAssertEqual(doc.session.columnPane, .history, "this window")
        XCTAssertNotNil(wc.history)
        XCTAssertEqual(settings.sideColumnPane, .history, "and the default")
        // A window opened later starts on it; one that already has its own keeps it.
        let (doc2, wc2) = try open(settings: settings, column: true)
        XCTAssertEqual(doc2.session.columnPane, .history)
        XCTAssertNotNil(wc2.history)
        doc2.session.selectColumnPane(.outline)
        XCTAssertEqual(doc.session.columnPane, .history, "each window keeps its own")
        // Hidden and shown again, the column comes back on the pane it had.
        doc.session.setColumnShown(false)
        doc.session.setColumnShown(true)
        XCTAssertNotNil(wc.history)
        XCTAssertNil(wc.outline)
    }

    func testOneWidthForBothPanesIsRememberedPerWindowAndAsTheDefault() throws {
        let settings = isolatedSettings()
        let (doc, wc) = try open(settings: settings, column: true)
        XCTAssertEqual(doc.session.columnWidth, 260)
        let host = try XCTUnwrap(wc.paneHost)
        host.setPosition(host.bounds.width - 330, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, 330, accuracy: 1)
        // Only the person's drag is remembered; the programmatic move above is not an event of the mouse's.
        XCTAssertEqual(settings.sideColumnWidth, 260)
        wc.session.columnWidth = 330
        wc.session.selectColumnPane(.history)
        wc.window?.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, 330, accuracy: 1, "the history has the width the outline had")
        wc.session.setColumnShown(false)
        wc.session.setColumnShown(true)
        XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, 330, accuracy: 1, "and it is remembered while the column is hidden")
        settings.sideColumnWidth = 300
        let (_, wc2) = try open(settings: settings, column: true)
        XCTAssertEqual(try XCTUnwrap(wc2.columnView).frame.width, 300, accuracy: 1, "a new window starts from the setting")
    }

    func testTheHeaderIsTheSystemsSmallSegmentedControlAndAccessible() throws {
        let (_, wc) = try open(column: true)
        let header = try XCTUnwrap(wc.sideColumn?.view.header)
        XCTAssertEqual(header.controlSize, .small)
        XCTAssertEqual(header.segmentCount, 2)
        XCTAssertEqual((0..<2).map { header.label(forSegment: $0) }, ["Outline", "History"])
        XCTAssertEqual(header.trackingMode, .selectOne)
        XCTAssertEqual(header.accessibilityLabel(), "Side column")
        XCTAssertTrue(header.isEnabled)
        // Below the title bar's row and above the pane, full width but for its margins.
        let column = try XCTUnwrap(wc.sideColumn?.view)
        column.layoutSubtreeIfNeeded()
        let bar = (wc.window?.frame.height ?? 0) - (wc.window?.contentLayoutRect.height ?? 0)
        XCTAssertGreaterThanOrEqual(header.frame.minY, bar, "under the title bar")
        XCTAssertEqual(header.frame.width, column.bounds.width - 20, accuracy: 0.5)
        let content = try XCTUnwrap(column.content)
        XCTAssertGreaterThanOrEqual(content.frame.minY, header.frame.maxY, "the pane starts under the header")
        XCTAssertEqual(content.frame.maxY, column.bounds.height, accuracy: 0.5)
        XCTAssertTrue(column.band.frame.height == bar && column.band.mouseDownCanMoveWindow, "the column's own band is the title bar's row")
        // The panes have no title bar room of their own.
        let outline = try XCTUnwrap(wc.outline?.view)
        XCTAssertEqual(outline.topInset, 0)
        XCTAssertTrue(outline.band.isHidden)
        wc.session.selectColumnPane(.history)
        wc.window?.layoutIfNeeded()
        let history = try XCTUnwrap(wc.history?.view)
        XCTAssertEqual(history.topInset, 0)
        XCTAssertTrue(history.band.isHidden)
    }

    // MARK: the menu

    func testViewSideColumnToggleAndShowHistoryAreOneColumnWithTwoKeys() throws {
        let (doc, wc) = try open()
        let side = try menuItem("Show Outline")
        let history = try menuItem("Show History")
        XCTAssertEqual(side.action, #selector(EditorWindowController.toggleSideColumn(_:)))
        XCTAssertEqual(side.keyEquivalent, "o")
        XCTAssertEqual(side.keyEquivalentModifierMask, [.command, .control])
        XCTAssertEqual(history.action, #selector(EditorWindowController.showHistory(_:)))
        XCTAssertEqual(history.keyEquivalent, "h")
        XCTAssertEqual(history.keyEquivalentModifierMask, [.command, .control])
        XCTAssertNil(MainMenu.build().items.first { $0.title == "View" }?.submenu?.items.first { $0.title == "Outline" || $0.title == "History" }, "the two old items are gone")
        XCTAssertTrue(wc.validateMenuItem(side) && wc.validateMenuItem(history))
        XCTAssertEqual(side.state, .off)
        XCTAssertEqual(history.state, .off)
        // ⌃⌘O: shows the column with the pane it had (the outline to start with), and hides it.
        wc.toggleSideColumn(nil)
        XCTAssertTrue(wc.validateMenuItem(side))
        XCTAssertEqual(side.state, .on)
        XCTAssertEqual(history.state, .off)
        XCTAssertEqual(doc.session.columnPane, .outline)
        // ⌃⌘H with the column on the outline: the same column, on History; each item's check is its own pane's.
        let width = wc.columnView?.frame.width ?? 0
        wc.showHistory(nil)
        XCTAssertTrue(wc.validateMenuItem(side) && wc.validateMenuItem(history))
        XCTAssertEqual(side.state, .off)
        XCTAssertEqual(history.state, .on)
        XCTAssertEqual(doc.session.columnPane, .history)
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, width, accuracy: 0.5)
        // ⌃⌘H again, as ⌃⌘O is: hides it.
        wc.showHistory(nil)
        XCTAssertFalse(doc.session.columnShown)
        XCTAssertNil(wc.sideColumn)
        XCTAssertTrue(wc.validateMenuItem(history))
        XCTAssertEqual(history.state, .off)
        // Hidden, ⌃⌘H shows the column on History; ⌃⌘O then switches it to the outline (the owner's third round:
        // it used to hide the column, which left no key back to the outline), and ⌃⌘O once more hides it.
        wc.showHistory(nil)
        XCTAssertTrue(doc.session.historyShown)
        wc.toggleSideColumn(nil)
        XCTAssertTrue(doc.session.outlineShown, "⌃⌘O with History showing switches to the outline")
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, width, accuracy: 0.5)
        wc.toggleSideColumn(nil)
        XCTAssertFalse(doc.session.columnShown)
        wc.toggleSideColumn(nil)
        XCTAssertTrue(doc.session.outlineShown, "hidden, ⌃⌘O shows the outline")
    }

    /// Found in the M8f test pass: ⌃⌘H (and every menu path) wrote the pane into the settings, so one press changed what
    /// "Side column starts on" says for every window opened later. Only a click on a segment is a new default.
    func testOnlyASegmentClickChangesTheDefaultPaneNotTheMenus() throws {
        let settings = isolatedSettings()
        settings.sideColumnPane = .outline
        let (doc, wc) = try open(settings: settings)
        wc.showHistory(nil)
        XCTAssertTrue(doc.session.historyShown)
        XCTAssertEqual(settings.sideColumnPane, .outline, "⌃⌘H leaves the setting alone")
        wc.showHistory(nil)
        wc.showHistory(nil)
        XCTAssertTrue(doc.session.historyShown, "this window remembers its own pane")
        doc.session.setOutlineShown(true)
        settings.sideColumnPane = .history
        doc.session.setHistoryShown(true)
        doc.session.setOutlineShown(true)
        XCTAssertEqual(settings.sideColumnPane, .history, "nor do the other menu paths")
        let header = try XCTUnwrap(wc.sideColumn?.view.header)
        header.selectedSegment = 1
        _ = NSApp.sendAction(try XCTUnwrap(header.action), to: header.target, from: header)
        header.selectedSegment = 0
        _ = NSApp.sendAction(try XCTUnwrap(header.action), to: header.target, from: header)
        XCTAssertEqual(settings.sideColumnPane, .outline, "a click on a segment does")
    }

    /// Found in the M8f test pass: the divider let the column go to 160 points while the setting (and so a new window)
    /// keeps 200 at least; the column now stops where the setting does, and the window's width never squeezes it.
    func testTheDividerStopsWhereTheSettingDoes() throws {
        let settings = isolatedSettings()
        let (doc, wc) = try open(settings: settings, column: true)
        let host = try XCTUnwrap(wc.paneHost)
        let w = host.bounds.width
        let minPos = wc.splitView(host, constrainMinCoordinate: 0, ofSubviewAt: 0)
        let maxPos = wc.splitView(host, constrainMaxCoordinate: w, ofSubviewAt: 0)
        XCTAssertEqual(w - 1 - maxPos, CGFloat(Settings.sideColumnWidthRange.lowerBound), accuracy: 0.5, "the narrowest column")
        XCTAssertEqual(w - 1 - minPos, CGFloat(Settings.sideColumnWidthRange.upperBound), accuracy: 0.5, "the widest")
        host.setPosition(w - 150, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(wc.columnView).frame.width, 199.5)
        doc.session.columnWidth = 150
        doc.session.setColumnShown(false)
        doc.session.setColumnShown(true)
        XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, 200, accuracy: 1, "a width below the least is the least")
    }

    /// The three columns and the title at the window's narrowest: the editor's pane keeps its least width, the title sits
    /// over it, the column keeps its width, whichever pane shows, and switching changes none of it.
    func testThreeColumnsAndTheTitleAtTheNarrowestWindow() throws {
        let (doc, wc) = try open(column: true)
        let ws = Workspace(library: LibraryController(), settings: wc.session.settings, notesMode: true)
        wc.adopt(ws)
        defer { wc.leaveWorkspace() }
        let window = try XCTUnwrap(wc.window)
        window.setContentSize(NSSize(width: window.minSize.width, height: 600))
        window.layoutIfNeeded()
        pump()
        XCTAssertEqual(window.frame.width, window.minSize.width, accuracy: 1)
        for pane in [SideColumnPane.history, .outline, .history] {
            doc.session.selectColumnPane(pane)
            window.layoutIfNeeded()
            pump()
            let column = try XCTUnwrap(wc.columnView)
            XCTAssertEqual(column.frame.width, 260, accuracy: 1, "\(pane)")
            XCTAssertGreaterThanOrEqual(wc.root.frame.width, wc.baseMinWidth - 0.5, "\(pane): the editor's pane keeps its least width")
            let sidebarRight = try XCTUnwrap(wc.sidebar?.view).convert(wc.sidebar!.view.bounds, to: nil).maxX
            wc.titleView.layoutSubtreeIfNeeded()
            let title = wc.titleView.convert(wc.titleView.titleFrame, to: nil)
            XCTAssertGreaterThanOrEqual(title.minX, sidebarRight, "\(pane)")
            XCTAssertLessThanOrEqual(title.maxX, try XCTUnwrap(wc.columnLeft), "\(pane)")
            XCTAssertLessThanOrEqual(window.frame.width, window.minSize.width + 1, "\(pane): the window did not grow")
        }
    }

    /// Someone who had the outline on by default in M8d opens a window after the update: the column is there, on the
    /// outline, at the outline's old width; once they change the new setting the old one no longer counts.
    func testTheOldOutlineSettingsOpenTheFirstWindowAsTheyDid() throws {
        let suite = "sidecolumn-migrate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "outlineByDefault")
        defaults.set(300, forKey: "outlineWidth")   // an integer, as `defaults write -int` leaves it
        defaults.set(340.0, forKey: "historyWidth")
        let settings = Settings(defaults: defaults)
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(Self.sample.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        docs.append(doc)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: 1100, height: 700))
        wc.window?.layoutIfNeeded()
        XCTAssertTrue(doc.session.outlineShown)
        XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, 300, accuracy: 1)
        settings.showSideColumnInNewWindows = false
        XCTAssertFalse(Settings(defaults: defaults).showSideColumnInNewWindows, "the new setting, once set, is the one")
    }

    func testShowHistoryIsOffForADocumentWithNoFileOfItsOwn() throws {
        let (_, bundled) = try open(bundled: true)
        XCTAssertFalse(bundled.validateMenuItem(try menuItem("Show History")), "a help page has no history")
        XCTAssertTrue(bundled.validateMenuItem(try menuItem("Show Outline")), "the column's outline is for any document")
    }

    // MARK: the title over the pane, whichever pane

    func testTheTitleEndsAtTheColumnsEdgeWhicheverPaneShows() throws {
        let (doc, wc) = try open(column: true)
        func titleEnd() throws -> (title: CGFloat, column: CGFloat) {
            wc.window?.layoutIfNeeded()
            wc.titleView.layoutSubtreeIfNeeded()
            return (wc.titleView.convert(wc.titleView.titleFrame, to: nil).maxX, try XCTUnwrap(wc.columnLeft))
        }
        for pane in [SideColumnPane.outline, .history, .outline] {
            doc.session.selectColumnPane(pane)
            let e = try titleEnd()
            XCTAssertLessThanOrEqual(e.title, e.column + 0.5, "\(pane)")
            let titleView = wc.titleView.convert(wc.titleView.bounds, to: nil)
            XCTAssertEqual(titleView.maxX, e.column, accuracy: 1.5, "\(pane): the title's row ends where the column starts")
        }
    }

    // MARK: the settings

    func testTheSettingsHoldThePaneAndTheWidthAndMigrateTheOutlinesOwn() throws {
        let suite = "sidecolumn-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = Settings(defaults: defaults)
        XCTAssertFalse(fresh.showSideColumnInNewWindows)
        XCTAssertEqual(fresh.sideColumnPane, .outline)
        XCTAssertEqual(fresh.sideColumnWidth, 260)
        // The old outline settings are the start of the new ones, once.
        defaults.set(true, forKey: "outlineByDefault")
        defaults.set(310.0, forKey: "outlineWidth")
        let migrated = Settings(defaults: defaults)
        XCTAssertTrue(migrated.showSideColumnInNewWindows, "an outline on by default stays on")
        XCTAssertEqual(migrated.sideColumnWidth, 310, "the width the outline had")
        defaults.set(120.0, forKey: "outlineWidth")
        XCTAssertEqual(migrated.sideColumnWidth, 200, "clamped to what a column of two panes needs")
        migrated.sideColumnWidth = 350
        XCTAssertEqual(migrated.sideColumnWidth, 350, "the new setting wins over the old")
        migrated.showSideColumnInNewWindows = false
        XCTAssertFalse(migrated.showSideColumnInNewWindows)
        migrated.sideColumnPane = .history
        XCTAssertEqual(Settings(defaults: defaults).sideColumnPane, .history)
        migrated.sideColumnWidth = 9_999
        XCTAssertEqual(migrated.sideColumnWidth, 480)
        migrated.sideColumnWidth = 1
        XCTAssertEqual(migrated.sideColumnWidth, 200)
    }

    func testANewWindowFollowsTheSettingsAndASwapKeepsTheColumnAsItWas() throws {
        let settings = isolatedSettings()
        settings.sideColumnPane = .history
        let (doc, wc) = try open(settings: settings, column: true)
        XCTAssertTrue(doc.session.historyShown, "the default segment")
        XCTAssertNotNil(wc.history)
        // A document replacing this one in its window (see `takeOver`) shows the column as it was, pane and width.
        doc.session.columnWidth = 333
        wc.session.selectColumnPane(.history)
        let next = MarkdownDocument(settings: settings)
        try next.read(from: Data("# Next\n".utf8), ofType: "net.daringfireball.markdown")
        next.makeWindowControllers()
        docs.append(next)
        let nwc = try XCTUnwrap(next.windowControllers.first as? EditorWindowController)
        settings.showSideColumnInNewWindows = false
        nwc.takeOver(from: wc)
        XCTAssertTrue(next.session.historyShown)
        XCTAssertEqual(next.session.columnWidth, 333)
        XCTAssertNotNil(nwc.history)
    }
}
