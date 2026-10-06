import AppKit
import NaturalLanguage
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The compositor as the layout manager sees it: random edits (at layer edges, through
/// surrogate pairs, across runs), Paste As and Mark As, caret moves, scrolling (a moving window
/// on a long text), theme changes, mode switches and the tools switched on and off. After every
/// step every character's *actual* temporary colour is compared with an independent reference
/// built from the attribution, the tagger's layer and the core's focus range: inside the window
/// what the precedence says, outside it nothing at all.
final class OverlayRandomTests: XCTestCase {
    static let paragraph = """
    The first sentence is here. A second one \u{1F600} follows it! Does a *third* ask? Yes, it does.
    It wraps over a soft break and **ends. Here** with \u{65E5}\u{672C}\u{3002} text.

    - A list item. With two sentences.
    - [ ] A task with `code. in it` here.

    > A quote. That continues.


    """

    func run(long: Bool, seed: UInt64, steps: Int) {
        let text = long ? String(repeating: Self.paragraph, count: 400) : String(repeating: Self.paragraph, count: 3)
        let e = Editor(text: text)
        e.privatePasteboard()
        let tagger = FakeTagger()
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        var visible = NSRange(location: 0, length: 3_000)
        e.session.visibleRange = { RangeMath.clamp(visible, toLength: e.session.storage.length) }
        e.session.setFocusEnabled(true)
        e.session.setSyntaxEnabled(true)
        var rng = SplitMix(seed: seed)
        var log: [String] = []
        func clampToCharacters(_ p: Int) -> Int {
            let ns = e.string as NSString
            guard p < ns.length else { return ns.length }
            return ns.rangeOfComposedCharacterSequence(at: p).location
        }
        /// A place near something the layers say: a run edge of one of them, or anywhere.
        func interestingPlace() -> Int {
            let o = e.session.overlay
            var edges: [Int] = []
            for r in o.layers.authorship + o.layers.pos { edges.append(r.range.location); edges.append(NSMaxRange(r.range)) }
            for r in o.layers.focus ?? [] { edges.append(r.location); edges.append(NSMaxRange(r)) }
            edges.append(NSMaxRange(o.appliedWindow)); edges.append(o.appliedWindow.location)
            let length = e.session.storage.length
            if !edges.isEmpty, rng.next() % 3 != 0 {
                let base = edges[Int(rng.next() % UInt64(edges.count))]
                return clampToCharacters(max(0, min(length, base + Int(rng.next() % 3) - 1)))
            }
            // Near the visible text most of the time, so the window is exercised.
            let from = max(0, visible.location - 2_000)
            return clampToCharacters(min(length, from + Int(rng.next() % UInt64(visible.length + 4_000))))
        }
        for step in 0..<steps {
            let length = e.session.storage.length
            let op = rng.next() % 14
            switch op {
            case 0, 1, 2:
                let at = interestingPlace()
                let s = ["x", "\u{1F600}", " ", ". ", "word", "\n", "**", "e\u{301}"][Int(rng.next() % 8)]
                log.append("type \(s.debugDescription) at \(at)")
                e.select(at)
                e.type(s)
            case 3:
                let a = interestingPlace(), b = clampToCharacters(min(length, a + Int(rng.next() % 40)))
                log.append("delete \(a)..<\(b)")
                e.edit(range: NSRange(location: a, length: b - a), with: "")
            case 4:
                let at = interestingPlace()
                log.append("paste as AI at \(at)")
                e.select(at)
                e.paste("pasted \u{1F600} text. More.", as: .ai)
            case 5:
                let a = interestingPlace(), b = clampToCharacters(min(length, a + Int(rng.next() % 200)))
                let c: AuthorChoice? = [nil, .me, .ai, .reference][Int(rng.next() % 4)]
                log.append("mark \(a)..<\(b) as \(String(describing: c))")
                e.session.mark(NSRange(location: a, length: b - a), as: c)
            case 6, 7:
                let at = interestingPlace()
                let len = rng.next() % 4 == 0 ? Int(rng.next() % 30) : 0
                log.append("select \(at)+\(len)")
                e.select(at, clampToCharacters(min(length, at + len)) - at)
            case 8:
                // Scroll: by a little (inside the sticky window) or far.
                let far = rng.next() % 2 == 0
                let to = far ? Int(rng.next() % UInt64(max(1, length))) : max(0, visible.location + Int(rng.next() % 4_000) - 2_000)
                visible = NSRange(location: min(to, max(0, length - 1)), length: 3_000)
                log.append("scroll to \(visible.location)")
                e.session.viewportChanged()
            case 9:
                let theme = [ThemeChoice.light, .dark, .sepia][Int(rng.next() % 3)]
                log.append("theme \(theme)")
                e.session.settings.theme = theme
            case 10:
                let at = Int(rng.next() % UInt64(max(1, length)))
                log.append("caret \(at)")
                e.select(at)
            case 11:
                log.append("focus toggle")
                e.session.setFocusEnabled(!e.session.focusEnabled)
            case 12:
                log.append("syntax toggle")
                e.session.setSyntaxEnabled(!e.session.syntaxEnabled)
            default:
                log.append("undo")
                if e.um.canUndo { e.um.undo() }
            }
            XCTAssertTrue(e.session.waitUntilStyled())
            e.session.refreshState()
            XCTAssertTrue(e.session.pos.waitUntilSettled())
            e.session.overlay.apply()
            let context = "seed \(seed) step \(step): \(log.suffix(3))"
            if !check(e, context) { return }
        }
    }

    /// Every character, the whole text: the layout manager's temporary colour against the
    /// reference. Returns false (and fails) at the first difference.
    func check(_ e: Editor, _ context: String) -> Bool {
        let o = e.session.overlay
        let length = e.session.storage.length
        // The layers are what the sources say.
        let a = e.session.authorship
        let authors = a.authors()
        var wantAuthorship: [OverlayRun] = []
        if e.session.authorshipDisplay {
            for r in a.runs(within: nil) where r.authorIndex != 0 {
                wantAuthorship.append(OverlayRun(r.range.nsRange, .authorship(authors[Int(r.authorIndex)].kind == .ai ? .ai : .reference)))
            }
        }
        XCTAssertEqual(o.layers.authorship, OverlayCompositor.merged(wantAuthorship), "authorship layer, \(context)")
        if e.session.focusEnabled, !e.session.focusHeld {
            // (A selection holds the focus range where it was: the owner's decision of 5 October.)
            let sel = e.tv.selectedRange()
            let scope: FocusScope = e.session.settings.focusScope == .sentence ? .sentence : .paragraph
            let core = e.session.coordinator.sync { doc in
                doc.focusRange(selection: Utf16Range(start: UInt32(sel.location), end: UInt32(NSMaxRange(sel))), scope: scope).map(\.nsRange)
            }
            // A selection's units are worked out inside the query's window (what is on screen and
            // around it); inside that window the answer is the core's.
            let w = e.session.queryWindow()
            func clip(_ rs: [NSRange]) -> [NSRange] { rs.map { NSIntersectionRange($0, w) }.filter { $0.length > 0 } }
            XCTAssertEqual(clip(o.layers.focus ?? []), clip(core), "focus layer, \(context)")
        } else if !e.session.focusEnabled {
            XCTAssertNil(o.layers.focus, context)
        }
        if !e.session.syntaxEnabled { XCTAssertEqual(o.layers.pos, [], context) }
        // Character by character, against the precedence written out longhand.
        let window = o.appliedWindow
        let visible = e.session.visibleRange()
        if visible.length > 0 {
            XCTAssertEqual(NSIntersectionRange(visible, window), visible, "the window holds the visible text, \(context)")
        }
        // The precedence, painted layer over layer (the same statement as
        // `OverlayCompositorTests.reference`, linear in the text).
        var reference = [OverlayPaint?](repeating: nil, count: length)
        for r in o.layers.authorship + o.layers.pos {
            for k in r.range.location..<min(length, NSMaxRange(r.range)) { reference[k] = r.paint }
        }
        if let keep = o.layers.focus {
            var lit = [Bool](repeating: false, count: length)
            for r in keep { for k in r.location..<min(length, NSMaxRange(r)) { lit[k] = true } }
            for k in 0..<length where !lit[k] { reference[k] = .dim }
        }
        var i = 0
        while i < length {
            var effective = NSRange()
            let actual = (e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: &effective) as? NSColor)?.hexString
            let end = min(length, max(i + 1, NSMaxRange(effective)))
            for k in i..<end {
                let paint = NSLocationInRange(k, window) ? reference[k] : nil
                let want = paint.flatMap { o.color(for: $0)?.hexString }
                if actual != want {
                    XCTFail("character \(k) is \(actual ?? "unpainted"), should be \(want ?? "unpainted") (\(String(describing: paint))), window \(window), \(context)")
                    return false
                }
            }
            i = end
        }
        return true
    }

    func testShortTextWholeWindow() {
        let seeds = Int(ProcessInfo.processInfo.environment["OVERLAY_SEEDS"] ?? "") ?? 3
        for s in 0..<seeds { run(long: false, seed: 0x0FE1_0000 + UInt64(s), steps: 120) }
    }

    func testLongTextMovingWindow() {
        let seeds = Int(ProcessInfo.processInfo.environment["OVERLAY_SEEDS"] ?? "") ?? 2
        for s in 0..<seeds { run(long: true, seed: 0x10_0000 + UInt64(s), steps: 80) }
    }
}

/// With everything switched on and nothing happening, nothing runs: no tagging, no queries,
/// no overlay applications, no polling timer.
final class IdleTests: XCTestCase {
    func testEverythingGoesIdle() {
        let text = String(repeating: OverlayRandomTests.paragraph, count: 300)
        let e = Editor.laidOut(text, caret: 100)
        e.privatePasteboard()
        let tagger = FakeTagger()
        e.session.pos.tagger = tagger
        e.session.pos.languageOverride = .english
        e.session.setFocusEnabled(true)
        e.session.setSyntaxEnabled(true)
        e.select(50)
        e.paste("borrowed words", as: .ai)
        e.type("typed")
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertTrue(e.session.pos.waitUntilSettled())
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        let o = e.session.overlay
        let before = (tagger.calls, e.session.pos.refreshes, o.applications, e.session.stateQueries, e.session.coordinator.latestSeq)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.0))
        let after = (tagger.calls, e.session.pos.refreshes, o.applications, e.session.stateQueries, e.session.coordinator.latestSeq)
        XCTAssertTrue(before == after, "something kept running while idle: \(before) -> \(after)")
        XCTAssertTrue(e.session.pos.isSettled)
        XCTAssertTrue(e.session.isStyled)
    }
}

/// Typing under focus mode: the character just typed is never dimmed, wherever it goes.
final class FocusTypingTests: XCTestCase {
    func dimmedAt(_ e: Editor, _ i: Int) -> Bool {
        (e.lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor)?.hexString
            == e.session.appearance.palette.focusDim.hexString
    }

    func testTheTypedCharacterIsLitAtEveryKindOfPlace() {
        let text = "First sentence here. Second one.\n\nNext paragraph.\n\n- item one\n- item two\n"
        let ns = text as NSString
        let places: [(String, Int)] = [
            ("start of a sentence", ns.range(of: "Second").location),
            ("end of a sentence", NSMaxRange(ns.range(of: "here."))),
            ("end of the paragraph", NSMaxRange(ns.range(of: "one."))),
            ("blank line", NSMaxRange(ns.range(of: "one.\n"))),
            ("start of the text", 0),
            ("end of the text", ns.length),
            ("start of a list item", ns.range(of: "item two").location),
        ]
        for scope in [FocusScopeChoice.sentence, .paragraph] {
            for (name, at) in places {
                let settings = isolatedSettings()
                settings.focusScope = scope
                let e = Editor(text: text, settings: settings)
                e.session.setFocusEnabled(true)
                e.select(at)
                e.settle()
                e.type("X")
                // Before anything else runs: the text view has drawn nothing yet, but whatever it
                // draws next shows the X lit.
                XCTAssertFalse(dimmedAt(e, at), "\(scope) \(name): the typed character is dimmed straight away")
                e.settle()
                XCTAssertFalse(dimmedAt(e, at), "\(scope) \(name): the typed character is dimmed once focus caught up")
            }
        }
    }

    /// In a long document the analysis of a keystroke outlasts the bounded wait, so the focus
    /// range arrives after the character is drawn: until then the character must not be dim.
    func testTheTypedCharacterIsLitBeforeTheAnswerInALongDocument() {
        let para = "First sentence here. Second one.\n\nNext paragraph with **bold** and `code`.\n\n- item one\n- item two\n\n"
        let text = String(repeating: para, count: 8_000)
        let e = Editor(text: text)
        e.session.setFocusEnabled(true)
        let ns = text as NSString
        let blank = NSMaxRange(ns.range(of: "one.\n", options: [], range: NSRange(location: ns.length / 2, length: 5_000)))
        for (name, at) in [("blank line", blank), ("end of a sentence", blank - 2)] {
            e.select(at)
            e.settle()
            e.type("X")
            XCTAssertFalse(dimmedAt(e, at), "\(name): the typed character is dimmed before the answer came")
            e.settle()
            XCTAssertFalse(dimmedAt(e, at), "\(name): dimmed after")
        }
    }
}

/// A selection made away from what is on screen (Find Next, undo) holds focus mode still (the owner's decision of
/// 5 October): the dimming stays where it was, also once the selection is scrolled into view. The caret it collapses to
/// is asked about with the window of what is on screen. Focus mode turned on with such a selection is asked about with
/// the window of what was on screen: the selection lights itself only.
final class FocusScrollTests: XCTestCase {
    func testASelectionScrolledIntoViewGetsItsUnits() {
        let text = String(repeating: OverlayRandomTests.paragraph, count: 400)
        let e = Editor(text: text)
        var visible = NSRange(location: 0, length: 3_000)
        e.session.visibleRange = { RangeMath.clamp(visible, toLength: e.session.storage.length) }
        let ns = text as NSString
        let far = ns.range(of: "second one", options: [], range: NSRange(location: 90_000, length: 5_000))
        e.select(far.location, far.length)
        e.session.setFocusEnabled(true)
        e.settle()
        XCTAssertEqual(e.session.overlay.layers.focus, [far], "asked about off screen, the selection lights itself only")
        visible = NSRange(location: far.location - 1_000, length: 3_000)
        e.session.viewportChanged()
        XCTAssertTrue(spin { e.session.selectionStateSettled })
        e.settle()
        XCTAssertEqual(e.session.overlay.layers.focus, [far], "scrolled into view, the selection still holds it")
        // Found again from a caret at the top: held where the caret's sentence was.
        visible = NSRange(location: 0, length: 3_000)
        e.select(5)
        e.session.viewportChanged()
        e.settle()
        let top = e.session.overlay.layers.focus
        e.select(far.location, far.length)
        e.settle()
        visible = NSRange(location: far.location - 1_000, length: 3_000)
        e.session.viewportChanged()
        XCTAssertTrue(spin { e.session.selectionStateSettled })
        e.settle()
        XCTAssertEqual(e.session.overlay.layers.focus, top, "a Find match holds the dimming where it was")
        // Collapsed to a caret in it, on screen: the sentence it is in.
        e.select(far.location + 2)
        e.settle()
        let core = e.session.coordinator.sync { doc in
            doc.focusRange(selection: Utf16Range(start: UInt32(far.location + 2), end: UInt32(far.location + 2)), scope: .sentence).map(\.nsRange)
        }
        XCTAssertEqual(e.session.overlay.layers.focus, core, "on screen, the sentence the caret is in")
    }
}

/// Undo asks about the selection again on the next turn; with nothing to ask (focus off) that must not leave the
/// request hanging.
final class UndoRefreshTests: XCTestCase {
    func testUndoWithFocusOffLeavesNothingPending() {
        let e = Editor(text: "Some *text* here.\n")
        e.um.groupsByEvent = false
        e.select(4)
        e.type("x")
        e.um.undo()
        XCTAssertTrue(spin(timeout: 2) { !e.session.statePending })
        XCTAssertTrue(e.session.selectionStateSettled)
    }
}
