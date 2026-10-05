import AppKit

/// Puts the windows of a `SessionRecord` back at launch. The windows are opened one at a time, the back-most first, each
/// with its state applied before it is shown (the modes, the column, the sidebar), then its caret and scroll after its
/// layout, and full screen last; the recorded key window is made key at the end. A file that is not there any more (or
/// cannot be read) is skipped with a note in the log, never a dialog. A document that is open already (opened by the
/// system as the app was launched, or brought back by AppKit's own restoration) is not opened again: its window takes
/// the record's state.
public final class SessionRestorer {
    /// The restorer of this launch, while it works and after (a UI script waits for it).
    nonisolated(unsafe) public static var current: SessionRestorer?

    public let record: SessionRecord
    public let settings: Settings
    public private(set) var isRestoring = false
    /// The windows put back (front-most first; not held, a window that closes is gone) and how many entries were skipped.
    public var restored: [EditorWindowController] { restoredBoxes.compactMap(\.window) }
    public private(set) var restoredCount = 0
    public private(set) var skipped = 0
    private var restoredBoxes: [WeakWindow] = []
    private struct WeakWindow { weak var window: EditorWindowController? }
    private var finish: (() -> Void)?

    public init(record: SessionRecord, settings: Settings) {
        self.record = record
        self.settings = settings
    }

    /// Whether this launch restores anything: the preference is on and the record has a window to bring back.
    public static func record(for settings: Settings, at url: URL = DocumentFileAccess.sessionRecordURL) -> SessionRecord? {
        guard settings.reopenAtLaunch, let record = SessionRecord.read(from: url), !record.windows.isEmpty else { return nil }
        return record
    }

    public func start(completion: (() -> Void)? = nil) {
        isRestoring = true
        finish = completion
        SessionRecorder.current?.suspended = true
        var queue = Array(record.windows.enumerated().reversed())
        func next() {
            guard let (index, state) = queue.popLast() else { done(); return }
            open(state) { [self] wc in
                if let wc {
                    restoredBoxes.insert(WeakWindow(window: wc), at: 0)
                    restoredCount += 1
                    if index == record.key { keyWindow = wc }
                } else {
                    skipped += 1
                }
                next()
            }
        }
        next()
    }

    private weak var keyWindow: EditorWindowController?

    private func done() {
        // The key window last, so it is in front; the front-most of the rest when the record names none.
        let key = keyWindow ?? restored.first
        key?.window?.makeKeyAndOrderFront(nil)
        key?.documentBecameFront(force: true)
        for wc in restored { if let state = state(of: wc) { wc.restoreFullScreen(state) } }
        isRestoring = false
        if let recorder = SessionRecorder.current {
            recorder.suspended = false
            recorder.noteChange()
        }
        finish?()
        finish = nil
    }

    private var states: [ObjectIdentifier: SessionRecord.Window] = [:]
    private func state(of wc: EditorWindowController) -> SessionRecord.Window? { states[ObjectIdentifier(wc)] }

    // MARK: one window

    private func open(_ state: SessionRecord.Window, then done: @escaping (EditorWindowController?) -> Void) {
        if let ref = state.file {
            guard let url = DocumentFileAccess.resolve(ref) else {
                SessionRecord.log.notice("not reopened, the file is gone: \(ref.path, privacy: .public)")
                done(nil)
                return
            }
            if let existing = NSDocumentController.shared.document(for: url) as? MarkdownDocument {
                done(place(existing, state))
                return
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [self] doc, _, error in
                guard let doc = doc as? MarkdownDocument else {
                    SessionRecord.log.notice("not reopened, the file cannot be read: \(url.path, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
                    done(nil)
                    return
                }
                done(place(doc, state))
            }
        } else if let text = state.untitledText {
            let controller = NSDocumentController.shared
            guard let doc = try? controller.makeUntitledDocument(ofType: controller.defaultType ?? "net.daringfireball.markdown") as? MarkdownDocument else {
                done(nil)
                return
            }
            doc.session.load(text)
            controller.addDocument(doc)
            done(place(doc, state))
            // Its text is what it was, and nothing has been typed since: the title does not say Edited.
            doc.updateChangeCount(.changeCleared)
        } else {
            done(nil)
        }
    }

    /// The document in a window of the record's state, shown.
    private func place(_ doc: MarkdownDocument, _ state: SessionRecord.Window) -> EditorWindowController? {
        if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
        guard let wc = doc.windowControllers.first as? EditorWindowController else { return nil }
        wc.restore(state)
        states[ObjectIdentifier(wc)] = state
        doc.showWindows()
        wc.restoreView(state)
        return wc
    }
}
