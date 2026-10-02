import Foundation

/// When the window chrome (title bar contents, formatting toolbar) is shown. Pure logic, no
/// windows: the controller feeds it events and animates whatever it answers.
///
/// Typing hides the chrome; the pointer moving, a menu opening, or the window losing focus
/// brings it back. With auto-hide off it is always visible.
public struct ChromeState: Equatable {
    public enum Event: Equatable {
        case typingStarted
        case pointerMoved
        case menuOpened
        case menuClosed
        case windowResignedKey
        case windowBecameKey
        case autoHideChanged(Bool)
    }

    public private(set) var isVisible = true
    public private(set) var autoHide: Bool
    public private(set) var menuOpen = false
    public private(set) var windowIsKey = true

    public init(autoHide: Bool = true) { self.autoHide = autoHide }

    /// Applies an event; returns the new visibility when it changed, nil otherwise.
    @discardableResult
    public mutating func handle(_ event: Event) -> Bool? {
        let before = isVisible
        switch event {
        case .typingStarted:
            if autoHide && windowIsKey && !menuOpen { isVisible = false }
        case .pointerMoved:
            isVisible = true
        case .menuOpened:
            menuOpen = true
            isVisible = true
        case .menuClosed:
            menuOpen = false
        case .windowResignedKey:
            windowIsKey = false
            isVisible = true
        case .windowBecameKey:
            windowIsKey = true
        case .autoHideChanged(let on):
            autoHide = on
            if !on { isVisible = true }
        }
        return isVisible == before ? nil : isVisible
    }
}
