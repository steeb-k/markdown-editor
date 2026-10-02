import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// A real document with its window, driven the way AppKit drives it (undo grouped by event,
/// typing through `insertText`).
final class DocumentLifecycleTests: XCTestCase {
    private func open(_ text: String) throws -> (MarkdownDocument, EditorWindowController) {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func type(_ s: String, into tv: NSTextView) {
        for c in s {
            tv.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump(0.01)
        }
    }

    func testTypingMarksTheDocumentEdited() throws {
        let (doc, wc) = try open("# Hi\n\ntext\n")
        wc.textView.setSelectedRange(NSRange(location: 10, length: 0))
        type("abc", into: wc.textView)
        pump()
        XCTAssertTrue(doc.isDocumentEdited || doc.hasUnautosavedChanges, "typing must mark the document changed")
        XCTAssertEqual(doc.undoManager?.canUndo, true)
        doc.close()
    }

    func testUndoingARealignLeavesTheTypingAndIsNotReapplied() throws {
        let original = "| a | b |\n|---|---|\n| alpha | 1 |\n\nThe end.\n"
        let (doc, wc) = try open(original)
        let tv = wc.textView
        let um = try XCTUnwrap(doc.undoManager)
        let ns = { doc.session.text as NSString }
        tv.setSelectedRange(NSRange(location: ns().range(of: "alpha").location + 5, length: 0))
        XCTAssertTrue(spin { doc.session.activeTable != nil })
        type("-and-more", into: tv)
        pump(0.2)
        let typed = doc.session.text
        XCTAssertTrue(typed.contains("| alpha-and-more | 1 |"))
        // Leave the table: it is realigned as its own undo step.
        tv.setSelectedRange(NSRange(location: ns().range(of: "end").location, length: 0))
        XCTAssertTrue(spin { doc.session.text != typed }, "realigned on leave")
        let aligned = doc.session.text
        XCTAssertEqual(um.undoActionName, "Align Table")
        um.undo()
        XCTAssertEqual(doc.session.text, typed, "undo takes back the realign only")
        // Going back into the table and out again does not realign what was just undone.
        tv.setSelectedRange(NSRange(location: ns().range(of: "alpha").location + 2, length: 0))
        XCTAssertTrue(spin { doc.session.activeTable != nil })
        tv.setSelectedRange(NSRange(location: ns().range(of: "end").location, length: 0))
        pump(0.4)
        XCTAssertEqual(doc.session.text, typed, "an undone realign is not re-applied until the table is edited again")
        // Editing the table again brings realign-on-leave back.
        tv.setSelectedRange(NSRange(location: ns().range(of: "alpha").location + 2, length: 0))
        XCTAssertTrue(spin { doc.session.activeTable != nil })
        type("!", into: tv)
        tv.setSelectedRange(NSRange(location: ns().range(of: "end").location, length: 0))
        XCTAssertTrue(spin { doc.session.text.contains("| al!pha-and-more | 1   |") }, doc.session.text)
        um.redo() // nothing to redo after a new edit; must not crash or change text
        _ = aligned
        doc.close()
    }

    func testClosingADocumentFreesItsWindowSessionCoordinatorAndQueue() throws {
        weak var weakDoc: MarkdownDocument?
        weak var weakSession: EditorSession?
        weak var weakCoordinator: AnalysisCoordinator?
        weak var weakTextView: EditorTextView?
        weak var weakController: EditorWindowController?
        weak var weakWindow: NSWindow?
        try autoreleasepool {
            let (doc, wc) = try open("# Title\n\n- a\n- b\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```\n")
            wc.showWindow(nil)
            let tv = wc.textView
            tv.setSelectedRange(NSRange(location: 9, length: 0))
            type("xy", into: tv)
            tv.toggleStrong(nil)
            pump(0.2)
            weakDoc = doc; weakSession = doc.session; weakCoordinator = doc.session.coordinator
            weakTextView = tv; weakController = wc; weakWindow = wc.window
            doc.updateChangeCount(.changeCleared)
            doc.close()
        }
        XCTAssertTrue(spin(timeout: 5) { weakDoc == nil && weakSession == nil && weakCoordinator == nil && weakController == nil })
        XCTAssertNil(weakDoc, "document")
        XCTAssertNil(weakController, "window controller")
        XCTAssertNil(weakSession, "session")
        XCTAssertNil(weakCoordinator, "coordinator (and the queue it owns)")
        // AppKit may hold on to a closed window and its text view for a while (a plain NSWindow
        // too). If it does, the view must be safe: no delegate pointing at the freed session,
        // and a whole text system to draw or answer with.
        if let tv = weakTextView {
            XCTAssertNil(tv.delegate)
            XCTAssertNotNil(tv.layoutManager?.textStorage)
            XCTAssertEqual(tv.string.isEmpty, false)
        }
        _ = weakWindow
    }
}
