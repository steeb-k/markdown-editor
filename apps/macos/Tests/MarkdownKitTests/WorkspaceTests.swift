import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// What a tab group shares: the library's snapshot, the selection, the filters, the sort, the open
/// folders; and the operations that make notes and folders.
final class WorkspaceTests: XCTestCase {
    private var lib: TempLibrary!
    private var controller: LibraryController!
    private var settings: Settings!
    private var ws: Workspace!

    override func setUpWithError() throws {
        lib = try TempLibrary([
            "Home.md": "# Home\n\nSee [[Alpha]] #index\n",
            "Projects/Alpha.md": "---\ntags: [work, plan]\n---\n# Alpha\n\nabout pineapple\n",
            "Projects/Beta.md": "# Beta\n\n#work notes about pineapple too\n",
            "Templates/Daily.md": "# {{title}}\n\nDate: {{date}}\nToday: {{today}}\n\n{{cursor}}\n",
            "Templates/Meeting.md": "# Meeting {{date}}\n\n{{cursor}}",
            "plain.txt": "text",
        ])
        settings = isolatedSettings()
        controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
        ws = Workspace(library: controller, settings: settings, notesMode: true)
        XCTAssertTrue(waitUntil { !ws.snapshot.roots.isEmpty })
    }

    override func tearDown() { lib.remove() }

    private func settle() {
        XCTAssertTrue(controller.waitUntilIdle())
        ws.requestSnapshot()
        XCTAssertTrue(controller.waitUntilIdle())
    }

    // MARK: state

    func testTheSnapshotArrivesAndEachRootStartsOpen() {
        XCTAssertEqual(ws.snapshot.roots.count, 1)
        XCTAssertEqual(ws.snapshot.noteCount, 6)
        XCTAssertTrue(ws.expanded.contains("lib:"), "a root starts open")
        XCTAssertFalse(ws.expanded.contains("lib:Projects"))
    }

    func testObserversHearWhatChanged() {
        var heard: [Workspace.Change] = []
        let owner = NSObject()
        ws.observe(owner) { heard.append($0) }
        ws.setSelection(["lib:Home.md"])
        ws.setSelection(["lib:Home.md"])
        ws.setExpanded("lib:Projects", true)
        ws.setBacklinksShown(true)
        ws.setSidebarWidth(300)
        ws.setScrollOffset(40)
        ws.setNotesMode(false)
        // (The library may announce changes of its own meanwhile: they are not what is looked at here.)
        let own = heard.filter { $0 != .snapshot && $0 != .backlinks }
        XCTAssertEqual(own, [.selection, .expansion, [.layout, .backlinks], .layout, .scroll, .mode], "a change that changes nothing says nothing")
        XCTAssertEqual(ws.selection, ["lib:Home.md"])
        XCTAssertTrue(ws.expanded.contains("lib:Projects"))
        XCTAssertFalse(ws.notesMode)
        ws.stopObserving(owner)
        let count = heard.count
        ws.setSelection(["lib:Home.md", "lib:Projects"])
        XCTAssertEqual(heard.count, count, "a window that stopped observing is not told")
    }

    func testTheWidthAndTheScrollAreKeptWithinTheirLimits() {
        ws.setSidebarWidth(5000)
        XCTAssertEqual(ws.sidebarWidth, 480)
        XCTAssertEqual(settings.sidebarWidth, 480, "remembered for the next window")
        ws.setSidebarWidth(10)
        XCTAssertEqual(ws.sidebarWidth, 160)
        ws.setScrollOffset(100)
        ws.setScrollOffset(100.2)
        XCTAssertEqual(ws.scrollOffset, 100)
    }

    func testFiltersAreAnAndAndAnswerFromTheLibrary() {
        ws.toggleTag("work")
        XCTAssertTrue(waitUntil { ws.snapshot.query.tags == ["work"] })
        XCTAssertEqual(ws.snapshot.roots[0].notes.map(\.path).sorted(), ["Projects/Alpha.md", "Projects/Beta.md"])
        ws.toggleTag("plan")
        XCTAssertTrue(waitUntil { ws.snapshot.query.tags == ["work", "plan"] })
        XCTAssertEqual(ws.snapshot.roots[0].notes.map(\.path), ["Projects/Alpha.md"])
        ws.toggleTag("work")
        XCTAssertTrue(waitUntil { ws.snapshot.query.tags == ["plan"] })
        ws.clearTags()
        XCTAssertTrue(waitUntil { ws.snapshot.query.tags.isEmpty })
        XCTAssertEqual(ws.snapshot.roots[0].notes.count, 6)
    }

    func testSearchReplacesTheTreeWithHitsAndClearingBringsItBack() {
        ws.setSearch("pineapple")
        XCTAssertTrue(waitUntil { ws.snapshot.query.search == "pineapple" && !ws.snapshot.hits.isEmpty })
        XCTAssertEqual(Set(ws.snapshot.hits.map(\.note.path)), ["Projects/Alpha.md", "Projects/Beta.md"])
        ws.setSearch("")
        XCTAssertTrue(waitUntil { ws.snapshot.query.search.isEmpty })
        XCTAssertTrue(ws.snapshot.hits.isEmpty)
    }

    func testAnAnswerToAnOlderQuestionIsDropped() {
        ws.setSearch("a")
        ws.setSearch("al")
        ws.setSearch("pineapple")
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(ws.snapshot.query.search, "pineapple")
        XCTAssertEqual(Set(ws.snapshot.hits.map(\.note.path)), ["Projects/Alpha.md", "Projects/Beta.md"])
    }

    func testTheSortIsRememberedAndAsksTheLibraryAgain() {
        ws.setSort(.modified)
        XCTAssertEqual(settings.noteSort, .modified)
        XCTAssertTrue(waitUntil { ws.snapshot.query.sort == .modified })
        ws.setSort(.name)
        XCTAssertTrue(waitUntil { ws.snapshot.query.sort == .name })
        XCTAssertEqual(Workspace(library: controller, settings: settings).sort, .name, "a new workspace starts as the setting says")
    }

    func testRevealOpensTheFoldersToANote() {
        ws.reveal("lib:Projects/Beta.md")
        XCTAssertTrue(ws.expanded.contains("lib:Projects"))
        XCTAssertTrue(ws.expanded.contains("lib:"))
    }

    func testNewNotesAndFoldersGoWhereTheSelectionIs() {
        XCTAssertEqual(ws.destinationFolder()?.id, "lib:", "nothing selected: the library")
        ws.setSelection(["lib:Projects"])
        XCTAssertEqual(ws.destinationFolder()?.id, "lib:Projects")
        ws.setSelection(["lib:Projects/Beta.md"])
        XCTAssertEqual(ws.destinationFolder()?.id, "lib:Projects", "a note: the folder it is in")
        ws.setSelection(["lib:Home.md"])
        XCTAssertEqual(ws.destinationFolder()?.id, "lib:")
    }

    func testAForkStartsAsItsParentWasAndGoesItsOwnWay() {
        ws.setSelection(["lib:Home.md"])
        ws.setExpanded("lib:Projects", true)
        ws.setBacklinksShown(true)
        let copy = ws.fork()
        XCTAssertTrue(copy !== ws)
        XCTAssertEqual(copy.selection, ["lib:Home.md"])
        XCTAssertTrue(copy.expanded.contains("lib:Projects"))
        XCTAssertTrue(copy.backlinksShown)
        XCTAssertTrue(copy.library === ws.library, "the index is the app's")
        copy.setSelection([])
        XCTAssertEqual(ws.selection, ["lib:Home.md"])
    }

    // MARK: roots

    func testRootsAreRememberedAsGrants() throws {
        let other = try TempLibrary(["Other.md": "# Other\n"])
        defer { other.remove() }
        let settings = isolatedSettings()
        let fresh = Workspace(library: LibraryController(), settings: settings, notesMode: true)
        XCTAssertNil(fresh.primaryRoot)
        let first = fresh.addRoot(lib.url)
        XCTAssertEqual(first?.id, LibraryRootInfo.libraryID, "the first folder is the library")
        let second = fresh.addRoot(other.url)
        XCTAssertEqual(second?.id, "folder-2")
        XCTAssertEqual(settings.libraryGrants.map(\.id), ["library", "folder-2"])
        XCTAssertNotNil(settings.libraryGrants[0].bookmark, "remembered as a bookmark")
        XCTAssertEqual(fresh.addRoot(other.url)?.id, "folder-2", "the same folder is one root")
        XCTAssertTrue(fresh.library.waitUntilIdle())
        XCTAssertEqual(fresh.library.roots.map(\.id), ["library", "folder-2"])
        fresh.removeRoot(id: "folder-2")
        XCTAssertTrue(fresh.library.waitUntilIdle())
        XCTAssertEqual(fresh.library.roots.map(\.id), ["library"])
        fresh.setLibraryFolder(other.url)
        XCTAssertTrue(fresh.library.waitUntilIdle())
        XCTAssertEqual(settings.libraryGrants.map(\.id), ["library"])
        XCTAssertEqual(fresh.primaryRoot?.url.path, other.url.path, "the library moved to the chosen folder")
    }

    func testAGrantFindsItsFolder() throws {
        let grant = DocumentFileAccess.makeGrant(id: "x", folder: lib.url)
        XCTAssertEqual(DocumentFileAccess.open(grant).map(DocumentFileAccess.canonical)?.path, lib.url.path)
        let gone = DocumentFileAccess.Grant(id: "y", path: "/nonexistent/folder", bookmark: nil)
        XCTAssertNil(DocumentFileAccess.open(gone))
        let data = try JSONEncoder().encode([grant])
        XCTAssertEqual(try JSONDecoder().decode([DocumentFileAccess.Grant].self, from: data), [grant])
    }

    // MARK: making things

    func testNewNotesAreNumberedAndTheLibrarySeesThem() throws {
        let folder = ws.snapshot.node(withID: "lib:Projects")
        let a = try ws.createNote(in: folder)
        let b = try ws.createNote(in: folder)
        XCTAssertEqual([a, b].map(\.lastPathComponent), ["Untitled.md", "Untitled 2.md"])
        XCTAssertTrue(lib.exists("Projects/Untitled.md") && lib.exists("Projects/Untitled 2.md"))
        settle()
        XCTAssertTrue(ws.snapshot.node(withID: "lib:Projects/Untitled 2.md") != nil)
        XCTAssertEqual(ws.snapshot.noteCount, 8)
        let top = try ws.createNote(base: "Idea")
        XCTAssertEqual(top.deletingLastPathComponent().path, lib.url.path, "no folder selected: the library")
        XCTAssertEqual(lib.read("Idea.md"), "")
    }

    func testFoldersAreNumberedToo() throws {
        let a = try ws.createFolder()
        let b = try ws.createFolder()
        XCTAssertEqual([a, b].map(\.lastPathComponent), ["New Folder", "New Folder 2"])
        settle()
        XCTAssertNotNil(ws.snapshot.node(withID: "lib:New Folder 2"))
    }

    func testDuplicateCopiesTheFile() throws {
        let node = try XCTUnwrap(ws.snapshot.node(withID: "lib:Projects/Beta.md"))
        let copy = try ws.duplicate(node)
        XCTAssertEqual(copy.lastPathComponent, "Beta 2.md")
        XCTAssertEqual(lib.read("Projects/Beta 2.md"), lib.read("Projects/Beta.md"))
        let again = try ws.duplicate(node)
        XCTAssertEqual(again.lastPathComponent, "Beta 3.md")
        let folder = try XCTUnwrap(ws.snapshot.node(withID: "lib:Projects"))
        XCTAssertEqual(try ws.duplicate(folder).lastPathComponent, "Projects 2")
        XCTAssertTrue(lib.exists("Projects 2/Alpha.md"))
    }

    func testANoteFromATemplateHasItsPlaceholdersFilledAndTheCaretMarked() throws {
        let t = try XCTUnwrap(ws.templates().first { $0.lastPathComponent == "Meeting.md" })
        XCTAssertEqual(ws.templates().map(\.lastPathComponent), ["Daily.md", "Meeting.md"])
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let made = try ws.newNote(fromTemplate: t, in: ws.snapshot.node(withID: "lib:Projects"), date: when)
        XCTAssertEqual(made.url.lastPathComponent, "Meeting.md")
        XCTAssertEqual(made.url.deletingLastPathComponent().lastPathComponent, "Projects")
        let text = try XCTUnwrap(lib.read("Projects/Meeting.md"))
        XCTAssertTrue(text.hasPrefix("# Meeting 20"))
        XCTAssertFalse(text.contains("{{"))
        XCTAssertEqual(made.cursor, (text as NSString).length, "the cursor was at the end")
        let second = try ws.newNote(fromTemplate: t, in: ws.snapshot.node(withID: "lib:Projects"), date: when)
        XCTAssertEqual(second.url.lastPathComponent, "Meeting 2.md")
    }

    func testTodaysNoteIsMadeOnceFromTheDailyTemplate() throws {
        let when = Date()
        let first = try ws.todaysNote(date: when)
        let name = DailyNote.name(for: when, format: settings.dailyFormat)
        XCTAssertEqual(first.url.lastPathComponent, "\(name).md")
        XCTAssertEqual(first.url.deletingLastPathComponent().lastPathComponent, "Daily")
        let text = try XCTUnwrap(lib.read("Daily/\(name).md"))
        XCTAssertTrue(text.hasPrefix("# \(name)\n\nDate: "), text)
        XCTAssertNotNil(first.cursor)
        // Written once: a second call finds it, the file is not touched, no caret is asked for.
        try Data("Written today.".utf8).write(to: first.url)
        let again = try ws.todaysNote(date: when)
        XCTAssertEqual(again.url, first.url)
        XCTAssertNil(again.cursor)
        XCTAssertEqual(lib.read("Daily/\(name).md"), "Written today.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lib.url.appendingPathComponent("Daily").path).count, 1)
    }

    func testTodaysNoteWithoutATemplateIsEmptyAndFollowsTheSettings() throws {
        try FileManager.default.removeItem(at: lib.url.appendingPathComponent("Templates/Daily.md"))
        settings.dailyFolder = "Journal/Days"
        settings.dailyFormat = "[Day] YYYY.MM.DD"
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let made = try ws.todaysNote(date: when)
        XCTAssertTrue(made.url.path.contains("/Journal/Days/Day 20"), made.url.path)
        XCTAssertEqual(lib.read("Journal/Days/\(made.url.lastPathComponent)"), "")
        XCTAssertNil(made.cursor)
    }

    func testTheTemplatesFolderIsASetting() throws {
        settings.templatesFolder = "Models"
        XCTAssertEqual(ws.templates(), [])
        try lib.write("Models/Standup.md", "# Standup\n")
        XCTAssertEqual(ws.templates().map(\.lastPathComponent), ["Standup.md"])
    }
}
