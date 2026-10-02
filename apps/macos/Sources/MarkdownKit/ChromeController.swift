import AppKit

/// Feeds window events into a `ChromeState` and animates the result: the title bar contents
/// and the formatting toolbar fade, they never move or take layout space.
final class ChromeController {
    private(set) var state: ChromeState
    private weak var window: NSWindow?
    private weak var toolbar: NSView?
    private var observers: [NSObjectProtocol] = []
    static let fadeDuration: TimeInterval = 0.25

    init(window: NSWindow, toolbar: NSView, autoHide: Bool) {
        self.window = window
        self.toolbar = toolbar
        state = ChromeState(autoHide: autoHide)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.send(.menuOpened)
        })
        observers.append(nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.send(.menuClosed)
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.send(.windowResignedKey)
        })
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.send(.windowBecameKey)
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func send(_ event: ChromeState.Event) {
        guard let visible = state.handle(event) else { return }
        animate(visible: visible)
    }

    /// What fades: the whole title bar view, so that labels AppKit adds later ("— Edited",
    /// which appears with the very keystroke that hides the chrome) fade with it.
    var titlebarViews: [NSView] {
        guard let window else { return [] }
        if let bar = window.standardWindowButton(.closeButton)?.superview { return [bar] }
        return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    private var generation = 0

    /// True once a fade-out has finished: the title bar controls are hidden, not just
    /// transparent, so a click where they were does not close or zoom the window.
    var titlebarControlsAreHidden: Bool { titlebarViews.allSatisfy { $0.isHidden } }

    private func animate(visible: Bool) {
        generation += 1
        let token = generation
        let alpha: CGFloat = visible ? 1 : 0
        let views = titlebarViews
        if visible { for v in views { v.isHidden = false } }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            toolbar?.animator().alphaValue = alpha
            for v in views { v.animator().alphaValue = alpha }
        }, completionHandler: { [weak self] in
            // Invisible controls must not take clicks (the toolbar refuses them in hitTest).
            guard let self, token == generation, !visible, !state.isVisible else { return }
            for v in views { v.isHidden = true }
        })
        if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}

/// Content view that reports pointer movement anywhere over the window.
final class EditorRootView: NSView {
    var onPointerMoved: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) {
        if abs(event.deltaX) + abs(event.deltaY) >= 1 { onPointerMoved?() }
    }
}
