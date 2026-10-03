import AppKit
import MarkdownCore

/// The editing surface: plain text as far as the user is concerned, styled source on screen.
/// Return, Tab and Shift-Tab go to the core first; every core edit is applied through the
/// normal text-view editing path so undo and redo keep working.
public final class EditorTextView: NSTextView {
    weak var session: EditorSession?
    /// Keeps the text system (storage, layout manager, container) alive as long as the view.
    var textSystem: NSTextStorage?
    /// The document's undo manager (so edits mark the document changed and undo is shared).
    /// Weak: the undo stack's text operations refer back to this view, and a strong reference
    /// here kept the window and the text view alive after the document closed.
    public weak var documentUndoManager: UndoManager?
    /// Called when the user starts typing (not for shortcuts or navigation): chrome fades out.
    public var onTyping: (() -> Void)?
    /// Where copy, cut and paste go. The general pasteboard, except in tests and UI scripts.
    public var pasteboard: NSPasteboard = .general
    /// The key binding command being performed (`moveLeft:`...), while it runs.
    public internal(set) var currentCommand: Selector?
    /// The selection Live mode last extended from the keyboard, and its anchor.
    var liveAnchor: (selection: NSRange, anchor: Int)?
    /// Up and Down through pictures in Live mode (see `moveVerticallyThroughPictures`): the column
    /// the run of presses keeps, the caret it left, and whether it has placed the caret itself
    /// (AppKit's own memory of the column is lost once the selection is set by hand).
    var verticalGoal: (selection: NSRange, x: CGFloat, placed: Bool)?
    /// The pointing hand is showing for a Command-hover over a link.
    var showsLinkCursor = false
    /// Focus mode's centring; while it is on, what asks the view to scroll something into view
    /// asks it to centre that instead (one slide, not a jump and a slide).
    weak var centring: FocusCentring?

    ///
    /// Only for the selection, though (the caret, a found match, a revealed element). AppKit itself
    /// calls this with whatever is on screen when the text view changes size (the layout manager
    /// keeps that text in view while the window resizes or concealment changes line heights): that
    /// is not a line to centre, and taking it for the user's caret move centred the wrong text.
    public override func scrollRangeToVisible(_ range: NSRange) {
        let selection = selectedRange()
        if let centring, centring.isActive, range == selection {
            centring.request(range)
        } else if let centring, centring.isActive, Self.touches(range, selection) {
            // Text around the caret (the visible text AppKit keeps in view): the caret's line stays
            // in the middle; a scroll of the user's own is not undone for it.
            centring.request(selection, user: false)
        } else {
            super.scrollRangeToVisible(range)
        }
    }

    /// The two ranges overlap or meet (a caret at either end of a range touches it).
    static func touches(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location <= NSMaxRange(b) && b.location <= NSMaxRange(a)
    }

    public override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }

    // MARK: setup

    func configure(appearance a: EditorAppearance, settings: Settings) {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = settings.spellCheck
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true

        drawsBackground = true
        backgroundColor = a.palette.background
        insertionPointColor = a.palette.caret
        selectedTextAttributes = [.backgroundColor: a.palette.selection]
        enclosingScrollView?.backgroundColor = a.palette.background
        enclosingScrollView?.drawsBackground = true
        updateColumnGeometry()
        refreshTypingAttributes()
        needsDisplay = true
    }

    /// Centered column: a maximum measure, the rest is margin; recomputed on resize and on
    /// font change.
    func updateColumnGeometry() {
        guard let a = session?.appearance else { return }
        let side = max(EditorAppearance.minimumSideMargin, ((bounds.width - a.measure) / 2).rounded(.down))
        let inset = NSSize(width: side, height: EditorAppearance.topInset)
        if textContainerInset != inset { textContainerInset = inset }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateColumnGeometry()
    }

    /// AppKit scrolls to what it kept in view as a live resize ends; focus mode's centring puts the
    /// caret's line back in the middle before the window draws again.
    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        centring?.liveResizeEnded()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        session?.refreshAppearance()
    }

    /// Typed text must not inherit stale attributes (a heading's size after Return): take the
    /// face from the character before the caret on the same line, else the body style.
    func refreshTypingAttributes() {
        guard let session else { return }
        let base = session.appearance.baseAttributes()
        var attrs = base
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0, sel.location <= session.storage.length {
            let ns = session.storage.mutableString
            let prev = ns.character(at: sel.location - 1)
            if prev != 0x0A && prev != 0x0D {
                let at = session.storage.attributes(at: sel.location - 1, effectiveRange: nil)
                for k in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
                    if let v = at[k] { attrs[k] = v }
                }
            }
        }
        typingAttributes = attrs
    }

    /// Code block panels go between the view's background and the text.
    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager as? EditorLayoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let local = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -EditorLayoutManager.blockOutset.height)
        let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: local, in: tc)
        lm.drawBlockBackgrounds(forGlyphRange: glyphs, at: origin)
        // Live mode's decorations are drawn by the layout manager, after the selection highlight
        // (which would cover a selected line's bullet or checkbox), before the glyphs.
    }

    func visibleCharacterRange() -> NSRange {
        guard let lm = layoutManager, let tc = textContainer else { return NSRange(location: 0, length: 0) }
        let g = lm.glyphRange(forBoundingRect: visibleRect, in: tc)
        return lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
    }

    /// Remembers the exact edit for attribution (the storage's edited range can be wider).
    public override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        // An edit that starts an undo step (not one the text system folds into the typing it
        // is coalescing) registers the attribution before it, *before* the text system registers
        // its own action: anything registered after the text system's would stop it coalescing.
        let changesSomething = affectedRanges.contains { $0.rangeValue.length > 0 } || (replacementStrings ?? []).contains { !$0.isEmpty }
        let undoing = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        // Several ranges at once (the find bar's Replace All, a drag that moves text) are never
        // part of the typing being coalesced: the text system registers them as an undo step of
        // their own, so the attribution before them needs one too.
        if changesSomething, affectedRanges.count > 1, !undoing { breakUndoCoalescing() }
        if changesSomething, !isCoalescingUndo, !undoing {
            session?.registerAuthorshipUndo()
        }
        let ok = session?.phase("shouldChangeSuper") { super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) }
            ?? super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if ok, let strings = replacementStrings, strings.count == affectedRanges.count, !affectedRanges.isEmpty {
            session?.pendingEdits = zip(affectedRanges, strings).map { ($0.rangeValue, ($1 as NSString).length) }
        } else {
            session?.pendingEdits = []
        }
        return ok
    }

    // MARK: plain text only

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    public override func pasteAsRichText(_ sender: Any?) { pasteAsPlainText(sender) }
    public override func changeFont(_ sender: Any?) {}
    public override func changeAttributes(_ sender: Any?) {}
    public override func changeColor(_ sender: Any?) {}
    public override func changeDocumentBackgroundColor(_ sender: Any?) {}

    public override func unmarkText() {
        super.unmarkText()
        session?.overlay.apply()
        session?.kickDebt()
        session?.refreshLive()
    }

    public override func didChangeText() {
        if let session { session.phase("didChangeSuper") { super.didChangeText() } } else { super.didChangeText() }
        // The overlay moved with the text; what was typed gets its colour before it is drawn.
        session?.overlay.apply()
        if !hasMarkedText() {
            session?.kickDebt()
            session?.refreshLive()
        }
    }

    public override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        session?.settings.spellCheck = isContinuousSpellCheckingEnabled
    }

    // MARK: keys

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control])
        if flags.isEmpty, let c = event.charactersIgnoringModifiers?.unicodeScalars.first,
           !(0xF700...0xF8FF).contains(c.value), c.value != 0x1B {
            onTyping?()
        }
        if let session { session.phase("keyDown") { super.keyDown(with: event) } } else { super.keyDown(with: event) }
    }

    public override func doCommand(by selector: Selector) {
        // Live mode's caret rules depend on what kind of move asked for a new selection.
        let previous = currentCommand
        currentCommand = selector
        defer { currentCommand = previous }
        if session != nil, !hasMarkedText(), handleLiveCommand(selector) { return }
        if session != nil, !hasMarkedText() {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if perform({ $0.newline(selection: $1) }) { return }
            case #selector(NSResponder.insertTab(_:)):
                if handleTab(outdent: false) { return }
            case #selector(NSResponder.insertBacktab(_:)):
                if handleTab(outdent: true) { return }
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                if moveVerticallyThroughPictures(selector) { return }
            default: break
            }
        }
        super.doCommand(by: selector)
    }

    /// Tab and Shift-Tab: next/previous cell in a table, else indent/outdent a list item.
    @discardableResult
    public func handleTab(outdent: Bool) -> Bool {
        perform { doc, sel in
            if doc.tableAt(offset: sel.start) != nil {
                return doc.tableCommand(command: outdent ? .previousCell : .nextCell, selection: sel)
            }
            return doc.indent(selection: sel, outdent: outdent)
        }
    }

    // MARK: applying core edits

    /// Asks the core (after letting analysis catch up) for an edit at the selection and applies
    /// it. Returns false when the core has nothing to do (default behavior should follow).
    @discardableResult
    ///
    /// `origin` attributes what the edit inserts (see `EditOrigin`): by default a command's edit,
    /// whose inserted text takes its neighbour's author.
    public func perform(actionName: String? = nil, _ make: @escaping (Document, Utf16Range) -> TextEdit?) -> Bool {
        perform(actionName: actionName, origin: nil, make)
    }

    @discardableResult
    func perform(actionName: String? = nil, origin: EditOrigin?, _ make: @escaping (Document, Utf16Range) -> TextEdit?) -> Bool {
        guard let session, !hasMarkedText(), isEditable else { return false }
        let sel = selectedRange()
        let u = Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel)))
        guard let edit = session.coordinator.sync({ make($0, u) }) else { return false }
        apply(edit, actionName: actionName, origin: origin)
        return true
    }

    public func apply(_ edit: TextEdit, actionName: String? = nil) {
        apply(edit, actionName: actionName, origin: nil)
    }

    func apply(_ edit: TextEdit, actionName: String?, origin: EditOrigin?) {
        guard let session else { return }
        let range = NSRange(location: Int(edit.range.start), length: Int(edit.range.end - edit.range.start))
        let selection = NSRange(location: Int(edit.selection.start), length: Int(edit.selection.end - edit.selection.start))
        guard NSMaxRange(range) <= session.storage.length else { return }
        session.isApplyingEdit = true
        defer {
            session.isApplyingEdit = false
            session.selectionChanged(in: self)
        }
        if !(range.length == 0 && edit.replacement.isEmpty) {
            guard replaceThroughUndo(range: range, with: edit.replacement, origin: origin) else { return }
            if let actionName { undoManager?.setActionName(actionName) }
        }
        if NSMaxRange(selection) <= session.storage.length {
            setSelectedRange(selection)
            scrollRangeToVisible(selection)
        }
    }

    /// The normal editing path: ask permission, change, announce. Registers undo.
    ///
    /// `origin` says who made the edit (see `EditOrigin`); everything that is not the user typing
    /// is a command's edit by default, whose inserted text takes its neighbour's author.
    func replaceThroughUndo(range: NSRange, with replacement: String, origin: EditOrigin? = nil) -> Bool {
        guard shouldChangeText(inRanges: [NSValue(range: range)], replacementStrings: [replacement]) else { return false }
        if let session {
            session.editOrigin = origin ?? .inherit(old: (session.storage.string as NSString).substring(with: range))
        }
        defer { session?.editOrigin = .typed }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        return true
    }
}

extension EditorTextView {
    /// Cursor rects and mouse tracking that Live mode needs (pointing hand over checkboxes).
    func updateTrackingForLive() {
        window?.invalidateCursorRects(for: self)
    }
}
