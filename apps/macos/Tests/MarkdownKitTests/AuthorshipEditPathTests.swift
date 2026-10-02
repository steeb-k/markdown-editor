import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Edits that reach the text storage by paths other than typing and the app's own commands:
/// the find bar's Replace All, several ranges announced at once (a drag that moves text),
/// IME composition, spelling corrections, dropped files. Each must attribute exactly what it
/// inserts (to the user, unless it carries marks) and leave its neighbours alone.
final class AuthorshipEditPathTests: XCTestCase {
    /// What NSTextFinder does for Replace All on a text view: one announcement for every range,
    /// the replacements (last first, so earlier ranges stay valid), one `didReplaceCharacters`.
    private func replaceAll(_ e: Editor, _ needle: String, with replacement: String, forwards: Bool = false) {
        let ns = e.string as NSString
        var ranges: [NSRange] = []
        var from = 0
        while true {
            let r = ns.range(of: needle, options: [], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            ranges.append(r)
            from = NSMaxRange(r)
        }
        let client = e.tv as AnyObject
        e.grouped {
            XCTAssertEqual(client.shouldReplaceCharacters?(inRanges: ranges.map { NSValue(range: $0) }, with: ranges.map { _ in replacement }), true)
            if forwards {
                var shift = 0
                for r in ranges {
                    client.replaceCharacters?(in: NSRange(location: r.location + shift, length: r.length), with: replacement)
                    shift += (replacement as NSString).length - r.length
                }
            } else {
                for r in ranges.reversed() { client.replaceCharacters?(in: r, with: replacement) }
            }
            client.didReplaceCharacters?()
        }
    }

    func testReplaceAllAttributesTheReplacementsToTheUserAndLeavesNeighboursAlone() {
        for forwards in [false, true] {
            // "foo" right before an AI run, inside one, and in the user's own text.
            let e = Editor(text: "foo")
            e.privatePasteboard()
            e.select(3)
            e.paste("bar foo baz", as: .ai)
            e.select((e.string as NSString).length)
            e.type(" and foo.")
            XCTAssertEqual(e.string, "foobar foo baz and foo.")
            let before = e.runState()
            replaceAll(e, "foo", with: "quux", forwards: forwards)
            XCTAssertEqual(e.string, "quuxbar quux baz and quux.")
            // The replacements are the user's: the AI run keeps exactly its own words.
            XCTAssertEqual(e.runs(), ["0,4 \(e.me)", "4,4 AI", "8,4 \(e.me)", "12,4 AI", "16,10 \(e.me)"], "forwards \(forwards)")
            XCTAssertEqual(e.authorshipProblems(), [])
            e.um.undo()
            XCTAssertEqual(e.string, "foobar foo baz and foo.")
            XCTAssertEqual(e.runState(), before, "Replace All undoes in one step, marks included")
            e.um.redo()
            XCTAssertEqual(e.string, "quuxbar quux baz and quux.")
        }
    }

    /// A drag that moves text inside the view announces the deletion and the insertion together.
    /// The moved text is the user's (marks do not travel with a drag); nothing else changes.
    func testSeveralRangesAnnouncedAtOnceAreEachTheUsers() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("AI words here", as: .ai)
        e.select((e.string as NSString).length)
        e.type(" mine")
        XCTAssertEqual(e.runs(), ["0,13 AI", "13,5 \(e.me)"])
        // Move "words " (6..12) to the end, the way NSTextView does: insertion and deletion
        // announced in one call, applied separately (the later range first).
        e.grouped {
            let ranges = [NSValue(range: NSRange(location: 18, length: 0)), NSValue(range: NSRange(location: 3, length: 6))]
            XCTAssertTrue(e.tv.shouldChangeText(inRanges: ranges, replacementStrings: [" words", ""]))
            e.tv.textStorage?.beginEditing()
            e.tv.textStorage?.replaceCharacters(in: NSRange(location: 18, length: 0), with: " words")
            e.tv.textStorage?.replaceCharacters(in: NSRange(location: 3, length: 6), with: "")
            e.tv.textStorage?.endEditing()
            e.tv.didChangeText()
        }
        XCTAssertEqual(e.string, "AI here mine words")
        XCTAssertEqual(e.runs(), ["0,7 AI", "7,11 \(e.me)"])
        XCTAssertEqual(e.authorshipProblems(), [])
        e.um.undo()
        XCTAssertEqual(e.runs(), ["0,13 AI", "13,5 \(e.me)"])
    }

    /// Composition inside an AI run: the marked text and what it commits are the user's, and
    /// the run is split around it, as typing would.
    func testIMECompositionInsideAnAIRun() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("abcdef", as: .ai)
        e.select(3)
        e.tv.breakUndoCoalescing()
        let none = NSRange(location: NSNotFound, length: 0)
        e.grouped { e.tv.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        XCTAssertEqual(e.runs(), ["0,3 AI", "3,1 \(e.me)", "4,3 AI"], "the marked text is the user's while it is composed")
        e.grouped { e.tv.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        e.grouped { e.tv.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: none) }
        XCTAssertEqual(e.string, "abcかんdef")
        XCTAssertEqual(e.runs(), ["0,3 AI", "3,2 \(e.me)", "5,3 AI"])
        e.grouped { e.tv.insertText("漢", replacementRange: none) }
        XCTAssertFalse(e.tv.hasMarkedText())
        XCTAssertEqual(e.string, "abc漢def")
        XCTAssertEqual(e.runs(), ["0,3 AI", "3,1 \(e.me)", "4,3 AI"])
        XCTAssertEqual(e.authorshipProblems(), [])
        var n = 0
        while e.string != "abcdef", e.um.canUndo, n < 5 { e.um.undo(); n += 1 }
        XCTAssertEqual(e.string, "abcdef")
        XCTAssertEqual(e.runs(), ["0,6 AI"])
    }

    /// The spelling panel and the contextual menu's suggestions replace a word through
    /// `insertText(_:replacementRange:)`: the correction is the user's.
    func testASpellingCorrectionIsTheUsers() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("the quikc fox", as: .ai)
        e.type("")
        e.tv.breakUndoCoalescing()
        e.grouped { e.tv.insertText("quick", replacementRange: NSRange(location: 4, length: 5)) }
        XCTAssertEqual(e.string, "the quick fox")
        XCTAssertEqual(e.runs(), ["0,4 AI", "4,5 \(e.me)", "9,4 AI"])
        e.um.undo()
        XCTAssertEqual(e.runs(), ["0,13 AI"])
    }

    /// A file dropped beside borrowed text: the reference to it is the user's own text, not the
    /// borrowed text's.
    func testADroppedFileIsTheUsers() throws {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("AI paragraph.", as: .ai)
        let url = URL(fileURLWithPath: "/tmp/picture.png")
        e.tv.insertFiles([url], at: (e.string as NSString).length)
        XCTAssertTrue(e.string.hasPrefix("AI paragraph."))
        XCTAssertTrue(e.string.contains("](/tmp/picture.png)"), e.string)
        XCTAssertEqual(e.runs().first, "0,13 AI")
        XCTAssertEqual(e.runs().count, 2, "\(e.runs())")
        XCTAssertTrue(e.runs().last?.hasSuffix(e.me) == true, "\(e.runs())")
    }
}

// MARK: saving

final class AuthorshipSaveTests: XCTestCase {
    private let type = "net.daringfireball.markdown"

    private func settings() -> Settings {
        let s = isolatedSettings()
        s.authorNameSetting = "Steve"
        return s
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.fixtureDir.appendingPathComponent("authorship").appendingPathComponent(name))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("authorship-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func textView(_ doc: MarkdownDocument) -> EditorTextView {
        (doc.windowControllers.first as! EditorWindowController).textView
    }

    private func edit(_ doc: MarkdownDocument, _ body: (EditorTextView) -> Void) {
        doc.undoManager?.beginUndoGrouping()
        body(textView(doc))
        doc.undoManager?.endUndoGrouping()
    }

    /// The save writes what the document was when it started, whatever is typed meanwhile.
    func testASaveSnapshotIsIndependentOfLaterEdits() throws {
        let doc = MarkdownDocument(settings: settings())
        try doc.read(from: try fixture("ai-draft.md"), ofType: type)
        doc.makeWindowControllers()
        let snapshot = doc.saveSnapshot()
        let before = try doc.data(ofType: type)
        edit(doc) { tv in
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.insertText("Typed during the save. ", replacementRange: tv.selectedRange())
        }
        doc.session.mark(NSRange(location: 0, length: 5), as: .ai)
        XCTAssertNotEqual(try doc.data(ofType: type), before)
        XCTAssertEqual(snapshot.encoded(), before, "the text and the attribution were copied together")
        XCTAssertEqual(before, try fixture("ai-draft.md"))
        doc.close()
    }

    /// A real save through NSDocument: written off the main thread, reopened with the same marks
    /// and a valid block. (Duplicate needs the app's document types, which a test bundle lacks.)
    func testSavingIsAsynchronousAndTheFileReopensWithTheSameMarks() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("lights.md")
        try fixture("harbour-lights.md").write(to: url)
        let doc = MarkdownDocument(settings: settings())
        try doc.read(from: url, ofType: type)
        doc.fileURL = url
        doc.fileType = type
        doc.makeWindowControllers()
        XCTAssertTrue(doc.session.waitUntilStyled())
        XCTAssertNil(doc.session.pendingAuthorshipDecision)
        let marks = doc.session.authorship.runs(within: nil).count
        XCTAssertGreaterThan(marks, 10)
        edit(doc) { tv in
            tv.setSelectedRange(NSRange(location: (doc.session.text as NSString).length, length: 0))
            tv.pasteboard = NSPasteboard(name: NSPasteboard.Name("markdown-test-\(UUID().uuidString)"))
            tv.pasteboard.setString("A closing line from elsewhere.\n", forType: .string)
            tv.pasteAsReference(nil)
        }
        var done = false
        var failure: Error?
        doc.save(to: url, ofType: type, for: .saveOperation) { error in failure = error; done = true }
        XCTAssertTrue(spin(timeout: 20) { done })
        XCTAssertNil(failure)
        XCTAssertEqual(doc.writesOnMainThread, [false], "the block is hashed and the file written off the main thread")
        let reopened = MarkdownDocument(settings: settings())
        try reopened.read(from: url, ofType: type)
        XCTAssertNil(reopened.session.pendingAuthorshipDecision, "the block written is valid")
        XCTAssertEqual(reopened.session.text, doc.session.text)
        XCTAssertEqual(reopened.session.authorship.runs(within: nil), doc.session.authorship.runs(within: nil))
        XCTAssertEqual(reopened.session.authorship.authors(), doc.session.authorship.authors())
        doc.close()
    }

    /// Typing a character and deleting it again leaves the file byte-identical (the remembered
    /// block is written back, not a canonical one with a longer hash).
    func testTypingAndDeletingACharacterKeepsTheFileByteIdentical() throws {
        for name in ["harbour-lights.md", "crlf.md", "unknown-keys.md", "spec-example.md"] {
            let data = try fixture(name)
            let doc = MarkdownDocument(settings: settings())
            try doc.read(from: data, ofType: type)
            doc.makeWindowControllers()
            let n = (doc.session.text as NSString).length
            edit(doc) { tv in tv.insertText("x", replacementRange: NSRange(location: n / 2, length: 0)) }
            XCTAssertNotEqual(try doc.data(ofType: type), data, name)
            edit(doc) { tv in tv.insertText("", replacementRange: NSRange(location: n / 2, length: 1)) }
            XCTAssertEqual(try doc.data(ofType: type), data, name)
            // And through undo and redo.
            doc.undoManager?.undo()
            doc.undoManager?.undo()
            XCTAssertEqual(try doc.data(ofType: type), data, name)
            doc.close()
        }
    }

    /// While the keep-or-discard question stands, anything written (an autosave, a Versions
    /// snapshot) is the file as it was: nothing is dropped or re-hashed behind the user's back.
    func testNothingLossyIsWrittenWhileTheQuestionStands() throws {
        for name in ["mismatch.md", "malformed.md"] {
            let data = try fixture(name)
            let doc = MarkdownDocument(settings: settings())
            try doc.read(from: data, ofType: type)
            doc.makeWindowControllers()
            XCTAssertNotNil(doc.session.pendingAuthorshipDecision)
            XCTAssertFalse(doc.isDocumentEdited, "nothing to autosave")
            XCTAssertEqual(try doc.data(ofType: type), data, name)
            // Keep, untouched: still the original bytes (the next open asks again, honestly).
            doc.session.resolveAuthorshipDecision(keep: true)
            XCTAssertEqual(try doc.data(ofType: type), data, name)
            doc.close()
        }
    }
}
