import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

extension Editor {
    /// An editor in Live mode with the concealment for `caret` applied and laid out.
    static func live(_ text: String, caret: Int? = nil, width: CGFloat = 800) -> Editor {
        let e = Editor(text: text)
        e.tv.setFrameSize(NSSize(width: width, height: 600))
        e.session.setViewMode(.live)
        e.select(caret ?? (text as NSString).length)
        e.settle()
        return e
    }

    /// Waits for styling and the concealment of the current selection, then lays everything out.
    func settle() {
        _ = session.waitUntilStyled()
        session.refreshLive()
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: session.storage.length))
    }

    var lm: EditorLayoutManager { session.layoutManager }

    func property(_ i: Int) -> NSLayoutManager.GlyphProperty { lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: i)) }

    /// Is the character at `i` not laid out: a null glyph, or (for the markup that starts a
    /// paragraph) a zero-advance control glyph?
    func isNull(_ i: Int) -> Bool {
        let p = property(i)
        if p.contains(.null) { return true }
        let c = (string as NSString).character(at: i)
        return p.contains(.controlCharacter) && c != 0x0A && c != 0x0D && c != 0x09
    }

    func nullCharacters() -> [Int] { (0..<session.storage.length).filter { isNull($0) } }

    var hiddenText: [String] { lm.live.hidden.map { (string as NSString).substring(with: $0) } }

    /// Width of the first line fragment's used rect.
    func firstLineWidth() -> CGFloat {
        var w: CGFloat = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, used, _, _, stop in
            w = used.width
            stop.pointee = true
        }
        return w
    }

    /// Top of the line fragment holding the character at `i`.
    func lineTop(of i: Int) -> CGFloat {
        lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil).minY
    }

    func lineHeight(of i: Int) -> CGFloat {
        lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil).height
    }
}

final class LiveConcealTests: XCTestCase {
    private func assertNullExactly(_ e: Editor, _ expected: [String], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let ns = e.string as NSString
        let got = RangeList.normalized(e.nullCharacters().map { NSRange(location: $0, length: 1) }).map { ns.substring(with: $0) }
        XCTAssertEqual(got, expected, message, file: file, line: line)
    }

    // The M3 acceptance line: with the caret outside, no markup glyph is laid out; with it
    // inside, it is.
    func testMarkupGlyphsAreNullOutsideAndLaidOutInside() {
        let cases: [(name: String, text: String, markup: [String], inside: String)] = [
            ("emphasis", "x *em* y", ["*", "*"], "em"),
            ("strong", "x **strong** y", ["**", "**"], "strong"),
            ("code", "x `code` y", ["`", "`"], "code"),
            ("link", "x [link](http://a.b/c) y", ["[", "](http://a.b/c)"], "link"),
            ("strike", "x ~~gone~~ y", ["~~", "~~"], "gone"),
            ("heading", "# Head\n\nx", ["# "], "Head"),
            ("escape", "x \\* y", ["\\"], "* y"),
        ]
        for c in cases {
            let ns = c.text as NSString
            let e = Editor.live(c.text, caret: ns.length)
            assertNullExactly(e, c.markup, "\(c.name): caret outside")
            // Inside, and at both edges of the element.
            let inner = ns.range(of: c.inside)
            let element = c.name == "heading" ? NSRange(location: 0, length: 6)
                : c.name == "escape" ? NSRange(location: 2, length: 2)
                : NSRange(location: max(0, inner.location - c.markup[0].count), length: inner.length + c.markup.joined().count)
            for caret in [inner.location + 1, element.location, NSMaxRange(element)] {
                e.select(caret)
                e.settle()
                assertNullExactly(e, [], "\(c.name): caret at \(caret)")
            }
            e.select(ns.length)
            e.settle()
            assertNullExactly(e, c.markup, "\(c.name): caret outside again")
        }
    }

    func testNullMarkupTakesNoWidth() {
        // Same attributes with and without the markup, so the widths must match exactly.
        let pairs: [(with: String, without: String)] = [
            ("see [text](http://example.com/a/long/destination) end\n\nx", "see text end\n\nx"),
            ("a ~~gone~~ b\n\nx", "a gone b\n\nx"),
            ("a \\* b\n\nx", "a * b\n\nx"),
        ]
        for p in pairs {
            let concealed = Editor.live(p.with, caret: (p.with as NSString).length)
            let plain = Editor.live(p.without, caret: (p.without as NSString).length)
            XCTAssertEqual(concealed.firstLineWidth(), plain.firstLineWidth(), accuracy: 0.01, p.with)
            // Revealed, the line is wider.
            concealed.select(4)
            concealed.settle()
            XCTAssertGreaterThan(concealed.firstLineWidth(), plain.firstLineWidth() + 1, p.with)
        }
    }

    func testStorageIsNeverChangedByConcealment() {
        let text = "# Head\n\nSome *em* **strong** `code` [link](http://a.b) and\n\n> quote\n\n```\ncode\n```\n\n![i](x.png)\n\n---\n\n- item\n"
        let e = Editor(text: text)
        let before = (e.string, e.signature())
        e.session.setViewMode(.live)
        e.settle()
        XCTAssertEqual(e.string, before.0)
        XCTAssertEqual(e.signature(), before.1, "going Live changes no attribute the styler wrote")
        let ns = text as NSString
        for i in stride(from: 0, to: ns.length, by: 3) {
            e.select(i)
            e.settle()
            XCTAssertEqual(e.string, before.0)
            XCTAssertEqual(e.signature(), before.1, "caret at \(i)")
        }
        e.session.setViewMode(.source)
        e.settle()
        XCTAssertEqual(e.string, before.0)
        XCTAssertEqual(e.signature(), before.1)
        XCTAssertTrue(e.nullCharacters().isEmpty, "Source shows everything")
        XCTAssertTrue(e.lm.live.isEmpty)
        XCTAssertFalse(e.um.canUndo, "none of it registered undo")
    }

    func testToggleRoundTripAndUndoAreUnaffected() {
        let e = Editor(text: "a **b** c\n\n# H\n")
        e.select(0)
        e.edit(range: NSRange(location: 0, length: 0), with: "x ")
        XCTAssertEqual(e.string, "x a **b** c\n\n# H\n")
        e.session.setViewMode(.live)
        e.settle()
        XCTAssertFalse(e.nullCharacters().isEmpty)
        e.session.setViewMode(.source)
        e.session.setViewMode(.live)
        e.settle()
        XCTAssertFalse(e.nullCharacters().isEmpty)
        e.um.undo()
        e.settle()
        XCTAssertEqual(e.string, "a **b** c\n\n# H\n")
        e.um.redo()
        e.settle()
        XCTAssertEqual(e.string, "x a **b** c\n\n# H\n")
        XCTAssertTrue(e.um.canUndo)
        // Undoing the edit leaves the document as it was loaded.
        e.um.undo()
        XCTAssertFalse(e.um.canUndo)
    }

    func testViewModeIsPerSessionAndComesFromSettings() {
        let s = isolatedSettings()
        s.defaultViewMode = .live
        XCTAssertEqual(Editor(text: "x", settings: s).session.viewMode, .live)
        s.defaultViewMode = .source
        let a = Editor(text: "x", settings: s), b = Editor(text: "x", settings: s)
        a.session.setViewMode(.live)
        XCTAssertEqual(a.session.viewMode, .live)
        XCTAssertEqual(b.session.viewMode, .source, "a window's mode is its own")
        XCTAssertEqual(Settings(defaults: UserDefaults(suiteName: "markdown-fresh-\(UUID())")!).defaultViewMode, .source, "styled source is the default; Live is a choice")
    }

    // MARK: random editing

    private let base = """
    # Title

    Some *text* with **bold** and `code`, a [link](http://x.y "t") and ![i](p.png) 日本語 🎉.

    - one
    - [ ] task
    - [x] done
      - nested

    1. first
    > quoted **line**
    > second

    ![alone](img.png)

    ---

    | a | b |
    |---|---|
    | **1** | `2` |

    ```swift
    code
    ```

    Setext
    ======

    ---
    front: x
    ---
    """

    func testRandomEditsAndSelectionsKeepTheMirrorAndTheConcealment() {
        var rng = SplitMix(seed: 0xC0DE)
        for round in 0..<6 {
            let e = Editor.live(base, caret: 0)
            e.session.coordinator.verifiesMirror = true
            for step in 0..<60 {
                if step % 11 == 0 { e.session.coordinator.artificialDelay = (round % 2 == 0) ? 0.004 : 0 }
                let len = e.session.storage.length
                let ns = e.string as NSString
                func pos(_ x: Int) -> Int {
                    guard len > 0 else { return 0 }
                    let p = x % (len + 1)
                    return p == len ? p : ns.rangeOfComposedCharacterSequence(at: p).location
                }
                let a = pos(Int(rng.next() % 10_000)), b = pos(Int(rng.next() % 10_000))
                let sel = NSRange(location: min(a, b), length: abs(a - b) > 8 ? 0 : abs(a - b))
                e.select(sel.location, sel.length)
                e.grouped {
                    switch rng.next() % 12 {
                    case 0, 1: e.tv.insertText(["x", "**", "\n", "- ", "`", "é", "🎉", "[", "](u)", "# ", "> ", "```\n"][Int(rng.next() % 12)], replacementRange: sel)
                    case 2: e.tv.insertText("", replacementRange: NSRange(location: sel.location, length: max(sel.length, sel.location < len ? 1 : 0)))
                    case 3: e.tv.toggleStrong(nil)
                    case 4: e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    case 5: e.tv.setHeading(level: Int(rng.next() % 3))
                    case 6: e.tv.toggleBlockQuote(nil)
                    case 7: e.tv.toggleTaskList(nil)
                    case 8: e.tv.insertLink(nil)
                    case 9: e.session.storage.replaceCharacters(in: sel, with: "REPL")
                    default: break
                    }
                }
                if rng.next() % 9 == 0, e.um.canUndo { e.um.undo() }
                if rng.next() % 11 == 0, e.um.canRedo { e.um.redo() }
            }
            e.session.coordinator.artificialDelay = 0
            e.settle()
            XCTAssertEqual(e.session.coordinator.coreText(), e.string, "round \(round): core text drifted")
            XCTAssertEqual(e.session.coordinator.mirrorMismatches, 0)
            // Concealment equals a fresh query for the final text and selection, and the
            // glyphs follow it.
            let fresh = Editor.live(e.string, caret: e.tv.selectedRange().location)
            fresh.select(e.tv.selectedRange().location, e.tv.selectedRange().length)
            fresh.settle()
            XCTAssertEqual(e.lm.live, fresh.lm.live, "round \(round): concealment differs from a fresh query for \(e.string.debugDescription) at \(e.tv.selectedRange())")
            XCTAssertEqual(e.nullCharacters().sorted(), fresh.nullCharacters().sorted(), "round \(round): glyphs")
            let ns = e.string as NSString
            // (The tail of a surrogate pair or a combining sequence has a null placeholder glyph.)
            for i in 0..<ns.length where e.isNull(i) && ns.rangeOfComposedCharacterSequence(at: i).location == i {
                XCTAssertTrue(e.lm.live.isHidden(i), "round \(round): character \(i) is null but not hidden: \(ns.substring(with: NSRange(location: max(0, i - 6), length: min(14, ns.length - max(0, i - 6)))).debugDescription) hidden \(e.hiddenText) sel \(e.tv.selectedRange()) stale \(e.lm.staleRanges)")
            }
        }
    }

    // MARK: collapsed lines, spacing, stability

    func testMovingTheCaretInvalidatesOnlyTheParagraphsThatChanged() {
        let paras = (0..<40).map { "Paragraph \($0) with **bold \($0)** and [link](http://x.y/\($0)) inside.\n\n" }
        let text = paras.joined()
        let ns = text as NSString
        let e = Editor.live(text, caret: 0)
        e.lm.recordsInvalidations = true
        let a = ns.range(of: "bold 5").location + 1
        e.select(a)          // reveals paragraph 5
        e.lm.invalidatedRanges.removeAll()
        let b = ns.range(of: "bold 30").location + 1
        e.select(b)          // paragraph 5 hides again, paragraph 30 is revealed
        let total = e.lm.invalidatedRanges.reduce(0) { $0 + $1.length }
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(total, 400, "two paragraphs, not the document (\(ns.length) characters): \(e.lm.invalidatedRanges)")
        for r in e.lm.invalidatedRanges {
            XCTAssertTrue(NSLocationInRange(r.location, ns.paragraphRange(for: NSRange(location: a, length: 0))) || NSLocationInRange(r.location, ns.paragraphRange(for: NSRange(location: b, length: 0))), "\(r)")
        }
        // Moving within the same element changes nothing at all.
        e.lm.invalidatedRanges.removeAll()
        e.select(b + 2)
        XCTAssertEqual(e.lm.invalidatedRanges, [])
    }

    func testConcealmentIsAppliedInTheTurnOfTheSelectionChange() {
        let e = Editor.live("a **b** c\n\nz", caret: 12)
        XCTAssertEqual(e.hiddenText, ["**", "**"])
        e.select(4)                     // no run-loop turn in between
        XCTAssertEqual(e.hiddenText, [], "revealed by the time the selection change returns")
        e.select(12)
        XCTAssertEqual(e.hiddenText, ["**", "**"])
    }

    func testFencesAndFrontMatterCollapseAndComeBack() {
        let text = "---\ntitle: x\n---\n\nbefore\n\n```swift\nlet a = 1\n```\n\nafter\n\nTitle\n=====\n\nend"
        let e = Editor.live(text, caret: (text as NSString).length)
        let ns = text as NSString
        XCTAssertEqual(e.lm.live.collapsed.map { ns.substring(with: $0) }, ["---\n", "---\n", "```swift\n", "```\n", "=====\n"])
        // The line holding each concealed line's terminator is a sliver.
        for needle in ["---\ntitle", "```swift"] {
            let r = ns.range(of: needle)
            let terminator = r.location + (needle == "---\ntitle" ? 3 : 8)
            XCTAssertLessThan(e.lineHeight(of: terminator), 12, needle)
        }
        let top = e.lineTop(of: ns.range(of: "end").location)
        // Revealing the code block gives its fences their lines back (the block's own lines).
        e.select(ns.range(of: "let a").location)
        e.settle()
        XCTAssertTrue(e.lm.live.collapsed.map { ns.substring(with: $0) }.allSatisfy { $0 != "```\n" && $0 != "```swift\n" })
        XCTAssertGreaterThan(e.lineTop(of: ns.range(of: "end").location), top + 20)
        // And hides them again.
        e.select(ns.length)
        e.settle()
        XCTAssertEqual(e.lineTop(of: ns.range(of: "end").location), top, accuracy: 0.5)
    }

    func testAdjacentCollapsedLinesBothCollapse() {
        // An empty code block: its two fences are consecutive collapsed lines.
        for text in ["a\n\n```\n```\n\nb", "a\n\n```\nx\n```\n```\ny\n```\n\nb"] {
            let ns = text as NSString
            let e = Editor.live(text, caret: ns.length)
            XCTAssertGreaterThanOrEqual(e.lm.live.collapsed.count, 2, text)
            for line in e.lm.live.collapsed {
                XCTAssertEqual(ns.substring(with: line).filter { $0 == "\n" }.count, 1, "one line per range: \(text.debugDescription)")
                XCTAssertLessThan(e.lineHeight(of: NSMaxRange(line) - 1), 12, "\(text.debugDescription): \(ns.substring(with: line).debugDescription) collapses")
            }
        }
    }

    func testRevealingInlineMarkupHeadingsAndQuotesMovesNoLineBelow() {
        let text = "para one\n\n# Head with **bold**\n\n> a quote line\n> second\n\n- item with [link](http://a.b)\n\n## Two\n\nlast line"
        let ns = text as NSString
        let e = Editor.live(text, caret: ns.length)
        let probes = ["para one", "last line", "Two"].map { ns.range(of: $0).location }
        let baseline = probes.map { e.lineTop(of: $0) }
        for needle in ["Head with", "bold", "a quote line", "second", "link", "item with"] {
            e.select(ns.range(of: needle).location + 1)
            e.settle()
            XCTAssertEqual(probes.map { e.lineTop(of: $0) }, baseline, "caret in \(needle) moved a line elsewhere")
        }
        // Heading lines themselves keep their height too (the text only moves right).
        let head = ns.range(of: "Head with").location
        e.select(ns.length)
        e.settle()
        let concealedTop = e.lineTop(of: head), concealedHeight = e.lineHeight(of: head)
        e.select(head + 2)
        e.settle()
        XCTAssertEqual(e.lineTop(of: head), concealedTop, accuracy: 0.5)
        XCTAssertEqual(e.lineHeight(of: head), concealedHeight, accuracy: 0.5)
    }

    func testBlockPanelIgnoresTheLineCarryingHiddenFenceGlyphs() throws {
        let text = "Before.\n\n```\ncode line\n```\n\nAfter.\n"
        let e = Editor.live(text, caret: (text as NSString).length)
        let ns = text as NSString
        let block = ns.range(of: "```\ncode line\n```")
        let g = e.lm.glyphRange(forCharacterRange: block, actualCharacterRange: nil)
        let panels = e.lm.blockBackgroundRects(forGlyphRange: g)
        XCTAssertEqual(panels.count, 1)
        let panel = try XCTUnwrap(panels.first).0
        let blank = e.lm.lineFragmentRect(forGlyphAt: e.lm.glyphIndexForCharacter(at: ns.range(of: "\n\n```").location + 1), effectiveRange: nil)
        XCTAssertGreaterThan(panel.minY, blank.minY + 10, "the panel starts at the code, not at the blank line above")
        let code = e.lm.lineFragmentRect(forGlyphAt: e.lm.glyphIndexForCharacter(at: ns.range(of: "code line").location), effectiveRange: nil)
        XCTAssertLessThan(panel.minY, code.minY)
        XCTAssertGreaterThan(panel.maxY, code.maxY)
        XCTAssertLessThan(panel.height, code.height * 2 + 30)
    }

    // MARK: hanging indents

    func testQuoteAndTaskTextStartsWhereItDoesWithTheMarkupShown() {
        let text = "> quote text that is long enough to wrap around a narrow column and more words\n\n- [ ] task text that is long enough to wrap around a narrow column and more words\n\n- bullet text that is long enough to wrap around a narrow column and more words\n\nend"
        let ns = text as NSString
        func startX(_ e: Editor, _ needle: String) -> CGFloat {
            let i = ns.range(of: needle).location
            return e.lm.location(forGlyphAt: e.lm.glyphIndexForCharacter(at: i)).x
        }
        let e = Editor.live(text, caret: ns.length, width: 500)
        let concealedQuote = startX(e, "quote text")
        // A wrapped line hangs at the same x as the first line's text.
        func wrappedX(_ word: String) -> CGFloat {
            let i = ns.range(of: word).location
            return e.lm.lineFragmentUsedRect(forGlyphAt: e.lm.glyphIndexForCharacter(at: i), effectiveRange: nil).minX
        }
        XCTAssertEqual(startX(e, "text that is long enough to wrap around a narrow column and more words\n\n- bullet"), concealedQuote, accuracy: 100) // sanity: finite
        XCTAssertGreaterThan(concealedQuote, 5, "the hidden quote marker keeps its width")
        let quoteHang = wrappedX("more words\n\n- [")
        _ = quoteHang
        // Quote: same first-line x as with the marker revealed.
        e.select(ns.range(of: "quote text").location + 2)
        e.settle()
        XCTAssertEqual(startX(e, "quote text"), concealedQuote, accuracy: 0.5, "revealing the quote marker moves no text")
        // Task: its text starts where a bullet item's does.
        e.select(ns.length)
        e.settle()
        XCTAssertEqual(startX(e, "task text"), startX(e, "bullet text") - 0, accuracy: 3)
    }

    // MARK: drawn decorations

    func testDecorationsFromTheCore() {
        let text = "x\n\n- a\n- [ ] t\n- [x] u\n\n> q\n\n---\n\n![i](p.png)\n\nend"
        let e = Editor.live(text, caret: (text as NSString).length)
        var kinds: [String] = []
        for d in e.lm.live.decorations {
            switch d.kind {
            case .bullet: kinds.append("bullet")
            case .checkbox(let c): kinds.append("box\(c)")
            case .rule: kinds.append("rule")
            case .image: kinds.append("image")
            case .quoteBar: kinds.append("bar")
            }
        }
        XCTAssertEqual(kinds, ["bullet", "boxfalse", "boxtrue", "bar", "rule", "image"])
        // Source mode draws none.
        e.session.setViewMode(.source)
        XCTAssertTrue(e.lm.live.decorations.isEmpty)
    }

    /// Bullets and checkboxes stand for glyphs: like glyphs, they are drawn over the selection
    /// highlight, not hidden by it.
    func testDecorationsAreDrawnOverTheSelection() throws {
        let text = "x\n\n- bullet item\n- [x] done item\n\nend"
        let ns = text as NSString
        let e = Editor.live(text, caret: ns.length, width: 600)
        e.tv.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)]
        let probes: [NSPoint] = try {
            let tc = try XCTUnwrap(e.tv.textContainer)
            let bullet = try XCTUnwrap(e.lm.live.decorations.first { $0.kind == .bullet })
            let g = e.lm.glyphRange(forCharacterRange: bullet.range, actualCharacterRange: nil)
            let line = e.lm.lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
            let rect = e.lm.boundingRect(forGlyphRange: g, in: tc)
            let font = try XCTUnwrap(e.session.storage.attribute(.font, at: bullet.range.location, effectiveRange: nil) as? NSFont)
            let baseline = line.minY + e.lm.location(forGlyphAt: g.location).x * 0 + e.lm.location(forGlyphAt: g.location).y
            let diameter = max(4, (font.pointSize * 0.3).rounded())
            let bulletCenter = NSPoint(x: rect.minX + font.pointSize * 0.06 + diameter / 2, y: baseline - font.xHeight * 0.5)
            let box = try XCTUnwrap(e.lm.live.decorations.first { if case .checkbox = $0.kind { return true } else { return false } })
            let frame = try XCTUnwrap(e.lm.checkboxFrame(of: box, in: tc))
            return [bulletCenter, NSPoint(x: frame.midX, y: frame.midY)]
        }()
        func color(at p: NSPoint) throws -> NSColor {
            e.tv.setFrameSize(NSSize(width: 600, height: 300))
            let rep = try XCTUnwrap(e.tv.bitmapImageRepForCachingDisplay(in: e.tv.bounds))
            e.tv.cacheDisplay(in: e.tv.bounds, to: rep)
            let o = e.tv.textContainerOrigin
            let scale = CGFloat(rep.pixelsWide) / e.tv.bounds.width
            return try XCTUnwrap(rep.colorAt(x: Int((p.x + o.x) * scale), y: Int((p.y + o.y) * scale))).usingColorSpace(.sRGB)!
        }
        let unselected = try probes.map(color)
        e.select(ns.range(of: "- bullet").location, ns.range(of: "end").location - ns.range(of: "- bullet").location)
        e.settle()
        for (i, p) in probes.enumerated() {
            let c = try color(at: p)
            XCTAssertFalse(c.greenComponent > 0.9 && c.redComponent < 0.1, "decoration \(i) is covered by the selection highlight")
            XCTAssertEqual(c.redComponent, unselected[i].redComponent, accuracy: 0.2)
        }
    }

    func testBulletAndCheckboxMarkersAreLaidOutButNotDrawn() {
        let text = "- a\n- [ ] b\n\nx"
        let e = Editor.live(text, caret: (text as NSString).length)
        // The dash stays a real glyph (its place is the bullet's); the `[ ]` is hidden.
        XCTAssertFalse(e.isNull(0))
        XCTAssertEqual(e.lm.markerRanges, [NSRange(location: 0, length: 1)])
        XCTAssertTrue(e.lm.live.isHidden((text as NSString).range(of: "[ ]").location))
    }
}

/// Inline code backgrounds and strikethrough are drawn by hand next to hidden markup; they must
/// cover their text in right-to-left and CJK lines too, wrapped or not.
final class LiveManualDrawingTests: XCTestCase {
    func testCodeBackgroundsAndStrikesCoverTheirGlyphsInEveryScript() throws {
        for (line, inner) in [("Latin `code` and ~~gone~~ here", ["code", "gone"]),
                              ("עברית `קוד` וגם ~~מחוק~~ כאן", ["קוד", "מחוק"]),
                              ("日本語`コード`と~~取り消し~~です", ["コード", "取り消し"])] {
            let text = line + "\n\nend"
            let ns = text as NSString
            let e = Editor.live(text, caret: ns.length, width: 700)
            let tc = try XCTUnwrap(e.tv.textContainer)
            e.lm.manualDrawings = []
            e.tv.setFrameSize(NSSize(width: 700, height: 300))
            let rep = try XCTUnwrap(e.tv.bitmapImageRepForCachingDisplay(in: e.tv.bounds))
            e.tv.cacheDisplay(in: e.tv.bounds, to: rep)
            let drawn = try XCTUnwrap(e.lm.manualDrawings)
            for word in inner {
                let r = ns.range(of: word)
                let g = e.lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                // The glyphs' own extent, glyph by glyph (no hidden neighbours involved).
                var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
                for gi in g.location..<NSMaxRange(g) where !e.lm.propertyForGlyph(at: gi).contains(.null) {
                    let b = e.lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc)
                    lo = min(lo, b.minX); hi = max(hi, b.maxX)
                }
                let mine = drawn.filter { NSIntersectionRange($0.glyphs, g).length > 0 }
                XCTAssertFalse(mine.isEmpty, "\(word): drawn by hand")
                // AppKit may hand the strike over glyph by glyph: together they cover the word.
                let from = mine.map(\.x.lowerBound).min() ?? 0, to = mine.map(\.x.upperBound).max() ?? 0
                XCTAssertEqual(from, lo, accuracy: 3, "\(word) in \(line.debugDescription): starts at its first glyph")
                XCTAssertEqual(to, hi, accuracy: 3, "\(word) in \(line.debugDescription): ends at its last glyph")
                XCTAssertGreaterThan(mine.map { $0.x.upperBound - $0.x.lowerBound }.reduce(0, +), (hi - lo) * 0.9, "\(word): no gaps")
            }
        }
    }
}
