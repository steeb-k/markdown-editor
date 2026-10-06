import AppKit
import ImageIO
import XCTest
import MarkdownCore
@testable import MarkdownKit

enum TestImages {
    static func png(width: Int, height: Int, color: NSColor = .systemTeal) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

/// Which file a picture's destination names: the one rule the preview, the PDF and the print follow.
final class PictureResolutionTests: XCTestCase {
    private func resolve(_ destination: String, document: URL?) -> URL? {
        guard let url = DocumentFileAccess.pictureURL(for: destination, documentURL: document) else { return nil }
        return url.isFileURL && !DocumentFileAccess.mayRead(url, documentURL: document) ? nil : url
    }

    func testResolvesPathsAndSchemes() {
        let doc = URL(fileURLWithPath: "/docs/sub/note.md")
        XCTAssertEqual(resolve("img/a.png", document: doc)?.path, "/docs/sub/img/a.png")
        XCTAssertEqual(resolve("../a%20b.png", document: doc)?.path, "/docs/a b.png")
        XCTAssertEqual(resolve("/abs/a.png", document: doc)?.path, "/abs/a.png")
        XCTAssertEqual(resolve("file:///x/y.png", document: doc)?.path, "/x/y.png")
        XCTAssertEqual(resolve("https://example.com/a.png", document: doc)?.absoluteString, "https://example.com/a.png")
        XCTAssertNil(resolve("ftp://example.com/a.png", document: doc))
        XCTAssertEqual(resolve("data:image/png;base64,AAAA", document: doc)?.scheme, "data")
        XCTAssertNil(resolve("", document: doc))
        XCTAssertNil(resolve("img/a.png", document: nil), "an untitled document resolves relative paths against nothing")
        XCTAssertEqual(resolve("/abs/a.png", document: nil)?.path, "/abs/a.png")
    }
}

final class DropAndPasteTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = TestImages.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func pasteboard(files: [URL]) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("markdown-drop-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    func testDroppedImageBecomesAnImageWithARelativePath() throws {
        let img = dir.appendingPathComponent("pics/cat photo.png")
        try FileManager.default.createDirectory(at: img.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestImages.png(width: 10, height: 10).write(to: img)
        let e = Editor(text: "Hello world\n")
        e.session.documentURL = { self.dir.appendingPathComponent("note.md") }
        e.um.groupsByEvent = false
        e.grouped { XCTAssertTrue(e.tv.handleDrop(self.pasteboard(files: [img]), at: 5)) }
        XCTAssertEqual(e.string, "Hello![cat photo](<pics/cat photo.png>) world\n", "at the drop location, relative to the document")
        XCTAssertEqual(e.um.undoActionName, "Insert Image")
        e.um.undo()
        XCTAssertEqual(e.string, "Hello world\n")
        XCTAssertFalse(e.um.canUndo, "one undo step")
        XCTAssertEqual(e.session.coordinator.coreText(), e.string)
    }

    func testDroppedImageInUnsavedDocumentUsesAnAbsolutePath() throws {
        let img = dir.appendingPathComponent("a.png")
        try TestImages.png(width: 10, height: 10).write(to: img)
        let e = Editor(text: "x")
        e.grouped { _ = e.tv.handleDrop(self.pasteboard(files: [img]), at: 1) }
        XCTAssertEqual(e.string, "x![a](\(img.path))")
    }

    func testOtherFilesBecomeLinksAndSeveralFilesGetTheirOwnLines() throws {
        let pdf = dir.appendingPathComponent("doc.pdf"), png = dir.appendingPathComponent("p.png")
        try Data("%PDF".utf8).write(to: pdf)
        try TestImages.png(width: 4, height: 4).write(to: png)
        let e = Editor(text: "start\n")
        e.session.documentURL = { self.dir.appendingPathComponent("note.md") }
        e.um.groupsByEvent = false
        e.grouped { XCTAssertTrue(e.tv.handleDrop(self.pasteboard(files: [pdf]), at: 0)) }
        XCTAssertEqual(e.string, "[doc.pdf](doc.pdf)start\n")
        e.grouped { XCTAssertTrue(e.tv.handleDrop(self.pasteboard(files: [png, pdf]), at: (e.string as NSString).length)) }
        XCTAssertEqual(e.string, "[doc.pdf](doc.pdf)start\n![p](p.png)\n\n[doc.pdf](doc.pdf)")
        e.um.undo()
        XCTAssertEqual(e.string, "[doc.pdf](doc.pdf)start\n", "several files are one undo step")
        XCTAssertEqual(e.session.coordinator.coreText(), e.string)
    }

    func testDropWithoutFilesIsNotHandled() {
        let e = Editor(text: "x")
        let pb = NSPasteboard(name: NSPasteboard.Name("markdown-drop-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("just text", forType: .string)
        XCTAssertFalse(e.tv.handleDrop(pb, at: 0))
        XCTAssertEqual(e.string, "x")
    }

    // MARK: pasting image data

    private func imagePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("markdown-paste-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(TestImages.png(width: 32, height: 16), forType: .png)
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    func testPastedImageIsWrittenBesideTheDocumentWithUniqueNames() throws {
        let e = Editor(text: "Paste here: \n")
        let doc = dir.appendingPathComponent("My Note.md")
        e.session.documentURL = { doc }
        e.select(12)
        let pb = imagePasteboard()
        XCTAssertTrue(e.tv.pasteboardHasOnlyImage(pb))
        var ok: Bool?
        e.tv.pasteImage(from: pb) { ok = $0 }
        XCTAssertTrue(spin { ok != nil })
        XCTAssertEqual(ok, true)
        let assets = dir.appendingPathComponent("My Note.assets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("image.png").path))
        XCTAssertEqual(e.string, "Paste here: ![image](<My Note.assets/image.png>)\n")
        let written = try Data(contentsOf: assets.appendingPathComponent("image.png"))
        XCTAssertNotNil(NSBitmapImageRep(data: written), "a real PNG")
        XCTAssertEqual(NSBitmapImageRep(data: written)?.pixelsWide, 32)
        // Pasting again never overwrites.
        ok = nil
        e.tv.pasteImage(from: pb) { ok = $0 }
        XCTAssertTrue(spin { ok != nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent("image 2.png").path))
        XCTAssertTrue(e.string.contains("My Note.assets/image 2.png"))
        XCTAssertEqual(e.session.coordinator.coreText(), e.string)
    }

    func testTwoPastesAtOnceNeverShareAFile() throws {
        // Both pastes pick a name off the main thread: picking and writing must be one step.
        let pb = imagePasteboard()
        let e = Editor(text: "x\n")
        e.session.documentURL = { self.dir.appendingPathComponent("n.md") }
        var done = 0
        for _ in 0..<6 { e.tv.pasteImage(from: pb) { _ in done += 1 } }
        XCTAssertTrue(spin { done == 6 })
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("n.assets").path)
        XCTAssertEqual(files.count, 6, "\(files)")
        let links = e.string.components(separatedBy: "![image](").count - 1
        XCTAssertEqual(links, 6)
        // And the primitive itself, from many threads.
        let target = dir.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let lock = NSLock()
        var urls = Set<URL>()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            let u = try? DocumentFileAccess.writeNew(Data([UInt8(i)]), in: target, name: "image", ext: "png")
            lock.lock()
            if let u { urls.insert(u) }
            lock.unlock()
        }
        XCTAssertEqual(urls.count, 40)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, 40)
    }

    func testPastedImageIntoAnUnsavedDocumentAsksToSaveFirst() throws {
        let e = Editor(text: "x\n")
        var asked = 0
        var savedURL: URL?
        e.session.documentURL = { savedURL }
        e.session.requestSave = { done in
            asked += 1
            savedURL = self.dir.appendingPathComponent("Saved.md")
            done(true)
        }
        var ok: Bool?
        e.tv.pasteImage(from: imagePasteboard()) { ok = $0 }
        XCTAssertTrue(spin { ok != nil })
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(ok, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Saved.assets/image.png").path))
        XCTAssertTrue(e.string.contains("![image](Saved.assets/image.png)"))
    }

    func testCancellingTheSavePanelAbortsCleanly() {
        let e = Editor(text: "x\n")
        e.session.documentURL = { nil }
        e.session.requestSave = { done in done(false) }
        var ok: Bool?
        e.tv.pasteImage(from: imagePasteboard()) { ok = $0 }
        XCTAssertTrue(spin { ok != nil })
        XCTAssertEqual(ok, false)
        XCTAssertEqual(e.string, "x\n")
        XCTAssertFalse(e.um.canUndo)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count, 0, "nothing was written")
    }

    func testOnlyBareImageDataIsAnImagePaste() {
        let e = Editor(text: "x")
        func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
            let pb = NSPasteboard(name: NSPasteboard.Name("markdown-paste-\(UUID().uuidString)"))
            pb.clearContents()
            fill(pb)
            addTeardownBlock { pb.releaseGlobally() }
            return pb
        }
        XCTAssertTrue(e.tv.pasteboardHasOnlyImage(board { $0.setData(TestImages.png(width: 2, height: 2), forType: .png) }))
        XCTAssertFalse(e.tv.pasteboardHasOnlyImage(board { $0.setString("text", forType: .string); $0.setData(TestImages.png(width: 2, height: 2), forType: .png) }), "text wins")
        XCTAssertFalse(e.tv.pasteboardHasOnlyImage(board { $0.setString("text", forType: .string) }))
        XCTAssertFalse(e.tv.pasteboardHasOnlyImage(board { _ in }))
    }
}
