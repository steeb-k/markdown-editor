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
                    // (In Split focus mode only dims: no room above and below the text, nothing centred.)
                    if focus { XCTAssertEqual(wc.editorScrollView.focusInset > 0, layout == .editor, "focus mode makes room in the Editor layout only") }
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
            // The title bar is never the content's: a click in its row is AppKit's own title bar's or the band's (which drags
            // and zooms like it; with no accessory in the row AppKit's views do not reach the whole of it).
            let title = NSPoint(x: window.frame.width / 2, y: window.frame.height - 8)
            let t = try hit(wc, title)
            XCTAssertNotNil(t)
            let content = try XCTUnwrap(window.contentView)
            XCTAssertTrue(t === wc.titlebarBand || !(t?.isDescendant(of: content) ?? true), "focus \(focus): the title bar")
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

    /// Under a UI script every window ignores the real mouse and opens at the screen's top-left corner, and a
    /// mouse-down and -up posted to the app's queue (as the harness's click steps post them) still place the caret:
    /// `ignoresMouseEvents` only changes the window server's routing, never `NSApplication.sendEvent`.
    func testHarnessWindowsIgnoreTheRealMouseYetTakePostedClicks() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let window = try XCTUnwrap(wc.window)
        XCTAssertFalse(window.ignoresMouseEvents, "outside a script nothing changes")
        UIScriptRunner.adopt(window, requested: false)
        XCTAssertFalse(window.ignoresMouseEvents)

        UIScriptRunner.adopt(window, requested: true)
        XCTAssertTrue(window.ignoresMouseEvents)
        let visible = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        XCTAssertEqual(window.frame.minX, visible.minX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, visible.maxY, accuracy: 1)
        // Placed once: a window the script then moves is not pulled back.
        window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: window.frame.minY - 40))
        UIScriptRunner.adopt(window, requested: true)
        XCTAssertEqual(window.frame.minX, visible.minX + 40, accuracy: 1)
        // A menu's window is left alone.
        let menuLevel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless], backing: .buffered, defer: true)
        menuLevel.level = .popUpMenu
        UIScriptRunner.adopt(menuLevel, requested: true)
        XCTAssertFalse(menuLevel.ignoresMouseEvents)

        // Posted mouse events reach a window that ignores the real mouse. (A view that takes the first mouse: the test
        // runner is not the active app, so its windows are never key; `clicks.json` checks the text view itself.)
        let probe = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        let recorder = MouseRecorder(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        probe.contentView = recorder
        probe.orderFront(nil)
        defer { probe.orderOut(nil) }
        probe.ignoresMouseEvents = true
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 60), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: probe.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.postEvent(e, atStart: false)
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline, recorder.seen.count < 2 {
            if let e = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
        }
        XCTAssertEqual(recorder.seen, ["down", "up"], "posted events arrive with ignoresMouseEvents on")
        XCTAssertTrue(probe.ignoresMouseEvents)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    /// Found in the M8d test pass: a person moving the pointer over a harness window still reached the root view's
    /// tracking area, which brought the chrome back in the middle of `titlebar.json`'s fade checks. A window that
    /// ignores the mouse ignores its moves too; any other window reports them.
    func testPointerMovesOverAHarnessWindowDoNotBringTheChromeBack() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = EditorRootView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        window.contentView = root
        var moves = 0
        root.onPointerMoved = { moves += 1 }
        func move() throws {
            let e = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 50, y: 50), mouseButton: .left))
            e.setIntegerValueField(.mouseEventDeltaX, value: 5)
            root.mouseMoved(with: try XCTUnwrap(NSEvent(cgEvent: e)))
        }
        try move()
        XCTAssertEqual(moves, 1)
        window.ignoresMouseEvents = true
        try move()
        XCTAssertEqual(moves, 1, "a harness window's real pointer moves are not the script's")
    }
}

/// Records the mouse events a view is given.
private final class MouseRecorder: NSView {
    var seen: [String] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { seen.append("down") }
    override func mouseUp(with event: NSEvent) { seen.append("up") }
}
