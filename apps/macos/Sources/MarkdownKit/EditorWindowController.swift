import AppKit
import MarkdownCore

/// One document's window: a full-size content view with the text column filling it and the
/// formatting toolbar floating over its bottom margin.
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    public let session: EditorSession
    public let textView: EditorTextView
    public let scrollView: NSScrollView
    let toolbar = FormattingToolbar(frame: .zero)
    /// Text scrolled up under the transparent title bar fades out instead of colliding with the
    /// traffic lights and the title.
    let titlebarFade = EdgeFadeView()
    private var fadeHeight: NSLayoutConstraint!
    private let root = EditorRootView()
    private var chrome: ChromeController!
    private var observers: [NSObjectProtocol] = []
    private static var windowCount = 0

    public init(document: MarkdownDocument) {
        session = document.session
        let settings = session.settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 740),
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
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = textView
        scrollView = scroll
        scroll.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(titlebarFade)
        root.addSubview(toolbar)
        titlebarFade.translatesAutoresizingMaskIntoConstraints = false
        fadeHeight = titlebarFade.heightAnchor.constraint(equalToConstant: 52)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            titlebarFade.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarFade.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarFade.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fadeHeight,
            toolbar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.toolbarBottomMargin),
        ])
        window.contentView = root

        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
        Self.windowCount += 1
        window.center()
        if Self.windowCount > 1 {
            let f = window.frame
            window.setFrameOrigin(NSPoint(x: f.minX + CGFloat((Self.windowCount - 1) % 8) * 26,
                                          y: f.minY - CGFloat((Self.windowCount - 1) % 8) * 26))
        }

        chrome = ChromeController(window: window, toolbar: toolbar, autoHide: settings.autoHideChrome)
        root.onPointerMoved = { [weak self] in self?.chrome.send(.pointerMoved) }
        textView.onTyping = { [weak self] in self?.chrome.send(.typingStarted) }
        session.onFormatStateChange = { [weak self] in
            guard let self else { return }
            toolbar.update(session.formatState)
        }
        session.onAppearanceChange = { [weak self] in self?.applyChrome() }
        observers.append(NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification, object: settings, queue: .main
        ) { [weak self] _ in self?.settingsChanged() })
        toolbar.isHidden = !settings.showFormattingToolbar
        applyChrome()
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func settingsChanged() {
        chrome.send(.autoHideChanged(session.settings.autoHideChrome))
        toolbar.isHidden = !session.settings.showFormattingToolbar
        applyChrome()
    }

    /// Window-level look: background under the transparent title bar, and the native
    /// appearance (scrollers, title text, toolbar) that matches the theme.
    private func applyChrome() {
        guard let window else { return }
        window.backgroundColor = session.appearance.palette.background
        titlebarFade.color = session.appearance.palette.background
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
        window?.makeFirstResponder(textView)
    }

    /// The "+" in the tab bar and File > New Tab.
    @objc public override func newWindowForTab(_ sender: Any?) {
        guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true),
              let newWindow = doc.windowControllers.last?.window, let window else { return }
        window.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        session.refreshAppearance()
    }

    // MARK: for tests and UI scripts

    var chromeVisible: Bool { chrome.state.isVisible }
    /// Views drawn over the text (UI-script snapshots composite them).
    var overlayViews: [NSView] { root.subviews.filter { $0 !== scrollView } }
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
