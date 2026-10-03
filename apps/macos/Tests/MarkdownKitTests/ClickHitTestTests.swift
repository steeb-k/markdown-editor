import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Where a click lands: the view the window's frame view hit-tests at a point is the one AppKit
/// gives the mouse-down to, and makes first responder. Over the text it must be the text view in
/// every layout and state: focus mode's room for centring is content inset, AppKit gives a click in
/// a scroll view's insets to the scroll view itself, and with the room covering the whole clip view
/// no click ever reached the text (the caret did not move; a text view that had lost the keyboard to
/// the preview or the sidebar never got it back).
@MainActor
final class ClickHitTestTests: XCTestCase {
    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    private static let text = (1...80).map { "Paragraph \($0) with a few words in it." }.joined(separator: "\n\n") + "\n"

    private func open(configure: (Settings) -> Void = { _ in }) throws -> (MarkdownDocument, EditorWindowController) {
        _ = NSApplication.shared
        let settings = isolatedSettings()
        settings.focusMode = false
        configure(settings)
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(Self.text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        wc.window?.setContentSize(NSSize(width: 900, height: 640))
        wc.window?.layoutIfNeeded()
        XCTAssertTrue(doc.session.waitUntilStyled())
        wc.updateFadeGeometry()
        pump(0.1)
        return (doc, wc)
    }

    private func hit(_ wc: EditorWindowController, _ p: NSPoint) throws -> NSView? {
        let window = try XCTUnwrap(wc.window)
        return try XCTUnwrap(window.contentView?.superview).hitTest(p)
    }

    /// Points down the editor's pane, left of the formatting bar, from just above the window's bottom
    /// edge to just below the title bar: each is the text view's.
    private func assertTextTakesClicks(_ wc: EditorWindowController, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let window = try XCTUnwrap(wc.window)
        let bar = window.frame.height - window.contentLayoutRect.height
        let pane = wc.scrollView.convert(wc.scrollView.bounds, to: nil)
        // (The formatting bar, where it shows, is the bar's: a pane narrower than the bar has it over its left edge.)
        let toolbar = wc.toolbar.isHidden || wc.toolbar.alphaValue < 0.5 ? NSRect.zero : wc.toolbar.convert(wc.toolbar.bounds, to: nil)
        var y: CGFloat = 4
        while y < window.frame.height - bar - 2 {
            let p = NSPoint(x: pane.minX + 30, y: y)
            if toolbar.insetBy(dx: -1, dy: -1).contains(p) { y += 23; continue }
            let v = try hit(wc, p)
            XCTAssertTrue(v === wc.textView, "\(what): the click at \(p) went to \(v.map { "\(type(of: $0))" } ?? "nil"), not the text view (insets \(wc.scrollView.contentInsets.top) \(wc.scrollView.contentInsets.bottom))", file: file, line: line)
            y += 23
        }
    }

    func testEveryPointOverTheTextIsTheTextViewsInEachLayoutAndState() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        for layout in [LayoutMode.editor, .split] {
            doc.session.setLayout(layout)
            pump()
            for toolbar in [true, false] {
                doc.session.settings.showFormattingToolbar = toolbar
                pump()
                for focus in [false, true] {
                    doc.session.setFocusEnabled(focus)
                    pump(0.6)
                    if focus { XCTAssertGreaterThan(wc.editorScrollView.focusInset, 0, "focus mode makes room") }
                    let what = "\(layout), toolbar \(toolbar), focus \(focus)"
                    try assertTextTakesClicks(wc, what)
                    // The chrome faded by typing: the same.
                    wc.chromeController.fadeDuration = 0
                    wc.chromeController.send(.windowBecameKey)
                    wc.chromeController.send(.typingStarted)
                    XCTAssertFalse(wc.chromeVisible)
                    try assertTextTakesClicks(wc, what + ", chrome faded")
                    wc.chromeController.send(.pointerMoved)
                }
                doc.session.setFocusEnabled(false)
                pump(0.6)
            }
        }
    }

    func testTheFormattingBarThePreviewTheDividerAndTheTitleBarKeepTheirClicks() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let window = try XCTUnwrap(wc.window)
        for focus in [false, true] {
            doc.session.setFocusEnabled(focus)
            pump(0.6)
            doc.session.setLayout(.split)
            pump()
            wc.chromeController.fadeDuration = 0
            wc.chromeController.send(.pointerMoved)
            // The bar's own buttons.
            let barCentre = wc.toolbar.convert(NSPoint(x: wc.toolbar.bounds.midX, y: wc.toolbar.bounds.midY), to: nil)
            XCTAssertTrue(try hit(wc, barCentre)?.isDescendant(of: wc.toolbar) ?? false, "focus \(focus): the formatting bar")
            // A faded bar is text.
            wc.chromeController.send(.windowBecameKey)
            wc.chromeController.send(.typingStarted)
            XCTAssertFalse(wc.chromeVisible)
            let underBar = try hit(wc, barCentre)
            var chain: [String] = []
            var v = underBar
            while let x = v { chain.append("\(type(of: x)) \(x.frame) a\(x.alphaValue)"); v = x.superview }
            XCTAssertTrue(underBar === wc.textView, "focus \(focus): a faded bar is the text's, not \(chain) toolbar alpha \(wc.toolbar.alphaValue)")
            wc.chromeController.send(.pointerMoved)
            // The preview.
            let web = wc.previewController.webView
            let inPreview = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
            XCTAssertTrue(try hit(wc, inPreview)?.isDescendant(of: web) ?? false, "focus \(focus): the preview")
            // The divider.
            let divider = wc.splitView.convert(NSPoint(x: wc.scrollView.frame.maxX + 0.5, y: wc.splitView.bounds.midY), to: nil)
            XCTAssertTrue(try hit(wc, divider) === wc.splitView, "focus \(focus): the divider")
            // The title bar is never the content's.
            let title = NSPoint(x: window.frame.width / 2, y: window.frame.height - 8)
            let t = try hit(wc, title)
            XCTAssertNotNil(t)
            XCTAssertFalse(t?.isDescendant(of: try XCTUnwrap(window.contentView)) ?? true, "focus \(focus): the title bar")
            // Nor does the scroll view hand a point under the title bar to the text (AppKit gives a click there to a
            // content view that will not move the window: the title bar's drag and double-click would be lost).
            let scroll = wc.editorScrollView
            let under = try XCTUnwrap(scroll.superview).convert(NSPoint(x: 40, y: window.frame.height - 6), from: nil)
            XCTAssertFalse(scroll.hitTest(under) === wc.textView, "focus \(focus): under the title bar")
            doc.session.setLayout(.editor)
            pump()
        }
    }

    /// The views over the text that must never take a click, and the ones that exist only for a while.
    func testOverlaysTakeNoClicksAndThePaletteIsAbsentInPlainMode() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.contentView === wc.root, "plain mode: the window is the editor's own view")
        XCTAssertNil(wc.notesContainer)
        XCTAssertNil(wc.palette)
        XCTAssertFalse(wc.root.subviews.contains { $0 is PalettePanelView })
        XCTAssertNil(wc.titlebarFade.hitTest(NSPoint(x: 10, y: 10)), "the fade under the title bar never takes clicks")
        // A point over the fade below the title bar is the text's.
        let fade = wc.titlebarFade.convert(NSPoint(x: 40, y: wc.titlebarFade.bounds.height - 4), to: nil)
        let bar = window.frame.height - window.contentLayoutRect.height
        if fade.y < window.frame.height - bar {
            XCTAssertTrue(try hit(wc, fade) === wc.textView)
        }
    }
}
