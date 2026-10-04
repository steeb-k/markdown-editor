import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// M8f: the title is the app's own, centred over the editor's pane (from the sidebar's right edge to the right column's
/// left edge), not AppKit's, which centres it in the whole window and ran it across the sidebar's edge.
@MainActor
final class TitleViewTests: XCTestCase {
    private var docs: [MarkdownDocument] = []
    private var folders: [URL] = []

    override func tearDown() {
        for d in docs { d.updateChangeCount(.changeCleared); d.close() }
        docs = []
        for f in folders { try? FileManager.default.removeItem(at: f) }
        folders = []
        super.tearDown()
    }

    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    private func open(_ text: String = "# Title\n\nSome words here.\n", file: String? = nil, width: CGFloat = 1000) throws -> (MarkdownDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        if let file {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("title-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folders.append(folder)
            let url = folder.appendingPathComponent(file)
            try Data(text.utf8).write(to: url)
            doc.fileURL = url
        }
        doc.makeWindowControllers()
        docs.append(doc)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: width, height: 700))
        wc.window?.layoutIfNeeded()
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    private func addSidebar(_ wc: EditorWindowController) {
        let ws = Workspace(library: LibraryController(), settings: wc.session.settings, notesMode: true)
        wc.adopt(ws)
        wc.window?.layoutIfNeeded()
    }

    private func setColumn(_ wc: EditorWindowController, _ on: Bool) {
        if wc.session.columnShown != on { wc.toggleSideColumn(nil) }
        wc.window?.layoutIfNeeded()
        pump(0.05)
    }

    /// The pane's range and the title's frame, both as x in the window.
    private func geometry(_ wc: EditorWindowController) throws -> (pane: ClosedRange<CGFloat>, title: NSRect) {
        let window = try XCTUnwrap(wc.window)
        window.contentView?.layoutSubtreeIfNeeded()
        wc.titleView.layoutSubtreeIfNeeded()
        var left: CGFloat = 0
        var right = window.contentView?.bounds.width ?? 0
        if let bar = wc.sidebar?.view { left = bar.convert(bar.bounds, to: nil).maxX }
        if let l = wc.columnLeft { right = l }
        return (left...right, wc.titleView.convert(wc.titleView.titleFrame, to: nil))
    }

    private func assertCentred(_ wc: EditorWindowController, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let g = try geometry(wc)
        XCTAssertGreaterThanOrEqual(g.title.minX, g.pane.lowerBound - 0.5, "\(what): starts inside the pane", file: file, line: line)
        XCTAssertLessThanOrEqual(g.title.maxX, g.pane.upperBound + 0.5, "\(what): ends inside the pane", file: file, line: line)
        XCTAssertEqual(g.title.midX, (g.pane.lowerBound + g.pane.upperBound) / 2, accuracy: 1.5, "\(what): centred over the pane \(g.pane)", file: file, line: line)
        let window = try XCTUnwrap(wc.window)
        let bar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThanOrEqual(g.title.minY, window.frame.height - bar - 0.5, "\(what): in the title bar's row", file: file, line: line)
        XCTAssertEqual(wc.titleView.frame.height, bar, accuracy: 0.5, file: file, line: line)
    }

    func testTheTitleIsCentredOverTheEditorsPaneInEveryLayoutAndConfiguration() throws {
        let (_, wc) = try open(file: "Showcase.md")
        for layout in [LayoutMode.editor, .split, .preview] {
            wc.session.setLayout(layout)
            for (sidebar, column) in [(false, false), (false, true), (true, false), (true, true)] {
                if column != wc.session.outlineShown { setColumn(wc, column) }
                if sidebar, wc.sidebar == nil { addSidebar(wc) }
                if !sidebar, wc.sidebar != nil { wc.leaveWorkspace() }
                wc.window?.layoutIfNeeded()
                let what = "\(layout), sidebar \(sidebar), column \(column)"
                try assertCentred(wc, what)
                XCTAssertEqual(wc.titleView.name, "Showcase.md", what)
                XCTAssertFalse(wc.titleView.isHidden)
            }
        }
    }

    func testTheTitleOverTheSidebarIsNotThereAndThePaneStartsAtTheSidebarsEdge() throws {
        let (_, wc) = try open(file: "Notes.md")
        addSidebar(wc)
        let g = try geometry(wc)
        let sidebarRight = try XCTUnwrap(wc.sidebar).view.convert(wc.sidebar!.view.bounds, to: nil).maxX
        XCTAssertGreaterThan(sidebarRight, 100)
        XCTAssertGreaterThanOrEqual(g.title.minX, sidebarRight, "the title does not run over the sidebar")
        XCTAssertEqual(wc.titleView.convert(wc.titleView.bounds, to: nil).minX, sidebarRight, accuracy: 1.5, "the title's row is the pane's")
    }

    func testTheTitleFollowsTheSidebarsWidthTheColumnAndTheWindow() throws {
        let (_, wc) = try open(file: "Follow.md", width: 1300)
        addSidebar(wc)
        setColumn(wc, true)
        let window = try XCTUnwrap(wc.window)
        let before = try geometry(wc)
        // The sidebar's divider.
        let ws = try XCTUnwrap(wc.workspace)
        ws.setSidebarWidth(320)
        window.layoutIfNeeded()
        pump(0.05)
        let wider = try geometry(wc)
        XCTAssertGreaterThan(wider.pane.lowerBound, before.pane.lowerBound + 50, "the sidebar grew")
        try assertCentred(wc, "after the sidebar's divider moved")
        XCTAssertGreaterThan(wider.title.minX, before.title.minX, "the title moved with it")
        // The column's divider.
        let host = try XCTUnwrap(wc.paneHost)
        host.setPosition(host.bounds.width - 400, ofDividerAt: 0)
        XCTAssertEqual(try XCTUnwrap(wc.columnView).frame.width, 400, accuracy: 1.5)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        pump(0.05)
        try assertCentred(wc, "after the column's divider moved")
        XCTAssertLessThan(try geometry(wc).title.midX, wider.title.midX, "a wider column moved the title to the left")
        // The window.
        window.setContentSize(NSSize(width: 1500, height: 700))
        window.layoutIfNeeded()
        pump(0.05)
        try assertCentred(wc, "after the window grew")
        // Hiding the column gives the pane its width back.
        setColumn(wc, false)
        try assertCentred(wc, "column hidden")
        XCTAssertEqual(try geometry(wc).pane.upperBound, window.contentView?.bounds.width ?? 0, accuracy: 1.5)
    }

    func testAFadedChromeLeavesTheTitleWhereItIsAndTakesItsAlphaAlong() throws {
        let (_, wc) = try open(file: "Fade.md")
        addSidebar(wc)
        setColumn(wc, true)
        let before = try geometry(wc)
        wc.chromeController.fadeDuration = 0
        wc.chromeController.send(.typingStarted)
        pump(0.1)
        XCTAssertFalse(wc.chromeVisible)
        XCTAssertEqual(wc.titleView.alphaValue, 0, accuracy: 0.01, "the title fades with the title bar")
        XCTAssertTrue(wc.chromeController.titlebarViews.contains(wc.titleView))
        let faded = try geometry(wc)
        XCTAssertEqual(faded.title, before.title, "nothing moves")
        wc.chromeController.send(.pointerMoved)
        pump(0.1)
        XCTAssertEqual(wc.titleView.alphaValue, 1, accuracy: 0.01)
        try assertCentred(wc, "chrome back")
    }

    func testALongNameIsCutInTheMiddleAndNeverReachesTheWindowButtonsOrThePaneEdges() throws {
        let name = String(repeating: "a long file name ", count: 8) + ".md"
        let (_, wc) = try open(file: name, width: 500)
        let tv = wc.titleView
        XCTAssertGreaterThan(tv.fullNameWidth, tv.availableWidth, "it does not fit")
        XCTAssertLessThan(tv.parts.name, tv.fullNameWidth, "the name is shortened")
        XCTAssertLessThanOrEqual(tv.parts.total, tv.availableWidth + 0.5)
        XCTAssertEqual(tv.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == name }?.lineBreakMode, .byTruncatingMiddle)
        try assertCentred(wc, "truncated")
        // Clear of the window buttons (the pane starts under them in a window without a sidebar).
        let zoom = try XCTUnwrap(wc.window?.standardWindowButton(.zoomButton))
        let buttons = zoom.convert(zoom.bounds, to: nil).maxX
        XCTAssertGreaterThanOrEqual(try geometry(wc).title.minX, buttons, "clear of the window buttons")
        // The window's own title is whole, for the Dock and VoiceOver.
        XCTAssertEqual(wc.window?.title, name)
    }

    func testTheWindowKeepsItsTitleAndRepresentedFileForTheSystem() throws {
        let (doc, wc) = try open(file: "System.md")
        let window = try XCTUnwrap(wc.window)
        XCTAssertEqual(window.title, "System.md")
        XCTAssertEqual(window.representedURL?.lastPathComponent, "System.md")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(wc.titleView.name, "System.md")
        XCTAssertEqual(wc.titleView.fileURL, doc.fileURL)
        XCTAssertEqual(wc.titleView.accessibilityLabel(), "System.md")
        XCTAssertEqual(wc.titleView.accessibilityRole(), .staticText)
        // A rename shows in both.
        let folder = try XCTUnwrap(doc.fileURL?.deletingLastPathComponent())
        doc.fileURL = folder.appendingPathComponent("Renamed.md")
        wc.synchronizeWindowTitleWithDocumentName()
        XCTAssertEqual(window.title, "Renamed.md")
        XCTAssertEqual(wc.titleView.name, "Renamed.md")
        XCTAssertTrue(SystemTitle.views(in: window).allSatisfy { $0.isHidden }, "AppKit's own title views stay hidden")
    }

    func testAnUntitledDocumentShowsItsNameWithoutAnIcon() throws {
        let (_, wc) = try open()
        XCTAssertFalse(wc.titleView.name.isEmpty)
        XCTAssertNil(wc.titleView.fileURL)
        XCTAssertTrue(wc.titleView.subviews.allSatisfy { !($0 is NSImageView) })
        try assertCentred(wc, "untitled")
    }

    func testEditedShowsWhileTheDocumentIsEditedAndGoesWithTheAutosave() throws {
        let (doc, wc) = try open(file: "Edit.md")
        MarkdownDocument.autosaveDelay = 0.3
        defer { MarkdownDocument.autosaveDelay = 2 }
        XCTAssertFalse(wc.titleView.edited)
        let width = try geometry(wc).title.width
        wc.textView.setSelectedRange(NSRange(location: 0, length: 0))
        wc.textView.insertText("Typed. ", replacementRange: NSRange(location: 0, length: 0))
        pump(0.05)
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertTrue(wc.titleView.edited, "the title says Edited at the keystroke")
        XCTAssertGreaterThan(try geometry(wc).title.width, width + 20, "and makes room for it")
        try assertCentred(wc, "edited")
        XCTAssertTrue(spin(timeout: 10) { !doc.isDocumentEdited && !wc.titleView.edited }, "gone when the autosave has written it")
        XCTAssertEqual(try geometry(wc).title.width, width, accuracy: 0.5)
        XCTAssertTrue(SystemTitle.views(in: try XCTUnwrap(wc.window)).allSatisfy { $0.isHidden })
    }

    func testThereIsNoDocumentIconAndACommandClickShowsThePathWhileTheWindowKeepsTheFile() throws {
        let (doc, wc) = try open(file: "Path.md")
        let tv = wc.titleView
        XCTAssertTrue(tv.subviews.allSatisfy { !($0 is NSImageView) }, "no icon beside the name")
        XCTAssertEqual(wc.window?.representedURL, doc.fileURL, "the window still has its file, for the Dock and the system")
        XCTAssertTrue(SystemTitle.views(in: try XCTUnwrap(wc.window)).allSatisfy { $0.isHidden })
        // Command-click: the folders the file is in, nearest first, up to the volume's root.
        let menu = try XCTUnwrap(tv.pathMenu())
        let folder = try XCTUnwrap(doc.fileURL?.deletingLastPathComponent())
        XCTAssertEqual(menu.items.first?.title, folder.lastPathComponent)
        XCTAssertEqual(menu.items.first?.representedObject as? URL, folder)
        XCTAssertEqual(menu.items.last?.representedObject as? URL, URL(fileURLWithPath: "/"))
        XCTAssertGreaterThanOrEqual(menu.items.count, 3)
        var opened: [URL] = []
        TitlebarTitleView.openFolder = { opened.append($0) }
        defer { TitlebarTitleView.openFolder = { NSWorkspace.shared.open($0) } }
        let first = try XCTUnwrap(menu.items.first)
        _ = first.target?.perform(first.action, with: first)
        XCTAssertEqual(opened, [folder], "choosing a folder opens it")
        // No file, no path.
        let (_, untitled) = try open()
        XCTAssertNil(untitled.titleView.pathMenu())
    }

    func testTheRowIsTheWindowsEverywhereAndTheTitleRenamesOnlyWhenItIsThere() throws {
        let (_, wc) = try open(file: "Row.md")
        let tv = wc.titleView
        XCTAssertTrue(tv.hitTest(NSPoint(x: tv.frame.minX + 3, y: tv.frame.midY)) === tv, "the whole row is the title view's")
        XCTAssertNil(tv.hitTest(NSPoint(x: tv.frame.minX + 3, y: tv.frame.minY - 5)), "below the row it is the text's")
        XCTAssertTrue(wc.titleView.canRename(), "a titled document, chrome showing")
        wc.chromeController.fadeDuration = 0
        wc.chromeController.send(.typingStarted)
        pump(0.1)
        XCTAssertFalse(wc.titleView.canRename(), "faded: the title is not there to be double-clicked")
    }
}
