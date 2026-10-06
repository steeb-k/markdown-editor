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

    // MARK: from the M8f test pass

    /// At the window's narrowest, with every combination of sidebar and column, every layout, the chrome shown and faded,
    /// a long name, an RTL name and one with emoji, edited and not: the title stays inside its pane (never over the sidebar
    /// or the column, never under the window buttons), centred, and never wider than its room.
    func testAtTheNarrowestWindowTheTitleStaysInsideItsPaneWhateverItSays() throws {
        let names = [String(repeating: "a very long file name ", count: 10) + ".md",
                     "\u{645}\u{644}\u{627}\u{62D}\u{638}\u{627}\u{62A} \u{627}\u{644}\u{627}\u{62C}\u{62A}\u{645}\u{627}\u{639} \u{627}\u{644}\u{623}\u{633}\u{628}\u{648}\u{639}\u{64A}\u{629}.md",
                     "\u{1F4DD} Notes \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1EB}\u{1F1F7} plan.md"]
        for name in names {
            let (_, wc) = try open(file: name)
            let window = try XCTUnwrap(wc.window)
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            for (sidebar, column) in [(false, false), (false, true), (true, false), (true, true)] {
                if column != wc.session.columnShown { setColumn(wc, column) }
                if sidebar, wc.sidebar == nil { addSidebar(wc) }
                if !sidebar, wc.sidebar != nil { wc.leaveWorkspace() }
                window.setContentSize(NSSize(width: window.minSize.width, height: 600))
                window.layoutIfNeeded()
                XCTAssertEqual(window.frame.width, window.minSize.width, accuracy: 1)
                for layout in [LayoutMode.editor, .split, .preview] {
                    wc.session.setLayout(layout)
                    for edited in [false, true] {
                        wc.titleView.edited = edited
                        for faded in [false, true] {
                            wc.chromeController.fadeDuration = 0
                            wc.chromeController.send(faded ? .typingStarted : .pointerMoved)
                            pump(0.02)
                            let what = "\(name.prefix(12)) sidebar \(sidebar) column \(column) \(layout) edited \(edited) faded \(faded)"
                            try assertCentred(wc, what)
                            let tv = wc.titleView
                            XCTAssertLessThanOrEqual(tv.parts.total, tv.availableWidth + 0.5, what)
                            let g = try geometry(wc)
                            if !sidebar {
                                XCTAssertGreaterThanOrEqual(g.title.minX, zoom.convert(zoom.bounds, to: nil).maxX, "\(what): clear of the window buttons")
                            }
                            // Every part drawn inside the title's frame: the name and "Edited".
                            for field in tv.subviews where !field.isHidden && field.frame.width > 0 {
                                let f = tv.convert(field.frame, to: nil)
                                XCTAssertGreaterThanOrEqual(f.minX, g.pane.lowerBound - 0.5, what)
                                XCTAssertLessThanOrEqual(f.maxX, g.pane.upperBound + 0.5, what)
                            }
                            if edited { XCTAssertGreaterThan(tv.parts.status, 20, "\(what): Edited is there in full") }
                        }
                    }
                }
            }
            wc.leaveWorkspace()
        }
    }

    /// The title's own arithmetic, at every width down to nothing: never wider than its room, the name cut first and then
    /// "Edited", and never drawn outside its row.
    func testARowNarrowerThanItsTitleCutsTheNameThenEditedAndNeverDrawsOutside() throws {
        let tv = TitlebarTitleView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        tv.name = "A title of some length.md"
        for edited in [false, true] {
            tv.edited = edited
            for width in stride(from: CGFloat(0), through: 400, by: 7) {
                tv.setFrameSize(NSSize(width: width, height: 28))
                tv.layoutSubtreeIfNeeded()
                let p = tv.parts
                XCTAssertLessThanOrEqual(p.total, tv.availableWidth + 0.01, "width \(width), edited \(edited)")
                XCTAssertGreaterThanOrEqual(p.name, 0)
                XCTAssertGreaterThanOrEqual(p.status, 0)
                if edited, p.name > 0 { XCTAssertEqual(p.status, TitlebarTitleView.width(of: NSTextField(labelWithString: TitlebarTitleView.statusText)), accuracy: 6, "the name goes first") }
                for v in tv.subviews where !v.isHidden && v.frame.width > 0 {
                    XCTAssertGreaterThanOrEqual(v.frame.minX, TitlebarTitleView.sideMargin - 0.5, "width \(width)")
                    XCTAssertLessThanOrEqual(v.frame.maxX, width - TitlebarTitleView.sideMargin + 0.5, "width \(width)")
                }
            }
        }
        XCTAssertTrue(tv.clipsToBounds, "nothing of it is drawn outside its row")
    }

    /// Full screen (and any window with no title-bar row): the row is gone, and so is the title (AppKit's own title bar
    /// comes down over the content there; ours, in a row of no height, would draw over the text).
    func testWithNoTitleBarRowThereIsNoTitle() throws {
        let (_, wc) = try open(file: "Bare.md")
        let window = try XCTUnwrap(wc.window)
        XCTAssertFalse(wc.titleView.isHidden)
        let mask = window.styleMask
        window.styleMask = [.borderless, .resizable]
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame.height - window.contentLayoutRect.height, 0, accuracy: 0.5)
        XCTAssertTrue(wc.titleView.isHidden, "no row, no title")
        XCTAssertEqual(wc.titleView.frame.height, 0, accuracy: 0.5)
        window.styleMask = mask
        wc.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        window.layoutIfNeeded()
        XCTAssertFalse(wc.titleView.isHidden, "and back with it")
        try assertCentred(wc, "after the row came back")
    }

    /// ⌘-click: the folders, named as the Finder names them, ending at the file's volume (the startup disk by its name, not
    /// "/"); a file nested deep has every one of them, nearest first.
    func testThePathMenuNamesTheFoldersAsTheFinderDoesAndEndsAtTheVolume() throws {
        let (doc, wc) = try open(file: "Deep.md")
        let base = try XCTUnwrap(doc.fileURL?.deletingLastPathComponent())
        let nested = base.appendingPathComponent("one/two words/thrée", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("Deep.md")
        try Data("# Deep\n".utf8).write(to: file)
        doc.fileURL = file
        wc.synchronizeWindowTitleWithDocumentName()
        let menu = try XCTUnwrap(wc.titleView.pathMenu())
        let titles = menu.items.map(\.title)
        XCTAssertEqual(Array(titles.prefix(4)), ["thrée", "two words", "one", base.lastPathComponent])
        let last = try XCTUnwrap(menu.items.last?.representedObject as? URL)
        XCTAssertEqual((try last.resourceValues(forKeys: [.isVolumeKey])).isVolume, true, "it ends at the volume")
        XCTAssertEqual(menu.items.last?.title, FileManager.default.displayName(atPath: "/"), "named as the Finder names it")
        XCTAssertNotEqual(menu.items.last?.title, "/")
        XCTAssertEqual(menu.items.compactMap { $0.representedObject as? URL }.count, menu.items.count)
        // A volume other than the startup disk ends at itself, not at /Volumes and /.
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") }
        for volume in volumes.prefix(1) {
            let folders = TitlebarTitleView.enclosingFolders(of: volume.appendingPathComponent("some/where/file.md"))
            XCTAssertEqual(folders.last?.standardizedFileURL.path, volume.standardizedFileURL.path, "\(volume.path)")
            XCTAssertFalse(folders.contains { $0.path == "/Volumes" || $0.path == "/" })
        }
    }

    /// A double-click on the name renames (and does not zoom); on the blank part of the row it does what the system's
    /// title bar setting says, not rename.
    func testADoubleClickOnTheNameRenamesAndDoesNotZoom() throws {
        let (_, wc) = try open(file: "Rename.md")
        let window = try XCTUnwrap(wc.window)
        let tv = wc.titleView
        tv.layoutSubtreeIfNeeded()
        var renames = 0
        tv.onRename = { renames += 1 }
        let frame = window.frame
        func doubleClick(at p: NSPoint) throws {
            let inWindow = tv.convert(p, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            tv.mouseDown(with: event)
            pump(0.3)
        }
        try doubleClick(at: NSPoint(x: tv.titleFrame.midX, y: tv.titleFrame.midY))
        XCTAssertEqual(renames, 1, "the name renames")
        XCTAssertEqual(window.frame, frame, "and does not zoom")
        // Faded, the same place is the row's: no rename.
        wc.chromeController.fadeDuration = 0
        wc.chromeController.send(.typingStarted)
        pump(0.05)
        try doubleClick(at: NSPoint(x: tv.titleFrame.midX, y: tv.titleFrame.midY))
        XCTAssertEqual(renames, 1, "faded: not renamed")
        wc.chromeController.send(.pointerMoved)
        pump(0.05)
        try doubleClick(at: NSPoint(x: tv.bounds.maxX - 20, y: tv.bounds.midY))
        XCTAssertEqual(renames, 1, "beside the name: the row's, not a rename")
    }

    /// Found in the M8f test pass: the double-click called `NSDocument.rename`, whose popover anchors to AppKit's own title
    /// views, hidden while the app draws its title: nothing came up at all (a real double-click in `titlebar.json`). The
    /// title has its own popover now: the name in a field under the title, Return renames the file, Escape leaves it.
    func testADoubleClickOnTheNameOpensARenamePopoverThatRenamesTheFile() throws {
        let (doc, wc) = try open(file: "Before.md")
        let folder = try XCTUnwrap(doc.fileURL?.deletingLastPathComponent())
        wc.showRename()
        let r = try XCTUnwrap(wc.renamer)
        XCTAssertTrue(r.popover.isShown, "the popover is up")
        XCTAssertEqual(r.field.stringValue, "Before.md")
        XCTAssertEqual(r.field.currentEditor()?.selectedRange, NSRange(location: 0, length: 6), "the name without .md selected")
        let popoverWindow = try XCTUnwrap(r.popover.contentViewController?.view.window)
        let title = wc.titleView.convert(wc.titleView.titleFrame, to: nil)
        let titleOnScreen = try XCTUnwrap(wc.window).convertToScreen(title)
        XCTAssertLessThanOrEqual(popoverWindow.frame.maxY, titleOnScreen.minY + 1, "under the title")
        XCTAssertTrue(popoverWindow.frame.minX < titleOnScreen.maxX && popoverWindow.frame.maxX > titleOnScreen.minX, "by it")
        wc.showRename()
        XCTAssertTrue(wc.renamer === r, "one at a time")
        // Escape: nothing renamed.
        _ = r.control(r.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        pump(0.3)
        XCTAssertNil(wc.renamer)
        XCTAssertEqual(doc.fileURL?.lastPathComponent, "Before.md")
        // Return with a new name (no extension typed: the old one is kept).
        wc.showRename()
        let r2 = try XCTUnwrap(wc.renamer)
        r2.field.stringValue = "After"
        _ = r2.control(r2.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(spin(timeout: 5) { doc.fileURL?.lastPathComponent == "After.md" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("After.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Before.md").path))
        XCTAssertTrue(spin(timeout: 2) { wc.titleView.name == "After.md" && wc.window?.title == "After.md" })
        // A name already taken: nothing moves.
        try Data("x".utf8).write(to: folder.appendingPathComponent("Taken.md"))
        wc.rename(doc, from: try XCTUnwrap(doc.fileURL), to: "Taken.md")
        pump(0.3)
        XCTAssertEqual(doc.fileURL?.lastPathComponent, "After.md")
        if let sheet = wc.window?.attachedSheet { wc.window?.endSheet(sheet) }
        // Names that cannot be a file's.
        let url = URL(fileURLWithPath: "/tmp/a/Note.md")
        XCTAssertNil(TitleRenamer.destination(for: url, typed: "  "))
        XCTAssertNil(TitleRenamer.destination(for: url, typed: "a/b"))
        XCTAssertNil(TitleRenamer.destination(for: url, typed: ".hidden"))
        XCTAssertEqual(TitleRenamer.destination(for: url, typed: "New.txt")?.lastPathComponent, "New.txt")
        XCTAssertEqual(TitleRenamer.destination(for: url, typed: " Été ")?.path, "/tmp/a/Été.md")
        // An untitled document has nothing to rename.
        let (_, untitled) = try open()
        untitled.showRename()
        XCTAssertNil(untitled.renamer)
    }

    /// Nothing of the title outlives its window.
    func testTheTitleViewIsFreedWithItsWindow() throws {
        weak var weakTitle: TitlebarTitleView?
        weak var weakController: EditorWindowController?
        try autoreleasepool {
            let (doc, wc) = try open(file: "Gone.md")
            addSidebar(wc)
            setColumn(wc, true)
            weakTitle = wc.titleView
            weakController = wc
            wc.leaveWorkspace()
            doc.updateChangeCount(.changeCleared)
            // No fade-out: AppKit holds a closing window until the fade has run, which takes a display that is being
            // drawn (with the screen locked it never ends). What is alive afterwards is what this app holds.
            wc.window?.animationBehavior = .none
            doc.close()
            docs.removeAll { $0 === doc }
        }
        XCTAssertTrue(spin(timeout: 5) { weakTitle == nil && weakController == nil }, "the title view and its controller are freed")
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
