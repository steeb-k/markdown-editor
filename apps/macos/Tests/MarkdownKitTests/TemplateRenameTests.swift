import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// What renaming a template does to the documents that name it, and to the setting (PLAN 3.22).
@MainActor
final class TemplateRenameTests: XCTestCase {
    private var lib: TempLibrary!
    private var outside: TempLibrary!
    private var controller: LibraryController!
    private var ws: Workspace!
    private var window: TemplatesWindowController!
    private var docs: [MarkdownDocument] = []
    private var questions: [String] = []
    private var answer = true
    private var savedDefault = ""
    private var tmp: URL!

    private var editor: TemplateEditor { window.editor }

    override func setUpWithError() throws {
        lib = try TempLibrary([
            "Open.md": "---\ntemplate: Paper\n---\n\nOpen\n",
            "Closed.md": "---\ntemplate: \"paper\"\n---\n\nClosed\n",
            "Letter.md": "---\ntemplate: Letter\n---\n\nLetter\n",
            "Plain.md": "No front matter\n",
        ])
        outside = try TempLibrary(["Stray.md": "---\ntemplate: PAPER\n---\n\nStray\n"])
        controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
        ws = Workspace(library: controller, settings: isolatedSettings(), notesMode: true)
        XCTAssertTrue(waitUntil { !ws.snapshot.roots.isEmpty })
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("template-rename-\(UUID().uuidString)")
        let builtIn = Fixtures.root.appendingPathComponent("apps/macos/Resources/Templates")
        window = TemplatesWindowController(store: TemplateStore(builtInDirectory: builtIn, userDirectory: tmp))
        let paper = try editor.store.create("Paper")
        XCTAssertTrue(editor.select(named: paper.name))
        questions = []
        answer = true
        WorkspacePrompts.templateUpdateOverride = { [unowned self] q in questions.append(q); return answer }
        savedDefault = Settings.shared.defaultTemplate
    }

    override func tearDown() {
        WorkspacePrompts.templateUpdateOverride = nil
        Settings.shared.defaultTemplate = savedDefault
        for d in docs { d.updateChangeCount(.changeCleared); d.close() }
        docs = []
        window.window?.orderOut(nil)
        window = nil
        lib.remove()
        outside.remove()
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func open(_ path: String, in place: TempLibrary? = nil) throws -> MarkdownDocument {
        let url = (place ?? lib).url.appendingPathComponent(path)
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: url, ofType: "net.daringfireball.markdown")
        doc.fileURL = url
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        XCTAssertTrue(doc.session.waitUntilStyled())
        if place == nil { doc.session.onLibraryTextChange = { [weak self, weak doc] in if let doc { self?.ws.documentEdited(doc) } } }
        docs.append(doc)
        return doc
    }

    private func offer(_ old: String = "Paper", _ new: String = "Thesis") {
        var finished = false
        editor.offerTemplateUpdate(from: old, to: new, library: controller, workspace: ws) { finished = true }
        XCTAssertTrue(waitUntil { finished })
        XCTAssertTrue(controller.waitUntilIdle())
    }

    func testUpdateWritesOpenAndClosedNotesAndStrayDocumentsOnce() throws {
        let open = try open("Open.md")
        let stray = try self.open("Stray.md", in: outside)
        offer()
        XCTAssertEqual(questions, ["Update 3 documents that use \u{201C}Paper\u{201D}?"])
        // A note that is open and in the library is written once, through its document (one undo step); a closed one on disk.
        XCTAssertEqual(open.session.text, "---\ntemplate: Thesis\n---\n\nOpen\n")
        XCTAssertEqual(open.undoManager?.undoActionName, "Change Template")
        XCTAssertEqual(lib.read("Open.md"), "---\ntemplate: Paper\n---\n\nOpen\n", "an open document is not written behind its back")
        XCTAssertEqual(lib.read("Closed.md"), "---\ntemplate: Thesis\n---\n\nClosed\n")
        open.undoManager?.undo()
        XCTAssertEqual(open.session.text, "---\ntemplate: Paper\n---\n\nOpen\n", "one undo takes it back")
        // A document outside the library is set through its session.
        XCTAssertEqual(stray.session.text, "---\ntemplate: Thesis\n---\n\nStray\n")
        // Unrelated notes are left alone.
        XCTAssertEqual(lib.read("Letter.md"), "---\ntemplate: Letter\n---\n\nLetter\n")
        XCTAssertEqual(lib.read("Plain.md"), "No front matter\n")
    }

    func testLeaveChangesNothing() throws {
        let open = try open("Open.md")
        answer = false
        offer()
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(open.session.text, "---\ntemplate: Paper\n---\n\nOpen\n")
        XCTAssertEqual(lib.read("Closed.md"), "---\ntemplate: \"paper\"\n---\n\nClosed\n")
    }

    func testNothingNamingTheTemplateAsksNothing() throws {
        offer("Nobody", "Somebody")
        XCTAssertTrue(questions.isEmpty)
        offer("Letter", "Note")
        XCTAssertEqual(questions, ["Update 1 document that uses \u{201C}Letter\u{201D}?"])
        XCTAssertEqual(lib.read("Letter.md"), "---\ntemplate: Note\n---\n\nLetter\n")
    }

    /// A closed note changed on disk while the question was up is not written with ranges from its old text (they cut
    /// into the new one); it is left and reported. The others are written.
    func testAClosedNoteChangedWhileTheQuestionIsUpIsLeftAndReported() throws {
        var reported: [Error] = []
        WorkspacePrompts.reportOverride = { reported.append($0) }
        defer { WorkspacePrompts.reportOverride = nil }
        let changed = "---\ntitle: Added on another machine\ntemplate: \"paper\"\n---\n\nClosed\n"
        WorkspacePrompts.templateUpdateOverride = { [unowned self] q in
            questions.append(q)
            try? lib.write("Closed.md", changed)
            return true
        }
        let open = try open("Open.md")
        offer()
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(lib.read("Closed.md"), changed)
        XCTAssertEqual(open.session.text, "---\ntemplate: Thesis\n---\n\nOpen\n")
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual((reported.first as NSError?)?.localizedDescription, "Some documents could not be updated")
        XCTAssertEqual((reported.first as NSError?)?.localizedRecoverySuggestion, "Closed.md")
    }

    /// An open note that takes no typing (an authorship question pending) refuses the edit; it is reported, not counted
    /// as written.
    func testAnOpenNoteThatTakesNoTypingIsReported() throws {
        var reported: [Error] = []
        WorkspacePrompts.reportOverride = { reported.append($0) }
        defer { WorkspacePrompts.reportOverride = nil }
        let open = try open("Open.md")
        open.session.textView?.isEditable = false
        offer()
        XCTAssertEqual(open.session.text, "---\ntemplate: Paper\n---\n\nOpen\n")
        XCTAssertEqual((reported.first as NSError?)?.localizedRecoverySuggestion, "Open.md")
        XCTAssertEqual(lib.read("Closed.md"), "---\ntemplate: Thesis\n---\n\nClosed\n")
    }

    /// A name is found as the store resolves it, accents and case aside: a note naming `resume` uses `Résumé`.
    func testANameWithoutItsAccentsIsFound() throws {
        try lib.write("Accentless.md", "---\ntemplate: resume\n---\n\nText\n")
        controller.refresh([lib.url.appendingPathComponent("Accentless.md")])
        XCTAssertTrue(controller.waitUntilIdle())
        let stray = try open("Stray.md", in: outside)
        XCTAssertTrue(stray.session.setTemplate(name: "RESUME"))
        offer("R\u{e9}sum\u{e9}", "CV")
        XCTAssertEqual(questions, ["Update 2 documents that use \u{201C}R\u{e9}sum\u{e9}\u{201D}?"])
        XCTAssertEqual(lib.read("Accentless.md"), "---\ntemplate: CV\n---\n\nText\n")
        XCTAssertEqual(stray.session.frontMatterTemplateName(), "CV")
    }

    func testTheSettingFollowsARenameAndADelete() throws {
        Settings.shared.defaultTemplate = "paper"
        editor.rename(to: "Thesis")
        XCTAssertEqual(Settings.shared.defaultTemplate, "Thesis")
        // Another template's rename leaves it.
        _ = try editor.store.create("Other")
        XCTAssertTrue(editor.select(named: "Other"))
        editor.rename(to: "Another")
        XCTAssertEqual(Settings.shared.defaultTemplate, "Thesis")
        XCTAssertTrue(editor.select(named: "Thesis"))
        editor.deleteSelected()
        XCTAssertEqual(Settings.shared.defaultTemplate, TemplateStore.defaultName)
        XCTAssertTrue(questions.isEmpty, "a delete asks nothing")
    }
}
