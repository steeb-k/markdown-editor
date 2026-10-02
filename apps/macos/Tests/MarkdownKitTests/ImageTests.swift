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

final class ImageControllerTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = TestImages.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func load(_ c: ImageController, _ dest: String, budget: ImageController.Budget, scale: CGFloat = 1) -> ImageController.Entry {
        _ = c.entry(for: dest, budget: budget, scale: scale)
        XCTAssertTrue(spin { !c.isLoading })
        return c.entry(for: dest, budget: budget, scale: scale)
    }

    func testResolvesPathsAndSchemes() {
        let c = ImageController()
        c.documentURL = { URL(fileURLWithPath: "/docs/sub/note.md") }
        XCTAssertEqual(c.resolve("img/a.png")?.path, "/docs/sub/img/a.png")
        XCTAssertEqual(c.resolve("../a%20b.png")?.path, "/docs/a b.png")
        XCTAssertEqual(c.resolve("/abs/a.png")?.path, "/abs/a.png")
        XCTAssertEqual(c.resolve("file:///x/y.png")?.path, "/x/y.png")
        XCTAssertEqual(c.resolve("https://example.com/a.png")?.absoluteString, "https://example.com/a.png")
        XCTAssertNil(c.resolve("ftp://example.com/a.png"))
        XCTAssertNil(c.resolve("data:image/png;base64,AAAA"))
        XCTAssertNil(c.resolve(""))
        c.documentURL = { nil }
        XCTAssertNil(c.resolve("img/a.png"), "an untitled document resolves relative paths against nothing")
        XCTAssertEqual(c.resolve("/abs/a.png")?.path, "/abs/a.png")
    }

    func testLoadsOffMainDecodesAndCaches() throws {
        let file = dir.appendingPathComponent("pic.png")
        try TestImages.png(width: 300, height: 150).write(to: file)
        let c = ImageController()
        c.documentURL = { self.dir.appendingPathComponent("note.md") }
        let budget = ImageController.Budget(width: 600, maxHeight: 400)
        var updates: [URL] = []
        c.onUpdate = { updates.append($0) }
        let first = c.entry(for: "pic.png", budget: budget, scale: 1)
        XCTAssertEqual(first.phase, .loading)
        XCTAssertNil(first.image)
        XCTAssertEqual(first.size, ImageController.placeholderSize(budget), "a placeholder's size is reserved meanwhile")
        XCTAssertTrue(spin { !c.isLoading && c.decodeCount == 1 })
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.lastPathComponent, "pic.png")
        let loaded = c.entry(for: "pic.png", budget: budget, scale: 1)
        XCTAssertEqual(loaded.phase, .loaded)
        XCTAssertNotNil(loaded.image)
        XCTAssertEqual(loaded.size, CGSize(width: 300, height: 150), "never enlarged")
        XCTAssertEqual(c.decodeCount, 1)
        XCTAssertTrue(c.lastDecodeWasOffMain, "decoded off the main thread")
        // Cached: asking again decodes nothing and updates nobody.
        for _ in 0..<5 { XCTAssertEqual(c.entry(for: "pic.png", budget: budget, scale: 1).phase, .loaded) }
        _ = spin(timeout: 0.3) { false }
        XCTAssertEqual(c.decodeCount, 1)
        XCTAssertEqual(updates.count, 1)
    }

    func testDownsamplesToTheColumnAndCapsTheHeight() throws {
        let wide = dir.appendingPathComponent("wide.png"), tall = dir.appendingPathComponent("tall.png")
        try TestImages.png(width: 4000, height: 2000).write(to: wide)
        try TestImages.png(width: 500, height: 3000).write(to: tall)
        let c = ImageController()
        c.documentURL = { self.dir.appendingPathComponent("note.md") }
        let budget = ImageController.Budget(width: 400, maxHeight: 300)
        let w = load(c, "wide.png", budget: budget, scale: 2)
        XCTAssertEqual(w.size, CGSize(width: 400, height: 200))
        let decoded = try XCTUnwrap(w.image)
        XCTAssertLessThanOrEqual(decoded.width, 802, "decoded for 400 points at 2x, not at 4000 pixels")
        XCTAssertGreaterThanOrEqual(decoded.width, 798)
        let t = load(c, "tall.png", budget: budget, scale: 1)
        XCTAssertEqual(t.size.height, 300, "capped to the height budget")
        XCTAssertEqual(t.size.width, 50, "keeping the aspect ratio")
        XCTAssertLessThanOrEqual(try XCTUnwrap(t.image).width, 51)
        // A wider column needs a better decode: it is asked for again.
        let wider = ImageController.Budget(width: 1000, maxHeight: 900)
        let before = c.decodeCount
        let again = load(c, "wide.png", budget: wider, scale: 2)
        XCTAssertEqual(again.size, CGSize(width: 1000, height: 500))
        XCTAssertGreaterThan(c.decodeCount, before)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(again.image).width, 1998)
    }

    func testBrokenImagesAreQuietPlaceholders() throws {
        let c = ImageController()
        c.documentURL = { self.dir.appendingPathComponent("note.md") }
        let budget = ImageController.Budget(width: 600, maxHeight: 400)
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("bad.png"))
        for name in ["missing.png", "bad.png", "http://127.0.0.1:9/x.png"] {
            let e = load(c, name, budget: budget)
            XCTAssertEqual(e.phase, .failed, name)
            XCTAssertNil(e.image)
            XCTAssertEqual(e.size, ImageController.placeholderSize(budget))
        }
        // Not retried on every draw.
        let n = c.requests
        for _ in 0..<10 { _ = c.entry(for: "missing.png", budget: budget, scale: 1) }
        _ = spin(timeout: 0.2) { false }
        XCTAssertFalse(c.isLoading)
        XCTAssertEqual(c.requests, n + 10)
        // Unsaved document, relative path: nothing to resolve against.
        c.documentURL = { nil }
        XCTAssertEqual(c.entry(for: "pic.png", budget: budget, scale: 1).phase, .failed)
        XCTAssertFalse(c.isLoading)
    }

    func testChangedFilesAreReloadedWhenRevalidated() throws {
        let file = dir.appendingPathComponent("pic.png")
        try TestImages.png(width: 100, height: 100).write(to: file)
        let c = ImageController()
        c.documentURL = { self.dir.appendingPathComponent("note.md") }
        let budget = ImageController.Budget(width: 600, maxHeight: 400)
        XCTAssertEqual(load(c, "pic.png", budget: budget).size, CGSize(width: 100, height: 100))
        try TestImages.png(width: 200, height: 50).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        c.revalidate()
        XCTAssertTrue(spin { c.entry(for: "pic.png", budget: budget, scale: 1).size == CGSize(width: 200, height: 50) })
    }

    func testFitNeverEnlargesAndKeepsAspect() {
        let b = ImageController.Budget(width: 500, maxHeight: 250)
        XCTAssertEqual(ImageController.fit(CGSize(width: 100, height: 50), in: b), CGSize(width: 100, height: 50))
        XCTAssertEqual(ImageController.fit(CGSize(width: 1000, height: 100), in: b), CGSize(width: 500, height: 50))
        XCTAssertEqual(ImageController.fit(CGSize(width: 100, height: 1000), in: b), CGSize(width: 25, height: 250))
    }
}

final class InlineImageLayoutTests: XCTestCase {
    private var dir: URL!
    override func setUp() { dir = TestImages.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSpaceIsReservedPushesTextDownAndSourceReturnsOnEntry() throws {
        try TestImages.png(width: 600, height: 300).write(to: dir.appendingPathComponent("pic.png"))
        let text = "before\n\n![alt](pic.png)\n\nafter text\n"
        let ns = text as NSString
        let e = Editor(text: text)
        e.session.documentURL = { self.dir.appendingPathComponent("note.md") }
        e.tv.setFrameSize(NSSize(width: 800, height: 600))
        e.session.setViewMode(.live)
        e.select(0)
        e.settle()
        let after = ns.range(of: "after").location
        // While loading: a placeholder's room.
        let placeholderTop = e.lineTop(of: after)
        XCTAssertGreaterThan(placeholderTop, e.lineTop(of: 0) + 60)
        XCTAssertTrue(spin { !e.session.imageController.isLoading })
        e.settle()
        // Loaded: the image's room (300 tall in an 800-wide window, within 60% of the view).
        let loadedTop = e.lineTop(of: after)
        XCTAssertGreaterThan(loadedTop, placeholderTop + 100, "text below moved down when the real size arrived")
        // The reserved room is the image plus its padding, on the image's own line.
        let host = ns.range(of: "\n\nafter").location + 1 - 1 // the terminator after the source
        _ = host
        let imageLine = e.lm.lineFragmentRect(forGlyphAt: e.lm.glyphIndexForCharacter(at: ns.range(of: ")\n\nafter").location + 1), effectiveRange: nil)
        XCTAssertEqual(imageLine.height, 300 + 2 * EditorLayoutManager.imagePadding, accuracy: 1)
        // The source is hidden (null/zero-width) and an image decoration is there.
        XCTAssertTrue(e.isNull(ns.range(of: "![alt]").location))
        XCTAssertEqual(e.lm.live.decorations.filter { if case .image = $0.kind { return true } else { return false } }.count, 1)
        // Entering the paragraph shows the source and gives back a line's height.
        e.select(ns.range(of: "alt").location + 1)
        e.settle()
        XCTAssertFalse(e.isNull(ns.range(of: "![alt]").location))
        XCTAssertTrue(e.lm.live.decorations.allSatisfy { if case .image = $0.kind { return false } else { return true } })
        XCTAssertLessThan(e.lineTop(of: after), loadedTop - 200)
        // Leaving restores it.
        e.select(ns.length)
        e.settle()
        XCTAssertEqual(e.lineTop(of: after), loadedTop, accuracy: 0.5)
    }

    func testImageIsDrawnInItsRoom() throws {
        try TestImages.png(width: 200, height: 100, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)).write(to: dir.appendingPathComponent("red.png"))
        let text = "x\n\n![r](red.png)\n\nz\n"
        let e = Editor(text: text)
        e.session.documentURL = { self.dir.appendingPathComponent("note.md") }
        e.tv.setFrameSize(NSSize(width: 700, height: 600))
        e.session.setViewMode(.live)
        e.select((text as NSString).length)
        e.settle()
        XCTAssertTrue(spin { !e.session.imageController.isLoading })
        e.settle()
        e.tv.setFrameSize(NSSize(width: 700, height: 10))
        e.tv.layoutManager?.ensureLayout(for: e.tv.textContainer!)
        e.tv.sizeToFit()
        let rep = try XCTUnwrap(e.tv.bitmapImageRepForCachingDisplay(in: e.tv.bounds))
        e.tv.cacheDisplay(in: e.tv.bounds, to: rep)
        let ns = text as NSString
        let line = e.lm.lineFragmentRect(forGlyphAt: e.lm.glyphIndexForCharacter(at: ns.range(of: ")\n\nz").location + 1), effectiveRange: nil)
        let origin = e.tv.textContainerOrigin
        let scale = CGFloat(rep.pixelsWide) / e.tv.bounds.width
        let probe = NSPoint(x: origin.x + 100, y: origin.y + line.minY + EditorLayoutManager.imagePadding + 50)
        let c = try XCTUnwrap(rep.colorAt(x: Int(probe.x * scale), y: Int(probe.y * scale))).usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(c.redComponent, 0.9)
        XCTAssertLessThan(c.greenComponent, 0.15, "the picture is painted in the reserved room")
    }

    func testAPictureArrivingAboveTheViewportDoesNotMoveWhatIsOnScreen() throws {
        try TestImages.png(width: 600, height: 300).write(to: dir.appendingPathComponent("pic.png"))
        let filler = (0..<60).map { "Line \($0) of filler text.\n\n" }.joined()
        let text = "![alt](pic.png)\n\n" + filler
        let e = Editor(text: text)
        e.session.documentURL = { self.dir.appendingPathComponent("note.md") }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        scroll.documentView = e.tv
        e.tv.setFrameSize(NSSize(width: 800, height: 300))
        e.session.setViewMode(.live)
        let ns = text as NSString
        e.select(ns.range(of: "Line 20").location) // the reader's place: on screen after the scroll below
        // Hold the loader back until the reader has scrolled below the picture.
        e.session.imageController.documentURL = { nil }
        e.settle()
        e.tv.scrollRangeToVisible(NSRange(location: ns.range(of: "Line 20").location, length: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        e.session.imageController.documentURL = { self.dir.appendingPathComponent("note.md") }
        let probe = ns.range(of: "Line 20").location
        e.lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: ns.length))
        // Watch the reader's line on screen across the arrival itself (so nothing else can
        // have moved it).
        func onScreen() -> CGFloat {
            e.lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: ns.length))
            return e.lineTop(of: probe) - scroll.contentView.bounds.origin.y
        }
        var seen: (before: CGFloat, after: CGFloat)?
        let original = try XCTUnwrap(e.session.imageController.onUpdate)
        e.session.imageController.onUpdate = { url in
            let before = onScreen()
            original(url)
            seen = (before, onScreen())
        }
        e.session.documentURLChanged() // failures forgotten: the picture is found now
        XCTAssertTrue(spin { seen != nil })
        let result = try XCTUnwrap(seen)
        XCTAssertEqual(result.after, result.before, accuracy: 1, "the line the reader is looking at stayed where it was on screen")
        // And the picture really did change the layout above it.
        XCTAssertGreaterThan(e.lineHeight(of: ns.range(of: ")\n\n").location + 1), 150)
    }

    func testPlaceholderForMissingImageDoesNotChangeTheText() {
        let text = "a\n\n![gone](missing.png)\n\nb\n"
        let e = Editor(text: text)
        e.session.documentURL = { URL(fileURLWithPath: "/nonexistent/note.md") }
        e.session.setViewMode(.live)
        e.select(0)
        e.settle()
        XCTAssertTrue(spin { !e.session.imageController.isLoading })
        e.settle()
        XCTAssertEqual(e.string, text)
        XCTAssertGreaterThan(e.lineTop(of: (text as NSString).range(of: "b\n").location), e.lineTop(of: 0) + 60)
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
