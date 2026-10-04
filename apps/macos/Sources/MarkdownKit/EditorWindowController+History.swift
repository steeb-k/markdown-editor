import AppKit
import MarkdownCore

/// The history pane of a window (View > Show History) and what the window does with it: Restore, and the bar that says
/// another app changed the file.
extension EditorWindowController {
    /// The diff's colours and font: the theme's own, in the editor's monospaced face at a size the column holds.
    var historyDiffStyle: HistoryModel.DiffStyle {
        let palette = session.appearance.palette
        let mono = session.appearance.fonts.mono
        let font = NSFont(descriptor: mono.fontDescriptor, size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return HistoryModel.DiffStyle(palette: palette, secondary: SidebarStyle(palette).secondary, font: font)
    }

    func makeHistoryController() -> HistoryController {
        let h = HistoryController(style: SidebarStyle(session.appearance.palette), diffStyle: historyDiffStyle)
        h.currentText = { [weak self] in self?.session.text ?? "" }
        h.onRestore = { [weak self] version, text in self?.restore(version, text: text) }
        h.key = markdownDocument?.historyKey
        h.service = HistoryService.current
        return h
    }

    /// The document's file changed name or place, or it got one (a draft was made): the panel shows the history it has now.
    func documentKeyChanged() {
        history?.key = markdownDocument?.historyKey
    }

    /// Puts a version's text in the document: the text as it is now is recorded first (with a message, so the
    /// retention keeps it), the version's replaces it as one undoable edit, "Restore Version", and the result is
    /// recorded as well.
    func restore(_ version: HistoryVersion, text: String) {
        guard text != session.text else { NSSound.beep(); return }
        markdownDocument?.recordSnapshot(.restore, message: "Before restoring a version")
        session.restoreText(text, actionName: "Restore Version")
        markdownDocument?.recordSnapshot(.restore)
        focusEditor()
    }

    // MARK: another app changed the file

    func observeChangesOnDisk() {
        observers.append(NotificationCenter.default.addObserver(forName: .documentChangedOnDisk, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let doc = note.object as? MarkdownDocument, doc === self.markdownDocument else { return }
                self.showChangeBar(hadChanges: note.userInfo?["hadChanges"] as? Bool ?? false)
            }
        })
    }

    func showChangeBar(hadChanges: Bool) {
        changeBar?.removeFromSuperview()
        let message = hadChanges ? "Another app changed this file. What you had here is kept in History."
                                 : "Another app changed this file; it was read again."
        let bar = ExternalChangeBar(message: message, style: SidebarStyle(session.appearance.palette))
        bar.onShowHistory = { [weak self] in
            self?.session.setHistoryShown(true)
            self?.dismissChangeBar()
        }
        bar.onDismiss = { [weak self] in self?.dismissChangeBar() }
        root.addSubview(bar, positioned: .above, relativeTo: nil)
        changeBar = bar
        positionChangeBar()
    }

    func dismissChangeBar() {
        changeBar?.removeFromSuperview()
        changeBar = nil
    }

    /// Under the title bar, across the editor's pane.
    func positionChangeBar() {
        guard let bar = changeBar, let window else { return }
        let top = max(0, window.frame.height - window.contentLayoutRect.height)
        bar.frame = NSRect(x: 0, y: root.bounds.height - top - ExternalChangeBar.height, width: root.bounds.width, height: ExternalChangeBar.height)
        bar.autoresizingMask = [.width, .minYMargin]
    }
}

/// A line under the title bar that says what happened and offers the history; it takes no layout space (it floats over the
/// text, like the toolbar) and stays until dismissed.
final class ExternalChangeBar: NSView {
    static let height: CGFloat = 30
    let label: NSTextField
    let showButton = NSButton(title: "Show History", target: nil, action: nil)
    let closeButton = NSButton(title: "", target: nil, action: nil)
    var onShowHistory: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let style: SidebarStyle

    init(message: String, style: SidebarStyle) {
        self.style = style
        label = NSTextField(labelWithString: message)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        label.font = .systemFont(ofSize: 12)
        label.textColor = style.text
        label.lineBreakMode = .byTruncatingTail
        showButton.bezelStyle = .inline
        showButton.target = self
        showButton.action = #selector(showHistory(_:))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = style.secondary
        closeButton.target = self
        closeButton.action = #selector(dismiss(_:))
        closeButton.setAccessibilityLabel("Dismiss")
        for v in [label, showButton, closeButton] as [NSView] { addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func showHistory(_ sender: Any?) { onShowHistory?() }
    @objc private func dismiss(_ sender: Any?) { onDismiss?() }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 30, y: (bounds.height - 20) / 2, width: 20, height: 20)
        showButton.sizeToFit()
        showButton.frame.origin = NSPoint(x: closeButton.frame.minX - showButton.frame.width - 6, y: (bounds.height - showButton.frame.height) / 2)
        label.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: max(0, showButton.frame.minX - 24), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        style.background.blended(withFraction: 0.08, of: style.accent)?.setFill()
        bounds.fill()
        style.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
