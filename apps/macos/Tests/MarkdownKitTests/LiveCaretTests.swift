import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Caret behavior in Live mode, exhaustively on small documents, one construct at a time.
///
/// The rules under test (see `EditorSession.textView(_:willChangeSelectionFrom...)` and
/// `EditorTextView.handleLiveCommand`):
/// * every arrow press makes visible progress: it passes at least one character that is drawn
///   before or after the press (touching an element reveals its markup, so the text may move
///   under the caret, but the caret never just sits while a hidden run goes by);
/// * the caret never rests inside, or at the start of, text that is hidden with it there;
/// * Left retraces Right;
/// * Backspace and Delete remove only what the user can see (a checkbox counts: it is deleted as
///   one unit, with the hidden `- [ ] ` it stands for).
final class LiveCaretTests: XCTestCase {
    static let constructs: [(String, String)] = [
        ("strong", "a **bold** b"),
        ("emphasis", "a *em* b"),
        ("code", "a `code` b"),
        ("strike", "a ~~gone~~ b"),
        ("link", "a [link](http://x.y \"t\") b"),
        ("reference link", "a [link][r] b\n\n[r]: http://x.y"),
        ("autolink", "a <http://a.b> b"),
        ("escape", "a \\* b"),
        ("hard break", "a\\\nb"),
        ("nested", "a ***both*** b [x *y* z](u) c"),
        ("link with image", "a [![i](p.png)](u) b"),
        ("emphasis next to escape", "\\**a*\\*"),
        ("atx", "# Head"),
        ("atx closed", "## Head ##"),
        ("setext", "Title\n====="),
        ("quote", "> q1\n> q2"),
        ("lazy quote", "> q1\nlazy"),
        ("nested quote", "> > deep"),
        ("bullets", "- a\n- b\n  - c"),
        ("tasks", "- [ ] t\n- [x] u"),
        ("nested task", "- a\n  - [ ] t"),
        ("ordered", "1. a\n2. b"),
        ("rule", "---"),
        ("fence", "```\ncode\n```"),
        ("fence with info", "~~~ swift\nlet x\n~~~"),
        ("unclosed fence", "```\ncode"),
        ("fence in list", "- item\n\n  ```\n  code\n  ```"),
        ("image", "![i](p.png)"),
        ("image in list", "- ![i](p.png)"),
        ("heading in list", "- # H\n- b"),
        ("heading in quote", "> # H"),
        ("quote in list", "- > q"),
        ("quote task", "> - [ ] t"),
        ("emoji and CJK", "😀 **日本** e\u{301} `x`"),
        ("crlf", "a **b**\r\n\r\n# H\r\n\r\n- [ ] t"),
    ]

    static func doc(_ construct: String) -> String { "start\n\n" + construct + "\n\nend" }

    struct Step {
        var loc: Int
        var live: LiveState
    }

    /// Presses `command` until the caret stops, recording each place and the concealment there.
    static func walk(_ e: Editor, _ command: Selector, from start: Int) -> [Step] {
        e.select(start)
        e.settle()
        var out = [Step(loc: start, live: e.lm.live)]
        for _ in 0..<((e.string as NSString).length * 3 + 10) {
            e.tv.doCommand(by: command)
            e.settle()
            let loc = e.tv.selectedRange().location
            if loc == out.last!.loc { break }
            out.append(Step(loc: loc, live: e.lm.live))
        }
        return out
    }

    /// Problems with one walk: presses that passed only hidden text, and resting places inside
    /// (or at the start of) hidden text.
    static func problems(_ path: [Step], _ tag: String) -> [String] {
        var out: [String] = []
        for (i, s) in path.enumerated() {
            if let h = RangeList.range(containing: s.live.hidden, s.loc) { out.append("\(tag): rests in hidden \(h) at \(s.loc)") }
            guard i > 0 else { continue }
            let a = path[i - 1]
            let passed = min(a.loc, s.loc)..<max(a.loc, s.loc)
            if !passed.contains(where: { !a.live.isHidden($0) || !s.live.isHidden($0) }) {
                out.append("\(tag): \(a.loc) -> \(s.loc) passed only hidden text")
            }
        }
        return out
    }

    func testArrowKeysMakeVisibleProgressAndLeftRetracesRight() {
        for (name, c) in Self.constructs {
            let text = Self.doc(c)
            let ns = text as NSString
            let e = Editor.live(text, caret: 0)
            let right = Self.walk(e, #selector(NSResponder.moveRight(_:)), from: 0)
            let left = Self.walk(e, #selector(NSResponder.moveLeft(_:)), from: ns.length)
            XCTAssertEqual(right.last?.loc, ns.length, "\(name): Right reaches the end")
            XCTAssertEqual(left.last?.loc, 0, "\(name): Left reaches the start")
            XCTAssertEqual(Self.problems(right, "right") + Self.problems(left, "left"), [], name)
            XCTAssertEqual(right.map(\.loc), left.map(\.loc).reversed(), "\(name): Left retraces Right")
            // Forward and backward are the same moves in left-to-right text.
            XCTAssertEqual(Self.walk(e, #selector(NSResponder.moveForward(_:)), from: 0).map(\.loc), right.map(\.loc), name)
        }
    }

    func testShiftArrowsExtendOneVisibleCharacterAtATime() {
        for (name, c) in Self.constructs {
            let text = Self.doc(c)
            let ns = text as NSString
            let e = Editor.live(text, caret: 0)
            let caretPath = Self.walk(e, #selector(NSResponder.moveRight(_:)), from: 0).map(\.loc)
            e.select(0)
            e.settle()
            var ends = [0]
            for _ in 0..<(ns.length * 2) {
                e.tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
                e.settle()
                let sel = e.tv.selectedRange()
                XCTAssertEqual(sel.location, 0, "\(name): the anchor stays")
                if NSMaxRange(sel) == ends.last { break }
                ends.append(NSMaxRange(sel))
            }
            XCTAssertEqual(ends.last, ns.length, "\(name): extends to the end")
            // The selection grows through the same places the caret visits.
            XCTAssertEqual(ends, caretPath, name)
            // Everything selected is shown (a checkbox is the exception: it stands for its text).
            let sel = e.tv.selectedRange()
            let hidden = (sel.location..<NSMaxRange(sel)).filter { e.lm.live.isHidden($0) }
            let boxes = e.lm.live.decorations.filter { if case .checkbox = $0.kind { return true } else { return false } }
            XCTAssertTrue(hidden.allSatisfy { i in boxes.contains { d in RangeList.range(containing: e.lm.live.hidden, i).map { NSIntersectionRange($0, d.range).length > 0 } ?? false } },
                          "\(name): selected but hidden: \(hidden)")
            // And back again from the end.
            e.select(ns.length)
            e.settle()
            var starts = [ns.length]
            for _ in 0..<(ns.length * 2) {
                e.tv.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:)))
                e.settle()
                let s = e.tv.selectedRange()
                XCTAssertEqual(NSMaxRange(s), ns.length, "\(name): the anchor stays at the end")
                if s.location == starts.last { break }
                starts.append(s.location)
            }
            XCTAssertEqual(starts, caretPath.reversed(), "\(name): shift-left")
        }
    }

    func testCharacterAndWordExtensionsShareTheAnchorAsInSourceMode() {
        let text = "one two three four five six\n\nx **b**"
        var results: [[NSRange]] = []
        for mode in [ViewMode.source, .live] {
            let e = Editor(text: text)
            e.session.setViewMode(mode)
            var out: [NSRange] = []
            e.select(14)
            for _ in 0..<3 { e.tv.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:))) }
            out.append(e.tv.selectedRange())
            e.tv.doCommand(by: #selector(NSResponder.moveWordLeftAndModifySelection(_:)))
            out.append(e.tv.selectedRange())
            e.tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
            out.append(e.tv.selectedRange())
            e.select(4)
            for _ in 0..<3 { e.tv.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:))) }
            e.tv.doCommand(by: #selector(NSResponder.moveWordRightAndModifySelection(_:)))
            out.append(e.tv.selectedRange())
            e.tv.doCommand(by: #selector(NSResponder.moveLeft(_:)))
            out.append(e.tv.selectedRange())
            results.append(out)
        }
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0], [NSRange(location: 11, length: 3), NSRange(location: 8, length: 6), NSRange(location: 9, length: 5),
                                    NSRange(location: 4, length: 9), NSRange(location: 4, length: 0)])
    }

    /// The index of the line fragment holding the caret.
    static func lineIndex(_ e: Editor, _ loc: Int) -> Int {
        let length = e.session.storage.length
        guard length > 0 else { return 0 }
        let lm = e.lm
        let g = loc >= length ? max(0, lm.numberOfGlyphs - 1) : lm.glyphIndexForCharacter(at: loc)
        var line = 0
        var index = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, glyphs, stop in
            if NSLocationInRange(g, glyphs) { line = index; stop.pointee = true }
            index += 1
        }
        return line
    }

    func testUpAndDownReachTheEndAndNeverRestInHiddenText() {
        for (name, c) in Self.constructs {
            let text = Self.doc(c)
            let ns = text as NSString
            let e = Editor.live(text, caret: 0)
            for (command, start, end) in [(#selector(NSResponder.moveDown(_:)), 0, ns.length), (#selector(NSResponder.moveUp(_:)), ns.length, 0)] {
                let path = Self.walk(e, command, from: start)
                let rests = path.compactMap { s in RangeList.range(containing: s.live.hidden, s.loc).map { "\($0) at \(s.loc)" } }
                XCTAssertEqual(rests, [], "\(name) \(command): rests in hidden text")
                XCTAssertTrue(path.last?.loc == end || Self.lineIndex(e, path.last!.loc) == Self.lineIndex(e, end), "\(name) \(command) ends on the last line: \(path.map(\.loc))")
                // Every press changes the line until the last one.
                for (i, s) in path.enumerated().dropFirst() where i < path.count - 1 {
                    XCTAssertNotEqual(Self.lineIndex(e, s.loc), Self.lineIndex(e, path[i - 1].loc), "\(name) \(command): \(path.map(\.loc))")
                }
            }
        }
    }

    func testVerticalMovesKeepTheColumnAcrossHiddenPrefixesFencesAndImages() {
        let row = "abcdefghij"
        let text = [row, "- [ ] " + row, row, "```\ncode\n```", row, "![i](p.png)", row, "# " + row, row, "> " + row, row].joined(separator: "\n\n")
        let ns = text as NSString
        let e = Editor.live(text, caret: 5)
        var columns: [Int] = []
        var path: [Int] = [5]
        for _ in 0..<40 {
            e.tv.doCommand(by: #selector(NSResponder.moveDown(_:)))
            e.settle()
            let loc = e.tv.selectedRange().location
            let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length - 1), length: 0))
            // Down on the last line goes to its end.
            if loc == path.last || NSLocationInRange(path.last!, para) { break }
            path.append(loc)
            if ns.substring(with: para).trimmingCharacters(in: .newlines) == row { columns.append(loc - para.location) }
        }
        XCTAssertEqual(columns.count, 5, "every plain row below visited: \(path)")
        XCTAssertTrue(columns.allSatisfy { abs($0 - 5) <= 1 }, "the column is kept: \(columns) along \(path)")
    }

    // MARK: deleting

    func testBackspaceAndDeleteRemoveOnlyWhatTheUserSees() {
        for (name, c) in Self.constructs {
            let text = Self.doc(c)
            let ns = text as NSString
            let e = Editor.live(text, caret: 0)
            let source = Editor(text: text)
            let places = Self.walk(e, #selector(NSResponder.moveRight(_:)), from: 0).map(\.loc)
            for p in places {
                for command in [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:))] {
                    let backward = command == #selector(NSResponder.deleteBackward(_:))
                    if backward && p == 0 || !backward && p == ns.length { continue }
                    e.select(p)
                    e.settle()
                    let live = e.lm.live
                    let target = backward ? ns.rangeOfComposedCharacterSequence(at: p - 1) : ns.rangeOfComposedCharacterSequence(at: p)
                    let hidden = live.isHidden(target.location)
                    e.grouped { e.tv.doCommand(by: command) }
                    e.settle()
                    let got = e.string
                    if !hidden {
                        // Exactly what the same key does in Source mode.
                        source.session.load(text)
                        source.select(p)
                        source.grouped { source.tv.doCommand(by: command) }
                        XCTAssertEqual(got, source.string, "\(name): \(command) at \(p) removes the character beside the caret")
                    } else {
                        // Only a checkbox may stand beside the caret hidden: it goes as one unit.
                        let run = RangeList.range(containing: live.hidden, target.location)!
                        let boxed = live.decorations.contains { d in
                            if case .checkbox = d.kind { return NSIntersectionRange(d.range, run).length > 0 } else { return false }
                        }
                        XCTAssertTrue(backward && boxed, "\(name): \(command) at \(p) next to hidden \(ns.substring(with: run).debugDescription)")
                        XCTAssertEqual(got, ns.replacingCharacters(in: NSRange(location: run.location, length: p - run.location), with: ""), "\(name): the checkbox and its prefix go")
                    }
                    if got != text {
                        e.um.undo()
                        e.settle()
                    }
                    XCTAssertEqual(e.string, text, "\(name): undo")
                }
            }
        }
    }

    func testBackspaceAfterACheckboxRemovesItAsOneUndoStep() {
        let text = "- [ ] one\n- [x] two\n\nend"
        let ns = text as NSString
        let e = Editor.live(text, caret: ns.range(of: "two").location)
        e.grouped { e.tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        e.settle()
        XCTAssertEqual(e.string, "- [ ] one\ntwo\n\nend")
        XCTAssertEqual(e.tv.selectedRange(), NSRange(location: 10, length: 0))
        XCTAssertFalse(e.lm.live.decorations.contains { if case .checkbox(true) = $0.kind { return true } else { return false } })
        e.um.undo()
        e.settle()
        XCTAssertEqual(e.string, text)
        XCTAssertEqual(e.session.coordinator.coreText(), text)
    }

    // MARK: typing and Return at element edges

    func testTypingAtTheEdgesOfAnElementGoesWhereTheCaretIsShown() {
        // The caret touching bold text shows its `**`, so the user sees which side of them they type on.
        let cases: [(String, Int, String)] = [
            ("a **bold** b", 10, "a **bold**x b"),     // right after the closing `**`: outside, plain
            ("a **bold** b", 8, "a **boldx** b"),      // right before it: inside, bold
            ("a **bold** b", 2, "a x**bold** b"),      // right before the opening `**`
            ("a **bold** b", 4, "a **xbold** b"),
            ("[link](u) b", 9, "[link](u)x b"),
            ("- [ ] t", 6, "- [ ] xt"),               // after the checkbox: the item's text
        ]
        for (text, caret, expected) in cases {
            let e = Editor.live(text + "\n\nend", caret: caret)
            XCTAssertEqual(e.tv.selectedRange().location, caret, text)
            let shown = !e.lm.live.isHidden(max(0, caret - 1)) || text.hasPrefix("- [")
            XCTAssertTrue(shown, "\(text): the markup beside the caret is shown before typing")
            e.grouped { e.tv.insertText("x", replacementRange: e.tv.selectedRange()) }
            e.settle()
            XCTAssertEqual(e.string, expected + "\n\nend")
            XCTAssertEqual(e.session.coordinator.coreText(), e.string)
        }
    }

    func testReturnInsideHiddenPrefixLines() {
        let cases: [(String, String, String)] = [
            ("- [ ] task", "task", "- [ ] \n- [ ] task"),       // after the checkbox: a new item above
            ("- [ ] task", "", "- [ ] task\n- [ ] "),            // at the end: the next item
            ("> quote", "quote", "> \n> quote"),
            ("# Head", "Head", "# \nHead"),
        ]
        for (line, before, expected) in cases {
            let text = "start\n\n" + line + "\n\nend"
            let ns = text as NSString
            let r = ns.range(of: line)
            let caret = before.isEmpty ? NSMaxRange(r) : ns.range(of: before, range: r).location
            let e = Editor.live(text, caret: caret)
            e.grouped { e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            e.settle()
            XCTAssertEqual(e.string, "start\n\n" + expected + "\n\nend", line)
            let sel = e.tv.selectedRange().location
            XCTAssertNil(RangeList.range(containing: e.lm.live.hidden, sel), "\(line): the caret rests in hidden text at \(sel)")
        }
    }

    // MARK: line and word moves

    func testLineAndWordMovesNeverRestInHiddenText() {
        let commands: [Selector] = [
            #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
            #selector(NSResponder.moveToLeftEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)),
            #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordRight(_:)),
            #selector(NSResponder.moveToBeginningOfParagraph(_:)), #selector(NSResponder.moveToEndOfParagraph(_:)),
            #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
        ]
        for (name, c) in Self.constructs {
            let text = Self.doc(c)
            let e = Editor.live(text, caret: 0)
            let places = Self.walk(e, #selector(NSResponder.moveRight(_:)), from: 0).map(\.loc)
            for p in places {
                for command in commands {
                    e.select(p)
                    e.settle()
                    e.tv.doCommand(by: command)
                    e.settle()
                    let loc = e.tv.selectedRange().location
                    XCTAssertNil(RangeList.range(containing: e.lm.live.hidden, loc), "\(name): \(command) from \(p) rests in hidden text at \(loc)")
                }
            }
        }
        // Command-Left in a task item goes to the start of its text, not to the line above.
        let text = "above\n- [ ] task"
        let e = Editor.live(text, caret: (text as NSString).length)
        e.tv.doCommand(by: #selector(NSResponder.moveToLeftEndOfLine(_:)))
        e.settle()
        XCTAssertEqual(e.tv.selectedRange().location, 12)
        e.tv.doCommand(by: #selector(NSResponder.moveToLeftEndOfLine(_:)))
        e.settle()
        XCTAssertEqual(e.tv.selectedRange().location, 12, "pressed again: stays")
    }

    // MARK: clicks

    func testDoubleAndTripleClickSelectWhatIsShown() {
        let text = "start\n\nsee **bold** and [link](http://a.b) end\n# Next\n\nend"
        let ns = text as NSString
        let e = Editor.live(text, caret: ns.length)
        let word = ns.range(of: "bold")
        let byWord = e.tv.selectionRange(forProposedRange: NSRange(location: word.location + 1, length: 0), granularity: .selectByWord)
        XCTAssertEqual(ns.substring(with: byWord), "bold")
        let link = ns.range(of: "link")
        XCTAssertEqual(ns.substring(with: e.tv.selectionRange(forProposedRange: NSRange(location: link.location + 1, length: 0), granularity: .selectByWord)), "link")
        // A triple click selects the line with its line break; the heading below keeps its prefix hidden.
        let line = e.tv.selectionRange(forProposedRange: NSRange(location: word.location, length: 0), granularity: .selectByParagraph)
        XCTAssertEqual(ns.substring(with: line), "see **bold** and [link](http://a.b) end\n")
        e.select(line.location, line.length)
        e.settle()
        XCTAssertTrue(e.lm.live.isHidden(ns.range(of: "# Next").location), "the next line's `# ` stays hidden")
        XCTAssertFalse(e.lm.live.isHidden(word.location - 1), "the selected line's markup is shown")
    }
}
