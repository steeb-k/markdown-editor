import AppKit
import MarkdownCore

public final class MarkdownDocument: NSDocument {
    public let session: EditorSession
    public private(set) var hasBOM = false
    public private(set) var lineEnding: LineEnding = .lf
    /// File > Print is loading the page or showing its panel (a second Print waits for it).
    var isPreparingPrint = false
    /// The print operation File > Print last ran (tests end its panel).
    weak var lastPrintOperation: NSPrintOperation?
    /// A document the app made for itself (Help): never opened in notes mode, never drafted or snapshotted.
    var isBundled = false
    /// The workspace the window this document is about to get adopts (a note opened from a window's sidebar), in
    /// place of starting a workspace of its own.
    var inheritedWorkspace: Workspace?
    /// The text as it was read: the first snapshot of a document's history in this session, so that what the first
    /// edit changed can be seen and got back.
    var openedText: String?
    var baselineRecorded = false
    /// Autosave (see `MarkdownDocument+Autosave`): the timer that writes 2 s after the last edit, and the saves in flight.
    var autosaveTimer: Timer?
    var savesInFlight = 0
    /// Why the next write's snapshot is taken, when not the usual (a draft).
    var nextSnapshotReason: HistoryReason?
    /// How long after the last edit the document is written and a snapshot taken.
    nonisolated(unsafe) public static var autosaveDelay: TimeInterval = 2
    /// The longest a stream of edits goes unwritten (NSDocument's own timer, from the first edit).
    nonisolated(unsafe) public static var autosaveCeiling: TimeInterval = 15

    public override init() {
        session = EditorSession(settings: .shared)
        super.init()
        configurePrintInfo()
    }

    public init(settings: Settings) {
        session = EditorSession(settings: settings)
        super.init()
        configurePrintInfo()
    }

    public override var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            session.documentURLChanged()
            if let old = oldValue, let new = fileURL { renamedHistory(from: old, to: new) }
            (windowControllers.first as? EditorWindowController)?.documentKeyChanged()
        }
    }

    /// A titled document is written as it is typed (see `MarkdownDocument+Autosave`); the file is the one place the
    /// text lives and the history is the app's own, so the system's Versions have nothing left to do.
    public override class var autosavesInPlace: Bool { true }
    public override class var autosavesDrafts: Bool { true }
    public override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    public override class var preservesVersions: Bool { false }

    /// Saves an untitled document (the standard save panel) so files can be written beside it.
    /// `done` is told whether the document has a file afterwards.
    func saveForAssets(_ done: @escaping (Bool) -> Void) {
        if fileURL != nil { done(true); return }
        let box = SaveCompletion(done)
        save(withDelegate: self, didSave: #selector(document(_:didSave:contextInfo:)),
             contextInfo: Unmanaged.passRetained(box).toOpaque())
    }

    @objc private func document(_ doc: NSDocument, didSave ok: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        let box = Unmanaged<SaveCompletion>.fromOpaque(contextInfo).takeRetainedValue()
        box.done(ok && fileURL != nil)
    }

    public override func close() {
        cancelAutosave()
        super.close()
    }

    public override func makeWindowControllers() {
        session.requestSave = { [weak self] done in self?.saveForAssets(done) ?? done(false) }
        session.onAuthorshipDiscarded = { [weak self] in self?.updateChangeCount(.changeDone) }
        session.onDocumentTextChange = { [weak self] in self?.textChanged() }
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
        // A note opened from a window's sidebar starts with its workspace. Otherwise new windows start in notes mode
        // when the setting says so (the library is the app's: the sidebar is drawn from the same index as every
        // other window's).
        if let ws = inheritedWorkspace {
            inheritedWorkspace = nil
            controller.adopt(ws)
        } else if session.settings.notesModeByDefault, !isBundled {
            controller.startNotesMode()
        }
    }

    // MARK: reading and writing (all file access through DocumentFileAccess)

    public override func read(from url: URL, ofType typeName: String) throws {
        try read(from: DocumentFileAccess.read(url), ofType: typeName)
    }

    public override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try TextCodec.decode(data)
        hasBOM = decoded.hasBOM
        lineEnding = decoded.lineEnding
        // The annotation block (authorship) is split off here: the editor never shows it and
        // it is not part of the text the core analyses. The core decides what is a block.
        let split = splitAnnotations(fileText: decoded.raw)
        let body = split.annotations == nil ? decoded.text : TextCodec.normalize(split.body, decoded.lineEnding)
        let authorship: Authorship
        if let annotations = split.annotations {
            authorship = Authorship.fromAnnotations(body: body, annotations: annotations, me: session.settings.authorName)
        } else {
            authorship = Authorship(me: session.settings.authorName)
        }
        // Remembered so that a file nobody changed is written back byte for byte.
        authorship.setOrigin(body: body, rawTail: split.rawTail ?? "", ending: decoded.lineEnding.annotationEnding)
        session.load(body, authorship: authorship)
        // The text as first read is the baseline; a re-read (another app's change) keeps it.
        if openedText == nil {
            openedText = body
            baselineRecorded = false
        }
        undoManager?.removeAllActions()
        switch split.status {
        case .hashMismatch, .malformed: session.requireAuthorshipDecision(split.status)
        case .absent, .valid: break
        }
    }

    /// What a save writes: the text and a copy of the attribution, taken together.
    struct SaveSnapshot {
        let text: String
        let authorship: Authorship
        let hasBOM: Bool
        let lineEnding: LineEnding

        /// The file's bytes: the text, then the annotation block when some text belongs to
        /// someone other than the user (or the original block, if neither the text nor the
        /// marks changed). The block's hash is the expensive part (tens of milliseconds at 1 MB).
        func encoded() -> Data {
            var data = TextCodec.encode(text, hasBOM: hasBOM, lineEnding: lineEnding)
            let tail = authorship.fileTail(text: text, ending: lineEnding.annotationEnding)
            if !tail.isEmpty { data.append(Data(tail.utf8)) }
            return data
        }
    }

    /// Instrumentation (tests): the thread each write ran on.
    var writesOnMainThread: [Bool] = []

    func saveSnapshot() -> SaveSnapshot {
        SaveSnapshot(text: session.text, authorship: session.authorship.copy(), hasBOM: hasBOM, lineEnding: lineEnding)
    }

    public override func data(ofType typeName: String) throws -> Data {
        saveSnapshot().encoded()
    }

    /// Saves are written off the main thread: the text and the attribution are copied while
    /// NSDocument holds the main thread, then the user can type again while the block is hashed
    /// and the file written.
    public override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                                for saveOperation: NSDocument.SaveOperationType) -> Bool {
        true
    }

    public override func write(to url: URL, ofType typeName: String) throws {
        // On a background thread during an asynchronous save, with the main thread waiting for
        // `unblockUserInteraction` (nothing can change the text meanwhile); on the main thread
        // otherwise.
        let snapshot = saveSnapshot()
        writesOnMainThread.append(Thread.isMainThread)
        if !Thread.isMainThread { unblockUserInteraction() }
        try DocumentFileAccess.write(snapshot.encoded(), to: url)
    }
}

/// Answers NSDocument's own question on closing (`MarkdownDocument.askStandard`).
private final class CloseAsker: NSObject {
    let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) { self.done = done }
    /// The context is this object, retained for the asking; it is let go of here.
    @objc func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        done(shouldClose)
        if let contextInfo { Unmanaged<CloseAsker>.fromOpaque(contextInfo).release() }
    }
}

extension MarkdownDocument {
    /// NSDocument's own question ("Do you want to save the changes?") for what the app cannot save by itself: an
    /// untitled document with text and no library to draft it in. `done` is told whether the window may close.
    func askStandard(_ done: @escaping (Bool) -> Void) {
        let asker = CloseAsker(done)
        super.canClose(withDelegate: asker, shouldClose: #selector(CloseAsker.document(_:shouldClose:contextInfo:)),
                       contextInfo: Unmanaged.passRetained(asker).toOpaque())
    }
}

private final class SaveCompletion {
    let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) { self.done = done }
}
