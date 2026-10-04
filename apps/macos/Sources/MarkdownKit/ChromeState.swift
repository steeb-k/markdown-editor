import Foundation

/// When the window chrome (the title, the window buttons and the formatting
/// toolbar) is shown. Pure logic, no windows and no clock: the controller feeds it events and the
/// time they happened at, and animates whatever it answers.
///
/// Typing hides the chrome; the pointer moving, a menu opening, or the window losing focus
/// brings it back at once, and so does a pause in typing (`reappearDelay` after the last key).
/// With auto-hide off it is always visible.
public struct ChromeState: Equatable {
    public enum Event: Equatable {
        case typingStarted
        case pointerMoved
        case menuOpened
        case menuClosed
        case windowResignedKey
        case windowBecameKey
        case autoHideChanged(Bool)
        /// Whether a pause in typing brings the chrome back (a setting).
        case reappearAfterPauseChanged(Bool)
        /// Time has passed (the controller sends one when a deadline falls due).
        case tick
    }

    /// How long after the last keystroke the chrome fades back in.
    public static let reappearDelay: TimeInterval = 2.5

    public private(set) var isVisible = true
    public private(set) var autoHide: Bool
    public private(set) var reappearsAfterPause: Bool
    public private(set) var menuOpen = false
    public private(set) var windowIsKey = true
    /// The time of the last keystroke that hid (or kept hidden) the chrome; nil while it is shown.
    public private(set) var lastKey: TimeInterval?
    public let delay: TimeInterval

    public init(autoHide: Bool = true, reappearsAfterPause: Bool = true, delay: TimeInterval = ChromeState.reappearDelay) {
        self.autoHide = autoHide
        self.reappearsAfterPause = reappearsAfterPause
        self.delay = delay
    }

    /// When the chrome comes back by itself, if it is hidden and nothing else is going to show it.
    public var reappearDeadline: TimeInterval? {
        guard !isVisible, reappearsAfterPause, let lastKey else { return nil }
        return lastKey + delay
    }

    /// Applies an event that happened at `now` (seconds, any steady clock); returns the new
    /// visibility when it changed, nil otherwise.
    @discardableResult
    public mutating func handle(_ event: Event, at now: TimeInterval = 0) -> Bool? {
        let before = isVisible
        switch event {
        case .typingStarted:
            if autoHide && windowIsKey && !menuOpen {
                isVisible = false
                lastKey = now
            }
        case .pointerMoved:
            show()
        case .menuOpened:
            menuOpen = true
            show()
        case .menuClosed:
            menuOpen = false
        case .windowResignedKey:
            windowIsKey = false
            show()
        case .windowBecameKey:
            windowIsKey = true
        case .autoHideChanged(let on):
            autoHide = on
            if !on { show() }
        case .reappearAfterPauseChanged(let on):
            reappearsAfterPause = on
        case .tick:
            if let deadline = reappearDeadline, now >= deadline { show() }
        }
        return isVisible == before ? nil : isVisible
    }

    private mutating func show() {
        isVisible = true
        lastKey = nil
    }
}
