import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

// MARK: chrome timing (pure)

/// The chrome comes back by itself after a pause in typing: the state machine is given the time,
/// never reads a clock.
final class ChromeReappearanceTests: XCTestCase {
    func testTheFirstKeyHidesAndSchedulesTheReturn() {
        var s = ChromeState(autoHide: true)
        XCTAssertNil(s.reappearDeadline)
        XCTAssertEqual(s.handle(.typingStarted, at: 10), false)
        XCTAssertEqual(s.reappearDeadline, 10 + ChromeState.reappearDelay)
        XCTAssertEqual(ChromeState.reappearDelay, 2.5)
    }

    func testItStaysHiddenWhileKeysKeepComingWithinThePause() {
        var s = ChromeState(autoHide: true)
        s.handle(.typingStarted, at: 0)
        for t in stride(from: 1.0, through: 20.0, by: 1.0) {
            XCTAssertNil(s.handle(.typingStarted, at: t))
            XCTAssertNil(s.handle(.tick, at: t + 0.5), "a tick between keys does nothing")
            XCTAssertFalse(s.isVisible)
        }
    }

    func testItFadesBackAfterThePause() {
        var s = ChromeState(autoHide: true)
        s.handle(.typingStarted, at: 100)
        XCTAssertNil(s.handle(.tick, at: 102.49))
        XCTAssertEqual(s.handle(.tick, at: 102.5), true)
        XCTAssertTrue(s.isVisible)
        XCTAssertNil(s.reappearDeadline)
        XCTAssertNil(s.handle(.tick, at: 200), "once is enough")
        XCTAssertEqual(s.handle(.typingStarted, at: 200), false, "and the next key hides it again")
    }

    func testAKeyDuringThePauseResetsIt() {
        var s = ChromeState(autoHide: true)
        s.handle(.typingStarted, at: 0)
        s.handle(.typingStarted, at: 2.4)
        XCTAssertNil(s.handle(.tick, at: 2.6), "2.5 s have passed since the first key, not the last")
        XCTAssertEqual(s.reappearDeadline, 4.9)
        XCTAssertEqual(s.handle(.tick, at: 4.9), true)
    }

    func testNoSecondFadeWhenThePointerCameFirst() {
        var s = ChromeState(autoHide: true)
        s.handle(.typingStarted, at: 0)
        XCTAssertEqual(s.handle(.pointerMoved, at: 1), true)
        XCTAssertNil(s.reappearDeadline, "the countdown is cancelled by the other trigger")
        XCTAssertNil(s.handle(.tick, at: 3), "nothing to show again")
        // The same for a menu and for the window losing focus.
        s.handle(.typingStarted, at: 4)
        XCTAssertEqual(s.handle(.menuOpened, at: 5), true)
        XCTAssertNil(s.reappearDeadline)
        s.handle(.menuClosed, at: 5.1)
        s.handle(.typingStarted, at: 6)
        XCTAssertEqual(s.handle(.windowResignedKey, at: 7), true)
        XCTAssertNil(s.reappearDeadline)
    }

    func testTheReturnIsASetting() {
        var s = ChromeState(autoHide: true, reappearsAfterPause: false)
        s.handle(.typingStarted, at: 0)
        XCTAssertNil(s.reappearDeadline)
        XCTAssertNil(s.handle(.tick, at: 1000), "left hidden until the pointer moves")
        s.handle(.reappearAfterPauseChanged(true), at: 1000)
        XCTAssertEqual(s.reappearDeadline, 2.5, "counted from the last key")
        XCTAssertEqual(s.handle(.tick, at: 1001), true)
        let settings = isolatedSettings()
        XCTAssertTrue(settings.chromeReturnsAfterPause)
        settings.chromeReturnsAfterPause = false
        XCTAssertFalse(settings.chromeReturnsAfterPause)
    }

    func testNothingHidesWithAutoHideOff() {
        var s = ChromeState(autoHide: false)
        XCTAssertNil(s.handle(.typingStarted, at: 0))
        XCTAssertNil(s.reappearDeadline)
    }
}

// MARK: the title bar

@MainActor
final class TitlebarTests: XCTestCase {
    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    private func open(_ text: String = "# Title\n\nSome words here.\n", configure: (Settings) -> Void = { _ in }) throws -> (MarkdownDocument, EditorWindowController) {
        _ = NSApplication.shared
        let settings = isolatedSettings()
        configure(settings)
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    func testTheTitleBarHasNoCustomControls() throws {
        let (doc, wc) = try open()
        let window = try XCTUnwrap(wc.window)
        // The only accessory is the tab strip, and it is hidden for a single tab.
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertTrue(window.titlebarAccessoryViewControllers[0].view is TabStripView)
        XCTAssertTrue(window.titlebarAccessoryViewControllers[0].isHidden)
        XCTAssertFalse(wc.tabs.isShown)
        XCTAssertEqual(window.titleVisibility, .visible, "one tab: the window's own title")
        // Nothing else: no segmented control, no buttons but the window's.
        func controls(in view: NSView) -> [NSView] {
            var found: [NSView] = []
            for sub in view.subviews where !sub.isHidden && sub.frame.height > 0 && !(sub is TabStripView) {
                let name = "\(type(of: sub))"
                if sub is NSControl, !(name.hasPrefix("NSTheme") || name.hasPrefix("_NSTheme") || sub.className == "NSTextField" || name.hasPrefix("NSButtonTextField")) { found.append(sub) }
                found += controls(in: sub)
            }
            return found
        }
        let strays = wc.titlebarControls.flatMap { controls(in: $0) }.filter { !wc.chromeController.windowButtons.contains($0) }
        XCTAssertTrue(strays.isEmpty, "stray controls in the title bar: \(strays)")
        XCTAssertFalse(wc.titlebarControls.contains { v in v.subviews.contains { $0 is NSSegmentedControl } })
        doc.close()
    }

    func testFadingTheChromeLeavesTheTitleBarHitTestable() throws {
        let (doc, wc) = try open()
        let window = try XCTUnwrap(wc.window)
        let bar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        wc.chromeController.send(.typingStarted)
        pump(ChromeController.fadeDuration + 0.3)
        XCTAssertFalse(wc.chromeVisible)
        XCTAssertEqual(bar.alphaValue, 0, accuracy: 0.01, "faded")
        XCTAssertFalse(bar.isHidden, "never hidden: it keeps taking clicks (and the double-click)")
        XCTAssertTrue(wc.titlebarButtonsIgnoreClicksWhenHidden, "the window buttons do not")
        for b in wc.chromeController.windowButtons {
            XCTAssertFalse(b.isHidden, "not hidden either: AppKit moves the tab strip over to where hidden buttons were")
            XCTAssertFalse((b as? NSControl)?.isEnabled ?? true)
        }
        // A point in the strip of the title bar finds a view in the title bar's own hierarchy, not the text.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hit = frameView.hitTest(NSPoint(x: window.frame.width / 2, y: window.frame.height - 10))
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit?.isDescendant(of: window.contentView!) ?? true, "the click does not fall through to the text view")
        wc.chromeController.send(.pointerMoved)
        pump(ChromeController.fadeDuration + 0.3)
        XCTAssertTrue(wc.chromeVisible)
        XCTAssertEqual(bar.alphaValue, 1, accuracy: 0.01)
        XCTAssertTrue(wc.chromeController.windowButtons.allSatisfy { ($0 as? NSControl)?.isEnabled ?? false })
        doc.close()
    }

    /// A window on screen fades over a quarter of a second; the fade ends (faded, buttons off; and
    /// back) whether or not AppKit's animation runs, which it does not while the display sleeps.
    func testTheFadeEndsOnAWindowOnScreen() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.showWindow(nil)
        let window = try XCTUnwrap(wc.window)
        let bar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 3)
            while !condition(), Date() < deadline { pump(0.02) }
        }
        let buttons = wc.chromeController.windowButtons
        // (Whether it animates depends on the window being seen: occlusion, the display.)
        wc.chromeController.send(.typingStarted)
        waitFor { bar.alphaValue < 0.01 && !buttons.contains { ($0 as? NSControl)?.isEnabled ?? true } }
        XCTAssertEqual(bar.alphaValue, 0, accuracy: 0.01)
        XCTAssertEqual(wc.toolbar.alphaValue, 0, accuracy: 0.01)
        XCTAssertTrue(wc.titlebarButtonsIgnoreClicksWhenHidden)
        // Shown again: the buttons take clicks at once, before the fade-in has finished.
        wc.chromeController.send(.pointerMoved)
        XCTAssertTrue(buttons.allSatisfy { ($0 as? NSControl)?.isEnabled ?? false })
        waitFor { bar.alphaValue > 0.99 }
        XCTAssertEqual(bar.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(wc.toolbar.alphaValue, 1, accuracy: 0.01)
        // A fade-out cut short by a fade-in never disables the buttons afterwards.
        wc.chromeController.send(.typingStarted)
        wc.chromeController.send(.pointerMoved)
        pump(ChromeController.fadeDuration + 0.3)
        XCTAssertTrue(buttons.allSatisfy { ($0 as? NSControl)?.isEnabled ?? false })
        XCTAssertEqual(bar.alphaValue, 1, accuracy: 0.01)
    }

    func testTheChromeComesBackByItselfAfterAPause() throws {
        let (doc, wc) = try open()
        var now: TimeInterval = 1000
        let controller = ChromeController(window: try XCTUnwrap(wc.window), toolbar: wc.toolbar, autoHide: true, delay: 0.2)
        controller.clock = { now }
        controller.send(.typingStarted)
        XCTAssertFalse(controller.state.isVisible)
        now += 0.15
        controller.send(.typingStarted)   // within the pause: restarts it
        now += 0.15
        pump(0.1)
        XCTAssertFalse(controller.state.isVisible, "0.3 s since the first key, 0.15 s since the last")
        now += 0.1
        pump(0.35)
        XCTAssertTrue(controller.state.isVisible)
        XCTAssertEqual(controller.pauseReappearances, 1)
        doc.close()
    }

    /// A zoom and an unzoom bring the window back to the frame it had. (It came back 40 points wider:
    /// the formatting bar's wish to sit under the editor, stronger than the window's size, held the
    /// window at the old centre while the panes were still laid out for the zoomed width.)
    func testUnzoomRestoresTheFrameExactly() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.showWindow(nil)
        let window = try XCTUnwrap(wc.window)
        let screen = try XCTUnwrap(window.screen?.visibleFrame)
        let frame = NSRect(x: screen.minX + 40, y: screen.minY + 40, width: min(900, screen.width - 200), height: min(700, screen.height - 100))
        window.setFrame(frame, display: true)
        pump(0.2)
        window.zoom(nil)
        pump(0.5)
        guard window.frame.width > frame.width + 50 else { throw XCTSkip("the screen is too small to zoom wider") }
        window.zoom(nil)
        pump(0.5)
        XCTAssertEqual(window.frame.width, frame.width, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, frame.height, accuracy: 0.5)
        XCTAssertEqual(window.frame.minX, frame.minX, accuracy: 0.5)
    }

    func testTheDoubleClickActionFollowsTheSystemSetting() {
        func setting(_ value: String?) -> TitlebarDoubleClick {
            let name = "markdown-dblclick-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            defer { d.removePersistentDomain(forName: name) }
            if let value { d.set(value, forKey: "AppleActionOnDoubleClick") }
            return TitlebarDoubleClick.setting(d)
        }
        XCTAssertEqual(setting(nil), .zoom, "unset: zoom, the system's default")
        XCTAssertEqual(setting("Maximize"), .zoom)
        XCTAssertEqual(setting("Minimize"), .minimize)
        XCTAssertEqual(setting("None"), .nothing)
    }

    func testAnEmptyPartOfTheTabStripDoubleClicksLikeTheTitleBar() throws {
        let (doc, wc) = try open()
        var asked = 0
        wc.tabs.strip.onTitlebarClick = { _ in asked += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: wc.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        wc.tabs.strip.mouseDown(with: event)
        XCTAssertEqual(asked, 1)
        doc.close()
    }

    // MARK: the View menu

    func testEachViewMenuItemShowsTheStateOfTheWindow() throws {
        let (doc, wc) = try open()
        let view = try XCTUnwrap(MainMenu.build().items.first { $0.title == "View" }?.submenu)
        func item(_ path: String) throws -> NSMenuItem {
            var menu: NSMenu? = view
            var found: NSMenuItem?
            for part in path.components(separatedBy: " > ") {
                found = menu?.items.first { $0.title == part }
                menu = found?.submenu
            }
            return try XCTUnwrap(found, path)
        }
        func state(_ path: String) throws -> NSControl.StateValue {
            let i = try item(path)
            if let tv = i.action.map({ wc.textView.responds(to: $0) }), tv { _ = wc.textView.validateUserInterfaceItem(i) } else { _ = wc.validateMenuItem(i) }
            return i.state
        }
        XCTAssertEqual(try state("Source"), .on)
        XCTAssertEqual(try state("Live"), .off)
        XCTAssertEqual(try state("Editor"), .on)
        XCTAssertEqual(try state("Editor and Preview"), .off)
        XCTAssertEqual(try state("Preview"), .off)
        XCTAssertEqual(try state("Focus Mode"), .off)
        XCTAssertEqual(try state("Focus Scope > Sentence"), .on)
        XCTAssertEqual(try state("Syntax Highlight > Highlight Parts of Speech"), .off)
        XCTAssertEqual(try state("Show Authorship"), doc.session.authorshipDisplay ? .on : .off)

        doc.session.setViewMode(.live)
        doc.session.setLayout(.split)
        doc.session.setFocusEnabled(true)
        doc.session.setSyntaxEnabled(true)
        doc.session.settings.focusScope = .paragraph
        doc.session.setAuthorshipDisplay(!doc.session.authorshipDisplay)
        XCTAssertEqual(try state("Source"), .off)
        XCTAssertEqual(try state("Live"), .on)
        XCTAssertEqual(try state("Editor"), .off)
        XCTAssertEqual(try state("Editor and Preview"), .on)
        XCTAssertEqual(try state("Focus Mode"), .on)
        XCTAssertEqual(try state("Focus Scope > Paragraph"), .on)
        XCTAssertEqual(try state("Focus Scope > Sentence"), .off)
        XCTAssertEqual(try state("Syntax Highlight > Highlight Parts of Speech"), .on)
        XCTAssertEqual(try state("Show Authorship"), doc.session.authorshipDisplay ? .on : .off)
        doc.session.setLayout(.preview)
        XCTAssertEqual(try state("Preview"), .on)
        XCTAssertEqual(try state("Focus Mode"), .on, "still shown (and answered) with the preview in front")

        // The two global switches: the formatting bar and the centring, validated by the application.
        let app = AppDelegate()
        let bar = try item("Hide Formatting Toolbar")
        XCTAssertTrue(app.validateMenuItem(bar))
        let centre = try item("Keep Focused Line Centred")
        XCTAssertTrue(app.validateMenuItem(centre))
        XCTAssertEqual(centre.state, Settings.shared.centreFocusedLine ? .on : .off)
        XCTAssertEqual(centre.action, #selector(AppDelegate.toggleCentreFocusedLine(_:)))
        doc.close()
    }

    func testTheViewItemsAreOffWithNoWindowAndTheMenuHasThemInOrder() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let view = try XCTUnwrap(menu.items.first { $0.title == "View" }?.submenu)
        XCTAssertEqual(view.items.map(\.title).filter { !$0.isEmpty }.prefix(11),
                       ["Source", "Live", "Editor", "Editor and Preview", "Preview", "Focus Mode", "Focus Scope",
                        "Keep Focused Line Centred", "Syntax Highlight", "Show Authorship", "Hide Formatting Toolbar"])
        // With no document window, nothing in the responder chain answers the editor's actions: the
        // menu would show them disabled (an item whose action nobody handles is off).
        let editorActions: [Selector] = [
            #selector(EditorTextView.showSourceMode(_:)), #selector(EditorTextView.showLiveMode(_:)),
            #selector(EditorWindowController.showEditorLayout(_:)), #selector(EditorWindowController.showSplitLayout(_:)),
            #selector(EditorWindowController.showPreviewLayout(_:)), #selector(EditorTextView.toggleFocusMode(_:)),
            #selector(EditorTextView.setFocusScope(_:)), #selector(EditorTextView.toggleSyntaxHighlight(_:)),
            #selector(EditorTextView.toggleSyntaxClass(_:)), #selector(EditorTextView.toggleAuthorshipDisplay(_:)),
        ]
        for window in NSApp.windows where window.isVisible { window.orderOut(nil) }
        if NSApp.keyWindow == nil {
            for action in editorActions { XCTAssertNil(NSApp.target(forAction: action, to: nil, from: nil), "\(action) has a target with no window") }
        }
        // And every item the View menu holds validates without a window (the application's items answer, the rest are off).
        let app = AppDelegate()
        for item in view.items where item.action == #selector(AppDelegate.toggleFormattingToolbar(_:)) || item.action == #selector(AppDelegate.toggleCentreFocusedLine(_:)) {
            XCTAssertTrue(app.validateMenuItem(item))
        }
    }

    func testTheShortcutsOfTheViewMenuStayInTheTable() {
        _ = NSApplication.shared
        let table = HelpDocuments.shortcuts(of: MainMenu.build())
        XCTAssertEqual(table["View > Focus Mode"], "⌘D")
        XCTAssertEqual(table["View > Source"], "⌥⌘1")
        XCTAssertEqual(table["View > Live"], "⌥⌘2")
        XCTAssertEqual(table["View > Editor and Preview"], "⌥⌘4")
        XCTAssertEqual(table["View > Syntax Highlight > Highlight Parts of Speech"], "⇧⌘D")
        XCTAssertEqual(table["View > Show Authorship"], "⌥⌘A")
    }
}

// MARK: tabs

@MainActor
final class TabStripTests: XCTestCase {
    func testTabWidthsShrinkToAMinimumThenTheStripScrolls() {
        XCTAssertEqual(TabStripModel.tabWidth(count: 1, available: 800), TabStripModel.maximumTabWidth)
        XCTAssertEqual(TabStripModel.tabWidth(count: 4, available: 800), 200)
        XCTAssertEqual(TabStripModel.tabWidth(count: 40, available: 800), TabStripModel.minimumTabWidth)
        // With 40 tabs of 96 points in 800: the strip scrolls, and the selected tab is kept in view.
        let w = TabStripModel.minimumTabWidth
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 0, tabWidth: w, count: 40, available: 800, current: 500), 0)
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 39, tabWidth: w, count: 40, available: 800, current: 0), w * 40 - 800)
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 5, tabWidth: w, count: 40, available: 800, current: 100), 100, "already in view: no scroll")
        XCTAssertEqual(TabStripModel.scrollOffset(revealing: 2, tabWidth: 200, count: 3, available: 800, current: 50), 0, "fits: no offset")
    }

    func testOneWindowIsOneTabAndTheGroupGivesTitlesOrderEditedAndSelection() throws {
        _ = NSApplication.shared
        var docs: [MarkdownDocument] = []
        var controllers: [EditorWindowController] = []
        for (i, name) in ["alpha", "beta", "gamma"].enumerated() {
            let doc = MarkdownDocument(settings: isolatedSettings())
            try doc.read(from: Data("text \(i)\n".utf8), ofType: "net.daringfireball.markdown")
            doc.displayName = name
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
            _ = wc.window
            docs.append(doc)
            controllers.append(wc)
        }
        defer { docs.forEach { $0.close() } }
        let first = try XCTUnwrap(controllers[0].window)
        XCTAssertEqual(TabStripModel.entries(of: first).map(\.title), ["alpha"])
        XCTAssertFalse(controllers[0].tabs.isShown)
        controllers[0].showWindow(nil)
        controllers[1].showWindow(nil)
        controllers[2].showWindow(nil)
        let second = try XCTUnwrap(controllers[1].window)
        first.addTabbedWindow(second, ordered: .above)
        second.addTabbedWindow(try XCTUnwrap(controllers[2].window), ordered: .above)
        guard first.tabGroup?.windows.count == 3 else { throw XCTSkip("this environment does not form tab groups for off-screen test windows") }
        for wc in controllers { wc.tabs.refresh() }
        let entries = TabStripModel.entries(of: first)
        XCTAssertEqual(entries.map(\.title), ["alpha", "beta", "gamma"], "the group's order")
        XCTAssertEqual(entries.filter(\.selected).count, 1)
        XCTAssertEqual(entries.map(\.edited), [false, false, false])
        docs[1].updateChangeCount(.changeDone)
        XCTAssertEqual(TabStripModel.entries(of: first).map(\.edited), [false, true, false])
        // What every strip draws follows when the document tells its windows, which AppKit does at
        // the end of the next event (`updateWindows`), not only for the window in front.
        NSApp.updateWindows()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        for wc in controllers {
            XCTAssertEqual(wc.tabs.strip.entries.map(\.edited), [false, true, false], "the strip of \(wc.window?.title ?? "")")
        }
        docs[1].updateChangeCount(.changeCleared)
        NSApp.updateWindows()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        for wc in controllers { XCTAssertEqual(wc.tabs.strip.entries.map(\.edited), [false, false, false]) }
        docs[1].updateChangeCount(.changeDone)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        // The strip shows the tabs, the title is the strip's job, and the height of the bar does not grow.
        let selected = try XCTUnwrap(first.tabGroup?.selectedWindow)
        let wc = try XCTUnwrap(selected.windowController as? EditorWindowController)
        wc.tabs.refresh()
        XCTAssertTrue(wc.tabs.isShown)
        XCTAssertEqual(wc.tabs.strip.entries.map(\.title), ["alpha", "beta", "gamma"])
        XCTAssertEqual(wc.tabs.strip.tabViews.count, 3)
        XCTAssertEqual(selected.titleVisibility, .hidden)
        XCTAssertFalse(wc.tabs.nativeBarShowing, "AppKit's own tab bar is put away")
        XCTAssertLessThanOrEqual(wc.tabs.strip.frame.height, selected.frame.height - selected.contentLayoutRect.height + 0.5)
        // Selecting by the strip, reordering by the strip.
        let target = try XCTUnwrap(first.tabGroup?.windows.first { $0 !== selected })
        wc.tabs.select(target.windowNumber)
        XCTAssertTrue(first.tabGroup?.selectedWindow === target)
        wc.tabs.move(target.windowNumber, to: 0)
        XCTAssertTrue(first.tabGroup?.windows.first === target, "dragging a tab to the front moves it in the group")
    }

    /// The crash of 2026-10-02 (17:55): putting AppKit's bar away from inside the tab group's
    /// observation made AppKit fire the observation again, until the stack overflowed. Tabs are
    /// added, merged, moved out to their own window and back, selected and closed with every strip
    /// observing: no observation ever arrives inside another, and the native bar never shows.
    func testTabChangesNeverReenterTheStripsObservations() throws {
        _ = NSApplication.shared
        var docs: [MarkdownDocument] = []
        var controllers: [EditorWindowController] = []
        for i in 0..<4 {
            let doc = MarkdownDocument(settings: isolatedSettings())
            try doc.read(from: Data("text \(i)\n".utf8), ofType: "net.daringfireball.markdown")
            doc.makeWindowControllers()
            let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
            wc.showWindow(nil)
            docs.append(doc)
            controllers.append(wc)
        }
        defer { docs.filter { !$0.windowControllers.isEmpty }.forEach { $0.close() } }
        func pump() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15)) }
        func check(_ when: String) {
            for wc in controllers {
                XCTAssertEqual(wc.tabs.reentries, 0, "re-entered \(when)")
                XCTAssertFalse(wc.tabs.nativeBarShowing, "native bar \(when)")
            }
        }
        let windows = controllers.compactMap(\.window)
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        pump()
        guard windows[0].tabGroup?.windows.count == 2 else { throw XCTSkip("this environment does not form tab groups") }
        check("after the second tab")
        windows[1].addTabbedWindow(windows[2], ordered: .above)
        pump(); check("after the third")
        windows[3].mergeAllWindows(nil)
        pump(); check("after merging")
        XCTAssertEqual(windows[0].tabGroup?.windows.count, 4)
        windows[2].moveTabToNewWindow(nil)
        pump(); check("after moving a tab out")
        XCTAssertEqual(windows[2].tabGroup?.windows.count ?? 1, 1)
        windows[0].addTabbedWindow(windows[2], ordered: .below)
        pump(); check("after bringing it back")
        windows[0].tabGroup?.selectedWindow = windows[3]
        windows[0].selectNextTab(nil)
        pump(); check("after selecting")
        docs[1].close()
        pump(); check("after closing a tab")
        XCTAssertEqual(windows[0].tabGroup?.windows.count, 3)
    }

    func testTabViewsAreAccessibleAsTabsWithTheirTitles() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
        strip.setEntries([TabEntry(windowNumber: 1, title: "One", edited: false, selected: true),
                          TabEntry(windowNumber: 2, title: "Two", edited: true, selected: false)])
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.accessibilityRole(), .tabGroup)
        XCTAssertEqual(strip.tabViews.map { $0.accessibilityLabel() }, ["One", "Two"])
        XCTAssertEqual(strip.tabViews.map { $0.accessibilityRole() }, [.radioButton, .radioButton])
        XCTAssertEqual(strip.tabViews.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [1, 0])
        var pressed: [Int] = []
        strip.onSelect = { pressed.append($0) }
        XCTAssertTrue(strip.tabViews[1].accessibilityPerformPress())
        XCTAssertEqual(pressed, [2])
        // A tab of a window in the background takes the first click (it does not only activate the window).
        XCTAssertTrue(strip.acceptsFirstMouse(for: nil))
        XCTAssertTrue(strip.tabViews.allSatisfy { $0.acceptsFirstMouse(for: nil) })
        // A faded strip is title bar: its tabs take no hover and no clicks.
        strip.isFaded = true
        strip.tabViews[0].updateHover(true)
        XCTAssertFalse(strip.tabViews[0].hovering)
    }

    func testTheStripKeepsItsOrderAndHeightWhateverTheCount() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        let entries = (0..<30).map { TabEntry(windowNumber: $0, title: "Tab \($0)", edited: $0 % 5 == 0, selected: $0 == 29) }
        strip.setEntries(entries)
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.frame.height, 28, "never grows")
        XCTAssertEqual(strip.tabViews.count, 30)
        XCTAssertEqual(strip.tabViews[0].frame.width, TabStripModel.minimumTabWidth)
        XCTAssertGreaterThan(strip.scrollOffset, 0, "the selected tab is scrolled into view")
        XCTAssertEqual(strip.tabViews.map { $0.entry?.title }, entries.map(\.title))
        strip.setEntries(Array(entries.prefix(2)))
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(strip.tabViews.count, 2)
        XCTAssertEqual(strip.scrollOffset, 0)
    }
}

// MARK: focus mode's centring

@MainActor
final class FocusCentringTests: XCTestCase {
    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    /// A long document of short paragraphs, each its own line.
    private static let text = (1...120).map { "Line number \($0) of the long document." }.joined(separator: "\n\n") + "\n"

    private func open(visible: Bool = true) throws -> (MarkdownDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data(Self.text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        if visible { wc.showWindow(nil) }
        _ = wc.window
        wc.window?.setContentSize(NSSize(width: 800, height: 600))
        wc.window?.layoutIfNeeded()
        XCTAssertTrue(doc.session.waitUntilStyled())
        wc.updateFadeGeometry()
        return (doc, wc)
    }

    private func location(of line: Int) -> Int {
        (Self.text as NSString).range(of: "Line number \(line) ").location
    }

    /// The vertical middle of the caret's line and of what the reader sees, in the same coordinates
    /// (the clip view's: where the text view sits in it counts).
    private func offsets(_ wc: EditorWindowController) throws -> (line: CGFloat, middle: CGFloat) {
        let c = wc.centring
        let clip = wc.scrollView.contentView
        let mid = try XCTUnwrap(c.lineMidY(at: wc.textView.selectedRange().location)) + wc.textView.frame.minY
        let scroll = wc.editorScrollView
        let visible = clip.bounds.height - scroll.baseInsetTop - scroll.baseInsetBottom
        return (mid - clip.bounds.minY, scroll.baseInsetTop + visible / 2)
    }

    /// The caret's line in view but well off the middle (AppKit's own scroll to a far line centres it).
    private func bringOffMiddle(_ wc: EditorWindowController) {
        let tv = wc.textView
        tv.scrollRangeToVisible(tv.selectedRange())
        let clip = wc.scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 150))
        wc.scrollView.reflectScrolledClipView(clip)
    }

    // The maths, with no views.

    func testTheTargetOriginAtTheStartTheMiddleAndTheEndOfADocument() {
        // A 600-point window: 32 under the title bar, 60 under the formatting bar: 508 visible.
        let visible: CGFloat = 508, baseTop: CGFloat = 32, baseBottom: CGFloat = 60
        let room = FocusCentringMath.extraInset(visibleHeight: visible)
        XCTAssertEqual(room, 254)
        let clip: CGFloat = 600
        let docHeight: CGFloat = 5000
        let range = FocusCentringMath.scrollRange(documentHeight: docHeight, clipHeight: clip, topInset: baseTop + room, bottomInset: baseBottom + room)
        XCTAssertEqual(range.lowerBound, -(baseTop + room))
        func origin(_ mid: CGFloat) -> CGFloat {
            FocusCentringMath.targetOrigin(lineMidY: mid, baseTop: baseTop, visibleHeight: visible, range: range)
        }
        // Middle: the line's middle is exactly at the middle of the visible area.
        XCTAssertEqual(origin(2500), 2500 - baseTop - visible / 2)
        // Start: the first line (52 down) still reaches the middle, thanks to the room above.
        XCTAssertEqual(origin(52 + 12), 64 - baseTop - visible / 2)
        XCTAssertGreaterThanOrEqual(origin(64), range.lowerBound)
        // End: the last line (52 up from the end) reaches it thanks to the room below.
        let last = docHeight - 52 - 12
        XCTAssertEqual(origin(last), last - baseTop - visible / 2)
        XCTAssertLessThanOrEqual(origin(last), range.upperBound)
        // Beyond what exists: held within the range.
        XCTAssertEqual(origin(-10_000), range.lowerBound)
        XCTAssertEqual(origin(100_000), range.upperBound)
        // A short document is never scrolled out of its own range.
        let short = FocusCentringMath.scrollRange(documentHeight: 80, clipHeight: clip, topInset: baseTop + room, bottomInset: baseBottom + room)
        XCTAssertLessThanOrEqual(short.lowerBound, short.upperBound)
        // Easing: slow at the ends, half way at the middle, monotonic.
        XCTAssertEqual(FocusCentringMath.ease(0), 0)
        XCTAssertEqual(FocusCentringMath.ease(1), 1)
        XCTAssertEqual(FocusCentringMath.ease(0.5), 0.5, accuracy: 1e-9)
        XCTAssertLessThan(FocusCentringMath.ease(0.25), 0.25)
        XCTAssertGreaterThan(FocusCentringMath.ease(0.75), 0.75)
        var last2 = -1.0
        for i in 0...20 { let e = FocusCentringMath.ease(Double(i) / 20); XCTAssertGreaterThanOrEqual(e, last2); last2 = e }
    }

    // The room above and below, and the line in the middle.

    func testFocusModeAddsAndRemovesRoomAndCentresTheCaretLine() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let scroll = wc.editorScrollView
        let baseTop = scroll.contentInsets.top, baseBottom = scroll.contentInsets.bottom
        XCTAssertEqual(scroll.focusInset, 0)
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 50), length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        pump(0.1)
        let before = try offsets(wc)

        doc.session.setFocusEnabled(true)
        XCTAssertTrue(wc.centring.isActive)
        let visible = wc.scrollView.contentView.bounds.height - baseTop - baseBottom
        XCTAssertEqual(scroll.focusInset, FocusCentringMath.extraInset(visibleHeight: visible))
        XCTAssertEqual(scroll.contentInsets.top, baseTop + scroll.focusInset)
        XCTAssertEqual(scroll.contentInsets.bottom, baseBottom + scroll.focusInset)
        XCTAssertEqual(scroll.baseInsetTop, baseTop, "the permanent insets are what they were")
        let on = try offsets(wc)
        XCTAssertEqual(on.line, on.middle, accuracy: 2, "the caret line is in the middle")
        _ = before

        // Start and end of the document: still centred, thanks to the room.
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        pump(0.1)
        var o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2, "first line")
        tv.setSelectedRange(NSRange(location: (Self.text as NSString).length, length: 0))
        pump(0.4)
        o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2, "last line")

        // Off in the middle of the document: the line stays where it is on screen, and the room is gone.
        tv.setSelectedRange(NSRange(location: location(of: 60), length: 0))
        pump(0.1)
        let mid = try offsets(wc).line
        doc.session.setFocusEnabled(false)
        XCTAssertFalse(wc.centring.isActive)
        XCTAssertEqual(scroll.focusInset, 0)
        XCTAssertEqual(scroll.contentInsets.top, baseTop)
        XCTAssertEqual(scroll.contentInsets.bottom, baseBottom)
        XCTAssertEqual(try offsets(wc).line, mid, accuracy: 1, "nothing jumped")
    }

    /// The slide is driven frame by frame on a clock the test holds: no display link, no wall
    /// clock. (A display link sends no frames while the display sleeps, which is what made the
    /// first version of this test fail in a session whose screen had gone dark; the harness's
    /// `focus-centre.json` measures real frames, with the display held awake.)
    func testTheSlideIsAnimatedSmoothAndEndsInTheMiddle() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let c = wc.centring
        var clock: TimeInterval = 100
        c.now = { clock }
        c.deliversFrames = false
        c.reduceMotion = { false }
        c.editorShown = { true }
        c.enterDuration = 0.3
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 40), length: 0))
        bringOffMiddle(wc)
        pump(0.1)
        // The caret's line is in view, well off the middle; focus on.
        let clip = wc.scrollView.contentView
        let start = clip.bounds.minY
        doc.session.setFocusEnabled(true)
        XCTAssertEqual(clip.bounds.minY, start, "the room appears without moving the text")
        XCTAssertTrue(c.isSliding)
        XCTAssertEqual(c.slides, 1)
        XCTAssertEqual(c.jumps, 0, "a slide, not a jump")
        let target = try XCTUnwrap(c.targetOrigin(for: tv.selectedRange()))
        let travel = target - start
        XCTAssertGreaterThan(abs(travel), 20, "the line starts well off the middle")
        var samples: [CGFloat] = []
        let frames = 30
        for i in 1...frames {
            clock = 100 + 0.3 * Double(i) / Double(frames)
            c.tick()
            samples.append(clip.bounds.minY)
        }
        clock = 100.31
        c.tick()
        XCTAssertFalse(c.isSliding, "over after its duration")
        XCTAssertEqual(clip.bounds.minY, target, accuracy: 0.5)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
        // Ease in, ease out: slow at first, half way at half time, slow at the end; one way only.
        func share(at i: Int) -> CGFloat { (samples[i - 1] - start) / travel }
        XCTAssertLessThan(share(at: frames / 4), 0.25)
        XCTAssertEqual(share(at: frames / 2), 0.5, accuracy: 0.02)
        XCTAssertGreaterThan(share(at: frames * 3 / 4), 0.75)
        let deltas = zip([start] + samples, samples).map { $1 - $0 }
        XCTAssertTrue(deltas.allSatisfy { travel > 0 ? $0 >= -0.01 : $0 <= 0.01 }, "one direction only")
        XCTAssertGreaterThan(Set(samples.map { Int($0) }).count, frames / 2, "many distinct frames")
    }

    /// With no frames at all (the display asleep, the window covered), a slide still ends where it
    /// was going, on time: the deadline finishes it.
    func testASlideEndsWithoutAnyFrames() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let c = wc.centring
        c.deliversFrames = false
        c.reduceMotion = { false }
        c.editorShown = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 40), length: 0))
        bringOffMiddle(wc)
        pump(0.1)
        doc.session.setFocusEnabled(true)
        XCTAssertTrue(c.isSliding)
        let deadline = Date(timeIntervalSinceNow: 5)
        while c.isSliding, Date() < deadline { pump(0.02) }
        XCTAssertFalse(c.isSliding)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
        // Focus off the same way: the slide that removes the room ends too, and the room goes.
        tv.setSelectedRange(NSRange(location: location(of: 115), length: 0))
        pump(0.05)
        doc.session.setFocusEnabled(false)
        let deadline2 = Date(timeIntervalSinceNow: 5)
        while c.isSliding || c.holdsRoom, Date() < deadline2 { pump(0.02) }
        XCTAssertFalse(c.holdsRoom)
        XCTAssertEqual(wc.editorScrollView.focusInset, 0)
    }

    func testReduceMotionJumps() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let tv = wc.textView
        doc.session.setFocusEnabled(true)
        pump(0.05)
        let jumps = wc.centring.jumps, slides = wc.centring.slides
        tv.setSelectedRange(NSRange(location: location(of: 80), length: 0))
        pump(0.05)
        XCTAssertFalse(wc.centring.isSliding)
        XCTAssertEqual(wc.centring.slides, slides, "no slide")
        XCTAssertGreaterThan(wc.centring.jumps, jumps, "a jump")
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
    }

    // Typewriter scrolling and the user.

    func testTheCaretLineFollowsTypingAndMoves() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 30), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.05)
        for _ in 0..<5 {
            tv.insertText("\n", replacementRange: tv.selectedRange())
            pump(0.2)
            let o = try offsets(wc)
            XCTAssertEqual(o.line, o.middle, accuracy: 2)
        }
        for line in [10, 100, 3] {
            tv.setSelectedRange(NSRange(location: location(of: line), length: 0))
            pump(0.3)
            let o = try offsets(wc)
            XCTAssertEqual(o.line, o.middle, accuracy: 2, "line \(line)")
        }
    }

    func testCentringStopsForTheUsersScrollAndResumesOnTheNextKeystrokeOrCaretMove() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 50), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.05)
        let clip = wc.scrollView.contentView
        let centred = clip.bounds.minY
        // A scroll the user makes (the scroll view's wheel handler tells the centring).
        wc.editorScrollView.onUserScroll?()
        XCTAssertTrue(wc.centring.userScrolling)
        clip.scroll(to: NSPoint(x: 0, y: centred + 400))
        wc.scrollView.reflectScrolledClipView(clip)
        // Things that are not the caret or the keyboard do not bring it back: a layout settling,
        // a re-validation.
        wc.centring.layoutChanged()
        pump(0.1)
        XCTAssertEqual(clip.bounds.minY, centred + 400, accuracy: 0.5, "the user's scroll wins")
        XCTAssertTrue(wc.centring.userScrolling)
        // The next caret move or keystroke resumes.
        tv.insertText("x", replacementRange: tv.selectedRange())
        pump(0.1)
        XCTAssertFalse(wc.centring.userScrolling)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
        // A scroll in the middle of a slide cancels it.
        wc.centring.reduceMotion = { false }
        wc.centring.followDuration = 0.5
        tv.setSelectedRange(NSRange(location: location(of: 90), length: 0))
        pump(0.1)
        if wc.centring.isSliding {
            wc.editorScrollView.onUserScroll?()
            XCTAssertFalse(wc.centring.isSliding)
        }
    }

    func testNothingIsCentredWhileTheMouseHasTheCaret() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 50), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.05)
        let clip = wc.scrollView.contentView
        let before = clip.bounds.minY
        wc.centring.currentEventIsMouse = { true }
        tv.setSelectedRange(NSRange(location: location(of: 56), length: 0))
        pump(0.1)
        XCTAssertEqual(clip.bounds.minY, before, accuracy: 0.5, "a click or a drag selection leaves the text where it is")
        // The click's focus range (or Live mode's concealment) arrives later, out of the mouse event,
        // when the analysis queue was busy: it does not slide the clicked line either.
        wc.centring.currentEventIsMouse = { false }
        wc.centring.layoutChanged()
        pump(0.1)
        XCTAssertEqual(clip.bounds.minY, before, accuracy: 0.5, "a late layout change after a click leaves the text where it is")
        XCTAssertTrue(wc.centring.caretPlacedByMouse)
        tv.setSelectedRange(NSRange(location: location(of: 57), length: 0))
        pump(0.1)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
    }

    /// The caret moves again before the checks of its last move have run (key repeat, fast typing):
    /// those checks must not bring the line it left back to the middle. (They did: a jump back to
    /// the first line after the caret had gone to the last, found by the test above.)
    func testAnOlderMovesChecksNeverBringItsLineBack() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let c = wc.centring
        c.reduceMotion = { true }
        c.editorShown = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 60), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.3)
        let clip = wc.scrollView.contentView
        var lastFirst: CGFloat?
        for _ in 0..<5 {
            tv.setSelectedRange(NSRange(location: location(of: 10), length: 0))
            pump(0.005)   // its jump, not its checks (the first is 30 ms later)
            let first = clip.bounds.minY
            lastFirst = first
            var samples: [CGFloat] = []
            let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in samples.append(clip.bounds.minY) }
            tv.setSelectedRange(NSRange(location: location(of: 110), length: 0))
            pump(0.3)
            NotificationCenter.default.removeObserver(token)
            XCTAssertFalse(samples.dropFirst().contains { abs($0 - first) < 0.5 }, "went back to the line the caret left: \(samples)")
            let o = try offsets(wc)
            XCTAssertEqual(o.line, o.middle, accuracy: 2)
        }
        _ = lastFirst
    }

    /// A resize (and leaving or entering full screen, which is one) keeps the line in the new middle,
    /// with the room above and below resized to half the new height.
    func testAResizeKeepsTheLineInTheNewMiddle() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 70), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.2)
        for size in [NSSize(width: 700, height: 900), NSSize(width: 1000, height: 420), NSSize(width: 800, height: 600)] {
            wc.window?.setContentSize(size)
            pump(0.2)
            let o = try offsets(wc)
            XCTAssertEqual(o.line, o.middle, accuracy: 2, "at \(size)")
            let scroll = wc.editorScrollView
            let visible = scroll.contentView.bounds.height - scroll.baseInsetTop - scroll.baseInsetBottom
            XCTAssertEqual(scroll.focusInset, FocusCentringMath.extraInset(visibleHeight: visible), accuracy: 1)
        }
        doc.session.setFocusEnabled(false)
        pump(0.1)
        XCTAssertEqual(wc.editorScrollView.focusInset, 0, "no room left behind")
    }

    /// Long paragraphs that wrap: a change of width moves every line below the first.
    private static let wrapping = (1...60).map { n in
        "Paragraph \(n): " + String(repeating: "words that wrap at any width the window has ", count: 1 + n % 4)
    }.joined(separator: "\n\n") + "\n"

    /// A live resize (the user dragging the window's corner) in many small steps, narrower, wider,
    /// shorter and taller, with no keystroke anywhere: after every step, once the window has laid
    /// itself out as it does before it draws a frame, the caret's line is in the middle. Nothing is
    /// left to a later turn of the run loop (no slide, no check that corrects it afterwards), and
    /// when the resize ends nothing moves. In the editor and in Split, with and without the
    /// formatting bar, with motion (a resize never animates).
    func testALiveResizeKeepsTheLineInTheMiddleAtEveryStep() throws {
        for (layout, mode) in [(LayoutMode.editor, ViewMode.source), (.editor, .live), (.split, .source)] {
            for toolbar in [true, false] {
                _ = NSApplication.shared
                let settings = isolatedSettings()
                settings.showFormattingToolbar = toolbar
                let doc = MarkdownDocument(settings: settings)
                try doc.read(from: Data(Self.wrapping.utf8), ofType: "net.daringfireball.markdown")
                doc.makeWindowControllers()
                let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
                wc.showWindow(nil)
                let window = try XCTUnwrap(wc.window)
                window.setContentSize(NSSize(width: layout == .split ? 1100 : 800, height: 640))
                window.layoutIfNeeded()
                XCTAssertTrue(doc.session.waitUntilStyled())
                doc.session.setLayout(layout)
                doc.session.setViewMode(mode)
                XCTAssertTrue(doc.session.waitUntilStyled())
                let c = wc.centring
                c.reduceMotion = { false }
                c.editorShown = { true }
                let tv = wc.textView
                let text = Self.wrapping as NSString
                tv.setSelectedRange(NSRange(location: text.range(of: "Paragraph 31: ").location + 40, length: 0))
                doc.session.setFocusEnabled(true)
                let settle = Date(timeIntervalSinceNow: 3)
                while !c.isSettled, Date() < settle { pump(0.02) }
                pump(0.1)
                let label = "\(layout) \(mode) toolbar \(toolbar)"
                var o = try offsets(wc)
                XCTAssertEqual(o.line, o.middle, accuracy: 0.5, "\(label): centred before the resize")
                // What the window tells every view as a live resize starts and ends (the text view's own
                // end of a live resize scrolls the clip view).
                let content = try XCTUnwrap(window.contentView)
                func tell(_ v: NSView, _ start: Bool) {
                    if start { v.viewWillStartLiveResize() } else { v.viewDidEndLiveResize() }
                    v.subviews.forEach { tell($0, start) }
                }
                tell(content, true)
                var size = window.frame.size
                var worst: CGFloat = 0
                let steps: [(CGFloat, CGFloat)] = Array(repeating: (-23, 0), count: 8) + Array(repeating: (0, -17), count: 6)
                    + Array(repeating: (31, 11), count: 8) + Array(repeating: (-7, 29), count: 5)
                for (i, (dw, dh)) in steps.enumerated() {
                    size.width += dw
                    size.height += dh
                    var f = window.frame
                    f.origin.y += f.height - size.height
                    f.size = size
                    window.setFrame(f, display: false)
                    // What AppKit does before it draws the frame: layout, then display.
                    window.layoutIfNeeded()
                    window.displayIfNeeded()
                    o = try offsets(wc)
                    worst = max(worst, abs(o.line - o.middle))
                    XCTAssertEqual(o.line, o.middle, accuracy: 0.5, "\(label): step \(i) at \(size)")
                    XCTAssertFalse(c.isSliding, "\(label): no slide during a live resize (step \(i))")
                }
                tell(content, false)
                window.layoutIfNeeded()
                o = try offsets(wc)
                XCTAssertEqual(o.line, o.middle, accuracy: 0.5, "\(label): centred as the resize ends")
                let end = wc.scrollView.contentView.bounds.minY
                pump(0.5)
                XCTAssertEqual(wc.scrollView.contentView.bounds.minY, end, accuracy: 0.5, "\(label): nothing moves after the resize")
                o = try offsets(wc)
                XCTAssertEqual(o.line, o.middle, accuracy: 0.5, "\(label): centred after the resize")
                // Where a fresh keystroke would put it.
                let target = try XCTUnwrap(c.targetOrigin(for: tv.selectedRange()))
                XCTAssertEqual(wc.scrollView.contentView.bounds.minY, target, accuracy: 0.5, "\(label): where a keystroke would put it")
                print("live resize \(label): worst offset \(worst)")
                doc.close()
            }
        }
    }

    /// AppKit calls `scrollRangeToVisible` with the text on screen when the text view changes size.
    /// That is not the caret moving: it does not end the user's own scroll, and a range away from
    /// the caret is not centred.
    func testAppKitsOwnScrollRequestsAreNotTheCaretMoving() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let c = wc.centring
        c.reduceMotion = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 30), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.2)
        XCTAssertTrue(EditorTextView.touches(NSRange(location: 5, length: 0), NSRange(location: 0, length: 5)))
        XCTAssertFalse(EditorTextView.touches(NSRange(location: 6, length: 2), NSRange(location: 0, length: 5)))
        // The user scrolls far away; AppKit keeps what is now on screen in view.
        wc.editorScrollView.onUserScroll?()
        let clip = wc.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 2000))
        wc.scrollView.reflectScrolledClipView(clip)
        tv.scrollRangeToVisible(NSRange(location: location(of: 90), length: 300))
        pump(0.2)
        XCTAssertTrue(c.userScrolling, "still the user's scroll")
        let caretTarget = try XCTUnwrap(c.targetOrigin(for: tv.selectedRange()))
        XCTAssertGreaterThan(abs(clip.bounds.minY - caretTarget), 100, "the caret's line was not brought back for it")
        // Text around the caret (the caret's own line among it): the caret's line, not the range's start.
        tv.setSelectedRange(NSRange(location: location(of: 60), length: 0))
        pump(0.2)
        tv.scrollRangeToVisible(NSRange(location: location(of: 55), length: location(of: 66) - location(of: 55)))
        pump(0.2)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
    }

    func testRequestsInOneTurnMakeOneSlide() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        let c = wc.centring
        var clock: TimeInterval = 100
        c.now = { clock }
        c.deliversFrames = false
        c.editorShown = { true }
        // Centred at line 50 at once, then slides from there.
        c.reduceMotion = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 50), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.1)
        XCTAssertFalse(c.isSliding)
        var o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
        c.reduceMotion = { false }
        let slides = c.slides, jumps = c.jumps
        let range = NSRange(location: location(of: 55), length: 0)
        // The selection and `scrollRangeToVisible` (the text view's own call, or the find bar's) in one turn.
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.scrollRangeToVisible(range)
        XCTAssertEqual(c.slides, slides, "nothing moves until the turn is over")
        pump(0.05)
        XCTAssertEqual(c.slides - slides, 1, "one slide, not one per caller")
        XCTAssertEqual(c.jumps, jumps, "and no jump before it")
        XCTAssertTrue(c.isSliding)
        clock += c.followDuration + 0.01
        c.tick()
        XCTAssertFalse(c.isSliding)
        o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
        pump(0.3)
        XCTAssertEqual(c.slides - slides, 1, "and nothing after it (the checks found the line in place)")
    }

    func testTheSettingTurnsCentringOffAndOnWhileFocusIsOn() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        doc.session.setFocusEnabled(true)
        XCTAssertTrue(wc.centring.isActive)
        XCTAssertTrue(doc.session.settings.centreFocusedLine, "on by default")
        doc.session.settings.centreFocusedLine = false
        pump(0.05)
        XCTAssertFalse(wc.centring.isActive)
        XCTAssertEqual(wc.editorScrollView.focusInset, 0)
        XCTAssertTrue(doc.session.focusEnabled, "focus mode itself is unchanged")
        doc.session.settings.centreFocusedLine = true
        pump(0.05)
        XCTAssertTrue(wc.centring.isActive)
        XCTAssertGreaterThan(wc.editorScrollView.focusInset, 0)
    }

    func testThePreviewAndTheEditorKeepTheirBaseInsetForTheirMaths() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let base = wc.scrollView.editorBaseInsetTop
        doc.session.setFocusEnabled(true)
        XCTAssertEqual(wc.scrollView.editorBaseInsetTop, base, "scroll sync reads the title bar's inset, not the room focus mode makes")
        XCTAssertGreaterThan(wc.scrollView.contentInsets.top, base)
    }

    /// Split with focus mode: the preview's top is the text at the top of the editor, not the
    /// centred line in its middle (the sync once read the whole inset, room for centring included).
    /// (The way back uses the same inset; `focus-centre.json` checks both ways in Split.)
    func testScrollSyncPairsTheTopsWithFocusModeOn() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        wc.centring.reduceMotion = { true }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 60), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.1)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
        let pc = wc.previewController
        let top = try XCTUnwrap(pc.editorReadingPosition())
        // The source line at the top of what the reader sees, worked out here from the layout.
        let scroll = wc.editorScrollView
        let y = scroll.contentView.bounds.minY + scroll.baseInsetTop - tv.textContainerOrigin.y
        let lm = doc.session.layoutManager
        let glyph = lm.glyphIndex(for: NSPoint(x: 10, y: y), in: try XCTUnwrap(tv.textContainer))
        let char = lm.characterIndexForGlyph(at: glyph)
        let line = Double((Self.text as NSString).substring(to: char).components(separatedBy: "\n").count - 1)
        XCTAssertEqual(top, line, accuracy: 1.5, "the preview's top follows the editor's top")
        let caretLine = Double((Self.text as NSString).substring(to: location(of: 60)).components(separatedBy: "\n").count - 1)
        XCTAssertLessThan(top, caretLine - 5, "not the centred line")
    }
}

// MARK: Insert Table through its sheet, as a person does it

/// The harness once hit "must begin a group before registering undo" answering this sheet. That was
/// the harness's own doing: its `asEvent` turns the undo manager's grouping by event off for good.
/// The app never does, so a person's click on Insert is grouped like any other edit. Here the sheet's
/// button is clicked from a later turn of the run loop (no event being handled at all, the harder case).
@MainActor
final class InsertTableSheetTests: XCTestCase {
    private func pump(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    func testInsertingATableThroughTheSheetIsOneUndoStep() throws {
        _ = NSApplication.shared
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data("Before.\n".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        wc.showWindow(nil)
        defer { doc.close() }
        let window = try XCTUnwrap(wc.window)
        let um = try XCTUnwrap(doc.undoManager)
        XCTAssertTrue(um.groupsByEvent, "the app leaves grouping by event on")
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("x", replacementRange: tv.selectedRange())   // typing first: coalescing is in play
        pump()
        tv.insertTable(NSMenuItem())
        let deadline = Date(timeIntervalSinceNow: 3)
        while window.attachedSheet == nil, Date() < deadline { pump() }
        let sheet = try XCTUnwrap(window.attachedSheet, "the Insert Table sheet")
        func buttons(in view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? [] + buttons(in: $0) } }
        let insert = try XCTUnwrap(buttons(in: try XCTUnwrap(sheet.contentView)).first { $0.title == "Insert" })
        insert.performClick(nil)
        let deadline2 = Date(timeIntervalSinceNow: 3)
        while window.attachedSheet != nil || !tv.string.contains("|"), Date() < deadline2 { pump() }
        XCTAssertTrue(tv.string.contains("| --- |") || tv.string.contains("|---"), tv.string)
        pump()   // the group the undo manager opened by itself closes at the end of the run-loop turn
        XCTAssertEqual(um.groupingLevel, 0, "no group left open")
        XCTAssertEqual(um.undoActionName, "Insert Table")
        um.undo()
        XCTAssertEqual(tv.string, "Before.\nx", "one undo removes the whole table and nothing else")
        um.undo()
        XCTAssertEqual(tv.string, "Before.\n")
    }
}

// MARK: a new document is not edited

/// A new document carried the dot of an edited one on its tab from the start: setting its page
/// margins went through NSDocument's print-info setter, which registers "Change Print Settings"
/// for undo and so marks the document edited. Closing such an untouched window asked to save it.
@MainActor
final class NewDocumentStateTests: XCTestCase {
    func testANewDocumentIsNotEditedAndHasNothingToUndo() throws {
        _ = NSApplication.shared
        let doc = MarkdownDocument(settings: isolatedSettings())
        doc.makeWindowControllers()
        defer { doc.close() }
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertFalse(doc.hasUnautosavedChanges)
        XCTAssertFalse(doc.undoManager?.canUndo ?? false, "nothing to undo: \(doc.undoManager?.undoActionName ?? "")")
        XCTAssertEqual(doc.printInfo.leftMargin, MarkdownDocument.defaultPageMargin, "the margins are still set")
        XCTAssertEqual(doc.printInfo.topMargin, MarkdownDocument.defaultPageMargin)
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        XCTAssertEqual(TabStripModel.entries(of: try XCTUnwrap(wc.window)).map(\.edited), [false])
        // The same for one read from a file, and the first keystroke still marks it edited.
        let other = MarkdownDocument(settings: isolatedSettings())
        try other.read(from: Data("text\n".utf8), ofType: "net.daringfireball.markdown")
        other.makeWindowControllers()
        defer { other.close() }
        XCTAssertFalse(other.isDocumentEdited)
        let tv = try XCTUnwrap((other.windowControllers.first as? EditorWindowController)?.textView)
        tv.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(other.isDocumentEdited)
    }
}
