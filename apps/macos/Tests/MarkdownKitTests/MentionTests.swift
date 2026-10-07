import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The Mentions section of the Backlinks panel, and the Link button: the panel's rows, what
/// `refreshBacklinks` fetches, and what linking does to an open and to a closed note.
final class MentionTests: XCTestCase {
    private var lib: TempLibrary!
    private var controller: LibraryController!
    private var ws: Workspace!
    private var docs: [MarkdownDocument] = []
    private var windows: [EditorWindowController] = []

    override func setUpWithError() throws {
        lib = try TempLibrary([
            "Target.md": "---\naliases: [QG patch]\n---\n# Quantum Garden\n",
            "Open.md": "# Open Note\n\nWe talked about the quantum garden yesterday.\n",
            "Closed.md": "# Closed Note\n\nSee target for details.\n",
            "Linked.md": "# Linked Note\n\nSee [[Target]] here.\n",
        ])
        controller = LibraryController()
        controller.setRoots([lib.root])
        XCTAssertTrue(controller.waitUntilIdle())
        ws = Workspace(library: controller, settings: isolatedSettings(), notesMode: true)
        XCTAssertTrue(waitUntil { !ws.snapshot.roots.isEmpty })
        Workspace.pushDelay = 0.05
        Workspace.pushLimit = 0.2
    }

    override func tearDown() {
        Workspace.pushDelay = 0.5
        Workspace.pushLimit = 1.0
        for w in windows { w.leaveWorkspace() }
        windows = []
        for d in docs { d.updateChangeCount(.changeCleared); d.close() }
        docs = []
        lib.remove()
    }

    private func open(_ path: String) throws -> (MarkdownDocument, EditorWindowController) {
        let url = lib.url.appendingPathComponent(path)
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: url, ofType: "net.daringfireball.markdown")
        doc.fileURL = url
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        XCTAssertTrue(doc.session.waitUntilStyled())
        doc.session.onLibraryTextChange = { [weak self, weak doc] in if let doc { self?.ws.documentEdited(doc) } }
        docs.append(doc)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.adopt(ws)
        windows.append(wc)
        return (doc, wc)
    }

    private func mention(_ from: String) -> NoteMention {
        NoteMention(to: NoteRef(root: "lib", path: "Target.md"), from: NoteRef(root: "lib", path: from), fromTitle: from, range: Utf16Range(start: 0, end: 1),
                    context: "context of \(from)", name: "Target")
    }

    private func backlink(_ from: String) -> NoteBacklink {
        NoteBacklink(from: NoteRef(root: "lib", path: from), fromTitle: from, range: Utf16Range(start: 0, end: 1), context: "link in \(from)")
    }

    // MARK: the panel

    func testTheMentionsHeaderShowsOnlyWithMentions() throws {
        let panel = BacklinksPanel(frame: NSRect(x: 0, y: 0, width: 260, height: 190))
        panel.setLinks([backlink("A")])
        XCTAssertEqual(panel.table.numberOfRows, 1)
        panel.setLinks([backlink("A")], mentions: [mention("B"), mention("C")])
        XCTAssertEqual(panel.table.numberOfRows, 4, "a backlink, the header and two mentions")
        XCTAssertTrue(panel.tableView(panel.table, isGroupRow: 1))
        XCTAssertEqual((panel.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? MentionsHeaderCell)?.label.stringValue, "Mentions")
        panel.setLinks([backlink("A")])
        XCTAssertEqual(panel.table.numberOfRows, 1, "no mentions, no header")
        panel.setLinks([], mentions: [mention("B")])
        XCTAssertEqual(panel.table.numberOfRows, 3, "the empty line, the header and the mention")
    }

    func testMentionRowsHaveALinkButtonLabelledForVoiceOver() throws {
        let panel = BacklinksPanel(frame: NSRect(x: 0, y: 0, width: 260, height: 190))
        var linked: [NoteMention] = []
        var opened: [NoteMention] = []
        panel.onLinkMention = { linked.append($0) }
        panel.onOpenMention = { opened.append($0) }
        panel.setLinks([backlink("A")], mentions: [mention("B"), mention("C")])
        let cell = try XCTUnwrap(panel.table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? MentionCell)
        XCTAssertEqual(cell.title.stringValue, "B")
        XCTAssertEqual(cell.context.stringValue, "context of B")
        XCTAssertEqual(cell.link.title, "Link")
        XCTAssertEqual(cell.link.accessibilityLabel(), "Link mention in B")
        XCTAssertEqual(cell.accessibilityLabel(), "B: context of B", "as a backlink row")
        let button = try XCTUnwrap(panel.linkButton(at: 1))
        XCTAssertEqual(button.accessibilityLabel(), "Link mention in C")
        button.performClick(nil)
        XCTAssertEqual(linked.map(\.fromTitle), ["C"])
        XCTAssertTrue(opened.isEmpty, "the button is not a row click")
        XCTAssertNil(panel.linkButton(at: 2))
    }

    // MARK: refreshing

    func testRefreshBacklinksFetchesBothSections() throws {
        let (_, wc) = try open("Target.md")
        ws.setBacklinksShown(true)
        let panel = try XCTUnwrap(wc.sidebar?.view.backlinks)
        XCTAssertTrue(waitUntil { panel.mentions.count == 2 && panel.links.count == 1 })
        XCTAssertEqual(panel.links.map(\.fromTitle), ["Linked Note"])
        XCTAssertEqual(panel.mentions.map(\.fromTitle), ["Closed Note", "Open Note"])
        XCTAssertEqual(panel.mentions.map(\.name), ["Target", "Quantum Garden"])
    }

    // MARK: linking

    func testLinkingAMentionInAnOpenNoteIsOneUndoStepAndTheRowMovesToBacklinks() throws {
        let (_, wc) = try open("Target.md")
        let (open, _) = try self.open("Open.md")
        ws.setBacklinksShown(true)
        let panel = try XCTUnwrap(wc.sidebar?.view.backlinks)
        XCTAssertTrue(waitUntil { panel.mentions.count == 2 })
        let m = try XCTUnwrap(panel.mentions.first { $0.fromTitle == "Open Note" })
        wc.linkMention(m)
        XCTAssertTrue(waitUntil { panel.links.map(\.fromTitle).contains("Open Note") && panel.mentions.count == 1 })
        XCTAssertEqual(open.session.text, "# Open Note\n\nWe talked about the [[Target|quantum garden]] yesterday.\n")
        XCTAssertEqual(open.undoManager?.undoActionName, "Link Mention")
        XCTAssertEqual(lib.read("Open.md"), "# Open Note\n\nWe talked about the quantum garden yesterday.\n", "an open note is not written behind its back")
        open.undoManager?.undo()
        XCTAssertEqual(open.session.text, "# Open Note\n\nWe talked about the quantum garden yesterday.\n", "one undo takes it back")
    }

    func testLinkingAMentionInAClosedNoteRewritesTheFile() throws {
        let (_, wc) = try open("Target.md")
        ws.setBacklinksShown(true)
        let panel = try XCTUnwrap(wc.sidebar?.view.backlinks)
        XCTAssertTrue(waitUntil { panel.mentions.count == 2 })
        let m = try XCTUnwrap(panel.mentions.first { $0.fromTitle == "Closed Note" })
        wc.linkMention(m)
        XCTAssertTrue(waitUntil { panel.links.map(\.fromTitle).contains("Closed Note") && panel.mentions.count == 1 })
        XCTAssertEqual(lib.read("Closed.md"), "# Closed Note\n\nSee [[target]] for details.\n")
    }

    func testAStaleMentionLeavesTheTextAlone() throws {
        let (_, wc) = try open("Target.md")
        ws.setBacklinksShown(true)
        let panel = try XCTUnwrap(wc.sidebar?.view.backlinks)
        XCTAssertTrue(waitUntil { panel.mentions.count == 2 })
        let m = try XCTUnwrap(panel.mentions.first { $0.fromTitle == "Closed Note" })
        // The note changes under the panel: the range no longer holds the name.
        try lib.write("Closed.md", "# Closed Note\n\nNothing to see here, move along.\n")
        controller.refresh([lib.url.appendingPathComponent("Closed.md")])
        XCTAssertTrue(controller.waitUntilIdle())
        var edit: LibraryEdit?
        var answered = false
        controller.linkMentionEdit(m) { edit = $0; answered = true }
        XCTAssertTrue(waitUntil { answered })
        XCTAssertNil(edit)
        wc.linkMention(m)
        XCTAssertTrue(waitUntil { panel.mentions.count == 1 })
        XCTAssertEqual(lib.read("Closed.md"), "# Closed Note\n\nNothing to see here, move along.\n")
    }
}
