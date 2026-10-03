import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Code highlighting in the editor (M8c): the colours the styler stores, the language badge, its menu
/// and the edit the menu makes, and what themes, Live mode and focus mode do with them.
final class CodeHighlightTests: XCTestCase {
    private let doc = """
    Some prose first, long enough to be a paragraph of its own.

    ```rust
    // a comment
    fn main() {
        let n = 42; let s = "text";
    }
    ```

    ```nosuchlanguage
    fn plain() {}
    ```

    ```
    fn nolanguage() {}
    ```

    Closing prose.

    """

    private func colour(_ e: Editor, _ needle: String, offset: Int = 0) -> String? {
        let r = (e.string as NSString).range(of: needle)
        precondition(r.location != NSNotFound, needle)
        return (e.session.storage.attribute(.foregroundColor, at: r.location + offset, effectiveRange: nil) as? NSColor)?.hexString
    }

    private func syntax(_ e: Editor) -> ThemePalette.SyntaxColors { e.session.appearance.palette.syntax }

    // MARK: colours

    func testRolesBecomeStoredForegroundColours() {
        let e = Editor(text: doc)
        let p = e.session.appearance.palette
        let s = p.syntax
        XCTAssertEqual(colour(e, "// a comment"), s.comment.hexString)
        XCTAssertEqual(colour(e, "fn main"), s.keyword.hexString)
        XCTAssertEqual(colour(e, "main()"), s.function.hexString)
        XCTAssertEqual(colour(e, "42"), s.number.hexString)
        XCTAssertEqual(colour(e, "\"text\""), s.string.hexString)
        // What the highlighter leaves plain keeps the code colour; the font is the code font throughout.
        XCTAssertEqual(colour(e, "{\n    let", offset: 0), p.codeText.hexString)
        let font = e.session.storage.attribute(.font, at: (e.string as NSString).range(of: "fn main").location, effectiveRange: nil) as? NSFont
        let plain = e.session.storage.attribute(.font, at: (e.string as NSString).range(of: "{\n    let").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font, plain)
        XCTAssertTrue(font?.isFixedPitch ?? false)
        // Blocks with no language or an unknown one, prose, and the fences' markup are not coloured by roles.
        XCTAssertEqual(colour(e, "fn plain"), p.codeText.hexString)
        XCTAssertEqual(colour(e, "fn nolanguage"), p.codeText.hexString)
        XCTAssertEqual(colour(e, "Closing prose"), p.text.hexString)
        XCTAssertEqual(colour(e, "```rust"), p.markup.hexString)
        XCTAssertEqual(colour(e, "rust\n", offset: 0), p.markup.hexString, "the info string stays dim")
    }

    func testOnlyKnownLanguagesCarryTheBadgeAttribute() {
        let e = Editor(text: doc)
        let ns = e.string as NSString
        let lang = { (needle: String) in e.session.storage.attribute(.markdownCodeLanguage, at: ns.range(of: needle).location, effectiveRange: nil) as? String }
        XCTAssertEqual(lang("fn main"), "Rust")
        XCTAssertEqual(lang("```rust"), "Rust")
        XCTAssertNil(lang("fn plain"))
        XCTAssertNil(lang("fn nolanguage"))
        XCTAssertNil(lang("Closing prose"))
    }

    func testAnEditInsideABlockRestylesTheWholeBlock() {
        // Opening a block comment on the first line changes the colours of lines the dirty range does not name.
        let e = Editor(text: doc)
        let at = (e.string as NSString).range(of: "// a comment").location
        e.edit(range: NSRange(location: at, length: 2), with: "/*")
        XCTAssertTrue(e.session.waitUntilStyled())
        let fresh = Editor(text: e.string)
        XCTAssertEqual(e.signature(), fresh.signature())
        XCTAssertEqual(colour(e, "fn main"), syntax(e).comment.hexString, "everything after the opener is a comment now")
        // And back.
        e.edit(range: NSRange(location: at, length: 2), with: "//")
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(e.signature(), Editor(text: e.string).signature())
        XCTAssertEqual(colour(e, "fn main"), syntax(e).keyword.hexString)
    }

    func testChangingTheLanguageInTheInfoStringRecolours() {
        let e = Editor(text: doc)
        let r = (e.string as NSString).range(of: "rust")
        e.edit(range: r, with: "nosuchlanguage")
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(colour(e, "fn main"), e.session.appearance.palette.codeText.hexString)
        XCTAssertNil(e.session.storage.attribute(.markdownCodeLanguage, at: (e.string as NSString).range(of: "fn main").location, effectiveRange: nil))
        XCTAssertEqual(e.signature(), Editor(text: e.string).signature())
    }

    func testFastTypingEndsWithTheStylingOfAFreshAnalysis() {
        let e = Editor(text: doc)
        e.session.coordinator.artificialDelay = 0.03
        let at = (e.string as NSString).range(of: "let n").location
        for (i, ch) in "let m = 7; // x\n".enumerated() {
            e.edit(range: NSRange(location: at + i, length: 0), with: String(ch))
        }
        e.session.coordinator.artificialDelay = 0
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(e.signature(), Editor(text: e.string).signature())
    }

    /// A block longer than the analysis queue fetches inline (`maxInlineSpanRange`): an edit in it widens to the whole
    /// block, too long to fetch with the edit, so the colours come through the styling debt in pieces. Opening a block
    /// comment on its first line must still recolour its last line, and closing it again restore it, as a fresh document
    /// styles them (the colours and the language attribute alike), also with results arriving late.
    func testABlockLongerThanTheInlineRangeIsRestyledWholeThroughTheDebt() {
        // Comments, which the highlighter takes quickly even in a debug build (a block that misses the query's time
        // budget is plain: see PLAN, "From the test pass" of M8c).
        let lines = (0..<420).map { "# line \($0): a comment long enough that the block outgrows the inline range" }.joined(separator: "\n")
        let text = "Intro.\n\n```python\nfirst = 1\n\(lines)\nlast = 'end'\n```\n\nAfter.\n"
        XCTAssertGreaterThan((text as NSString).length, AnalysisCoordinator.maxInlineSpanRange)
        let e = Editor(text: text)
        XCTAssertTrue(e.session.waitUntilStyled(timeout: 60))
        func languages(_ e: Editor) -> [String] {
            var out: [String] = []
            e.session.storage.enumerateAttribute(.markdownCodeLanguage, in: NSRange(location: 0, length: e.session.storage.length)) { v, r, _ in
                out.append("\(r) \(v as? String ?? "-")")
            }
            return out
        }
        XCTAssertEqual(colour(e, "'end'"), syntax(e).string.hexString)
        XCTAssertEqual(colour(e, "# line 300"), syntax(e).comment.hexString)
        // Opening a string on the first line: every line after it is the string's, the last one included.
        let at = (e.string as NSString).range(of: "first = 1").location + 8
        e.session.coordinator.artificialDelay = 0.02
        for (i, ch) in "\"\"\"".enumerated() { e.edit(range: NSRange(location: at + i, length: 0), with: String(ch)) }
        e.session.coordinator.artificialDelay = 0
        XCTAssertTrue(e.session.waitUntilStyled(timeout: 60))
        XCTAssertEqual(colour(e, "# line 300"), syntax(e).string.hexString, "the rest of the block is a string now")
        XCTAssertEqual(colour(e, "last = "), syntax(e).string.hexString)
        let fresh = Editor(text: e.string)
        XCTAssertTrue(fresh.session.waitUntilStyled(timeout: 60))
        XCTAssertEqual(e.signature(), fresh.signature())
        XCTAssertEqual(languages(e), languages(fresh))
        // And closed again.
        e.edit(range: NSRange(location: at, length: 3), with: "")
        XCTAssertTrue(e.session.waitUntilStyled(timeout: 60))
        XCTAssertEqual(colour(e, "# line 300"), syntax(e).comment.hexString)
        XCTAssertEqual(colour(e, "'end'"), syntax(e).string.hexString)
        XCTAssertEqual(e.signature(), Editor(text: text).signature())
    }

    func testAThemeSwitchRecolours() {
        let e = Editor(text: doc)
        let light = colour(e, "fn main")
        e.session.settings.theme = .dark
        e.session.refreshAppearance()
        XCTAssertTrue(e.session.waitUntilStyled())
        let dark = colour(e, "fn main")
        XCTAssertNotEqual(light, dark)
        XCTAssertEqual(dark, ThemeStore.shared.palette(ThemeStore.shared.theme(id: "dark")).syntax.keyword.hexString)
        XCTAssertEqual(colour(e, "42"), ThemeStore.shared.palette(ThemeStore.shared.theme(id: "dark")).syntax.number.hexString)
        XCTAssertEqual(e.signature(), Editor(text: doc, settings: e.session.settings).signature())
        e.session.settings.theme = .sepia
        e.session.refreshAppearance()
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(colour(e, "fn main"), ThemeStore.shared.palette(ThemeStore.shared.theme(id: "sepia")).syntax.keyword.hexString)
        // The badge follows too.
        e.tv.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertEqual(e.lm.palette?.id, "sepia")
    }

    // MARK: badges

    private func laidOut(_ text: String, live: Bool = false, caret: Int? = nil, width: CGFloat = 800) -> Editor {
        let e = live ? Editor.live(text, caret: caret, width: width) : Editor(text: text)
        if !live { e.tv.setFrameSize(NSSize(width: width, height: 600)); e.select(caret ?? 0) }
        e.settle()
        return e
    }

    private func badges(_ e: Editor, ignoringCaret: Bool = false) -> [CodeBadge] {
        e.lm.codeBadges(forGlyphRange: NSRange(location: 0, length: e.lm.numberOfGlyphs), ignoringCaret: ignoringCaret)
    }

    func testOneBadgePerKnownLanguageAtThePanelsTopRight() {
        let e = laidOut(doc, caret: 3)
        let found = badges(e)
        XCTAssertEqual(found.map(\.text), ["Rust"], "none for an unknown language or for none")
        let panels = e.lm.blockPanels(forGlyphRange: NSRange(location: 0, length: e.lm.numberOfGlyphs))
        XCTAssertEqual(panels.count, 3)
        let panel = panels[0]
        let b = found[0]
        XCTAssertTrue(panel.rect.contains(b.frame), "inside the chip")
        XCTAssertEqual(b.frame.maxX, panel.rect.maxX - EditorLayoutManager.badgeMargin.width, accuracy: 1)
        XCTAssertEqual(b.frame.minY, panel.rect.minY + EditorLayoutManager.badgeMargin.height, accuracy: 1)
        XCTAssertEqual(b.fill.hexString, e.session.appearance.palette.codeBackground.hexString, "a pill of the chip's colour")
        XCTAssertEqual(b.block.location, (e.string as NSString).range(of: "```rust").location)
    }

    func testTheBadgeIsDrawnAndItsPixelsAreThePillsAndTheName() throws {
        let e = laidOut(doc, caret: 3)
        let b = try XCTUnwrap(badges(e).first)
        let origin = e.tv.textContainerOrigin
        let frame = b.frame.offsetBy(dx: origin.x, dy: origin.y)
        let rep = try XCTUnwrap(e.tv.bitmapImageRepForCachingDisplay(in: e.tv.bounds))
        e.tv.cacheDisplay(in: e.tv.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / e.tv.bounds.width
        func pixel(_ x: CGFloat, _ y: CGFloat) -> String {
            (rep.colorAt(x: Int(x * scale), y: Int(y * scale)) ?? .clear).hexString
        }
        // The pill's corner area has the chip's colour; somewhere inside it there is ink for the name.
        XCTAssertEqual(pixel(frame.minX + 3, frame.midY), b.fill.hexString)
        var ink = 0
        var y = frame.minY + 2
        while y < frame.maxY - 2 {
            var x = frame.minX + 4
            while x < frame.maxX - 4 { if pixel(x, y) != b.fill.hexString { ink += 1 }; x += 1 }
            y += 1
        }
        XCTAssertGreaterThan(ink, 20)
    }

    /// The first visible line fragment of the first block: its line rect, where its text ends and its characters.
    private func firstFragment(_ e: Editor) -> (line: NSRect, textEnd: CGFloat, characters: NSRange)? {
        e.lm.blockPanels(forGlyphRange: NSRange(location: 0, length: e.lm.numberOfGlyphs)).first?.firstLine
    }

    /// Where the insertion point is, horizontally, at `loc` on the first fragment (computed from the glyphs, not the badge's own rule).
    private func caretX(_ e: Editor, _ loc: Int, _ f: (line: NSRect, textEnd: CGFloat, characters: NSRange)) -> CGFloat {
        if loc >= NSMaxRange(f.characters) { return f.line.minX + f.textEnd }
        let g = e.lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1), actualCharacterRange: nil)
        return e.lm.boundingRect(forGlyphRange: g, in: e.tv.textContainer!).minX
    }

    func testTheBadgeNeverHidesTheInsertionPointOnTheFirstLine() throws {
        // Source mode: the first line is the fence's. A long info string, unbroken, fills the line under the pill.
        let long = "```rust,\(String(repeating: "attribute", count: 14))\nfn a() {}\n```\n"
        let e = laidOut(long, width: 700)
        let f = try XCTUnwrap(firstFragment(e))
        XCTAssertEqual(badges(e, ignoringCaret: true).count, 1)
        var hidden = 0, shown = 0
        for loc in f.characters.location...NSMaxRange(f.characters) {
            e.select(loc)
            if let b = badges(e).first {
                shown += 1
                let x = caretX(e, loc, f)
                XCTAssertFalse(x >= b.frame.minX - 1 && x <= b.frame.maxX + 1, "caret at \(loc) (x \(x)) is under the badge \(b.frame)")
            } else {
                hidden += 1
            }
        }
        XCTAssertGreaterThan(hidden, 0, "the caret's line does reach the badge")
        XCTAssertGreaterThan(shown, 0, "and the badge is there while the caret is further left")
        // On a later line of the same block, or outside it, the badge is back; while it is hidden a click where it would be hits nothing.
        e.select(NSMaxRange(f.characters))
        XCTAssertTrue(badges(e).isEmpty)
        let hiddenFrame = try XCTUnwrap(badges(e, ignoringCaret: true).first).frame
        let viewPoint = NSPoint(x: hiddenFrame.midX + e.tv.textContainerOrigin.x, y: hiddenFrame.midY + e.tv.textContainerOrigin.y)
        XCTAssertNil(e.tv.codeBadge(at: viewPoint))
        e.select((e.string as NSString).range(of: "fn a").location)
        XCTAssertEqual(badges(e).count, 1)
        XCTAssertNotNil(e.tv.codeBadge(at: viewPoint))
    }

    func testTheBadgeStaysWhenTheFirstLineIsShort() {
        let e = laidOut(doc, caret: 3)
        let fence = (e.string as NSString).range(of: "```rust")
        for loc in fence.location...NSMaxRange(fence) {
            e.select(loc)
            XCTAssertEqual(badges(e).count, 1, "caret at \(loc - fence.location)")
        }
    }

    func testLiveModeKeepsTheBadgeAtTheTopRightWithTheFencesConcealed() {
        let e = laidOut(doc, live: true, caret: 3)
        let fence = (e.string as NSString).range(of: "```rust")
        XCTAssertTrue(e.lm.live.isHidden(fence.location), "the fence is concealed")
        let b = badges(e)
        XCTAssertEqual(b.map(\.text), ["Rust"])
        let panel = e.lm.blockPanels(forGlyphRange: NSRange(location: 0, length: e.lm.numberOfGlyphs))[0]
        XCTAssertEqual(b[0].frame.maxX, panel.rect.maxX - EditorLayoutManager.badgeMargin.width, accuracy: 1)
        // The panel starts at the first code line, not at the collapsed fence.
        let codeTop = e.lineTop(of: (e.string as NSString).range(of: "// a comment").location)
        XCTAssertEqual(panel.rect.minY, codeTop - EditorLayoutManager.blockOutset.height, accuracy: 1.5)
        XCTAssertEqual(b[0].frame.minY, panel.rect.minY + EditorLayoutManager.badgeMargin.height, accuracy: 1)
        // Caret on the first code line, whose text is short: the badge stays; the fence stays concealed? (it reveals with the caret on its line only)
        e.select((e.string as NSString).range(of: "// a comment").location + 4)
        e.settle()
        XCTAssertEqual(badges(e).count, 1)
    }

    func testInLiveModeTheCaretInABlockRevealsTheFencesSoTheBadgeNeverCoversIt() throws {
        // With the fences concealed the caret is outside the block; once it is inside they are shown, so the first
        // line is the short fence line, and a long first code line is never the caret's first line under the pill.
        let text = "```js\nconst_" + String(repeating: "x", count: 120) + " = 1;\nlet b = 1;\n```\n"
        let e = laidOut(text, live: true, caret: nil, width: 640)
        let concealed = try XCTUnwrap(firstFragment(e))
        XCTAssertGreaterThan(concealed.characters.location, 0, "the fence is concealed: the first line is the code's")
        XCTAssertEqual(badges(e).count, 1, "the caret is outside the block")
        for loc in 0...(text as NSString).length {
            e.select(loc)
            e.settle()
            guard let f = firstFragment(e) else { continue }
            let shown = badges(e)
            let x = caretX(e, loc, f)
            if let b = shown.first, loc >= f.characters.location, loc <= NSMaxRange(f.characters) {
                XCTAssertFalse(x >= b.frame.minX - 1 && x <= b.frame.maxX + 1, "caret at \(loc) is under the badge")
            }
            if loc > 6 && loc < (text as NSString).range(of: "```\n", options: .backwards).location {
                XCTAssertEqual(f.characters.location, 0, "the caret is in the block: its fences are shown (caret \(loc))")
            }
        }
    }

    func testClickingTheBadgeHitsItAndOnlyIt() throws {
        let e = laidOut(doc, caret: 3)
        e.session.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: e.session.storage.length))
        let b = try XCTUnwrap(badges(e).first)
        let o = e.tv.textContainerOrigin
        XCTAssertNotNil(e.tv.codeBadge(at: NSPoint(x: b.frame.midX + o.x, y: b.frame.midY + o.y)))
        XCTAssertNil(e.tv.codeBadge(at: NSPoint(x: b.frame.minX - 40 + o.x, y: b.frame.midY + o.y)))
        XCTAssertNil(e.tv.codeBadge(at: NSPoint(x: b.frame.midX + o.x, y: b.frame.maxY + 30 + o.y)))
    }

    // MARK: the menu

    func testTheMenuListsCommonLanguagesThenAllByLetter() {
        let e = laidOut(doc, caret: 3)
        let menu = e.tv.codeLanguageMenu(current: "Rust")
        let items = menu.items
        let sepAt = items.firstIndex { $0.isSeparatorItem }
        XCTAssertEqual(sepAt, codeLanguageChoices().filter(\.common).count)
        XCTAssertGreaterThanOrEqual(sepAt ?? 0, 25)
        XCTAssertEqual(items[0].title, "Rust")
        XCTAssertEqual(items[0].state, .on)
        XCTAssertEqual(items.filter { $0.state == .on }.count, 1)
        let all = items.last
        XCTAssertEqual(all?.title, "All")
        let letters = all?.submenu?.items.map(\.title) ?? []
        XCTAssertEqual(letters, letters.sorted { a, b in a == "#" ? false : b == "#" ? true : a < b })
        XCTAssertTrue(letters.contains("P") && letters.contains("R"))
        let total = all?.submenu?.items.reduce(0) { $0 + ($1.submenu?.items.count ?? 0) } ?? 0
        XCTAssertEqual(total, codeLanguageChoices().count)
        for g in all?.submenu?.items ?? [] {
            for i in g.submenu?.items ?? [] { XCTAssertEqual(i.title.first.map { String($0).uppercased() }, g.title, i.title) }
        }
        XCTAssertNotNil(all?.submenu?.items.first { $0.title == "R" }?.submenu?.items.first { $0.title == "Ruby" })
    }

    func testChoosingALanguageIsOneUndoableEditAndKeepsTheSelection() throws {
        let e = laidOut(doc, caret: 3)
        var presented: (NSMenu, NSPoint)?
        e.tv.codeMenuPresenter = { presented = ($0, $1) }
        let b = try XCTUnwrap(badges(e).first)
        let o = e.tv.textContainerOrigin
        let click = NSPoint(x: b.frame.midX + o.x, y: b.frame.midY + o.y)
        XCTAssertTrue(e.tv.handleBadgeClick(at: click))
        let menu = try XCTUnwrap(presented?.0)
        XCTAssertEqual(e.string, doc, "a click alone changes nothing")
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 3, length: 0), "and leaves the caret")
        // "Python" in the All submenu, under P.
        let python = try XCTUnwrap(menu.items.first { $0.title == "Python" })
        let afterUndoDepth = e.um.canUndo
        e.grouped { e.tv.chooseCodeLanguage(python) }
        XCTAssertEqual(e.string, doc.replacingOccurrences(of: "```rust", with: "```python"))
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(badges(e).map(\.text), ["Python"])
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(e.signature(), Editor(text: e.string).signature())
        XCTAssertEqual(e.um.undoActionName, "Change Code Language")
        e.um.undo()
        XCTAssertEqual(e.string, doc, "one undo restores the info string")
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(badges(e).map(\.text), ["Rust"])
        e.um.redo()
        XCTAssertEqual(e.string, doc.replacingOccurrences(of: "```rust", with: "```python"))
        _ = afterUndoDepth
    }

    func testChoosingKeepsTheAttributesAfterTheLanguage() {
        let text = "```rust,ignore title=x\nfn a() {}\n```\n"
        let e = laidOut(text, caret: 5)
        e.tv.setCodeLanguage("go", inBlock: NSRange(location: 0, length: 10))
        XCTAssertEqual(e.string, "```go,ignore title=x\nfn a() {}\n```\n")
        // Choosing the language it already has changes nothing and registers nothing.
        let e2 = laidOut(doc, caret: 3)
        e2.um.removeAllActions()
        e2.tv.setCodeLanguage("rust", inBlock: NSRange(location: (doc as NSString).range(of: "```rust").location, length: 5))
        XCTAssertEqual(e2.string, doc)
        XCTAssertFalse(e2.um.canUndo)
    }

    func testTheMenuEditWorksInLiveModeWithTheFencesConcealed() throws {
        let e = laidOut(doc, live: true, caret: 3)
        let b = try XCTUnwrap(badges(e).first)
        e.grouped { e.tv.setCodeLanguage("python", inBlock: b.block) }
        XCTAssertTrue(e.string.contains("```python\n"))
        e.settle()
        XCTAssertEqual(badges(e).map(\.text), ["Python"])
        e.um.undo()
        XCTAssertEqual(e.string, doc)
    }

    // MARK: accessibility

    func testTheBadgeIsAnAccessibilityButtonThatOpensTheMenu() throws {
        let e = laidOut(doc, caret: 3)
        var presented = 0
        e.tv.codeMenuPresenter = { _, _ in presented += 1 }
        let children = e.tv.accessibilityChildren() ?? []
        let element = try XCTUnwrap(children.compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Language: Rust" })
        XCTAssertEqual(element.accessibilityRole(), .button)
        XCTAssertTrue(element.isAccessibilityElement())
        XCTAssertTrue(element.accessibilityPerformPress())
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(children.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }.filter { $0.hasPrefix("Language:") }.count, 1)
    }

    /// VoiceOver tells elements apart by identity: asking for the children again (it does, after every change it is told
    /// of) must give the same button, or its place on the badge is lost. And the pointer over the badge names the button.
    func testTheBadgesButtonIsOneObjectAndThePointerOverTheBadgeFindsIt() throws {
        let e = laidOut(doc, caret: 3)
        func button() -> NSAccessibilityElement? {
            (e.tv.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Language: Rust" }
        }
        let first = try XCTUnwrap(button())
        XCTAssertTrue(first === button(), "the same element when asked again")
        e.select(40)
        e.settle()
        XCTAssertTrue(first === button(), "and after the caret moved")
        // A language change is another button.
        let block = try XCTUnwrap(first as? CodeBadgeElement).block
        e.grouped { e.tv.setCodeLanguage("python", inBlock: block) }
        e.settle()
        let python = (e.tv.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.first { $0.accessibilityLabel() == "Language: Python" }
        XCTAssertNotNil(python)
        e.um.undo()
        e.settle()

        // In a window: the screen point over the pill is the button's, a point beside it the text's.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 820, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 620))
        scroll.documentView = e.tv
        window.contentView = scroll
        defer { scroll.documentView = nil; window.orderOut(nil) }
        e.settle()
        let b = try XCTUnwrap(badges(e).first)
        let view = e.tv.viewFrame(of: b)
        let onPill = window.convertPoint(toScreen: e.tv.convert(NSPoint(x: view.midX, y: view.midY), to: nil))
        let hit = e.tv.accessibilityHitTest(onPill) as? NSAccessibilityElement
        XCTAssertEqual(hit?.accessibilityLabel(), "Language: Rust")
        XCTAssertTrue(hit === button(), "the pointer finds the same button the children list")
        let beside = window.convertPoint(toScreen: e.tv.convert(NSPoint(x: view.minX - 60, y: view.midY + 40), to: nil))
        XCTAssertFalse(e.tv.accessibilityHitTest(beside) is CodeBadgeElement)
        XCTAssertEqual(hit?.accessibilityFrame().size, view.size, "its frame is the pill's")
    }

    // MARK: focus mode

    func testFocusModeDimsHighlightedCodeWithEverythingElse() throws {
        let e = laidOut(doc, caret: 3)
        e.session.setFocusEnabled(true)
        e.select(3)
        e.settle()
        let dim = e.session.appearance.palette.focusDim.hexString
        let at = (e.string as NSString).range(of: "fn main").location
        XCTAssertEqual((e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil) as? NSColor)?.hexString, dim,
                       "the overlay still wins over the stored highlight colour")
        XCTAssertEqual(colour(e, "fn main"), syntax(e).keyword.hexString, "and the stored colour is untouched")
        XCTAssertEqual(badges(e).first?.dimmed, true, "the badge recedes with its block")
        // The caret in the block: its code is at full strength.
        e.select(at + 1)
        e.settle()
        XCTAssertNil(e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil))
        XCTAssertEqual(badges(e).first?.dimmed, false)
    }
}
