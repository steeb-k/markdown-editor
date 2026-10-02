import AppKit
import MarkdownCore

/// How the next character edit of the text storage is attributed. Set by whoever makes the
/// edit; the storage delegate (which sees every edit, whoever made it) reads it.
enum EditOrigin {
    /// Typing, IME, plain paste, drag, find-and-replace: the user's own text (Me).
    case typed
    /// An edit the core's commands computed (format, table, newline, indent, task, realign,
    /// image): what it did not change keeps its author, what it inserts takes its neighbour's.
    /// `old` is the text the edit replaces.
    case inherit(old: String)
    /// Paste As: the author the user chose.
    case pasteAs(Author)
    /// Leave the inserted text unattributed (a paste about to apply the runs it carries).
    case unattributed
}

/// The three sources the menus offer.
public enum AuthorChoice: Int, CaseIterable {
    case me, ai, reference

    public var title: String {
        switch self {
        case .me: return "Me"
        case .ai: return "AI"
        case .reference: return "Reference"
        }
    }
}

/// The undo bookkeeping for authorship, see `EditorSession.registerAuthorshipUndo`.
struct AuthorshipUndoState {
    /// Bumped whenever the observed undo manager opens a group.
    var groupSerial = 0
    /// The group an authorship action was last registered in.
    var registeredSerial = -1
    /// The attribution when the undo or redo in progress began.
    var operationStart: AuthorshipSnapshot?
    /// What the attribution must be once that undo or redo has finished.
    var pendingRestore: AuthorshipSnapshot?
    weak var observed: UndoManager?
    var observers: [NSObjectProtocol] = []

    mutating func reset() {
        registeredSerial = -1
        operationStart = nil
        pendingRestore = nil
    }
}

extension NSRange {
    var utf16Range: Utf16Range { Utf16Range(start: UInt32(location), end: UInt32(location + length)) }
}

extension EditorSession {
    /// The Human author whose text is the user's.
    public var meAuthor: Author { authorship.me() }

    /// The author a menu choice stands for in this document: Me, or the first author of that
    /// kind the file already has (a file written by another app keeps its names), or a new one.
    public func author(for choice: AuthorChoice) -> Author {
        switch choice {
        case .me: return authorship.me()
        case .ai: return authorship.authors().first { $0.kind == .ai } ?? Author(kind: .ai, name: "AI")
        case .reference: return authorship.authors().first { $0.kind == .reference } ?? Author(kind: .reference, name: "Reference")
        }
    }

    /// Which menu choice an author index falls under (another person's text counts as Reference).
    func choice(ofAuthorAt index: UInt32, in authors: [Author]) -> AuthorChoice {
        if index == 0 { return .me }
        return authors[Int(index)].kind == .ai ? .ai : .reference
    }

    // MARK: display

    public func setAuthorshipDisplay(_ on: Bool) {
        guard on != authorshipDisplay else { return }
        authorshipDisplay = on
        refreshAuthorshipOverlay()
        textView?.setNeedsDisplay(textView?.visibleRect ?? .zero, avoidAdditionalLayout: true)
        onAuthorshipChange?()
    }

    /// Feeds the compositor's authorship layer from the attribution: the user's own text (and
    /// unattributed text) is the stored colour, so only the rest becomes runs. With `around`,
    /// only the layer inside that range is rebuilt (an edit changed nothing else).
    func refreshAuthorshipOverlay(around: NSRange? = nil, apply: Bool = true) {
        var runs: [OverlayRun] = []
        let visible = authorshipDisplay && authorship.hasMarks()
        var window = around
        if let w = around { window = RangeMath.clamp(w, toLength: storage.length) }
        if visible {
            let authors = authorship.authors()
            let within = window.map { Utf16Range(start: UInt32($0.location), end: UInt32(NSMaxRange($0))) }
            for r in authorship.runs(within: within) where r.authorIndex != 0 {
                let source: AuthorSource = authors[Int(r.authorIndex)].kind == .ai ? .ai : .reference
                runs.append(OverlayRun(r.range.nsRange, .authorship(source)))
            }
        }
        if let window, visible || !overlay.layers.authorship.isEmpty {
            overlay.patchAuthorship(runs, in: window)
        } else if around == nil {
            overlay.setAuthorship(OverlayCompositor.merged(runs))
        }
        if apply { overlay.apply() }
    }

    // MARK: following edits

    /// The storage changed `change.old` into `replacement`: the attribution follows.
    func trackAuthorship(_ change: TextChange, replacement: String) {
        // However the attribution changes, the compositor's runs (which `noteEdit` just cut
        // around the edit) are put right from it, a little beyond the edit on both sides (runs
        // merge or split there).
        defer {
            let around = NSRange(location: max(0, change.old.location - 1), length: change.newLength + 2)
            refreshAuthorshipOverlay(around: around, apply: false)
        }
        let um = textView?.undoManager
        if um?.isUndoing == true || um?.isRedoing == true {
            // Undo and redo put the attribution back from a snapshot once they are done
            // (`finishUndoOperation`); in between it only has to stay in step with the text.
            // (A same-length event is attributes being fixed, or text put back as it was; the
            // edited range is wider than the change and must not flatten what lies in it.)
            if change.newLength != change.old.length {
                authorship.edit(range: change.old.utf16Range, insertedLen: UInt32(change.newLength), attribution: .inherit)
            }
            return
        }
        // The storage's edited range can be wider than what was typed (attribute fixing makes
        // it cover the text after the caret too, and reports edits that change nothing); the
        // edits the text view announced are exact. One storage edit can carry several of them
        // (the text view applies a Replace All inside one round of editing) and several storage
        // edits can make up one announcement (each replacement on its own).
        let inside = pendingEdits.indices.filter {
            let p = pendingEdits[$0].range
            return p.location >= change.old.location && NSMaxRange(p) <= NSMaxRange(change.old)
        }
        let delta = inside.reduce(0) { $0 + pendingEdits[$1].length - pendingEdits[$1].range.length }
        guard !inside.isEmpty, delta == change.newLength - change.old.length else {
            pendingEdits = []
            // An edit nobody announced: one that changed no length is taken for a change of
            // attributes only; otherwise the text is inserted as a command would.
            if change.newLength != change.old.length {
                authorship.edit(range: change.old.utf16Range, insertedLen: UInt32(change.newLength), attribution: .inherit)
            }
            return
        }
        let edits = inside.map { pendingEdits[$0] }
        pendingEdits = pendingEdits.indices.filter { !inside.contains($0) }.map { i in
            // What is still to come moves with this change.
            var e = pendingEdits[i]
            if e.range.location >= NSMaxRange(change.old) { e.range.location += change.newLength - change.old.length }
            return e
        }
        if edits.count == 1, case .inherit(let old) = editOrigin {
            let p = edits[0]
            let offset = p.range.location - change.old.location
            let exactReplacement = (replacement as NSString).substring(with: NSRange(location: offset, length: p.length))
            authorship.editReplacing(range: p.range.utf16Range, old: old, new: exactReplacement, attribution: .inherit)
            return
        }
        let attribution: Attribution
        switch editOrigin {
        case .typed, .inherit: attribution = .typed(author: authorship.me())
        case .pasteAs(let author): attribution = .pasted(author: author)
        case .unattributed: attribution = .none
        }
        // Last first: the earlier ranges are still where they were announced.
        for p in edits.sorted(by: { $0.range.location > $1.range.location }) {
            authorship.edit(range: p.range.utf16Range, insertedLen: UInt32(p.length), attribution: attribution)
        }
    }

    // MARK: Mark As

    /// Mark As: attributes `range` to `choice`, or to nobody (`nil`). One undo step.
    @discardableResult
    public func mark(_ range: NSRange, as choice: AuthorChoice?, actionName: String? = nil) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        let before = authorship.snapshot()
        var author: Author?
        if let choice { author = self.author(for: choice) }
        authorship.mark(range: Utf16Range(start: UInt32(range.location), end: UInt32(NSMaxRange(range))), author: author)
        guard !before.equals(other: authorship.snapshot()) else { return false }
        registerAuthorshipUndo(before: before)
        if let um = textView?.undoManager, um.groupingLevel > 0 {
            um.setActionName(actionName ?? "Mark as \(choice?.title ?? "No Author")")
        }
        refreshAuthorshipOverlay()
        onAuthorshipChange?()
        return true
    }

    /// Applies runs that travelled with copied text, at `location`, without a separate undo step.
    func applyCarried(_ payload: AuthorshipPasteboard.Payload, at location: Int) {
        for run in payload.runs {
            let author = payload.authors[run.author]
            authorship.mark(range: Utf16Range(start: UInt32(location + run.start), end: UInt32(location + run.start + run.length)),
                            author: author)
        }
        refreshAuthorshipOverlay()
    }

    // MARK: undo and redo

    /// Called before an edit changes the attribution (and by Mark As with its own snapshot):
    /// registers, once per undo group, an action that puts the attribution back.
    ///
    /// The design: undo and redo of the *text* re-enter the storage delegate, which can only
    /// keep the attribution in step, not know what it was. So each group carries an action
    /// holding the attribution from before it. When the undo manager runs that action (undo or
    /// redo, it is symmetrical) the action registers its own inverse, holding the attribution
    /// as it was when the operation began, and remembers what to restore. When the operation is
    /// over (`NSUndoManagerDidUndoChange` / `DidRedoChange`) the attribution is set to exactly
    /// that snapshot, whatever the text edits in between did to it.
    func registerAuthorshipUndo(before: AuthorshipSnapshot? = nil) {
        guard let um = textView?.undoManager, um.isUndoRegistrationEnabled else { return }
        guard um.groupsByEvent || um.groupingLevel > 0 else { return }
        observeUndoManager(um)
        let snapshot: AuthorshipSnapshot
        if let before {
            snapshot = before
        } else {
            // Once per undo group: later edits of the group are covered by this snapshot.
            if um.groupingLevel > 0, authorshipUndo.registeredSerial == authorshipUndo.groupSerial { return }
            snapshot = authorship.snapshot()
        }
        um.registerUndo(withTarget: self) { target in target.authorshipUndoStep(to: snapshot) }
        authorshipUndo.registeredSerial = authorshipUndo.groupSerial
    }

    private func authorshipUndoStep(to target: AuthorshipSnapshot) {
        let inverse = authorshipUndo.operationStart ?? authorship.snapshot()
        textView?.undoManager?.registerUndo(withTarget: self) { $0.authorshipUndoStep(to: inverse) }
        authorshipUndo.pendingRestore = target
    }

    private func finishUndoOperation() {
        if let restore = authorshipUndo.pendingRestore {
            authorship.restore(snapshot: restore)
            onAuthorshipChange?()
        }
        refreshAuthorshipOverlay()
        authorshipUndo.pendingRestore = nil
        authorshipUndo.operationStart = nil
        // Undo and redo select what they changed and scroll it into view, in that order: the
        // selection was asked about with the window of what was on screen before. Ask again on
        // the next turn, with the view where it ended up (a far selection's units are worked
        // out inside the window, see `focus_ranges`).
        scheduleLiveRefresh()
    }

    private func observeUndoManager(_ um: UndoManager) {
        guard authorshipUndo.observed !== um else { return }
        authorshipUndo.observers.forEach(NotificationCenter.default.removeObserver)
        authorshipUndo.observed = um
        let nc = NotificationCenter.default
        func watch(_ name: Notification.Name, _ body: @escaping (EditorSession) -> Void) -> NSObjectProtocol {
            nc.addObserver(forName: name, object: um, queue: nil) { [weak self] _ in
                if let self { body(self) }
            }
        }
        authorshipUndo.observers = [
            watch(.NSUndoManagerDidOpenUndoGroup) { $0.authorshipUndo.groupSerial += 1 },
            watch(.NSUndoManagerWillUndoChange) { $0.authorshipUndo.operationStart = $0.authorship.snapshot(); $0.authorshipUndo.pendingRestore = nil },
            watch(.NSUndoManagerWillRedoChange) { $0.authorshipUndo.operationStart = $0.authorship.snapshot(); $0.authorshipUndo.pendingRestore = nil },
            watch(.NSUndoManagerDidUndoChange) { $0.finishUndoOperation() },
            watch(.NSUndoManagerDidRedoChange) { $0.finishUndoOperation() },
        ]
    }

    // MARK: keep or discard

    /// A file whose marks may be misplaced was just loaded: nothing can be edited until the
    /// user has chosen (the spec: "before continuing editing the file").
    func requireAuthorshipDecision(_ status: AnnotationStatus) {
        pendingAuthorshipDecision = status
        textView?.isEditable = false
        onAuthorshipDecisionNeeded?()
    }

    /// Keep: the marks stay as they are, the document is not changed. Discard: they are
    /// dropped and the document becomes edited.
    public func resolveAuthorshipDecision(keep: Bool) {
        guard pendingAuthorshipDecision != nil else { return }
        pendingAuthorshipDecision = nil
        if !keep {
            authorship = Authorship(me: settings.authorName)
            refreshAuthorshipOverlay()
            onAuthorshipDiscarded?()
        }
        textView?.isEditable = true
        onAuthorshipChange?()
    }
}
