import AppKit
import MarkdownCore

/// One document's text system and analysis pipeline: storage -> layout manager -> container
/// (all TextKit 1, built explicitly), the coordinator that owns the core `Document` off the
/// main thread, and the styler. It is the storage's delegate: it forwards character edits to
/// the coordinator and applies the resulting spans. Main thread only.
public final class EditorSession: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    public let settings: Settings
    public let storage = NSTextStorage()
    public let layoutManager = EditorLayoutManager()
    public let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    public let coordinator: AnalysisCoordinator
    public let styler: Styler
    public private(set) var appearance: EditorAppearance
    public private(set) weak var textView: EditorTextView?
    /// Loads and caches the images Live mode draws.
    public let imageController = ImageController()
    /// How the text is shown in this window. Set through `setViewMode`.
    public internal(set) var viewMode: ViewMode
    public var onViewModeChange: (() -> Void)?
    /// Whether this window shows the editor, the preview or both. Set through `setLayout`.
    public internal(set) var layout: LayoutMode
    public var onLayoutChange: (() -> Void)?
    /// Whether this window shows the outline column, and how wide it is here. Set through `setOutlineShown`.
    public internal(set) var outlineShown: Bool
    public var outlineWidth: CGFloat
    public var onOutlineVisibilityChange: (() -> Void)?
    /// Whether this window shows the history column instead (the two share the column on the right), and how wide
    /// it is here. Set through `setHistoryShown`.
    public internal(set) var historyShown = false
    public var historyWidth: CGFloat
    public var onHistoryVisibilityChange: (() -> Void)?
    /// The headings as the core last gave them, while the outline is shown, and who hears of a change
    /// (see `EditorSession+Outline`).
    public internal(set) var outlineEntries: [OutlineEntry] = []
    public var onOutline: (([OutlineEntry]) -> Void)?
    var outlineTimer: Timer?
    /// How long after the last analysis the headings are asked for again: a keystroke costs a timer's move, and
    /// the list follows a pause in typing.
    public static let outlineDelay: TimeInterval = 0.25
    /// Told after every edit of the text (a keystroke, a load, an undo): the preview schedules a render.
    public var onTextChange: (() -> Void)?
    /// Told after every edit, for a window in notes mode: the library hears of the new text.
    public var onLibraryTextChange: (() -> Void)?
    /// Told after every edit of the text but not a load: the document schedules its autosave and snapshot.
    public var onDocumentTextChange: (() -> Void)?
    /// Command-click on a wikilink: the window opens the note it names.
    public var onOpenWikilink: ((WikilinkRef) -> Void)?
    /// Command-Option-click on a wikilink: the note it names opens in a window of its own.
    public var onOpenWikilinkInNewWindow: ((WikilinkRef) -> Void)?
    /// The text range the layout manager's live state was last computed for.
    var liveWindow = NSRange(location: 0, length: 0)
    /// The text range focus mode's ranges were last asked for.
    var focusWindow = NSRange(location: 0, length: 0)
    var liveToken = 0
    var livePending = false
    var liveQueries = 0
    /// The room pictures were last laid out for (the window's height caps it).
    var lastImageBudget: ImageController.Budget?
    /// A query for newly visible text is scheduled (see `visibleRangeChanged`).
    var scrollRefreshPending = false

    /// Everything drawn over the stored colours: focus dimming, parts of speech (and, later,
    /// authorship), composed with a fixed precedence. See `OverlayCompositor`.
    public let overlay = OverlayCompositor()
    /// Parts-of-speech highlighting.
    public private(set) lazy var pos = PosHighlighter(session: self)
    /// This window's focus mode and syntax highlighting (the defaults come from `Settings`).
    public internal(set) var focusEnabled: Bool
    public internal(set) var syntaxEnabled: Bool
    public var onFocusToolsChange: (() -> Void)?
    /// The caret moved or the text changed (the selection changed): focus mode's centring follows.
    public var onCaretActivity: (() -> Void)?
    /// Concealment or the focus range was applied (the lines may have changed height): centring is kept.
    public var onLayoutSettled: (() -> Void)?
    // Authorship (see EditorSession+Authorship.swift).
    /// Which author each character belongs to. Main thread only, next to the text: undo has to
    /// be synchronous, which is why it is not part of the analysis queue's `Document`.
    public internal(set) var authorship: Authorship
    /// Whether borrowed text is coloured in this window (a view toggle: no data changes).
    public internal(set) var authorshipDisplay: Bool
    public var onAuthorshipChange: (() -> Void)?
    /// What the next text edit is, for attributing it (see `EditOrigin`).
    var editOrigin: EditOrigin = .typed
    var isLoading = false
    var authorshipUndo = AuthorshipUndoState()
    /// The edits the text view last announced (`shouldChangeText`): exact, unlike the storage's
    /// edited range. One for an ordinary edit, several when it announced several ranges at once
    /// (Replace All, a drag that moves text). Consumed by the storage edits that make them.
    var pendingEdits: [(range: NSRange, length: Int)] = []
    /// A file whose marks might be misplaced: editing waits for Keep or Discard.
    public internal(set) var pendingAuthorshipDecision: AnnotationStatus?
    public var onAuthorshipDecisionNeeded: (() -> Void)?
    /// Told when Discard changed the document (it becomes edited).
    public var onAuthorshipDiscarded: (() -> Void)?
    /// Instrumentation: queries to the analysis queue made for the selection (see `refreshState`).
    var stateQueries = 0
    /// Selection queries asked asynchronously whose answer has not been applied yet.
    var stateQueriesInFlight = 0
    /// Nothing about the selection is still to come: no query in flight or scheduled.
    var selectionStateSettled: Bool { stateQueriesInFlight == 0 && !livePending && !scrollRefreshPending }
    /// Instrumentation: main-thread time spent asking and applying (seconds).
    var timeInStateQueries: TimeInterval = 0
    /// The scope and classes the overlay was last told about (to notice a change in `Settings`).
    var appliedFocusScope: FocusScopeChoice
    var appliedSyntaxClasses: Set<SyntaxClass>

    /// The format state at the selection, refreshed off the main thread on every selection change.
    public private(set) var formatState: FormatState = EditorSession.emptyFormatState
    public private(set) var activeTable: NSRange?
    public var onFormatStateChange: (() -> Void)?
    public var onStyled: (() -> Void)?
    public var onAppearanceChange: (() -> Void)?

    /// Set by the text view: the character range on screen (styled first), and whether an IME
    /// is composing (restyling would erase its marks).
    public var visibleRange: () -> NSRange = { NSRange(location: 0, length: 0) }
    public var isComposing: () -> Bool = { false }
    public var forcedAppearance: NSAppearance?
    /// The saved file's URL, for paths relative to the document.
    public var documentURL: () -> URL? = { nil }
    /// Asks the document to be saved (an untitled one shows the save panel) and reports whether
    /// it now has a file; used before writing pasted images next to it.
    public var requestSave: ((@escaping (Bool) -> Void) -> Void)?

    public static let chunkSize = 12_000
    public static let emptyFormatState = FormatState(
        strong: false, emphasis: false, strikethrough: false, inlineCode: false, link: false,
        headingLevel: 0, inQuote: false, list: .none, inCodeBlock: false, inTable: false)

    private var log: [(seq: Int, change: TextChange)] = []
    private var debt = RangeSet()
    private var debtInFlight = false
    private var inDelegate = false
    private var isStyling = false
    var isApplyingEdit = false
    var selectionToken = 0
    /// The table holding the caret has been edited (not just visited) since the caret entered it.
    public private(set) var activeTableEdited = false
    var lastUserEdit: NSRange?
    private var isRealigning = false
    /// Tests: a table left after an edit is aligned when `flushHeldRealigns()` says, not on its
    /// own a moment later (a random walk needs to know which undo step is whose).
    var holdsRealigns = false
    private var heldRealigns: [NSRange] = []

    func flushHeldRealigns() {
        let held = heldRealigns
        heldRealigns = []
        for t in held { realign(t, token: selectionToken) }
    }
    private var observers: [NSObjectProtocol] = []

    public init(settings: Settings = .shared, forcedAppearance: NSAppearance? = nil) {
        self.settings = settings
        self.forcedAppearance = forcedAppearance
        coordinator = AnalysisCoordinator()
        appearance = EditorAppearance(settings: settings, appearance: forcedAppearance)
        styler = Styler(appearance: appearance)
        viewMode = settings.defaultViewMode
        layout = settings.defaultLayout
        outlineShown = settings.showOutlineInNewWindows
        outlineWidth = CGFloat(settings.outlineWidth)
        historyWidth = CGFloat(settings.historyWidth)
        focusEnabled = settings.focusMode
        syntaxEnabled = settings.syntaxHighlight
        authorship = Authorship(me: settings.authorName)
        authorshipDisplay = settings.authorshipDisplay
        appliedFocusScope = settings.focusScope
        appliedSyntaxClasses = settings.syntaxClasses
        styler.liveMode = viewMode == .live
        super.init()
        configureLive()
        configureOverlay()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        storage.delegate = self
        coordinator.onResult = { [weak self] in self?.handle($0) }
        observers.append(NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification, object: settings, queue: .main
        ) { [weak self] _ in self?.settingsChanged() })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        authorshipUndo.observers.forEach(NotificationCenter.default.removeObserver)
        // AppKit can keep a closed window's text view alive for a while; it must not call back
        // into a session that is gone (the delegate reference is unowned).
        textView?.delegate = nil
    }

    // MARK: text view

    public func makeTextView() -> EditorTextView {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        tv.session = self
        tv.delegate = self
        // TextKit 1 ownership runs storage -> layout manager -> container; the view only points
        // back. If AppKit holds on to the view after the session is gone, the view must still
        // have a whole text system, so it keeps the storage alive too.
        tv.textSystem = storage
        tv.isEditable = pendingAuthorshipDecision == nil
        textView = tv
        visibleRange = { [weak tv] in tv?.visibleCharacterRange() ?? NSRange(location: 0, length: 0) }
        isComposing = { [weak tv] in tv?.hasMarkedText() ?? false }
        tv.configure(appearance: appearance, settings: settings)
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification, object: tv)
        if syntaxEnabled { pos.configure(enabled: true, classes: settings.syntaxClasses) }
        return tv
    }

    /// Replaces the whole text (document load, revert). Not undoable; the coordinator learns
    /// of it as an ordinary edit and styling is owed for the whole text.
    public func load(_ text: String, authorship loaded: Authorship? = nil) {
        let attributed = NSAttributedString(string: text, attributes: appearance.baseAttributes())
        isLoading = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: attributed)
        isLoading = false
        textView?.undoManager?.removeAllActions()
        authorshipUndo.reset()
        authorship = loaded ?? Authorship(me: settings.authorName)
        pendingAuthorshipDecision = nil
        textView?.isEditable = true
        activeTable = nil
        formatState = Self.emptyFormatState
        liveWindow = NSRange(location: 0, length: 0)
        layoutManager.setLive(LiveState())
        overlay.reset()
        refreshAuthorshipOverlay()
        overlay.apply()
        if syntaxEnabled { pos.reset() }
        if focusEnabled { refreshState() }
    }

    public var text: String { storage.string }

    // MARK: storage delegate

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        phase("storageDelegate") { processedEditing(editedMask, range: editedRange, changeInLength: delta) }
    }

    private func processedEditing(_ editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        // Attribute-only edits (the styler's own, find highlights...) never reach the core.
        guard editedMask.contains(.editedCharacters), !isStyling else { return }
        let change = TextChange(old: NSRange(location: editedRange.location, length: editedRange.length - delta),
                                newLength: editedRange.length)
        let replacement = storage.mutableString.substring(with: editedRange)
        debt.shift(through: change)
        debt.clamp(toLength: storage.length)
        layoutManager.shiftLive(through: change)
        overlay.noteEdit(change)
        if syntaxEnabled { pos.noteEdit(change) }
        liveWindow = RangeMath.shift(liveWindow, through: change)
        focusWindow = RangeMath.shift(focusWindow, through: change)
        if let t = activeTable { activeTable = RangeMath.shift(t, through: change) }
        // What counts as editing a table (so leaving it realigns): typing and commands, not undo
        // or redo (undoing a realign must not bring it straight back) and not the realign itself.
        let um = textView?.undoManager
        if !isRealigning, um?.isUndoing != true, um?.isRedoing != true {
            let edited = NSRange(location: change.old.location, length: change.newLength)
            lastUserEdit = edited
            if let t = activeTable, touches(t, edited) { activeTableEdited = true }
        } else if let e = lastUserEdit {
            lastUserEdit = RangeMath.shift(e, through: change)
        }
        if !isLoading { trackAuthorship(change, replacement: replacement) }
        let seq = coordinator.submit(range: change.old, replacement: replacement)
        log.append((seq, change))
        inDelegate = true
        coordinator.waitForResult(seq: seq)
        inDelegate = false
        onTextChange?()
        if !isLoading {
            onLibraryTextChange?()
            onDocumentTextChange?()
        }
    }

    // MARK: results

    private func handle(_ result: AnalysisResult) {
        var range = result.range
        for e in log where e.seq > result.seq { range = RangeMath.shift(range, through: e.change) }
        log.removeAll { $0.seq <= result.seq }
        if outlineShown { scheduleOutline() }
        if result.seq == coordinator.latestSeq {
            if let spans = result.spans, !isComposing() {
                apply(spans, prose: result.prose, code: result, in: result.range, afterEdit: true)
                debt.subtract(result.range)
            } else {
                debt.add(result.range)
            }
        } else {
            debt.add(range) // stale: never applied; owed to the next styling
        }
        scheduleDebt()
    }

    /// Instrumentation: main-thread seconds per named phase of a keystroke (the UI harness).
    public var phaseTimes: [String: TimeInterval] = [:]
    @inline(__always)
    func phase<R>(_ name: String, _ body: () -> R) -> R {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { phaseTimes[name, default: 0] += CFAbsoluteTimeGetCurrent() - t0 }
        return body()
    }

    /// Instrumentation: main-thread time spent applying styles so far.
    public private(set) var totalStyleTime: TimeInterval = 0
    public private(set) var longestStyle: TimeInterval = 0

    /// `afterEdit`: the result of an edit (the text changed, so Live mode asks again what to
    /// conceal). Styling owed for unchanged text (a theme change, the initial pass, a mode
    /// switch) changes no concealment and asks nothing.
    private func apply(_ spans: [Span], prose: [Utf16Range], code: AnalysisResult, in range: NSRange, afterEdit: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer {
            let d = CFAbsoluteTimeGetCurrent() - t0
            totalStyleTime += d
            longestStyle = max(longestStyle, d)
        }
        isStyling = true
        styler.style(storage, range: range, spans: spans, prose: prose.map(\.nsRange),
                     languages: code.languages, insideProcessing: inDelegate)
        isStyling = false
        // The colour roles of code go to the overlay (painted for what is visible, scrolling brings the rest from
        // this layer at once); in the keystroke's own pass `didChangeText` applies it before anything is drawn.
        let window = RangeMath.clamp(range, toLength: storage.length)
        overlay.patchCode(code.highlights.map { OverlayRun($0.range.nsRange, .code($0.role)) }, in: window)
        if !inDelegate { overlay.apply() }
        textView?.refreshTypingAttributes()
        if viewMode == .live, afterEdit {
            if inDelegate { scheduleLiveRefresh() } else { refreshLive() }
        }
        onStyled?()
    }

    private func scheduleDebt() {
        if inDelegate { DispatchQueue.main.async { [weak self] in self?.kickDebt() } } else { kickDebt() }
    }

    /// Styles the next chunk of what is owed: the visible part first, then the rest. Runs only
    /// while the queue is idle and nothing is composing; each chunk is its own run-loop turn.
    public func kickDebt() {
        guard !debt.isEmpty, !debtInFlight, coordinator.isIdle, !isComposing() else { return }
        debt.clamp(toLength: storage.length)
        guard let first = debt.ranges.first else { return }
        var chunk = debt.intersection(with: visibleRange()).first ?? first
        if chunk.length > Self.chunkSize { chunk.length = Self.chunkSize }
        debtInFlight = true
        coordinator.spans(in: chunk) { [weak self] result in
            guard let self else { return }
            debtInFlight = false
            if result.seq == coordinator.latestSeq, !isComposing(), let spans = result.spans {
                apply(spans, prose: result.prose, code: result, in: RangeMath.clamp(result.range, toLength: storage.length), afterEdit: false)
                debt.subtract(result.range)
            }
            DispatchQueue.main.async { [weak self] in self?.kickDebt() }
        }
    }

    /// True when no styling is owed or in flight.
    /// (A result that arrived after the last delivery is still owed: the queue turns idle the
    /// moment it posts its last result, which `waitUntilStyled` could see between delivering and
    /// asking, and so return with that edit unstyled; a full test run caught it about one time in six.)
    public var isStyled: Bool { debt.isEmpty && !debtInFlight && coordinator.isIdle && !coordinator.hasUndelivered }
    public var owedStyling: [NSRange] { debt.ranges }

    /// Spins the run loop until styling has caught up (tests, and the launch screenshot).
    @discardableResult
    public func waitUntilStyled(timeout: TimeInterval = 20) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            coordinator.deliverPending()
            if isStyled { return true }
            kickDebt()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return isStyled
    }

    // MARK: appearance

    /// Styling is owed for the whole text again (the mode or the theme changed what the styler writes).
    func restyleEverything() {
        debt.add(NSRange(location: 0, length: storage.length))
        kickDebt()
    }

    private func settingsChanged() {
        let new = EditorAppearance(settings: settings, appearance: currentSystemAppearance())
        applyAppearance(new)
        applyFocusToolSettings()
        authorship.setMeName(name: settings.authorName)
    }

    /// Re-reads settings and the effective appearance (System theme follows the OS live).
    public func refreshAppearance() {
        applyAppearance(EditorAppearance(settings: settings, appearance: currentSystemAppearance()))
    }

    func currentSystemAppearance() -> NSAppearance? {
        forcedAppearance ?? textView?.effectiveAppearance
    }

    private func applyAppearance(_ new: EditorAppearance) {
        let changed = new.theme.id != appearance.theme.id || new.fonts.body != appearance.fonts.body
            || new.fonts.mono != appearance.fonts.mono || new.maxCharacters != appearance.maxCharacters
            || new.choice != appearance.choice
        appearance = new
        styler.appearance = new
        layoutManager.palette = new.palette
        layoutManager.bodyFont = new.fonts.body
        overlay.palette = new.palette
        textView?.configure(appearance: new, settings: settings)
        if changed {
            debt.add(NSRange(location: 0, length: storage.length))
            kickDebt()
        }
        onAppearanceChange?()
    }

    // MARK: selection

    @objc private func selectionChanged(_ note: Notification) {
        guard let tv = textView, !isApplyingEdit else { return }
        phase("selectionChanged") { selectionChanged(in: tv) }
    }

    func selectionChanged(in tv: EditorTextView) {
        selectionToken += 1
        let token = selectionToken
        onCaretActivity?()
        tv.refreshTypingAttributes()
        tv.codeBadgeCaretMoved()
        let selection = tv.selectedRange()
        // The table the caret has just left (the answer below replaces it).
        if let table = activeTable, !tableContains(table, selection), canRealign(tv) {
            activeTable = nil
            if activeTableEdited {
                if holdsRealigns { heldRealigns.append(table) } else { realign(table, token: token) }
            }
            activeTableEdited = false
        }
        // One round trip to the analysis queue: concealment (Live), focus range (focus mode), format
        // state and table. Answered on the spot when the queue is idle.
        refreshState(selectionChange: true)
    }

    /// What the selection query said about the format state and the table.
    func applyFormatState(_ state: SelectionState) {
        formatState = state.formatState
        let table = state.table?.nsRange
        if table != activeTable {
            // A table just entered counts as edited if the last edit (typed before the
            // query came back) was in it.
            activeTableEdited = table.map { t in self.lastUserEdit.map { self.touches(t, $0) } ?? false } ?? false
        }
        activeTable = table
        onFormatStateChange?()
    }

    private func touches(_ a: NSRange, _ b: NSRange) -> Bool {
        b.location <= NSMaxRange(a) && NSMaxRange(b) >= a.location
    }

    private func tableContains(_ t: NSRange, _ sel: NSRange) -> Bool {
        sel.location >= t.location && NSMaxRange(sel) <= NSMaxRange(t)
    }

    private func canRealign(_ tv: EditorTextView) -> Bool {
        if tv.hasMarkedText() { return false }
        if let um = tv.undoManager, um.isUndoing || um.isRedoing { return false }
        if NSEvent.pressedMouseButtons != 0 { return false }
        return true
    }

    /// The caret left `table`: pad it, as its own undo step, without moving the caret.
    private func realign(_ table: NSRange, token: Int) {
        let at = UInt32(table.location)
        coordinator.async({ doc in
            doc.tableCommand(command: .realign, selection: Utf16Range(start: at, end: at))
        }) { [weak self] edit, processed in
            guard let self, let tv = textView, processed == coordinator.latestSeq,
                  let edit, canRealign(tv) else { return }
            let range = NSRange(location: Int(edit.range.start), length: Int(edit.range.end - edit.range.start))
            guard range.length > 0 || !edit.replacement.isEmpty else { return }
            let change = TextChange(old: range, newLength: (edit.replacement as NSString).length)
            let sel = tv.selectedRange()
            let a = RangeMath.shiftPoint(sel.location, through: change)
            let b = RangeMath.shiftPoint(NSMaxRange(sel), through: change)
            tv.undoManager?.beginUndoGrouping()
            tv.breakUndoCoalescing()
            isApplyingEdit = true
            isRealigning = true
            _ = tv.replaceThroughUndo(range: range, with: edit.replacement)
            tv.setSelectedRange(NSRange(location: a, length: b - a))
            isRealigning = false
            isApplyingEdit = false
            lastUserEdit = nil
            tv.breakUndoCoalescing()
            tv.undoManager?.setActionName("Align Table")
            tv.undoManager?.endUndoGrouping()
            selectionChanged(in: tv)
        }
    }
}

extension EditorSession {
    // MARK: spell checking

    /// Spelling marks only on the core's prose ranges: never in code, URLs, markup or front
    /// matter (the styler tags prose with `.markdownProse`).
    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        value == 0 || allowsSpellChecking(in: affectedCharRange) ? value : 0
    }

    public func allowsSpellChecking(in r: NSRange) -> Bool {
        guard r.length > 0, NSMaxRange(r) <= storage.length else { return false }
        var all = true
        storage.enumerateAttribute(.markdownProse, in: r, options: []) { v, _, stop in
            if v == nil { all = false; stop.pointee = true }
        }
        return all
    }
}

extension Utf16Range {
    var nsRange: NSRange { NSRange(location: Int(start), length: Int(end - start)) }
}

extension TableInfo {
    var nsRange: NSRange { NSRange(location: Int(range.start), length: Int(range.end - range.start)) }
}
