import AppKit

public final class MarkdownDocument: NSDocument {
    public let session: EditorSession
    public private(set) var hasBOM = false
    public private(set) var lineEnding: LineEnding = .lf

    public override init() {
        session = EditorSession(settings: .shared)
        super.init()
    }

    public init(settings: Settings) {
        session = EditorSession(settings: settings)
        super.init()
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
        session.load(decoded.text)
        undoManager?.removeAllActions()
    }

    public override func data(ofType typeName: String) throws -> Data {
        TextCodec.encode(session.text, hasBOM: hasBOM, lineEnding: lineEnding)
    }

    public override func write(to url: URL, ofType typeName: String) throws {
        try DocumentFileAccess.write(data(ofType: typeName), to: url)
    }
}

private final class SaveCompletion {
    let done: (Bool) -> Void
    init(_ done: @escaping (Bool) -> Void) { self.done = done }
}
