import AppKit
import Network
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Scroll sync between the editor and the preview: both directions, through tall pictures, code
/// and tables, at the ends, without feedback, while typing, and while pictures arrive.
@MainActor
final class PreviewScrollTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func pump(_ s: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func open(_ text: String) throws -> (MarkdownDocument, EditorWindowController) {
        let settings = isolatedSettings()
        settings.defaultLayout = .split
        settings.autoHideChrome = false
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let url = tmp.appendingPathComponent("doc.md")
        try Data(text.utf8).write(to: url)
        doc.fileURL = url
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: 1300, height: 760))
        XCTAssertTrue(doc.session.waitUntilStyled())
        XCTAssertTrue(wc.previewController.waitUntilSettled())
        pump(0.3)
        return (doc, wc)
    }

    private func editorScroll(_ wc: EditorWindowController, _ f: CGFloat) {
        let sv = wc.scrollView, clip = sv.contentView, tv = wc.textView
        let top = -sv.contentInsets.top
        let range = max(0, tv.frame.height - clip.bounds.height + sv.contentInsets.bottom - top)
        clip.scroll(to: NSPoint(x: 0, y: top + range * f))
        sv.reflectScrolledClipView(clip)
    }

    /// Scrolls the page as the reader would. The page's own scroll event comes with its next
    /// rendering update, which WebKit suspends for a window it thinks is hidden (the test
    /// runner's often are): the event is sent at once, as that update would send it.
    private func previewScroll(_ p: PreviewController, _ f: Double) {
        _ = p.evaluateSync("const m = Math.max(0, document.documentElement.scrollHeight - window.innerHeight); window.scrollTo(0, m * f); window.dispatchEvent(new Event('scroll')); return m;", arguments: ["f": f])
    }

    private func positions(_ p: PreviewController) -> (editor: Double, preview: Double) {
        (p.editorReadingPosition() ?? -1, (p.evaluateSync("return __md.currentLine();") as? NSNumber)?.doubleValue ?? -2)
    }

    private func settle(_ p: PreviewController) {
        pump(0.35)
        _ = p.waitUntilSettled(timeout: 10)
        pump(0.1)
    }

    private func editorAt(_ wc: EditorWindowController) -> (top: Bool, end: Bool) {
        let sv = wc.scrollView, clip = sv.contentView
        // As far as AppKit lets the clip view go, each way.
        // The end: as far down as AppKit lets the clip view go (what a scroll wheel reaches). The
        // top: where a document opens, or above it (AppKit lets the wheel go a little further up).
        let lowest = clip.constrainBoundsRect(NSRect(x: 0, y: 1e9, width: clip.bounds.width, height: clip.bounds.height)).minY
        return (clip.bounds.minY <= -sv.contentInsets.top + 1, clip.bounds.minY >= lowest - 1)
    }

    private func previewAt(_ p: PreviewController) -> (top: Bool, end: Bool) {
        let m = p.evaluateSync("const max = document.documentElement.scrollHeight - window.innerHeight; return [window.scrollY, max];") as? [Double] ?? [-1, -1]
        return (m[0] < 1, m[0] >= m[1] - 1)
    }

    private func longDocument() throws -> String {
        try Self.png(width: 600, height: 1400).write(to: tmp.appendingPathComponent("tall.png"))
        var md = "# A long document\n\n"
        for i in 1...24 {
            md += "## Part \(i)\n\n" + String(repeating: "Prose that wraps over a couple of lines in either view, part \(i). ", count: 3) + "\n\n"
            if i % 4 == 1 { md += "![tall](tall.png)\n\n" }
            if i % 4 == 2 { md += "```swift\n" + (1...30).map { "let line\($0) = \($0) // part \(i)" }.joined(separator: "\n") + "\n```\n\n" }
            if i % 4 == 3 { md += "| a | b |\n|---|---|\n" + (1...20).map { "| \($0) | part \(i) |" }.joined(separator: "\n") + "\n\n" }
        }
        return md
    }

    func testBothWaysThroughTallPicturesCodeAndTablesAndAtTheEnds() throws {
        let (doc, wc) = try open(try longDocument())
        let p = wc.previewController
        XCTAssertTrue(spin(timeout: 10) { (p.evaluateSync("return [...document.images].every(i => i.complete && i.naturalWidth > 0);") as? Bool) == true })
        settle(p)
        var worst = 0.0
        for f in [0.1, 0.27, 0.5, 0.73, 0.9] as [CGFloat] {
            editorScroll(wc, f)
            settle(p)
            let (e, v) = positions(p)
            worst = max(worst, abs(e - v))
            XCTAssertEqual(v, e, accuracy: 1.0, "editor at \(f): editor line \(e), preview line \(v)")
        }
        for f in [0.15, 0.4, 0.6, 0.85] {
            previewScroll(p, f)
            // The page reports its scroll with its next rendering update, which WebKit holds back
            // for a window that is not frontmost (the test runner's): wait for it.
            _ = spin(timeout: 3) { let (e, v) = self.positions(p); return abs(e - v) <= 1 }
            settle(p)
            let (e, v) = positions(p)
            if editorAt(wc).end, e < v {
                // The editor's last screenful starts at an earlier line than the preview's: past
                // it, the editor stays at its end (the two cannot both show the same top line).
                continue
            }
            worst = max(worst, abs(e - v))
            XCTAssertEqual(e, v, accuracy: 1.0, "preview at \(f): editor line \(e), preview line \(v); received \(p.receivedScrolls.suffix(3)); \(p.lastEditorScrollTrace)")
        }
        print("scroll sync: worst disagreement \(String(format: "%.2f", worst)) lines")
        // The ends are the ends, both ways.
        editorScroll(wc, 1)
        XCTAssertTrue(spin(timeout: 3) { self.previewAt(p).end }, "editor at its end: preview at its end")
        previewScroll(p, 0)
        XCTAssertTrue(spin(timeout: 3) { self.editorAt(wc).top }, "preview at its top: editor at its top; received \(p.receivedScrolls.suffix(4)); \(p.lastEditorScrollTrace); clip \(wc.scrollView.contentView.bounds.minY) inset \(wc.scrollView.contentInsets.top); preview top \(p.scrollTopForTests); page scroll events \(String(describing: p.evaluateSync("return __md.scrollLog();")))")
        previewScroll(p, 1)
        XCTAssertTrue(spin(timeout: 3) { self.editorAt(wc).end }, "preview at its end: editor at its end; clip \(wc.scrollView.contentView.bounds) text height \(wc.textView.frame.height) insets \(wc.scrollView.contentInsets.bottom); \(p.lastEditorScrollTrace); received \(p.receivedScrolls.suffix(2))")
        editorScroll(wc, 0)
        XCTAssertTrue(spin(timeout: 3) { self.previewAt(p).top }, "editor at its top: preview at its top")
        settle(p)
        XCTAssertTrue(editorAt(wc).top && previewAt(p).top, "and they stay there")
        doc.close()
    }

    /// The preview scrolled: the editor is aimed at its line, and aimed again once the new screenful is laid out. A move
    /// of the editor in between is AppKit keeping the drawn text in place as the heights above it are corrected, not the
    /// reader's: it must not be pushed back to the page (preview.json: the page went back 18 lines and stayed there).
    func testAMoveOfTheEditorBeforeTheSecondAimIsNotPushedToThePage() throws {
        // preview.json's document and steps: the editor halfway, then the page scrolled to nine tenths.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../scripts/macos/ui/fixtures")
        let text = try String(contentsOf: root.appendingPathComponent("preview-tour.md"), encoding: .utf8)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path)) ?? [] {
            try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("images"), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: root.appendingPathComponent("images").appendingPathComponent(name), to: tmp.appendingPathComponent("images").appendingPathComponent(name))
        }
        let (doc, wc) = try open(text)
        wc.window?.setContentSize(NSSize(width: 1300, height: 820))
        let p = wc.previewController
        settle(p)
        editorScroll(wc, 0.5)
        settle(p)
        let before = p.receivedScrolls.count
        previewScroll(p, 0.9)
        XCTAssertTrue(spin(timeout: 3) { p.receivedScrolls.count > before }, "the page reported its scroll")
        let line = try XCTUnwrap(p.receivedScrolls.last)
        settle(p)
        let (e, v) = positions(p)
        XCTAssertEqual(v, line, accuracy: 1.0, "the page stays where the reader put it")
        XCTAssertEqual(e, v, accuracy: 1.0, "and the editor follows it; \(p.lastEditorScrollTrace)")
        doc.close()
    }

    func testAlternatingScrollsSettleAndDoNotOscillate() throws {
        let (doc, wc) = try open(try longDocument())
        let p = wc.previewController
        for k in 0..<12 {
            if k % 2 == 0 { editorScroll(wc, CGFloat(k) / 14) } else { previewScroll(p, Double(k) / 13) }
            pump(0.03)
        }
        settle(p)
        // Then nothing moves on its own.
        var samples: [(CGFloat, Double)] = []
        for _ in 0..<10 {
            pump(0.1)
            samples.append((wc.scrollView.contentView.bounds.minY, p.scrollTopForTests))
        }
        XCTAssertTrue(samples.allSatisfy { abs($0.0 - samples[0].0) < 0.5 && abs($0.1 - samples[0].1) < 0.5 }, "still moving: \(samples)")
        let (e, v) = positions(p)
        XCTAssertEqual(e, v, accuracy: 1.0)
        doc.close()
    }

    func testTypingAtTheEndKeepsThePreviewOnTheCaretsBlock() throws {
        var md = "# Notes\n\n"
        for i in 0..<150 { md += "Paragraph \(i) with some words in it.\n\n" }
        let (doc, wc) = try open(md)
        let p = wc.previewController
        let tv = wc.textView
        wc.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        settle(p)
        for line in 0..<6 {
            for c in "New line \(line) typed at the end." { tv.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            tv.insertText("\n\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            pump(0.02)
        }
        settle(p)
        settle(p)
        let caretLine = LineTable(tv.string as NSString).line(at: tv.selectedRange().location)
        let visible = p.evaluateSync("const y = __md.yForLine(l); return [y, window.scrollY, window.innerHeight];", arguments: ["l": caretLine - 2]) as? [Double] ?? []
        XCTAssertEqual(visible.count, 3)
        if visible.count == 3 {
            XCTAssertTrue(visible[0] >= visible[1] && visible[0] <= visible[1] + visible[2], "the block typed in (y \(visible[0])) is on screen (\(visible[1])...\(visible[1] + visible[2]))")
        }
        XCTAssertTrue(p.lastBodyHTML.contains("New line 5 typed at the end."))
        doc.close()
    }

    /// A theme change (any page update that is not an edit) keeps the preview where the editor is,
    /// even with the caret far away: only typing keeps the caret's block on screen.
    func testAThemeChangeDoesNotPullThePreviewToTheCaret() throws {
        var md = "# Top\n\n"
        for i in 0..<150 { md += "Paragraph \(i) with some words in it.\n\n" }
        let (doc, wc) = try open(md)
        let p = wc.previewController
        wc.window?.makeFirstResponder(wc.textView)
        wc.textView.setSelectedRange(NSRange(location: (md as NSString).range(of: "Paragraph 120").location, length: 0))
        editorScroll(wc, 0)
        settle(p)
        XCTAssertLessThan(positions(p).preview, 1)
        doc.session.settings.theme = .dark
        settle(p)
        settle(p)
        XCTAssertEqual(positions(p).preview, positions(p).editor, accuracy: 1, "the preview stayed with the editor, not the caret")
        doc.close()
    }

    /// Pictures that arrive after the preview was scrolled grow the page above the reader; the
    /// reader stays on the same line.
    func testThePreviewDoesNotJumpWhenPicturesArriveAbove() throws {
        let server = try DelayedPictureServer(delay: 1.5, png: Self.png(width: 500, height: 900))
        defer { server.stop() }
        XCTAssertTrue(spin(timeout: 5) { server.port != nil })
        var md = "# Slow pictures\n\n"
        for i in 0..<6 { md += "![slow \(i)](http://127.0.0.1:\(server.port!)/p\(i).png)\n\nText after picture \(i).\n\n" }
        for i in 0..<160 { md += "Paragraph \(i) with some words in it.\n\n" }
        let (doc, wc) = try open(md)
        let p = wc.previewController
        editorScroll(wc, 0.6)
        pump(0.4)
        XCTAssertEqual(p.evaluateSync("return [...document.images].filter(i => i.complete).length;") as? Int, 0, "the pictures are still on their way")
        let before = positions(p)
        let topBefore = p.scrollTopForTests
        XCTAssertTrue(spin(timeout: 10) { (p.evaluateSync("return [...document.images].every(i => i.complete && i.naturalWidth > 0);") as? Bool) == true })
        pump(0.4)
        let after = positions(p)
        let topAfter = p.scrollTopForTests
        XCTAssertGreaterThan(topAfter - topBefore, 1000, "the page grew above the reader (\(topBefore) -> \(topAfter))")
        XCTAssertEqual(after.preview, before.preview, accuracy: 0.5, "and the reader is on the same line")
        XCTAssertEqual(after.editor, before.editor, accuracy: 0.01, "and the editor did not move")
        doc.close()
    }
}

/// Serves the same picture for every request, after a delay.
final class DelayedPictureServer {
    private let listener: NWListener
    private var held: [NWConnection] = []
    private(set) var port: UInt16?

    init(delay: TimeInterval, png: Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.held.append(c)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(png.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(png)
                    c.send(content: response, completion: .contentProcessed { _ in c.cancel() })
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        held.forEach { $0.cancel() }
    }
}
