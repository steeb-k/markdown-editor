import AppKit
import WebKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Format > Template (PLAN 3.21): the submenu's items and checks, the front matter edit as one undo step, and the preview, PDF
/// and print pages taking the resolved template's stylesheet.
@MainActor
final class TemplateMenuTests: XCTestCase {
    private var tmp: URL!
    private var saved: TemplateStore!
    private var store: TemplateStore!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("template-menu-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        saved = TemplateStore.shared
        store = TemplateStore(builtInDirectory: TemplateStore.defaultBuiltInDirectory, userDirectory: tmp.appendingPathComponent("yours"))
        TemplateStore.shared = store
        // Two templates of this suite's own, each with a marker in its custom CSS that no other stylesheet has.
        for name in ["Marked", "Other"] {
            let t = try store.create(name)
            try "/* marker-\(name.lowercased()) */".write(to: t.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        }
        store.reload()
    }

    override func tearDownWithError() throws {
        TemplateStore.shared = saved
        try? FileManager.default.removeItem(at: tmp)
    }

    private func pump(_ seconds: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func open(_ text: String, layout: LayoutMode = .editor, settings: Settings = isolatedSettings()) throws -> (MarkdownDocument, EditorWindowController) {
        settings.defaultLayout = layout
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    private func templateMenu(for wc: EditorWindowController?) -> NSMenu {
        let format = MainMenu.build().items.first { $0.title == "Format" }?.submenu
        let menu = format?.items.first { $0.title == "Template" }?.submenu ?? NSMenu()
        DocumentTemplateMenu.fill(menu, for: wc)
        return menu
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
    private func checked(_ menu: NSMenu) -> [String] { menu.items.filter { $0.state == .on }.map(\.title) }

    private func choose(_ name: String, in wc: EditorWindowController) throws {
        let item = try XCTUnwrap(templateMenu(for: wc).items.first { ($0.representedObject as? String) == name }, "no item \(name)")
        XCTAssertTrue(wc.validateMenuItem(item))
        wc.chooseLookTemplate(item)
    }

    private func style(of p: PreviewController) -> String {
        p.evaluateSync("return document.head.querySelector('style').textContent;") as? String ?? ""
    }

    // MARK: the submenu

    func testTheSubmenuIsInFormatAndListsTheTemplates() throws {
        let format = try XCTUnwrap(MainMenu.build().items.first { $0.title == "Format" }?.submenu)
        let holder = try XCTUnwrap(format.items.first { $0.title == "Template" })
        XCTAssertNotNil(holder.submenu?.delegate, "rebuilt when it opens")
        let (doc, wc) = try open("text\n")
        let menu = templateMenu(for: wc)
        XCTAssertEqual(titles(menu), ["Default template", "-", "Academic", "Default", "Letter", "Marked", "Other", "Typewriter"])
        XCTAssertEqual(menu.items[0].representedObject as? String, "")
        doc.close()
    }

    func testTheCheckFollowsTheFrontMatterElseTheDefaultItem() throws {
        let (a, plain) = try open("text\n")
        XCTAssertEqual(checked(templateMenu(for: plain)), ["Default template"], "no name in the front matter: the default item, not what it resolves to")
        a.close()

        let settings = isolatedSettings()
        settings.defaultTemplate = "Typewriter"
        let (b, named) = try open("---\ntemplate: academic\n---\n\ntext\n", settings: settings)
        XCTAssertEqual(checked(templateMenu(for: named)), ["Academic"], "case-insensitive; the front matter beats the app's default")
        b.close()

        let (c, missing) = try open("---\ntemplate: Nowhere\n---\n\ntext\n", settings: settings)
        let menu = templateMenu(for: missing)
        XCTAssertEqual(checked(menu), ["Default template"])
        let note = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(note.title, "Nowhere (not installed)")
        XCTAssertFalse(note.isEnabled)
        XCTAssertNil(note.action)
        c.close()
    }

    func testANewTemplateAppearsWhenTheMenuOpens() throws {
        let (doc, wc) = try open("text\n")
        let menu = templateMenu(for: wc)
        XCTAssertFalse(titles(menu).contains("Fresh"))
        _ = try store.create("Fresh")
        DocumentTemplateMenu.shared.menuNeedsUpdate(menu)   // (no key window here: the items without a document)
        XCTAssertTrue(titles(menu).contains("Fresh"))
        doc.close()
    }

    // MARK: choosing

    func testChoosingAppliesOneUndoableEditAndTheDefaultItemRemovesTheKey() throws {
        let original = "# Title\n\nSome text.\n"
        let (doc, wc) = try open(original)
        let um = try XCTUnwrap(doc.undoManager)
        um.groupsByEvent = false
        wc.textView.setSelectedRange(NSRange(location: 9, length: 4))   // "Some"

        um.beginUndoGrouping()
        try choose("Academic", in: wc)
        um.endUndoGrouping()
        XCTAssertEqual(doc.session.text, "---\ntemplate: Academic\n---\n\n" + original)
        XCTAssertEqual(um.undoActionName, "Change Template")
        XCTAssertEqual(checked(templateMenu(for: wc)), ["Academic"])
        XCTAssertEqual(wc.textView.selectedRange(), NSRange(location: 9 + 28, length: 4), "the caret stays with its words")
        XCTAssertEqual(doc.session.resolvedTemplate(frontMatterName: doc.session.frontMatterTemplateName()).template.name, "Academic")

        um.undo()
        XCTAssertEqual(doc.session.text, original, "one undo restores the text")
        XCTAssertFalse(um.canUndo)
        um.redo()
        XCTAssertEqual(doc.session.frontMatterTemplateName(), "Academic")

        // Another one rewrites the line; the default item removes it and the block it leaves empty.
        um.beginUndoGrouping()
        try choose("Letter", in: wc)
        um.endUndoGrouping()
        XCTAssertEqual(doc.session.frontMatterTemplateName(), "Letter")
        um.beginUndoGrouping()
        try choose("", in: wc)
        um.endUndoGrouping()
        XCTAssertEqual(doc.session.text, original)
        XCTAssertNil(doc.session.frontMatterTemplateName())
        XCTAssertEqual(checked(templateMenu(for: wc)), ["Default template"])

        // Choosing what is already there changes nothing.
        let count = um.canUndo
        try choose("", in: wc)
        XCTAssertEqual(um.canUndo, count)
        XCTAssertEqual(doc.session.text, original)
        doc.close()
    }

    func testChoosingKeepsOtherFrontMatter() throws {
        let (doc, wc) = try open("---\ntitle: Paper\n---\n\nbody\n")
        try choose("Typewriter", in: wc)
        XCTAssertEqual(doc.session.text, "---\ntitle: Paper\ntemplate: Typewriter\n---\n\nbody\n")
        try choose("", in: wc)
        XCTAssertEqual(doc.session.text, "---\ntitle: Paper\n---\n\nbody\n")
        doc.close()
    }

    // MARK: the pages

    func testThePreviewTakesTheChosenTemplateAndFollowsTheFrontMatter() throws {
        let (doc, wc) = try open("# Title\n\ntext\n", layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertFalse(style(of: p).contains("marker-"))
        XCTAssertEqual(style(of: p).trimmingCharacters(in: .whitespacesAndNewlines), p.previewCSS().trimmingCharacters(in: .whitespacesAndNewlines))

        try choose("Marked", in: wc)
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertTrue(style(of: p).contains("/* marker-marked */"), "the front matter edit restyles the page in place")
        XCTAssertTrue(style(of: p).hasSuffix("/* marker-marked */"), "custom CSS last")
        XCTAssertEqual(p.appliedTemplate, store.template(named: "Marked")?.url)
        XCTAssertEqual(p.renders, 2, "a render for the edit, not a reload")

        try choose("Other", in: wc)
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertTrue(style(of: p).contains("marker-other") && !style(of: p).contains("marker-marked"))

        try choose("", in: wc)
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertFalse(style(of: p).contains("marker-"))
        doc.close()
    }

    func testThePageIsFirstLoadedWithTheDocumentsOwnTemplate() throws {
        let (doc, wc) = try open("---\ntemplate: Marked\n---\n\ntext\n", layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertTrue(style(of: p).contains("marker-marked"))
        doc.close()
    }

    func testTheAppsDefaultTemplateAppliesWhereTheFrontMatterNamesNone() throws {
        let settings = isolatedSettings()
        let (doc, wc) = try open("text\n", layout: .split, settings: settings)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertFalse(style(of: p).contains("marker-"))
        settings.defaultTemplate = "Other"
        wc.session.onAppearanceChange?()   // what the window does when a setting changes
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertTrue(style(of: p).contains("marker-other"))
        // And a template that is not installed falls back to the Default.
        settings.defaultTemplate = "Gone"
        wc.session.onAppearanceChange?()
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertFalse(style(of: p).contains("marker-"))
        doc.close()
    }

    func testEditingATemplateOnDiskRestylesOpenPreviews() throws {
        let (doc, wc) = try open("---\ntemplate: Marked\n---\n\ntext\n", layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        let t = try XCTUnwrap(store.template(named: "Marked"))
        try "/* marker-edited */".write(to: t.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertTrue(p.waitUntilSettled(timeout: 30))
        XCTAssertTrue(style(of: p).contains("marker-edited") && !style(of: p).contains("marker-marked"))
        doc.close()
    }

    func testPDFAndPrintPagesCarryTheTemplate() throws {
        let (doc, wc) = try open("---\ntemplate: Marked\n---\n\n# Title\n")
        _ = wc
        var page: String?
        let done = expectation(description: "page")
        (doc as MarkdownDocument).renderStandalone { page = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        let html = try XCTUnwrap(page)
        XCTAssertTrue(html.contains("/* marker-marked */\n</style>\n</head>"))
        XCTAssertEqual(html.components(separatedBy: "<style>").count, 2, "the one stylesheet, replaced rather than added to")
        XCTAssertTrue(html.contains("<main class=\"md\" id=\"md\">"), "the rest of the page is the core's")
        doc.close()
    }

    func testAStylesheetCannotEndItsStyleElement() {
        let page = "<html><head>\n<style>\nbody{}\n</style>\n</head><body></body></html>"
        let out = TemplateStore.replacingStyle(inPage: page, with: "a{} </STYLE><script>x</script>")
        XCTAssertEqual(out.components(separatedBy: "</style>").count, 2, "only the page's own closing tag")
        XCTAssertFalse(out.contains("body{}"))
    }
}
