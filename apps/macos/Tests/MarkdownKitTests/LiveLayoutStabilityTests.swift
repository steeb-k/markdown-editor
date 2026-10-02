import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// What the reader is looking at does not move when Live mode changes what is concealed
/// somewhere else: caret moves relayout only the paragraphs whose concealment changed, and a
/// change above the viewport (a fence that collapses, a picture that loads, a region queried
/// for the first time) keeps the visible text where it is on screen.
final class LiveLayoutStabilityTests: XCTestCase {
    /// An editor inside a scroll view of `height` points.
    static func scrolled(_ text: String, height: CGFloat = 400, mode: ViewMode = .live) -> (Editor, NSScrollView) {
        let e = Editor(text: text)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: height))
        scroll.documentView = e.tv
        e.tv.setFrameSize(NSSize(width: 800, height: height))
        e.session.setViewMode(mode)
        e.select(0)
        e.settle()
        return (e, scroll)
    }

    /// Where the line holding character `i` is on screen (relative to the top of the clip view).
    static func screenY(_ e: Editor, _ scroll: NSScrollView, _ i: Int) -> CGFloat {
        let lm = e.lm
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(e.session.storage.length, i + 1)))
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil)
        return rect.minY + e.tv.textContainerOrigin.y - scroll.contentView.bounds.origin.y
    }

    static func scroll(_ e: Editor, _ scroll: NSScrollView, toCharacter i: Int) {
        let lm = e.lm
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: i + 1))
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + e.tv.textContainerOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        e.session.visibleRangeChanged()
        e.settle()
    }

    static let paragraphs = (0..<80).map { "Paragraph \($0) has **bold \($0)** and a [link](http://x.y/\($0)) in it.\n\n" }.joined()

    func testRevealingAboveTheViewportDoesNotMoveWhatIsOnScreen() {
        let text = "Intro.\n\n```swift\nlet a = 1\n```\n\n---\ntitle: no\n---\n\n# Heading\n\n" + Self.paragraphs
        let ns = text as NSString
        let (e, scroll) = Self.scrolled(text)
        // The caret in the code block: its fences are shown.
        e.select(ns.range(of: "let a").location)
        e.settle()
        XCTAssertTrue(e.lm.live.collapsed.isEmpty || !e.lm.live.collapsed.contains { ns.substring(with: $0).hasPrefix("```") })
        let target = ns.range(of: "Paragraph 40 ").location
        Self.scroll(e, scroll, toCharacter: target)
        let before = Self.screenY(e, scroll, target)
        let docBefore = e.lineTop(of: target)
        // A click on screen: the code block above hides its fences (two lines collapse).
        e.select(target + 3)
        e.settle()
        XCTAssertLessThan(e.lineTop(of: target), docBefore - 20, "the text below the fences moved up in the document")
        XCTAssertTrue(e.lm.live.collapsed.contains { ns.substring(with: $0).hasPrefix("```swift") }, "the fences collapsed")
        XCTAssertEqual(Self.screenY(e, scroll, target), before, accuracy: 0.5, "the clicked line stayed where it was on screen")
        // And back: the caret returns to the code block by keyboard (scrolls there), nothing jumps
        // on the way back down either.
        e.select(ns.range(of: "let a").location)
        e.settle()
        Self.scroll(e, scroll, toCharacter: target)
        let again = Self.screenY(e, scroll, target)
        e.select(target + 5)
        e.settle()
        XCTAssertEqual(Self.screenY(e, scroll, target), again, accuracy: 0.5)
    }

    func testCaretMovesShiftOnlyTheParagraphsWhoseConcealmentChanged() {
        let text = "---\ntitle: x\n---\n\n# Head **b**\n\nText with *em* and `code`.\n\n```\nfence\n```\n\n> quote\n> more\n\n- [ ] task\n- item\n\n***\n\nSetext\n===\n\nEnd [l](u).\n"
        let ns = text as NSString
        let e = Editor.live(text, caret: 0)
        let paras: [NSRange] = {
            var out: [NSRange] = []
            var i = 0
            while i < ns.length { let p = ns.paragraphRange(for: NSRange(location: i, length: 0)); out.append(p); i = NSMaxRange(p) }
            return out
        }()
        func tops() -> [CGFloat] { paras.map { e.lineTop(of: $0.location) } }
        /// From the top of a paragraph's first line fragment to the bottom of its last.
        func heights() -> [CGFloat] {
            paras.map { p in
                let g = e.lm.glyphRange(forCharacterRange: p, actualCharacterRange: nil)
                var top = CGFloat.greatestFiniteMagnitude, bottom: CGFloat = 0
                e.lm.enumerateLineFragments(forGlyphRange: g) { rect, _, _, _, _ in
                    top = min(top, rect.minY)
                    bottom = max(bottom, rect.maxY)
                }
                return bottom - top
            }
        }
        func touched(_ a: LiveState, _ b: LiveState, _ p: NSRange) -> Bool {
            func inP(_ r: NSRange) -> Bool { NSIntersectionRange(r, p).length > 0 || NSLocationInRange(r.location, p) }
            return a.hidden.filter(inP) != b.hidden.filter(inP) || a.collapsed.filter(inP) != b.collapsed.filter(inP)
                || a.decorations.filter { inP($0.range) } != b.decorations.filter { inP($0.range) }
        }
        var prev = (tops(), heights(), e.lm.live)
        for p in 0...ns.length {
            e.select(p)
            e.settle()
            let now = (tops(), heights(), e.lm.live)
            var shift: CGFloat = 0
            for (i, para) in paras.enumerated() {
                let changed = touched(prev.2, now.2, para)
                if !changed {
                    XCTAssertEqual(now.0[i] - prev.0[i], shift, accuracy: 0.5, "caret \(p): paragraph \(i) \(ns.substring(with: para).debugDescription) moved by itself")
                    XCTAssertEqual(now.1[i], prev.1[i], accuracy: 0.5, "caret \(p): paragraph \(i) changed height")
                }
                shift = (now.0[i] + now.1[i]) - (prev.0[i] + prev.1[i])
            }
            prev = now
        }
    }

    func testSwitchingModesKeepsTheTopLine() {
        let text = "Intro.\n\n```\ncode\n```\n\n" + Self.paragraphs + "![i](p.png)\n\n" + Self.paragraphs
        let ns = text as NSString
        let (e, scroll) = Self.scrolled(text, mode: .source)
        let target = ns.range(of: "Paragraph 60 ").location
        Self.scroll(e, scroll, toCharacter: target)
        let before = Self.screenY(e, scroll, target)
        e.session.setViewMode(.live)
        e.settle()
        XCTAssertEqual(Self.screenY(e, scroll, target), before, accuracy: 1, "Source -> Live")
        e.session.setViewMode(.source)
        e.settle()
        XCTAssertEqual(Self.screenY(e, scroll, target), before, accuracy: 1, "Live -> Source")
    }

    func testABigDocumentQueriedForTheFirstTimeOnScrollDoesNotJump() {
        // Beyond the whole-text limit: concealment is queried by window.
        let unit = "Paragraph with **bold** and `code`.\n\n```\nfenced\n```\n\n> quote\n\n"
        let text = String(repeating: unit, count: 160_000 / (unit as NSString).length + 1)
        let ns = text as NSString
        XCTAssertGreaterThan(ns.length, EditorSession.wholeTextLimit)
        let (e, scroll) = Self.scrolled(text)
        let target = ns.length * 2 / 3
        let anchor = ns.paragraphRange(for: NSRange(location: target, length: 0)).location
        // Jump far: the new region was never queried, so it is laid out as source first.
        e.lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: anchor + 1))
        let rect = e.lm.lineFragmentRect(forGlyphAt: e.lm.glyphIndexForCharacter(at: anchor), effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + e.tv.textContainerOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = Self.screenY(e, scroll, anchor)
        e.session.visibleRangeChanged()
        e.settle()
        XCTAssertTrue(NSLocationInRange(anchor, e.session.liveWindow), "queried")
        XCTAssertEqual(Self.screenY(e, scroll, anchor), before, accuracy: 0.5, "the line at the top stays at the top")
    }
}
