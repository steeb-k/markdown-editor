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
            let changed = overlay.isFocusing
            overlay.setFocus(nil)
            overlay.apply()
            if changed { redrawDecorations() }
        }
        onFocusToolsChange?()
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
        guard focusEnabled else { return }
        let new = (ranges ?? []).map(\.nsRange)
        let changed = new != overlay.layers.focus
        overlay.setFocus(new)
        overlay.apply()
        if changed { redrawDecorations() }
    }

    /// Bullets, boxes, bars, rules and pictures are drawn by hand and take their strength from
    /// the focus range: when it changes, what is on screen is drawn again (colour only, no
    /// layout). Text itself is redrawn by the temporary attributes.
    private func redrawDecorations() {
        guard viewMode == .live, !layoutManager.live.decorations.isEmpty, let tv = textView else { return }
        tv.setNeedsDisplay(tv.visibleRect, avoidAdditionalLayout: true)
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
