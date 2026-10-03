import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The sidebar's rows, the notes-mode window around it, and the menus that drive both.
final class SidebarTests: XCTestCase {
    // MARK: the rows

    private func node(_ path: String, _ kind: LibraryNode.Kind = .note, children: [LibraryNode] = []) -> LibraryNode {
        LibraryNode(kind: kind, root: "lib", path: path,
                    name: kind == .note ? (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "") : (path as NSString).lastPathComponent,
                    url: URL(fileURLWithPath: "/lib/" + path), modified: Date(timeIntervalSince1970: 0), children: children)
    }

    private func snapshot(search: String = "", hits: [SearchHit] = []) -> LibrarySnapshot {
        var s = LibrarySnapshot()
        s.roots = [LibraryNode(kind: .root, root: "lib", path: "", name: "lib", url: URL(fileURLWithPath: "/lib"), modified: .distantPast,
                               children: [node("Sub", .folder, children: [node("Sub/a.md")]), node("b.md"), node("pic.png", .other)])]
        s.tags = [TagCount(tag: "home", count: 2), TagCount(tag: "work", count: 1)]
        s.query = LibraryQuery(search: search)
        s.hits = hits
        s.noteCount = 2
        return s
    }

    private func hit(_ path: String) -> SearchHit {
        SearchHit(note: NoteRef(root: "lib", path: path), title: path, snippet: "x", highlights: [], titleMatch: true, occurrences: 1)
    }

    func testTheRowsAreTheRootsTreesThenTheTags() {
        let items = SidebarModel.items(for: snapshot())
        XCTAssertEqual(items.map(\.id), ["lib:", "tags"])
        let root = items[0]
        XCTAssertEqual(root.children.map(\.title), ["Sub", "b", "pic.png"])
        XCTAssertEqual(root.children[0].children.map(\.id), ["lib:Sub/a.md"])
        XCTAssertEqual(items[1].children.map(\.title), ["#home", "#work"])
        XCTAssertTrue(items[1].isExpandable && root.isExpandable && root.children[0].isExpandable)
        XCTAssertFalse(root.children[1].isExpandable)
        // Notes and folders are selected; tags and the header act on a click; a file that is not a note is listed.
        XCTAssertTrue(root.children[0].isSelectable && root.children[1].isSelectable)
        XCTAssertFalse(items[1].isSelectable || items[1].children[0].isSelectable)
    }

    func testASearchReplacesTheTreeWithItsHits() {
        let items = SidebarModel.items(for: snapshot(search: "x", hits: [hit("b.md"), hit("Sub/a.md")]))
        XCTAssertEqual(items.map(\.id), ["hit:lib:b.md", "hit:lib:Sub/a.md"])
        XCTAssertTrue(items.allSatisfy(\.isSelectable))
        let none = SidebarModel.items(for: snapshot(search: "zzz"))
        XCTAssertEqual(none.map(\.title), ["No results"])
        XCTAssertFalse(none[0].isSelectable)
    }

    func testRowsAreReusedSoTheOutlineKeepsWhatIsOpen() {
        let first = SidebarModel.items(for: snapshot())
        let index = SidebarModel.index(first)
        var changed = snapshot()
        changed.roots[0].children.append(node("c.md"))
        let second = SidebarModel.items(for: changed, reuse: index)
        XCTAssertTrue(second[0] === first[0], "the same object for the same id")
        XCTAssertTrue(second[0].children[0] === first[0].children[0])
        XCTAssertEqual(second[0].children.map(\.title), ["Sub", "b", "pic.png", "c"])
    }

    func testASnapshotThatDrawsTheSameNeedsNoReload() {
        var a = snapshot(), b = snapshot()
        b.generation = 7
        XCTAssertTrue(a.drawsSameAs(b), "a new generation changes nothing that is drawn")
        b.tags.append(TagCount(tag: "new", count: 1))
        XCTAssertFalse(a.drawsSameAs(b))
        a = snapshot()
        b = snapshot()
        b.roots[0].children[1].name = "renamed"
        XCTAssertFalse(a.drawsSameAs(b))
        b = snapshot(search: "q")
        XCTAssertFalse(a.drawsSameAs(b))
    }

    // MARK: a window in notes mode

    private var lib: TempLibrary!
    private var docs: [MarkdownDocument] = []

    override func tearDown() {
        for d in docs { d.updateChangeCount(.changeCleared); d.close() }
        docs = []
        lib?.remove()
        lib = nil
    }

    private func makeWorkspace() throws -> Workspace {
        lib = try TempLibrary(["Home.md": "# Home\n\n#index [[Alpha]]\n", "Projects/Alpha.md": "---\ntags: [work]\n---\n# Alpha\n", "plain.txt": "t"])
        let controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
        let ws = Workspace(library: controller, settings: isolatedSettings(), notesMode: true)
        XCTAssertTrue(waitUntil { !ws.snapshot.roots.isEmpty })
        return ws
    }

    private func makeWindow(_ text: String = "# Hi\n") throws -> (MarkdownDocument, EditorWindowController) {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        docs.append(doc)
        return (doc, wc)
    }

    func testAPlainWindowIsExactlyWhatItWas() throws {
        let (_, wc) = try makeWindow()
        XCTAssertNil(wc.workspace)
        XCTAssertNil(wc.sidebar)
        XCTAssertNil(wc.notesSplit)
        XCTAssertTrue(wc.window?.contentView === wc.root, "the editor's own view is the window's content")
        XCTAssertEqual(wc.window?.minSize.width, wc.baseMinWidth)
    }

    func testNotesModeShowsTheSidebarBesideTheEditorAndLeavingPutsTheWindowBack() throws {
        let ws = try makeWorkspace()
        let (_, wc) = try makeWindow()
        let window = try XCTUnwrap(wc.window)
        let before = window.frame
        wc.adopt(ws)
        let sidebar = try XCTUnwrap(wc.sidebar)
        let split = try XCTUnwrap(wc.notesSplit)
        XCTAssertTrue(window.contentView === wc.notesContainer)
        XCTAssertTrue(split.subviews.first === sidebar.view && split.subviews.last === wc.root)
        XCTAssertEqual(sidebar.view.frame.width, ws.sidebarWidth, accuracy: 0.5)
        XCTAssertEqual(window.minSize.width, wc.baseMinWidth + ws.sidebarWidth + 1, "room for both")
        XCTAssertGreaterThanOrEqual(window.frame.width, window.minSize.width)
        XCTAssertEqual(window.frame.height, before.height)
        XCTAssertEqual(sidebar.visibleRowTitles.first, lib.url.lastPathComponent)
        ws.setNotesMode(false)
        XCTAssertNil(wc.sidebar)
        XCTAssertTrue(window.contentView === wc.root)
        XCTAssertEqual(window.minSize.width, wc.baseMinWidth)
        ws.setNotesMode(true)
        XCTAssertNotNil(wc.sidebar, "turned on again: a sidebar again")
        wc.leaveWorkspace()
    }

    func testTheMenuTogglesNotesModeAndShowsIt() throws {
        let (_, wc) = try makeWindow()
        let item = NSMenuItem(title: "Notes Mode", action: #selector(EditorWindowController.toggleNotesMode(_:)), keyEquivalent: "")
        XCTAssertTrue(wc.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        // The commands that need a library are off in plain mode.
        for sel in [#selector(EditorWindowController.quickOpen(_:)), #selector(EditorWindowController.searchLibrary(_:)), #selector(EditorWindowController.todaysNote(_:)),
                    #selector(EditorWindowController.newFolder(_:)), #selector(EditorWindowController.toggleBacklinks(_:)), #selector(EditorWindowController.chooseTemplate(_:))] {
            XCTAssertFalse(wc.validateMenuItem(NSMenuItem(title: "x", action: sel, keyEquivalent: "")), NSStringFromSelector(sel))
        }
        let new = NSMenuItem(title: "New", action: #selector(EditorWindowController.newDocument(_:)), keyEquivalent: "n")
        XCTAssertTrue(wc.validateMenuItem(new))
        XCTAssertEqual(new.title, "New")
        wc.toggleNotesMode(nil)
        XCTAssertTrue(wc.inNotesMode)
        XCTAssertTrue(wc.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(wc.validateMenuItem(new))
        XCTAssertEqual(new.title, "New Note")
        XCTAssertTrue(wc.validateMenuItem(NSMenuItem(title: "x", action: #selector(EditorWindowController.quickOpen(_:)), keyEquivalent: "")))
        let back = NSMenuItem(title: "Show Backlinks", action: #selector(EditorWindowController.toggleBacklinks(_:)), keyEquivalent: "")
        XCTAssertTrue(wc.validateMenuItem(back))
        XCTAssertEqual(back.title, "Show Backlinks")
        wc.toggleBacklinks(nil)
        XCTAssertTrue(wc.validateMenuItem(back))
        XCTAssertEqual(back.title, "Hide Backlinks")
        XCTAssertTrue(wc.sidebar?.view.showsBacklinks == true)
        wc.toggleNotesMode(nil)
        XCTAssertFalse(wc.inNotesMode)
        wc.leaveWorkspace()
    }

    func testMoveToTrashIsTheSidebarsUnlessTheEditorHasTheKeyboard() throws {
        let ws = try makeWorkspace()
        let (_, wc) = try makeWindow()
        wc.adopt(ws)
        let sidebar = try XCTUnwrap(wc.sidebar)
        ws.setSelection(["lib:Home.md"])
        let trash = NSMenuItem(title: "Move to Trash", action: #selector(EditorWindowController.trashSelection(_:)), keyEquivalent: "\u{8}")
        // With a selection, but the keyboard in the editor: the key stays the editor's (delete to the line start).
        XCTAssertFalse(wc.validateMenuItem(trash))
        wc.window?.makeFirstResponder(sidebar.outline)
        if wc.window?.firstResponder === sidebar.outline { XCTAssertTrue(wc.validateMenuItem(trash)) }
        wc.leaveWorkspace()
    }

    func testTheSidebarFollowsTheWorkspaceInEveryWindowOfAGroup() throws {
        let ws = try makeWorkspace()
        let (_, a) = try makeWindow("# A\n")
        let (_, b) = try makeWindow("# B\n")
        a.adopt(ws)
        b.adopt(ws)
        let sa = try XCTUnwrap(a.sidebar), sb = try XCTUnwrap(b.sidebar)
        XCTAssertEqual(sa.visibleRowTitles, sb.visibleRowTitles)
        ws.setExpanded("lib:Projects", true)
        XCTAssertTrue(sa.visibleRowTitles.contains("Alpha"))
        XCTAssertEqual(sa.visibleRowTitles, sb.visibleRowTitles, "both windows draw the one workspace, hidden or not")
        ws.toggleTag("work")
        XCTAssertTrue(waitUntil { sa.visibleRowTitles == sb.visibleRowTitles && !sa.visibleRowTitles.contains("Home") && sa.visibleRowTitles.contains("Alpha") })
        XCTAssertEqual(sa.visibleRowTitles.filter { !$0.hasPrefix("#") && $0 != "Tags" }, [lib.url.lastPathComponent, "Projects", "Alpha"])
        ws.clearTags()
        XCTAssertTrue(waitUntil { sa.visibleRowTitles.contains("Home") && sb.visibleRowTitles.contains("Home") })
        ws.setSelection(["lib:Home.md"])
        XCTAssertEqual(sa.selectedRowIDs, ["lib:Home.md"])
        XCTAssertEqual(sb.selectedRowIDs, ["lib:Home.md"])
        ws.setSidebarWidth(300)
        XCTAssertEqual(sa.view.frame.width, 300, accuracy: 0.5)
        XCTAssertEqual(sb.view.frame.width, 300, accuracy: 0.5)
        a.leaveWorkspace()
        b.leaveWorkspace()
    }

    func testAClickOnATagFiltersAndOnAFolderOpensIt() throws {
        let ws = try makeWorkspace()
        let (_, wc) = try makeWindow()
        wc.adopt(ws)
        let sb = try XCTUnwrap(wc.sidebar)
        sb.activate(try XCTUnwrap(sb.item(withID: "tag:work")))
        XCTAssertTrue(waitUntil { ws.snapshot.query.tags == ["work"] })
        XCTAssertEqual(ws.selectedTags, ["work"])
        sb.activate(try XCTUnwrap(sb.item(withID: "tag:work")))
        XCTAssertTrue(waitUntil { ws.snapshot.query.tags.isEmpty })
        let projects = try XCTUnwrap(sb.item(withID: "lib:Projects"))
        XCTAssertFalse(sb.outline.isItemExpanded(projects))
        sb.activate(projects)
        XCTAssertTrue(sb.outline.isItemExpanded(projects))
        XCTAssertTrue(ws.expanded.contains("lib:Projects"), "what is opened is the workspace's")
        sb.activate(projects)
        XCTAssertFalse(ws.expanded.contains("lib:Projects"))
        wc.leaveWorkspace()
    }

    func testTheSearchFieldDrivesTheWorkspaceAndEscapeClearsIt() throws {
        let ws = try makeWorkspace()
        let (_, wc) = try makeWindow()
        wc.adopt(ws)
        let sb = try XCTUnwrap(wc.sidebar)
        sb.view.searchField.stringValue = "alpha"
        sb.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sb.view.searchField))
        XCTAssertTrue(waitUntil { !ws.snapshot.hits.isEmpty && sb.visibleRowTitles.first == "Alpha" })
        XCTAssertFalse(sb.visibleRowTitles.contains("Tags"))
        let editor = NSTextView()
        XCTAssertTrue(sb.control(sb.view.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(ws.searchText, "")
        XCTAssertEqual(sb.view.searchField.stringValue, "")
        XCTAssertTrue(waitUntil { sb.visibleRowTitles.contains("Tags") })
        wc.leaveWorkspace()
    }

    func testALoadedSnapshotThatChangesNothingDoesNotReloadTheOutline() throws {
        let ws = try makeWorkspace()
        let (_, wc) = try makeWindow()
        wc.adopt(ws)
        let sb = try XCTUnwrap(wc.sidebar)
        let reloads = sb.reloads
        ws.requestSnapshot()
        XCTAssertTrue(ws.library.waitUntilIdle())
        XCTAssertTrue(waitUntil { sb.skippedReloads > 0 })
        XCTAssertEqual(sb.reloads, reloads, "the same tree is not drawn again")
        wc.leaveWorkspace()
    }

    func testTheEmptyStateInvitesYouToMakeALibrary() throws {
        let (_, wc) = try makeWindow()
        let empty = Workspace(library: LibraryController(), settings: isolatedSettings(), notesMode: true)
        wc.adopt(empty)
        let sb = try XCTUnwrap(wc.sidebar)
        XCTAssertTrue(sb.view.showsEmptyState)
        XCTAssertFalse(sb.view.emptyState.isHidden)
        XCTAssertTrue(sb.view.scroll.isHidden)
        wc.leaveWorkspace()
    }

    func testTheSidebarFollowsTheTheme() throws {
        let ws = try makeWorkspace()
        let (doc, wc) = try makeWindow()
        wc.adopt(ws)
        let sb = try XCTUnwrap(wc.sidebar)
        doc.session.settings.theme = .light
        XCTAssertTrue(waitUntil { sb.view.style.text.hexString == doc.session.appearance.palette.text.hexString })
        let light = sb.view.style.background.hexString
        doc.session.settings.theme = .dark
        XCTAssertTrue(waitUntil { sb.view.style.background.hexString != light })
        XCTAssertEqual(sb.view.style.text.hexString, doc.session.appearance.palette.text.hexString)
        wc.leaveWorkspace()
    }

    func testWindowsMergedIntoAGroupShareItsWorkspaceAndATornOffTabGetsACopy() throws {
        let ws = try makeWorkspace()
        let (_, a) = try makeWindow("# A\n")
        let (_, b) = try makeWindow("# B\n")
        let (_, c) = try makeWindow("# C\n")
        a.adopt(ws)
        let wa = try XCTUnwrap(a.window), wb = try XCTUnwrap(b.window), wc = try XCTUnwrap(c.window)
        wa.addTabbedWindow(wb, ordered: .above)
        XCTAssertTrue(b.workspace === ws, "a window that joins a group in notes mode is in notes mode")
        XCTAssertNotNil(b.sidebar)
        XCTAssertTrue(window(wb, isInGroupOf: wa))
        wa.addTabbedWindow(wc, ordered: .above)
        XCTAssertTrue(c.workspace === ws)
        // A plain group is not given a workspace by a window that has none.
        let (_, d) = try makeWindow("# D\n")
        let (_, e) = try makeWindow("# E\n")
        let wd = try XCTUnwrap(d.window)
        wd.addTabbedWindow(try XCTUnwrap(e.window), ordered: .above)
        XCTAssertNil(d.workspace)
        XCTAssertNil(e.workspace)
        XCTAssertTrue(e.window?.contentView === e.root)
        // Torn off: its own group, its own workspace (a copy), the library the same.
        ws.setSelection(["lib:Home.md"])
        wc.moveTabToNewWindow(nil)
        XCTAssertFalse(window(wc, isInGroupOf: wa))
        XCTAssertNotNil(c.workspace)
        XCTAssertTrue(c.workspace !== ws, "one workspace per group")
        XCTAssertTrue(c.workspace?.library === ws.library)
        XCTAssertEqual(c.workspace?.selection, ["lib:Home.md"])
        XCTAssertTrue(a.workspace === ws && b.workspace === ws)
        c.workspace?.setSelection([])
        XCTAssertEqual(ws.selection, ["lib:Home.md"], "each group its own selection")
        // Merged back, it takes the group's.
        wa.addTabbedWindow(wc, ordered: .above)
        XCTAssertTrue(c.workspace === ws)
        for w in [a, b, c, d, e] { w.leaveWorkspace() }
    }

    /// The title bar's row: the strip is the editor pane's width, never over the sidebar's part of it.
    @MainActor
    func testTheTabStripKeepsToTheEditorPaneWithFifteenTabsAndGetsTheWholeRowBack() throws {
        let ws = try makeWorkspace()
        var windows: [EditorWindowController] = []
        for i in 0..<15 { windows.append(try makeWindow("# Tab \(i)\n").1) }
        let first = try XCTUnwrap(windows.first?.window)
        windows[0].adopt(ws)
        for c in windows.dropFirst() { first.addTabbedWindow(try XCTUnwrap(c.window), ordered: .above) }
        XCTAssertTrue(windows.allSatisfy { $0.workspace === ws })
        XCTAssertEqual(first.tabGroup?.windows.count, 15)
        ws.setSidebarWidth(240)

        func settle(_ c: EditorWindowController) {
            c.tabs.refresh()
            c.tabs.strip.layoutSubtreeIfNeeded()
        }
        func check(pane expected: CGFloat, _ message: String) throws {
            for c in windows {
                settle(c)
                let strip = c.tabs.strip
                XCTAssertTrue(c.tabs.isShown, message)
                let pane = c.root.convert(c.root.bounds, to: nil).minX
                XCTAssertEqual(pane, expected, accuracy: 1, message)
                let visible = strip.visibleTabFrames.filter { !$0.isEmpty }
                XCTAssertFalse(visible.isEmpty, message)
                for f in visible {
                    XCTAssertGreaterThanOrEqual(strip.convert(f, to: nil).minX, pane - 0.5, "\(message): a tab reaches left of the editor pane")
                }
                // Nor is there a tab where the sidebar's title row is, whatever is scrolled out of the clip.
                for x in stride(from: 80.0, to: Double(pane) - 2, by: 8.0) {
                    let local = strip.convert(NSPoint(x: x, y: 10), from: nil)
                    XCTAssertFalse(strip.hitTest(strip.convert(local, to: strip.superview)) is TabView, "\(message): a tab takes a click at x = \(x)")
                }
            }
        }
        try check(pane: 241, "sidebar at 240")
        let stripLeft = windows[0].tabs.strip.convert(NSPoint.zero, to: nil).x
        XCTAssertEqual(windows[0].tabs.strip.leadingInset, 241 - stripLeft, accuracy: 1, "the tabs begin where the editor pane does, wherever AppKit put the strip")
        // The tabs shrank to their least and the strip scrolls, inside the pane.
        XCTAssertEqual(windows[0].tabs.strip.tabWidth, TabStripModel.minimumTabWidth)
        XCTAssertGreaterThan(windows[0].tabs.strip.tabWidth * 15, windows[0].tabs.strip.available)
        // The divider moves: the tabs follow.
        ws.setSidebarWidth(360)
        try check(pane: 361, "sidebar at 360")
        ws.setSidebarWidth(160)
        try check(pane: 161, "sidebar at 160")
        // A window that is wider or narrower: the pane starts where it did.
        var f = first.frame
        f.size.width = 1300
        first.setFrame(f, display: false)
        try check(pane: 161, "a wide window")
        // Out of notes mode: the whole row, as before.
        ws.setNotesMode(false)
        for c in windows {
            settle(c)
            XCTAssertEqual(c.tabs.strip.leadingInset, 0)
            XCTAssertEqual(c.tabs.strip.frame.width, (c.window?.frame.width ?? 0) - TabStripController.leadingClearance - TabStripController.trailingClearance, accuracy: 1)
            XCTAssertTrue(c.window?.contentView === c.root)
            XCTAssertTrue(c.tabs.isShown, "fifteen tabs: shown")
            XCTAssertEqual(c.tabs.strip.available, c.tabs.strip.bounds.width)
        }
        for c in windows { c.leaveWorkspace() }
    }

    @MainActor
    func testALoneTabInNotesModeShowsInTheStripNotTheTitleOverTheSidebar() throws {
        let ws = try makeWorkspace()
        let (_, wc) = try makeWindow("# Alone\n")
        XCTAssertFalse(wc.tabs.isShown, "plain: a lone window has its title")
        XCTAssertEqual(wc.window?.titleVisibility, .visible)
        wc.adopt(ws)
        wc.tabs.refresh()
        XCTAssertTrue(wc.tabs.isShown)
        XCTAssertEqual(wc.window?.titleVisibility, .hidden, "the row above the sidebar is the sidebar's")
        XCTAssertEqual(wc.tabs.strip.entries.count, 1)
        ws.setNotesMode(false)
        wc.tabs.refresh()
        XCTAssertFalse(wc.tabs.isShown)
        XCTAssertEqual(wc.window?.titleVisibility, .visible)
        wc.leaveWorkspace()
    }

    private func window(_ w: NSWindow, isInGroupOf other: NSWindow) -> Bool {
        other.tabGroup?.windows.contains { $0 === w } ?? false
    }

    // MARK: the menus

    func testNoKeyEquivalentIsUsedTwice() {
        var seen: [String: String] = [:]
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items where !item.isSeparatorItem {
                let name = path + " > " + item.title
                if let sub = item.submenu { walk(sub, name) }
                guard !item.keyEquivalent.isEmpty, !item.isAlternate else { continue }
                let key = HelpDocuments.display(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                if let other = seen[key] { XCTFail("\(key) is both \(other) and \(name)") }
                seen[key] = name
            }
        }
        for top in MainMenu.build().items { if let sub = top.submenu { walk(sub, top.title) } }
        let keys = HelpDocuments.shortcuts(of: MainMenu.build())
        XCTAssertEqual(keys["View > Notes Mode"], "⌃⌘L")
        XCTAssertEqual(keys["Library > Quick Open"], "⇧⌘O")
        XCTAssertEqual(keys["Library > Search Library"], "⇧⌘F")
        XCTAssertEqual(keys["File > Today\u{2019}s Note"], "⌃⌘N")
        XCTAssertEqual(keys["File > New from Template > Choose Template"], "⇧⌘N")
        XCTAssertEqual(keys["View > Show Backlinks"], "⌥⌘B")
        XCTAssertEqual(keys["Library > Move to Trash"], "⌘⌫")
        XCTAssertEqual(keys["File > New Folder"], "⌥⌘N")
        XCTAssertEqual(keys["File > New"], "⌘N", "New is still New")
    }

    func testTheTemplateMenuListsTheLibrarysTemplates() throws {
        let (_, wc) = try makeWindow()
        let menu = MainMenu.build()
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let templates = try XCTUnwrap(file.items.first { $0.title == "New from Template" }?.submenu)
        XCTAssertTrue(templates.delegate === TemplateMenuDelegate.shared)
        XCTAssertEqual(templates.items.count, 1)
        _ = wc
    }
}
