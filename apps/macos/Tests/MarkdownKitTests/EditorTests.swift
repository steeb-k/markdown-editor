import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

// MARK: document round trip

final class DocumentRoundTripTests: XCTestCase {
    private func roundTrip(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: data, ofType: "net.daringfireball.markdown")
        XCTAssertEqual(try doc.data(ofType: "net.daringfireball.markdown"), data, file: file, line: line)
    }

    func testEveryFixtureIsByteIdentical() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Fixtures.fixtureDir.path)
        XCTAssertGreaterThanOrEqual(names.count, 5)
        for n in names where n != ".DS_Store" {
            try roundTrip(Data(contentsOf: Fixtures.fixtureDir.appendingPathComponent(n)))
        }
    }

    func testBOMAndLineEndings() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("# Title\n\ntext é\n".utf8)
        try roundTrip(bom)
        try roundTrip(Data("a\r\nb\r\n\r\nc".utf8))        // CRLF throughout
        try roundTrip(Data("a\rb\r".utf8))                  // old Mac
        try roundTrip(Data("a\r\nb\nc\rd\r\n".utf8))        // mixed: untouched
        try roundTrip(Data())
        try roundTrip(Data("no newline at end".utf8))
        try roundTrip(Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb".utf8))
    }

    func testCRLFFileIsEditedWithLFAndSavedWithCRLF() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data("a\r\nb".utf8), ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.session.text, "a\nb")
        XCTAssertEqual(doc.lineEnding, .crlf)
        doc.session.storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "!\nc")
        XCTAssertEqual(try doc.data(ofType: "x"), Data("a\r\nb!\r\nc".utf8))
    }

    func testUndecodableBytesAreRejected() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        for bad in [Data([0xFF, 0xFE, 0x41, 0x00]), Data([0x61, 0xC3, 0x28]), Data("a\u{0}b".utf8)] {
            XCTAssertThrowsError(try doc.read(from: bad, ofType: "x")) { e in
                XCTAssertEqual((e as NSError).code, NSFileReadInapplicableStringEncodingError)
                XCTAssertFalse((e as NSError).localizedDescription.isEmpty)
            }
        }
    }

    func testReadThroughFileAccessAndLoadDoesNotDirtyDocument() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).md")
        try Data("# Hi\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: url, ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.session.text, "# Hi\n")
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(doc.undoManager?.canUndo, false)
    }

    func testRelativePaths() {
        let doc = URL(fileURLWithPath: "/a/b/note.md")
        XCTAssertEqual(DocumentFileAccess.path(of: URL(fileURLWithPath: "/a/b/img/x.png"), relativeTo: doc), "img/x.png")
        XCTAssertEqual(DocumentFileAccess.path(of: URL(fileURLWithPath: "/a/c/x.png"), relativeTo: doc), "../c/x.png")
        XCTAssertEqual(DocumentFileAccess.path(of: URL(fileURLWithPath: "/a/b/x.png"), relativeTo: doc), "x.png")
        XCTAssertEqual(DocumentFileAccess.path(of: URL(fileURLWithPath: "/z/x.png"), relativeTo: nil), "/z/x.png")
    }

    func testRangeMath() {
        let c = TextChange(old: NSRange(location: 5, length: 3), newLength: 1)
        XCTAssertEqual(RangeMath.shift(NSRange(location: 0, length: 4), through: c), NSRange(location: 0, length: 4))
        XCTAssertEqual(RangeMath.shift(NSRange(location: 10, length: 2), through: c), NSRange(location: 8, length: 2))
        XCTAssertEqual(RangeMath.shift(NSRange(location: 4, length: 6), through: c), NSRange(location: 4, length: 4))
        XCTAssertEqual(RangeMath.shift(NSRange(location: 6, length: 1), through: c), NSRange(location: 5, length: 1))
        var set = RangeSet()
        set.add(NSRange(location: 0, length: 5)); set.add(NSRange(location: 5, length: 5)); set.add(NSRange(location: 20, length: 5))
        XCTAssertEqual(set.ranges, [NSRange(location: 0, length: 10), NSRange(location: 20, length: 5)])
        set.subtract(NSRange(location: 3, length: 20))
        XCTAssertEqual(set.ranges, [NSRange(location: 0, length: 3), NSRange(location: 23, length: 2)])
    }
}

// MARK: styler

final class StylerTests: XCTestCase {
    static let sample = """
    # Title

    Some *emph* and **strong** and `code` and [link](http://x.y) text.

    - item one that is long
    - item two

    > quoted line

    ```swift
    let x = 1
    ```

    | a | b |
    |---|---|
    | 1 | 2 |

    """

    func attrs(_ e: Editor, at needle: String, offset: Int = 0) -> [NSAttributedString.Key: Any] {
        let r = (e.string as NSString).range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, needle)
        return e.session.storage.attributes(at: r.location + offset, effectiveRange: nil)
    }

    func testExpectedAttributes() {
        let e = Editor(text: Self.sample)
        let fonts = e.session.appearance.fonts
        let p = e.session.appearance.palette
        let body = fonts.body

        let h = attrs(e, at: "Title")[.font] as! NSFont
        XCTAssertGreaterThan(h.pointSize, body.pointSize * 1.5)
        XCTAssertTrue(fonts.isBold(h))
        XCTAssertEqual((attrs(e, at: "Title")[.foregroundColor] as! NSColor).hexString, p.heading.hexString)
        XCTAssertEqual((attrs(e, at: "# Title")[.foregroundColor] as! NSColor).hexString, p.markup.hexString, "# is dimmed")

        XCTAssertTrue(fonts.isItalic(attrs(e, at: "emph")[.font] as! NSFont))
        XCTAssertEqual((attrs(e, at: "*emph*")[.foregroundColor] as! NSColor).hexString, p.markup.hexString)
        XCTAssertTrue(fonts.isBold(attrs(e, at: "strong")[.font] as! NSFont))
        XCTAssertEqual((attrs(e, at: "**strong")[.foregroundColor] as! NSColor).hexString, p.markup.hexString)

        let code = attrs(e, at: "code` and")
        XCTAssertTrue(FontSet.isMonospaced(code[.font] as! NSFont))
        XCTAssertEqual((code[.backgroundColor] as! NSColor).hexString, p.codeBackground.hexString)
        let block = attrs(e, at: "let x")
        XCTAssertTrue(FontSet.isMonospaced(block[.font] as! NSFont))
        XCTAssertEqual((block[.markdownBlockBackground] as? NSColor)?.hexString, p.codeBackground.hexString, "code block panel")
        XCTAssertNil(block[.backgroundColor], "no per-glyph background (it striped between lines)")

        XCTAssertEqual((attrs(e, at: "link]")[.foregroundColor] as! NSColor).hexString, p.link.hexString)
        XCTAssertEqual((attrs(e, at: "http://x.y")[.foregroundColor] as! NSColor).hexString, p.markup.hexString, "destination dimmed")

        let item = attrs(e, at: "item one")[.paragraphStyle] as! NSParagraphStyle
        XCTAssertGreaterThan(item.headIndent, 0, "wrapped list lines hang under the text")
        XCTAssertEqual(item.firstLineHeadIndent, 0)
        let quote = attrs(e, at: "quoted")[.paragraphStyle] as! NSParagraphStyle
        XCTAssertGreaterThan(quote.headIndent, 0)
        let plain = attrs(e, at: "Some")[.paragraphStyle] as! NSParagraphStyle
        XCTAssertEqual(plain.headIndent, 0)
        XCTAssertGreaterThan(plain.lineSpacing, 0, "generous line height")

        XCTAssertTrue(FontSet.isMonospaced(attrs(e, at: "| 1")[.font] as! NSFont), "tables are monospaced")
    }

    func testProportionalFontStillGetsMonospacedTablesAndCode() {
        let s = isolatedSettings()
        s.fontChoice = .systemSerif
        let e = Editor(text: Self.sample, settings: s)
        XCTAssertFalse(FontSet.isMonospaced(e.session.appearance.fonts.body))
        XCTAssertTrue(FontSet.isMonospaced(attrs(e, at: "| 1")[.font] as! NSFont))
        XCTAssertTrue(FontSet.isMonospaced(attrs(e, at: "let x")[.font] as! NSFont))
    }

    func testBundledFontsFallBackSilently() {
        let s = isolatedSettings()
        s.fontChoice = .iaDuo
        let set = FontStore.fonts(choice: .iaDuo, customFamily: "", size: 16)
        XCTAssertEqual(set.body.pointSize, 16)
        if !FontStore.bundledFontsAvailable { XCTAssertFalse(set.bundled) }
        let custom = FontStore.fonts(choice: .custom, customFamily: "No Such Family", size: 16)
        XCTAssertEqual(custom.body.pointSize, 16)
    }

    func testBundledFontsResolveFacesWhenPresent() throws {
        let dir = Fixtures.root.appendingPathComponent("apps/macos/Resources/Fonts")
        let ttfs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "ttf" }
        try XCTSkipIf(ttfs.isEmpty, "bundled fonts not downloaded")
        CTFontManagerRegisterFontURLs(ttfs as CFArray, .process, true, nil)
        let set = FontStore.fonts(choice: .iaQuattro, customFamily: "", size: 16)
        XCTAssertTrue(set.bundled)
        XCTAssertEqual(set.body.fontName, "iAWriterQuattroS-Regular")
        XCTAssertEqual(set.variant(of: set.body, bold: true).fontName, "iAWriterQuattroS-Bold")
        XCTAssertEqual(set.variant(of: set.variant(of: set.body, bold: true), italic: true).fontName, "iAWriterQuattroS-BoldItalic")
        XCTAssertEqual(set.mono.fontName.hasPrefix("iAWriterMono"), true)
    }

    func testKeystrokeRestylesOnlyTheDirtyParagraph() {
        let e = Editor(text: Self.sample)
        e.session.styler.recordsTouchedRanges = true
        e.session.styler.resetTouchedRanges()
        let ns = e.string as NSString
        let at = ns.range(of: "item two").location + 2
        e.select(at)
        e.grouped { e.tv.insertText("Z", replacementRange: NSRange(location: at, length: 0)) }
        XCTAssertTrue(e.session.waitUntilStyled())
        let touched = e.session.styler.touchedRanges
        XCTAssertFalse(touched.isEmpty)
        let paragraph = (e.string as NSString).paragraphRange(for: NSRange(location: at, length: 1))
        let allowed = (e.string as NSString).paragraphRange(for: NSRange(location: max(0, paragraph.location - 1), length: 0))
        let hull = NSUnionRange(allowed, NSRange(location: NSMaxRange(paragraph), length: 0))
        for r in touched {
            XCTAssertTrue(NSIntersectionRange(r, hull).length == r.length, "touched \(r), expected within \(hull)")
        }
        XCTAssertLessThan(touched.reduce(0) { $0 + $1.length }, 80)
    }

    func testAttributeEditsNeverMarkTheDocumentChangedOrReachTheCore() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data(Self.sample.utf8), ofType: "x")
        let session = doc.session
        XCTAssertTrue(session.waitUntilStyled())
        let seq = session.coordinator.latestSeq
        session.storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 4))
        XCTAssertEqual(session.coordinator.latestSeq, seq)
        XCTAssertFalse(doc.isDocumentEdited)
    }

    func testTypingAttributesAreNotStaleAfterHeading() {
        let e = Editor(text: "# Head\n")
        e.select(7) // start of the empty line after the heading
        let f = e.tv.typingAttributes[.font] as! NSFont
        XCTAssertEqual(f.pointSize, e.session.appearance.fonts.body.pointSize)
    }
}

// MARK: analysis coordinator

final class AnalysisCoordinatorTests: XCTestCase {
    func testBurstFasterThanAnalysisEndsIdenticalToFreshStyling() {
        let base = (0..<30).map { "## Heading \($0)\n\nPara *em* **st** `c` [l](u)\n\n- a\n- b\n" }.joined(separator: "\n")
        let e = Editor(text: base)
        e.session.coordinator.artificialDelay = 0.03
        var rng = SystemRandomNumberGenerator()
        for i in 0..<60 {
            let len = e.session.storage.length
            let at = Int.random(in: 0...len, using: &rng)
            let snippets = ["*", "# ", "x", "\n", "**", "`", "- ", "|a|b|\n|-|-|\n", ""]
            let s = snippets[i % snippets.count]
            let del = (s.isEmpty && at < len) ? 1 : 0
            e.edit(range: NSRange(location: at, length: del), with: s)
        }
        e.session.coordinator.artificialDelay = 0
        XCTAssertTrue(e.session.waitUntilStyled())
        let fresh = Editor(text: e.string)
        XCTAssertEqual(e.signature(), fresh.signature())
        XCTAssertEqual(e.session.coordinator.mirrorText(), e.string)
        XCTAssertEqual(e.session.coordinator.coreText(), e.string)
    }

    /// `isIdle` (what `isStyled` and the bounded wait rely on) is true only once the last
    /// edit's result can be delivered: it used to turn true while that result's spans were still
    /// being fetched, so `waitUntilStyled` could return with the styling not applied (seen with a
    /// release-built core, where the race is easy to win).
    func testIdleOnlyOnceTheLastResultIsReady() {
        let c = AnalysisCoordinator(text: String(repeating: "# Head\n\ntext *em* **b**\n\n", count: 400))
        for round in 0..<30 {
            c.artificialDelay = round % 2 == 0 ? 0.002 : 0
            var delivered: [Int] = []
            c.onResult = { delivered.append($0.seq) }
            var last = 0
            for i in 0..<3 { last = c.submit(range: NSRange(location: i, length: 0), replacement: "x") }
            // Without running the main run loop (which would deliver on its own): the moment the
            // queue says it is idle, the result must be there to deliver.
            let deadline = Date(timeIntervalSinceNow: 5)
            while !c.isIdle && Date() < deadline { usleep(50) }
            c.deliverPending()
            XCTAssertTrue(delivered.contains(last), "round \(round): idle, but the result for edit \(last) was not ready: \(delivered)")
        }
        c.artificialDelay = 0
    }

    func testStaleResultsAreNeverAppliedToShiftedText() {
        let e = Editor(text: "# Title\n\nbody\n")
        let heading = e.session.storage.attribute(.font, at: 3, effectiveRange: nil) as! NSFont
        e.session.coordinator.artificialDelay = 0.05
        e.session.styler.recordsTouchedRanges = true
        e.session.styler.resetTouchedRanges()
        e.edit(range: NSRange(location: 0, length: 0), with: "x") // kills the heading
        e.edit(range: NSRange(location: 0, length: 0), with: "yyyyyyyyyy")
        // Nothing may have been styled yet: the first result (for revision 1) is stale by now.
        let early = e.session.styler.touchedRanges
        e.session.coordinator.artificialDelay = 0
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(e.string, "yyyyyyyyyyx# Title\n\nbody\n")
        let f = e.session.storage.attribute(.font, at: 12, effectiveRange: nil) as! NSFont
        XCTAssertLessThan(f.pointSize, heading.pointSize)
        XCTAssertEqual(e.signature(), Editor(text: e.string).signature())
        for r in early { XCTAssertLessThanOrEqual(NSMaxRange(r), e.session.storage.length) }
    }

    func testBigDocumentKeystrokeBlocksMainThreadOnlyForTheBoundedWait() throws {
        var text = ""
        let unit = try Fixtures.text("basic.md") + "\n" + Fixtures.text("gfm.md") + "\n"
        while (text as NSString).length < 1_000_000 { text += unit }
        let e = Editor(text: "")
        let started = Date()
        e.session.load(text)
        XCTAssertTrue(e.session.waitUntilStyled(timeout: 120))
        print("1 MB load + full chunked styling: \(Date().timeIntervalSince(started)) s")
        let wait = e.session.coordinator.syncWait
        var worst: TimeInterval = 0
        let len = e.session.storage.length
        for i in 0..<25 {
            let at = len / 2 + i * 7
            let t0 = CFAbsoluteTimeGetCurrent()
            e.edit(range: NSRange(location: at, length: 0), with: "k")
            worst = max(worst, CFAbsoluteTimeGetCurrent() - t0)
            // let analysis finish between keystrokes, like a human typist
            _ = spin(timeout: 5) { e.session.coordinator.isIdle }
            e.session.coordinator.deliverPending()
        }
        print("worst main-thread time per keystroke at 1 MB: \(worst * 1000) ms (bound \(wait * 1000) ms)")
        XCTAssertLessThan(worst, wait + 0.030)
        XCTAssertTrue(e.session.waitUntilStyled(timeout: 60))
    }

    func testInitialPassIsChunkedAndVisibleFirst() throws {
        var text = ""
        let unit = try Fixtures.text("basic.md") + "\n"
        while (text as NSString).length < 200_000 { text += unit }
        let e = Editor(text: "")
        let target = (text as NSString).length - 5000
        e.session.visibleRange = { NSRange(location: target, length: 3000) }
        e.session.load(text)
        // After one run-loop turn the tail (visible) region is styled before the head.
        XCTAssertTrue(spin(timeout: 20) { !e.session.owedStyling.contains { NSLocationInRange(target + 100, $0) } })
        XCTAssertFalse(e.session.isStyled, "not everything is styled in one go")
        XCTAssertTrue(e.session.waitUntilStyled(timeout: 60))
    }
}

// MARK: commands through a real text view

final class EditorCommandTests: XCTestCase {
    func testStrongToggle() {
        let e = Editor(text: "a word b")
        e.select(2, 4)
        e.grouped { e.tv.toggleStrong(nil) }
        XCTAssertEqual(e.string, "a **word** b")
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 4, length: 4))
        e.um.undo(); XCTAssertEqual(e.string, "a word b")
        e.um.redo(); XCTAssertEqual(e.string, "a **word** b")
        e.select(4, 4)
        e.roundTrip { e.tv.toggleStrong(nil) }
        XCTAssertEqual(e.string, "a word b")
    }

    func testHeading() {
        let e = Editor(text: "title")
        e.select(2)
        e.roundTrip { e.tv.setHeading(level: 2) }
        XCTAssertEqual(e.string, "## title")
        XCTAssertTrue(e.session.waitUntilStyled())
        let f = e.session.storage.attribute(.font, at: 4, effectiveRange: nil) as! NSFont
        XCTAssertGreaterThan(f.pointSize, e.session.appearance.fonts.body.pointSize)
    }

    func testReturnContinuesAndEndsList() {
        let e = Editor(text: "- a")
        e.select(3)
        e.roundTrip { e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(e.string, "- a\n- ")
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 6, length: 0))
        e.roundTrip { e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(e.string, "- a\n")
    }

    func testReturnOutsideListFallsBackToDefault() {
        let e = Editor(text: "plain")
        e.select(5)
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        XCTAssertEqual(e.string, "plain\n")
    }

    func testTabAndShiftTabInList() {
        let e = Editor(text: "- a\n- b")
        e.select(7)
        e.roundTrip { e.tv.doCommand(by: #selector(NSResponder.insertTab(_:))) }
        XCTAssertEqual(e.string, "- a\n  - b")
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
        XCTAssertEqual(e.string, "- a\n- b")
    }

    func testTabInTableMovesCellsAndAddsRow() {
        let e = Editor(text: "| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        e.select(2)
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertTab(_:))) }
        XCTAssertEqual((e.string as NSString).substring(with: e.tv.selectedRange()), "b")
        // From the last cell Tab appends a body row.
        let last = (e.string as NSString).range(of: "2").location
        e.select(last)
        e.roundTrip { e.tv.doCommand(by: #selector(NSResponder.insertTab(_:))) }
        XCTAssertEqual(e.string.split(separator: "\n").count, 4)
        e.select(0)
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 0, length: 0), "Shift-Tab in the first cell does nothing")
    }

    func testTableMenuCommandsAndInsert() {
        let e = Editor(text: "x\n")
        e.select(0)
        e.roundTrip { e.tv.insertTable(rows: 2, columns: 3) }
        XCTAssertTrue(e.string.contains("---"))
        e.um.undo(); e.um.redo()
        e.select((e.string as NSString).range(of: "|").location + 2)
        XCTAssertTrue(spin { e.session.formatState.inTable })
        e.roundTrip { e.tv.tableAddColumnRight(nil) }
        XCTAssertTrue(e.string.split(separator: "\n")[0].components(separatedBy: "|").count >= 6)
    }

    func testSelectionOnlyEditMovesSelectionWithoutChangingText() {
        let e = Editor(text: "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n")
        e.select(2)
        let before = e.string
        e.grouped { _ = e.tv.handleTab(outdent: false) }
        XCTAssertEqual(e.string, before)
        XCTAssertEqual((e.string as NSString).substring(with: e.tv.selectedRange()), "b")
    }

    func testNothingHappensWhileComposing() {
        let e = Editor(text: "a word b")
        e.select(2, 4)
        e.grouped { e.tv.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 8, length: 0)) }
        let before = e.string
        XCTAssertTrue(e.tv.hasMarkedText())
        e.tv.toggleStrong(nil)
        XCTAssertEqual(e.string, before)
        e.grouped { e.tv.unmarkText() }
    }

    func testFormatStateReachesTheSessionOffMainThread() {
        let e = Editor(text: "a **word** b")
        e.select(6)
        XCTAssertTrue(spin { e.session.formatState.strong })
        e.select(0)
        XCTAssertTrue(spin { !e.session.formatState.strong })
    }

    func testValidation() {
        let e = Editor(text: "plain text")
        e.select(0)
        XCTAssertTrue(spin { !e.session.formatState.inTable })
        let item = NSMenuItem(title: "Add Row", action: #selector(EditorTextView.tableAddRowBelow(_:)), keyEquivalent: "")
        XCTAssertFalse(e.tv.validateUserInterfaceItem(item), "table commands are disabled outside a table")
        let strong = NSMenuItem(title: "Strong", action: #selector(EditorTextView.toggleStrong(_:)), keyEquivalent: "")
        XCTAssertTrue(e.tv.validateUserInterfaceItem(strong))
    }

    func testPlainTextConfiguration() {
        let e = Editor(text: "x")
        XCTAssertFalse(e.tv.isRichText)
        XCTAssertFalse(e.tv.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(e.tv.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(e.tv.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(e.tv.isAutomaticLinkDetectionEnabled)
        XCTAssertTrue(e.tv.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(e.tv.usesFindBar)
        XCTAssertTrue(e.tv.isIncrementalSearchingEnabled)
        XCTAssertTrue(e.tv.allowsUndo)
        XCTAssertNotNil(e.tv.textContainer?.layoutManager as? EditorLayoutManager)
        XCTAssertNil(e.tv.textLayoutManager, "TextKit 1")
    }

    func testImageUsesRelativePathWhenSaved() {
        let e = Editor(text: "")
        e.session.documentURL = { URL(fileURLWithPath: "/docs/note.md") }
        e.grouped { e.tv.insertImage(fileURL: URL(fileURLWithPath: "/docs/img/cat photo.png")) }
        XCTAssertTrue(e.string.contains("img/cat photo.png"), e.string)
        XCTAssertFalse(e.string.contains("/docs"))
    }
}

// MARK: realign on leave

final class RealignTests: XCTestCase {
    func testLeavingAMisalignedTableAlignsItAndUndoRestores() {
        let original = "| a | b |\n|-|-|\n| long cell | c |\n\nafter"
        let e = Editor(text: original)
        e.select(3)
        XCTAssertTrue(spin { e.session.activeTable != nil })
        let after = (original as NSString).range(of: "after").location + 2
        e.select(after)
        XCTAssertTrue(spin { e.string != original }, "table was realigned")
        let lines = e.string.components(separatedBy: "\n")
        XCTAssertEqual(lines[0].count, lines[2].count)
        XCTAssertEqual(lines[1].count, lines[2].count)
        // The caret did not jump: still inside "after".
        XCTAssertEqual((e.string as NSString).substring(from: e.tv.selectedRange().location), "ter")
        e.um.undo()
        XCTAssertEqual(e.string, original)
        e.um.redo()
        XCTAssertNotEqual(e.string, original)
    }

    func testNoRealignWhileComposingOrMovingInsideTable() {
        let original = "| a | b |\n|-|-|\n| long cell | c |\n\nafter"
        let e = Editor(text: original)
        e.select(3)
        XCTAssertTrue(spin { e.session.activeTable != nil })
        e.select(14)
        e.select(20)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(e.string, original)
    }
}

// MARK: chrome, settings, themes

final class ChromeStateTests: XCTestCase {
    func testTypingHidesAndPointerShows() {
        var s = ChromeState(autoHide: true)
        XCTAssertTrue(s.isVisible)
        XCTAssertEqual(s.handle(.typingStarted), false)
        XCTAssertNil(s.handle(.typingStarted))
        XCTAssertEqual(s.handle(.pointerMoved), true)
    }

    func testMenuAndResignShow() {
        var s = ChromeState(autoHide: true)
        s.handle(.typingStarted)
        XCTAssertEqual(s.handle(.menuOpened), true)
        XCTAssertNil(s.handle(.typingStarted), "no hiding while a menu is open")
        s.handle(.menuClosed)
        XCTAssertEqual(s.handle(.typingStarted), false)
        XCTAssertEqual(s.handle(.windowResignedKey), true)
        XCTAssertNil(s.handle(.typingStarted), "no hiding in a background window")
        s.handle(.windowBecameKey)
        XCTAssertEqual(s.handle(.typingStarted), false)
    }

    func testAlwaysVisibleSetting() {
        var s = ChromeState(autoHide: false)
        XCTAssertNil(s.handle(.typingStarted))
        XCTAssertTrue(s.isVisible)
        var t = ChromeState(autoHide: true)
        t.handle(.typingStarted)
        XCTAssertEqual(t.handle(.autoHideChanged(false)), true)
    }
}

final class SettingsAndThemeTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let name = "markdown-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let a = Settings(defaults: defaults)
        XCTAssertEqual(a.theme, .system)
        XCTAssertEqual(a.lineWidth, 72)
        XCTAssertTrue(a.spellCheck); XCTAssertTrue(a.showFormattingToolbar); XCTAssertTrue(a.autoHideChrome)
        a.theme = .sepia; a.fontChoice = .systemSerif; a.fontSize = 21; a.lineWidth = 60
        a.spellCheck = false; a.showFormattingToolbar = false; a.autoHideChrome = false
        a.customFontFamily = "Menlo"
        let b = Settings(defaults: defaults)
        XCTAssertEqual(b.theme, .sepia)
        XCTAssertEqual(b.fontChoice, .systemSerif)
        XCTAssertEqual(b.fontSize, 21)
        XCTAssertEqual(b.lineWidth, 60)
        XCTAssertFalse(b.spellCheck); XCTAssertFalse(b.showFormattingToolbar); XCTAssertFalse(b.autoHideChrome)
        XCTAssertEqual(b.customFontFamily, "Menlo")
        b.fontSize = 500
        XCTAssertEqual(b.fontSize, Settings.fontSizeRange.upperBound)
    }

    func testChangesPostNotificationAndApplyLive() {
        let s = isolatedSettings()
        let e = Editor(text: "# H\n\ntext", settings: s)
        let before = e.session.appearance.theme.id
        let exp = expectation(forNotification: Settings.didChangeNotification, object: s)
        s.theme = .sepia
        wait(for: [exp], timeout: 1)
        XCTAssertNotEqual(before, e.session.appearance.theme.id)
        XCTAssertEqual(e.session.appearance.theme.id, "sepia")
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual((e.session.storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as! NSColor).hexString,
                       e.session.appearance.palette.text.hexString)
        XCTAssertEqual(e.tv.backgroundColor.hexString, e.session.appearance.palette.background.hexString)
        s.fontSize = 24
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual((e.session.storage.attribute(.font, at: 8, effectiveRange: nil) as! NSFont).pointSize, 24)
        s.spellCheck = false
        XCTAssertFalse(e.tv.isContinuousSpellCheckingEnabled)
    }

    func testSystemThemeFollowsAppearance() {
        let store = ThemeStore()
        XCTAssertEqual(store.theme(for: .system, appearance: NSAppearance(named: .darkAqua)).id, "dark")
        XCTAssertEqual(store.theme(for: .system, appearance: NSAppearance(named: .aqua)).id, "light")
        XCTAssertEqual(store.theme(for: .dark, appearance: NSAppearance(named: .aqua)).id, "dark")
        XCTAssertEqual(store.theme(for: .sepia, appearance: nil).id, "sepia")
        let e = Editor(text: "x", appearance: NSAppearance(named: .darkAqua))
        XCTAssertEqual(e.session.appearance.theme.id, "dark")
        XCTAssertTrue(e.session.appearance.palette.isDark)
        e.session.forcedAppearance = NSAppearance(named: .aqua)
        e.session.refreshAppearance()
        XCTAssertEqual(e.session.appearance.theme.id, "light")
        XCTAssertEqual(e.tv.backgroundColor.hexString, ThemeStore.color(store.theme(id: "light").colors.background).hexString)
        XCTAssertEqual(e.tv.insertionPointColor.hexString, e.session.appearance.palette.caret.hexString)
    }

    func testColumnGeometryIsCenteredWithMaximumMeasure() {
        let e = Editor(text: "x")
        e.tv.setFrameSize(NSSize(width: 1600, height: 800))
        let m = e.session.appearance.measure
        XCTAssertEqual(e.tv.textContainerInset.width, ((1600 - m) / 2).rounded(.down))
        e.tv.setFrameSize(NSSize(width: 300, height: 800))
        XCTAssertEqual(e.tv.textContainerInset.width, EditorAppearance.minimumSideMargin)
        e.session.settings.fontSize = 30
        e.tv.setFrameSize(NSSize(width: 2400, height: 800))
        XCTAssertGreaterThan(e.session.appearance.measure, m)
    }
}

final class ToolbarTests: XCTestCase {
    func testButtonsReflectFormatState() {
        let bar = FormattingToolbar(frame: .zero)
        var s = EditorSession.emptyFormatState
        s.strong = true; s.headingLevel = 3; s.list = .task
        bar.update(s)
        XCTAssertEqual(Set(bar.litButtonLabels), ["Strong", "Task List"])
        XCTAssertEqual(bar.headingTitle, "Heading 3")
        bar.alphaValue = 0
        XCTAssertNil(bar.hitTest(NSPoint(x: 5, y: 5)), "hidden chrome never eats clicks")
    }
}
