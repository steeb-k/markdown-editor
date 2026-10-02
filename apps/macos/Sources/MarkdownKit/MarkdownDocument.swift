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

    public override class var autosavesInPlace: Bool { true }
    public override class var autosavesDrafts: Bool { true }
    public override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    public override class var preservesVersions: Bool { true }

    public override func makeWindowControllers() {
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
