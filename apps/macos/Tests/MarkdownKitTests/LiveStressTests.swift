import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Live mode under random use: edits, pastes, undo and redo, commands, every kind of caret and
/// selection move, mode, theme and font changes. After every step the invariants hold.
class LiveStressTests: XCTestCase {
    static let base = """
    ---
    title: Stress
    ---

    # Title with **bold** and `code`

    Some *text* with **bold**, ~~gone~~, `code`, a [link](http://x.y "t"), <http://a.b>, \\* and ![i](p.png) 日本語 🎉 e\u{301}.
    A hard\\
    break and [ref][r] with 😀**x**😀.

    - one **b**
    - [ ] task 日本
    - [x] done
      - nested 🎉
    1. first
    > quoted **line**
    > second
    lazy line

    > > deep `c`

    ![alone](img.png)

    ---

    | a | **b** |
    |---|---|
    | 日本 | `2` |

    ```swift
    let x = 1
    ```

    Setext
    ======

    [r]: http://r.example
    """

    /// Problems with the glyphs: hidden characters that take room or are drawn, visible ones
    /// that have no glyph.
    static func glyphProblems(_ e: Editor, in range: NSRange? = nil) -> [String] {
        let ns = e.string as NSString
        let lm = e.lm
        let live = lm.live
        guard ns.length > 0 else { return [] }
        let check = range.map { RangeMath.clamp($0, toLength: ns.length) } ?? NSRange(location: 0, length: ns.length)
        lm.ensureLayout(forCharacterRange: check)
        var out: [String] = []
        var i = check.location > 0 ? ns.rangeOfComposedCharacterSequence(at: check.location).location : 0
        while i < NSMaxRange(check) {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            let hidden = live.isHidden(i)
            if (r.location + 1..<NSMaxRange(r)).contains(where: { live.isHidden($0) != hidden }) {
                out.append("hidden text splits the character at \(i)")
            }
            let g = lm.glyphIndexForCharacter(at: i)
            let prop = lm.propertyForGlyph(at: g)
            let c = ns.character(at: i)
            let control = c == 0x0A || c == 0x0D || c == 0x09
            if hidden {
                if !prop.contains(.null) {
                    if !prop.contains(.controlCharacter) {
                        out.append("hidden \(i) \(ns.substring(with: r).debugDescription) has a drawn glyph")
                    } else if g + 1 < lm.numberOfGlyphs {
                        var here = NSRange(), there = NSRange()
                        let a = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &here)
                        let b = lm.lineFragmentRect(forGlyphAt: g + 1, effectiveRange: &there)
                        if a == b, NSEqualRanges(here, there) {
                            let advance = lm.location(forGlyphAt: g + 1).x - lm.location(forGlyphAt: g).x
                            // (AppKit puts the line break of a line with nothing visible a point
                            // after its hidden characters; nothing is drawn there.)
                            let next = lm.characterIndexForGlyph(at: g + 1)
                            let nc = next < ns.length ? ns.character(at: next) : 0
                            let line = ns.lineRange(for: NSRange(location: i, length: 0))
                            let lineHidden = (line.location..<NSMaxRange(line)).allSatisfy { j in
                                let ch = ns.character(at: j)
                                return live.isHidden(j) || ch == 0x0A || ch == 0x0D || ch == 0x20 || ch == 0x09
                            }
                            if advance > 0.01 && !Self.isQuotePrefix(ns, i) && !((nc == 0x0A || nc == 0x0D) && lineHidden && advance <= 1.01) {
                                out.append("hidden \(i) \(ns.substring(with: r).debugDescription) advances \(advance)")
                            }
                        }
                    }
                }
            } else if !control && (prop.contains(.null) || prop.contains(.controlCharacter)) {
                out.append("visible \(i) \(ns.substring(with: r).debugDescription) has no glyph")
            }
            i = NSMaxRange(r)
        }
        return out
    }

    /// A quote's `>` and the blanks after it keep their width in a hanging paragraph (wrapped
    /// lines hang under the text): the layout manager's `keepsWidth` rule.
    static func isQuotePrefix(_ ns: NSString, _ i: Int) -> Bool {
        var j = i
        while j >= 0 {
            let c = ns.character(at: j)
            if c == 0x3E { return true }
            if c != 0x20 && c != 0x09 { return false }
            j -= 1
        }
        return false
    }

    /// With focus mode on: the focus range is the core's answer for the selection, and every
    /// character's temporary colour is what the layers (focus dimming over parts of speech) say.
    static func overlayProblems(_ e: Editor) -> [String] {
        guard e.session.focusEnabled else { return [] }
        var out: [String] = []
        let sel = e.tv.selectedRange()
        let scope: FocusScope = e.session.settings.focusScope == .sentence ? .sentence : .paragraph
        let want = e.session.coordinator.sync { doc in
            doc.focusRange(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))), scope: scope).map(\.nsRange)
        }
        if e.session.overlay.layers.focus != want { out.append("focus range \(String(describing: e.session.overlay.layers.focus)) is not the core's \(want)") }
        let o = e.session.overlay
        o.apply()
        let window = o.appliedWindow
        let composed = OverlayCompositor.compose(o.layers, in: window)
        let ns = e.string as NSString
        var run = 0
        for i in window.location..<min(NSMaxRange(window), ns.length) {
            while run < composed.count, NSMaxRange(composed[run].range) <= i { run += 1 }
            let paint = run < composed.count && composed[run].range.location <= i ? composed[run].paint : nil
            let actual = (e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor)?.hexString
            let expected = paint.flatMap { o.color(for: $0)?.hexString }
            if actual != expected { out.append("character \(i) is painted \(String(describing: actual)), the layers say \(String(describing: expected))"); break }
        }
        return out
    }

    /// What the core says now, for the editor's selection and query window.
    static func fresh(_ e: Editor) -> LiveState {
        let sel = e.tv.selectedRange()
        let w = e.session.liveQueryWindow()
        return e.session.coordinator.sync { doc in
            LiveState(doc.concealment(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))),
                                      within: Utf16Range(start: UInt32(w.location), end: UInt32(NSMaxRange(w)))),
                      images: doc.images())
        }
    }

    func testRandomUseKeepsEveryInvariant() {
        let moves: [Selector] = [
            #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveRightAndModifySelection(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveUpAndModifySelection(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)),
            #selector(NSResponder.moveWordRight(_:)), #selector(NSResponder.moveWordLeft(_:)),
            #selector(NSResponder.moveWordRightAndModifySelection(_:)), #selector(NSResponder.moveWordLeftAndModifySelection(_:)),
            #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
            #selector(NSResponder.moveToLeftEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)),
            #selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
            #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
            #selector(NSResponder.moveParagraphForwardAndModifySelection(_:)),
        ]
        let typed = ["x", " ", "**", "*", "`", "[", "](u)", "# ", "> ", "- ", "- [ ] ", "\n", "日", "🎉", "e\u{301}", "\\", "~~", "```\n", "---\n", "|"]
        let pastes = ["**bold** and *em*", "\n\n# Pasted\n\n> q\n", "- [ ] a\n- [x] b\n", "![p](q.png)\n", "```\ncode\n```\n", "日本 🎉 [l](http://e.f)", "a\r\nb **c**\r\n"]
        let rounds = Int(ProcessInfo.processInfo.environment["LIVE_STRESS_ROUNDS"] ?? "") ?? 4
        let steps = Int(ProcessInfo.processInfo.environment["LIVE_STRESS_STEPS"] ?? "") ?? 120
        for round in 0..<rounds {
            let seed = UInt64(ProcessInfo.processInfo.environment["LIVE_STRESS_SEED"] ?? "") ?? 0x5EED_0000
            var rng = SplitMix(seed: seed + UInt64(round))
            let e = Editor.live(Self.base, caret: 0)
            e.session.coordinator.verifiesMirror = true
            var log: [String] = []
            for step in 0..<steps {
                let len = e.session.storage.length
                let ns = e.string as NSString
                func pos(_ x: UInt64) -> Int {
                    guard len > 0 else { return 0 }
                    let p = Int(x % UInt64(len + 1))
                    return p == len ? p : ns.rangeOfComposedCharacterSequence(at: p).location
                }
                let textBefore = e.string
                func note(_ s: String) {
                    log.append(s)
                    if let path = ProcessInfo.processInfo.environment["LIVE_STRESS_TRACE"] {
                        // The state before each step, for reproducing a crash.
                        let state = "round \(round) step \(step): \(s)\n" + textBefore
                        try? state.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
                let op = Int(rng.next() % 20)
                var movedOnly = false
                let before = (text: e.string, signature: e.signature())
                switch op {
                case 0, 1, 2:
                    let s = typed[Int(rng.next() % UInt64(typed.count))]
                    note("type \(s.debugDescription) at \(e.tv.selectedRange())")
                    e.grouped { e.tv.insertText(s, replacementRange: e.tv.selectedRange()) }
                case 3:
                    note("backspace at \(e.tv.selectedRange())")
                    e.grouped { e.tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
                case 4:
                    note("delete at \(e.tv.selectedRange())")
                    e.grouped { e.tv.doCommand(by: #selector(NSResponder.deleteForward(_:))) }
                case 5:
                    let s = pastes[Int(rng.next() % UInt64(pastes.count))]
                    note("paste \(s.debugDescription) at \(e.tv.selectedRange())")
                    e.grouped { e.tv.insertText(s, replacementRange: e.tv.selectedRange()) }
                case 6:
                    if e.um.canUndo { note("undo"); e.um.undo() }
                case 7:
                    if e.um.canRedo { note("redo"); e.um.redo() }
                case 8:
                    let k = Int(rng.next() % 6)
                    note("command \(k) at \(e.tv.selectedRange())")
                    e.grouped {
                        switch k {
                        case 0: e.tv.toggleStrong(nil)
                        case 1: e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                        case 2: e.tv.setHeading(level: Int(rng.next() % 3))
                        case 3: e.tv.toggleTaskList(nil)
                        case 4: e.tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                        default: e.tv.toggleBlockQuote(nil)
                        }
                    }
                case 9, 10, 11, 12, 13, 14:
                    let m = moves[Int(rng.next() % UInt64(moves.count))]
                    note("\(m) from \(e.tv.selectedRange())")
                    e.tv.doCommand(by: m)
                    movedOnly = true
                case 15, 16:
                    let a = pos(rng.next()), b = pos(rng.next())
                    let r = NSRange(location: min(a, b), length: rng.next() % 3 == 0 ? abs(a - b) : 0)
                    note("click \(r)")
                    e.select(r.location, r.length)
                    movedOnly = true
                case 17:
                    note("mode toggle")
                    e.session.setViewMode(.source)
                    e.settle()
                    XCTAssertTrue(e.lm.live.isEmpty, "round \(round) step \(step): Source mode conceals nothing")
                    let ns2 = e.string as NSString
                    // (The tail of a surrogate pair or of a combining sequence has a null placeholder glyph.)
                    let nulls = e.nullCharacters().filter { ns2.rangeOfComposedCharacterSequence(at: $0).location == $0 }
                    XCTAssertEqual(nulls, [], "round \(round) step \(step): Source mode has no null glyphs")
                    e.session.setViewMode(.live)
                case 18:
                    let theme = [ThemeChoice.light, .dark, .sepia][Int(rng.next() % 3)]
                    note("theme \(theme)")
                    e.session.settings.theme = theme
                default:
                    let size = [15.0, 17.0, 22.0][Int(rng.next() % 3)]
                    note("font \(size)")
                    e.session.settings.fontSize = size
                    e.session.settings.fontChoice = [FontChoice.iaQuattro, .iaDuo, .systemSerif][Int(rng.next() % 3)]
                }
                e.settle()
                let context = "round \(round) step \(step) after \(log.suffix(3)); selection \(e.tv.selectedRange()) in \(e.string.debugDescription)"
                XCTAssertEqual(e.session.coordinator.coreText(), e.string, "core text: \(context)")
                if movedOnly {
                    XCTAssertEqual(e.string, before.text, "a move changed the text: \(context)")
                    let after = e.signature()
                    if let i = zip(after, before.signature).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                        let ns = e.string as NSString
                        let para = ns.paragraphRange(for: NSRange(location: i, length: 0))
                        XCTFail("a move changed the attributes at \(i) in \(ns.substring(with: para).debugDescription): \(before.signature[i]) -> \(after[i]); \(context)")
                    }
                }
                XCTAssertEqual(e.lm.live, Self.fresh(e), "concealment is not the core's answer: \(context)")
                let glyphs = Self.glyphProblems(e)
                XCTAssertEqual(glyphs, [], context)
                let overlay = Self.overlayProblems(e)
                XCTAssertEqual(overlay, [], context)
                if !glyphs.isEmpty || !overlay.isEmpty || e.lm.live != Self.fresh(e) { return }
            }
            XCTAssertEqual(e.session.coordinator.mirrorMismatches, 0)
        }
    }

    /// The same in a document long enough to be queried by window: inside the window (what is
    /// on screen and around it) the concealment is the core's answer and the glyphs follow it.
    func testRandomUseInALongDocumentKeepsTheWindowRight() {
        var text = ""
        while (text as NSString).length < EditorSession.wholeTextLimit * 3 { text += Self.base + "\n\n" }
        let steps = Int(ProcessInfo.processInfo.environment["LIVE_STRESS_STEPS"] ?? "") ?? 60
        var rng = SplitMix(seed: UInt64(ProcessInfo.processInfo.environment["LIVE_STRESS_SEED"] ?? "") ?? 0xB16D0C)
        let (e, scroll) = LiveLayoutStabilityTests.scrolled(text)
        e.session.coordinator.verifiesMirror = true
        var ops: [String] = []
        for step in 0..<steps {
            let len = e.session.storage.length
            let ns = e.string as NSString
            let p = ns.rangeOfComposedCharacterSequence(at: Int(rng.next() % UInt64(len))).location
            let op = rng.next() % 6
            ops.append("\(op)@\(p) sel \(e.tv.selectedRange()) window \(e.session.liveWindow)")
            switch op {
            case 0: e.grouped { e.tv.insertText(["x", "**", "\n", "# ", "```\n", "- [ ] "][Int(rng.next() % 6)], replacementRange: NSRange(location: p, length: 0)) }
            case 1:
                // Whole characters only (half a surrogate pair is not something a user can delete).
                let end = min(len, p + 3)
                let to = end < len ? ns.rangeOfComposedCharacterSequence(at: end).location : len
                e.grouped { e.tv.insertText("", replacementRange: NSRange(location: p, length: max(to, p) - p)) }
            case 2: e.select(p)
            case 3: LiveLayoutStabilityTests.scroll(e, scroll, toCharacter: p)
            case 4: if e.um.canUndo { e.um.undo() }
            default: e.tv.doCommand(by: [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveWordLeft(_:))][Int(rng.next() % 3)])
            }
            e.settle()
            e.session.visibleRangeChanged()
            let turn = expectation(description: "turn")
            DispatchQueue.main.async { turn.fulfill() }
            wait(for: [turn], timeout: 5)
            let w = e.session.liveWindow, sel = e.tv.selectedRange()
            XCTAssertTrue(NSIntersectionRange(w, e.session.visibleRange()) == e.session.visibleRange(), "step \(step): the window covers what is on screen")
            let fresh = e.session.coordinator.sync { doc in
                LiveState(doc.concealment(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))),
                                          within: Utf16Range(start: UInt32(w.location), end: UInt32(NSMaxRange(w)))), images: [])
            }
            XCTAssertEqual(RangeList.normalized(e.lm.live.hidden.map { NSIntersectionRange($0, w) }), fresh.hidden, "step \(step)")
            XCTAssertEqual(Self.glyphProblems(e, in: e.session.visibleRange()), [], "step \(step): \(ops.suffix(3))")
            XCTAssertEqual(e.session.coordinator.coreText(), e.string)
        }
        XCTAssertEqual(e.session.coordinator.mirrorMismatches, 0)
    }

    func testTablesAreLaidOutAsInSourceMode() {
        let text = "x\n\n| a | **b** | 日本 |\n|---|:-:|---|\n| 🎉 | `2` | e\u{301} |\n\nend"
        let source = Editor(text: text)
        let live = Editor.live(text, caret: 0)
        let ns = text as NSString
        source.lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: ns.length))
        let table = ns.range(of: "| a")
        for i in table.location..<ns.range(of: "\n\nend").location where ns.character(at: i) == 0x7C {
            let xs = source.lm.location(forGlyphAt: source.lm.glyphIndexForCharacter(at: i)).x
            let xl = live.lm.location(forGlyphAt: live.lm.glyphIndexForCharacter(at: i)).x
            XCTAssertEqual(xs, xl, accuracy: 0.01, "pipe at \(i)")
        }
        XCTAssertEqual(Self.glyphProblems(live), [])
    }
}
