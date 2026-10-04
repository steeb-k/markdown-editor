import AppKit
import MarkdownCore

/// Writing without being asked, and the history that goes with it.
///
/// A titled document is written 2 s after the last edit (`autosaveDelay`), and when it leaves its window (closing,
/// being replaced, quitting); every such write takes a snapshot. NSDocument's own machinery does the writing:
/// `autosavesInPlace` makes `autosave(withImplicitCancellability:)` save over the file itself, through the same
/// coordinated, asynchronous path as ⌘S, and clears the change count, so the window never shows its edited dot for
/// longer than the pause. Its own timer (`NSDocumentController.autosavingDelay`) stays as the ceiling for a stream of
/// typing that never pauses. The undo stack is never touched by a save.
///
/// An untitled document is written into the library's `Drafts` folder as `Untitled N.md` (it becomes titled, and
/// appears in the sidebar); with no library it keeps NSDocument's own question on closing.
extension MarkdownDocument {
    // MARK: the history of this document

    var historyLibrary: LibraryController { Workspace.libraryController(for: session.settings) }

    /// The key of this document's history (see `HistoryKey`); nil until it has a file.
    public var historyKey: String? { fileURL.map { HistoryKey.key(for: $0, library: historyLibrary) } }

    /// The file moved or was renamed (by the app or by NSDocument's own Rename and Move To): its history goes with it.
    func renamedHistory(from old: URL, to new: URL) {
        guard !isBundled, let service = HistoryService.current else { return }
        // A move or a rename takes the file from where it was (a change of case only is the same file); a Save As leaves
        // the first file where it is, with its history.
        let sameFile = old.path.lowercased() == new.path.lowercased()
        guard sameFile || !DocumentFileAccess.exists(old) else { return }
        let library = historyLibrary
        service.rekey(HistoryKey.key(for: old, library: library), to: HistoryKey.key(for: new, library: library))
    }

    /// Records the document's text (or `text`) in its history, after the text it was opened with when that has not
    /// been recorded yet. Nothing for a document without a file, or when history is off; the store records nothing
    /// when the text is what its latest snapshot holds, and nothing is recorded while the text is still the one the
    /// document was opened with (a note looked at and left unchanged gets no history).
    func recordSnapshot(_ reason: HistoryReason, message: String? = nil, text: String? = nil) {
        guard !isBundled, let service = HistoryService.current, let key = historyKey else { return }
        let text = text ?? session.text
        if !baselineRecorded {
            if let opened = openedText, opened == text { return }
            baselineRecorded = true
            if let opened = openedText { service.record(key: key, text: opened, reason: .close) }
        }
        service.record(key: key, text: text, reason: reason, message: message)
    }

    // MARK: autosave

    /// The text changed (not a load): the write and the snapshot are owed 2 s after the last change.
    func textChanged() {
        guard !isBundled else { return }
        refreshTitleSoon()
        let due = Date(timeIntervalSinceNow: Self.autosaveDelay)
        // A keystroke moves the one timer on; it makes none.
        if let t = autosaveTimer, t.isValid { t.fireDate = due; return }
        let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosaveFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    /// The title says "Edited" by the change count, which NSDocument moves (when an undo group closes, when a write is done)
    /// without always telling: one look after the edit's own event, which a burst of keys shares.
    func refreshTitleSoon() {
        guard !titleRefreshPending else { return }
        titleRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.titleRefreshPending = false
                (self?.windowControllers.first as? EditorWindowController)?.updateTitleView()
            }
        }
    }

    func cancelAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    /// Every change of the change count: the window's title says "Edited" while it is on, and an edit that did not come
    /// with a change of the text (Mark As, a discarded authorship check) still owes its write: without the timer the
    /// document stayed edited until it was closed.
    public override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        (windowControllers.first as? EditorWindowController)?.updateTitleView()
        switch change {
        case .changeDone, .changeRedone, .changeUndone:
            if isDocumentEdited, autosaveTimer?.isValid != true { textChanged() }
        default: break
        }
    }

    /// A write's own clearing of the change count goes through here, not through `updateChangeCount(_:)`: nothing else says
    /// the document is clean again (AppKit's own title kept "Edited" after every autosave in place).
    public override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        (windowControllers.first as? EditorWindowController)?.updateTitleView()
    }

    /// The pause: another app's newer version of the file first, then the snapshot and the write.
    func autosaveFired() {
        autosaveTimer = nil
        guard !isBundled else { return }
        if fileURL == nil {
            makeDraft()
            return
        }
        if handleExternalChange() { return }
        recordSnapshot(.pause)
        if isDocumentEdited { autosave(withImplicitCancellability: false) { _ in } }
    }

    // MARK: saving: the snapshot that goes with it

    public override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                              completionHandler: @escaping (Error?) -> Void) {
        let text = session.text
        // Typing goes on in a new undo group after a write. Coalesced into the group the write already counted, it
        // would never mark the document edited again: the next pause would snapshot it but not write it, and closing
        // would write nothing (AppKit's own advice for `breakUndoCoalescing`, which TextEdit follows for autosaves too).
        session.textView?.breakUndoCoalescing()
        let explicit = saveOperation == .saveOperation || saveOperation == .saveAsOperation
        let reason = nextSnapshotReason ?? (explicit ? .save : .pause)
        nextSnapshotReason = nil
        savesInFlight += 1
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self else { completionHandler(error); return }
            savesInFlight -= 1
            if error == nil, explicit || saveOperation == .autosaveInPlaceOperation { recordSnapshot(reason, text: text) }
            completionHandler(error)
            // NSDocument clears the change count after this returns, and tells nobody when it does for a save in place.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { (self?.windowControllers.first as? EditorWindowController)?.updateTitleView() }
            }
        }
    }

    // MARK: drafts

    /// Where an untitled document is drafted: the library's `Drafts` folder.
    var draftsFolder: URL? {
        historyLibrary.roots.first { !$0.isAddedFolder }?.url.appendingPathComponent("Drafts", isDirectory: true)
    }

    /// `Untitled 1.md`, `Untitled 2.md`... the first not taken in `folder`.
    static func draftURL(in folder: URL) -> URL {
        var n = 1
        while true {
            let url = folder.appendingPathComponent("Untitled \(n)").appendingPathExtension("md")
            if !DocumentFileAccess.exists(url) { return url }
            n += 1
        }
    }

    /// Whether the document is untitled with text worth keeping.
    var hasDraftableText: Bool {
        fileURL == nil && !isBundled && !session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes an untitled document into `Drafts` and makes it titled. False when that cannot be done (no library, no
    /// text); `done` is told whether the file was written.
    @discardableResult
    func makeDraft(done: ((Bool) -> Void)? = nil) -> Bool {
        guard hasDraftableText, let folder = draftsFolder else { return false }
        do { try DocumentFileAccess.ensureFolder(folder) } catch { return false }
        let url = Self.draftURL(in: folder)
        nextSnapshotReason = .draft
        save(to: url, ofType: fileType ?? "net.daringfireball.markdown", for: .saveAsOperation) { [weak self] error in
            guard let self else { done?(false); return }
            if error == nil {
                historyLibrary.refresh([url])
                (windowControllers.first as? EditorWindowController)?.documentBecameFront(force: true)
            }
            done?(error == nil)
        }
        return true
    }

    // MARK: leaving the window

    /// The document is about to leave its window (closing, a note replacing it, quitting): whatever is owed is written
    /// and snapshotted first. `completion` is told whether it may go: false only when the user cancelled the question
    /// an untitled document with no library asks.
    func settleForLeaving(completion: @escaping (Bool) -> Void) {
        cancelAutosave()
        if isBundled {
            isDocumentEdited ? askStandard(completion) : completion(true)
            return
        }
        if fileURL == nil {
            if hasDraftableText {
                if makeDraft(done: { ok in ok ? completion(true) : self.askStandard(completion) }) { return }
                askStandard(completion)
            } else {
                // Nothing worth a file (empty, or blanks): nothing to ask about either.
                updateChangeCount(.changeCleared)
                completion(true)
            }
            return
        }
        _ = handleExternalChange()
        recordSnapshot(.close)
        guard isDocumentEdited else { completion(true); return }
        autosave(withImplicitCancellability: false) { [weak self] error in
            if error == nil { completion(true) } else if let self { askStandard(completion) } else { completion(true) }
        }
    }

    public override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                                  contextInfo: UnsafeMutableRawPointer?) {
        settleForLeaving { [self] ok in
            guard let selector = shouldCloseSelector else { return }
            let target = delegate as AnyObject
            typealias Callback = @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
            let call = unsafeBitCast(target.method(for: selector), to: Callback.self)
            call(target, selector, self, ok, contextInfo)
        }
    }

    // MARK: another app changed the file

    /// The file on disk has another date than the one this document last wrote or read: it was changed by another app
    /// (a newer date, or an older one: a copy put back with its own date, as `cp -p`, `rsync -t` or a restored backup
    /// leave it, which NSDocument would otherwise meet at the next autosave with its "changed by another application"
    /// sheet). Never overwritten: the text here is snapshotted (with a message when it had changes of its own, so the
    /// thinning keeps it), the file is read again, and the window says so in a bar. True when it did.
    @discardableResult
    func handleExternalChange() -> Bool {
        guard !isBundled, savesInFlight == 0, let url = fileURL, let disk = DocumentFileAccess.modificationDate(of: url),
              let known = fileModificationDate, abs(disk.timeIntervalSince(known)) > 0.001 else { return false }
        let wasEdited = isDocumentEdited
        // Another date on the very bytes this document would write (a sync tool touched the file): nothing changed.
        if let onDisk = try? DocumentFileAccess.read(url), onDisk == saveSnapshot().encoded() {
            fileModificationDate = disk
            return false
        }
        recordSnapshot(.pause, message: wasEdited ? "Before another app changed this file" : nil)
        do { try revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown") } catch { return false }
        recordSnapshot(.pause)
        NotificationCenter.default.post(name: .documentChangedOnDisk, object: self, userInfo: ["hadChanges": wasEdited])
        return true
    }

    public override func presentedItemDidChange() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = handleExternalChange() }
        } else {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { _ = self?.handleExternalChange() } }
        }
        super.presentedItemDidChange()
    }
}
