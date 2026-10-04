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

    /// Found in the test pass: where the clocks go forward at midnight (Chile, on 6 September 2026) that day starts at
    /// 01:00, and on it the day before was titled with its date: "a day before today's first instant" is 01:00 the
    /// day before, not its start.
    func testYesterdayIsYesterdayWhereTheClocksChangeAtMidnight() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        let iso = ISO8601DateFormatter()
        func v(_ id: UInt64, _ s: String) -> HistoryVersion { version(id, Int64(iso.date(from: s)!.timeIntervalSince1970)) }
        let versions = [v(3, "2026-09-06T14:00:00Z"), v(2, "2026-09-05T14:00:00Z"), v(1, "2026-09-04T14:00:00Z")]
        let en = Locale(identifier: "en_US")
        // On the short day itself.
        XCTAssertEqual(HistoryModel.sections(versions, now: iso.date(from: "2026-09-06T15:00:00Z")!, calendar: santiago, locale: en).map(\.title).prefix(2),
                       ["Today", "Yesterday"])
        // And the day after it.
        XCTAssertEqual(HistoryModel.sections(versions, now: iso.date(from: "2026-09-07T15:00:00Z")!, calendar: santiago, locale: en).map(\.title).prefix(2),
                       ["Yesterday", "Saturday, September 5"])
        // Versions either side of local midnight fall on their own days.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let s = HistoryModel.sections([v(2, "2026-10-03T22:01:00Z"), v(1, "2026-10-03T21:59:00Z")], now: iso.date(from: "2026-10-04T10:00:00Z")!, calendar: berlin, locale: en)
        XCTAssertEqual(s.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(s.map(\.versions.count), [1, 1])
    }

    /// Found in the test pass: selecting a version of a 1 MB document with one line changed split both megabyte-long
    /// unchanged stretches into lines on the main thread to show four of them (about 40 ms in a debug build), and built
    /// every changed line's attributes anew (160 ms for a megabyte of changed lines). The stretches' first and last lines
    /// are taken without splitting them now. Lines are split on the byte: split on the `Character` "\n", a CRLF text
    /// was one line ("\r\n" is one character), its lines run together under one mark.
    func testALongStretchShowsItsContextWithoutBeingSplitAndLineEndingsAreRight() {
        let n = 50_000
        let crlf = (1...n).map { "line \($0)" }.joined(separator: "\r\n")   // no final newline
        let lf = (1...n).map { "line \($0)\n" }.joined()
        let hunks = [HistoryHunk(kind: .equal, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: lf),
                     HistoryHunk(kind: .removed, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: "old\r\nold 2\r\n"),
                     HistoryHunk(kind: .added, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: "new"),
                     HistoryHunk(kind: .equal, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: crlf)]
        _ = HistoryModel.diffText([hunks[1]], style: style())   // the fonts made once, outside the timing
        let started = Date()
        let s = HistoryModel.diffText(hunks, style: style()).string
        let ms = Date().timeIntervalSince(started) * 1000
        XCTAssertEqual(s, "  \u{22EF} 49998 unchanged lines\n  line 49999\n  line 50000\n\u{2212} old\n\u{2212} old 2\n+ new\n  line 1\n  line 2\n  \u{22EF} 49998 unchanged lines\n")
        XCTAssertLessThan(ms, 30, "the stretches are not split into lines")
        XCTAssertEqual(HistoryModel.lineCount(crlf), n)
        XCTAssertEqual(HistoryModel.lineCount(lf), n)
        XCTAssertEqual(HistoryModel.lineCount("a\n\n"), 2)
        XCTAssertEqual(HistoryModel.firstLines("a\n\nb\n", 2), ["a", ""])
        XCTAssertEqual(HistoryModel.lastLines("a\n\nb\n", 2), ["", "b"])
        XCTAssertEqual(HistoryModel.lastLines("a\nb", 1), ["b"])
        // Short stretches are shown whole, as the full split gives them.
        for text in ["a\n", "a\nb", "\n", "a\r\n\r\nb\r\n", "x\ny\nz\nw\nv\n"] {
            let h = [HistoryHunk(kind: .added, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: "+\n"),
                     HistoryHunk(kind: .equal, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: text),
                     HistoryHunk(kind: .added, oldRange: Utf16Range(start: 0, end: 0), newRange: Utf16Range(start: 0, end: 0), text: "+\n")]
            let whole = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let ls = whole.last == "" ? Array(whole.dropLast()) : whole
            XCTAssertEqual(HistoryModel.diffText(h, style: style()).string, "+ +\n" + ls.map { "  \($0)\n" }.joined() + "+ +\n", text.debugDescription)
        }
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

    /// Found in the test pass: a note opened and left without a change recorded the text it was opened with (reason
    /// close), so looking through notes in the sidebar gave each one a history. 3.15: an unchanged document records
    /// nothing.
    func testANoteLookedAtAndLeftUnchangedGetsNoHistory() throws {
        let (doc, wc, _) = try open("# Looked at\n")
        var allowed: Bool?
        doc.settleForLeaving { allowed = $0 }
        XCTAssertTrue(waitUntil { allowed != nil })
        doc.textChanged()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        var saved = false
        doc.save(to: try XCTUnwrap(doc.fileURL), ofType: "net.daringfireball.markdown", for: .saveOperation) { _ in saved = true }
        XCTAssertTrue(waitUntil { saved })
        service.flush()
        XCTAssertEqual(service.versionsNow(key: try XCTUnwrap(doc.historyKey)).count, 0, "leaving, a pause and ⌘S on an unchanged text record nothing")
        // Typing something and taking it back is unchanged too.
        type("x", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))   // the undo group closes
        doc.undoManager?.undo()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        service.flush()
        XCTAssertEqual(service.versionsNow(key: try XCTUnwrap(doc.historyKey)).count, 0)
        // The first real change records the opening text, then the change.
        type("y", in: wc)
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "").count == 2 })
        XCTAssertEqual(service.versionsNow(key: try XCTUnwrap(doc.historyKey)).map(\.reason), [.pause, .close])
    }

    /// Found in the test pass: typing that went on in the same place after an autosave was coalesced into the undo
    /// group the write had already counted, so the document never became edited again. The next pause snapshotted the
    /// text but did not write it, and closing wrote nothing: the file kept the text of the first pause. A write now
    /// breaks the typing's coalescing, as AppKit advises (and TextEdit does for its autosaves).
    func testTypingOnAfterAnAutosaveIsWrittenAtTheNextPauseAndOnLeaving() throws {
        let (doc, wc, url) = try open("one\n")
        type("a", in: wc)
        XCTAssertTrue(waitUntil { !doc.isDocumentEdited && self.onDisk(url) == "one\na" })
        type("b", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(doc.isDocumentEdited, "a key after a write is a change to write")
        XCTAssertTrue(waitUntil { self.onDisk(url) == "one\nab" }, "written at the next pause")
        type("c", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        var allowed: Bool?
        doc.settleForLeaving { allowed = $0 }
        XCTAssertTrue(waitUntil { allowed != nil })
        XCTAssertEqual(onDisk(url), "one\nabc", "and on leaving")
        // Undo still works, a write at a time.
        doc.undoManager?.undo()
        XCTAssertEqual(doc.session.text, "one\nab")
    }

    /// Keys a little closer together than the pause are never written while they come; the write follows the pause
    /// after the last one. And typing that never pauses is still written by NSDocument's own ceiling.
    func testTypingThatNeverPausesWaitsForThePauseOrTheCeiling() throws {
        MarkdownDocument.autosaveDelay = 0.6
        let ceiling = NSDocumentController.shared.autosavingDelay
        NSDocumentController.shared.autosavingDelay = 3
        defer { NSDocumentController.shared.autosavingDelay = ceiling }
        let (doc, wc, url) = try open("p\n")
        for i in 0..<6 {
            type("\(i)", in: wc)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            XCTAssertEqual(onDisk(url), "p\n", "key \(i): not written while the keys come faster than the pause")
        }
        let last = Date()
        XCTAssertTrue(waitUntil { self.onDisk(url).hasSuffix("5") })
        XCTAssertGreaterThan(Date().timeIntervalSince(last), 0.25, "written a pause after the last key")
        XCTAssertEqual(doc.writesOnMainThread.count, 1)
        // The ceiling: keys every 0.3 s with a pause of 0.6 s never pause, and the ceiling (3 s here) writes anyway,
        // again and again (each write breaks the typing's coalescing, so the keys after it are a change again).
        var seen: Set<String> = [onDisk(url)]
        for i in 0..<30 {
            type("\(i % 10)", in: wc)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            seen.insert(onDisk(url))
        }
        XCTAssertGreaterThanOrEqual(seen.count - 1, 2, "the ceiling wrote at least twice in 9 s of typing that never paused")
    }

    /// Found in the test pass: another app putting back an older copy of the file with its own date (`cp -p`, `rsync
    /// -t`, a backup restored) was not seen (only a newer date was); the next autosave then met NSDocument's own
    /// "changed by another application" refusal instead of the read-again and the bar.
    func testAnOlderCopyPutBackByAnotherAppIsReadAgainNotOverwritten() throws {
        let (doc, wc, url) = try open("mine\n")
        type("more", in: wc)
        XCTAssertTrue(waitUntil { !doc.isDocumentEdited && self.onDisk(url) == "mine\nmore" })
        type(" unsaved", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        try Data("from the backup\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
        XCTAssertTrue(doc.handleExternalChange())
        XCTAssertEqual(doc.session.text, "from the backup\n")
        XCTAssertEqual(onDisk(url), "from the backup\n")
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: doc.historyKey ?? "").first.map { self.service.textNow(key: doc.historyKey ?? "", id: $0.id) } == "from the backup\n" })
        let v = service.versionsNow(key: try XCTUnwrap(doc.historyKey))
        XCTAssertEqual(v.dropFirst().first?.message, "Before another app changed this file")
        XCTAssertEqual(service.textNow(key: try XCTUnwrap(doc.historyKey), id: v[1].id), "mine\nmore unsaved")
        XCTAssertFalse(doc.handleExternalChange(), "known now")
    }

    /// Found in the test pass: a key that reached the old window after it had been settled for a note to replace it
    /// (while the note was being read, or the old one's own write finished) was dropped when the old document closed.
    func testAKeyAfterSettlingIsWrittenBeforeTheReplacedDocumentCloses() throws {
        let settings = isolatedSettings()
        let (doc, wc, url) = try open("leaving\n", settings: settings)
        type(" first", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        var allowed: Bool?
        doc.settleForLeaving { allowed = $0 }
        XCTAssertTrue(waitUntil { allowed != nil })
        XCTAssertEqual(onDisk(url), "leaving\n first")
        type(" late", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let next = MarkdownDocument(settings: settings)
        try next.read(from: Data("# Next\n".utf8), ofType: "net.daringfireball.markdown")
        next.makeWindowControllers()
        docs.append(next)
        let nwc = try XCTUnwrap(next.windowControllers.first as? EditorWindowController)
        nwc.takeOver(from: wc)
        nwc.finishReplacing(doc)
        docs.removeAll { $0 === doc }
        XCTAssertTrue(waitUntil { self.onDisk(url) == "leaving\n first late" })
        XCTAssertTrue(waitUntil { doc.windowControllers.isEmpty }, "and then it closed")
        XCTAssertTrue(waitUntil { self.service.versionsNow(key: HistoryKey.key(forFile: url)).first.map { self.service.textNow(key: HistoryKey.key(forFile: url), id: $0.id) } == "leaving\n first late" })
    }

    /// Fifty replacements of a window's document (what a click in the sidebar does once the old one is settled): one
    /// window throughout, at the first one's frame, with its workspace, layout and column, and every document, window
    /// controller and session that left freed.
    func testFiftyReplacementsKeepOneWindowAndFreeEveryDocumentThatLeft() throws {
        let lib = try TempLibrary(["One.md": "# One\n"])
        defer { lib.remove() }
        let settings = isolatedSettings()
        let ws = Workspace.make(settings: settings, notesMode: true)
        ws.setLibraryFolder(lib.url)
        XCTAssertTrue(waitUntil { ws.library.roots.count == 1 })
        var gone: [() -> AnyObject?] = []
        var current: (MarkdownDocument, EditorWindowController)?
        var frame = NSRect.zero
        try autoreleasepool {
            let (doc, wc, _) = try open("# Start\n", name: "start.md", settings: settings)
            wc.adopt(ws)
            wc.showWindow(nil)
            doc.session.setLayout(.split)
            doc.session.setOutlineShown(true)
            frame = try XCTUnwrap(wc.window).frame
            current = (doc, wc)
            docs.removeAll { $0 === doc }
        }
        for i in 0..<50 {
            try autoreleasepool {
                let (doc, wc) = try XCTUnwrap(current)
                let next = MarkdownDocument(settings: settings)
                try next.read(from: Data("# Note \(i)\n".utf8), ofType: "net.daringfireball.markdown")
                next.inheritedWorkspace = ws
                next.makeWindowControllers()
                let nwc = try XCTUnwrap(next.windowControllers.first as? EditorWindowController)
                nwc.takeOver(from: wc)
                next.showWindows()
                nwc.finishReplacing(doc)
                weak let d = doc, c = wc, s = doc.session
                gone += [{ d }, { c }, { s }]
                current = (next, nwc)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        let (doc, wc) = try XCTUnwrap(current)
        docs.append(doc)
        XCTAssertTrue(waitUntil { gone.allSatisfy { $0() == nil } }, "\(gone.filter { $0() != nil }.count) of \(gone.count) still alive")
        let window = try XCTUnwrap(wc.window)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(doc.session.layout, .split)
        XCTAssertTrue(doc.session.outlineShown)
        XCTAssertTrue(wc.workspace === ws)
        XCTAssertEqual(NSApp.windows.filter { $0.isVisible && $0.windowController is EditorWindowController }.count, 1)
        wc.leaveWorkspace()
        ws.library.stopObserving(ws)
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
        // The pause's write is over (it snapshots the text as it is when it starts, which could otherwise be the next keys).
        XCTAssertTrue(waitUntil { !doc.isDocumentEdited && doc.savesInFlight == 0 })
        type(" and unsaved", in: wc)
        // The key's undo group closes before the click on Restore, as between two events. (Typing after a write is a
        // group of its own now, so without this the restore would join the key's group and one undo would take both.)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
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

    func testTheOutlineAndTheHistoryShareOneColumnWithOneWidthAndOneToggle() throws {
        let (doc, wc, _) = try open("# A\n\ntext\n")
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: 1000, height: 700))
        let s = doc.session
        s.setOutlineShown(true)
        XCTAssertNotNil(wc.outline)
        XCTAssertNil(wc.history)
        let width = wc.columnView?.frame.width ?? 0
        s.setHistoryShown(true)
        XCTAssertNil(wc.outline, "the outline gives the content area up")
        XCTAssertNotNil(wc.history)
        XCTAssertFalse(s.outlineShown)
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, width, accuracy: 0.5, "one width: switching panes leaves it")
        XCTAssertEqual(wc.columnLeft ?? 0, (wc.window?.frame.width ?? 0) - s.columnWidth, accuracy: 1.5)
        s.setOutlineShown(true)
        XCTAssertNil(wc.history)
        XCTAssertNotNil(wc.outline)
        XCTAssertFalse(s.historyShown)
        XCTAssertEqual(wc.columnView?.frame.width ?? 0, width, accuracy: 0.5)
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
        // The title is the new document's, and clean.
        XCTAssertEqual(nwc.titleView.name, window.title)
        XCTAssertEqual(nwc.titleView.fileURL, next.fileURL)
        XCTAssertFalse(nwc.titleView.edited)
    }

    // MARK: from the M8f test pass: edits that change no text, and the title's "Edited"

    /// The title says "Edited" exactly while the document is (checked after every turn of the run loop until `until`).
    private func titleFollows(_ doc: MarkdownDocument, _ wc: EditorWindowController, for seconds: TimeInterval,
                              file: StaticString = #filePath, line: UInt = #line) {
        let end = Date(timeIntervalSinceNow: seconds)
        var mismatches = 0
        while Date() < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            // The title catches up within its own short look after an edit (50 ms): compare after it.
            if wc.titleView.edited != doc.isDocumentEdited {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
                if wc.titleView.edited != doc.isDocumentEdited { mismatches += 1 }
            }
        }
        XCTAssertEqual(mismatches, 0, "the title's Edited is the document's state", file: file, line: line)
    }

    func testMarkAsChangesNoTextAndIsStillWrittenWithinThePause() throws {
        let (doc, wc, url) = try open("one two three\n", name: "mark.md")
        wc.showWindow(nil)
        wc.textView.setSelectedRange(NSRange(location: 4, length: 3))
        wc.textView.markAsAI(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(doc.session.text, "one two three\n", "Mark As changes no text")
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertTrue(wc.titleView.edited)
        XCTAssertTrue(doc.autosaveTimer?.isValid ?? false, "the pause's timer runs for it")
        XCTAssertTrue(waitUntil(3) { self.onDisk(url).contains("Annotations:") && !doc.isDocumentEdited }, "written within the pause, with its marks")
        titleFollows(doc, wc, for: 0.2)
        XCTAssertFalse(wc.titleView.edited)
        // Undone: the marks go from the file at the next pause too.
        doc.undoManager?.undo()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertTrue(wc.titleView.edited, "undo past the write: edited again")
        XCTAssertTrue(waitUntil(3) { self.onDisk(url) == "one two three\n" && !doc.isDocumentEdited })
        titleFollows(doc, wc, for: 0.2)
    }

    func testADiscardedAuthorshipCheckIsWrittenWithinThePause() throws {
        let fixture = try Data(contentsOf: Fixtures.fixtureDir.appendingPathComponent("authorship").appendingPathComponent("mismatch.md"))
        let (doc, wc, url) = try open(String(decoding: fixture, as: UTF8.self), name: "mismatch.md")
        XCTAssertNotNil(doc.session.pendingAuthorshipDecision)
        XCTAssertFalse(wc.titleView.edited)
        doc.session.resolveAuthorshipDecision(keep: false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertTrue(wc.titleView.edited)
        XCTAssertTrue(waitUntil(3) { !self.onDisk(url).contains("SHA-256") && !doc.isDocumentEdited }, "the file without its marks, within the pause")
        titleFollows(doc, wc, for: 0.2)
        XCTAssertFalse(wc.titleView.edited)
    }

    func testAFormatToggleWithNothingSelectedIsWrittenWithinThePause() throws {
        let (doc, wc, url) = try open("one two three\n", name: "format.md")
        for (caret, toggle) in [(5, #selector(EditorTextView.toggleStrong(_:))), (0, #selector(EditorTextView.toggleEmphasis(_:))),
                                (14, #selector(EditorTextView.toggleInlineCode(_:)))] {
            let before = onDisk(url)
            wc.textView.setSelectedRange(NSRange(location: min(caret, doc.session.storage.length), length: 0))
            wc.textView.perform(toggle, with: nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            guard doc.isDocumentEdited else { continue }   // nothing to toggle there: nothing owed
            XCTAssertTrue(wc.titleView.edited)
            XCTAssertTrue(waitUntil(3) { self.onDisk(url) != before && !doc.isDocumentEdited }, "\(toggle) written within the pause")
            XCTAssertEqual(onDisk(url), doc.session.text)
            titleFollows(doc, wc, for: 0.1)
        }
        XCTAssertNotEqual(onDisk(url), "one two three\n", "at least one toggle changed the text")
    }

    func testTheTitlesEditedFollowsSaveUndoPastTheSaveAndTheAutosave() throws {
        let (doc, wc, url) = try open("s\n", name: "title.md")
        wc.showWindow(nil)
        XCTAssertFalse(wc.titleView.edited)
        type("x", in: wc)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(wc.titleView.edited)
        // ⌘S before the pause.
        var saved = false
        doc.save(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation) { _ in saved = true }
        XCTAssertTrue(waitUntil { saved })
        titleFollows(doc, wc, for: 0.2)
        XCTAssertFalse(wc.titleView.edited, "clean after ⌘S")
        // Undo past the save point: edited again, and written again at the pause.
        doc.undoManager?.undo()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(doc.session.text, "s\n")
        XCTAssertTrue(doc.isDocumentEdited)
        XCTAssertTrue(wc.titleView.edited)
        XCTAssertTrue(waitUntil(3) { self.onDisk(url) == "s\n" && !doc.isDocumentEdited })
        titleFollows(doc, wc, for: 0.2)
        // Redo, and the autosave.
        doc.undoManager?.redo()
        titleFollows(doc, wc, for: 0.1)
        XCTAssertTrue(waitUntil(3) { self.onDisk(url) == "s\nx" && !doc.isDocumentEdited })
        titleFollows(doc, wc, for: 0.2)
        XCTAssertTrue(SystemTitle.views(in: try XCTUnwrap(wc.window)).allSatisfy(\.isHidden), "AppKit's own Edited never shows")
    }

    func testADraftsTitleIsItsNewNameAndItsPathEndsInDrafts() throws {
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
        XCTAssertNil(wc.titleView.pathMenu(), "untitled: no path")
        XCTAssertFalse(wc.titleView.canRename(), "untitled: a double-click zooms, nothing to rename")
        type("A draft.", in: wc)
        XCTAssertTrue(waitUntil { doc.fileURL != nil && !doc.isDocumentEdited })
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let url = try XCTUnwrap(doc.fileURL)
        XCTAssertEqual(try url.resourceValues(forKeys: [.hasHiddenExtensionKey]).hasHiddenExtension, false, "the draft's .md shows, as every other note's does")
        XCTAssertEqual(wc.titleView.name, "Untitled 1.md")
        XCTAssertEqual(wc.window?.title, "Untitled 1.md")
        XCTAssertEqual(wc.window?.representedURL?.lastPathComponent, "Untitled 1.md")
        XCTAssertFalse(wc.titleView.edited)
        let menu = try XCTUnwrap(wc.titleView.pathMenu())
        XCTAssertEqual(menu.items.first?.title, "Drafts")
        XCTAssertEqual(menu.items.dropFirst().first?.title, lib.url.lastPathComponent)
        ws.library.stopObserving(ws)
    }
}
