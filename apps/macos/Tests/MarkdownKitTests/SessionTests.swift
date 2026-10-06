import XCTest
import AppKit
@testable import MarkdownKit

final class SessionRecordTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        _ = NSApplication.shared
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        SessionRecorder.current = nil
        QuitConfirmation.run = { $0.runModal() }
        try? FileManager.default.removeItem(at: scratch)
    }

    func testRoundTrip() throws {
        var w = SessionRecord.Window()
        w.file = DocumentFileAccess.makeFileRef(scratch)
        w.frame = [10, 20, 800, 600]
        w.layout = "split"
        w.caret = [4, 2]
        w.scrollCharacter = 120
        w.scrollInto = 3.5
        var n = SessionRecord.Notes()
        n.selection = ["library:Projects"]
        n.expanded = ["library:", "library:Projects"]
        n.sidebarWidth = 300
        w.notes = n
        var u = SessionRecord.Window()
        u.untitledText = "draft"
        let record = SessionRecord(windows: [w, u], key: 1)
        let url = scratch.appendingPathComponent("session.json")
        try record.write(to: url)
        XCTAssertEqual(SessionRecord.read(from: url), record)
        // No temporary file is left beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), ["session.json"])
    }

    func testUnknownKeysAndMissingFieldsAreTolerated() throws {
        let json = #"{"version":1,"future":{"x":1},"key":0,"windows":[{"layout":"split","somethingNew":true}]}"#
        let record = try XCTUnwrap(SessionRecord.decode(Data(json.utf8)))
        XCTAssertEqual(record.windows.count, 1)
        XCTAssertEqual(record.windows[0].layout, "split")
    }

    /// A record from a build that had Live mode names a view mode that no longer exists: it is ignored, and the
    /// window restores as it always does, in the editor's one view.
    func testARecordFromABuildWithLiveModeStillRestores() throws {
        let json = #"{"version":1,"key":0,"windows":[{"layout":"split","viewMode":"live","focus":true}]}"#
        let record = try XCTUnwrap(SessionRecord.decode(Data(json.utf8)))
        XCTAssertEqual(record.windows.count, 1)
        XCTAssertEqual(record.windows[0].layout, "split")
        XCTAssertEqual(record.windows[0].focus, true)
    }

    func testABadFileIsIgnored() {
        XCTAssertNil(SessionRecord.decode(Data("not json".utf8)))
        XCTAssertNil(SessionRecord.decode(Data(#"{"windows":"nope"}"#.utf8)))
        XCTAssertNil(SessionRecord.decode(Data(#"{"version":99,"windows":[]}"#.utf8)))
        let url = scratch.appendingPathComponent("bad.json")
        try? Data("{".utf8).write(to: url)
        XCTAssertNil(SessionRecord.read(from: url))
        XCTAssertNil(SessionRecord.read(from: scratch.appendingPathComponent("absent.json")))
        XCTAssertNil(SessionRestorer.record(for: isolatedSettings(), at: url))
    }

    func testPreferenceOffRestoresNothing() throws {
        var w = SessionRecord.Window()
        w.untitledText = "x"
        let url = scratch.appendingPathComponent("session.json")
        try SessionRecord(windows: [w]).write(to: url)
        let settings = isolatedSettings()
        XCTAssertNotNil(SessionRestorer.record(for: settings, at: url))
        settings.reopenAtLaunch = false
        XCTAssertNil(SessionRestorer.record(for: settings, at: url))
    }

    func testChangesAreCoalescedIntoOneWrite() {
        let recorder = SessionRecorder(url: scratch.appendingPathComponent("session.json"), interval: 0.15)
        recorder.windows = { [] }
        for _ in 0..<20 { recorder.noteChange() }
        XCTAssertEqual(recorder.writes, 0)
        let wrote = expectation(description: "written")
        recorder.onWrite = { _ in wrote.fulfill() }
        wait(for: [wrote], timeout: 2)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertEqual(recorder.writes, 1)
        recorder.onWrite = nil
        // The final write is synchronous and the last.
        recorder.noteChange()
        recorder.writeNow(final: true)
        XCTAssertEqual(recorder.writes, 2)
        recorder.noteChange()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertEqual(recorder.writes, 2)
    }

    func testRestoreReusesAnOpenDocumentAndSkipsAMissingFile() throws {
        let file = scratch.appendingPathComponent("note.md")
        try Data("# hello\n".utf8).write(to: file)
        let settings = isolatedSettings()
        let doc = MarkdownDocument(settings: settings)
        doc.fileURL = file
        try doc.read(from: file, ofType: "net.daringfireball.markdown")
        NSDocumentController.shared.addDocument(doc)
        defer { doc.close() }
        var open = SessionRecord.Window()
        open.file = DocumentFileAccess.makeFileRef(file)
        open.layout = "split"
        var gone = SessionRecord.Window()
        gone.file = DocumentFileAccess.FileRef(path: scratch.appendingPathComponent("gone.md").path, bookmark: nil)
        let before = NSDocumentController.shared.documents.count
        let restorer = SessionRestorer(record: SessionRecord(windows: [open, gone], key: 0), settings: settings)
        let done = expectation(description: "restored")
        restorer.start { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(NSDocumentController.shared.documents.count, before, "the open document is not opened twice")
        XCTAssertEqual(restorer.restoredCount, 1)
        XCTAssertEqual(restorer.skipped, 1)
        XCTAssertEqual(doc.session.layout, .split)
        (doc.windowControllers.first as? EditorWindowController)?.window?.close()
    }

    func testQuitAsksOnlyWithAWindowAndTheCheckboxTurnsThePreferenceOff() {
        let settings = isolatedSettings()
        var asked: [NSAlert] = []
        var answer = NSApplication.ModalResponse.alertSecondButtonReturn
        var tick = false
        QuitConfirmation.run = { alert in
            asked.append(alert)
            if tick { alert.suppressionButton?.state = .on }
            return answer
        }
        XCTAssertTrue(QuitConfirmation.mayQuit(windows: 0, settings: settings))
        XCTAssertTrue(asked.isEmpty, "no window: no question")
        XCTAssertFalse(QuitConfirmation.mayQuit(windows: 1, settings: settings), "Cancel")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].messageText, "Quit Markdown?")
        XCTAssertEqual(asked[0].buttons.map(\.title), ["Quit", "Cancel"])
        XCTAssertEqual(asked[0].suppressionButton?.title, "Do not ask again")
        // Ticking the box and cancelling is not a decision.
        tick = true
        XCTAssertFalse(QuitConfirmation.mayQuit(windows: 1, settings: settings))
        XCTAssertTrue(settings.askBeforeQuitting)
        answer = .alertFirstButtonReturn
        XCTAssertTrue(QuitConfirmation.mayQuit(windows: 1, settings: settings))
        XCTAssertFalse(settings.askBeforeQuitting)
        XCTAssertTrue(QuitConfirmation.mayQuit(windows: 3, settings: settings))
        XCTAssertEqual(asked.count, 3, "the preference is off: no more questions")
    }
}
