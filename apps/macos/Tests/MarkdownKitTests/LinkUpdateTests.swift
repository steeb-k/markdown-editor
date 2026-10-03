import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Renaming and moving notes that others link to, trashing, and what an open document does with the
/// library's edits: through the open session as one undoable change, through file coordination for
/// the rest.
final class LinkUpdateTests: XCTestCase {
    private var lib: TempLibrary!
    private var controller: LibraryController!
    private var ws: Workspace!
    private var docs: [MarkdownDocument] = []
    private var questions: [String] = []

    override func setUpWithError() throws {
        lib = try TempLibrary([
            "Home.md": "See [[Alpha]] and [[Projects/Alpha|the first]].\n",
            "Other.md": "[[Alpha]] twice [[alpha]]\n",
            "Unrelated.md": "[[Beta]] only\n",
            "Projects/Alpha.md": "# Alpha\n\nSelf: [[Alpha]]\n",
            "Projects/Beta.md": "# Beta\n",
            "Archive/Old.md": "# Old\n",
        ])
        controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
        ws = Workspace(library: controller, settings: isolatedSettings(), notesMode: true)
        XCTAssertTrue(waitUntil { !ws.snapshot.roots.isEmpty })
        Workspace.pushDelay = 0.05
        Workspace.pushLimit = 0.2
        questions = []
        WorkspacePrompts.linkUpdateOverride = { [unowned self] q in questions.append(q); return .update }
    }

    override func tearDown() {
        WorkspacePrompts.linkUpdateOverride = nil
        WorkspacePrompts.trashEditedOverride = nil
        DocumentFileAccess.trashObserver = nil
        Workspace.pushDelay = 0.5
        Workspace.pushLimit = 1.0
        for d in docs { d.updateChangeCount(.changeCleared); d.close() }
        docs = []
        lib.remove()
    }

    /// A document open on a file of the library, with its window, wired as notes mode wires it.
    @discardableResult
    private func open(_ path: String) throws -> MarkdownDocument {
        let url = lib.url.appendingPathComponent(path)
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: url, ofType: "net.daringfireball.markdown")
        doc.fileURL = url
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        XCTAssertTrue(doc.session.waitUntilStyled())
        doc.session.onLibraryTextChange = { [weak self, weak doc] in if let doc { self?.ws.documentEdited(doc) } }
        docs.append(doc)
        return doc
    }

    private func move(_ from: String, to: String) -> Result<URL?, Error>? {
        var result: Result<URL?, Error>?
        ws.move(lib.url.appendingPathComponent(from), to: lib.url.appendingPathComponent(to), window: nil) { result = $0 }
        waitUntil { result != nil }
        XCTAssertTrue(controller.waitUntilIdle())
        return result
    }

    // MARK: the applying

    func testLinkEditsGoThroughTheSessionAsOneUndoableChange() {
        let e = Editor(text: "a [[X]] b [[X|label]] c")
        e.select(23)
        func edit(_ a: UInt32, _ b: UInt32) -> LibraryEdit { LibraryEdit(note: NoteRef(root: "r", path: "p"), range: Utf16Range(start: a, end: b), replacement: "Renamed") }
        e.grouped { XCTAssertTrue(e.session.applyLinkEdits([edit(4, 5), edit(12, 13)])) }
        XCTAssertEqual(e.string, "a [[Renamed]] b [[Renamed|label]] c")
        XCTAssertEqual(e.session.textView?.selectedRange().location, e.string.utf16.count, "the caret stays with its text")
        XCTAssertEqual(e.um.undoActionName, "Update Links")
        e.um.undo()
        XCTAssertEqual(e.string, "a [[X]] b [[X|label]] c", "one undo takes back both")
        e.um.redo()
        XCTAssertEqual(e.string, "a [[Renamed]] b [[Renamed|label]] c")
    }

    func testEditsThatDoNotFitLeaveTheTextAlone() {
        let e = Editor(text: "short [[X]]")
        func edit(_ a: UInt32, _ b: UInt32) -> LibraryEdit { LibraryEdit(note: NoteRef(root: "r", path: "p"), range: Utf16Range(start: a, end: b), replacement: "Y") }
        XCTAssertFalse(e.session.applyLinkEdits([edit(8, 99)]))
        XCTAssertFalse(e.session.applyLinkEdits([edit(2, 6), edit(4, 8)]), "overlapping edits")
        XCTAssertFalse(e.session.applyLinkEdits([]))
        XCTAssertEqual(e.string, "short [[X]]")
        XCTAssertEqual(e.um.canUndo, false)
    }

    // MARK: rename

    func testRenamingANoteUpdatesLinksInOpenAndClosedNotes() throws {
        let home = try open("Home.md")
        let alpha = try open("Projects/Alpha.md")
        let result = move("Projects/Alpha.md", to: "Projects/Omega.md")
        XCTAssertEqual(try result?.get(), lib.url.appendingPathComponent("Projects/Omega.md"))
        XCTAssertEqual(questions, ["Update 5 links in 3 notes?"])
        XCTAssertFalse(lib.exists("Projects/Alpha.md"))
        XCTAssertTrue(lib.exists("Projects/Omega.md"))
        // Closed: written through file coordination.
        XCTAssertEqual(lib.read("Other.md"), "[[Omega]] twice [[Omega]]\n")
        XCTAssertEqual(lib.read("Unrelated.md"), "[[Beta]] only\n")
        // Open: the session, one undoable change each, not yet saved.
        XCTAssertEqual(home.session.text, "See [[Omega]] and [[Projects/Omega|the first]].\n")
        XCTAssertEqual(lib.read("Home.md"), "See [[Alpha]] and [[Projects/Alpha|the first]].\n", "an open document is not written behind its back")
        XCTAssertTrue(home.isDocumentEdited)
        XCTAssertEqual(home.undoManager?.undoActionName, "Update Links")
        home.undoManager?.undo()
        XCTAssertEqual(home.session.text, "See [[Alpha]] and [[Projects/Alpha|the first]].\n")
        home.undoManager?.redo()
        XCTAssertEqual(home.session.text, "See [[Omega]] and [[Projects/Omega|the first]].\n")
        // The renamed note itself: its own link, in its window, and its document followed the file.
        XCTAssertEqual(alpha.session.text, "# Alpha\n\nSelf: [[Omega]]\n")
        XCTAssertEqual(alpha.undoManager?.undoActionName, "Update Links")
        // (The document hears of the move from its file presenter, a moment later.)
        XCTAssertTrue(waitUntil { alpha.fileURL.map(DocumentFileAccess.canonical)?.lastPathComponent == "Omega.md" })
    }

    func testTheLibraryFollowsTheRenameAndTheEditedText() throws {
        try open("Home.md")
        _ = move("Projects/Alpha.md", to: "Projects/Omega.md")
        // The edited document's text reaches the library without a save.
        XCTAssertTrue(waitUntil { controller.waitUntilIdle(); return backlinkSources("Projects/Omega.md").contains("Home.md") })
        XCTAssertEqual(Set(backlinkSources("Projects/Omega.md")), ["Home.md", "Other.md"])
    }

    private func backlinkSources(_ path: String) -> [String] {
        var out: [String] = []
        controller.backlinks(of: NoteRef(root: "lib", path: path)) { out = $0.map(\.from.path) }
        _ = controller.waitUntilIdle()
        return out
    }

    /// Closed notes are rewritten byte for byte outside the links: a BOM and CRLF, mixed line endings, an
    /// authorship block (kept as it was).
    func testClosedNotesKeepTheirBytesOutsideTheEditedLinks() throws {
        let files: [String: [UInt8]] = [
            "Crlf.md": [0xEF, 0xBB, 0xBF] + Array("Intro\r\n\r\nSee [[Alpha]] here.\r\nEnd\r\n".utf8),
            "Mixed.md": Array("a\r\nSee [[Alpha]]\nz\rlast".utf8),
            "Marked.md": Array("See [[Alpha]] now\n\n---\nAnnotations: 0,17 SHA-256 abc  \n&AI: 0,3  \n...\n".utf8),
        ]
        for (name, bytes) in files { try Data(bytes).write(to: lib.url.appendingPathComponent(name)) }
        controller.refresh(files.keys.map { lib.url.appendingPathComponent($0) })
        XCTAssertTrue(controller.waitUntilIdle())
        _ = move("Projects/Alpha.md", to: "Projects/Omega.md")
        func bytes(_ name: String) -> [UInt8] { (try? Data(contentsOf: lib.url.appendingPathComponent(name))).map { Array($0) } ?? [] }
        XCTAssertEqual(bytes("Crlf.md"), [0xEF, 0xBB, 0xBF] + Array("Intro\r\n\r\nSee [[Omega]] here.\r\nEnd\r\n".utf8))
        XCTAssertEqual(String(decoding: bytes("Mixed.md"), as: UTF8.self), "a\r\nSee [[Omega]]\nz\rlast")
        XCTAssertEqual(String(decoding: bytes("Marked.md"), as: UTF8.self), "See [[Omega]] now\n\n---\nAnnotations: 0,17 SHA-256 abc  \n&AI: 0,3  \n...\n")
    }

    /// A note open with unsaved changes when the question was asked, and closed without saving before it was
    /// answered: its links were found in the text it had, not in the file, and the file is left alone.
    func testANoteClosedWhileTheQuestionWasUpIsNotEditedByTheWrongRanges() throws {
        let other = try open("Other.md")
        let tv = try XCTUnwrap(other.session.textView)
        _ = tv.replaceThroughUndo(range: NSRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(other.session.text, "X[[Alpha]] twice [[alpha]]\n")
        var reported: [Error] = []
        WorkspacePrompts.reportOverride = { reported.append($0) }
        defer { WorkspacePrompts.reportOverride = nil }
        WorkspacePrompts.linkUpdateOverride = { [unowned self] q in
            questions.append(q)
            other.updateChangeCount(.changeCleared)
            other.close()
            return .update
        }
        docs.removeAll { $0 === other }
        _ = move("Projects/Alpha.md", to: "Projects/Omega.md")
        XCTAssertEqual(lib.read("Other.md"), "[[Alpha]] twice [[alpha]]\n", "not written with ranges from another text")
        XCTAssertEqual(lib.read("Home.md"), "See [[Omega]] and [[Projects/Omega|the first]].\n", "the rest are updated")
        XCTAssertEqual(reported.count, 1, "and the user is told which note was left")
        XCTAssertTrue(lib.exists("Projects/Omega.md"))
    }

    /// Hundreds of closed notes that link to a renamed one are rewritten off the main thread.
    func testClosedNotesAreRewrittenOffTheMainThread() throws {
        let names = (0..<200).map { "Many/Link \($0).md" }
        for n in names { try lib.write(n, "Up to [[Alpha]].\n") }
        controller.refresh([lib.url.appendingPathComponent("Many")])
        XCTAssertTrue(controller.waitUntilIdle())
        let lock = NSLock()
        var onMain = 0, off = 0
        DocumentFileAccess.coordinatedWriteObserver = { _ in lock.lock(); if Thread.isMainThread { onMain += 1 } else { off += 1 }; lock.unlock() }
        defer { DocumentFileAccess.coordinatedWriteObserver = nil }
        let result = move("Projects/Alpha.md", to: "Projects/Omega.md")
        XCTAssertNotNil(try result?.get())
        XCTAssertEqual(onMain, 0, "no closed note is written on the main thread")
        XCTAssertEqual(off, 203, "the 200, Home, Other and Alpha's link to itself")
        XCTAssertEqual(lib.read("Many/Link 7.md"), "Up to [[Omega]].\n")
        XCTAssertTrue(lib.exists("Projects/Omega.md"), "moved once the links were written")
    }

    func testRenameOnlyLeavesTheLinks() throws {
        WorkspacePrompts.linkUpdateOverride = { [unowned self] q in questions.append(q); return .leave }
        let result = move("Projects/Alpha.md", to: "Projects/Omega.md")
        XCTAssertNotNil(try result?.get())
        XCTAssertTrue(lib.exists("Projects/Omega.md"))
        XCTAssertEqual(lib.read("Other.md"), "[[Alpha]] twice [[alpha]]\n")
        XCTAssertEqual(lib.read("Projects/Omega.md"), "# Alpha\n\nSelf: [[Alpha]]\n")
    }

    func testCancellingChangesNothing() throws {
        WorkspacePrompts.linkUpdateOverride = { [unowned self] q in questions.append(q); return .cancel }
        let result = move("Projects/Alpha.md", to: "Projects/Omega.md")
        XCTAssertNil(try result?.get(), "cancelled: no new place")
        XCTAssertTrue(lib.exists("Projects/Alpha.md"))
        XCTAssertFalse(lib.exists("Projects/Omega.md"))
        XCTAssertEqual(lib.read("Other.md"), "[[Alpha]] twice [[alpha]]\n")
    }

    func testARenameNobodyLinksToAsksNothing() throws {
        let result = move("Archive/Old.md", to: "Archive/Older.md")
        XCTAssertNotNil(try result?.get())
        XCTAssertEqual(questions, [])
        XCTAssertTrue(lib.exists("Archive/Older.md"))
    }

    func testANameThatIsTakenIsRefusedBeforeAnythingChanges() throws {
        let result = move("Projects/Alpha.md", to: "Projects/Beta.md")
        if case .failure = try XCTUnwrap(result) {} else { XCTFail("an existing file is not replaced") }
        XCTAssertEqual(questions, [])
        XCTAssertEqual(lib.read("Projects/Beta.md"), "# Beta\n")
        XCTAssertTrue(lib.exists("Projects/Alpha.md"))
    }

    func testRenamingToTheSameNameIsNothing() throws {
        let result = move("Projects/Alpha.md", to: "Projects/Alpha.md")
        XCTAssertNil(try result?.get())
        XCTAssertEqual(questions, [])
    }

    // MARK: folders and moves

    func testRenamingAFolderUpdatesLinksThatNameItsPath() throws {
        try lib.write("Index.md", "By path: [[Projects/Beta]]\n")
        controller.refresh([lib.url.appendingPathComponent("Index.md")])
        XCTAssertTrue(controller.waitUntilIdle())
        let result = move("Projects", to: "Work")
        XCTAssertNotNil(try result?.get())
        XCTAssertTrue(lib.exists("Work/Alpha.md") && lib.exists("Work/Beta.md"))
        XCTAssertFalse(lib.exists("Projects"))
        XCTAssertEqual(lib.read("Index.md"), "By path: [[Work/Beta]]\n")
        XCTAssertEqual(lib.read("Home.md"), "See [[Alpha]] and [[Work/Alpha|the first]].\n", "a link by name stays")
        XCTAssertEqual(questions.count, 1)
        // The index has the notes under the new folder.
        XCTAssertTrue(waitUntil { controller.snapshotNow().roots[0].notes.map(\.path).contains("Work/Alpha.md") })
        XCTAssertFalse(controller.snapshotNow().roots[0].notes.map(\.path).contains("Projects/Alpha.md"))
        XCTAssertEqual(Set(backlinkSources("Work/Alpha.md")), ["Home.md", "Other.md"])
    }

    func testMovingANoteIntoAnotherFolderKeepsLinksByNameAndChangesPaths() throws {
        let result = move("Projects/Alpha.md", to: "Archive/Alpha.md")
        XCTAssertNotNil(try result?.get())
        XCTAssertEqual(lib.read("Home.md"), "See [[Alpha]] and [[Archive/Alpha|the first]].\n")
        XCTAssertEqual(lib.read("Other.md"), "[[Alpha]] twice [[Alpha]]\n", "by name the links still find it; the core only writes the file's own capitals")
        XCTAssertEqual(Set(backlinkSources("Archive/Alpha.md")), ["Home.md", "Other.md"])
    }

    // MARK: trash

    func testTrashingMovesToTheTrashAndClosesTheOpenDocument() throws {
        let beta = try open("Projects/Beta.md")
        var trashed: [(URL, URL?)] = []
        DocumentFileAccess.trashObserver = { trashed.append(($0, $1)) }
        var count = -1
        ws.trash([lib.url.appendingPathComponent("Projects/Beta.md")], window: nil) { count = $0 }
        XCTAssertTrue(waitUntil { count >= 0 })
        XCTAssertEqual(count, 1)
        XCTAssertFalse(lib.exists("Projects/Beta.md"), "gone from the library")
        let landed = try XCTUnwrap(trashed.first?.1)
        XCTAssertTrue(landed.path.contains("/.Trash/"), "moved to the Trash, not unlinked: \(landed.path)")
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), "# Beta\n")
        try? FileManager.default.removeItem(at: landed)
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === beta }, "its document closed")
        docs.removeAll { $0 === beta }
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertTrue(waitUntil { !controller.snapshotNow().roots[0].notes.contains { $0.path == "Projects/Beta.md" } })
    }

    func testAnEditedNoteAsksBeforeItIsTrashed() throws {
        let beta = try open("Projects/Beta.md")
        beta.updateChangeCount(.changeDone)
        var asked: [String] = []
        WorkspacePrompts.trashEditedOverride = { asked.append($0); return false }
        var count = -1
        ws.trash([lib.url.appendingPathComponent("Projects/Beta.md")], window: nil) { count = $0 }
        XCTAssertTrue(waitUntil { count >= 0 })
        XCTAssertEqual(count, 0)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(lib.exists("Projects/Beta.md"), "declined: nothing moved")
        XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === beta })
    }

    // MARK: the open documents' text reaches the library

    func testAnEditedDocumentIsPushedWithinTheLimit() throws {
        let doc = try open("Unrelated.md")
        XCTAssertEqual(backlinkSources("Projects/Beta.md"), ["Unrelated.md"])
        let tv = try XCTUnwrap(doc.session.textView)
        _ = tv.replaceThroughUndo(range: NSRange(location: 0, length: 8), with: "[[Alpha]]")
        let t0 = Date()
        XCTAssertTrue(waitUntil(2) { backlinkSources("Projects/Alpha.md").contains("Unrelated.md") })
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "a second at most")
        XCTAssertEqual(lib.read("Unrelated.md"), "[[Beta]] only\n", "nothing was written")
        XCTAssertEqual(backlinkSources("Projects/Beta.md"), [])
    }

    func testAClosedDocumentThatWasNotSavedIsReadAgainFromDisk() throws {
        let doc = try open("Unrelated.md")
        let tv = try XCTUnwrap(doc.session.textView)
        _ = tv.replaceThroughUndo(range: NSRange(location: 0, length: 8), with: "[[Alpha]]")
        XCTAssertTrue(waitUntil(2) { backlinkSources("Projects/Alpha.md").contains("Unrelated.md") })
        ws.documentClosed(url: lib.url.appendingPathComponent("Unrelated.md"), wasEdited: true)
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(backlinkSources("Projects/Alpha.md").contains("Unrelated.md"), false, "what was typed and thrown away is gone from the index")
        XCTAssertEqual(backlinkSources("Projects/Beta.md"), ["Unrelated.md"])
    }

    func testTheWindowsOfAGroupWireTheirDocumentsToTheLibrary() throws {
        // A window that joins a workspace pushes its document's edits; leaving stops it.
        let doc = try open("Home.md")
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.adopt(ws)
        XCTAssertNotNil(doc.session.onLibraryTextChange)
        XCTAssertTrue(ws.members.contains(wc))
        XCTAssertNotNil(wc.sidebar)
        wc.leaveWorkspace()
        XCTAssertNil(doc.session.onLibraryTextChange)
        XCTAssertFalse(ws.members.contains(wc))
        XCTAssertNil(wc.sidebar)
        XCTAssertTrue(wc.window?.contentView === wc.root, "a window that left is a plain window again")
    }
}
