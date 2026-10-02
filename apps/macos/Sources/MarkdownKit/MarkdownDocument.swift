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
        didSet { if fileURL != oldValue { session.documentURLChanged() } }
    }

    public override class var autosavesInPlace: Bool { true }
    public override class var autosavesDrafts: Bool { true }
    public override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    public override class var preservesVersions: Bool { true }

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

    public override func makeWindowControllers() {
        session.requestSave = { [weak self] done in self?.saveForAssets(done) ?? done(false) }
        session.onAuthorshipDiscarded = { [weak self] in self?.updateChangeCount(.changeDone) }
        addWindowController(EditorWindowController(document: self))
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

private final class SaveCompletion {
    let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) { self.done = done }
}
