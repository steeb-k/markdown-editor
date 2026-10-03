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
        XCTAssertTrue(wc.chromeController.windowButtons.allSatisfy { ($0 as? NSControl)?.isEnabled ?? false })
        doc.close()
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

    /// The vertical middle of the caret's line and of what the reader sees, in the same coordinates.
    private func offsets(_ wc: EditorWindowController) throws -> (line: CGFloat, middle: CGFloat) {
        let c = wc.centring
        let mid = try XCTUnwrap(c.lineMidY(at: wc.textView.selectedRange().location))
        let clip = wc.scrollView.contentView
        let scroll = wc.editorScrollView
        let visible = clip.bounds.height - scroll.baseInsetTop - scroll.baseInsetBottom
        return (mid - clip.bounds.minY, scroll.baseInsetTop + visible / 2)
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

    func testTheSlideIsAnimatedSmoothAndEndsInTheMiddle() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        guard wc.window?.isVisible == true else { throw XCTSkip("no visible window here") }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 40), length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        pump(0.1)
        // Move the caret a few lines off the middle, then turn focus on.
        let clip = wc.scrollView.contentView
        var samples: [CGFloat] = []
        let token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in samples.append(clip.bounds.minY) }
        defer { NotificationCenter.default.removeObserver(token) }
        wc.centring.reduceMotion = { false }
        wc.centring.enterDuration = 0.3
        let start = clip.bounds.minY
        doc.session.setFocusEnabled(true)
        let t0 = Date()
        var steps = 0
        while wc.centring.isSliding, steps < 200 { pump(0.01); steps += 1 }
        let took = Date().timeIntervalSince(t0)
        XCTAssertFalse(wc.centring.isSliding)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
        let travel = clip.bounds.minY - start
        if abs(travel) > 5 {
            XCTAssertGreaterThan(wc.centring.slides, 0)
            XCTAssertGreaterThan(samples.count, 3, "a slide, not a jump")
            XCTAssertGreaterThan(took, 0.2)
            XCTAssertLessThan(took, 0.6)
            let deltas = zip(samples, samples.dropFirst()).map { $1 - $0 }
            XCTAssertTrue(deltas.allSatisfy { travel > 0 ? $0 >= -0.01 : $0 <= 0.01 }, "one direction only")
        }
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
        wc.centring.currentEventIsMouse = { false }
        tv.setSelectedRange(NSRange(location: location(of: 57), length: 0))
        pump(0.1)
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
    }

    func testRequestsInOneTurnMakeOneSlide() throws {
        let (doc, wc) = try open()
        defer { doc.close() }
        guard wc.window?.isVisible == true else { throw XCTSkip("no visible window here") }
        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: location(of: 50), length: 0))
        doc.session.setFocusEnabled(true)
        pump(0.5)
        wc.centring.reduceMotion = { false }
        let slides = wc.centring.slides, jumps = wc.centring.jumps
        let range = NSRange(location: location(of: 55), length: 0)
        // The selection and `scrollRangeToVisible` (the text view's own call, or the find bar's) in one turn.
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.scrollRangeToVisible(range)
        pump(0.5)
        XCTAssertEqual(wc.centring.slides - slides, 1, "one slide, not one per caller")
        XCTAssertEqual(wc.centring.jumps, jumps, "and no jump before it")
        let o = try offsets(wc)
        XCTAssertEqual(o.line, o.middle, accuracy: 2)
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
}
