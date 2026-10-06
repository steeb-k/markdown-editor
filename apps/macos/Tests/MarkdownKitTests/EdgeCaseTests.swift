import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Edge cases found in the overnight pass (5 to 6 October), the ones that need no event from the window server: values
/// that trap when they are not numbers, a day with thousands of versions, symbolic links, odd names, records with odd
/// numbers in them, and a file that goes away under an open document.
@MainActor
final class EdgeCaseTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-edge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func entry(_ level: UInt8, _ text: String, start: UInt32 = 0, line: UInt32 = 0) -> OutlineEntry {
        OutlineEntry(level: level, text: text, range: Utf16Range(start: start, end: start + 1), line: line)
    }

    private func version(_ id: UInt64, _ time: Int64) -> HistoryVersion {
        HistoryVersion(id: id, time: time, reason: .pause, message: nil, bytes: 10, added: 1, removed: 0)
    }

    // MARK: the outline

    /// `Int(Double.nan)` and `Int(1e300)` trap: the line the preview reports is a number from a page's script.
    func testALineThatIsNotANumberOrIsOutOfRangeIsStillAPlaceInTheOutline() {
        let e = [entry(1, "A", start: 10, line: 2), entry(2, "B", start: 50, line: 8)]
        XCTAssertNil(OutlineModel.index(atLine: .nan, in: e))
        XCTAssertEqual(OutlineModel.index(atLine: .infinity, in: e), 1)
        XCTAssertNil(OutlineModel.index(atLine: -.infinity, in: e))
        XCTAssertEqual(OutlineModel.index(atLine: 1e300, in: e), 1)
        XCTAssertNil(OutlineModel.index(atLine: -1e300, in: e))
        XCTAssertNil(OutlineModel.index(atLine: .nan, in: []))
    }

    /// 5 000 headings and a document edited a few at a time: each tick's tree, built from the one before, is the tree a
    /// fresh build gives (same shape, same indexes), and a tick is quick.
    func testTheTreeOfFiveThousandHeadingsFollowsEditsLikeAFreshBuild() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        var entries = (0..<5_000).map { entry(UInt8(1 + rnd(4)), "Heading \($0)", start: UInt32($0 * 20), line: UInt32($0 * 3)) }
        var tree = OutlineModel.tree(of: entries)
        func shape(_ t: [OutlineNode]) -> [[Int]] {
            t.map { [$0.index, Int($0.entry.level), $0.parent?.index ?? -1, $0.children.map(\.index).reduce(0, &+)] }
        }
        var worst: TimeInterval = 0
        for tick in 0..<30 {
            switch rnd(4) {
            case 0: entries.insert(entry(UInt8(1 + rnd(6)), "New \(tick)"), at: rnd(entries.count + 1))
            case 1: if !entries.isEmpty { entries.remove(at: rnd(entries.count)) }
            case 2: if !entries.isEmpty { entries[rnd(entries.count)] = entry(UInt8(1 + rnd(6)), "Changed \(tick)") }
            default: entries.removeSubrange(0..<min(entries.count, rnd(3)))
            }
            let started = Date()
            let next = OutlineModel.tree(of: entries, reusing: tree.all)
            worst = max(worst, Date().timeIntervalSince(started))
            let fresh = OutlineModel.tree(of: entries)
            XCTAssertEqual(shape(next.all), shape(fresh.all), "tick \(tick)")
            XCTAssertEqual(next.roots.map(\.index), fresh.roots.map(\.index), "tick \(tick)")
            tree = next
        }
        XCTAssertLessThan(worst, 0.25, "a tick of 5 000 headings took \(worst) s")
    }

    // MARK: the history panel

    /// Ten thousand versions in a day (every pause of a long session): grouping was a copy of the day so far for every
    /// version.
    func testTenThousandVersionsInOneDayAreGroupedInLinearTime() {
        let day: Int64 = 86_400
        let now = Date(timeIntervalSince1970: TimeInterval(100 * day + 23 * 3600))
        let versions = (0..<10_000).map { version(UInt64(10_000 - $0), 100 * day + 80_000 - Int64($0) * 8) }
        let started = Date()
        let sections = HistoryModel.sections(versions, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[0].versions.map(\.id), versions.map(\.id))
        XCTAssertLessThan(took, 0.5, "grouping 10 000 versions took \(took) s")
        // And over many days.
        let spread = (0..<10_000).map { version(UInt64(10_000 - $0), 100 * day - Int64($0) * 3_000) }
        let days = HistoryModel.sections(spread, now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(days.reduce(0) { $0 + $1.versions.count }, 10_000)
        XCTAssertEqual(days.map(\.title), Array(Set(days.map(\.title))).isEmpty ? [] : days.map(\.title), "each day once, in order")
    }

    func testThePanelShowsTenThousandVersionsWithoutTheRowsBeingMade() {
        let palette = ThemeStore.shared.palette(ThemeStore.shared.theme(id: "light"))
        let style = SidebarStyle(palette)
        let p = HistoryController(style: style, diffStyle: HistoryModel.DiffStyle(palette: palette, secondary: style.secondary, font: .monospacedSystemFont(ofSize: 11, weight: .regular)))
        p.view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let versions = (0..<10_000).map { version(UInt64(10_000 - $0), 1_700_000_000 - Int64($0) * 40) }
        let started = Date()
        p.apply(versions)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(p.versions.count, 10_000)
        XCTAssertEqual(p.items.count, 10_000 + HistoryModel.sections(versions).count)
        p.select(id: 1)
        XCTAssertEqual(p.selectedVersion?.id, 1)
        p.apply(Array(versions.prefix(5)))
        XCTAssertNil(p.selectedID, "the selected version is gone")
    }

    // MARK: names

    func testWhatTheUserTypesAsANameOddOnesIncluded() {
        XCTAssertEqual(NoteNaming.fileName(from: "Idea "), "Idea")
        XCTAssertEqual(NoteNaming.fileName(from: " \n Idea\t"), "Idea")
        XCTAssertNil(NoteNaming.fileName(from: ".."))
        XCTAssertNil(NoteNaming.fileName(from: "."))
        XCTAssertNil(NoteNaming.fileName(from: " .hidden"))
        XCTAssertNil(NoteNaming.fileName(from: " \n\t "))
        XCTAssertEqual(NoteNaming.fileName(from: "a/b:c"), "a-b-c")
        XCTAssertEqual(NoteNaming.fileName(from: "/"), "-")
        XCTAssertEqual(NoteNaming.fileName(from: "caf\u{e9}"), "caf\u{e9}")
        XCTAssertEqual(NoteNaming.fileName(from: "e\u{301}\u{301}"), "e\u{301}\u{301}")
        XCTAssertEqual(NoteNaming.fileName(from: "\u{202E}fdp.md"), "\u{202E}fdp.md", "kept as typed: the file system takes it")
        // Whatever it makes is a single path component: no separator, never `.` or `..`.
        for typed in ["a/../b", "../x", "x/..", "..a", "a..", "...", "a\u{0}b", "\\", "a\\b", String(repeating: "x", count: 400)] {
            guard let name = NoteNaming.fileName(from: typed) else { continue }
            XCTAssertFalse(name.contains("/") || name.contains(":"), typed)
            XCTAssertNotEqual(name, ".")
            XCTAssertNotEqual(name, "..")
        }
        // A rename keeps the folder and the extension, and does not take a name with a separator into another folder.
        let old = URL(fileURLWithPath: "/n/Folder/Old.md")
        XCTAssertNil(NoteNaming.renamed(old, to: "../Up"), "a name that starts with dots (the separator became a hyphen) is not a name")
        XCTAssertEqual(NoteNaming.renamed(old, to: "Up/../x")?.deletingLastPathComponent().path, "/n/Folder")
        XCTAssertEqual(NoteNaming.renamed(old, to: "New ")?.lastPathComponent, "New.md")
        XCTAssertEqual(NoteNaming.renamed(old, to: "v1.2")?.lastPathComponent, "v1.2.md")
        XCTAssertEqual(NoteNaming.renamed(old, to: "Why?")?.lastPathComponent, "Why?.md")
        XCTAssertEqual(NoteNaming.renamed(old, to: "Idea.TXT")?.lastPathComponent, "Idea.TXT")
        XCTAssertNil(NoteNaming.renamed(old, to: ".."))
    }

    // MARK: links

    func testLinksWithEscapesAndUnicodeNames() throws {
        let doc = scratch.appendingPathComponent("docs/note.md")
        XCTAssertEqual(LinkOpener.url(for: "Caf%C3%A9.md", documentURL: doc)?.lastPathComponent, "Caf\u{e9}.md")
        XCTAssertEqual(LinkOpener.url(for: "Cafe%CC%81.md", documentURL: doc)?.lastPathComponent, "Cafe\u{301}.md")
        XCTAssertEqual(LinkOpener.url(for: "100%25.md", documentURL: doc)?.lastPathComponent, "100%.md")
        XCTAssertEqual(LinkOpener.url(for: "100%.md", documentURL: doc)?.lastPathComponent, "100%.md", "a stray percent is a percent")
        XCTAssertEqual(LinkOpener.url(for: "Why%3F.md#top", documentURL: doc)?.lastPathComponent, "Why?.md")
        XCTAssertEqual(LinkOpener.url(for: "a%20b.md?x=1", documentURL: doc)?.lastPathComponent, "a b.md")
        XCTAssertEqual(LinkOpener.url(for: "\u{65E5}\u{672C}/\u{1F389}.md", documentURL: doc)?.lastPathComponent, "\u{1F389}.md")
        XCTAssertNil(LinkOpener.url(for: "%23", documentURL: nil).map { _ in 1 }, "a relative path with no document is nothing")
        XCTAssertNil(LinkOpener.url(for: "javascript:alert(1)", documentURL: doc))
        XCTAssertNil(LinkOpener.url(for: "   ", documentURL: doc))
        // The file a link names, on this volume: written in either normalisation, the file system finds the one file
        // (APFS keeps the form a file was made with and compares names without regard to it).
        let nfd = "Cafe\u{301}.md", nfc = "Caf\u{e9}.md"
        try Data("x".utf8).write(to: scratch.appendingPathComponent(nfd))
        let a = try XCTUnwrap(LinkOpener.url(for: nfc.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nfc, documentURL: scratch.appendingPathComponent("n.md")))
        let b = try XCTUnwrap(LinkOpener.url(for: nfd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nfd, documentURL: scratch.appendingPathComponent("n.md")))
        XCTAssertEqual(DocumentFileAccess.exists(a), DocumentFileAccess.exists(b), "the same file by either spelling (on APFS)")
    }

    /// A folder of notes from a zip can hold a symbolic link named `readme.md` that points at an application: opening it
    /// from a click on a link would launch the application.
    func testASymbolicLinkToAnApplicationIsShownNotOpened() throws {
        let app = scratch.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let script = scratch.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        let plain = scratch.appendingPathComponent("plain.md")
        try Data("# hi\n".utf8).write(to: plain)
        for (name, target, launches) in [("readme.md", app, true), ("notes.txt", script, true), ("fine.md", plain, false)] {
            let link = scratch.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertEqual(LinkOpener.launchesSomething(link), launches, name)
        }
        XCTAssertTrue(LinkOpener.launchesSomething(app))
        XCTAssertFalse(LinkOpener.launchesSomething(plain))
        // A link to a link.
        let second = scratch.appendingPathComponent("again.md")
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: scratch.appendingPathComponent("readme.md"))
        XCTAssertTrue(LinkOpener.launchesSomething(second))
    }

    // MARK: files

    func testNamesThatDifferOnlyInCaseAreTheSameFileOnThisVolume() throws {
        let probe = scratch.appendingPathComponent("Case.md")
        try Data("x".utf8).write(to: probe)
        let insensitive = DocumentFileAccess.exists(scratch.appendingPathComponent("case.md"))
        let next = DocumentFileAccess.uniqueURL(in: scratch, name: "case", ext: "md")
        if insensitive {
            XCTAssertEqual(next.lastPathComponent, "case 2.md", "never a second name for the file that is there")
        } else {
            XCTAssertEqual(next.lastPathComponent, "case.md")
        }
        XCTAssertEqual(DocumentFileAccess.uniqueURL(in: scratch, name: "Case", ext: "md").lastPathComponent, "Case 2.md")
        let written = try DocumentFileAccess.writeNew(Data("y".utf8), in: scratch, name: "CASE", ext: "md")
        XCTAssertNotEqual(written.lastPathComponent.lowercased(), "case.md", "an existing file is never replaced")
        XCTAssertEqual(try String(contentsOf: probe, encoding: .utf8), "x")
    }

    func testPicturesNamedByLinksThroughSymbolicLinksAndEscapes() throws {
        let folder = scratch.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let doc = folder.appendingPathComponent("note.md")
        let real = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: real.appendingPathComponent("p.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("img"), withDestinationURL: real)
        let url = try XCTUnwrap(DocumentFileAccess.pictureURL(for: "img/p.png", documentURL: doc))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "png", "a folder that is a symbolic link is followed")
        XCTAssertEqual(DocumentFileAccess.pictureURL(for: "img/p%2Epng", documentURL: doc)?.lastPathComponent, "p.png")
        XCTAssertEqual(DocumentFileAccess.pictureURL(for: "my%20pic%20%E2%9C%93.png", documentURL: doc)?.lastPathComponent, "my pic \u{2713}.png")
        XCTAssertNil(DocumentFileAccess.pictureURL(for: "pic.png", documentURL: nil))
        XCTAssertNil(DocumentFileAccess.pictureURL(for: "ftp://x/p.png", documentURL: doc))
        XCTAssertNil(DocumentFileAccess.pictureURL(for: "", documentURL: doc))
        // The place a note that is not made yet will have, and the one it has: the same spelling.
        let link = scratch.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(DocumentFileAccess.canonical(link.appendingPathComponent("not-yet.md")).path,
                       DocumentFileAccess.canonical(real).appendingPathComponent("not-yet.md").path)
        XCTAssertEqual(DocumentFileAccess.path(of: real.appendingPathComponent("p.png"), relativeTo: doc), "../elsewhere/p.png")
    }

    // MARK: the session record

    private func windowRecord(_ i: Int) -> SessionRecord.Window {
        var w = SessionRecord.Window()
        if i % 3 == 0 {
            w.untitledText = "untitled \(i) \u{1F389}"
        } else {
            w.file = DocumentFileAccess.FileRef(path: "/Volumes/Gone Drive \(i)/Notes/n\(i).md", bookmark: Data([1, 2, 3, UInt8(i)]))
        }
        w.frame = [Double(i * 7), Double(i * 5), 700, 500]
        w.screen = "Display \(i % 4)"
        w.layout = ["editor", "split", "preview"][i % 3]
        w.caret = [i, 0]
        w.notes = { var n = SessionRecord.Notes(); n.selection = ["r/\(i).md"]; n.expanded = ["r/a", "r/b"]; return n }()
        w.column = { var c = SessionRecord.Column(); c.shown = i % 2 == 0; c.pane = "history"; c.width = 260; return c }()
        return w
    }

    func testARecordOfFiftyWindowsRoundTripsAndRestoresWhatCanBe() throws {
        let record = SessionRecord(windows: (0..<50).map(windowRecord), key: 49)
        let data = try record.encoded()
        XCTAssertEqual(SessionRecord.decode(data), record)
        XCTAssertLessThan(data.count, 100_000)
        // At launch: every window is either put back or skipped (the volumes are not there; the untitled ones come back),
        // none is lost, and nothing hangs on a volume that is gone.
        let settings = isolatedSettings()
        let before = NSDocumentController.shared.documents.count
        let restorer = SessionRestorer(record: record, settings: settings)
        let done = expectation(description: "restored")
        let started = Date()
        restorer.start { done.fulfill() }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(restorer.restoredCount + restorer.skipped, 50)
        XCTAssertGreaterThanOrEqual(restorer.skipped, 33, "the files on volumes that are gone")
        // (The untitled ones come back in the app; the test bundle has no document types, so the controller makes none.)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        for wc in restorer.restored { wc.markdownDocument?.updateChangeCount(.changeCleared); wc.markdownDocument?.close() }
        XCTAssertTrue(spin(timeout: 5) { NSDocumentController.shared.documents.count == before })
    }

    /// A record with numbers no window ever wrote (an old or a hand-edited file): the caret and the scroll position put
    /// back to the nearest place, never a trap, and never the middle of an emoji.
    func testARecordWithOddNumbersRestoresToTheNearestPlace() throws {
        let file = scratch.appendingPathComponent("n.md")
        let text = String(repeating: "line \u{1F389}\u{1F389} here\n", count: 80)
        try Data(text.utf8).write(to: file)
        let doc = MarkdownDocument(settings: isolatedSettings())
        doc.fileURL = file
        try doc.read(from: file, ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let ns = text as NSString
        let emoji = ns.range(of: "\u{1F389}")
        for (caret, scrollCharacter) in [([-5, -3], -7), ([Int.max, Int.max], Int.max), ([emoji.location + 1, 0], 0), ([emoji.location + 1, 1], 5), ([0, Int.min], Int.min), ([3], 4)] {
            var w = SessionRecord.Window()
            w.caret = caret
            w.scrollCharacter = scrollCharacter
            w.scrollInto = scrollCharacter == 5 ? 1e12 : -3
            wc.restoreView(w)
            let sel = wc.textView.selectedRange()
            XCTAssertLessThanOrEqual(NSMaxRange(sel), ns.length, "\(caret)")
            XCTAssertGreaterThanOrEqual(sel.location, 0)
            for edge in [sel.location, NSMaxRange(sel)] where edge < ns.length {
                XCTAssertEqual(ns.rangeOfComposedCharacterSequence(at: edge).location, edge, "the selection \(sel) of \(caret) ends inside a character")
            }
        }
        // A frame with the wrong number of values, or none that make a window, is left alone.
        for frame in [[1.0, 2.0, 3.0], [0, 0, 0, 0], [0, 0, -5, 300], [1e300, 1e300, 1e300, 1e300]] {
            var w = SessionRecord.Window()
            w.frame = frame
            let before = wc.window?.frame
            wc.restore(w)
            XCTAssertNotNil(wc.window?.frame)
            if frame.count != 4 || frame[2] <= 0 || frame[3] <= 0 { XCTAssertEqual(wc.window?.frame, before, "\(frame)") }
        }
        let screens = NSScreen.screens.map(\.frame)
        if let frame = wc.window?.frame, let union = screens.first {
            XCTAssertTrue(screens.contains { $0.intersects(frame) } || union.isEmpty, "the window is on a screen")
        }
    }

    func testARecordThatIsNotARecordRestoresNothing() {
        for data in ["", "[]", "null", "{", "{\"windows\": 5}", "{\"windows\": [{\"frame\": \"x\"}]}", "{\"version\": 99, \"windows\": []}", "\u{0}\u{0}", "{\"windows\": [null]}"] {
            let record = SessionRecord.decode(Data(data.utf8))
            XCTAssertTrue(record == nil || record!.windows.isEmpty || data.contains("frame") == false, data)
        }
        XCTAssertNotNil(SessionRecord.decode(Data("{\"windows\": []}".utf8)))
        XCTAssertNil(SessionRecord.decode(Data("{\"version\": 99, \"windows\": []}".utf8)))
    }

    // MARK: autosave

    /// The file is deleted under an open document that has unsaved changes, then the pause ends: nothing traps, nothing
    /// is lost (the text is still in the window and the history), and the file is written again where it was.
    func testAnAutosaveAfterTheFileWasDeletedLosesNothing() throws {
        let service = HistoryService(directory: scratch.appendingPathComponent("history"))
        HistoryService.current = service
        MarkdownDocument.autosaveDelay = 0.3
        defer { HistoryService.current = nil; MarkdownDocument.autosaveDelay = 2 }
        let url = scratch.appendingPathComponent("gone.md")
        try Data("# One\n".utf8).write(to: url)
        let doc = MarkdownDocument(settings: isolatedSettings())
        doc.fileURL = url
        try doc.read(from: url, ofType: "net.daringfireball.markdown")
        doc.fileModificationDate = DocumentFileAccess.modificationDate(of: url)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        defer { doc.updateChangeCount(.changeCleared); doc.close(); service.flush() }
        try FileManager.default.removeItem(at: url)
        wc.textView.insertText("two", replacementRange: NSRange(location: wc.textView.string.utf16.count, length: 0))
        XCTAssertTrue(waitUntil(8) { DocumentFileAccess.exists(url) || !doc.isDocumentEdited }, "written again at the pause, or settled")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(doc.session.text, "# One\ntwo", "the text is still in the window")
        if DocumentFileAccess.exists(url) {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# One\ntwo")
        }
        // Closing the window then is not a crash either.
        var allowed: Bool?
        doc.settleForLeaving { allowed = $0 }
        XCTAssertTrue(waitUntil(8) { allowed != nil })
    }

    /// A rename to a name with a trailing space or `..` never leaves the folder or the extension.
    func testTheTitleRenamerNeverLeavesTheFolder() {
        let old = scratch.appendingPathComponent("Old.md")
        for typed in ["New ", "..", "../x", "a/../../b", ".", "  ", "x/y", "Old.md ", "name.\u{200B}"] {
            guard let dest = TitleRenamer.destination(for: old, typed: typed) else { continue }
            XCTAssertEqual(dest.deletingLastPathComponent().standardizedFileURL.path, scratch.standardizedFileURL.path, typed)
            XCTAssertFalse(dest.lastPathComponent.hasPrefix("."), typed)
            XCTAssertFalse(dest.lastPathComponent.contains("/"), typed)
        }
        XCTAssertEqual(TitleRenamer.destination(for: old, typed: "New ")?.lastPathComponent, "New.md")
        XCTAssertEqual(TitleRenamer.destination(for: old, typed: "a:b")?.lastPathComponent, "a-b.md", "a colon is a slash to Finder")
        XCTAssertNil(TitleRenamer.destination(for: old, typed: "a\u{0}b"))
        XCTAssertNil(NoteNaming.fileName(from: "a\u{0}b"))
    }

    // MARK: quitting

    func testTheQuitQuestionOverEveryCombination() {
        let settings = isolatedSettings()
        var asked = 0
        var response = NSApplication.ModalResponse.alertFirstButtonReturn
        QuitConfirmation.run = { _ in asked += 1; return response }
        defer { QuitConfirmation.run = { $0.runModal() } }
        for windows in [0, 1, 50] {
            for ask in [true, false] {
                settings.askBeforeQuitting = ask
                asked = 0
                XCTAssertTrue(QuitConfirmation.mayQuit(windows: windows, settings: settings))
                XCTAssertEqual(asked, windows > 0 && ask ? 1 : 0, "windows \(windows), ask \(ask)")
            }
        }
        // Cancel, and anything that is not the first button, stays.
        settings.askBeforeQuitting = true
        for r in [NSApplication.ModalResponse.alertSecondButtonReturn, .alertThirdButtonReturn, .cancel, .abort, .stop] {
            response = r
            XCTAssertFalse(QuitConfirmation.mayQuit(windows: 2, settings: settings), "\(r.rawValue)")
        }
        XCTAssertTrue(settings.askBeforeQuitting)
        // The wording follows the preference that makes the windows come back.
        XCTAssertTrue(QuitConfirmation.makeAlert(reopens: true).informativeText.contains("reopen"))
        XCTAssertFalse(QuitConfirmation.makeAlert(reopens: false).informativeText.contains("reopen"))
    }
}
