import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// A folder of notes made for one test.
final class TempLibrary {
    let url: URL

    init(_ files: [String: String] = [:]) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = DocumentFileAccess.canonical(base)
        for (path, text) in files { try write(path, text) }
    }

    func write(_ path: String, _ text: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path) }

    func remove() { try? FileManager.default.removeItem(at: url) }

    var root: LibraryRootInfo { LibraryRootInfo(id: "lib", url: url) }
}

/// Spins the run loop until `condition` holds.
@discardableResult
func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    return condition()
}

extension LibraryController {
    /// The snapshot for `query`, waited for.
    func snapshotNow(_ query: LibraryQuery = LibraryQuery()) -> LibrarySnapshot {
        var result: LibrarySnapshot?
        snapshot(for: query) { result = $0 }
        waitUntil { result != nil }
        return result ?? LibrarySnapshot()
    }
}

final class LibraryScannerTests: XCTestCase {
    func testScanListsNotesFoldersAndOtherFiles() throws {
        let lib = try TempLibrary([
            "a.md": "# A", "b.markdown": "b", "c.mdown": "c", "d.txt": "d", "pic.png": "x", "Sub/e.md": "e", "Sub/Deep/f.md": "f",
        ])
        defer { lib.remove() }
        try FileManager.default.createDirectory(at: lib.url.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        let entries = LibraryScanner.scan(root: lib.url)
        let kinds = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.kind) })
        XCTAssertEqual(kinds["a.md"], .note)
        XCTAssertEqual(kinds["b.markdown"], .note)
        XCTAssertEqual(kinds["c.mdown"], .note)
        XCTAssertEqual(kinds["d.txt"], .note)
        XCTAssertEqual(kinds["pic.png"], .other)
        XCTAssertEqual(kinds["Sub"], .folder)
        XCTAssertEqual(kinds["Sub/Deep/f.md"], .note)
        XCTAssertEqual(kinds["Empty"], .folder, "an empty folder is shown")
    }

    func testScanSkipsHiddenNodeModulesGitAndBigFiles() throws {
        let lib = try TempLibrary([
            ".hidden.md": "x", ".git/config.md": "x", "node_modules/pkg/readme.md": "x", "Sub/.secret.md": "x", "ok.md": "ok",
        ])
        defer { lib.remove() }
        try Data(count: DocumentFileAccess.maximumNoteSize + 1).write(to: lib.url.appendingPathComponent("big.md"))
        try Data(count: DocumentFileAccess.maximumNoteSize).write(to: lib.url.appendingPathComponent("exactly.md"))
        let paths = Set(LibraryScanner.scan(root: lib.url).map(\.path))
        XCTAssertEqual(paths, ["ok.md", "exactly.md", "Sub"])
    }

    func testSymbolicLinkToAFolderIsNotFollowed() throws {
        let lib = try TempLibrary(["real/n.md": "n"])
        defer { lib.remove() }
        try FileManager.default.createSymbolicLink(at: lib.url.appendingPathComponent("loop"), withDestinationURL: lib.url)
        try FileManager.default.createSymbolicLink(at: lib.url.appendingPathComponent("link.md"), withDestinationURL: lib.url.appendingPathComponent("real/n.md"))
        let paths = Set(LibraryScanner.scan(root: lib.url).map(\.path))
        XCTAssertEqual(paths, ["real", "real/n.md", "link.md"])
    }
}

final class LibraryTreeTests: XCTestCase {
    private func entry(_ path: String, _ kind: LibraryEntryKind = .note, _ t: TimeInterval = 0) -> LibraryEntry {
        LibraryEntry(path: path, kind: kind, modified: Date(timeIntervalSince1970: t), size: 1)
    }

    private var root: LibraryRootInfo { LibraryRootInfo(id: "lib", url: URL(fileURLWithPath: "/notes", isDirectory: true)) }

    func testTreeNestsFoldersFirstThenNotesByName() {
        let entries = [entry("b.md"), entry("a 10.md"), entry("a 2.md"), entry("Sub", .folder), entry("Sub/x.md"), entry("Zed", .folder), entry("pic.png", .other)]
        let tree = LibraryTree.build(roots: [root], entries: ["lib": entries], sort: .name)
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].kind, .root)
        XCTAssertEqual(tree[0].children.map(\.name), ["Sub", "Zed", "a 2", "a 10", "b", "pic.png"], "numbers compare by value, as in Finder")
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["Sub/x.md"])
        XCTAssertEqual(tree[0].children[2].kind, .note)
        XCTAssertEqual(tree[0].children[5].kind, .other)
        XCTAssertEqual(tree[0].children[2].id, "lib:a 2.md")
        XCTAssertEqual(tree[0].children[2].note, NoteRef(root: "lib", path: "a 2.md"))
        XCTAssertEqual(tree[0].children[2].url.path, "/notes/a 2.md")
    }

    func testSortByModifiedPutsTheNewestFirstAndKeepsFoldersOnTop() {
        let entries = [entry("old.md", .note, 1), entry("new.md", .note, 9), entry("mid.md", .note, 5), entry("F", .folder, 0)]
        let tree = LibraryTree.build(roots: [root], entries: ["lib": entries], sort: .modified)
        XCTAssertEqual(tree[0].children.map(\.name), ["F", "new", "mid", "old"])
    }

    func testFilteringKeepsOnlyMatchingNotesAndTheFoldersLeadingToThem() {
        let entries = [entry("a.md"), entry("A", .folder), entry("A/b.md"), entry("B", .folder), entry("B/c.md"), entry("E", .folder), entry("p.png", .other)]
        let only: Set<NoteRef> = [NoteRef(root: "lib", path: "A/b.md")]
        let tree = LibraryTree.build(roots: [root], entries: ["lib": entries], sort: .name, only: only)
        XCTAssertEqual(tree[0].children.map(\.name), ["A"])
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["A/b.md"])
        XCTAssertEqual(tree[0].notes.count, 1)
    }

    func testRootsKeepTheirOrderAndEachGetsItsOwnEntries() {
        let second = LibraryRootInfo(id: "folder-2", url: URL(fileURLWithPath: "/other", isDirectory: true))
        let tree = LibraryTree.build(roots: [root, second], entries: ["lib": [entry("a.md")], "folder-2": [entry("z.md")]], sort: .name)
        XCTAssertEqual(tree.map(\.name), ["notes", "other"])
        XCTAssertEqual(tree[1].children.map(\.id), ["folder-2:z.md"])
    }
}

final class NoteTextTests: XCTestCase {
    func testDecodeGivesWhatTheEditorHolds() {
        XCTAssertEqual(NoteText.decode(Data("a\r\nb\r\n".utf8)), "a\nb\n")
        XCTAssertEqual(NoteText.decode(Data([0xEF, 0xBB, 0xBF] + Array("x".utf8))), "x", "no BOM")
        XCTAssertNil(NoteText.decode(Data([0, 1, 2, 3])), "binary data is not a note")
        XCTAssertNil(NoteText.decode(Data([0xFF, 0xFE, 0xFD])), "not UTF-8")
    }

    func testEncodeKeepsTheFilesBOMAndLineEndings() {
        let original = Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8))
        let out = NoteText.encode("one\nTWO\n", replacing: original)
        XCTAssertEqual(out, Data([0xEF, 0xBB, 0xBF] + Array("one\r\nTWO\r\n".utf8)))
    }

    func testApplyEditsLastToFirstAndRefusesOnesThatDoNotFit() {
        func edit(_ a: UInt32, _ b: UInt32, _ r: String) -> LibraryEdit {
            LibraryEdit(note: NoteRef(root: "r", path: "p"), range: Utf16Range(start: a, end: b), replacement: r)
        }
        XCTAssertEqual(NoteText.apply([edit(2, 3, "XX"), edit(0, 1, "")], to: "abcd"), "bXXd")
        XCTAssertEqual(NoteText.apply([edit(0, 99, "x")], to: "abcd"), nil)
        XCTAssertEqual(NoteText.apply([edit(0, 3, "x"), edit(2, 4, "y")], to: "abcd"), nil, "overlapping edits are refused")
        XCTAssertEqual(NoteText.apply([edit(2, 3, "X")], to: "\u{1F389}bc"), "\u{1F389}Xc", "ranges are in UTF-16 units: the emoji is two")
    }
}

final class LibraryControllerTests: XCTestCase {
    private var lib: TempLibrary!
    private var controller: LibraryController!

    override func setUpWithError() throws {
        lib = try TempLibrary([
            "Home.md": "# Home\n\nSee [[Alpha]] and #index\n",
            "Projects/Alpha.md": "---\ntags: [work, plan]\n---\n# Alpha\n\nlinks to [[Home]] about pineapple\n",
            "Projects/Beta.md": "# Beta\n\n#work notes\n",
            "plain.txt": "just text",
            "pic.png": "not a note",
        ])
        controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
    }

    override func tearDown() { lib.remove() }

    func testTheFirstScanIndexesNotesAndBuildsTheTree() {
        XCTAssertFalse(controller.isLoading)
        let s = controller.snapshotNow()
        XCTAssertEqual(s.noteCount, 4)
        XCTAssertEqual(s.roots.count, 1)
        XCTAssertEqual(s.roots[0].children.map(\.name), ["Projects", "Home", "pic.png", "plain"])
        XCTAssertEqual(s.tags.map(\.tag).sorted(), ["index", "plan", "work"])
        XCTAssertEqual(s.tags.first { $0.tag == "work" }?.count, 2)
    }

    func testTagFilterIsAnAndAndPrunesTheTree() {
        var s = controller.snapshotNow(LibraryQuery(tags: ["work"]))
        XCTAssertEqual(s.roots[0].notes.map(\.path).sorted(), ["Projects/Alpha.md", "Projects/Beta.md"])
        s = controller.snapshotNow(LibraryQuery(tags: ["work", "plan"]))
        XCTAssertEqual(s.roots[0].notes.map(\.path), ["Projects/Alpha.md"])
        XCTAssertEqual(s.roots[0].children.map(\.name), ["Projects"])
        s = controller.snapshotNow(LibraryQuery(tags: ["work", "index"]))
        XCTAssertTrue(s.roots[0].notes.isEmpty)
    }

    func testSearchReturnsRankedHitsWithSnippets() {
        let s = controller.snapshotNow(LibraryQuery(search: "pineapple"))
        XCTAssertEqual(s.hits.map(\.note.path), ["Projects/Alpha.md"])
        XCTAssertTrue(s.hits[0].snippet.contains("pineapple"))
        XCTAssertFalse(s.hits[0].highlights.isEmpty)
        XCTAssertTrue(controller.snapshotNow(LibraryQuery(search: "")).hits.isEmpty)
    }

    func testReferencesAndFilesMapBothWays() {
        let ref = controller.ref(for: lib.url.appendingPathComponent("Projects/Alpha.md"))
        XCTAssertEqual(ref, NoteRef(root: "lib", path: "Projects/Alpha.md"))
        XCTAssertEqual(controller.url(for: ref!)?.path, lib.url.appendingPathComponent("Projects/Alpha.md").path)
        XCTAssertNil(controller.ref(for: URL(fileURLWithPath: "/somewhere/else.md")))
    }

    func testBacklinksResolveAndQuickOpenFindsByTitle() {
        var links: [NoteBacklink] = []
        controller.backlinks(of: NoteRef(root: "lib", path: "Home.md")) { links = $0 }
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(links.map(\.from.path), ["Projects/Alpha.md"])
        XCTAssertTrue(links[0].context.contains("links to"))
        var matches: [QuickOpenMatch] = []
        controller.quickOpen("alp") { matches = $0 }
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(matches.first?.note.path, "Projects/Alpha.md")
    }

    func testResultsAreDeliveredOnTheMainThread() {
        XCTAssertTrue(controller.isIdle)
        var thread: Bool?
        controller.snapshot(for: LibraryQuery()) { _ in thread = Thread.isMainThread }
        XCTAssertTrue(waitUntil { thread != nil })
        XCTAssertEqual(thread, true, "results are delivered on the main thread")
    }

    // MARK: following the file system

    func testANewFileAppearsThroughTheFileSystemEvents() throws {
        try lib.write("Fresh.md", "# Fresh\n\n#brandnew\n")
        XCTAssertTrue(waitUntil(15) { controller.snapshotNow().roots[0].children.contains { $0.name == "Fresh" } })
        XCTAssertTrue(controller.snapshotNow().tags.contains { $0.tag == "brandnew" })
    }

    func testAnEditedAndADeletedFileFollow() throws {
        try lib.write("Projects/Beta.md", "# Beta\n\n#changed\n")
        XCTAssertTrue(waitUntil(15) { controller.snapshotNow().tags.contains { $0.tag == "changed" } })
        XCTAssertFalse(controller.snapshotNow().tags.contains { $0.tag == "work" && $0.count == 2 })
        try FileManager.default.removeItem(at: lib.url.appendingPathComponent("Projects/Beta.md"))
        XCTAssertTrue(waitUntil(15) { !controller.snapshotNow().roots[0].notes.contains { $0.name == "Beta" } })
        XCTAssertFalse(controller.snapshotNow().tags.contains { $0.tag == "changed" })
    }

    func testANewFolderWithNotesAndItsRemoval() throws {
        try lib.write("New/Deeper/x.md", "# X\n")
        XCTAssertTrue(waitUntil(15) { controller.snapshotNow().roots[0].notes.contains { $0.path == "New/Deeper/x.md" } })
        try FileManager.default.removeItem(at: lib.url.appendingPathComponent("New"))
        XCTAssertTrue(waitUntil(15) { !controller.snapshotNow().roots[0].children.contains { $0.name == "New" } })
        XCTAssertEqual(controller.snapshotNow().noteCount, 4)
    }

    func testHiddenFilesAndBigFilesThatAppearAreIgnored() throws {
        try lib.write(".hidden.md", "# Hidden")
        try Data(count: DocumentFileAccess.maximumNoteSize + 10).write(to: lib.url.appendingPathComponent("big.md"))
        try lib.write("seen.md", "# Seen")
        XCTAssertTrue(waitUntil(15) { controller.snapshotNow().roots[0].children.contains { $0.name == "seen" } })
        let names = controller.snapshotNow().roots[0].children.map(\.name)
        XCTAssertFalse(names.contains(".hidden.md"))
        XCTAssertFalse(names.contains("big"))
    }

    // MARK: what the app does itself

    func testPushedTextReachesBacklinksWithoutASave() {
        controller.push(NoteRef(root: "lib", path: "Projects/Beta.md"), text: "# Beta\n\nnow links to [[Home]] and #pushed\n")
        XCTAssertTrue(controller.waitUntilIdle())
        var links: [NoteBacklink] = []
        controller.backlinks(of: NoteRef(root: "lib", path: "Home.md")) { links = $0 }
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(Set(links.map(\.from.path)), ["Projects/Alpha.md", "Projects/Beta.md"])
        XCTAssertTrue(controller.snapshotNow().tags.contains { $0.tag == "pushed" })
        XCTAssertEqual(lib.read("Projects/Beta.md"), "# Beta\n\n#work notes\n", "nothing was written")
    }

    /// A note deleted on disk while its document is open: what the document still pushes does not bring it
    /// back into the index (it would stay there, with its tags and links, after the window closed).
    func testAPushForANoteWhoseFileIsGoneIsIgnored() throws {
        try FileManager.default.removeItem(at: lib.url.appendingPathComponent("Projects/Beta.md"))
        controller.refresh([lib.url.appendingPathComponent("Projects/Beta.md")])
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(controller.snapshotNow().noteCount, 3)
        controller.push(NoteRef(root: "lib", path: "Projects/Beta.md"), text: "# Beta\n\n#ghost [[Home]]\n")
        controller.push(NoteRef(root: "lib", path: "Nowhere.md"), text: "#ghost\n")
        XCTAssertTrue(controller.waitUntilIdle())
        let s = controller.snapshotNow()
        XCTAssertEqual(s.noteCount, 3)
        XCTAssertFalse(s.tags.contains { $0.tag == "ghost" })
        XCTAssertTrue(controller.snapshotNow(LibraryQuery(search: "Beta")).hits.isEmpty)
        // Saved again: a note again, with what the file says.
        try lib.write("Projects/Beta.md", "# Beta\n\n#back\n")
        controller.refresh([lib.url.appendingPathComponent("Projects/Beta.md")])
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertTrue(controller.snapshotNow().tags.contains { $0.tag == "back" })
    }

    func testRefreshForceReadsTheFileAgainAfterAPush() {
        let beta = NoteRef(root: "lib", path: "Projects/Beta.md")
        controller.push(beta, text: "# Beta\n\n#unsaved\n")
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertTrue(controller.snapshotNow().tags.contains { $0.tag == "unsaved" })
        controller.refresh([lib.url.appendingPathComponent("Projects/Beta.md")], force: true)
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertFalse(controller.snapshotNow().tags.contains { $0.tag == "unsaved" })
    }

    func testMovedKeepsTheLinkGraphUnderTheNewPath() throws {
        try FileManager.default.createDirectory(at: lib.url.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: lib.url.appendingPathComponent("Projects/Alpha.md"), to: lib.url.appendingPathComponent("Archive/Alpha.md"))
        controller.moved(from: lib.url.appendingPathComponent("Projects/Alpha.md"), to: lib.url.appendingPathComponent("Archive/Alpha.md"))
        XCTAssertTrue(controller.waitUntilIdle())
        var links: [NoteBacklink] = []
        controller.backlinks(of: NoteRef(root: "lib", path: "Home.md")) { links = $0 }
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(links.map(\.from.path), ["Archive/Alpha.md"])
        let s = controller.snapshotNow()
        XCTAssertEqual(s.noteCount, 4)
        XCTAssertEqual(s.roots[0].notes.map(\.path).sorted(), ["Archive/Alpha.md", "Home.md", "Projects/Beta.md", "plain.txt"])
    }

    func testRenameEditsComeFromTheCore() {
        var edits: [LibraryEdit] = []
        controller.renameEdits(from: NoteRef(root: "lib", path: "Projects/Alpha.md"), to: NoteRef(root: "lib", path: "Projects/Omega.md")) { edits = $0 }
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(edits.map(\.note.path), ["Home.md"])
        XCTAssertEqual(edits.map(\.replacement), ["Omega"])
    }

    func testRemovingARootForgetsItsNotes() throws {
        let other = try TempLibrary(["Other.md": "# Other\n"])
        defer { other.remove() }
        controller.setRoots([lib.root, LibraryRootInfo(id: "folder-2", url: other.url)])
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(controller.snapshotNow().roots.map(\.name), [lib.url.lastPathComponent, other.url.lastPathComponent])
        XCTAssertEqual(controller.snapshotNow().noteCount, 5)
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertEqual(controller.snapshotNow().noteCount, 4)
    }

    func testObserversAreToldOnceForABurstOfChanges() {
        var calls = 0
        let owner = NSObject()
        controller.observe(owner) { calls += 1 }
        for i in 0..<5 { controller.push(NoteRef(root: "lib", path: "Home.md"), text: "# Home \(i)\n") }
        XCTAssertTrue(controller.waitUntilIdle())
        XCTAssertGreaterThanOrEqual(calls, 1)
        XCTAssertLessThanOrEqual(calls, 5)
        controller.stopObserving(owner)
    }
}
