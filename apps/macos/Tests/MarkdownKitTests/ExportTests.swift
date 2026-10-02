import AppKit
import Network
import PDFKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// PDF export and printing: every way a job can end comes back on the main thread, leaves no
/// offscreen window or web view behind, and reports problems as errors; and what lands on paper.
@MainActor
final class ExportTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        PrintRenderer.imageWaitMilliseconds = 10_000
        PrintRenderer.extraCSSForTests = ""
        PrintRenderer.loadTimeout = 30
    }

    override func tearDownWithError() throws {
        // No job may leave its window on screen, whatever the test did.
        XCTAssertTrue(spin(timeout: 5) { PrintRenderer.live == 0 && PrintRenderer.hostsOnScreen == 0 },
                      "renderers alive \(PrintRenderer.live), offscreen windows on screen \(PrintRenderer.hostsOnScreen)")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func document(_ text: String, file: String? = "doc.md", theme: ThemeChoice = .light) throws -> MarkdownDocument {
        let settings = isolatedSettings()
        settings.theme = theme
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        if let file {
            let url = tmp.appendingPathComponent(file)
            try Data(text.utf8).write(to: url)
            doc.fileURL = url
        }
        doc.makeWindowControllers()
        XCTAssertTrue(doc.session.waitUntilStyled())
        return doc
    }

    /// Exports and waits; the completion must run once, on the main thread.
    private func export(_ doc: MarkdownDocument, to name: String, timeout: TimeInterval = 90) -> (URL, Error?) {
        let url = tmp.appendingPathComponent(name)
        var results: [Error?] = []
        doc.exportPDF(to: url) { error in
            XCTAssertTrue(Thread.isMainThread, "completion on the main thread")
            results.append(error)
        }
        XCTAssertTrue(spin(timeout: timeout) { !results.isEmpty }, "export finished")
        pumpRunLoop(0.2)
        XCTAssertEqual(results.count, 1, "completion runs once")
        return (url, results.first ?? nil)
    }

    private func pumpRunLoop(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func longText(sections: Int = 40) -> String {
        var md = "# A long document\n\n"
        for i in 1...sections {
            md += "## Section \(i)\n\nParagraph \(i): " + String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 8) + "\n\n"
        }
        return md
    }

    // MARK: threads, windows, leaks

    func testTheJobEndsOnTheMainThreadAndLeavesNothingBehind() throws {
        let doc = try document(longText())
        let (url, error) = export(doc, to: "a.pdf")
        XCTAssertNil(error)
        XCTAssertGreaterThan(PDFInspector.pageCount(url), 1)
        // AppKit reported the end off the main thread (the crash this morning): the hop made it safe.
        XCTAssertNotNil(PrintCallbacks.lastCallbackWasOnMain)
        print("print callback arrived on the main thread: \(PrintCallbacks.lastCallbackWasOnMain ?? false)")
        XCTAssertTrue(spin(timeout: 5) { PrintRenderer.live == 0 }, "the renderer is freed: \(PrintRenderer.live)")
        XCTAssertEqual(PrintRenderer.hostsOnScreen, 0, "its window is off the screen")
        doc.close()
    }

    func testTwoExportsAtOnce() throws {
        let a = try document(longText(sections: 20) + "Alpha-only.\n", file: "a.md")
        let b = try document(longText(sections: 25) + "Bravo-only.\n", file: "b.md")
        var done: [String: Error?] = [:]
        let ua = tmp.appendingPathComponent("a.pdf"), ub = tmp.appendingPathComponent("b.pdf")
        a.exportPDF(to: ua) { done["a"] = $0 }
        b.exportPDF(to: ub) { done["b"] = $0 }
        // And the same document twice.
        let ua2 = tmp.appendingPathComponent("a2.pdf")
        a.exportPDF(to: ua2) { done["a2"] = $0 }
        XCTAssertTrue(spin(timeout: 120) { done.count == 3 })
        for (k, e) in done { XCTAssertNil(e ?? nil, k) }
        XCTAssertTrue(PDFInspector.text(ua).contains("Alpha-only") && !PDFInspector.text(ua).contains("Bravo-only"))
        XCTAssertTrue(PDFInspector.text(ub).contains("Bravo-only"))
        XCTAssertTrue(PDFInspector.text(ua2).contains("Alpha-only"))
        a.close()
        b.close()
    }

    func testClosingTheDocumentWhileItExports() throws {
        weak var weakDoc: MarkdownDocument?
        var result: Error??
        let url = tmp.appendingPathComponent("closed.pdf")
        try autoreleasepool {
            let doc = try document(longText())
            weakDoc = doc
            doc.exportPDF(to: url) { result = .some($0) }
            // The app may not be ended (sudden or automatic termination) while the PDF is written,
            // which matters most now: with the window closed there is nothing on screen.
            XCTAssertEqual(MarkdownDocument.exportsInFlight, 1, "the export holds off termination")
            pumpRunLoop(0.05)
            doc.close()
        }
        XCTAssertTrue(spin(timeout: 90) { result != nil }, "the export still ends")
        XCTAssertEqual(MarkdownDocument.exportsInFlight, 0, "and lets termination happen again")
        XCTAssertNil(result ?? nil, "and writes the PDF of the text it had")
        XCTAssertTrue(PDFInspector.text(url).contains("Section 40"))
        XCTAssertTrue(spin(timeout: 5) { weakDoc == nil }, "and lets the document go")
    }

    func testAPictureIsPrintedAtTheSizeItsResolutionDeclares() throws {
        // Two pictures of the same 400 by 200 pixels, one declaring 72 dpi and one 144: in the editor and
        // the preview the second is half the size of the first, and so it must be on paper (the export
        // used to print both at their pixels). A document of nothing but a picture exports at all (it
        // has no text layer, which the export used to take for a page not painted yet: "printFailed").
        var widths: [String: CGFloat] = [:]
        for name in ["dpi-72.png", "dpi-144.png"] {
            let picture = Fixtures.root.appendingPathComponent("scripts/macos/ui/fixtures/polish/\(name)")
            try FileManager.default.copyItem(at: picture, to: tmp.appendingPathComponent(name))
            let doc = try document("![picture](\(name))\n", file: "doc-\(name).md")
            let (url, error) = export(doc, to: "\(name).pdf")
            XCTAssertNil(error, name)
            let ink = try XCTUnwrap(PDFInspector.inkBounds(url, page: 0), name)
            XCTAssertEqual(ink.width / ink.height, 2, accuracy: 0.05, "\(name): \(ink)")
            widths[name] = ink.width
            doc.close()
        }
        let ratio = (widths["dpi-72.png"] ?? 0) / max(1, widths["dpi-144.png"] ?? 1)
        XCTAssertEqual(ratio, 2, accuracy: 0.05, "the 144 dpi picture is printed at half the size: \(widths)")
    }

    func testDocumentsWithoutWordsExport() throws {
        // Only front matter (which the page leaves out), only a rule, only an empty task: no text on paper,
        // and that is not a failure.
        for (i, text) in ["---\ntitle: Only front matter\n---\n", "---\n", "- [ ] \n"].enumerated() {
            let doc = try document(text, file: "wordless-\(i).md")
            let (url, error) = export(doc, to: "wordless-\(i).pdf")
            XCTAssertNil(error, text)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), text)
            doc.close()
        }
        XCTAssertFalse(PrintRenderer.hasVisibleText("<p><img src=\"x.png\" alt=\"x\" /></p>\n<hr />\n<p>&nbsp;</p>"))
        XCTAssertTrue(PrintRenderer.hasVisibleText("<p>a</p>"))
    }

    func testExportingDuringAnAsynchronousSave() throws {
        let doc = try document(longText())
        doc.session.textView?.insertText("Saved and exported. ", replacementRange: NSRange(location: 0, length: 0))
        var saved: Bool?
        doc.save(to: doc.fileURL!, ofType: "net.daringfireball.markdown", for: .saveOperation) { error in saved = error == nil }
        let (url, error) = export(doc, to: "during-save.pdf")
        XCTAssertNil(error)
        XCTAssertTrue(spin(timeout: 10) { saved != nil })
        XCTAssertEqual(saved, true)
        XCTAssertTrue(PDFInspector.text(url).contains("Saved and exported."))
        XCTAssertTrue(try String(contentsOf: doc.fileURL!, encoding: .utf8).hasPrefix("Saved and exported."))
        doc.close()
    }

    func testAnUnwritableDestinationIsAnErrorNotACrash() throws {
        let doc = try document("# Hello\n")
        let locked = tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        for name in ["locked/x.pdf", "missing-folder/x.pdf"] {
            let (url, error) = export(doc, to: name, timeout: 10)
            XCTAssertEqual(error as? ExportError, .cannotWrite("x.pdf"), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("permission") == true)
        }
        // A file there that may not be replaced.
        let ro = tmp.appendingPathComponent("readonly.pdf")
        try Data("old".utf8).write(to: ro)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ro.path)
        let (_, error) = export(doc, to: "readonly.pdf", timeout: 10)
        XCTAssertEqual(error as? ExportError, .cannotWrite("readonly.pdf"))
        XCTAssertEqual(try Data(contentsOf: ro), Data("old".utf8))
        // The window's error sheet says so.
        let alert = NSAlert(error: ExportError.cannotWrite("x.pdf"))
        XCTAssertTrue(alert.messageText.contains("permission") && alert.informativeText.contains("another folder"), alert.messageText + " / " + alert.informativeText)
        doc.close()
    }

    func testAnExistingFileIsReplaced() throws {
        let doc = try document("# Replacement\n\nNew text.\n")
        try Data("not a pdf".utf8).write(to: tmp.appendingPathComponent("old.pdf"))
        let (url, error) = export(doc, to: "old.pdf")
        XCTAssertNil(error)
        XCTAssertTrue(PDFInspector.text(url).contains("New text."))
        doc.close()
    }

    func testAnUntitledDocumentExports() throws {
        let doc = try document("# Untitled\n\nWombat ![rel](img/x.png).\n", file: nil)
        let (url, error) = export(doc, to: "untitled.pdf")
        XCTAssertNil(error)
        XCTAssertEqual(PDFInspector.pageCount(url), 1)
        XCTAssertTrue(PDFInspector.text(url).contains("Wombat"))
        doc.close()
    }

    func testAPictureThatNeverArrivesDoesNotHoldUpTheExport() throws {
        let server = try SilentServer()
        defer { server.stop() }
        XCTAssertTrue(spin(timeout: 5) { server.port != nil })
        PrintRenderer.imageWaitMilliseconds = 1500
        let doc = try document("# Slow picture\n\n![never](http://127.0.0.1:\(server.port!)/never.png)\n\nAfter the picture.\n")
        let t0 = Date()
        let (url, error) = export(doc, to: "slow.pdf", timeout: 30)
        XCTAssertNil(error)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15, "the wait is bounded")
        XCTAssertTrue(PDFInspector.text(url).contains("After the picture."))
        XCTAssertGreaterThan(server.connections, 0, "the page did ask for it")
        doc.close()
    }

    func testAPageThatNeverLoadsTimesOut() throws {
        // A renderer that is never given a page: the load times out and reports failure once.
        PrintRenderer.loadTimeout = 0.5
        let renderer = PrintRenderer(documentURL: nil, pageSize: NSSize(width: 400, height: 600))
        var results: [Bool] = []
        renderer.load(html: "", fonts: "") { results.append($0) }
        renderer.webView.stopLoading()
        XCTAssertTrue(spin(timeout: 5) { !results.isEmpty })
        pumpRunLoop(0.6)
        XCTAssertEqual(results.count, 1)
        renderer.close()
        renderer.close()
    }

    // MARK: what lands on paper

    func testPageSizeAndMarginsFollowThePrintInfo() throws {
        let doc = try document(longText(sections: 4))
        for (name, size) in [("letter", NSSize(width: 612, height: 792)), ("a4", NSSize(width: 595, height: 842))] {
            let info = doc.printInfo
            info.paperSize = size
            info.leftMargin = 72; info.rightMargin = 72; info.topMargin = 50; info.bottomMargin = 50
            doc.printInfo = info
            let (url, error) = export(doc, to: "\(name).pdf")
            XCTAssertNil(error)
            let box = try XCTUnwrap(PDFInspector.mediaBox(url, page: 0))
            XCTAssertEqual(box.width, size.width, accuracy: 1, name)
            XCTAssertEqual(box.height, size.height, accuracy: 1, name)
            let text = try XCTUnwrap(PDFInspector.textBounds(url, page: 0))
            // The text starts at the left margin and the top margin (within a few points of the
            // glyphs' own side bearings and the line's leading).
            XCTAssertEqual(text.minX - box.minX, 72, accuracy: 4, "\(name) left margin \(text)")
            XCTAssertGreaterThanOrEqual(box.maxX - text.maxX, 70, "\(name) right margin (text is ragged) \(text)")
            XCTAssertEqual(box.maxY - text.maxY, 50, accuracy: 12, "\(name) top margin \(text)")
        }
        doc.close()
    }

    func testEveryThemePrintsDarkOnWhite() throws {
        for theme in [ThemeChoice.dark, .sepia] {
            let doc = try document("# Themed\n\nSome text and `code`.\n\n```rust\nfn a() {}\n```\n", theme: theme)
            let (url, error) = export(doc, to: "\(theme).pdf")
            XCTAssertNil(error)
            let corner = try XCTUnwrap(PDFInspector.pixel(url, page: 0, x: 4, y: 4))
            XCTAssertGreaterThan(corner.r + corner.g + corner.b, 2.95, "\(theme): white paper")
            XCTAssertLessThan(try XCTUnwrap(PDFInspector.darkestLuminance(url, page: 0)), 0.25, "\(theme): dark text")
            doc.close()
        }
    }

    func testCJKEmojiLongCodeAndLongTablesAllReachThePaper() throws {
        var md = "# 日本語の見出し\n\n中文段落，包含标点。한국어 문장도 있습니다. Emoji: 🎉🦊👩‍💻.\n\n```python\n"
        for i in 1...120 { md += "line_\(i) = \(i)  # code line \(i)\n" }
        md += "```\n\n| Key | Value |\n|-----|------:|\n"
        for i in 1...150 { md += "| row-\(i) | \(i * 7) |\n" }
        let doc = try document(md)
        let (url, error) = export(doc, to: "mixed.pdf")
        XCTAssertNil(error)
        // PDFKit reads some ideographs back as their Kangxi radicals (日 as U+2F47): the glyph is
        // shared and the font's map points there. NFKC folds them back. (Searching the PDF for
        // 日本語 in Preview fails the same way: a WebKit and CoreText matter, not ours.)
        let text = PDFInspector.text(url).precomposedStringWithCompatibilityMapping
        for needle in ["日本語の見出し", "中文段落", "한국어", "line_1 = 1", "line_120 = 120", "row-1", "row-150", "1050"] {
            XCTAssertTrue(text.contains(needle), "\(needle) in \(text.prefix(300).debugDescription)")
        }
        // Emoji print as pictures (Apple Color Emoji is a bitmap font): no text for them.
        XCTAssertFalse(text.contains("🎉"))
        XCTAssertGreaterThanOrEqual(PDFInspector.pageCount(url), 4, "the long code and table run over pages")
        // A code block or table longer than a page is split, not cut off: every line is there once.
        let line77 = try NSRegularExpression(pattern: "code line 77(?!\\d)")
        XCTAssertEqual(line77.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)), 1)
        let pages = (0..<PDFInspector.pageCount(url)).map { PDFInspector.pageText(url, page: $0) }
        let tablePages = pages.indices.filter { pages[$0].contains("row-") }
        XCTAssertGreaterThan(tablePages.count, 1)
        // Known WebKit limits, recorded rather than asserted: a table longer than a page does not
        // repeat its header on the pages it continues on, and its header can be left alone at the
        // foot of a page (this document does it: the header after the long code block).
        let headerPage = pages.indices.first { pages[$0].contains("Key") }
        print("table: header on page \(headerPage.map { $0 + 1 } ?? -1), rows on pages \(tablePages.map { $0 + 1 }), header repeated on \(tablePages.filter { pages[$0].contains("Key") }.count) of them")
        doc.close()
    }

    /// A heading never ends a page. The document is built so that, without the print rule that
    /// keeps a heading with what follows, headings do end pages (checked first, so the test can fail).
    func testNoPageEndsWithAHeading() throws {
        var md = ""
        for i in 1...45 {
            // Paragraphs of varying lengths move each heading through every position on a page.
            md += "Para \(i) " + String(repeating: "lorem ipsum dolor sit amet ", count: 3 + (i * 7) % 23) + "\n\n## HEADING \(i)\n\n"
        }
        md += "The end.\n"
        let doc = try document(md)
        func headingsEndingPages(_ url: URL) -> [String] {
            (0..<PDFInspector.pageCount(url)).compactMap { p in
                let lines = PDFInspector.pageText(url, page: p).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let last = lines.last, last.hasPrefix("HEADING") else { return nil }
                return "page \(p + 1): \(last)"
            }
        }
        PrintRenderer.extraCSSForTests = "@media print { h1, h2, h3, h4, h5, h6 { padding-bottom: 0 !important; margin-bottom: 0.4em !important; } }"
        let (without, e1) = export(doc, to: "without-rule.pdf")
        XCTAssertNil(e1)
        let bad = headingsEndingPages(without)
        XCTAssertFalse(bad.isEmpty, "the document must put a heading at a page's end without the rule (else this test proves nothing)")
        print("without the rule: \(bad)")
        PrintRenderer.extraCSSForTests = ""
        let (with, e2) = export(doc, to: "with-rule.pdf")
        XCTAssertNil(e2)
        XCTAssertEqual(headingsEndingPages(with), [], "with the rule")
        // And nothing was lost.
        XCTAssertTrue(PDFInspector.text(with).contains("HEADING 45") && PDFInspector.text(with).contains("The end."))
        doc.close()
    }

    func testATwoHundredPageDocument() throws {
        var md = "# Two hundred pages\n\n"
        for i in 1...1400 {
            md += "Paragraph \(i). " + String(repeating: "Words fill the page with text that wraps over several lines. ", count: 4) + "\n\n"
            if i % 50 == 0 { md += "## Part \(i / 50)\n\n```swift\nlet part = \(i / 50)\n```\n\n" }
        }
        let doc = try document(md)
        let before = residentMegabytes()
        let t0 = Date()
        var longestGap: TimeInterval = 0
        var last = Date()
        let heartbeat = Timer(timeInterval: 0.005, repeats: true) { _ in
            let now = Date(); longestGap = max(longestGap, now.timeIntervalSince(last)); last = now
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        let (url, error) = export(doc, to: "200.pdf", timeout: 240)
        heartbeat.invalidate()
        let seconds = Date().timeIntervalSince(t0)
        XCTAssertNil(error)
        let pages = PDFInspector.pageCount(url)
        let after = residentMegabytes()
        print("200-page export: \(pages) pages in \(String(format: "%.1f", seconds)) s, resident \(before) -> \(after) MB, longest main-thread gap \(Int(longestGap * 1000)) ms, \((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map { $0 / 1024 } ?? 0) KB")
        XCTAssertGreaterThanOrEqual(pages, 150)
        XCTAssertLessThan(seconds, 120)
        XCTAssertTrue(PDFInspector.text(url).contains("Paragraph 1400."))
        doc.close()
    }

    private func residentMegabytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.resident_size) >> 20 : -1
    }

    // MARK: print and page setup, as far as they can be driven

    func testPrintShowsItsPanelAndCancelling() throws {
        let doc = try document(longText(sections: 3))
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        let window = try XCTUnwrap(wc.window)
        doc.printDocument(nil)
        XCTAssertTrue(doc.isPreparingPrint)
        // A second Print while the first is loading does nothing (it beeps).
        doc.printDocument(nil)
        XCTAssertTrue(spin(timeout: 30) { window.attachedSheet != nil }, "the print panel is a sheet on the window")
        XCTAssertEqual(PrintRenderer.live, 1, "one page loaded, not two")
        let sheet = try XCTUnwrap(window.attachedSheet)
        print("print sheet: \(type(of: sheet)) \(sheet.title)")
        window.endSheet(sheet, returnCode: .cancel)
        XCTAssertTrue(spin(timeout: 10) { !doc.isPreparingPrint }, "cancelling ends the job")
        XCTAssertTrue(spin(timeout: 5) { PrintRenderer.live == 0 && window.attachedSheet == nil })
        XCTAssertEqual(PrintCallbacks.lastCallbackWasOnMain != nil, true)
        doc.close()
    }

    func testPageSetupShowsItsPanel() throws {
        let doc = try document("# Page setup\n")
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        let window = try XCTUnwrap(wc.window)
        doc.runPageLayout(nil)
        XCTAssertTrue(spin(timeout: 10) { window.attachedSheet != nil }, "the page setup panel is a sheet")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        XCTAssertTrue(spin(timeout: 5) { window.attachedSheet == nil })
        doc.close()
    }

    // MARK: the preview's own web view

    func testClosingAWindowWithThePreviewFreesThePreview() throws {
        weak var weakPreview: PreviewController?
        weak var weakWeb: NSView?
        weak var weakDoc: MarkdownDocument?
        try autoreleasepool {
            let settings = isolatedSettings()
            settings.defaultLayout = .split
            let doc = MarkdownDocument(settings: settings)
            try doc.read(from: Data("# Preview\n\n![p](x.png)\n".utf8), ofType: "net.daringfireball.markdown")
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
            wc.showWindow(nil)
            XCTAssertTrue(wc.previewController.waitUntilSettled())
            weakPreview = wc.previewController
            weakWeb = wc.previewController.webView
            weakDoc = doc
            doc.close()
        }
        XCTAssertTrue(spin(timeout: 5) { weakDoc == nil && weakPreview == nil }, "document \(weakDoc == nil), preview \(weakPreview == nil)")
        _ = weakWeb
    }
}

/// A TCP server that accepts connections and never answers.
final class SilentServer {
    private let listener: NWListener
    private var held: [NWConnection] = []
    private(set) var connections = 0
    private(set) var port: UInt16?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.held.append(c)
            self?.connections += 1
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        held.forEach { $0.cancel() }
    }
}
