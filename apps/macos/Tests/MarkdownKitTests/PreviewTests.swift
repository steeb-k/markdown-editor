import AppKit
import PDFKit
import WebKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The preview, layouts, link policy, scroll mapping, PDF export and Copy As.
final class PreviewTests: XCTestCase {
    private func pump(_ seconds: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func spin(timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.01)
        }
        return condition()
    }

    private var tmp: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// A document with its window, as the app makes them; with `file` it has a place on disk.
    private func open(_ text: String, file: String? = nil, layout: LayoutMode = .editor) throws -> (MarkdownDocument, EditorWindowController) {
        let settings = isolatedSettings()
        settings.defaultLayout = layout
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        if let file {
            let url = tmp.appendingPathComponent(file)
            try Data(text.utf8).write(to: url)
            doc.fileURL = url
        }
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    private func coreBody(_ s: EditorSession, _ p: PreviewController) -> String {
        s.coordinator.sync { $0.renderHtml(options: p.renderOptions(standalone: false)) }
    }

    private func type(_ s: String, into tv: NSTextView) {
        for c in s {
            tv.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0))
            pump(0.01)
        }
    }

    // MARK: rendering

    func testPreviewBodyEqualsTheCoresRenderAfterEdits() throws {
        let (doc, wc) = try open("# Title\n\nSome *text*.\n\n```rust\nfn a() {}\n```\n", layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        XCTAssertEqual(p.lastBodyHTML, coreBody(doc.session, p))
        XCTAssertTrue(p.lastBodyHTML.contains("data-line=\"0\""), "scroll sync needs data-line")
        wc.textView.setSelectedRange(NSRange(location: 7, length: 0))
        type(" and more", into: wc.textView)
        XCTAssertTrue(p.waitUntilSettled())
        XCTAssertEqual(p.lastBodyHTML, coreBody(doc.session, p))
        XCTAssertTrue(p.lastBodyHTML.contains("Title and more"))
        // The page itself holds it too.
        let text = p.evaluateSync("return document.getElementById('md').innerText;") as? String
        XCTAssertTrue(text?.contains("Title and more") == true, text ?? "nil")
        doc.close()
    }

    func testSupersededRendersNeverApply() throws {
        let (doc, wc) = try open("one\n", layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        var shown: [String] = []
        p.onApplied = { shown.append(p.lastBodyHTML) }
        // The analysis of the first edit takes a while; the render queues behind it, the second edit
        // arrives while it is waiting: the render answers for a text that is already out of date.
        doc.session.coordinator.artificialDelay = 0.25
        wc.textView.setSelectedRange(NSRange(location: 3, length: 0))
        wc.textView.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))
        pump(0.15)
        wc.textView.insertText("B", replacementRange: NSRange(location: NSNotFound, length: 0))
        doc.session.coordinator.artificialDelay = 0
        XCTAssertTrue(p.waitUntilSettled())
        XCTAssertGreaterThanOrEqual(p.superseded, 1)
        XCTAssertFalse(shown.contains { $0.contains("oneA<") || $0.contains("oneA\n") && !$0.contains("oneAB") }, "a stale render reached the page: \(shown)")
        XCTAssertEqual(p.lastBodyHTML, coreBody(doc.session, p))
        XCTAssertTrue(p.lastBodyHTML.contains("oneAB"))
        doc.close()
    }

    func testNothingIsRenderedWhileHidden() throws {
        let (doc, wc) = try open("# Hidden\n")
        let p = wc.previewController
        wc.textView.setSelectedRange(NSRange(location: 8, length: 0))
        type(" still", into: wc.textView)
        pump(0.5)
        XCTAssertEqual(p.renders, 0, "the editor-only layout renders nothing")
        XCTAssertFalse(p.isVisible)
        doc.session.setLayout(.split)
        XCTAssertTrue(p.waitUntilSettled())
        XCTAssertEqual(p.renders, 1)
        XCTAssertTrue(p.lastBodyHTML.contains("Hidden still"))
        // Hidden again: edits wait; coming back renders once.
        doc.session.setLayout(.editor)
        type("er", into: wc.textView)
        pump(0.5)
        XCTAssertEqual(p.renders, 1)
        doc.session.setLayout(.preview)
        XCTAssertTrue(p.waitUntilSettled())
        XCTAssertTrue(p.lastBodyHTML.contains("Hidden stiller"))
        doc.close()
    }

    func testThePageRunsNoJavaScriptOfItsOwn() throws {
        let (doc, wc) = try open("<script>document.body.setAttribute('data-ran', 'yes')</script>\n\n<img src=x onerror=\"document.body.setAttribute('data-ran', 'yes')\">\n\ntext\n", layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        pump(0.5)
        XCTAssertEqual(p.evaluateSync("return document.body.getAttribute('data-ran');") as? String, nil)
        XCTAssertTrue(p.lastBodyHTML.contains("<script>"), "the raw HTML is in the page; it just does not run")
        // The app's own world is alive.
        XCTAssertEqual(p.evaluateSync("return 1 + 1;") as? Int, 2)
        doc.close()
    }

    // MARK: local pictures

    func testSchemeResolutionIsLimitedToTheDocumentFolderAndExplicitPaths() {
        let folder = URL(fileURLWithPath: "/Users/me/notes")
        func r(_ s: String, folder: URL? = folder) -> PreviewURL.Resolution { PreviewURL.resolve(URL(string: s)!, documentFolder: folder, home: URL(fileURLWithPath: "/Users/me")) }
        XCTAssertEqual(r("mdoc://doc/rel/img/a.png"), .file(URL(fileURLWithPath: "/Users/me/notes/img/a.png")))
        XCTAssertEqual(r("mdoc://doc/rel/a%20b.png"), .file(URL(fileURLWithPath: "/Users/me/notes/a b.png")))
        XCTAssertEqual(r("mdoc://doc/rel/../secret.png"), .denied, "the document's folder and below only")
        XCTAssertEqual(r("mdoc://doc/rel/a/../../secret.png"), .denied)
        XCTAssertEqual(r("mdoc://doc/rel/%2e%2e/secret.png"), .denied)
        XCTAssertEqual(r("mdoc://doc/rel/img/a.png", folder: nil), .denied, "an untitled document has no base")
        XCTAssertEqual(r("mdoc://doc/abs/Users/me/pics/a.png"), .file(URL(fileURLWithPath: "/Users/me/pics/a.png")), "named outright, as the editor allows")
        XCTAssertEqual(r("mdoc://doc/home/pics/a.png"), .file(URL(fileURLWithPath: "/Users/me/pics/a.png")))
        XCTAssertEqual(r("mdoc://doc/font/iAWriterQuattroS-Regular.ttf"), .font("iAWriterQuattroS-Regular.ttf"))
        XCTAssertEqual(r("mdoc://doc/other"), .denied)
        XCTAssertEqual(r("https://doc/rel/a.png"), .unknown)
        XCTAssertEqual(r("mdoc://elsewhere/rel/a.png"), .unknown)
    }

    func testTheSchemeHandlerServesADocumentRelativePicture() throws {
        let png = try Data(contentsOf: Fixtures.root.appendingPathComponent("scripts/macos/ui/fixtures/images/small.png"))
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("img"), withIntermediateDirectories: true)
        try png.write(to: tmp.appendingPathComponent("img/small.png"))
        try Data("secret".utf8).write(to: tmp.deletingLastPathComponent().appendingPathComponent("outside-\(tmp.lastPathComponent).png"))
        let md = "![ok](img/small.png)\n\n![missing](img/none.png)\n\n![outside](../outside-\(tmp.lastPathComponent).png)\n\n![abs](file://\(tmp.path)/img/small.png)\n"
        let (doc, wc) = try open(md, file: "doc.md", layout: .split)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent().appendingPathComponent("outside-\(tmp.lastPathComponent).png")) }
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        func state() -> [String: Int] { p.evaluateSync("const i = [...document.images]; return {total: i.length, loaded: i.filter(x => x.complete && x.naturalWidth > 0).length, broken: i.filter(x => x.complete && x.naturalWidth === 0).length};") as? [String: Int] ?? [:] }
        XCTAssertTrue(spin { state()["loaded"] == 2 && state()["broken"] == 2 }, "\(state())")
        XCTAssertGreaterThanOrEqual(p.schemeHandler.denied, 1, "the picture outside the folder was refused")
        XCTAssertTrue(p.schemeHandler.requests.contains { $0.path == "/rel/img/small.png" })
        doc.close()
    }

    // MARK: links

    func testLinkPolicy() {
        let folder = URL(fileURLWithPath: "/Users/me/notes")
        func decide(_ s: String, link: Bool = true, main: Bool = true, initial: Bool = false, folder: URL? = folder) -> LinkAction {
            LinkPolicy.decide(url: URL(string: s), isLinkActivation: link, isMainFrame: main, isInitialLoad: initial, documentFolder: folder)
        }
        let table: [(String, LinkAction)] = [
            ("https://example.com/a?b=c#d", .open(URL(string: "https://example.com/a?b=c#d")!)),
            ("http://example.com", .open(URL(string: "http://example.com")!)),
            ("mailto:a@b.c", .open(URL(string: "mailto:a@b.c")!)),
            ("tel:+123", .open(URL(string: "tel:+123")!)),
            ("mdoc://doc/rel/#the-end", .scrollToFragment("the-end")),
            ("mdoc://doc/rel/#caf%C3%A9", .scrollToFragment("café")),
            ("mdoc://doc/rel/", .ignore),
            ("mdoc://doc/rel/other.md", .open(URL(fileURLWithPath: "/Users/me/notes/other.md"))),
            ("mdoc://doc/rel/sub/x.pdf#page=2", .open(URL(fileURLWithPath: "/Users/me/notes/sub/x.pdf"))),
            ("mdoc://doc/rel/../escape.md", .ignore),
            ("file:///Users/me/a.txt", .open(URL(fileURLWithPath: "/Users/me/a.txt"))),
            ("javascript:alert(1)", .ignore),
            ("data:text/html,hi", .ignore),
            ("ftp://example.com/x", .ignore),
            ("x-apple.systempreferences:", .ignore),
        ]
        for (url, want) in table { XCTAssertEqual(decide(url), want, "\(url) \(PreviewURL.resolve(URL(string: url)!, documentFolder: folder))") }
        XCTAssertEqual(decide("mdoc://doc/rel/other.md", folder: nil), .ignore, "an untitled document has no neighbours")
        XCTAssertEqual(decide("https://example.com", link: false), .ignore, "only a click opens things")
        XCTAssertEqual(decide("https://example.com", main: false), .ignore, "a frame in the document's HTML navigates nowhere")
        XCTAssertEqual(decide("mdoc://doc/rel/", link: false, initial: true), .allow, "the app's own load of the page")
        XCTAssertEqual(decide("https://example.com", link: false, initial: true), .ignore)
        XCTAssertEqual(LinkPolicy.decide(url: nil, isLinkActivation: true, isMainFrame: true, isInitialLoad: false, documentFolder: nil), .ignore)
    }

    func testClickingLinksInThePreviewUsesThePolicy() throws {
        var opened: [URL] = []
        LinkOpener.opened = { opened.append($0); return true }
        defer { LinkOpener.opened = nil }
        let (doc, wc) = try open("# Top\n\n[web](https://example.com/x) [here](#top) [file](other.md)\n\n" + String(repeating: "filler\n\n", count: 80), file: "doc.md", layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        func click(_ text: String) {
            _ = p.evaluateSync("[...document.querySelectorAll('a')].find(a => a.textContent === t).click(); return true;", arguments: ["t": text])
            pump(0.3)
        }
        click("web")
        XCTAssertEqual(opened, [URL(string: "https://example.com/x")!])
        click("file")
        XCTAssertEqual(opened.last, tmp.appendingPathComponent("other.md").standardizedFileURL)
        _ = p.evaluateSync("window.scrollTo(0, 400); return 1;")
        pump(0.3)
        click("here")
        XCTAssertEqual(p.lastLinkAction, .scrollToFragment("top"))
        XCTAssertTrue(spin(timeout: 3) { p.scrollTopForTests < 100 }, "scrolled to the heading")
        XCTAssertEqual(opened.count, 2, "a fragment link opens nothing")
        doc.close()
    }

    // MARK: scroll sync

    func testLineTable() {
        let t = LineTable("ab\ncd\r\nef\rgh\n" as NSString)
        XCTAssertEqual(t.starts, [0, 3, 7, 10, 13])
        XCTAssertEqual(t.lineCount, 5)
        XCTAssertEqual(t.line(at: 0), 0)
        XCTAssertEqual(t.line(at: 2), 0)
        XCTAssertEqual(t.line(at: 3), 1)
        XCTAssertEqual(t.line(at: 5), 1)
        XCTAssertEqual(t.line(at: 6), 1, "between the CR and the LF")
        XCTAssertEqual(t.line(at: 7), 2)
        XCTAssertEqual(t.line(at: 10), 3)
        XCTAssertEqual(t.line(at: 999), 4)
        XCTAssertEqual(t.range(ofLine: 1), NSRange(location: 3, length: 4))
        XCTAssertEqual(t.position(at: 3), 1)
        XCTAssertEqual(t.position(at: 5), 1.5, accuracy: 0.01)
        XCTAssertEqual(t.location(at: 1.5), 5)
        XCTAssertEqual(t.location(at: 0), 0)
        for loc in 0...13 { XCTAssertEqual(t.location(at: t.position(at: loc)), loc, "round trip \(loc)") }
        XCTAssertEqual(LineTable("" as NSString).lineCount, 1)
    }

    func testScrollMappingMath() {
        let anchors = [ScrollAnchor(line: 2, y: 100), ScrollAnchor(line: 10, y: 300), ScrollAnchor(line: 12, y: 500)]
        func y(_ l: Double) -> Double { ScrollSync.y(forLine: l, anchors: anchors, startY: 52, endLine: 20, endY: 900) }
        func l(_ v: Double) -> Double { ScrollSync.line(forY: v, anchors: anchors, startY: 52, endLine: 20, endY: 900) }
        XCTAssertEqual(y(0), 52)
        XCTAssertEqual(y(1), 76)
        XCTAssertEqual(y(2), 100)
        XCTAssertEqual(y(6), 200, accuracy: 1e-9)
        XCTAssertEqual(y(10), 300)
        XCTAssertEqual(y(11), 400)
        XCTAssertEqual(y(16), 700, accuracy: 1e-9)
        XCTAssertEqual(y(20), 900)
        XCTAssertEqual(y(99), 900, "clamped to the end")
        XCTAssertEqual(y(-5), 52)
        XCTAssertEqual(l(52), 0)
        XCTAssertEqual(l(200), 6, accuracy: 1e-9)
        XCTAssertEqual(l(900), 20)
        XCTAssertEqual(l(5000), 20)
        // An inverse of each other, everywhere.
        for line in stride(from: 0.0, through: 20.0, by: 0.37) { XCTAssertEqual(l(y(line)), line, accuracy: 1e-9) }
        // Monotone.
        var last = -1.0
        for line in stride(from: 0.0, through: 20.0, by: 0.1) { XCTAssertGreaterThanOrEqual(y(line), last); last = y(line) }
        // No elements at all: the whole page is the document.
        XCTAssertEqual(ScrollSync.y(forLine: 5, anchors: [], startY: 0, endLine: 10, endY: 1000), 500, accuracy: 1e-9)
        // Equal heights (a zero-height interval) never divide by zero.
        let flat = [ScrollAnchor(line: 1, y: 10), ScrollAnchor(line: 2, y: 10)]
        XCTAssertFalse(ScrollSync.y(forLine: 1.5, anchors: flat, startY: 0, endLine: 3, endY: 20).isNaN)
        XCTAssertFalse(ScrollSync.line(forY: 10, anchors: flat, startY: 0, endLine: 3, endY: 20).isNaN)
        // Echo and clamping.
        XCTAssertTrue(ScrollSync.isEcho(position: 100.4, lastSet: 100))
        XCTAssertFalse(ScrollSync.isEcho(position: 103, lastSet: 100))
        XCTAssertFalse(ScrollSync.isEcho(position: 100, lastSet: nil))
        XCTAssertEqual(ScrollSync.clamp(-10, contentHeight: 1000, viewportHeight: 200), 0)
        XCTAssertEqual(ScrollSync.clamp(900, contentHeight: 1000, viewportHeight: 200), 800)
        XCTAssertEqual(ScrollSync.clamp(-100, contentHeight: 1000, viewportHeight: 200, minimum: -50), -50)
        XCTAssertEqual(ScrollSync.clamp(5, contentHeight: 100, viewportHeight: 200), 0)
        // Debounce: short for small documents, longer for large ones, bounded.
        XCTAssertLessThan(ScrollSync.debounce(forLength: 1_000), 0.1)
        XCTAssertGreaterThan(ScrollSync.debounce(forLength: 1_000_000), 0.4)
        XCTAssertLessThanOrEqual(ScrollSync.debounce(forLength: 100_000_000), 0.6)
    }

    func testThePagesScriptAgreesWithTheSwiftMapping() throws {
        var text = "# Title\n\n"
        for i in 0..<30 { text += "Paragraph \(i) with some words.\n\n- item\n- item\n\n```\ncode \(i)\n```\n\n" }
        let (doc, wc) = try open(text, layout: .split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        pump(0.3)
        let table = try XCTUnwrap(p.evaluateSync("return __md.table();") as? [[Double]])
        XCTAssertGreaterThan(table.count, 20)
        let inner = table.dropFirst().dropLast()
        let anchors = inner.map { ScrollAnchor(line: $0[0], y: $0[1]) }
        let (startY, endLine, endY) = (table.first![1], table.last![0], table.last![1])
        XCTAssertEqual(table.first![0], 0)
        for line in stride(from: 0.0, through: endLine, by: 3.3) {
            let js = (p.evaluateSync("return __md.yForLine(l);", arguments: ["l": line]) as? NSNumber)?.doubleValue ?? -1
            XCTAssertEqual(js, ScrollSync.y(forLine: line, anchors: anchors, startY: startY, endLine: endLine, endY: endY), accuracy: 0.01, "line \(line)")
            let back = (p.evaluateSync("return __md.lineForY(y);", arguments: ["y": js]) as? NSNumber)?.doubleValue ?? -1
            XCTAssertEqual(back, line, accuracy: 0.01)
        }
        doc.close()
    }

    func testScrollingTheEditorMovesThePreviewAndBack() throws {
        var text = "# Title\n\n"
        for i in 0..<60 { text += "Paragraph \(i) with some words in it, enough to run to a second line when the column is narrow.\n\n" }
        let (doc, wc) = try open(text, layout: .split)
        wc.window?.setContentSize(NSSize(width: 1100, height: 700))
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        pump(0.3)
        XCTAssertLessThan(p.scrollTopForTests, 2)
        let sv = wc.scrollView
        let clip = sv.contentView
        // Editor -> preview.
        clip.scroll(to: NSPoint(x: 0, y: (wc.textView.frame.height - clip.bounds.height) / 2))
        sv.reflectScrolledClipView(clip)
        XCTAssertTrue(spin(timeout: 5) { p.scrollTopForTests > 100 }, "the preview followed")
        func lines() -> (Double, Double) {
            (p.editorReadingPosition() ?? -1, (p.evaluateSync("return __md.currentLine();") as? NSNumber)?.doubleValue ?? -2)
        }
        pump(0.3)
        XCTAssertEqual(lines().0, lines().1, accuracy: 3)
        let editorWas = clip.bounds.minY
        // The preview's echo does not move the editor again.
        pump(0.4)
        XCTAssertEqual(clip.bounds.minY, editorWas, accuracy: 1)
        // Preview -> editor.
        _ = p.evaluateSync("window.scrollTo(0, 10); return 1;")
        XCTAssertTrue(spin(timeout: 5) { clip.bounds.minY < editorWas - 100 }, "the editor followed")
        pump(0.3)
        XCTAssertEqual(lines().0, lines().1, accuracy: 3)
        doc.close()
    }

    func testSwitchingLayoutsKeepsTheEditorsSelectionAndScroll() throws {
        var text = "# Title\n\n"
        for i in 0..<80 { text += "Paragraph \(i) with some words in it.\n\n" }
        let (doc, wc) = try open(text)
        wc.window?.setContentSize(NSSize(width: 1000, height: 600))
        let sv = wc.scrollView
        let clip = sv.contentView
        clip.scroll(to: NSPoint(x: 0, y: 700))
        sv.reflectScrolledClipView(clip)
        wc.textView.setSelectedRange(NSRange(location: 400, length: 12))
        pump(0.1)
        // The text at the top of the editor (a narrower pane wraps differently, so offsets in points move).
        let top = wc.textView.visibleCharacterRange().location
        XCTAssertGreaterThan(top, 100)
        for layout in [LayoutMode.preview, .split, .preview, .editor, .split] {
            doc.session.setLayout(layout)
            pump(0.3)
            XCTAssertEqual(wc.textView.selectedRange(), NSRange(location: 400, length: 12), "\(layout)")
            if layout.showsEditor { XCTAssertEqual(Double(wc.textView.visibleCharacterRange().location), Double(top), accuracy: 120, "\(layout)") }
            XCTAssertEqual(wc.scrollView.isHidden, !layout.showsEditor)
            XCTAssertEqual(wc.previewPane.isHidden, !layout.showsPreview)
        }
        doc.close()
    }

    func testThePreviewLayoutIsReadOnlyAndTheToolbarHides() throws {
        let (doc, wc) = try open("text\n", layout: .preview)
        XCTAssertTrue(wc.toolbar.isHidden)
        let tv = wc.textView
        let item = NSMenuItem(title: "Strong", action: #selector(EditorTextView.toggleStrong(_:)), keyEquivalent: "")
        XCTAssertFalse(tv.validateUserInterfaceItem(item), "editing commands are off in the preview")
        doc.session.setLayout(.split)
        XCTAssertTrue(tv.validateUserInterfaceItem(item))
        XCTAssertFalse(wc.toolbar.isHidden)
        for control in [wc.modeSwitch, wc.focusButton, wc.syntaxButton, wc.authorshipButton] as [NSControl] { XCTAssertTrue(control.isEnabled) }
        doc.session.setLayout(.preview)
        for control in [wc.modeSwitch, wc.focusButton, wc.syntaxButton, wc.authorshipButton] as [NSControl] { XCTAssertFalse(control.isEnabled) }
        doc.close()
    }

    func testTheDefaultLayoutAndTheSplitRatioAreSettings() throws {
        let s = isolatedSettings()
        XCTAssertEqual(s.defaultLayout, .editor)
        s.defaultLayout = .split
        XCTAssertEqual(EditorSession(settings: s).layout, .split)
        XCTAssertEqual(s.splitRatio, 0.5)
        s.splitRatio = 0.9
        XCTAssertEqual(s.splitRatio, 0.75, "kept sensible")
        s.splitRatio = 0.4
        XCTAssertEqual(s.splitRatio, 0.4)
    }

    // MARK: menus

    func testMenuItemsAndTheirKeyEquivalents() throws {
        let menu = MainMenu.build()
        var items: [NSMenuItem] = []
        func walk(_ m: NSMenu) { for i in m.items { items.append(i); if let s = i.submenu { walk(s) } } }
        walk(menu)
        func find(_ title: String) -> NSMenuItem? { items.first { $0.title == title } }
        let keys: [(String, String, NSEvent.ModifierFlags)] = [
            ("Editor", "3", [.command, .option]), ("Editor and Preview", "4", [.command, .option]), ("Preview", "5", [.command, .option]),
            ("Print…", "p", .command), ("Page Setup…", "p", [.command, .shift]),
        ]
        for (title, key, mods) in keys {
            let item = try XCTUnwrap(find(title), title)
            XCTAssertEqual(item.keyEquivalent, key, title)
            XCTAssertEqual(item.keyEquivalentModifierMask, mods, title)
        }
        XCTAssertNotNil(find("PDF…")); XCTAssertNotNil(find("HTML")); XCTAssertNotNil(find("Rich Text")); XCTAssertNotNil(find("Export")); XCTAssertNotNil(find("Copy As"))
        // No two items share a key equivalent (the alternate Save As aside).
        var seen: [String: String] = [:]
        for i in items where !i.keyEquivalent.isEmpty && !i.isAlternate {
            let k = "\(i.keyEquivalentModifierMask.rawValue)-\(i.keyEquivalent)"
            if let other = seen[k] { XCTFail("\(i.title) and \(other) share a key equivalent") }
            seen[k] = i.title
        }
        // Validation follows the window's layout.
        let (doc, wc) = try open("text\n")
        let editor = try XCTUnwrap(find("Editor")), split = try XCTUnwrap(find("Editor and Preview")), preview = try XCTUnwrap(find("Preview"))
        XCTAssertTrue(wc.validateMenuItem(editor)); XCTAssertEqual(editor.state, .on); XCTAssertEqual(split.state == .on || preview.state == .on, false)
        doc.session.setLayout(.split)
        XCTAssertTrue(wc.validateMenuItem(split)); XCTAssertEqual(split.state, .on)
        XCTAssertTrue(wc.validateMenuItem(editor)); XCTAssertEqual(editor.state, .off)
        doc.session.setLayout(.preview)
        XCTAssertTrue(wc.validateMenuItem(preview)); XCTAssertEqual(preview.state, .on)
        let html = try XCTUnwrap(find("HTML"))
        XCTAssertTrue(wc.validateMenuItem(html))
        // Actions reach the window controller through the responder chain's target lookup.
        XCTAssertTrue(wc.responds(to: #selector(EditorWindowController.exportPDF(_:))))
        XCTAssertTrue(doc.responds(to: #selector(NSDocument.printDocument(_:))))
        doc.close()
    }

    // MARK: PDF

    private func exportPDF(_ doc: MarkdownDocument, to name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        var result: Error??
        doc.exportPDF(to: url) { result = .some($0) }
        XCTAssertTrue(spin(timeout: 60) { result != nil }, "export finished")
        if let e = result ?? nil { XCTFail("export failed: \(e)") }
        return url
    }

    func testPDFExportIsPaginatedSelectableAndLight() throws {
        let png = try Data(contentsOf: Fixtures.root.appendingPathComponent("scripts/macos/ui/fixtures/images/small.png"))
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("img"), withIntermediateDirectories: true)
        try png.write(to: tmp.appendingPathComponent("img/small.png"))
        var md = "# Long document\n\n![a picture](img/small.png)\n\n"
        for i in 1...60 { md += "## Section \(i)\n\nQuokka paragraph \(i): " + String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 6) + "\n\n" }
        md += "```rust\nfn zebra() {}\n```\n"
        let settings = isolatedSettings()
        settings.theme = .dark
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(md.utf8), ofType: "net.daringfireball.markdown")
        doc.fileURL = tmp.appendingPathComponent("long.md")
        doc.makeWindowControllers()
        XCTAssertTrue(doc.session.waitUntilStyled())
        let url = try exportPDF(doc, to: "long.pdf")
        XCTAssertGreaterThan(PDFInspector.pageCount(url), 1, "a long document makes several pages")
        let text = PDFInspector.text(url)
        for word in ["Long document", "Quokka paragraph 1:", "Quokka paragraph 60", "zebra"] { XCTAssertTrue(text.contains(word), "\(word) is selectable text") }
        XCTAssertGreaterThanOrEqual(PDFInspector.imageCount(url), 1, "the local picture is in the PDF")
        // Light print styling whatever the theme (the app theme here is Dark).
        let corner = try XCTUnwrap(PDFInspector.pixel(url, page: 0, x: 4, y: 4))
        XCTAssertGreaterThan(corner.r + corner.g + corner.b, 2.9)
        XCTAssertLessThan(try XCTUnwrap(PDFInspector.darkestLuminance(url, page: 0)), 0.3)
        // The page's margins are the document's print info's.
        let box = try XCTUnwrap(PDFInspector.mediaBox(url, page: 0)), t = try XCTUnwrap(PDFInspector.textBounds(url, page: 0))
        XCTAssertGreaterThanOrEqual(t.minX - box.minX, 40)
        XCTAssertGreaterThanOrEqual(box.maxX - t.maxX, 40)
        doc.close()
    }

    func testAnUntitledDocumentExportsToo() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data("# Untitled\n\nWombat.\n".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let url = try exportPDF(doc, to: "untitled.pdf")
        XCTAssertEqual(PDFInspector.pageCount(url), 1)
        XCTAssertTrue(PDFInspector.text(url).contains("Wombat"))
        doc.close()
    }

    // MARK: authorship never shows

    func testMarksAreNeverRenderedPreviewedExportedOrCopied() throws {
        let file = try Fixtures.text("authorship/spec-example.md")
        XCTAssertTrue(file.contains("Annotations:"), "the fixture carries a block on disk")
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data(file.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        XCTAssertTrue(doc.session.waitUntilStyled())
        XCTAssertTrue(doc.session.authorship.hasMarks(), "the marks were read")
        XCTAssertFalse(doc.session.text.contains("Annotations:"))
        doc.session.setLayout(.split)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        XCTAssertFalse(p.lastBodyHTML.contains("Annotations:"))
        XCTAssertEqual(p.evaluateSync("return document.documentElement.innerHTML.includes('Annotations:');") as? Bool, false)
        let url = try exportPDF(doc, to: "marks.pdf")
        XCTAssertFalse(PDFInspector.text(url).contains("Annotations:"))
        XCTAssertFalse(PDFInspector.text(url).contains("SHA-256"))
        let pb = NSPasteboard(name: NSPasteboard.Name("markdown-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        for kind in [CopyAsKind.html, .richText] {
            XCTAssertTrue(doc.session.copyAs(kind, range: NSRange(location: 0, length: 0), to: pb))
            for type in pb.types ?? [] {
                if let s = pb.string(forType: type) { XCTAssertFalse(s.contains("Annotations:"), "\(type.rawValue)") }
                if type == .rtf, let d = pb.data(forType: .rtf) { XCTAssertFalse((NSAttributedString(rtf: d, documentAttributes: nil)?.string ?? "").contains("Annotations:")) }
            }
            XCTAssertNil(pb.data(forType: AuthorshipPasteboard.type), "the private authorship type is not written")
        }
        doc.close()
    }

    // MARK: Copy As

    func testCopyAsHTMLAndRichText() throws {
        let md = "# Heading\n\nA **bold** word and `code`, a [link](https://example.com).\n\n- [x] done\n- [ ] open\n\n<script>alert(1)</script>\n\nSecond paragraph.\n"
        let (doc, wc) = try open(md)
        let session = doc.session
        let pb = NSPasteboard(name: NSPasteboard.Name("markdown-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        // No selection: the whole document.
        XCTAssertTrue(session.copyAs(.html, range: NSRange(location: 0, length: 0), to: pb))
        let html = try XCTUnwrap(pb.string(forType: .html))
        let plain = try XCTUnwrap(pb.string(forType: .string))
        XCTAssertTrue(html.contains("<h1 id=\"heading\">Heading</h1>") && html.contains("<strong>bold</strong>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
        XCTAssertFalse(html.contains("<script"), "sanitized")
        XCTAssertFalse(html.contains("data-line") || html.contains("class=\"s-"), "clean")
        XCTAssertEqual("<meta charset=\"utf-8\">" + plain, html, "the plain-text flavour is the HTML source")
        XCTAssertTrue(Set((pb.types ?? []).map(\.rawValue)).isSuperset(of: ["public.html", "public.utf8-plain-text"]))
        XCTAssertNil(pb.data(forType: .rtf))
        // A selection: just its blocks.
        let at = (md as NSString).range(of: "Second").location
        XCTAssertTrue(session.copyAs(.html, range: NSRange(location: at + 2, length: 3), to: pb))
        XCTAssertEqual(pb.string(forType: .string), "<p>Second paragraph.</p>\n")
        // Rich text: HTML, RTF and plain text.
        XCTAssertTrue(session.copyAs(.richText, range: NSRange(location: 0, length: 0), to: pb))
        XCTAssertTrue(Set((pb.types ?? []).map(\.rawValue)).isSuperset(of: ["public.html", "public.rtf", "public.utf8-plain-text"]))
        XCTAssertNil(pb.data(forType: AuthorshipPasteboard.type))
        let rtf = try XCTUnwrap(pb.data(forType: .rtf))
        let rich = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        XCTAssertTrue(rich.string.contains("Heading") && rich.string.contains("bold word"), rich.string)
        var boldFound = false, linkFound = false, monoFound = false
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attrs, range, _ in
            let text = (rich.string as NSString).substring(with: range)
            if let f = attrs[.font] as? NSFont {
                if text == "bold" { boldFound = f.fontDescriptor.symbolicTraits.contains(.bold) }
                if text == "code" { monoFound = f.isFixedPitch }
            }
            if text == "link", attrs[.link] != nil { linkFound = true }
        }
        XCTAssertTrue(boldFound && linkFound && monoFound, "basic styles survive: bold \(boldFound), link \(linkFound), mono \(monoFound)")
        XCTAssertTrue(rich.string.contains("\u{2611}") && rich.string.contains("\u{2610}"), "task boxes are said in words")
        let fallback = try XCTUnwrap(pb.string(forType: .string))
        XCTAssertTrue(fallback.contains("Heading") && fallback.contains("bold word") && fallback.contains("done") && !fallback.contains("<"), "the plain-text fallback: \(fallback)")
        XCTAssertFalse(rich.string.contains("alert(1)"))
        // Nothing the editor paints reaches it: colours on the pasteboard come from the HTML alone.
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            guard let c = (value as? NSColor)?.usingColorSpace(.sRGB) else { return }
            XCTAssertFalse(abs(c.redComponent - session.appearance.palette.markup.usingColorSpace(.sRGB)!.redComponent) < 0.001 && abs(c.greenComponent - session.appearance.palette.markup.usingColorSpace(.sRGB)!.greenComponent) < 0.001, "markup colour leaked")
        }
        // Nothing to copy: nothing happens.
        let empty = NSPasteboard(name: NSPasteboard.Name("markdown-tests-\(UUID().uuidString)"))
        defer { empty.releaseGlobally() }
        session.load("")
        XCTAssertFalse(session.copyAs(.html, range: NSRange(location: 0, length: 0), to: empty))
        // Plain copy is unchanged: Markdown source.
        session.load("**src**\n")
        wc.textView.pasteboard = pb
        wc.textView.setSelectedRange(NSRange(location: 0, length: 7))
        wc.textView.copy(nil)
        XCTAssertEqual(pb.string(forType: .string), "**src**")
        doc.close()
    }

    func testTheStylesheetFollowsTheEditorsAppearance() throws {
        let settings = isolatedSettings()
        settings.theme = .sepia
        settings.fontSize = 19
        settings.lineWidth = 64
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data("text\n".utf8), ofType: "net.daringfireball.markdown")
        doc.session.setLayout(.split)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        let p = wc.previewController
        XCTAssertTrue(p.waitUntilSettled())
        func css() -> String { p.evaluateSync("return document.head.querySelector('style').textContent;") as? String ?? "" }
        XCTAssertTrue(css().contains("--bg: #F5EEDC;") && css().contains("font-size: 19px") && css().contains("max-width: 64ch"), String(css().prefix(300)))
        settings.theme = .dark
        settings.fontSize = 21
        XCTAssertTrue(p.waitUntilSettled())
        pump(0.3)
        XCTAssertTrue(css().contains("--bg: #1C1D1F;") && css().contains("font-size: 21px"), String(css().prefix(300)))
        doc.close()
    }
}
