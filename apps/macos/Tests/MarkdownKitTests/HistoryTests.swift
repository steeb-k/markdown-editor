import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The history store as the app uses it (off the main thread, keyed per document), the panel that shows it, and what
/// the document does to feed it.
final class HistoryModelTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func version(_ id: UInt64, _ time: Int64, _ reason: HistoryReason = .pause, message: String? = nil, added: UInt32 = 1, removed: UInt32 = 0) -> HistoryVersion {
        HistoryVersion(id: id, time: time, reason: reason, message: message, bytes: 10, added: added, removed: removed)
    }

    func testVersionsAreGroupedByDayNewestFirstWithTodayAndYesterday() {
        let day: Int64 = 86_400
        let now = Date(timeIntervalSince1970: TimeInterval(100 * day + 12 * 3600))
        let versions = [version(5, 100 * day + 11 * 3600), version(4, 100 * day + 3600), version(3, 99 * day + 80_000),
                        version(2, 90 * day + 5), version(1, 90 * day)]
        let sections = HistoryModel.sections(versions, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(sections.map(\.title).prefix(2), ["Today", "Yesterday"])
        XCTAssertEqual(sections.map { $0.versions.map(\.id) }, [[5, 4], [3], [2, 1]])
        XCTAssertFalse(sections[2].title.isEmpty)
        XCTAssertNotEqual(sections[2].title, "Today")
    }

    func testRowsSayTheReasonTheChangeAndTheMessage() {
        XCTAssertEqual(HistoryModel.summary(version(1, 0, added: 3, removed: 1)), "+3 \u{2212}1")
        XCTAssertEqual(HistoryModel.summary(version(1, 0, added: 0, removed: 2)), "\u{2212}2")
        XCTAssertEqual(HistoryModel.summary(version(1, 0, added: 4, removed: 0)), "+4")
        XCTAssertEqual(HistoryModel.reasonText(.pause), "Pause")
        for (r, t) in [(HistoryReason.close, "Close"), (.save, "Save"), (.restore, "Restore"), (.draft, "Draft")] { XCTAssertEqual(HistoryModel.reasonText(r), t) }
        let label = HistoryModel.accessibilityLabel(version(1, 0, .save, message: "before the rewrite", added: 1, removed: 2), calendar: utc, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(label, "12:00\u{202F}AM, save, 1 line added, 2 lines removed, before the rewrite")
    }

    private func style() -> HistoryModel.DiffStyle {
        let palette = ThemeStore.shared.palette(ThemeStore.shared.theme(id: "light"))
        return HistoryModel.DiffStyle(palette: palette, secondary: .secondaryLabelColor, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
    }

    func testTheDiffIsColouredWithTheReferenceAndAIColoursMuted() {
        let st = style()
        let hunks = [HistoryHunk(kind: .equal, oldRange: Utf16Range(start: 0, end: 2), newRange: Utf16Range(start: 0, end: 2), text: "a\n"),
                     HistoryHunk(kind: .removed, oldRange: Utf16Range(start: 2, end: 4), newRange: Utf16Range(start: 2, end: 2), text: "b\n"),
                     HistoryHunk(kind: .added, oldRange: Utf16Range(start: 4, end: 4), newRange: Utf16Range(start: 2, end: 4), text: "B\n")]
        let text = HistoryModel.diffText(hunks, style: st)
        XCTAssertEqual(text.string, "  a\n\u{2212} b\n+ B\n")
        func attrs(_ line: Int) -> (fg: NSColor, bg: NSColor?) {
            let r = (text.string as NSString).range(of: ["  a", "\u{2212} b", "+ B"][line])
            return (text.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as! NSColor, text.attribute(.backgroundColor, at: r.location, effectiveRange: nil) as? NSColor)
        }
        func same(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
            return abs(x.redComponent - y.redComponent) < 0.01 && abs(x.greenComponent - y.greenComponent) < 0.01 && abs(x.blueComponent - y.blueComponent) < 0.01
        }
        XCTAssertTrue(same(attrs(0).fg, .secondaryLabelColor), "unchanged lines are secondary")
        XCTAssertNil(attrs(0).bg)
        XCTAssertTrue(same(attrs(1).fg, st.removed), "removed: the theme's reference colour")
        XCTAssertTrue(same(attrs(2).fg, st.added), "added: the theme's AI colour")
        XCTAssertLessThan(attrs(1).fg.alphaComponent, 1, "muted")
        XCTAssertLessThan(attrs(2).bg?.alphaComponent ?? 1, 0.3, "a faint wash of the colour behind the line")
        XCTAssertFalse(same(st.removed, st.added))
    }

    func testALongUnchangedStretchShowsHowManyLinesItHides() {
        let many = (1...20).map { "line \($0)\n" }.joined()
        let hunks = [HistoryHunk(kind: .equal, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: many),
                     HistoryHunk(kind: .added, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: "new\n"),
                     HistoryHunk(kind: .equal, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: many)]
        let s = HistoryModel.diffText(hunks, style: style()).string
        // The first stretch keeps its last two lines, the last stretch its first two.
        XCTAssertTrue(s.contains("  \u{22EF} 18 unchanged lines\n  line 19\n  line 20\n+ new\n  line 1\n  line 2\n  \u{22EF} 18 unchanged lines"), s)
        XCTAssertFalse(s.contains("line 10"))
    }
}

@MainActor
final class HistoryServiceTests: XCTestCase {
    private var dir: URL!
    private var service: HistoryService!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-history-test-\(UUID().uuidString)", isDirectory: true)
        service = HistoryService(directory: dir)
    }

    override func tearDown() {
        service.flush()
        try? FileManager.default.removeItem(at: dir)
        HistoryService.current = nil
    }

    func testKeysAreTheNoteInTheLibraryOrAHashOfThePath() throws {
        let lib = try TempLibrary(["a/Note.md": "x"])
        defer { lib.remove() }
        let controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertEqual(HistoryKey.key(for: lib.url.appendingPathComponent("a/Note.md"), library: controller), "note:lib/a/Note.md")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside.md")
        let k = HistoryKey.key(for: outside, library: controller)
        XCTAssertTrue(k.hasPrefix("file:"))
        XCTAssertEqual(k, HistoryKey.key(forFile: outside), "stable")
        XCTAssertNotEqual(k, HistoryKey.key(forFile: outside.deletingLastPathComponent().appendingPathComponent("other.md")))
        XCTAssertEqual(HistoryKey.key(forFile: outside), HistoryKey.key(forFile: URL(fileURLWithPath: outside.path + "/../outside.md")), "a path is canonical before it is hashed")
    }

    func testRecordingIsAsyncDedupedAndAnnounced() {
        var announced: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .historyDidRecord, object: service, queue: .main) { n in announced.append(n.userInfo?["key"] as? String ?? "") }
        defer { NotificationCenter.default.removeObserver(token) }
        var ids: [UInt64?] = []
        service.record(key: "k", text: "one\n", reason: .pause) { ids.append($0) }
        service.record(key: "k", text: "one\n", reason: .close) { ids.append($0) }
        service.record(key: "k", text: "one\ntwo\n", reason: .save, message: "m") { ids.append($0) }
        XCTAssertTrue(waitUntil { ids.count == 3 })
        XCTAssertNotNil(ids[0])
        XCTAssertNil(ids[1], "the same text again records nothing")
        XCTAssertNotNil(ids[2])
        XCTAssertEqual(announced, ["k", "k"], "a snapshot is announced, a repeat is not")
        let v = service.versionsNow(key: "k")
        XCTAssertEqual(v.map(\.reason), [.save, .pause])
        XCTAssertEqual(v[0].message, "m")
        XCTAssertEqual(service.textNow(key: "k", id: v[1].id), "one\n")
        var diff: [HistoryHunk]?
        service.diff(key: "k", id: v[1].id, current: "one\ntwo\n") { diff = $0 }
        XCTAssertTrue(waitUntil { diff != nil })
        XCTAssertEqual(diff?.map(\.kind), [.equal, .added])
    }

    func testARenameKeepsTheHistoryAndForgetDropsIt() {
        service.record(key: "old", text: "a\n", reason: .pause)
        service.rekey("old", to: "new")
        service.flush()
        XCTAssertTrue(service.versionsNow(key: "old").isEmpty)
        XCTAssertEqual(service.versionsNow(key: "new").count, 1)
        service.forget(key: "new")
        service.flush()
        XCTAssertTrue(service.versionsNow(key: "new").isEmpty)
    }

    func testAMovedFolderTakesTheHistoriesOfItsNotesWithIt() {
        for path in ["Deep/a.md", "Deep/Sub/b.md", "Other.md"] { service.record(key: HistoryKey.key(for: NoteRef(root: "lib", path: path)), text: "t " + path, reason: .pause) }
        service.rekeyMoved(from: NoteRef(root: "lib", path: "Deep"), to: NoteRef(root: "lib", path: "Deeper"))
        service.flush()
        func count(_ path: String) -> Int { service.versionsNow(key: HistoryKey.key(for: NoteRef(root: "lib", path: path))).count }
        XCTAssertEqual([count("Deeper/a.md"), count("Deeper/Sub/b.md"), count("Other.md")], [1, 1, 1])
        XCTAssertEqual([count("Deep/a.md"), count("Deep/Sub/b.md")], [0, 0])
        // One note renamed.
        service.rekeyMoved(from: NoteRef(root: "lib", path: "Other.md"), to: NoteRef(root: "lib", path: "Renamed.md"))
        service.flush()
        XCTAssertEqual([count("Renamed.md"), count("Other.md")], [1, 0])
    }

    func testAFolderThatCannotBeMadeLeavesHistoryOffWithoutACrash() {
        let blocked = HistoryService(directory: URL(fileURLWithPath: "/dev/null/history"))
        XCTAssertFalse(blocked.isAvailable)
        var id: UInt64? = 1
        var called = false
        blocked.record(key: "k", text: "x", reason: .pause) { id = $0; called = true }
        XCTAssertTrue(waitUntil { called })
        XCTAssertNil(id)
        XCTAssertTrue(blocked.versionsNow(key: "k").isEmpty)
    }

    // MARK: the panel

    private func panel(_ service: HistoryService, key: String, text: @escaping () -> String) -> HistoryController {
        let palette = ThemeStore.shared.palette(ThemeStore.shared.theme(id: "light"))
        let style = SidebarStyle(palette)
        let c = HistoryController(style: style, diffStyle: HistoryModel.DiffStyle(palette: palette, secondary: style.secondary, font: .monospacedSystemFont(ofSize: 11, weight: .regular)))
        c.view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        c.currentText = text
        c.key = key
        c.service = service
        return c
    }

    func testThePanelListsVersionsSelectsOneToShowItsDiffAndRestoresAndCopies() throws {
        service.record(key: "k", text: "alpha\nbeta\n", reason: .close)
        service.record(key: "k", text: "alpha\nbeta\ngamma\n", reason: .pause)
        service.record(key: "k", text: "alpha\nBETA\ngamma\n", reason: .save, message: "milestone")
        service.flush()
        var current = "alpha\nBETA\ngamma\ndelta\n"
        let p = panel(service, key: "k") { current }
        XCTAssertTrue(waitUntil { p.versions.count == 3 })
        XCTAssertEqual(p.items.count, 4, "a day and three versions")
        if case .day(let t) = p.items[0] { XCTAssertEqual(t, "Today") } else { XCTFail("the day comes first") }
        XCTAssertFalse(p.view.restoreButton.isEnabled)
        XCTAssertFalse(p.view.showsEmptyState)
        // The oldest: against the text as it is now, what changed since.
        p.select(id: p.versions[2].id)
        XCTAssertTrue(waitUntil { p.diffsShown == 1 })
        let shown = p.view.diff.string
        XCTAssertTrue(shown.contains("\u{2212} beta"), shown)
        XCTAssertTrue(shown.contains("+ BETA") && shown.contains("+ delta"), shown)
        XCTAssertTrue(p.view.restoreButton.isEnabled && p.view.copyButton.isEnabled)
        // Restore hands the version's text to the window; Copy puts it on a pasteboard.
        var restored: (HistoryVersion, String)?
        p.onRestore = { restored = ($0, $1) }
        p.restoreSelected()
        XCTAssertTrue(waitUntil { restored != nil })
        XCTAssertEqual(restored?.1, "alpha\nbeta\n")
        let pb = NSPasteboard(name: NSPasteboard.Name("markdown-test-\(UUID().uuidString)"))
        var copied = false
        p.copySelected(to: pb) { copied = true }
        XCTAssertTrue(waitUntil { copied })
        XCTAssertEqual(pb.string(forType: .string), "alpha\nbeta\n")
        // A snapshot recorded while it is open appears in it, and the selection stays.
        let selected = p.selectedID
        current = "alpha\nBETA\ngamma\ndelta\nepsilon\n"
        service.record(key: "k", text: current, reason: .pause)
        XCTAssertTrue(waitUntil { p.versions.count == 4 })
        XCTAssertEqual(p.selectedID, selected)
        XCTAssertEqual(p.versions[0].reason, .pause)
        // The rows are named for VoiceOver: a role and a label with the time, the reason, the change and the message.
        p.view.list.reloadData()
        let milestone = try XCTUnwrap(p.items.firstIndex { if case .version(let v) = $0 { return v.message == "milestone" } else { return false } })
        let row = try XCTUnwrap(p.view.list.view(atColumn: 0, row: milestone, makeIfNecessary: true) as? HistoryRowView)
        XCTAssertEqual(row.accessibilityRole(), .row)
        let label = try XCTUnwrap(row.accessibilityLabel())
        XCTAssertTrue(label.contains("save") && label.contains("milestone") && label.contains("added"), label)
        XCTAssertEqual(p.view.list.accessibilityLabel(), "History")
        XCTAssertEqual(row.frame.height, HistoryRowView.messageHeight, accuracy: 0.5, "a message takes a second line")
    }

    func testThePanelOfADocumentWithoutAHistoryShowsTheEmptyState() {
        let p = panel(service, key: "none") { "" }
        XCTAssertTrue(waitUntil { p.reloads == 1 })
        XCTAssertTrue(p.view.showsEmptyState)
        XCTAssertTrue(p.items.isEmpty)
        p.key = nil
        XCTAssertTrue(p.items.isEmpty)
    }
}

@MainActor
final class AutosaveTests: XCTestCase {
    private var scratch: URL!
    private var service: HistoryService!
    private var docs: [MarkdownDocument] = []

    override func setUp() {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-autosave-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        service = HistoryService(directory: scratch.appendingPathComponent("history"))
        HistoryService.current = service
        MarkdownDocument.autosaveDelay = 0.3
    }

    override func tearDown() {
        for d in docs { d.updateChangeCount(.changeCleared); d.close() }
        service.flush()
        HistoryService.current = nil
        MarkdownDocument.autosaveDelay = 2
        try? FileManager.default.removeItem(at: scratch)
    }

    private func open(_ text: String, name: String = "note.md", settings: Settings = isolatedSettings()) throws -> (MarkdownDocument, EditorWindowController, URL) {
        let url = scratch.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let doc = MarkdownDocument(settings: settings)
        doc.fileURL = url
        try doc.read(from: url, ofType: "net.daringfireball.markdown")
        doc.fileModificationDate = DocumentFileAccess.modificationDate(of: url)
        doc.makeWindowControllers()
        docs.append(doc)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc, url)
    }

    private func type(_ s: String, in wc: EditorWindowController) {
        wc.textView.insertText(s, replacementRange: NSRange(location: wc.textView.string.utf16.count, length: 0))
    }

    private func onDisk(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testATitledDocumentIsWrittenAPauseAfterTheLastKeystrokeAndSnapshotted() throws {
        let (doc, wc, url) = try open("# Note\n")
        let started = Date()
        for chunk in ["a", "b", "c"] {
            type(chunk, in: wc)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
        }
        XCTAssertEqual(onDisk(url), "# Note\n", "typing that has not paused is not written (and the timer was moved on by each key)")
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertFalse(wc.window?.isDocumentEdited ?? true, "no dot on the red button")
        XCTAssertTrue(waitUntil { self.onDisk(url).hasSuffix("abc") })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3 + 0.2, "after the last keystroke (0.24 s in), not the first (0.3 s): the timer was moved on by each key")
        XCTAssertTrue(waitUntil { !doc.isDocumentEdited })
        XCTAssertEqual(doc.writesOnMainThread.count, 1, "one write for the whole burst")
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "").count == 2 })
        let versions = service.versionsNow(key: try XCTUnwrap(doc.historyKey))
        XCTAssertEqual(versions.map(\.reason), [.pause, .close], "the text as it was opened, then the pause")
        XCTAssertEqual(service.textNow(key: doc.historyKey ?? "", id: versions[1].id), "# Note\n")
        XCTAssertEqual(service.textNow(key: doc.historyKey ?? "", id: versions[0].id), "# Note\nabc")
        // Nothing changed since: another pause records nothing and writes nothing.
        doc.textChanged()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        XCTAssertEqual(service.versionsNow(key: doc.historyKey ?? "").count, 2)
        XCTAssertEqual(doc.writesOnMainThread.count, 1)
    }

    func testAnAutosaveLeavesUndoWorking() throws {
        let (doc, wc, url) = try open("one\n")
        type("two", in: wc)
        XCTAssertTrue(waitUntil { self.onDisk(url) == "one\ntwo" })
        XCTAssertTrue(waitUntil { !doc.isDocumentEdited })
        XCTAssertTrue(doc.undoManager?.canUndo ?? false, "the write did not clear the undo stack")
        doc.undoManager?.undo()
        XCTAssertEqual(doc.session.text, "one\n")
        XCTAssertTrue(doc.isDocumentEdited, "undoing past the write is a change again")
        XCTAssertTrue(waitUntil { self.onDisk(url) == "one\n" })
    }

    func testLeavingTheWindowWritesAndSnapshotsAtOnceAndNeverAsks() throws {
        let (doc, wc, url) = try open("start\n")
        type("!", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))   // the undo group closes, and the document is edited
        var allowed: Bool?
        doc.settleForLeaving { allowed = $0 }
        XCTAssertTrue(waitUntil { allowed != nil })
        XCTAssertEqual(allowed, true)
        XCTAssertEqual(onDisk(url), "start\n!")
        XCTAssertNil(wc.window?.attachedSheet)
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "").count == 2 })
        XCTAssertEqual(service.versionsNow(key: doc.historyKey ?? "").first?.reason, .close)
        XCTAssertFalse(doc.autosaveTimer?.isValid ?? false, "nothing is owed after it")
    }

    func testSaveRecordsASnapshotWithTheReasonSave() throws {
        let (doc, wc, url) = try open("s\n")
        type("x", in: wc)
        var saved = false
        doc.save(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation) { _ in saved = true }
        XCTAssertTrue(waitUntil { saved })
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "").count == 2 })
        XCTAssertEqual(service.versionsNow(key: doc.historyKey ?? "").map(\.reason), [.save, .close])
    }

    func testAnUntitledDocumentIsDraftedIntoTheLibrariesDraftsFolder() throws {
        let lib = try TempLibrary(["Home.md": "# Home\n"])
        defer { lib.remove() }
        let settings = isolatedSettings()
        let ws = Workspace.make(settings: settings, notesMode: true)
        ws.setLibraryFolder(lib.url)
        let doc = MarkdownDocument(settings: settings)
        doc.makeWindowControllers()
        docs.append(doc)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        type("A draft.", in: wc)
        XCTAssertNil(doc.fileURL)
        XCTAssertTrue(waitUntil { doc.fileURL != nil })
        XCTAssertEqual(doc.fileURL?.lastPathComponent, "Untitled 1.md")
        XCTAssertEqual(doc.fileURL?.deletingLastPathComponent().lastPathComponent, "Drafts")
        XCTAssertEqual(lib.read("Drafts/Untitled 1.md"), "A draft.")
        XCTAssertTrue(waitUntil { !doc.isDocumentEdited })
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "x").map(\.reason) == [.draft] })
        XCTAssertEqual(doc.historyKey, "note:\(LibraryRootInfo.libraryID)/Drafts/Untitled 1.md")
        // A second one takes the next number.
        let other = MarkdownDocument(settings: settings)
        other.makeWindowControllers()
        docs.append(other)
        let wc2 = try XCTUnwrap(other.windowControllers.first as? EditorWindowController)
        type("Another.", in: wc2)
        var done = false
        other.settleForLeaving { _ in done = true }
        XCTAssertTrue(waitUntil { done })
        XCTAssertEqual(lib.read("Drafts/Untitled 2.md"), "Another.", "leaving drafts it at once")
        // Blank text is not worth a file, and closing it asks nothing.
        let blank = MarkdownDocument(settings: settings)
        blank.makeWindowControllers()
        docs.append(blank)
        var allowed: Bool?
        blank.settleForLeaving { allowed = $0 }
        XCTAssertTrue(waitUntil { allowed != nil })
        XCTAssertEqual(allowed, true)
        XCTAssertFalse(lib.exists("Drafts/Untitled 3.md"))
        wc.leaveWorkspace()
        ws.library.stopObserving(ws)
    }

    func testAnUntitledDocumentWithoutALibraryIsNotDrafted() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        doc.makeWindowControllers()
        docs.append(doc)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        type("text", in: wc)
        XCTAssertNil(doc.draftsFolder)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.7))
        XCTAssertNil(doc.fileURL, "no library: it is asked about on closing, as before")
        XCTAssertTrue(doc.hasDraftableText)
    }

    func testAFileChangedByAnotherAppIsNeverOverwrittenOursIsKeptAndTheFileReadAgain() throws {
        let (doc, wc, url) = try open("mine\n")
        var notified: Bool?
        let token = NotificationCenter.default.addObserver(forName: .documentChangedOnDisk, object: doc, queue: .main) { notified = $0.userInfo?["hadChanges"] as? Bool }
        defer { NotificationCenter.default.removeObserver(token) }
        type("unsaved", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))   // the undo group closes, and the document is edited
        try Data("theirs\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 20)], ofItemAtPath: url.path)
        XCTAssertTrue(doc.handleExternalChange())
        XCTAssertEqual(doc.session.text, "theirs\n")
        XCTAssertEqual(onDisk(url), "theirs\n", "their file is as they left it")
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(notified, true)
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "").count == 3 })
        let v = service.versionsNow(key: try XCTUnwrap(doc.historyKey))
        XCTAssertEqual(v.map { service.textNow(key: doc.historyKey ?? "", id: $0.id) }, ["theirs\n", "mine\nunsaved", "mine\n"])
        XCTAssertEqual(v[1].message, "Before another app changed this file")
        // The bar says so, and offers the history.
        wc.showChangeBar(hadChanges: true)
        XCTAssertNotNil(wc.changeBar?.superview)
        XCTAssertTrue(wc.changeBar?.label.stringValue.contains("kept in History") ?? false)
        wc.changeBar?.onShowHistory?()
        XCTAssertTrue(wc.session.historyShown)
        XCTAssertNil(wc.changeBar)
        // A file nobody changed is not an external change.
        XCTAssertFalse(doc.handleExternalChange())
        // Nor is a newer date on the very bytes this document would write (a sync tool touched the file).
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        XCTAssertFalse(doc.handleExternalChange())
        XCTAssertEqual(doc.fileModificationDate?.timeIntervalSinceNow ?? 0, 60, accuracy: 5, "the date is taken as known")
        XCTAssertFalse(doc.handleExternalChange())
    }

    func testRenamingTheFileMovesTheHistory() throws {
        let (doc, wc, url) = try open("r\n")
        type("x", in: wc)
        var saved = false
        doc.save(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation) { _ in saved = true }
        XCTAssertTrue(waitUntil { saved })
        let oldKey = try XCTUnwrap(doc.historyKey)
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: oldKey).count == 2 })
        let moved = scratch.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: url, to: moved)
        doc.fileURL = moved
        service.flush()
        XCTAssertNotEqual(doc.historyKey, oldKey)
        XCTAssertEqual(service.versionsNow(key: oldKey).count, 0)
        XCTAssertEqual(service.versionsNow(key: try XCTUnwrap(doc.historyKey)).count, 2)
        // Save As leaves the first file where it is, with its history: the new file starts its own.
        let renamedKey = try XCTUnwrap(doc.historyKey)
        let copy = scratch.appendingPathComponent("copy.md")
        try FileManager.default.copyItem(at: moved, to: copy)
        doc.fileURL = copy
        service.flush()
        XCTAssertEqual(service.versionsNow(key: renamedKey).count, 2)
        XCTAssertEqual(service.versionsNow(key: try XCTUnwrap(doc.historyKey)).count, 0)
    }

    func testRestoreIsOneUndoableEditNamedRestoreVersionAndRecordsTheTextItReplaced() throws {
        let (doc, wc, _) = try open("original\n")
        type("more", in: wc)
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "").count == 2 })
        let key = try XCTUnwrap(doc.historyKey)
        let oldest = try XCTUnwrap(service.versionsNow(key: key).last)
        type(" and unsaved", in: wc)
        wc.restore(oldest, text: "original\n")
        XCTAssertEqual(doc.session.text, "original\n")
        XCTAssertEqual(doc.undoManager?.undoActionName, "Restore Version")
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: key).count == 4 })
        let versions = service.versionsNow(key: key)
        XCTAssertEqual(versions.map(\.reason), [.restore, .restore, .pause, .close])
        XCTAssertEqual(versions[1].message, "Before restoring a version")
        XCTAssertEqual(service.textNow(key: key, id: versions[1].id), "original\nmore and unsaved")
        doc.undoManager?.undo()
        XCTAssertEqual(doc.session.text, "original\nmore and unsaved", "one undo takes the whole restore back")
        doc.undoManager?.redo()
        XCTAssertEqual(doc.session.text, "original\n")
    }

    func testTheOutlineAndTheHistoryShareTheColumnEachWithItsOwnToggleAndWidth() throws {
        let (doc, wc, _) = try open("# A\n\ntext\n")
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: 1000, height: 700))
        let s = doc.session
        s.setOutlineShown(true)
        XCTAssertNotNil(wc.outline)
        XCTAssertNil(wc.history)
        s.setHistoryShown(true)
        XCTAssertNil(wc.outline, "the outline gives the column up")
        XCTAssertNotNil(wc.history)
        XCTAssertFalse(s.outlineShown)
        XCTAssertEqual(wc.history?.view.frame.width ?? 0, s.historyWidth, accuracy: 1.5, "the history's own width, 300 to start with")
        XCTAssertEqual(wc.columnLeft ?? 0, (wc.window?.frame.width ?? 0) - s.historyWidth, accuracy: 1.5)
        s.setOutlineShown(true)
        XCTAssertNil(wc.history)
        XCTAssertNotNil(wc.outline)
        XCTAssertFalse(s.historyShown)
        XCTAssertEqual(wc.outline?.view.frame.width ?? 0, s.outlineWidth, accuracy: 1.5)
        s.setOutlineShown(false)
        XCTAssertNil(wc.columnView)
        XCTAssertNil(wc.paneHost)
        XCTAssertTrue(wc.window?.contentView === wc.root)
        XCTAssertEqual(wc.window?.minSize.width ?? 0, wc.baseMinWidth)
    }

    func testAWindowStandingInForAnotherKeepsItsFrameLayoutColumnAndWorkspace() throws {
        let lib = try TempLibrary(["One.md": "# One\n"])
        defer { lib.remove() }
        let settings = isolatedSettings()
        let ws = Workspace.make(settings: settings, notesMode: true)
        ws.setLibraryFolder(lib.url)
        XCTAssertTrue(waitUntil { ws.library.roots.count == 1 })
        let (doc, wc, _) = try open("# Start\n", name: "start.md", settings: settings)
        wc.adopt(ws)
        wc.showWindow(nil)
        doc.session.setLayout(.split)
        doc.session.setViewMode(.live)
        doc.session.setHistoryShown(true)
        let frame = try XCTUnwrap(wc.window).frame
        // What `openNote` does once the old document is settled: the new document's window takes over, then the old closes.
        let next = MarkdownDocument(settings: settings)
        try next.read(from: Data("# One\n".utf8), ofType: "net.daringfireball.markdown")
        next.inheritedWorkspace = ws
        next.makeWindowControllers()
        docs.append(next)
        let nwc = try XCTUnwrap(next.windowControllers.first as? EditorWindowController)
        XCTAssertTrue(nwc.workspace === ws, "the workspace is handed on, not copied")
        nwc.takeOver(from: wc)
        next.showWindows()
        nwc.finishReplacing(doc)
        docs.removeAll { $0 === doc }
        let window = try XCTUnwrap(nwc.window)
        XCTAssertEqual(window.frame.minX, frame.minX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, frame.maxY, accuracy: 1)
        XCTAssertEqual(window.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, frame.height, accuracy: 1)
        XCTAssertEqual(next.session.layout, .split)
        XCTAssertEqual(next.session.viewMode, .live)
        XCTAssertTrue(next.session.historyShown)
        XCTAssertNotNil(nwc.history)
        XCTAssertEqual(window.animationBehavior, .default, "the animation is back once the swap is done")
        XCTAssertTrue(doc.windowControllers.isEmpty, "the old document closed with its window")
        nwc.leaveWorkspace()
    }
}
