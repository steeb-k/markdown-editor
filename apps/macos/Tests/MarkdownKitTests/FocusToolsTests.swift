import AppKit
import NaturalLanguage
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// A tagger that needs no model: every word of five or more letters is some class, by its
/// length. Counts how often it is asked.
final class FakeTagger: PosTagger {
    private let lock = NSLock()
    private var _calls = 0
    private var _texts: [String] = []
    var delay: TimeInterval = 0
    var supported = true
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return _texts }

    func supports(_ language: NLLanguage) -> Bool { supported }

    func tag(_ text: String, language: NLLanguage) -> [PosWord] {
        lock.lock(); _calls += 1; _texts.append(text); lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return Self.words(in: text)
    }

    static func words(in text: String) -> [PosWord] {
        let ns = text as NSString
        var out: [PosWord] = []
        let regex = try! NSRegularExpression(pattern: "[A-Za-z]+")
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length >= 5 {
            let classes: [PosClass] = [.noun, .verb, .adjective, .adverb, .conjunction]
            out.append(PosWord(range: m.range, posClass: classes[m.range.length % 5]))
        }
        return out
    }
}

/// Focus mode and syntax highlighting in the editor.
final class FocusToolsTests: XCTestCase {
    static let sample = """
    # A heading. With two sentences.

    First paragraph, sentence one. Sentence two follows here! Does a third? Yes.
    It wraps over a soft break. And continues.

    - A list item. With two sentences.
    - [ ] A task with **bold.** Next one.
      - nested item here. Two.

    > A quote that wraps
    > over lines. Then ends.

    ```
    code. block.
    ```

    | a | b |
    |---|---|
    | c | d |

    Last \u{65E5}\u{672C}\u{8A9E}\u{3002}\u{4E8C}\u{3064}\u{76EE}\u{3002} end \u{1F389}.
    """

    func ranges(_ e: Editor, _ selection: NSRange, _ scope: FocusScope) -> [NSRange] {
        e.session.coordinator.sync { doc in
            doc.focusRange(selection: Utf16Range(start: UInt32(selection.location), end: UInt32(NSMaxRange(selection))), scope: scope).map(\.nsRange)
        }
    }

    /// Characters whose temporary colour says "dimmed", and the palette's colour for that.
    func dimmed(_ e: Editor) -> [Bool] {
        let lm = e.lm
        let dim = e.session.appearance.palette.focusDim.hexString
        return (0..<e.session.storage.length).map { i in
            (lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor)?.hexString == dim
        }
    }

    func assertDimmingEqualsTheCore(_ e: Editor, selection: NSRange, scope: FocusScope, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        e.tv.setSelectedRange(selection)
        e.settle()
        let want = ranges(e, selection, scope)
        XCTAssertEqual(e.session.overlay.layers.focus, want, context, file: file, line: line)
        let got = dimmed(e)
        for i in 0..<got.count {
            let lit = want.contains { NSLocationInRange(i, $0) }
            if got[i] == lit {
                XCTFail("\(context): character \(i) is \(got[i] ? "dimmed" : "not dimmed") but the core says it is \(lit ? "in" : "outside") the focus range \(want)", file: file, line: line)
                return
            }
        }
    }

    // MARK: dimming equals the core

    func testDimmingEqualsTheCoresRangesAtEveryCaretInSourceAndLive() {
        for scope in [FocusScopeChoice.sentence, .paragraph] {
            for mode in [ViewMode.source, .live] {
                let settings = isolatedSettings()
                settings.focusScope = scope
                let e = Editor(text: Self.sample, settings: settings)
                e.session.setViewMode(mode)
                e.session.setFocusEnabled(true)
                let length = (Self.sample as NSString).length
                let stride = mode == .live ? 3 : 1
                for p in Swift.stride(from: 0, through: length, by: stride) {
                    assertDimmingEqualsTheCore(e, selection: NSRange(location: p, length: 0), scope: scope == .sentence ? .sentence : .paragraph,
                                               "\(mode) \(scope) caret \(p)")
                }
            }
        }
    }

    func testSelectionsLightUpEveryUnitTheyTouch() {
        let e = Editor(text: Self.sample)
        e.session.setFocusEnabled(true)
        let ns = Self.sample as NSString
        let a = ns.range(of: "sentence one").location, b = ns.range(of: "soft break").location
        assertDimmingEqualsTheCore(e, selection: NSRange(location: a, length: b - a), scope: .sentence, "selection across sentences")
        let c = ns.range(of: "list item").location, d = ns.range(of: "nested").location
        assertDimmingEqualsTheCore(e, selection: NSRange(location: c, length: d - c), scope: .sentence, "selection across items")
    }

    func testCaretOnABlankLineDimsEverything() {
        let e = Editor(text: Self.sample)
        e.session.setFocusEnabled(true)
        e.select((Self.sample as NSString).range(of: "\n\nFirst").location + 1)
        e.settle()
        XCTAssertEqual(e.session.overlay.layers.focus, [])
        XCTAssertTrue(dimmed(e).allSatisfy { $0 })
    }

    func testFocusFollowsEditsWithoutAFlashOfDim() {
        let e = Editor(text: "Alpha beta. Gamma delta. Epsilon zeta.")
        e.session.setFocusEnabled(true)
        let ns = e.string as NSString
        e.select(ns.range(of: "Gamma").location + 3)
        e.settle()
        let lit = e.session.overlay.layers.focus!
        // Type at the end of the lit sentence.
        let end = NSMaxRange(lit[0])
        e.select(end - 1)
        e.grouped { e.tv.insertText("Q", replacementRange: NSRange(location: end - 1, length: 0)) }
        // Straight away, before any query has come back, the typed character is not dimmed.
        let flags = dimmed(e)
        XCTAssertFalse(flags[end - 1], "the typed character is lit")
        e.settle()
        assertDimmingEqualsTheCore(e, selection: e.tv.selectedRange(), scope: .sentence, "after typing")
    }

    func testMovingTheCaretUnderFocusLaysNothingOutAgain() {
        let e = Editor(text: Self.sample)
        e.tv.setFrameSize(NSSize(width: 800, height: 600))
        e.session.setFocusEnabled(true)
        e.session.setSyntaxEnabled(true)
        XCTAssertTrue(e.session.pos.waitUntilSettled())
        let all = NSRange(location: 0, length: e.session.storage.length)
        e.lm.ensureLayout(forCharacterRange: all)
        let glyphs = e.lm.numberOfGlyphs
        let frames = (0..<glyphs).map { e.lm.lineFragmentRect(forGlyphAt: $0, effectiveRange: nil) }
        let passes = e.lm.layoutCompletions
        XCTAssertGreaterThan(passes, 0, "the counter works")
        for p in stride(from: 0, to: all.length, by: 7) {
            e.select(p)
            e.settle()
            e.lm.ensureLayout(forCharacterRange: all)
        }
        XCTAssertEqual(e.lm.layoutCompletions, passes, "no layout pass: colours only")
        XCTAssertEqual(e.lm.numberOfGlyphs, glyphs)
        XCTAssertEqual((0..<glyphs).map { e.lm.lineFragmentRect(forGlyphAt: $0, effectiveRange: nil) }, frames)
    }

    // MARK: no side effects

    func testTogglingFocusAndSyntaxChangesNothingButOverlays() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data(Self.sample.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        let s = doc.session
        XCTAssertTrue(s.waitUntilStyled())
        let um = try XCTUnwrap(doc.undoManager)
        let storageBefore = NSAttributedString(attributedString: s.storage)
        let revision = s.coordinator.sync { $0.revision() }
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertFalse(um.canUndo)

        let tv = wc.textView
        tv.setSelectedRange(NSRange(location: 80, length: 0))
        tv.toggleFocusMode(nil)
        tv.toggleSyntaxHighlight(nil)
        XCTAssertTrue(s.pos.waitUntilSettled())
        tv.setSelectedRange(NSRange(location: 200, length: 0))
        wc.focusButton.performClick(nil)   // off
        wc.syntaxButton.performClick(nil)  // off
        wc.focusButton.performClick(nil)   // on
        s.settings.focusScope = .paragraph
        s.settings.setSyntaxClass(.noun, false)
        XCTAssertTrue(s.waitUntilStyled())

        XCTAssertTrue(s.storage.isEqual(to: storageBefore), "not one stored attribute or character changed")
        XCTAssertEqual(s.coordinator.sync { $0.revision() }, revision, "the core was not told of any edit")
        XCTAssertFalse(doc.isDocumentEdited, "the document is not edited")
        XCTAssertFalse(um.canUndo, "nothing to undo")
        XCTAssertFalse(um.canRedo)
        XCTAssertEqual(s.coordinator.coreText(), s.text)
        doc.close()
    }

    func testOneRoundTripPerSelectionChange() {
        for mode in [ViewMode.source, .live] {
            for focus in [false, true] {
                let e = Editor(text: Self.sample)
                e.session.setViewMode(mode)
                e.session.setFocusEnabled(focus)
                e.settle()
                let ns = Self.sample as NSString
                let before = e.session.stateQueries
                e.select(ns.range(of: "Does a third").location + 3)
                XCTAssertEqual(e.session.stateQueries - before, 1, "\(mode) focus \(focus): one query for the move")
                // ... and it brought everything: the format state too.
                e.select(ns.range(of: "**bold.**").location + 3)
                XCTAssertTrue(e.session.formatState.strong || spin { e.session.formatState.strong }, "\(mode) focus \(focus)")
                if focus { XCTAssertEqual(e.session.overlay.layers.focus, ranges(e, e.tv.selectedRange(), .sentence)) }
                if mode == .live { XCTAssertFalse(e.lm.live.isEmpty) }
            }
        }
    }

    // MARK: parts of speech

    func wait(_ e: Editor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.session.pos.waitUntilSettled(), "tagging settles", file: file, line: line)
    }

    /// Word -> class painted by the part-of-speech layer, for the words of `text`.
    func classes(_ e: Editor, words: [String]) -> [String: String] {
        let ns = e.string as NSString
        var out: [String: String] = [:]
        for w in words {
            let r = ns.range(of: w)
            guard r.location != NSNotFound else { continue }
            if let run = e.session.overlay.layers.pos.first(where: { NSLocationInRange(r.location, $0.range) }), case .pos(let c) = run.paint {
                out[w] = "\(c)"
            } else {
                out[w] = "none"
            }
        }
        return out
    }

    func testTaggingAFixedEnglishParagraphWithNLTagger() {
        let e = Editor(text: "The old fisherman quickly mended his torn nets, and the children happily watched.")
        e.session.pos.languageOverride = .english
        e.session.setSyntaxEnabled(true)
        wait(e)
        let got = classes(e, words: ["fisherman", "quickly", "mended", "torn", "and", "happily", "watched", "The ", "his"])
        XCTAssertEqual(got["fisherman"], "noun")
        XCTAssertEqual(got["quickly"], "adverb")
        XCTAssertEqual(got["mended"], "verb")
        XCTAssertEqual(got["torn"], "adjective")
        XCTAssertEqual(got["and"], "conjunction")
        XCTAssertEqual(got["happily"], "adverb")
        XCTAssertEqual(got["watched"], "verb")
        XCTAssertEqual(got["The "], "none", "determiners stay uncoloured")
        XCTAssertEqual(got["his"], "none", "pronouns stay uncoloured")
        // Colours reach the layout manager, as the palette's, and the storage is untouched.
        let r = (e.string as NSString).range(of: "fisherman")
        let c = e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: r.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(c?.hexString, e.session.appearance.palette.posNoun.hexString)
        // Punctuation is never a word.
        let comma = (e.string as NSString).range(of: ",").location
        XCTAssertNil(e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: comma, effectiveRange: nil))
    }

    func testTheNLTagMapping() {
        XCTAssertEqual(NLPosTagger.posClass(of: .noun), .noun)
        XCTAssertEqual(NLPosTagger.posClass(of: .verb), .verb)
        XCTAssertEqual(NLPosTagger.posClass(of: .adjective), .adjective)
        XCTAssertEqual(NLPosTagger.posClass(of: .adverb), .adverb)
        XCTAssertEqual(NLPosTagger.posClass(of: .conjunction), .conjunction)
        for tag in [NLTag.pronoun, .determiner, .preposition, .particle, .number, .interjection, .classifier, .idiom, .otherWord,
                    .sentenceTerminator, .otherPunctuation, .whitespace, .personalName, .placeName, .organizationName] {
            XCTAssertNil(NLPosTagger.posClass(of: tag), "\(tag.rawValue) is not coloured")
        }
    }

    func testMarkupCodeAndUrlsAreNeverTagged() {
        let text = "The **heavy** ropes `broken_code` and a [linked page](https://example.org/path) here.\n\n```\nlet fishermen = boats\n```\n"
        let tagger = FakeTagger()
        let e = Editor(text: text)
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        e.session.setSyntaxEnabled(true)
        wait(e)
        XCTAssertEqual(tagger.texts, ["The heavy ropes  and a linked page here."])
        let pos = e.session.overlay.layers.pos
        let ns = text as NSString
        for run in pos {
            let piece = ns.substring(with: run.range)
            XCTAssertFalse(piece.contains("*") || piece.contains("`") || piece.contains("http") || piece.contains("let") || piece.contains("broken"), "\(piece)")
        }
        XCTAssertEqual(classes(e, words: ["heavy", "ropes", "linked", "broken_code", "fishermen"]).values.filter { $0 != "none" }.count, 3)
    }

    func testScrollingBackNeverTagsAgain() {
        let text = (0..<1_200).map { "Paragraph number \($0) holds several wonderful sentences." }.joined(separator: "\n\n")
        let tagger = FakeTagger()
        let (e, scroll) = LiveLayoutStabilityTests.scrolled(text, height: 400, mode: .source)
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        e.session.setSyntaxEnabled(true)
        wait(e)
        let top = tagger.calls
        XCTAssertGreaterThan(top, 20)
        XCTAssertLessThan(top, 600, "only the visible text and a margin is tagged")
        let ns = text as NSString
        // Far away: new units are tagged.
        LiveLayoutStabilityTests.scroll(e, scroll, toCharacter: ns.length * 2 / 3)
        wait(e)
        let far = tagger.calls
        XCTAssertGreaterThan(far, top)
        XCTAssertFalse(e.session.overlay.layers.pos.isEmpty)
        XCTAssertGreaterThan(e.session.overlay.layers.pos.first!.range.location, ns.length / 2, "colours follow the visible text")
        // And back: what was tagged is in the cache, and its colours are back at once.
        LiveLayoutStabilityTests.scroll(e, scroll, toCharacter: 0)
        wait(e)
        XCTAssertEqual(e.session.overlay.layers.pos.first?.range.location ?? .max, 0, "the colours are back")
        // (A unit at the very edge of a window may be looked at for the first time now.)
        XCTAssertLessThan(tagger.calls, far + 12)
        // Scrolling around: only text that was never in view is tagged, never a unit again.
        for target in [400, ns.length * 2 / 3, 0, ns.length / 3, ns.length * 2 / 3, 0] {
            LiveLayoutStabilityTests.scroll(e, scroll, toCharacter: target)
            wait(e)
        }
        XCTAssertEqual(Set(tagger.texts).count, tagger.texts.count, "no unit was ever tagged twice")
    }

    func testAnEditTagsOnlyTheEditedUnit() {
        let text = (0..<30).map { "Paragraph number \($0) holds several wonderful sentences." }.joined(separator: "\n\n")
        let tagger = FakeTagger()
        let e = Editor(text: text)
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        e.session.setSyntaxEnabled(true)
        wait(e)
        XCTAssertEqual(tagger.calls, 30)
        let ns = e.string as NSString
        // Typing into one paragraph: that unit, and no other.
        let seven = ns.range(of: "number 7 ")
        let at = ns.range(of: "holds several", options: [], range: NSRange(location: seven.location, length: 40)).location
        e.edit(range: NSRange(location: at, length: 0), with: "really ")
        wait(e)
        XCTAssertEqual(tagger.calls, 31)
        // A paragraph inserted before it: one new unit; the ones that moved are not tagged again.
        e.edit(range: NSRange(location: 0, length: 0), with: "A brand new paragraph arrives.\n\n")
        wait(e)
        XCTAssertEqual(tagger.calls, 32)
        // Undo: the old text of the edited unit is still cached.
        e.um.undo()
        wait(e)
        XCTAssertEqual(tagger.calls, 32)
        // And the layer is what tagging the final text gives, word for word.
        let units = e.session.coordinator.sync { $0.posUnits(within: nil) }
        var expected: [NSRange] = []
        for u in units {
            let joined = PosHighlighter.joinedText(of: u, in: e.string as NSString)
            let words = FakeTagger.words(in: joined).map { PosTag(range: Utf16Range(start: UInt32($0.range.location), end: UInt32(NSMaxRange($0.range))), class: $0.posClass) }
            expected += posMapTags(unit: u, words: words).map(\.range.nsRange)
        }
        XCTAssertEqual(e.session.overlay.layers.pos.map(\.range), expected)
    }

    func testTagsOfTextThatChangedMeanwhileAreNotApplied() {
        let text = "Alpha paragraph holds wonderful words.\n\nSecond paragraph holds different words.\n\nThird paragraph holds other words."
        let tagger = FakeTagger()
        tagger.delay = 0.15
        let e = Editor(text: text)
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        e.session.setSyntaxEnabled(true)
        // While the tagger is busy with the first unit, the text changes under it.
        XCTAssertTrue(spin { tagger.calls >= 1 })
        e.edit(range: NSRange(location: 0, length: 5), with: "Zulu zulu zulu zulu")
        wait(e)
        // Whatever was tagged for the old text is not painted onto the new.
        let units = e.session.coordinator.sync { $0.posUnits(within: nil) }
        var expected: [NSRange] = []
        for u in units {
            let words = FakeTagger.words(in: PosHighlighter.joinedText(of: u, in: e.string as NSString))
                .map { PosTag(range: Utf16Range(start: UInt32($0.range.location), end: UInt32(NSMaxRange($0.range))), class: $0.posClass) }
            expected += posMapTags(unit: u, words: words).map(\.range.nsRange)
        }
        XCTAssertEqual(e.session.overlay.layers.pos.map(\.range), expected)
        e.session.overlay.apply()
        let ns = e.string as NSString
        for run in e.session.overlay.layers.pos {
            let c = e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: run.range.location, effectiveRange: nil)
            XCTAssertNotNil(c, "\(ns.substring(with: run.range)) is painted")
        }
    }

    func testAnUnsupportedLanguageShowsNoColoursAndDoesNotSpin() {
        let tagger = FakeTagger()
        tagger.supported = false
        let e = Editor(text: "Some perfectly ordinary words in a paragraph.")
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = NLLanguage(rawValue: "tlh")
        e.session.setSyntaxEnabled(true)
        wait(e)
        XCTAssertTrue(e.session.overlay.layers.pos.isEmpty)
        XCTAssertEqual(tagger.calls, 0)
        let refreshes = e.session.pos.refreshes
        let applications = e.session.overlay.applications
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertEqual(e.session.pos.refreshes, refreshes, "no polling")
        XCTAssertEqual(e.session.overlay.applications, applications)
        XCTAssertTrue(e.session.pos.isSettled)
        XCTAssertFalse(e.session.pos.colouredLanguageIsSupported)
        // Edits do not wake it up beyond one look.
        e.edit(range: NSRange(location: 0, length: 0), with: "More ")
        wait(e)
        XCTAssertEqual(tagger.calls, 0)
        // The real tagger says the same for a language it has no model for.
        XCTAssertFalse(NLPosTagger().supports(NLLanguage(rawValue: "tlh")))
        XCTAssertTrue(NLPosTagger().supports(.english))
    }

    func testTheLanguageIsRecognizedFromTheText() {
        let tagger = FakeTagger()
        let e = Editor(text: "Le vieux p\u{EA}cheur r\u{E9}pare lentement ses grands filets bleus pendant que les enfants regardent la mer depuis le quai.")
        e.session.pos.tagger = tagger
        e.session.setSyntaxEnabled(true)
        wait(e)
        XCTAssertEqual(e.session.pos.language, .french)
        XCTAssertEqual(tagger.calls, 1)
    }

    func testClassesCanBeSwitchedOffWithoutTaggingAgain() {
        let tagger = FakeTagger()
        let e = Editor(text: "Paragraph words appear everywhere, including wonderful places and different houses.")
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        e.session.setSyntaxEnabled(true)
        wait(e)
        let all = Set(e.session.overlay.layers.pos.compactMap { r -> PosClass? in if case .pos(let c) = r.paint { return c } else { return nil } })
        XCTAssertGreaterThan(all.count, 2)
        for c in SyntaxClass.allCases where c != .verb { e.session.settings.setSyntaxClass(c, false) }
        wait(e)
        let left = Set(e.session.overlay.layers.pos.compactMap { r -> PosClass? in if case .pos(let c) = r.paint { return c } else { return nil } })
        XCTAssertEqual(left, Set<PosClass>([.verb]).intersection(all))
        XCTAssertEqual(tagger.calls, 1)
        for c in SyntaxClass.allCases { e.session.settings.setSyntaxClass(c, true) }
        wait(e)
        XCTAssertEqual(tagger.calls, 1)
        // Turning syntax off removes every colour; the layout manager has none left.
        e.session.setSyntaxEnabled(false)
        XCTAssertTrue(e.session.overlay.layers.pos.isEmpty)
        XCTAssertEqual(dimmed(e).filter { $0 }.count, 0)
        XCTAssertEqual((0..<e.session.storage.length).filter { e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: $0, effectiveRange: nil) != nil }.count, 0)
    }

    func testDimmedWordsShowNoPartOfSpeechColour() {
        let tagger = FakeTagger()
        let text = "Alpha sentence contains wonderful words here. Another sentence contains different words there."
        let e = Editor(text: text)
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        e.session.setSyntaxEnabled(true)
        e.session.setFocusEnabled(true)
        e.select(10)
        e.settle()
        wait(e)
        e.session.overlay.apply()
        let ns = text as NSString
        let p = e.session.appearance.palette
        func hex(_ needle: String) -> String? {
            (e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: ns.range(of: needle).location, effectiveRange: nil) as? NSColor)?.hexString
        }
        XCTAssertNotNil(hex("wonderful"))
        XCTAssertNotEqual(hex("wonderful"), p.focusDim.hexString, "in focus: coloured")
        XCTAssertEqual(hex("different"), p.focusDim.hexString, "outside focus: dim, not coloured")
        XCTAssertEqual(hex("Another"), p.focusDim.hexString)
        e.select(ns.range(of: "different").location)
        e.settle()
        XCTAssertNotEqual(hex("different"), p.focusDim.hexString)
        XCTAssertEqual(hex("wonderful"), p.focusDim.hexString)
    }

    // MARK: chrome, menu, settings

    func testTheMenuHasTheFocusToolsAndValidatesThem() throws {
        let menu = MainMenu.build()
        let view = try XCTUnwrap(menu.items.first { $0.title == "View" }?.submenu)
        let focus = try XCTUnwrap(view.items.first { $0.title == "Focus Mode" })
        XCTAssertEqual(focus.keyEquivalent, "d")
        XCTAssertEqual(focus.keyEquivalentModifierMask, .command)
        XCTAssertEqual(focus.action, #selector(EditorTextView.toggleFocusMode(_:)))
        let scope = try XCTUnwrap(view.items.first { $0.title == "Focus Scope" }?.submenu)
        XCTAssertEqual(scope.items.map(\.title), ["Sentence", "Paragraph"])
        let syntax = try XCTUnwrap(view.items.first { $0.title == "Syntax Highlight" }?.submenu)
        XCTAssertEqual(syntax.items.map(\.title), ["Highlight Parts of Speech", ""] + SyntaxClass.allCases.map(\.title))

        let e = Editor(text: "Words.")
        let tv = e.tv
        XCTAssertEqual(tv.validateEditorAction(focus.action, tag: 0)?.on, false)
        XCTAssertEqual(tv.validateEditorAction(syntax.items[2].action, tag: 0)?.enabled, false, "classes need syntax on")
        e.session.setFocusEnabled(true)
        e.session.setSyntaxEnabled(true)
        XCTAssertEqual(tv.validateEditorAction(focus.action, tag: 0)?.on, true)
        XCTAssertEqual(tv.validateEditorAction(syntax.items[0].action, tag: 0)?.on, true)
        XCTAssertEqual(tv.validateEditorAction(syntax.items[2].action, tag: 0)?.enabled, true)
        XCTAssertEqual(tv.validateEditorAction(syntax.items[2].action, tag: 0)?.on, true)
        XCTAssertEqual(tv.validateEditorAction(scope.items[0].action, tag: 0)?.on, true)
        XCTAssertEqual(tv.validateEditorAction(scope.items[1].action, tag: 1)?.on, false)
        // Menu items act on this window and on the settings.
        tv.toggleSyntaxClass(syntax.items[2])
        XCTAssertFalse(e.session.settings.syntaxClass(.noun))
        tv.setFocusScope(scope.items[1])
        XCTAssertEqual(e.session.settings.focusScope, .paragraph)
        tv.toggleFocusMode(nil)
        XCTAssertFalse(e.session.focusEnabled)
    }

    func testTheTitleBarButtonsFollowTheWindowAndFadeWithTheChrome() throws {
        let doc = MarkdownDocument(settings: isolatedSettings())
        try doc.read(from: Data("Some words.".utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertEqual(wc.focusButton.state, .off)
        wc.focusButton.performClick(nil)
        XCTAssertTrue(doc.session.focusEnabled)
        XCTAssertEqual(wc.focusButton.state, .on)
        wc.textView.toggleFocusMode(nil)
        XCTAssertEqual(wc.focusButton.state, .off, "the menu item and the button agree")
        wc.syntaxButton.performClick(nil)
        XCTAssertTrue(doc.session.syntaxEnabled)
        XCTAssertEqual(wc.syntaxButton.state, .on)
        // Beside the mode switch, in the one view that fades with the chrome.
        let holder = try XCTUnwrap(wc.modeSwitch.superview)
        XCTAssertTrue(wc.focusButton.superview === holder && wc.syntaxButton.superview === holder)
        XCTAssertTrue(wc.titlebarControls.contains { $0 === holder })
        XCTAssertLessThan(wc.focusButton.frame.maxX, wc.modeSwitch.frame.minX)
        // Each window has its own; a new one starts from the settings.
        let other = MarkdownDocument(settings: doc.session.settings)
        XCTAssertFalse(other.session.focusEnabled)
        doc.close()
    }

    func testSettingsGiveNewWindowsTheirStartingState() {
        let settings = isolatedSettings()
        settings.focusMode = true
        settings.syntaxHighlight = true
        settings.focusScope = .paragraph
        settings.setSyntaxClass(.adverb, false)
        let e = Editor(text: "One. Two.", settings: settings)
        XCTAssertTrue(e.session.focusEnabled)
        XCTAssertTrue(e.session.syntaxEnabled)
        XCTAssertEqual(e.session.settings.syntaxClasses, [.noun, .verb, .adjective, .conjunction])
        e.select(1)
        e.settle()
        XCTAssertEqual(e.session.overlay.layers.focus, ranges(e, NSRange(location: 1, length: 0), .paragraph))
        // The scope is a setting for every window, and applies at once.
        settings.focusScope = .sentence
        XCTAssertEqual(e.session.overlay.layers.focus, ranges(e, NSRange(location: 1, length: 0), .sentence))
    }

    func testThemeChangesRepaintTheOverlay() {
        let e = Editor(text: "Alpha sentence here. Beta sentence there.")
        e.session.setFocusEnabled(true)
        e.select(3)
        e.settle()
        let lm = e.lm
        let at = (e.string as NSString).range(of: "Beta").location
        let light = (lm.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil) as? NSColor)?.hexString
        e.session.settings.theme = .dark
        e.session.refreshAppearance()
        let dark = (lm.temporaryAttribute(.foregroundColor, atCharacterIndex: at, effectiveRange: nil) as? NSColor)?.hexString
        XCTAssertNotNil(light)
        XCTAssertEqual(dark, e.session.appearance.palette.focusDim.hexString)
        XCTAssertNotEqual(light, dark)
    }

    // MARK: hand-drawn things dim with their text

    func testDecorationsAreDimmedOutsideTheFocusRange() {
        let e = Editor.live("- first item here.\n\n- [ ] a task here.\n\n> a quote here.\n\nlast paragraph.", caret: 3)
        e.session.setFocusEnabled(true)
        e.select(3)
        e.settle()
        let o = e.session.overlay
        let ns = e.string as NSString
        let bullet = e.lm.live.decorations.first { if case .bullet = $0.kind { return true } else { return false } }!
        XCTAssertFalse(o.isDimmed(bullet.range), "the item the caret is in keeps its bullet")
        let box = e.lm.live.decorations.first { if case .checkbox = $0.kind { return true } else { return false } }!
        XCTAssertTrue(o.isDimmed(box.range))
        let bar = e.lm.live.decorations.first { if case .quoteBar = $0.kind { return true } else { return false } }!
        XCTAssertTrue(o.isDimmed(bar.range))
        e.select(ns.range(of: "a task").location)
        e.settle()
        XCTAssertTrue(o.isDimmed(bullet.range))
        XCTAssertFalse(o.isDimmed(box.range))
        // A bar recedes line by line.
        XCTAssertEqual(o.pieces(of: NSRange(location: 0, length: ns.length)).map(\.dimmed), [true, false, true])
    }
}

/// The whole of Live mode's caret behaviour again, with focus mode and syntax highlighting on.
final class LiveCaretFocusToolsTests: LiveCaretTests {
    override func setUp() { super.setUp(); TestMode.focusTools = true }
    override func tearDown() { TestMode.focusTools = false; super.tearDown() }
}

/// The stress tests again, with focus mode and syntax highlighting on, and the overlay checked
/// against the core after every step.
final class LiveStressFocusToolsTests: LiveStressTests {
    override func setUp() { super.setUp(); TestMode.focusTools = true }
    override func tearDown() { TestMode.focusTools = false; super.tearDown() }
}
