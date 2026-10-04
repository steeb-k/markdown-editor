import AppKit
import WebKit
import MarkdownCore

/// One document's window: a full-size content view with the text column filling it and the
/// formatting toolbar floating over its bottom margin.
public final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    public let session: EditorSession
    public let textView: EditorTextView
    public let scrollView: NSScrollView
    var editorScrollView: EditorScrollView { scrollView as! EditorScrollView }
    let toolbar = FormattingToolbar(frame: .zero)
    /// Text scrolled up under the transparent title bar fades out instead of colliding with the
    /// traffic lights and the title.
    let titlebarFade = EdgeFadeView()
    /// Stands in for the title bar where AppKit's own views do not take the click (see `TitlebarBandView`).
    let titlebarBand = TitlebarBandView()
    private var bandHeight: NSLayoutConstraint!
    /// The window's title, over the editor's pane (see `TitlebarTitleView`).
    let titleView = TitlebarTitleView(frame: .zero)
    private var titleHeight: NSLayoutConstraint!
    /// The editor and the preview side by side (either may be collapsed away).
    let splitView = PreviewSplitView()
    let previewPane = NSView()
    public let previewController: PreviewController
    private var applyingSplitPosition = false
    /// Focus mode's vertical centring (see `FocusCentring`).
    let centring = FocusCentring()
    private var fadeHeight: NSLayoutConstraint!
    let root = EditorRootView()
    private var chrome: ChromeController!
    /// The notes of this window (see `EditorWindowController+Notes`): nil until notes mode has been turned on
    /// in it. A plain window never makes one. Every window has its own; a window opened from another's
    /// sidebar starts with a copy of its state.
    var workspace: Workspace?
    var sidebar: SidebarController?
    var notesSplit: NotesSplitView?
    /// The window's content view in notes mode: the split view, and the palette over it.
    var notesContainer: EditorRootView?
    /// The narrowest the window may be without notes mode's sidebar.
    var baseMinWidth: CGFloat = 360
    /// The document whose note the sidebar last selected.
    var syncedSelectionURL: URL?
    var palette: PaletteController?
    var applyingSidebarWidth = false
    /// The right-hand column with its two panes, the outline and the history (see `EditorWindowController+SideColumn`),
    /// and the split view that holds it beside the editor's pane while it is shown.
    var sideColumn: SideColumnController?
    /// The window this one replaced was full screen: it enters full screen once the old one has closed.
    var replacedFullScreen = false
    /// The bar that says another app changed the file (see `ExternalChangeBar`).
    var changeBar: ExternalChangeBar?
    var paneHost: NotesSplitView?
    var applyingOutlineWidth = false
    /// The source line at the top of the preview as the page last reported it, and how many jumps the outline made.
    var lastPageLine: Double?
    var jumps = 0
    /// Instrumentation: the main-thread seconds the last arrival of the headings took.
    var lastOutlineArrival: TimeInterval = 0
    /// The editor's scroll moves the outline's mark, once a display refresh (see `outlineScrolled`).
    var outlineScrollCoalescer: DisplayCoalescer?
    /// Scrolls the outline itself made (a jump) do not move the mark until then.
    var outlineScrollQuietUntil: CFAbsoluteTime = 0
    /// Instrumentation: main-thread seconds of the last update of the mark from the scroll, and how many there were.
    var lastOutlineScrollUpdate: TimeInterval = 0
    var outlineScrollUpdates = 0
    var observers: [NSObjectProtocol] = []

    /// A comfortable size for a new window: 860 by 740 points on an ordinary screen, a little larger
    /// on a big one, never more than nine tenths of the visible screen on a small one.
    static func defaultContentSize(for screen: NSSize?) -> NSSize {
        guard let s = screen, s.width > 0, s.height > 0 else { return NSSize(width: 860, height: 740) }
        let width = min(s.width * 0.9, min(max(s.width * 0.5, 860), 1100))
        let height = min(s.height * 0.9, min(max(s.height * 0.75, 740), 1200))
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    public init(document: MarkdownDocument) {
        session = document.session
        let settings = session.settings

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize(for: NSScreen.main?.visibleFrame.size)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        // The title is the app's own (`titleView`); the window's `title` and `representedURL` stay set.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 280)

        textView = session.makeTextView()
        textView.documentUndoManager = document.undoManager
        session.documentURL = { [weak document] in document?.fileURL }

        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView = EditorClipView()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = textView
        // Becoming the document view, the text view sizes itself to its text (AppKit's
        // `_sizeDownIfPossible`) and can move its own origin doing so: a 10 KB text was left at
        // y = -104 for good (a short one stays at 0), and focus mode's centring, which works in the
        // clip view's coordinates, put the caret's line 104 points above the middle.
        textView.setFrameOrigin(.zero)
        scrollView = scroll
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        previewController = PreviewController(session: session)
        let web = previewController.webView
        web.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(web)
        // The two panes sit side by side in a view that lays them out by frames: NSSplitView's own
        // Auto Layout constraints clash with the panes'.
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setPanes(first: scroll, second: previewPane)
        root.addSubview(splitView)
        root.addSubview(titlebarFade)
        root.addSubview(toolbar)
        root.addSubview(titlebarBand)
        root.addSubview(titleView)
        titlebarBand.translatesAutoresizingMaskIntoConstraints = false
        titleView.translatesAutoresizingMaskIntoConstraints = false
        titleHeight = titleView.heightAnchor.constraint(equalToConstant: 0)
        bandHeight = titlebarBand.heightAnchor.constraint(equalToConstant: 0)
        titlebarFade.translatesAutoresizingMaskIntoConstraints = false
        fadeHeight = titlebarFade.heightAnchor.constraint(equalToConstant: 52)
        let toolbarCentre = toolbar.centerXAnchor.constraint(equalTo: scroll.centerXAnchor)
        // Below the window's own size (`windowSizeStayPut`, 500). The panes are laid out by frames,
        // a pass after the window's constraints are solved: while a window shrinks in one step (an
        // unzoom, leaving full screen) the editor's centre is still where the larger window had it,
        // and a stronger wish to sit under it, plus the bar's 8-point margins, made AppKit stop the
        // window wider than asked (900 came back as 940 after a zoom).
        toolbarCentre.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            web.topAnchor.constraint(equalTo: previewPane.topAnchor),
            web.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            titlebarFade.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarFade.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarFade.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fadeHeight,
            titlebarBand.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarBand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarBand.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bandHeight,
            titleView.topAnchor.constraint(equalTo: root.topAnchor),
            titleView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleHeight,
            // Centred under the editor, unless the editor's pane (in Split) is narrower than the bar:
            // then it moves over just enough to stay inside the window.
            toolbarCentre,
            toolbar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.toolbarBottomMargin),
        ])
        window.contentView = root

        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
        // The first window is centred; each further one cascades from the front document window,
        // so reopening after every window was closed starts in the same place again.
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.windowController is EditorWindowController && !$0.isMiniaturized }
        window.center()
        if let front = others.first(where: { $0.isMainWindow }) ?? others.first {
            let from = NSPoint(x: front.frame.minX, y: front.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: from))
        }
        #if DEBUG || UI_SCRIPT
        // Under a UI script: at the screen's top-left corner, deaf to the real mouse.
        UIScriptRunner.adopt(window)
        #endif

        chrome = ChromeController(window: window, toolbar: toolbar, autoHide: settings.autoHideChrome,
                                  reappearsAfterPause: settings.chromeReturnsAfterPause)
        chrome.titleViews = [titleView]
        titleView.onRename = { [weak self] in self?.markdownDocument?.rename(nil) }
        titleView.canRename = { [weak self] in
            guard let self, let doc = markdownDocument else { return false }
            return chrome.state.isVisible && doc.fileURL != nil && !doc.isBundled
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let w = self?.window { SystemTitle.hide(in: w) } }
        })
        splitView.onRatioChange = { [weak self] ratio in self?.session.settings.splitRatio = Double(ratio) }
        // When the editor's pane changes width (the divider, the window), its top character stays.
        splitView.captureTop = { [weak self] in self?.scrollView.isHidden == false ? self?.keptTopAnchor() : nil }
        // With focus mode centring the caret's line, the line it keeps in the middle is what stays
        // put, not the top character (the two disagree as soon as the text rewraps).
        splitView.restoreTop = { [weak self] anchor in
            guard let self else { return }
            if centring.isActive && !centring.userScrolling { centring.update() } else { restoreEditorTop(anchor) }
        }
        previewController.observeEditor(scroll)
        outlineScrollCoalescer = DisplayCoalescer(view: scroll) { [weak self] in self?.outlineFollowScroll() }
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outlineScrolled() }
        })
        installTitlebar(in: window)
        root.onPointerMoved = { [weak self] in self?.chrome.send(.pointerMoved) }
        textView.onTyping = { [weak self] in self?.chrome.send(.typingStarted) }
        session.onFormatStateChange = { [weak self] in
            guard let self else { return }
            toolbar.update(session.formatState)
        }
        session.onAppearanceChange = { [weak self] in
            self?.applyChrome()
            self?.previewController.appearanceChanged()
        }
        session.onTextChange = { [weak self] in self?.previewController.textChanged() }
        session.onOpenWikilink = { [weak self] ref in self?.openWikilink(target: ref.target, heading: ref.heading) }
        session.onOpenWikilinkInNewWindow = { [weak self] ref in self?.openWikilink(target: ref.target, heading: ref.heading, newWindow: true) }
        session.onLayoutChange = { [weak self] in
            self?.applyLayout()
            self?.outlineLayoutChanged()
        }
        session.onColumnChange = { [weak self] in self?.applyColumn() }
        session.onOutline = { [weak self] entries in self?.outlineArrived(entries) }
        previewController.onPageLine = { [weak self] line in self?.outlinePageScrolled(to: line) }
        observers.append(NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification, object: settings, queue: .main
        ) { [weak self] _ in self?.settingsChanged() })
        toolbar.isHidden = !settings.showFormattingToolbar
        applyChrome()
        applyLayout()
        if session.columnShown { applyColumn() }
        observeChangesOnDisk()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    /// The title bar holds the window buttons and the title, and nothing else: every switch lives in
    /// the menus. The window state the menus show comes from the session, so nothing here has to be
    /// kept in step with it.
    private func installTitlebar(in window: NSWindow) {
        // Never narrower than the formatting bar, and room for the window buttons and a title.
        window.minSize = NSSize(width: max(window.minSize.width, (toolbar.fittingSize.width + 40).rounded(), 360),
                                height: window.minSize.height)
        baseMinWidth = window.minSize.width
        session.onFocusToolsChange = { [weak self] in self?.focusToolsChanged() }
        session.onAuthorshipDecisionNeeded = { [weak self] in
            DispatchQueue.main.async { self?.presentAuthorshipSheetIfNeeded() }
        }
        centring.session = session
        centring.textView = textView
        centring.attach(to: editorScrollView)
        centring.applyInsets = { [weak self] in self?.updateFadeGeometry() }
        centring.editorShown = { [weak self] in self?.scrollView.isHidden == false && self?.window?.isVisible == true }
        centring.layoutAllows = { [weak self] in self?.session.layout != .split }
        textView.centring = centring
        // The caret does not move the outline's mark; the scroll does (`outlineScrolled`).
        session.onCaretActivity = { [weak self] in self?.centring.request() }
        session.onLayoutSettled = { [weak self] in self?.centring.layoutChanged() }
        centring.update()
    }

    private func focusToolsChanged() {
        centring.update()
    }

    /// The file's marks may not line up with its text (it was changed elsewhere): ask, once,
    /// whether to keep or discard them. Editing waits for the answer.
    func presentAuthorshipSheetIfNeeded() {
        guard let status = session.pendingAuthorshipDecision, let window, window.attachedSheet == nil else { return }
        var detail = "The text no longer matches the check value saved with the marks, so they may be on the wrong words. Keep them to see where they land, or discard them."
        if case .malformed(let reason) = status {
            detail = "The marks at the end of this file are not usable as written (\(reason)), so they may be on the wrong words. Keep them to see where they land, or discard them."
        }
        let alert = NSAlert()
        alert.messageText = "This file\u{2019}s authorship marks may be misplaced because it was changed outside the app"
        alert.informativeText = detail
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.session.resolveAuthorshipDecision(keep: response != .alertSecondButtonReturn)
        }
    }

    // MARK: layouts

    @objc func showEditorLayout(_ sender: Any?) { session.setLayout(.editor) }
    @objc func showSplitLayout(_ sender: Any?) { session.setLayout(.split) }
    @objc func showPreviewLayout(_ sender: Any?) { session.setLayout(.preview) }

    /// Shows what `session.layout` says: the editor and the preview each shown or collapsed away
    /// (the editor's text view keeps its selection and scroll while collapsed), the preview told
    /// whether it is visible (it renders only then), the tools that act on the editor off in the
    /// preview, the keyboard focus where the user can work.
    private func applyLayout() {
        let layout = session.layout
        // A narrower or wider editor wraps differently, so a scroll offset in points would land on
        // other text: what stays put is the character at the top of the editor. (While the editor
        // is hidden, the one it had when it was hidden.)
        let top = scrollView.isHidden ? hiddenEditorTop : keptTopAnchor()
        splitView.suspendsTopKeeping = true
        scrollView.isHidden = !layout.showsEditor
        previewPane.isHidden = !layout.showsPreview
        splitView.needsLayout = true
        updateToolbarVisibility()
        updateFadeGeometry()
        if layout == .split { restoreSplitPosition() }
        defer { centring.update() }
        splitView.layoutSubtreeIfNeeded()
        splitView.suspendsTopKeeping = false
        if layout.showsEditor {
            if let top { restoreEditorTop(top) }
            hiddenEditorTop = nil
        } else {
            hiddenEditorTop = top
        }
        previewController.setVisible(layout.showsPreview)
        if let window, window.isVisible || window.firstResponder != nil {
            window.makeFirstResponder(layout == .preview ? previewController.webView : textView)
        }
        // The editor's text view lays out lazily while hidden; its scroll position is not touched.
        if layout.showsPreview, layout.showsEditor { previewController.pushEditorScroll() }
    }

    /// The editor's top character while it is hidden (the Preview layout).
    var hiddenEditorTop: EditorTopAnchor?

    /// The character at the top of the editor's viewport, and how far into its line the viewport
    /// starts (nil when nothing is laid out).
    func editorTopAnchor() -> EditorTopAnchor? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, session.storage.length > 0 else { return nil }
        let y = scrollView.contentView.bounds.minY + scrollView.editorBaseInsetTop - textView.textContainerOrigin.y
        if y <= 0 { return EditorTopAnchor(character: 0, intoLine: y) }
        lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: y, width: tc.size.width, height: 1), in: tc)
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return EditorTopAnchor(character: lm.characterIndexForGlyph(at: glyph), intoLine: y - fragment.minY)
    }

    /// Scrolls the editor so the anchor's character is at the top again, as far into its line as it
    /// was; and once more after AppKit has finished laying out (the text view takes its new width
    /// a pass later, and the lines above move), unless the user scrolled meanwhile.
    func restoreEditorTop(_ anchor: EditorTopAnchor) {
        restoreEditorTopOnce(anchor)
        let placed = scrollView.contentView.bounds.minY
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, abs(self.scrollView.contentView.bounds.minY - placed) < 0.5 else { return }
                self.restoreEditorTopOnce(anchor)
            }
        }
    }

    private func restoreEditorTopOnce(_ anchor: EditorTopAnchor) {
        guard let lm = textView.layoutManager, session.storage.length > 0 else { return }
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let baseTop = scrollView.editorBaseInsetTop
        var y: CGFloat
        if anchor.character == 0 && anchor.intoLine <= 0 {
            y = anchor.intoLine
        } else {
            let character = min(anchor.character, session.storage.length - 1)
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: character + 1))
            let glyph = lm.glyphIndexForCharacter(at: character)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            y = fragment.minY + min(max(0, anchor.intoLine), max(0, fragment.height - 1))
        }
        let wanted = y + textView.textContainerOrigin.y - baseTop
        // Within what the clip view allows (the end is AppKit's), but never pulled up from the
        // top line by its odd top limit.
        let constrained = clip.constrainBoundsRect(NSRect(x: clip.bounds.minX, y: wanted, width: clip.bounds.width, height: clip.bounds.height)).minY
        let target = min(max(wanted, -insets.top), max(constrained, -insets.top))
        if abs(clip.bounds.minY - target) >= 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            scrollView.reflectScrolledClipView(clip)
        }
        restored = (anchor, clip.bounds.minY)
    }

    /// The anchor last restored and where it left the editor: while the editor is still there
    /// (the user has not scrolled), a further change of width keeps that same character, not the
    /// first character of the line it is now on (which, rewrapped again, can be a line earlier).
    private var restored: (anchor: EditorTopAnchor, offset: CGFloat)?

    /// The top to keep across a change of width: the last one restored if the editor has not moved since.
    func keptTopAnchor() -> EditorTopAnchor? {
        if let restored, abs(scrollView.contentView.bounds.minY - restored.offset) < 0.5 { return restored.anchor }
        restored = nil
        return editorTopAnchor()
    }

    /// The formatting toolbar is for editing: not in the preview, and when the setting says so.
    private func updateToolbarVisibility() {
        toolbar.isHidden = !session.settings.showFormattingToolbar || session.layout == .preview
    }

    private func restoreSplitPosition() {
        splitView.ratio = CGFloat(session.settings.splitRatio)
        splitView.layoutSubtreeIfNeeded()
    }

    // MARK: export and copy

    @objc func exportPDF(_ sender: Any?) {
        guard let window, let doc = document as? MarkdownDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.displayName ?? "Untitled") + ".pdf"
        if let folder = doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = folder }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            doc.exportPDF(to: url) { [weak window] error in
                guard let error else { return }
                // The window may have closed while the PDF was being made.
                guard let window, window.isVisible, window.attachedSheet == nil else { NSSound.beep(); return }
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// The selection's blocks, or the whole document: the selection of the editor, which in the
    /// preview layout (where nothing is selected in it) is the whole document.
    private var copyRange: NSRange {
        session.layout == .preview ? NSRange(location: 0, length: 0) : textView.selectedRange()
    }

    @objc func copyAsHTML(_ sender: Any?) {
        if !session.copyAs(.html, range: copyRange, to: textView.pasteboard) { NSSound.beep() }
    }

    @objc func copyAsRichText(_ sender: Any?) {
        if !session.copyAs(.richText, range: copyRange, to: textView.pasteboard) { NSSound.beep() }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showEditorLayout(_:)): item.state = session.layout == .editor ? .on : .off; return true
        case #selector(showSplitLayout(_:)): item.state = session.layout == .split ? .on : .off; return true
        case #selector(showPreviewLayout(_:)): item.state = session.layout == .preview ? .on : .off; return true
        case #selector(toggleSideColumn(_:)): item.state = session.columnShown ? .on : .off; return true
        case #selector(showHistory(_:)):
            item.state = session.historyShown ? .on : .off
            // The history is of a document with a file of its own; a Help page has none.
            return markdownDocument?.isBundled == false
        case #selector(copyAsHTML(_:)), #selector(copyAsRichText(_:)): return session.storage.length > 0
        case #selector(exportPDF(_:)): return true
        case .some(let action) where Self.forwardedToEditor.contains(action):
            // The View menu's switches while the preview has the keyboard: the editor's answers.
            guard let r = textView.validateEditorAction(action, tag: item.tag) else { return true }
            item.state = r.on ? .on : .off
            return r.enabled
        default: return validateNotesItem(item)
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: the View menu while the preview has the keyboard

    /// The view mode, focus and authorship switches are the text view's actions; in the Preview
    /// layout the web view is first responder and the menu would find nobody to ask.
    private static let forwardedToEditor: Set<Selector> = [
        #selector(EditorTextView.showSourceMode(_:)), #selector(EditorTextView.showLiveMode(_:)),
        #selector(EditorTextView.toggleFocusMode(_:)), #selector(EditorTextView.setFocusScope(_:)),
        #selector(EditorTextView.toggleSyntaxHighlight(_:)), #selector(EditorTextView.toggleSyntaxClass(_:)),
        #selector(EditorTextView.toggleAuthorshipDisplay(_:)),
    ]
    @objc func showSourceMode(_ sender: Any?) { textView.showSourceMode(sender) }
    @objc func showLiveMode(_ sender: Any?) { textView.showLiveMode(sender) }
    @objc func toggleFocusMode(_ sender: Any?) { textView.toggleFocusMode(sender) }
    @objc func setFocusScope(_ sender: Any?) { textView.setFocusScope(sender) }
    @objc func toggleSyntaxHighlight(_ sender: Any?) { textView.toggleSyntaxHighlight(sender) }
    @objc func toggleSyntaxClass(_ sender: Any?) { textView.toggleSyntaxClass(sender) }
    @objc func toggleAuthorshipDisplay(_ sender: Any?) { textView.toggleAuthorshipDisplay(sender) }

    private func settingsChanged() {
        chrome.send(.autoHideChanged(session.settings.autoHideChrome))
        chrome.send(.reappearAfterPauseChanged(session.settings.chromeReturnsAfterPause))
        updateToolbarVisibility()
        applyChrome()
        centring.update()
    }

    /// Window-level look: background under the transparent title bar, and the native
    /// appearance (scrollers, title text, toolbar) that matches the theme.
    private func applyChrome() {
        guard let window else { return }
        window.backgroundColor = session.appearance.palette.background
        titlebarFade.color = session.appearance.palette.background
        splitView.dividerTint = session.appearance.palette.rule
        if let sidebar {
            // Only a change of colours redraws the rows (this runs on every window activation too).
            let style = SidebarStyle(session.appearance.palette)
            if style != sidebar.view.style {
                sidebar.view.style = style
                sidebar.styleChanged()
            }
        }
        notesSplit?.tint = session.appearance.palette.rule
        paneHost?.tint = session.appearance.palette.rule
        styleSideColumn()
        updateFadeGeometry()
        let appearance = ThemeStore.windowAppearance(for: session.settings.theme)
        if window.appearance?.name != appearance?.name { window.appearance = appearance }
    }

    /// The fade covers the title bar (solid behind the controls) and then thins out. The scroll
    /// view's content insets keep the caret out from under the title bar and the toolbar when
    /// the text view scrolls it into view (text still runs under both). Fixed while chrome
    /// fades, so nothing shifts.
    func updateFadeGeometry() {
        guard let window else { return }
        let bar = max(0, window.frame.height - window.contentLayoutRect.height)
        titlebarFade.solid = max(0, bar - 6)
        fadeHeight.constant = bar + 22
        bandHeight.constant = bar
        titleHeight.constant = bar
        positionChangeBar()
        titlebarFade.isHidden = bar == 0
        previewController.setChrome(top: bar, bottom: 0)
        let bottom = toolbar.isHidden ? 0 : toolbar.fittingSize.height + Self.toolbarBottomMargin
        // Focus mode makes room above and below the text, half of what is visible, so that the
        // first and the last line can come to the middle.
        let clip = scrollView.contentView
        let extra = centring.insetNow(visibleHeight: max(0, clip.bounds.height - bar - bottom))
        let old = editorScrollView.focusInset
        let insets = NSEdgeInsets(top: bar + extra, left: 0, bottom: bottom + extra, right: 0)
        if scrollView.contentInsets.top != insets.top || scrollView.contentInsets.bottom != insets.bottom {
            let atTop = clip.bounds.minY <= 0 && extra == 0 && old == 0
            let origin = clip.bounds.minY
            editorScrollView.focusInset = extra
            scrollView.contentInsets = insets
            if atTop {
                // Start (or stay) at the top of the text, below the title bar.
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: -insets.top))
                scrollView.reflectScrolledClipView(clip)
            } else if extra != old, abs(clip.bounds.minY - origin) >= 0.01 {
                // Room appearing or going away moves nothing on screen.
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    static let toolbarBottomMargin: CGFloat = 16

    public func windowDidResize(_ notification: Notification) { geometryChanged() }
    public func windowDidEnterFullScreen(_ notification: Notification) { geometryChanged() }
    public func windowDidExitFullScreen(_ notification: Notification) { geometryChanged() }

    /// The window's size changed: the insets follow, and the centred line is placed in the new
    /// middle once the panes have their new frames (they are laid out a pass after the window).
    private func geometryChanged() {
        updateFadeGeometry()
        if centring.isActive { window?.contentView?.layoutSubtreeIfNeeded() }
        centring.update()
    }

    /// The title view shows what the document's name, file and state are now.
    func updateTitleView() {
        guard let window else { return }
        titleView.name = window.title
        titleView.fileURL = markdownDocument?.isBundled == true ? nil : markdownDocument?.fileURL
        titleView.edited = markdownDocument?.isDocumentEdited ?? false
        SystemTitle.hide(in: window)
    }

    public override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        updateTitleView()
    }

    public override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        updateTitleView()
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(session.layout == .preview ? previewController.webView : textView)
        DispatchQueue.main.async { [weak self] in self?.presentAuthorshipSheetIfNeeded() }
    }

    public func windowWillClose(_ notification: Notification) {
        session.outlineTimer?.invalidate()
        history?.service = nil
        previewController.tearDown()
        leaveWorkspace(closing: true)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        session.refreshAppearance()
        documentBecameFront()
        // Pictures another app changed while this window was in the background.
        session.imageController.revalidate()
    }

    // MARK: for tests and UI scripts

    var chromeVisible: Bool { chrome.state.isVisible }
    /// Views drawn over the text (UI-script snapshots composite them).
    var overlayViews: [NSView] { [titlebarFade, toolbar] }
    var titlebarControls: [NSView] { chrome.titlebarViews }
    var chromeController: ChromeController { chrome }
    func simulatePointerMoved() { chrome.send(.pointerMoved) }
    /// While the chrome is hidden the window buttons must not take clicks (the rest of the title
    /// bar stays a title bar: it can be dragged and double-clicked).
    var titlebarButtonsIgnoreClicksWhenHidden: Bool { chrome.state.isVisible || chrome.windowButtonsAreHidden }
}

/// A band of the window's background color that fades to clear downwards; never takes clicks.
final class EdgeFadeView: NSView {
    var color: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    /// Height of the opaque part at the top.
    var solid: CGFloat = 28 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 0 else { return }
        let stop = min(1, solid / bounds.height)
        let clear = color.withAlphaComponent(0)
        let g = NSGradient(colorsAndLocations: (color, 0), (color, stop), (color.withAlphaComponent(0.6), stop + (1 - stop) * 0.4), (clear, 1))
        // Flipped view: 90 degrees runs from the top edge (location 0) down.
        g?.draw(in: bounds, angle: 90)
    }
}

/// Which character is at the top of the editor, and how many points of its line are scrolled
/// past the top: what a layout change keeps.
public struct EditorTopAnchor: Equatable {
    public var character: Int
    public var intoLine: CGFloat
}

/// The editor and the preview side by side, laid out by frames: the divider is a hairline in the
/// theme's rule colour that the user can drag; a pane that is hidden gives its room to the other.
public final class PreviewSplitView: NSView {
    public private(set) var first: NSView?
    public private(set) var second: NSView?
    /// The first pane's share of the width when both are shown.
    public var ratio: CGFloat = 0.5 { didSet { needsLayout = true } }
    public var dividerTint: NSColor = .separatorColor { didSet { needsDisplay = true } }
    /// Told when a drag of the divider ends (the user changed the ratio, not a resize of the window).
    public var onRatioChange: ((CGFloat) -> Void)?
    public static let minimumPane: CGFloat = 260
    private let thickness: CGFloat = 1
    private var dragging = false
    /// Asked before the first pane changes width, and told after: the editor keeps the character
    /// at its top (the text wraps differently at another width).
    var captureTop: (() -> EditorTopAnchor?)?
    var restoreTop: ((EditorTopAnchor) -> Void)?
    /// The window controller is moving the panes itself (a layout switch) and keeps the top itself.
    var suspendsTopKeeping = false

    func setPanes(first: NSView, second: NSView) {
        self.first = first
        self.second = second
        addSubview(first)
        addSubview(second)
    }

    private var bothShown: Bool { first?.isHidden == false && second?.isHidden == false }

    private var firstWidth: CGFloat {
        let usable = bounds.width - thickness
        guard usable > 2 * Self.minimumPane else { return (usable / 2).rounded() }
        return min(max((usable * ratio).rounded(), Self.minimumPane), usable - Self.minimumPane)
    }

    public override func layout() {
        super.layout()
        guard let first, let second else { return }
        let h = bounds.height
        var firstFrame = first.frame, secondFrame = second.frame
        if bothShown {
            let w = firstWidth
            firstFrame = NSRect(x: 0, y: 0, width: w, height: h)
            secondFrame = NSRect(x: w + thickness, y: 0, width: bounds.width - w - thickness, height: h)
        } else {
            // The shown pane takes the width. A hidden one keeps the width it had: collapsing the
            // editor to nothing would wrap its whole text at zero width, and again on the way back.
            firstFrame = first.isHidden ? NSRect(x: 0, y: 0, width: first.frame.width, height: h) : bounds
            secondFrame = second.isHidden ? NSRect(x: bounds.width - second.frame.width, y: 0, width: second.frame.width, height: h) : bounds
        }
        let anchor = !suspendsTopKeeping && !first.isHidden && abs(first.frame.width - firstFrame.width) >= 0.5 ? captureTop?() : nil
        first.frame = firstFrame
        second.frame = secondFrame
        if let anchor {
            first.layoutSubtreeIfNeeded()
            restoreTop?(anchor)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard bothShown else { return }
        dividerTint.setFill()
        NSRect(x: firstWidth, y: 0, width: thickness, height: bounds.height).fill()
    }

    private var grabZone: NSRect { NSRect(x: firstWidth - 3, y: 0, width: thickness + 6, height: bounds.height) }

    public override func resetCursorRects() {
        if bothShown { addCursorRect(grabZone, cursor: .resizeLeftRight) }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bothShown, grabZone.contains(local) { return self }
        return super.hitTest(point)
    }

    public override func mouseDown(with event: NSEvent) { dragging = true }

    public override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let usable = bounds.width - thickness
        guard usable > 0 else { return }
        let lo = Self.minimumPane / usable, hi = 1 - lo
        ratio = min(max(x / usable, lo), max(lo, hi))
        layoutSubtreeIfNeeded()
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onRatioChange?(ratio)
    }
}

/// The editor's clip view. AppKit lets a scroll view with a transparent title bar scroll a whole
/// extra title-bar-and-more above the top of the text (104 points were measured, after a scroll
/// to the end); the text may not go lower than where the document opens, below the title bar.
final class EditorClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        let floor = -(enclosingScrollView?.contentInsets.top ?? 0)
        if r.origin.y < floor { r.origin.y = floor }
        return r
    }
}
