import AppKit
import WebKit
import MarkdownCore

/// One document's window: a full-size content view with the text column filling it and the
/// formatting toolbar floating over its bottom margin.
public final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    public let session: EditorSession
    public let textView: EditorTextView
    public let scrollView: NSScrollView
    let toolbar = FormattingToolbar(frame: .zero)
    /// Text scrolled up under the transparent title bar fades out instead of colliding with the
    /// traffic lights and the title.
    let titlebarFade = EdgeFadeView()
    /// The view-mode switch in the title bar (Source, Live).
    let modeSwitch = NSSegmentedControl()
    /// The layout switch beside it: editor, editor and preview, preview.
    let layoutSwitch = NSSegmentedControl()
    /// The editor and the preview side by side (either may be collapsed away).
    let splitView = PreviewSplitView()
    let previewPane = NSView()
    public let previewController: PreviewController
    private var applyingSplitPosition = false
    /// Focus mode and syntax highlighting for this window, beside the mode switch.
    let focusButton = NSButton()
    let syntaxButton = NSButton()
    /// Shows or hides the colouring of borrowed text (AI, Reference) in this window.
    let authorshipButton = NSButton()
    private var modeAccessory: NSTitlebarAccessoryViewController?
    private var fadeHeight: NSLayoutConstraint!
    private let root = EditorRootView()
    private var chrome: ChromeController!
    private var observers: [NSObjectProtocol] = []

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
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "io.github.steeb-k.Markdown.document"
        window.minSize = NSSize(width: 360, height: 280)

        textView = session.makeTextView()
        textView.documentUndoManager = document.undoManager
        session.documentURL = { [weak document] in document?.fileURL }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView = EditorClipView()
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = textView
        scrollView = scroll
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        previewController = PreviewController(session: session)
        let web = previewController.webView
        web.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(web)
        // The two panes sit side by side in a view that lays them out by frames: NSSplitView's own
        // Auto Layout constraints clash with the panes' (and break when a window becomes a tab).
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setPanes(first: scroll, second: previewPane)
        root.addSubview(splitView)
        root.addSubview(titlebarFade)
        root.addSubview(toolbar)
        titlebarFade.translatesAutoresizingMaskIntoConstraints = false
        fadeHeight = titlebarFade.heightAnchor.constraint(equalToConstant: 52)
        let toolbarCentre = toolbar.centerXAnchor.constraint(equalTo: scroll.centerXAnchor)
        toolbarCentre.priority = .defaultHigh
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

        chrome = ChromeController(window: window, toolbar: toolbar, autoHide: settings.autoHideChrome)
        splitView.onRatioChange = { [weak self] ratio in self?.session.settings.splitRatio = Double(ratio) }
        // When the editor's pane changes width (the divider, the window), its top character stays.
        splitView.captureTop = { [weak self] in self?.scrollView.isHidden == false ? self?.keptTopAnchor() : nil }
        splitView.restoreTop = { [weak self] anchor in self?.restoreEditorTop(anchor) }
        previewController.observeEditor(scroll)
        installModeSwitch(in: window)
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
        session.onLayoutChange = { [weak self] in self?.applyLayout() }
        observers.append(NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification, object: settings, queue: .main
        ) { [weak self] _ in self?.settingsChanged() })
        toolbar.isHidden = !settings.showFormattingToolbar
        applyChrome()
        applyLayout()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    private func installModeSwitch(in window: NSWindow) {
        modeSwitch.segmentCount = ViewMode.allCases.count
        for (i, mode) in ViewMode.allCases.enumerated() {
            modeSwitch.setLabel(mode.title, forSegment: i)
            modeSwitch.setWidth(0, forSegment: i)
        }
        modeSwitch.trackingMode = .selectOne
        modeSwitch.segmentStyle = .rounded
        modeSwitch.controlSize = .small
        modeSwitch.target = self
        modeSwitch.action = #selector(modeSwitchChanged(_:))
        modeSwitch.setAccessibilityLabel("View mode")
        modeSwitch.sizeToFit()
        for (button, title, action, label) in [
            (focusButton, "Focus", #selector(focusButtonPressed(_:)), "Focus mode"),
            (syntaxButton, "Syntax", #selector(syntaxButtonPressed(_:)), "Syntax highlighting"),
            (authorshipButton, "Authorship", #selector(authorshipButtonPressed(_:)), "Authorship colours"),
        ] {
            button.title = title
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.sizeToFit()
        }
        layoutSwitch.segmentCount = LayoutMode.allCases.count
        for (i, mode) in LayoutMode.allCases.enumerated() {
            layoutSwitch.setImage(NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title), forSegment: i)
            layoutSwitch.setToolTip(mode.title, forSegment: i)
            layoutSwitch.setWidth(30, forSegment: i)
        }
        layoutSwitch.trackingMode = .selectOne
        layoutSwitch.segmentStyle = .rounded
        layoutSwitch.controlSize = .small
        layoutSwitch.target = self
        layoutSwitch.action = #selector(layoutSwitchChanged(_:))
        layoutSwitch.setAccessibilityLabel("Layout")
        layoutSwitch.sizeToFit()
        let gap: CGFloat = 6
        let buttonsWidth = focusButton.frame.width + syntaxButton.frame.width + authorshipButton.frame.width + 3 * gap
        let height = max(modeSwitch.frame.height, focusButton.frame.height)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: buttonsWidth + modeSwitch.frame.width + gap + layoutSwitch.frame.width + 20, height: height + 8))
        focusButton.frame.origin = NSPoint(x: 8, y: (holder.frame.height - focusButton.frame.height) / 2)
        syntaxButton.frame.origin = NSPoint(x: focusButton.frame.maxX + gap, y: (holder.frame.height - syntaxButton.frame.height) / 2)
        authorshipButton.frame.origin = NSPoint(x: syntaxButton.frame.maxX + gap, y: (holder.frame.height - authorshipButton.frame.height) / 2)
        modeSwitch.frame.origin = NSPoint(x: authorshipButton.frame.maxX + gap, y: (holder.frame.height - modeSwitch.frame.height) / 2)
        layoutSwitch.frame.origin = NSPoint(x: modeSwitch.frame.maxX + gap, y: (holder.frame.height - layoutSwitch.frame.height) / 2)
        holder.addSubview(layoutSwitch)
        holder.addSubview(focusButton)
        holder.addSubview(syntaxButton)
        holder.addSubview(authorshipButton)
        holder.addSubview(modeSwitch)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        // Never narrower than the title-bar controls beside the window buttons and a little of the
        // title, or the formatting bar: at 360 points both ran off the window and over the buttons.
        window.minSize = NSSize(width: max(window.minSize.width, (holder.frame.width + 170).rounded(), (toolbar.fittingSize.width + 40).rounded()),
                                height: window.minSize.height)
        modeAccessory = accessory
        chrome.extraTitlebarViews = [holder]
        session.onViewModeChange = { [weak self] in self?.syncModeSwitch() }
        session.onFocusToolsChange = { [weak self] in self?.syncFocusButtons() }
        session.onAuthorshipChange = { [weak self] in self?.syncFocusButtons() }
        session.onAuthorshipDecisionNeeded = { [weak self] in
            DispatchQueue.main.async { self?.presentAuthorshipSheetIfNeeded() }
        }
        syncModeSwitch()
        syncFocusButtons()
    }

    @objc private func focusButtonPressed(_ sender: NSButton) {
        session.setFocusEnabled(sender.state == .on)
        window?.makeFirstResponder(textView)
    }

    @objc private func syntaxButtonPressed(_ sender: NSButton) {
        session.setSyntaxEnabled(sender.state == .on)
        window?.makeFirstResponder(textView)
    }

    @objc private func authorshipButtonPressed(_ sender: NSButton) {
        session.setAuthorshipDisplay(sender.state == .on)
        window?.makeFirstResponder(textView)
    }

    private func syncFocusButtons() {
        focusButton.state = session.focusEnabled ? .on : .off
        syntaxButton.state = session.syntaxEnabled ? .on : .off
        authorshipButton.state = session.authorshipDisplay ? .on : .off
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

    @objc private func modeSwitchChanged(_ sender: NSSegmentedControl) {
        let modes = ViewMode.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
        session.setViewMode(modes[sender.selectedSegment])
        window?.makeFirstResponder(textView)
    }

    private func syncModeSwitch() {
        if let i = ViewMode.allCases.firstIndex(of: session.viewMode) { modeSwitch.selectedSegment = i }
    }

    @objc private func layoutSwitchChanged(_ sender: NSSegmentedControl) {
        let modes = LayoutMode.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < modes.count else { return }
        session.setLayout(modes[sender.selectedSegment])
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
        if let i = LayoutMode.allCases.firstIndex(of: layout) { layoutSwitch.selectedSegment = i }
        let editing = layout.showsEditor
        for control in [modeSwitch, focusButton, syntaxButton, authorshipButton] as [NSControl] { control.isEnabled = editing }
        updateToolbarVisibility()
        updateFadeGeometry()
        if layout == .split { restoreSplitPosition() }
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
    private var hiddenEditorTop: EditorTopAnchor?

    /// The character at the top of the editor's viewport, and how far into its line the viewport
    /// starts (nil when nothing is laid out).
    func editorTopAnchor() -> EditorTopAnchor? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, session.storage.length > 0 else { return nil }
        let y = scrollView.contentView.bounds.minY + scrollView.contentInsets.top - textView.textContainerOrigin.y
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
        let wanted = y + textView.textContainerOrigin.y - insets.top
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
        case #selector(copyAsHTML(_:)), #selector(copyAsRichText(_:)): return session.storage.length > 0
        case #selector(exportPDF(_:)): return true
        default: return true
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func settingsChanged() {
        chrome.send(.autoHideChanged(session.settings.autoHideChrome))
        updateToolbarVisibility()
        applyChrome()
    }

    /// Window-level look: background under the transparent title bar, and the native
    /// appearance (scrollers, title text, toolbar) that matches the theme.
    private func applyChrome() {
        guard let window else { return }
        window.backgroundColor = session.appearance.palette.background
        titlebarFade.color = session.appearance.palette.background
        splitView.dividerTint = session.appearance.palette.rule
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
        titlebarFade.isHidden = bar == 0
        previewController.setChrome(top: bar, bottom: 0)
        let bottom = toolbar.isHidden ? 0 : toolbar.fittingSize.height + Self.toolbarBottomMargin
        let insets = NSEdgeInsets(top: bar, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInsets.top != insets.top || scrollView.contentInsets.bottom != insets.bottom {
            let clip = scrollView.contentView
            let atTop = clip.bounds.minY <= 0
            scrollView.contentInsets = insets
            if atTop {
                // Start (or stay) at the top of the text, below the title bar.
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: -insets.top))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    static let toolbarBottomMargin: CGFloat = 16

    public func windowDidResize(_ notification: Notification) { updateFadeGeometry() }
    public func windowDidEnterFullScreen(_ notification: Notification) { updateFadeGeometry() }
    public func windowDidExitFullScreen(_ notification: Notification) { updateFadeGeometry() }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(session.layout == .preview ? previewController.webView : textView)
        DispatchQueue.main.async { [weak self] in self?.presentAuthorshipSheetIfNeeded() }
    }

    /// The "+" in the tab bar and File > New Tab.
    @objc public override func newWindowForTab(_ sender: Any?) {
        guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true),
              let newWindow = doc.windowControllers.last?.window, let window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        previewController.tearDown()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        session.refreshAppearance()
        // Pictures another app changed while this window was in the background.
        session.imageController.revalidate()
    }

    // MARK: for tests and UI scripts

    var chromeVisible: Bool { chrome.state.isVisible }
    /// Views drawn over the text (UI-script snapshots composite them).
    var overlayViews: [NSView] { [titlebarFade, toolbar] }
    var titlebarControls: [NSView] { chrome.titlebarViews }
    func simulatePointerMoved() { chrome.send(.pointerMoved) }
    /// While the chrome is hidden its title bar controls must not take clicks.
    var titlebarButtonsIgnoreClicksWhenHidden: Bool { chrome.state.isVisible || chrome.titlebarControlsAreHidden }
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
