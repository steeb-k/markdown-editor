import AppKit

/// Feeds window events into a `ChromeState` and animates the result: the title bar contents
/// (the title, the window buttons, the tab strip) and the formatting toolbar fade, they never move
/// or take layout space. Typing hides them; the pointer, a menu or the window losing focus brings
/// them back, and so does a pause in typing (the state machine says when, a timer wakes it).
///
/// The title bar itself is never hidden: it keeps taking clicks (a double-click zooms the window
/// whether or not the chrome is showing, and the window can still be dragged by it). Only the three
/// window buttons are switched off once they have faded, so that a click where they were does not
/// close the window. (Switched off, not hidden: AppKit moves the title-bar accessories, the tab
/// strip among them, over to where hidden buttons were.)
final class ChromeController {
    private(set) var state: ChromeState
    private weak var window: NSWindow?
    private weak var toolbar: NSView?
    private var observers: [NSObjectProtocol] = []
    private var reappearTimer: Timer?
    static let fadeDuration: TimeInterval = 0.25
    /// The clock the state machine is given (tests and the harness may substitute their own).
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Told when the chrome has been hidden or shown (the tab strip stops taking clicks while it is hidden).
    var onFaded: ((Bool) -> Void)?
    /// How often the chrome came back by itself (instrumentation).
    private(set) var pauseReappearances = 0

    init(window: NSWindow, toolbar: NSView, autoHide: Bool, reappearsAfterPause: Bool = true,
         delay: TimeInterval = ChromeState.reappearDelay) {
        self.window = window
        self.toolbar = toolbar
        state = ChromeState(autoHide: autoHide, reappearsAfterPause: reappearsAfterPause, delay: delay)
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

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        reappearTimer?.invalidate()
        settleTimer?.invalidate()
    }

    func send(_ event: ChromeState.Event) {
        let changed = state.handle(event, at: clock())
        scheduleReappearance()
        guard let visible = changed else { return }
        animate(visible: visible)
    }

    /// One timer for the one deadline the state machine has, restarted by every keystroke and
    /// dropped when the chrome is shown by something else.
    private func scheduleReappearance() {
        reappearTimer?.invalidate()
        reappearTimer = nil
        guard let deadline = state.reappearDeadline else { return }
        let timer = Timer(timeInterval: max(0.01, deadline - clock()), repeats: false) { [weak self] _ in
            guard let self else { return }
            reappearTimer = nil
            let before = state.isVisible
            send(.tick)
            if !before, state.isVisible { pauseReappearances += 1 }
        }
        RunLoop.main.add(timer, forMode: .common)
        reappearTimer = timer
    }

    /// What fades: the whole title bar view, so that labels AppKit adds later ("— Edited",
    /// which appears with the very keystroke that hides the chrome) fade with it.
    var titlebarViews: [NSView] {
        guard let window else { return extraTitlebarViews }
        if let bar = window.standardWindowButton(.closeButton)?.superview { return [bar] + extraTitlebarViews }
        return windowButtons + extraTitlebarViews
    }

    /// The three window buttons.
    var windowButtons: [NSView] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// Views the window adds to the title bar itself (the tab strip), which fade with it.
    var extraTitlebarViews: [NSView] = []

    private var generation = 0

    /// True once a fade-out has finished: the window buttons are disabled, not just transparent, so a
    /// click where they were does not close or zoom the window.
    var windowButtonsAreHidden: Bool { windowButtons.allSatisfy { !(($0 as? NSControl)?.isEnabled ?? false) } }

    /// How long a fade takes (0: at once; tests use it).
    var fadeDuration: TimeInterval = ChromeController.fadeDuration
    private var settleTimer: Timer?

    private func animate(visible: Bool) {
        generation += 1
        let token = generation
        let alpha: CGFloat = visible ? 1 : 0
        let views = titlebarViews
        let buttons = windowButtons
        if visible { for v in buttons { (v as? NSControl)?.isEnabled = true } }
        onFaded?(!visible)
        if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        // The end state, whether or not the animation ran: invisible buttons must not take clicks
        // (the toolbar refuses them in hitTest); the title bar around them stays hit-testable.
        let settle = { [weak self] in
            guard let self, token == generation else { return }
            settleTimer?.invalidate()
            settleTimer = nil
            toolbar?.alphaValue = alpha
            for v in views { v.alphaValue = alpha }
            if !visible, !state.isVisible { for v in buttons { (v as? NSControl)?.isEnabled = false } }
        }
        settleTimer?.invalidate()
        settleTimer = nil
        // Nothing to animate for a window nobody can see (ordered out, covered, the display asleep).
        guard fadeDuration > 0, let window, window.isVisible, window.occlusionState.contains(.visible) else {
            settle()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            toolbar?.animator().alphaValue = alpha
            for v in views { v.animator().alphaValue = alpha }
        }, completionHandler: settle)
        // AppKit's view animations are paced by the display: with the display asleep they neither
        // progress nor complete. The fade still ends, on time.
        let timer = Timer(timeInterval: fadeDuration + 0.1, repeats: false) { _ in settle() }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
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
        // A window that ignores the mouse is a UI script's: the pointer moving over it is a person's, at work
        // elsewhere, and the tracking area still reports it (it brought the chrome back mid-script).
        if window?.ignoresMouseEvents == true { return }
        if abs(event.deltaX) + abs(event.deltaY) >= 1 { onPointerMoved?() }
    }
}

/// A strip over the top of the content view, as high as the title bar, that does what the title bar does where AppKit's
/// own title bar views do not reach: a few points beside the tab strip's room at each end, and the gaps between the
/// window buttons, where the text view, the web view or the scroll view's backdrop took the click and a drag or a
/// double-click on the row did nothing. AppKit's views stay above it (the buttons, the tab strip, the file name's own
/// button), and it is clear: nothing is drawn.
final class TitlebarBandView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            TitlebarDoubleClick.setting().perform(on: window)
        } else {
            window?.performDrag(with: event)
        }
    }
}
