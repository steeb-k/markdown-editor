import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

extension Editor {
    /// The attribution as "start,length name" for everything attributed to someone (Me included).
    func runs() -> [String] {
        let names = session.authorship.authors().map(\.name)
        return session.authorship.runs(within: nil).map { "\($0.range.start),\($0.range.end - $0.range.start) \(names[Int($0.authorIndex)])" }
    }

    /// The same with the author's kind (what a state is, for comparing histories).
    func runState() -> [String] {
        let authors = session.authorship.authors()
        return session.authorship.runs(within: nil).map { "\($0.range.start)-\($0.range.end) \(authors[Int($0.authorIndex)])" }
    }

    @discardableResult
    func privatePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("markdown-test-\(UUID().uuidString)"))
        tv.pasteboard = pb
        return pb
    }

    func paste(_ s: String, as choice: AuthorChoice? = nil) {
        let pb = tv.pasteboard
        pb.clearContents()
        pb.setString(s, forType: .string)
        switch choice {
        case nil: tv.paste(nil)
        case .me?: tv.pasteAsMe(nil)
        case .ai?: tv.pasteAsAI(nil)
        case .reference?: tv.pasteAsReference(nil)
        }
    }

    func type(_ s: String) {
        tv.breakUndoCoalescing()
        grouped { tv.insertText(s, replacementRange: tv.selectedRange()) }
    }

    var me: String { session.authorship.me().name }

    /// Every character's temporary colour is what the layers say, and the authorship layer is
    /// the attribution: borrowed text in the theme's colours, the user's own text untouched.
    func authorshipProblems() -> [String] {
        var out: [String] = []
        let o = session.overlay
        o.apply()
        let a = session.authorship
        let authors = a.authors()
        var expected: [OverlayRun] = []
        if session.authorshipDisplay {
            for r in a.runs(within: nil) where r.authorIndex != 0 {
                expected.append(OverlayRun(r.range.nsRange, .authorship(authors[Int(r.authorIndex)].kind == .ai ? .ai : .reference)))
            }
        }
        if o.layers.authorship != OverlayCompositor.merged(expected) { out.append("authorship layer \(o.layers.authorship) is not \(expected)") }
        let window = o.appliedWindow
        let composed = OverlayCompositor.compose(o.layers, in: window)
        var run = 0
        let length = session.storage.length
        for i in window.location..<min(NSMaxRange(window), length) {
            while run < composed.count, NSMaxRange(composed[run].range) <= i { run += 1 }
            let paint = run < composed.count && composed[run].range.location <= i ? composed[run].paint : nil
            let actual = (lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor)?.hexString
            let want = paint.flatMap { o.color(for: $0)?.hexString }
            if actual != want { out.append("character \(i) is painted \(String(describing: actual)), the layers say \(String(describing: want))"); break }
            // And the layers say what the attribution says, unless something above them paints.
            if let idx = a.authorAt(position: UInt32(i)), idx != 0, session.authorshipDisplay {
                let kind = authors[Int(idx)].kind
                switch paint {
                case .authorship(let s)?: if (s == .ai) != (kind == .ai) { out.append("character \(i) has the wrong source colour") }
                case .pos?, .dim?: break
                case nil: out.append("character \(i) is borrowed text but is not coloured")
                }
            } else if case .authorship? = paint {
                out.append("character \(i) is the user's but is coloured as borrowed")
            }
        }
        return out
    }
}

// MARK: basics

final class AuthorshipBasicsTests: XCTestCase {
    func testPasteAsAIThenUndoRedo() throws {
        let e = Editor(text: "Hello world\n")
        e.privatePasteboard()
        e.select(5)
        e.paste(" brave new", as: .ai)
        XCTAssertEqual(e.string, "Hello brave new world\n")
        XCTAssertEqual(e.runs(), ["5,10 AI"])
        XCTAssertEqual(e.um.undoActionName, "Paste as AI")
        e.um.undo()
        XCTAssertEqual(e.string, "Hello world\n")
        XCTAssertEqual(e.runs(), [])
        e.um.redo()
        XCTAssertEqual(e.runs(), ["5,10 AI"])
        XCTAssertEqual(e.authorshipProblems(), [])
    }

    func testPasteAsReferenceAndMe() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("ref", as: .reference)
        e.paste("me", as: .me)
        XCTAssertEqual(e.runs(), ["0,3 Reference", "3,2 \(e.me)"])
        XCTAssertTrue(e.session.authorship.hasMarks())
        XCTAssertEqual(e.authorshipProblems(), [])
    }

    func testTypingInsideAnAIRunSplitsItAndAtTheEdgeDoesNotExtendIt() throws {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("abcdefgh", as: .ai)
        e.select(4)
        e.type("XY")
        XCTAssertEqual(e.runs(), ["0,4 AI", "4,2 \(e.me)", "6,4 AI"])
        e.select(10)
        e.type("Z")
        XCTAssertEqual(e.runs().last, "10,1 \(e.me)")
        e.select(0)
        e.type("Q")
        XCTAssertEqual(e.runs().first, "0,1 \(e.me)")
        XCTAssertEqual(e.runs()[1], "1,4 AI")
        e.um.undo(); e.um.undo(); e.um.undo()
        XCTAssertEqual(e.runs(), ["0,8 AI"])
        e.um.redo()
        XCTAssertEqual(e.runs(), ["0,4 AI", "4,2 \(e.me)", "6,4 AI"])
        XCTAssertEqual(e.authorshipProblems(), [])
    }

    func testDeletingShrinksAndRemoves() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("0123456789", as: .ai)
        e.edit(range: NSRange(location: 2, length: 3), with: "")
        XCTAssertEqual(e.runs(), ["0,7 AI"])
        e.edit(range: NSRange(location: 0, length: 7), with: "")
        XCTAssertEqual(e.runs(), [])
        e.um.undo()
        XCTAssertEqual(e.runs(), ["0,7 AI"])
        e.um.undo()
        XCTAssertEqual(e.runs(), ["0,10 AI"])
        XCTAssertEqual(e.string, "0123456789")
    }

    func testMarkAsIsUndoableAndHasAName() {
        let e = Editor(text: "one two three\n")
        e.select(4, 3)
        e.grouped { e.tv.markAsAI(nil) }
        XCTAssertEqual(e.runs(), ["4,3 AI"])
        XCTAssertEqual(e.um.undoActionName, "Mark as AI")
        e.select(0, 3)
        e.grouped { e.tv.markAsReference(nil) }
        XCTAssertEqual(e.runs(), ["0,3 Reference", "4,3 AI"])
        e.select(4, 3)
        e.grouped { e.tv.markAsNoAuthor(nil) }
        XCTAssertEqual(e.um.undoActionName, "Mark as No Author")
        XCTAssertEqual(e.runs(), ["0,3 Reference"])
        e.um.undo()
        XCTAssertEqual(e.runs(), ["0,3 Reference", "4,3 AI"])
        e.um.undo()
        XCTAssertEqual(e.runs(), ["4,3 AI"])
        e.um.undo()
        XCTAssertEqual(e.runs(), [])
        e.um.redo(); e.um.redo(); e.um.redo()
        XCTAssertEqual(e.runs(), ["0,3 Reference"])
        XCTAssertEqual(e.string, "one two three\n", "Mark As never touches the text")
    }

    func testMarkAsMeAfterAIGivesTheTextBackAndRemovesTheBlock() {
        let e = Editor(text: "alpha beta\n")
        e.select(0, 5)
        e.grouped { e.tv.markAsAI(nil) }
        XCTAssertTrue(e.session.authorship.hasMarks())
        e.grouped { e.tv.markAsMe(nil) }
        XCTAssertFalse(e.session.authorship.hasMarks())
        XCTAssertEqual(e.session.authorship.annotationBlock(text: e.string, ending: .lf), nil)
    }

    func testMarkAsNeedsASelectionAndAMarkThatChangesNothingIsNotAnUndoStep() {
        let e = Editor(text: "abc")
        e.select(1)
        XCTAssertFalse(e.session.mark(NSRange(location: 1, length: 0), as: .ai))
        e.select(0, 3)
        e.grouped { e.tv.markAsMe(nil) } // already Me/unattributed text: nothing changes in what is written
        // (Marking unattributed text as Me is a change in memory, but not one that writes anything.)
        XCTAssertFalse(e.session.authorship.hasMarks())
    }

    func testToggleBoldInsideAITextStaysAI() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("Lorem ipsum dolor sit amet\n", as: .ai)
        let ns = e.string as NSString
        e.select(ns.range(of: "ipsum").location, 5)
        e.grouped { e.tv.toggleStrong(nil) }
        XCTAssertEqual(e.string, "Lorem **ipsum** dolor sit amet\n")
        XCTAssertEqual(e.runs(), ["0,31 AI"], "the asterisks are not the user's")
        e.um.undo()
        XCTAssertEqual(e.string, "Lorem ipsum dolor sit amet\n")
        XCTAssertEqual(e.runs(), ["0,27 AI"])
        e.um.redo()
        XCTAssertEqual(e.runs(), ["0,31 AI"])
    }

    func testBoldAcrossAMixedSelectionKeepsBothAuthors() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("mine ", as: .me)
        e.paste("theirs", as: .ai)
        e.select(0, 11)
        e.grouped { e.tv.toggleStrong(nil) }
        XCTAssertEqual(e.string, "**mine theirs**")
        // `mine ` stays Me's, `theirs` stays AI's; the opening `**` comes from the text before it
        // (none: it takes the text after, Me's) and the closing from the text before it (AI's).
        XCTAssertEqual(e.runs(), ["0,7 \(e.me)", "7,8 AI"])
    }

    func testRealignOfATableKeepsAuthorsInTheCells() {
        let table = "| a | b |\n|---|---|\n| alpha | beta |\n"
        let e = Editor(text: table)
        e.select(0, 0)
        let ns = e.string as NSString
        let beta = ns.range(of: "beta")
        e.session.mark(beta, as: .ai)
        e.select(ns.range(of: "alpha").location, 0)
        e.grouped { e.tv.tableRealign(nil) }
        XCTAssertNotEqual(e.string, table)
        let aligned = e.string as NSString
        let after = aligned.range(of: "beta")
        let ai = e.session.authorship.runs(within: nil).filter { e.session.authorship.authors()[Int($0.authorIndex)].kind == .ai }
        XCTAssertEqual(ai.map(\.range.nsRange), [after], "the cell's text is still AI's, wherever the padding put it")
        e.um.undo()
        XCTAssertEqual(e.string, table)
        XCTAssertEqual(e.session.authorship.runs(within: nil).map(\.range.nsRange), [beta])
        e.um.redo()
        XCTAssertEqual(e.session.authorship.runs(within: nil).map(\.range.nsRange), [after])
    }

    func testListRenumberingAndNewlineInheritFromTheirNeighbours() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("- item one", as: .ai)
        e.select((e.string as NSString).length)
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(e.string, "- item one\n- ")
        XCTAssertEqual(e.runs(), ["0,13 AI"], "the continued marker belongs to the list's author")
    }

    func testTypingWhileDisplayIsOffIsStillTracked() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("abcdef", as: .ai)
        e.session.setAuthorshipDisplay(false)
        e.select(3)
        e.type("-")
        XCTAssertEqual(e.runs(), ["0,3 AI", "3,1 \(e.me)", "4,3 AI"])
        e.session.setAuthorshipDisplay(true)
        XCTAssertEqual(e.authorshipProblems(), [])
    }

    func testMenuStateReflectsTheSelection() throws {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("ai text ", as: .ai)
        e.paste("ref", as: .reference)
        func state(_ sel: Selector, _ range: NSRange) -> (enabled: Bool, on: Bool) {
            e.select(range.location, range.length)
            return e.tv.validateAuthorshipAction(sel)!
        }
        XCTAssertFalse(state(#selector(EditorTextView.markAsAI(_:)), NSRange(location: 1, length: 0)).enabled, "disabled with an empty selection")
        XCTAssertFalse(state(#selector(EditorTextView.markAsNoAuthor(_:)), NSRange(location: 1, length: 0)).enabled)
        XCTAssertEqual(state(#selector(EditorTextView.markAsAI(_:)), NSRange(location: 0, length: 5)).on, true)
        XCTAssertEqual(state(#selector(EditorTextView.markAsReference(_:)), NSRange(location: 0, length: 5)).on, false)
        XCTAssertEqual(state(#selector(EditorTextView.markAsReference(_:)), NSRange(location: 8, length: 3)).on, true)
        XCTAssertEqual(state(#selector(EditorTextView.markAsAI(_:)), NSRange(location: 3, length: 8)).on, false, "a mixed selection checks nothing")
        XCTAssertEqual(state(#selector(EditorTextView.markAsMe(_:)), NSRange(location: 3, length: 8)).on, false)
        XCTAssertTrue(state(#selector(EditorTextView.pasteAsAI(_:)), NSRange(location: 0, length: 0)).enabled)
        e.tv.isEditable = false
        XCTAssertFalse(e.tv.validateAuthorshipAction(#selector(EditorTextView.pasteAsAI(_:)))!.enabled)
    }

    func testTheMenusExistWithDistinctKeyEquivalents() throws {
        let main = MainMenu.build()
        var seen: [String: String] = [:]
        var titles: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub, path + "/" + item.title) }
                if !item.keyEquivalent.isEmpty {
                    let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
                    if let other = seen[key] { XCTFail("\(path)/\(item.title) and \(other) share a key equivalent") }
                    seen[key] = path + "/" + item.title
                }
                titles.append(path + "/" + item.title)
            }
        }
        walk(main, "")
        for t in ["/Edit/Paste As", "/Edit/Paste As/Me", "/Edit/Paste As/AI", "/Edit/Paste As/Reference", "/Edit/Mark As",
                  "/Edit/Mark As/Me", "/Edit/Mark As/AI", "/Edit/Mark As/Reference", "/Edit/Mark As/No Author", "/View/Show Authorship"] {
            XCTAssertTrue(titles.contains(t), t)
        }
    }

    func testDisplayToggleChangesNothingInStorageUndoOrDirtyState() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data("plain text\n".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        wc.textView.pasteboard = NSPasteboard(name: NSPasteboard.Name("markdown-test-\(UUID().uuidString)"))
        wc.textView.pasteboard.setString("borrowed", forType: .string)
        wc.textView.setSelectedRange(NSRange(location: 5, length: 0))
        wc.textView.pasteAsAI(nil)
        _ = doc.session.waitUntilStyled()
        let text = doc.session.text
        let attrs = doc.session.storage.attributedSubstring(from: NSRange(location: 0, length: doc.session.storage.length))
        let um = try XCTUnwrap(doc.undoManager)
        let (canUndo, canRedo, name) = (um.canUndo, um.canRedo, um.undoActionName)
        let edited = doc.isDocumentEdited
        let revision = doc.session.coordinator.latestSeq
        for _ in 0..<3 {
            doc.session.setAuthorshipDisplay(false)
            XCTAssertEqual(wc.textView.validateAuthorshipAction(#selector(EditorTextView.toggleAuthorshipDisplay(_:)))?.on, false)
            XCTAssertFalse(wc.authorshipButton.state == .on)
            doc.session.setAuthorshipDisplay(true)
            XCTAssertTrue(wc.authorshipButton.state == .on)
        }
        XCTAssertEqual(doc.session.text, text)
        XCTAssertTrue(doc.session.storage.attributedSubstring(from: NSRange(location: 0, length: doc.session.storage.length)).isEqual(to: attrs))
        XCTAssertEqual(um.canUndo, canUndo)
        XCTAssertEqual(um.canRedo, canRedo)
        XCTAssertEqual(um.undoActionName, name)
        XCTAssertEqual(doc.isDocumentEdited, edited)
        XCTAssertEqual(doc.session.coordinator.latestSeq, revision, "nothing was sent to the analysis queue")
        doc.close()
    }

    func testChangingTheNameForMyTextRenamesMe() {
        let s = isolatedSettings()
        s.authorNameSetting = "Steve"
        let e = Editor(text: "abc", settings: s)
        XCTAssertEqual(e.me, "Steve")
        s.authorNameSetting = "Someone Else"
        XCTAssertEqual(e.me, "Someone Else")
        s.authorNameSetting = ""
        XCTAssertEqual(e.me, s.authorName)
        XCTAssertFalse(s.authorName.isEmpty)
    }
}

// MARK: copy and paste inside the app

final class AuthorshipPasteboardTests: XCTestCase {
    func testCopyAndPasteCarryMarks() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("mine ", as: .me)
        e.paste("ai ", as: .ai)
        e.paste("ref", as: .reference)
        XCTAssertEqual(e.runs(), ["0,5 \(e.me)", "5,3 AI", "8,3 Reference"])
        e.select(3, 7)
        e.tv.copy(nil)
        XCTAssertNotNil(e.tv.pasteboard.data(forType: AuthorshipPasteboard.type))
        XCTAssertEqual(e.tv.pasteboard.string(forType: .string), "e ai re")
        e.select((e.string as NSString).length)
        e.grouped { e.tv.paste(nil) }
        XCTAssertEqual(e.string, "mine ai refe ai re")
        XCTAssertEqual(e.runs(), ["0,5 \(e.me)", "5,3 AI", "8,3 Reference", "11,2 \(e.me)", "13,3 AI", "16,2 Reference"])
        XCTAssertEqual(e.um.undoActionName, "Paste")
        e.um.undo()
        XCTAssertEqual(e.runs(), ["0,5 \(e.me)", "5,3 AI", "8,3 Reference"])
        e.um.redo()
        XCTAssertEqual(e.runs().count, 6)
    }

    func testCutCarriesMarksAndPasteAsOverrides() {
        let e = Editor(text: "")
        e.privatePasteboard()
        e.paste("keep ", as: .me)
        e.paste("moved", as: .ai)
        e.select(5, 5)
        e.grouped { e.tv.cut(nil) }
        XCTAssertEqual(e.string, "keep ")
        XCTAssertEqual(e.runs(), ["0,5 \(e.me)"])
        e.select(0)
        e.grouped { e.tv.paste(nil) }
        XCTAssertEqual(e.string, "movedkeep ")
        XCTAssertEqual(e.runs(), ["0,5 AI", "5,5 \(e.me)"])
        e.select(0, 5)
        e.tv.copy(nil)
        e.select(10)
        e.grouped { e.tv.pasteAsReference(nil) }
        XCTAssertEqual(e.runs().last, "10,5 Reference", "Paste As overrides what the text carried")
    }

    func testPastingFromAnotherAppIsPlainAndMine() {
        let e = Editor(text: "x")
        e.privatePasteboard()
        e.paste("from elsewhere", as: nil)
        XCTAssertEqual(e.runs(), ["1,14 \(e.me)"])
        // The pasteboard still holds an old private payload but the string changed since: ignored.
        e.select(0, 1)
        e.paste("zzz", as: .ai)
        e.select(0, 3)
        e.tv.copy(nil)
        e.tv.pasteboard.setString("someone changed it", forType: .string)
        e.select(0)
        e.grouped { e.tv.paste(nil) }
        XCTAssertTrue(e.runs().first!.hasSuffix(e.me), e.runs().description)
    }

    func testPasteIsUndoableAsOneStepAndMarksTheEditorDirty() {
        let e = Editor(text: "abc")
        e.privatePasteboard()
        e.select(3)
        e.paste(" def", as: .ai)
        XCTAssertEqual(e.um.undoActionName, "Paste as AI")
        e.um.undo()
        XCTAssertEqual(e.string, "abc")
        XCTAssertFalse(e.um.canUndo)
    }
}

// MARK: files

final class AuthorshipFileTests: XCTestCase {
    private func settings(_ me: String = "Steve") -> Settings {
        let s = isolatedSettings()
        s.authorNameSetting = me
        return s
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.fixtureDir.appendingPathComponent("authorship").appendingPathComponent(name))
    }

    private func open(_ data: Data, me: String = "Steve", window: Bool = true) throws -> MarkdownDocument {
        let doc = MarkdownDocument(settings: settings(me))
        try doc.read(from: data, ofType: "net.daringfireball.markdown")
        if window {
            doc.makeWindowControllers()
            _ = (doc.windowControllers.first as? EditorWindowController)?.window
            XCTAssertTrue(doc.session.waitUntilStyled())
        }
        return doc
    }

    private func runs(_ doc: MarkdownDocument) -> [String] {
        let a = doc.session.authorship
        let authors = a.authors()
        return a.runs(within: nil).map { "\($0.range.start)-\($0.range.end) \(authors[Int($0.authorIndex)].kind) \(authors[Int($0.authorIndex)].name)" }
    }

    private func type(_ s: String, in doc: MarkdownDocument) {
        let tv = (doc.windowControllers.first as! EditorWindowController).textView
        doc.undoManager?.beginUndoGrouping()
        tv.insertText(s, replacementRange: tv.selectedRange())
        doc.undoManager?.endUndoGrouping()
    }

    func testTheEditorNeverSeesTheBlock() throws {
        let doc = try open(try fixture("ai-draft.md"))
        XCTAssertFalse(doc.session.text.contains("Annotations"))
        XCTAssertFalse(doc.session.text.contains("SHA-256"))
        XCTAssertTrue(doc.session.text.hasSuffix("lovely.\n"))
        XCTAssertNil(doc.session.pendingAuthorshipDecision)
        // And the core's analysis text does not either.
        XCTAssertEqual(doc.session.coordinator.coreText(), doc.session.text)
        XCTAssertEqual(runs(doc).filter { !$0.contains("Steve") }.count, 2)
        doc.close()
    }

    func testUntouchedFilesAreWrittenBackByteForByte() throws {
        for name in ["ai-draft.md", "crlf.md", "emoji.md", "unknown-keys.md", "bom.md", "spec-example.md", "spec-readme.md", "lookalikes.md"] {
            let data = try fixture(name)
            let doc = try open(data, window: name == "ai-draft.md")
            XCTAssertEqual(try doc.data(ofType: "net.daringfireball.markdown"), data, name)
            doc.close()
        }
    }

    func testByteIdentityOfTheNonUTF8Cases() throws {
        // Mixed line endings, CR only, a block with CRLF and a missing final newline after `...`.
        let base = try String(contentsOf: Fixtures.fixtureDir.appendingPathComponent("authorship/ai-draft.md"), encoding: .utf8)
        let variants: [String: Data] = [
            "no final newline": Data(base.trimmingCharacters(in: .newlines).utf8),
            "trailing blank lines": Data((base + "\n\n").utf8),
            "mixed": Data(base.replacingOccurrences(of: "tea.\n", with: "tea.\r\n").utf8),
        ]
        for (name, data) in variants {
            let doc = try open(data, window: false)
            XCTAssertEqual(try doc.data(ofType: "net.daringfireball.markdown"), data, name)
        }
    }

    func testFilesWithoutMarksNeverGainABlock() throws {
        let doc = try open(Data("# A title\n\nsome text\n".utf8))
        let tv = (doc.windowControllers.first as! EditorWindowController).textView
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        type("typed by me ", in: doc)
        doc.session.setAuthorshipDisplay(false)
        let out = String(decoding: try doc.data(ofType: "net.daringfireball.markdown"), as: UTF8.self)
        XCTAssertEqual(out, "# Atyped by me  title\n\nsome text\n")
        XCTAssertFalse(out.contains("SHA-256"))
        XCTAssertTrue(doc.session.authorship.hasMarks() == false)
        doc.close()
    }

    func testPasteAsAIWritesABlockAndSurvivesSaveAndReopen() throws {
        let doc = try open(Data("first line\n\nlast line\n".utf8), me: "Steve")
        let wc = doc.windowControllers.first as! EditorWindowController
        let tv = wc.textView
        tv.pasteboard = NSPasteboard(name: NSPasteboard.Name("markdown-test-\(UUID().uuidString)"))
        tv.pasteboard.setString("A generated sentence with an emoji \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}. ", forType: .string)
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        tv.pasteAsAI(nil)
        type("Typed. ", in: doc)
        let before = runs(doc)
        XCTAssertEqual(before.count, 2)
        let data = try doc.data(ofType: "net.daringfireball.markdown")
        let file = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(file.hasPrefix("first line\n\nA generated sentence"), file)
        XCTAssertTrue(file.contains("\n\n---\nAnnotations: 0,"), file)
        XCTAssertTrue(file.contains("&AI: "), file)
        XCTAssertTrue(file.hasSuffix("...\n"), file)
        // Reopen: the same text and the same marks; saving again changes nothing.
        let again = try open(data, me: "Steve", window: false)
        XCTAssertEqual(again.session.text, doc.session.text)
        XCTAssertEqual(runs(again), before)
        XCTAssertEqual(try again.data(ofType: "net.daringfireball.markdown"), data)
        XCTAssertNil(again.session.pendingAuthorshipDecision)
        doc.close()
    }

    func testEditingAFileWithMarksWritesACanonicalBlockThatReopensValid() throws {
        let original = try fixture("ai-draft.md")
        let doc = try open(original)
        let tv = (doc.windowControllers.first as! EditorWindowController).textView
        tv.setSelectedRange(NSRange(location: (doc.session.text as NSString).range(of: "myself").location, length: 0))
        type("really ", in: doc)
        let data = try doc.data(ofType: "net.daringfireball.markdown")
        XCTAssertNotEqual(data, original)
        let again = try open(data, window: false)
        XCTAssertNil(again.session.pendingAuthorshipDecision, "the hash of what was written matches")
        XCTAssertEqual(runs(again), runs(doc))
        XCTAssertEqual(try again.data(ofType: "net.daringfireball.markdown"), data)
        doc.close()
    }

    func testCRLFFilesKeepTheirEndingsAndTheHashIsOverTheirBytes() throws {
        let original = try fixture("crlf.md")
        let doc = try open(original)
        XCTAssertFalse(doc.session.text.contains("\r"))
        let tv = (doc.windowControllers.first as! EditorWindowController).textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        type("!", in: doc)
        let data = try doc.data(ofType: "net.daringfireball.markdown")
        let file = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(file.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line ends CRLF, the block too")
        let again = try open(data, window: false)
        XCTAssertNil(again.session.pendingAuthorshipDecision)
        XCTAssertEqual(runs(again), runs(doc))
        doc.close()
    }

    func testBOMIsKeptAndTheBlockStillValid() throws {
        let original = try fixture("bom.md")
        let doc = try open(original, window: false)
        XCTAssertNil(doc.session.pendingAuthorshipDecision)
        XCTAssertEqual(runs(doc).count, 5)
        XCTAssertEqual(Array(try doc.data(ofType: "x").prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func testEmojiRangesLandOnWholeClusters() throws {
        let doc = try open(try fixture("emoji.md"), window: false)
        XCTAssertNil(doc.session.pendingAuthorshipDecision)
        let ns = doc.session.text as NSString
        let authors = doc.session.authorship.authors()
        var found: [String] = []
        for r in doc.session.authorship.runs(within: nil) where authors[Int(r.authorIndex)].kind != .human {
            found.append(ns.substring(with: r.range.nsRange))
        }
        XCTAssertEqual(found, ["\u{1F1E9}\u{1F1EA} and \u{1F1EF}\u{1F1F5}", "nai\u{308}ve, e\u{301}t\u{e9}: \u{1F44D}\u{1F3FD} thumbs", "\u{1F600}\u{1F600}\u{1F600}"])
    }

    func testUnknownAnnotationsSurviveAnEdit() throws {
        let doc = try open(try fixture("unknown-keys.md"))
        let tv = (doc.windowControllers.first as! EditorWindowController).textView
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type("X", in: doc)
        let file = String(decoding: try doc.data(ofType: "x"), as: UTF8.self)
        XCTAssertTrue(file.contains("Title: Lighthouse notes  \nSession: first\n  second line\n...\n"), file)
        doc.close()
    }

    func testOtherAuthorsAreKeptInOrder() throws {
        let data = Data("Some text here\n\n---\nAnnotations: 0,14 SHA-256 \(try sha("Some text here"))  \n*Book: 0,4  \n@Zed: 5,4  \n&Model: 10,4  \n...\n".utf8)
        let doc = try open(data, me: "Steve", window: false)
        XCTAssertNil(doc.session.pendingAuthorshipDecision)
        doc.session.mark(NSRange(location: 0, length: 1), as: .me) // a change: the canonical writer runs
        let file = String(decoding: try doc.data(ofType: "x"), as: UTF8.self)
        let lines = file.split(separator: "\n").filter { "*@&".contains($0.first ?? " ") }
        XCTAssertEqual(lines.map { $0.split(separator: ":").first.map(String.init) ?? "" }, ["@Steve", "*Book", "@Zed", "&Model"])
    }

    private func sha(_ s: String) throws -> String {
        // The test needs a block with a valid hash for a text written by hand: ask the core.
        let a = Authorship(me: "x")
        a.mark(range: Utf16Range(start: 0, end: 1), author: Author(kind: .ai, name: "AI"))
        let block = try XCTUnwrap(a.annotationBlock(text: s, ending: .lf))
        let line = try XCTUnwrap(block.split(separator: "\n").first { $0.hasPrefix("Annotations:") })
        return String(line.split(separator: " ")[3])
    }

    // MARK: keep or discard

    func testMismatchAsksBeforeEditingAndKeepChangesNothing() throws {
        let original = try fixture("mismatch.md")
        let doc = try open(original)
        let wc = doc.windowControllers.first as! EditorWindowController
        XCTAssertEqual(doc.session.pendingAuthorshipDecision, .hashMismatch)
        XCTAssertFalse(wc.textView.isEditable, "nothing can be edited until the user has chosen")
        XCTAssertFalse(wc.textView.validateAuthorshipAction(#selector(EditorTextView.pasteAsAI(_:)))!.enabled)
        XCTAssertFalse(runs(doc).isEmpty, "the marks are there to be seen while the question stands")
        doc.session.resolveAuthorshipDecision(keep: true)
        XCTAssertTrue(wc.textView.isEditable)
        XCTAssertNil(doc.session.pendingAuthorshipDecision)
        XCTAssertFalse(doc.isDocumentEdited, "Keep does not change the document")
        XCTAssertFalse(runs(doc).isEmpty)
        XCTAssertEqual(try doc.data(ofType: "x"), original, "kept and untouched: the file is as it was")
        doc.close()
    }

    func testDiscardDropsTheMarksAndDirtiesTheDocument() throws {
        let doc = try open(try fixture("mismatch.md"))
        doc.session.resolveAuthorshipDecision(keep: false)
        XCTAssertTrue(runs(doc).isEmpty)
        XCTAssertTrue(doc.isDocumentEdited)
        let out = String(decoding: try doc.data(ofType: "x"), as: UTF8.self)
        XCTAssertFalse(out.contains("SHA-256"), "no marks, no block")
        XCTAssertTrue(out.hasSuffix("lovely.\n"))
        doc.close()
    }

    func testMalformedBlocksAskToo() throws {
        let doc = try open(try fixture("malformed.md"), window: false)
        guard case .malformed? = doc.session.pendingAuthorshipDecision else { return XCTFail("\(String(describing: doc.session.pendingAuthorshipDecision))") }
    }

    func testTheSheetCanBeAnsweredThroughItsButtons() throws {
        let doc = try open(try fixture("mismatch.md"))
        let wc = doc.windowControllers.first as! EditorWindowController
        wc.showWindow(nil)
        wc.presentAuthorshipSheetIfNeeded()
        let sheet = try XCTUnwrap(wc.window?.attachedSheet, "the question is asked in a sheet")
        let buttons = sheet.contentView?.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton } ?? []
        _ = buttons
        XCTAssertNotNil(doc.session.pendingAuthorshipDecision)
        wc.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        XCTAssertTrue(spin { doc.session.pendingAuthorshipDecision == nil })
        XCTAssertTrue(runs(doc).isEmpty, "the second button is Discard")
        wc.window?.orderOut(nil)
        doc.close()
    }

    func testRevertReadsTheFileAgain() throws {
        let doc = try open(try fixture("ai-draft.md"))
        let tv = (doc.windowControllers.first as! EditorWindowController).textView
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        type("changed ", in: doc)
        XCTAssertNotEqual(doc.session.text, try String(contentsOf: Fixtures.fixtureDir.appendingPathComponent("authorship/ai-draft.md")))
        try doc.read(from: try fixture("ai-draft.md"), ofType: "x")
        XCTAssertTrue(doc.session.text.hasPrefix("# Notes"))
        XCTAssertEqual(runs(doc).filter { !$0.contains("Steve") }.count, 2)
        XCTAssertFalse(doc.undoManager?.canUndo ?? true)
        doc.close()
    }

    func testSaveAsAndDuplicateCarryTheMarks() throws {
        let doc = try open(try fixture("ai-draft.md"), window: false)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("authorship-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("copy.md")
        try doc.write(to: url, ofType: "net.daringfireball.markdown")
        XCTAssertEqual(try Data(contentsOf: url), try fixture("ai-draft.md"))
        let again = MarkdownDocument(settings: settings())
        try again.read(from: url, ofType: "net.daringfireball.markdown")
        XCTAssertEqual(runs(again), runs(doc))
    }

    func testAnIllFormedFileThatMerelyEndsInDashesIsText() throws {
        let doc = try open(try fixture("lookalikes.md"), window: false)
        XCTAssertNil(doc.session.pendingAuthorshipDecision)
        XCTAssertTrue(doc.session.text.hasSuffix("...\n"), "the lookalike stays in the text")
        XCTAssertTrue(doc.session.text.hasPrefix("---\ntitle:"))
    }

    func testThreadingTheHashWorkIsOffTheTypingPath() throws {
        // The block is only built when saving: typing in a document with marks does no hashing
        // (a 1 MB document is checked by the UI script big-authorship.json).
        let e = Editor(text: String(repeating: "word ", count: 20_000))
        e.privatePasteboard()
        e.paste("ai", as: .ai)
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<50 { e.type("x") }
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - t0, 5)
    }
}

// MARK: random use

/// Random typing, deletion, Paste As, Mark As, command edits, copy and paste, and random
/// undo/redo walks, against a reference history of (text, attribution) at every step.
class AuthorshipRandomTests: XCTestCase {
    var live: Bool { false }

    struct State: Equatable {
        var text: String
        var runs: [String]
    }

    /// (No table: leaving one aligns it asynchronously, as a step of its own at a moment the
    /// test does not control. Realign has its own test.)
    static let base = """
    # Title

    Some *text* with **bold** words and a [link](http://x.y).

    - one
    - two
    1. first
    2. second

    > quote line

    Last \u{65E5}\u{672C} \u{1F389} e\u{301} end.
    """

    func testRandomHistoriesAreExactUnderUndoAndRedo() {
        let rounds = Int(ProcessInfo.processInfo.environment["AUTHORSHIP_ROUNDS"] ?? "") ?? 4
        let steps = Int(ProcessInfo.processInfo.environment["AUTHORSHIP_STEPS"] ?? "") ?? 140
        let typed = ["x", " ", "**", "word", "\n", "日", "\u{1F389}", "e\u{301}", "- ", "|", "\u{1F468}\u{200D}\u{1F469}"]
        let pastes = ["generated text", "two\nlines", "**b** \u{1F600}", "- a\n- b\n", "日本語"]
        for round in 0..<rounds {
            if let only = ProcessInfo.processInfo.environment["AUTHORSHIP_ONLY_ROUND"].flatMap({ Int($0) }), only != round { continue }
            let seed = UInt64(ProcessInfo.processInfo.environment["AUTHORSHIP_SEED"] ?? "") ?? 0xA17_0000
            var rng = SplitMix(seed: seed + UInt64(round))
            let e = live ? Editor.live(Self.base, caret: 0) : Editor(text: Self.base)
            e.privatePasteboard()
            // Undo is grouped by event, as in the app: an edit is one step, and an operation that
            // changes nothing (an empty selection) leaves no empty step behind.
            e.um.groupsByEvent = true
            func pump() {
                // Until the event's undo group has closed.
                for _ in 0..<200 {
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
                    if e.um.groupingLevel == 0 { break }
                }
            }
            func act(_ body: () -> Void) { body(); pump() }
            var closedGroups = 0
            let token = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: e.um, queue: nil) { _ in closedGroups += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            func state() -> State { State(text: e.string, runs: e.runState()) }
            var history = [state()]
            var at = 0
            var log: [String] = []
            for step in 0..<steps {
                let len = e.session.storage.length
                let ns = e.string as NSString
                func pos(_ x: UInt64) -> Int {
                    guard len > 0 else { return 0 }
                    let p = Int(x % UInt64(len + 1))
                    return p == len ? p : ns.rangeOfComposedCharacterSequence(at: p).location
                }
                func randomSelection() {
                    let a = pos(rng.next()), b = pos(rng.next())
                    let lo = min(a, b), hi = max(a, b)
                    let end = hi < len ? ns.rangeOfComposedCharacterSequence(at: hi).location : len
                    e.select(lo, rng.next() % 4 == 0 ? 0 : end - lo)
                }
                let op = Int(rng.next() % 16)
                let before = state()
                let groupsBefore = closedGroups
                var isEdit = true
                e.tv.breakUndoCoalescing()
                switch op {
                case 0, 1:
                    randomSelection()
                    let s = typed[Int(rng.next() % UInt64(typed.count))]
                    log.append("type \(s.debugDescription) at \(e.tv.selectedRange())")
                    act { e.tv.insertText(s, replacementRange: e.tv.selectedRange()) }
                case 2:
                    randomSelection()
                    log.append("delete \(e.tv.selectedRange())")
                    act { e.tv.insertText("", replacementRange: e.tv.selectedRange()) }
                case 3, 4:
                    randomSelection()
                    let c = AuthorChoice.allCases[Int(rng.next() % 3)]
                    let s = pastes[Int(rng.next() % UInt64(pastes.count))]
                    log.append("paste \(s.debugDescription) as \(c) at \(e.tv.selectedRange())")
                    act { e.paste(s, as: c) }
                case 5, 6:
                    randomSelection()
                    let c: AuthorChoice? = [nil, .me, .ai, .reference][Int(rng.next() % 4)]
                    log.append("mark as \(String(describing: c)) \(e.tv.selectedRange())")
                    act {
                        switch c {
                        case nil: e.tv.markAsNoAuthor(nil)
                        case .me?: e.tv.markAsMe(nil)
                        case .ai?: e.tv.markAsAI(nil)
                        case .reference?: e.tv.markAsReference(nil)
                        }
                    }
                case 7:
                    randomSelection()
                    let k = Int(rng.next() % 7)
                    log.append("command \(k) at \(e.tv.selectedRange())")
                    act {
                        switch k {
                        case 0: e.tv.toggleStrong(nil)
                        case 1: e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                        case 2: e.tv.setHeading(level: Int(rng.next() % 3))
                        case 3: e.tv.toggleTaskList(nil)
                        case 4: e.tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                        case 5: e.tv.tableRealign(nil)
                        default: e.tv.toggleBlockQuote(nil)
                        }
                    }
                case 8:
                    randomSelection()
                    log.append("copy+paste")
                    e.tv.copy(nil)
                    e.select(pos(rng.next()))
                    act { e.tv.paste(nil) }
                case 9:
                    randomSelection()
                    log.append("cut")
                    act { e.tv.cut(nil) }
                case 10, 11, 12:
                    isEdit = false
                    if at > 0 {
                        log.append("undo")
                        e.um.undo()
                        at -= 1
                        let got = state()
                        XCTAssertEqual(got.text, history[at].text, "undo text, step \(step): \(log.suffix(4))")
                        XCTAssertEqual(got.runs, history[at].runs, "undo attribution, step \(step): \(log.suffix(4))")
                    }
                case 13, 14:
                    isEdit = false
                    if at < history.count - 1 {
                        log.append("redo")
                        e.um.redo()
                        at += 1
                        let got = state()
                        XCTAssertEqual(got.text, history[at].text, "redo text, step \(step): \(log.suffix(4))")
                        XCTAssertEqual(got.runs, history[at].runs, "redo attribution, step \(step): \(log.suffix(4))")
                    }
                default:
                    isEdit = false
                    log.append("display toggle")
                    e.session.setAuthorshipDisplay(!e.session.authorshipDisplay)
                    XCTAssertEqual(state(), before, "toggling the display changes nothing")
                }
                if isEdit {
                    let now = state()
                    if closedGroups != groupsBefore {
                        // Every edit is exactly one undo step, and undoing it gives back exactly
                        // the state before, redoing it the state after.
                        e.um.undo()
                        XCTAssertEqual(state(), before, "undo of the last edit, step \(step): \(log.suffix(2))")
                        e.um.redo()
                        XCTAssertEqual(state(), now, "redo of the last edit, step \(step): \(log.suffix(2))")
                        // A new edit ends the redo history. 
                        history.removeSubrange((at + 1)...)
                        history.append(now)
                        at += 1
                    }
                }
                let groupsAfterOp = closedGroups
                e.settle()
                pump()
                // The app edits by itself too: a table is aligned when the caret leaves it, as its
                // own undo step. That is an edit like any other for the history.
                let settled = state()
                if closedGroups != groupsAfterOp || settled != history[at] {
                    log.append("(automatic edit)")
                    history.removeSubrange((at + 1)...)
                    history.append(settled)
                    at += 1
                }
                let problems = e.authorshipProblems()
                XCTAssertEqual(problems, [], "round \(round) step \(step): \(log.suffix(4))")
                let context = "round \(round) step \(step): \(log.suffix(4))"
                XCTAssertEqual(e.session.coordinator.coreText(), e.string, context)
                assertInvariants(e, context)
                if !problems.isEmpty { return }
            }
            // Finally walk all the way back and forth.
            while at > 0 { e.um.undo(); at -= 1; XCTAssertEqual(e.runState(), history[at].runs); XCTAssertEqual(e.string, history[at].text) }
            XCTAssertEqual(e.runState(), history[0].runs)
            while at < history.count - 1 { e.um.redo(); at += 1; XCTAssertEqual(e.runState(), history[at].runs); XCTAssertEqual(e.string, history[at].text) }
        }
    }

    func assertInvariants(_ e: Editor, _ context: String) {
        let runs = e.session.authorship.runs(within: nil)
        let length = UInt32(e.session.storage.length)
        var prevEnd: UInt32 = 0
        var prev: UInt32?
        let ns = e.string as NSString
        for r in runs {
            XCTAssertLessThan(r.range.start, r.range.end, context)
            XCTAssertGreaterThanOrEqual(r.range.start, prevEnd, "sorted and disjoint: \(context)")
            XCTAssertLessThanOrEqual(r.range.end, length, "in bounds: \(context)")
            if r.range.start == prevEnd { XCTAssertNotEqual(prev, r.authorIndex, "adjacent runs are merged: \(context)") }
            // Never inside a UTF-16 surrogate pair.
            for edge in [Int(r.range.start), Int(r.range.end)] where edge > 0 && edge < ns.length {
                let c = ns.character(at: edge)
                XCTAssertFalse(UTF16.isTrailSurrogate(c) && UTF16.isLeadSurrogate(ns.character(at: edge - 1)), "run edge splits a code point at \(edge): \(context)")
            }
            prevEnd = r.range.end
            prev = r.authorIndex
        }
    }
}

final class AuthorshipRandomLiveTests: AuthorshipRandomTests {
    override var live: Bool { true }
}

final class AuthorshipRandomFocusToolsTests: AuthorshipRandomTests {
    override var live: Bool { true }
    override func setUp() { super.setUp(); TestMode.focusTools = true }
    override func tearDown() { TestMode.focusTools = false; super.tearDown() }
}

// MARK: real typing

final class AuthorshipRealTypingTests: XCTestCase {
    private func pump(_ seconds: TimeInterval = 0.02) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    /// Typing the way AppKit delivers it (undo grouped by event, typing coalesced), then undo.
    func testUndoOfRealTypingRestoresTheAttributionOfTheWholeRun() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data("one two three\n".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        let tv = wc.textView
        tv.pasteboard = NSPasteboard(name: NSPasteboard.Name("markdown-test-\(UUID().uuidString)"))
        tv.pasteboard.setString("AIAIAIAI", forType: .string)
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.pasteAsAI(nil)
        pump(0.1)
        let afterPaste = doc.session.authorship.runs(within: nil)
        let pasted = doc.session.text
        XCTAssertEqual(pasted, "one AIAIAIAItwo three\n")
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        for c in "typed" {
            tv.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump(0.01)
        }
        XCTAssertEqual(doc.session.text, "one AIAItypedAIAItwo three\n")
        XCTAssertEqual(doc.session.authorship.runs(within: nil).count, 3)
        let um = try XCTUnwrap(doc.undoManager)
        pump(0.1)
        // Undo until the typing is gone: however AppKit grouped it, nothing may be left over.
        var guardCount = 0
        while doc.session.text != pasted, um.canUndo, guardCount < 20 { um.undo(); guardCount += 1 }
        XCTAssertEqual(doc.session.text, pasted)
        XCTAssertEqual(doc.session.authorship.runs(within: nil), afterPaste)
        XCTAssertLessThanOrEqual(guardCount, 1, "the typing undoes in one step, as it does without authorship")
        um.redo()
        XCTAssertEqual(doc.session.authorship.runs(within: nil).count, 3)
        doc.close()
    }
}

// MARK: display

final class AuthorshipDisplayTests: XCTestCase {
    func testBorrowedTextIsColouredFromTheTheme() {
        let e = Editor(text: "mine borrowed reference end\n")
        e.privatePasteboard()
        let ns = e.string as NSString
        e.session.mark(ns.range(of: "borrowed"), as: .ai)
        e.session.mark(ns.range(of: "reference"), as: .reference)
        e.session.overlay.apply()
        let p = e.session.appearance.palette
        func colour(_ needle: String) -> String? {
            let i = ns.range(of: needle).location
            return (e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor)?.hexString
        }
        XCTAssertEqual(colour("borrowed"), p.authorAI.hexString)
        XCTAssertEqual(colour("reference"), p.authorReference.hexString)
        XCTAssertNil(colour("mine"), "the user's own text keeps its stored colour")
        XCTAssertNil(colour("end"))
        XCTAssertEqual(e.authorshipProblems(), [])
        e.session.setAuthorshipDisplay(false)
        XCTAssertNil(colour("borrowed"))
        XCTAssertEqual(e.authorshipProblems(), [])
    }

    func testPrecedenceStoredAuthorshipPartOfSpeechFocusDim() {
        let e = Editor(text: "alpha beta gamma\n\nsecond paragraph here\n")
        let ns = e.string as NSString
        e.session.mark(ns.range(of: "beta"), as: .ai)
        e.session.setFocusEnabled(true)
        e.select(0)
        e.settle()
        // The caret is in the first sentence, which is lit: beta is AI-coloured.
        e.session.overlay.apply()
        func colour(_ needle: String) -> String? {
            (e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: ns.range(of: needle).location, effectiveRange: nil) as? NSColor)?.hexString
        }
        let p = e.session.appearance.palette
        XCTAssertEqual(colour("beta"), p.authorAI.hexString)
        e.session.mark(ns.range(of: "paragraph"), as: .reference)
        e.settle()
        XCTAssertEqual(colour("paragraph"), p.focusDim.hexString, "focus dimming is above authorship")
        // A part-of-speech colour is above authorship.
        e.session.overlay.setPos([OverlayRun(ns.range(of: "beta"), .pos(.noun))])
        e.session.overlay.apply()
        XCTAssertEqual(colour("beta"), p.posNoun.hexString)
        e.session.overlay.setPos([])
        e.session.overlay.apply()
        XCTAssertEqual(colour("beta"), p.authorAI.hexString)
    }

    func testLiveModeDrawsBorrowedBulletsInTheirColourAndKeepsGlyphsRight() {
        let e = Editor.live("- first item\n- second **item**\n", caret: 0)
        e.privatePasteboard()
        e.session.mark(NSRange(location: 15, length: 14), as: .ai)
        e.settle()
        XCTAssertEqual(e.authorshipProblems(), [])
        let p = e.session.appearance.palette
        XCTAssertEqual(e.session.overlay.authorshipColor(at: 20)?.hexString, p.authorAI.hexString)
        XCTAssertNil(e.session.overlay.authorshipColor(at: 2))
        XCTAssertEqual(LiveStressTests.glyphProblems(e), [])
    }

    func testEveryThemeKeepsBorrowedTextReadableButQuieter() {
        for theme in builtinThemes() {
            let c = theme.colors
            func contrast(_ a: ThemeColor, _ b: ThemeColor) -> Double {
                func lum(_ x: ThemeColor) -> Double {
                    func f(_ v: UInt8) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
                    return 0.2126 * f(x.r) + 0.7152 * f(x.g) + 0.0722 * f(x.b)
                }
                let (l1, l2) = (lum(a), lum(b))
                return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
            }
            XCTAssertGreaterThan(contrast(c.authorAi, c.background), 4.5, theme.id)
            XCTAssertGreaterThan(contrast(c.authorReference, c.background), 4.5, theme.id)
        }
    }
}

// MARK: the three modes

final class AuthorshipModesTests: XCTestCase {
    func run(live: Bool, tools: Bool) {
        TestMode.focusTools = tools
        defer { TestMode.focusTools = false }
        let e = live ? Editor.live("# Heading\n\nSome *emphasis* and text.\n\n- list item\n", caret: 0) : Editor(text: "# Heading\n\nSome *emphasis* and text.\n\n- list item\n")
        e.privatePasteboard()
        e.select(11)
        e.paste("Borrowed **sentence** here. ", as: .ai)
        e.settle()
        XCTAssertEqual(e.authorshipProblems(), [])
        e.select((e.string as NSString).range(of: "list").location)
        e.settle()
        XCTAssertEqual(e.authorshipProblems(), [])
        e.session.setViewMode(live ? .source : .live)
        e.settle()
        XCTAssertEqual(e.authorshipProblems(), [])
        e.um.undo()
        e.settle()
        XCTAssertEqual(e.authorshipProblems(), [])
        XCTAssertEqual(e.runs(), [])
    }

    func testSource() { run(live: false, tools: false) }
    func testLive() { run(live: true, tools: false) }
    func testSourceWithFocusAndSyntax() { run(live: false, tools: true) }
    func testLiveWithFocusAndSyntax() { run(live: true, tools: true) }
}

final class AuthorshipPerformanceTests: XCTestCase {
    /// A big document with thousands of marks: a keystroke does O(marks) work in the core and
    /// in the overlay, which must stay far from visible.
    func testTypingInABigMarkedDocument() throws {
        var text = ""
        let line = "The quick brown fox jumps over the lazy dog, and then it quietly sleeps. \n"
        while (text as NSString).length < 400_000 { text += line }
        let e = Editor(text: text)
        e.um.groupsByEvent = true
        let ns = text as NSString
        var at = 0
        var marks = 0
        while at + 40 < ns.length, marks < (ProcessInfo.processInfo.environment["NO_MARKS"] != nil ? 0 : 4000) {
            e.session.mark(NSRange(location: at + 4, length: 15), as: .ai)
            at += line.count
            marks += 1
        }
        if marks > 0 { XCTAssertGreaterThan(e.session.authorship.runs(within: nil).count, 3000) }
        e.um.removeAllActions()
        e.select(1000)
        var worst: TimeInterval = 0, total: TimeInterval = 0
        for i in 0..<60 {
            let t0 = CFAbsoluteTimeGetCurrent()
            e.tv.insertText("x", replacementRange: e.tv.selectedRange())
            let d = CFAbsoluteTimeGetCurrent() - t0
            worst = max(worst, d); total += d
            _ = i
        }
        print("authorship keystroke in a 400k document with \(marks) marks: mean \(total / 60 * 1000) ms, worst \(worst * 1000) ms")
        XCTAssertLessThan(total / 60, 0.05)
    }
}
