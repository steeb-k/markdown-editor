import AppKit
import MarkdownCore

/// Focus mode and syntax highlighting, session side. Both are *overlays*: temporary colours on
/// the layout manager, composed by `OverlayCompositor`. Turning them on or off, or moving the
/// caret, never touches the text storage, the undo stack, the document's edited state or the
/// analysis.
extension EditorSession {
    var focusScopeForCore: FocusScope { settings.focusScope == .sentence ? .sentence : .paragraph }

    func configureOverlay() {
        overlay.layoutManager = layoutManager
        overlay.palette = appearance.palette
        overlay.visibleRange = { [weak self] in self?.visibleRange() ?? NSRange(location: 0, length: 0) }
        overlay.textLength = { [weak self] in self?.storage.length ?? 0 }
        layoutManager.overlay = overlay
    }

    /// Focus mode on or off for this window.
    public func setFocusEnabled(_ on: Bool) {
        guard on != focusEnabled else { return }
        focusEnabled = on
        if on {
            refreshState(synchronous: true)
        } else {
            overlay.setFocus(nil)
            overlay.apply()
        }
        onFocusToolsChange?()
    }

    /// Focus mode holds still (the owner's decision of 5 October): while text is selected, however it was selected (a
    /// drag, ⇧-arrows, a double or triple click, Select All, a Find match), and while the mouse button is down in the
    /// text (a click or a drag that has not selected anything yet), the focus range is not asked for or changed, so the
    /// dimming stays where it was when the selection began. The centring holds too (`FocusCentring.selectionHeld`). One normal
    /// update follows when the selection collapses to a caret, or the button is released. Focus mode turned on with a
    /// selection present (no focus range yet) is not held: it dims around the selection once.
    var focusHeld: Bool {
        guard focusEnabled, overlay.isFocusing, let tv = textView else { return false }
        return tv.isTrackingMouse || tv.selectedRange().length > 0
    }

    /// Syntax (parts of speech) highlighting on or off for this window.
    public func setSyntaxEnabled(_ on: Bool) {
        guard on != syntaxEnabled else { return }
        syntaxEnabled = on
        pos.configure(enabled: on, classes: settings.syntaxClasses)
        onFocusToolsChange?()
    }

    /// The core's focus range for the selection arrived.
    func applyFocus(_ ranges: [Utf16Range]?) {
        guard focusEnabled, !focusHeld else { return }
        let new = (ranges ?? []).map(\.nsRange)
        overlay.setFocus(new)
        overlay.apply()
    }

    /// `Settings` changed: the scope and the classes apply to every window.
    func applyFocusToolSettings() {
        if settings.focusScope != appliedFocusScope {
            appliedFocusScope = settings.focusScope
            if focusEnabled { refreshState(synchronous: true) }
        }
        let classes = settings.syntaxClasses
        if classes != appliedSyntaxClasses || pos.isEnabled != syntaxEnabled {
            appliedSyntaxClasses = classes
            pos.configure(enabled: syntaxEnabled, classes: classes)
        }
    }
}
