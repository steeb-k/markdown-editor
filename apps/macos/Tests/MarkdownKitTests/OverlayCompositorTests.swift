import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The overlay compositor: what paints over the stored colours, in what order, and that only
/// the difference is ever applied.
final class OverlayCompositorTests: XCTestCase {
    typealias Paint = OverlayPaint

    static func run(_ loc: Int, _ len: Int, _ paint: Paint) -> OverlayRun { OverlayRun(NSRange(location: loc, length: len), paint) }

    /// What each character is painted with, by the book: the simplest possible statement of the
    /// precedence, one character at a time.
    static func reference(_ layers: OverlayLayers, length: Int) -> [Paint?] {
        (0..<length).map { i in
            if let keep = layers.focus, !keep.contains(where: { NSLocationInRange(i, $0) }) { return .dim }
            if let r = layers.pos.first(where: { NSLocationInRange(i, $0.range) }) { return r.paint }
            if let r = layers.authorship.first(where: { NSLocationInRange(i, $0.range) }) { return r.paint }
            return nil
        }
    }

    static func map(_ runs: [OverlayRun], length: Int) -> [Paint?] {
        var out = [Paint?](repeating: nil, count: length)
        for r in runs { for i in r.range.location..<min(length, NSMaxRange(r.range)) { out[i] = r.paint } }
        return out
    }

    // MARK: precedence

    func testBaseIsUnderAuthorshipUnderPartOfSpeechUnderDim() {
        var l = OverlayLayers()
        l.authorship = [Self.run(0, 20, .authorship(.ai))]
        l.pos = [Self.run(5, 10, .pos(.noun))]
        // No focus mode: authorship shows where nothing is above it, part of speech over it.
        var got = OverlayCompositor.compose(l, in: NSRange(location: 0, length: 30))
        XCTAssertEqual(got, [Self.run(0, 5, .authorship(.ai)), Self.run(5, 10, .pos(.noun)), Self.run(15, 5, .authorship(.ai))])
        // Focus mode: everything outside the focus range is dimmed, whatever is under it; inside it
        // the layers below show as before.
        l.focus = [NSRange(location: 8, length: 4)]
        got = OverlayCompositor.compose(l, in: NSRange(location: 0, length: 30))
        XCTAssertEqual(got, [Self.run(0, 8, .dim), Self.run(8, 4, .pos(.noun)), Self.run(12, 18, .dim)])
        // An empty focus range dims everything, even text with no colour of its own.
        l.focus = []
        XCTAssertEqual(OverlayCompositor.compose(l, in: NSRange(location: 0, length: 30)), [Self.run(0, 30, .dim)])
        // And the stored colour shows through where no layer says anything.
        XCTAssertEqual(OverlayCompositor.compose(OverlayLayers(), in: NSRange(location: 0, length: 30)), [])
    }

    func testDimmedTextShowsNoPartOfSpeechColour() {
        var l = OverlayLayers()
        l.pos = (0..<10).map { Self.run($0 * 3, 2, .pos(.verb)) }
        l.focus = [NSRange(location: 9, length: 6)]
        let paints = Self.map(OverlayCompositor.compose(l, in: NSRange(location: 0, length: 30)), length: 30)
        for i in 0..<30 {
            if (9..<15).contains(i) { XCTAssertNotEqual(paints[i], .dim, "\(i) is in focus") } else { XCTAssertEqual(paints[i], .dim, "\(i) is outside it") }
        }
    }

    func testComposeAndDifferenceAgreeWithTheReferenceOnRandomLayers() {
        var rng = SplitMix(seed: 0xC0FFEE)
        func runs(_ paints: [Paint], length: Int) -> [OverlayRun] {
            var out: [OverlayRun] = []
            var at = Int(rng.next() % 5)
            while at < length {
                let len = 1 + Int(rng.next() % 9)
                if rng.next() % 3 != 0 { out.append(Self.run(at, min(len, length - at), paints[Int(rng.next() % UInt64(paints.count))])) }
                at += len + Int(rng.next() % 6)
            }
            return out
        }
        var previous: [OverlayRun] = []
        for round in 0..<400 {
            let length = 1 + Int(rng.next() % 80)
            var l = OverlayLayers()
            l.authorship = runs([.authorship(.ai), .authorship(.reference)], length: length)
            l.pos = runs([.pos(.noun), .pos(.verb), .pos(.adjective)], length: length)
            if rng.next() % 3 != 0 {
                var keep: [NSRange] = []
                var at = Int(rng.next() % 10)
                while at < length {
                    let len = 1 + Int(rng.next() % 12)
                    if rng.next() % 2 == 0 { keep.append(NSRange(location: at, length: min(len, length - at))) }
                    at += len + 1 + Int(rng.next() % 8)
                }
                l.focus = keep
            }
            let window = NSRange(location: 0, length: length)
            let composed = OverlayCompositor.compose(l, in: window)
            XCTAssertEqual(Self.map(composed, length: length), Self.reference(l, length: length), "round \(round): \(l)")
            // Sorted, disjoint, merged.
            for (a, b) in zip(composed, composed.dropFirst()) {
                XCTAssertLessThanOrEqual(NSMaxRange(a.range), b.range.location)
                if NSMaxRange(a.range) == b.range.location { XCTAssertNotEqual(a.paint, b.paint, "touching runs of one paint are merged") }
            }
            // The difference from the last state takes it exactly to this one, touching only what differs.
            let diff = OverlayCompositor.difference(from: previous, to: composed)
            let top = max(length, previous.map { NSMaxRange($0.range) }.max() ?? 0)
            var state = Self.map(previous, length: top)
            let want = Self.map(composed, length: top)
            for (r, paint) in diff {
                for i in r.location..<NSMaxRange(r) {
                    XCTAssertNotEqual(state[i], want[i], "round \(round): \(i) was already right and is touched")
                    XCTAssertEqual(paint, want[i])
                    state[i] = paint
                }
            }
            XCTAssertEqual(state, want, "round \(round): applying the difference gives the new state")
            previous = composed
        }
    }

    func testSettingTheSameLayerTwiceChangesNothing() {
        let e = Editor(text: String(repeating: "word ", count: 40))
        e.session.overlay.setFocus([NSRange(location: 10, length: 20)])
        e.session.overlay.apply()
        e.session.overlay.resetInstrumentation()
        e.session.overlay.setFocus([NSRange(location: 10, length: 20)])
        e.session.overlay.apply()
        XCTAssertEqual(e.session.overlay.operations, 0)
        XCTAssertEqual(e.session.overlay.charactersTouched, 0)
    }

    // MARK: applying to a layout manager

    func testMovingTheFocusRangeTouchesOnlyWhatDiffers() {
        let text = (0..<30).map { "Sentence number \($0) goes here." }.joined(separator: " ")
        let e = Editor(text: text)
        let o = e.session.overlay
        let ns = text as NSString
        func sentence(_ i: Int) -> NSRange { ns.range(of: "Sentence number \(i) goes here.") }
        o.setFocus([sentence(4)])
        o.apply()
        e.session.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: ns.length))
        // Dimmed everywhere but the sentence.
        for i in [0, 100, 600, ns.length - 1] { XCTAssertEqual(o.appliedPaint(at: i), .dim) }
        XCTAssertNil(o.appliedPaint(at: sentence(4).location))
        o.resetInstrumentation()
        o.recordsOperations = true
        o.setFocus([sentence(5)])
        o.apply()
        // Two stretches changed: the old sentence is dimmed, the new one lit (they are neighbours,
        // so the one space between them stays as it was).
        XCTAssertEqual(o.operations, 2, "\(o.operationLog)")
        XCTAssertEqual(o.charactersTouched, sentence(4).length + sentence(5).length)
        XCTAssertEqual(o.operationLog.map(\.paint), [.dim, nil])
        // The layout manager says the same.
        let lm = e.session.layoutManager
        XCTAssertNil(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: sentence(5).location, effectiveRange: nil))
        XCTAssertNotNil(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: sentence(4).location, effectiveRange: nil))
    }

    func testTheLayersReachTheLayoutManagerInTheirOwnColours() {
        let text = "alpha beta gamma delta epsilon"
        let e = Editor(text: text)
        let o = e.session.overlay
        let p = e.session.appearance.palette
        let lm = e.session.layoutManager
        func color(_ i: Int) -> String? { (lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) as? NSColor)?.hexString }
        o.setAuthorship([Self.run(0, 10, .authorship(.reference))])
        o.setPos([Self.run(6, 4, .pos(.verb)), Self.run(11, 5, .pos(.conjunction))])
        o.apply()
        XCTAssertEqual(color(0), p.authorReference.hexString, "the authorship hook paints")
        XCTAssertEqual(color(7), p.posVerb.hexString, "part of speech is above authorship")
        XCTAssertEqual(color(12), p.posConjunction.hexString)
        XCTAssertNil(color(20), "nothing says anything about the rest: the stored colour")
        o.setFocus([NSRange(location: 6, length: 4)])
        o.apply()
        XCTAssertEqual(color(0), p.focusDim.hexString, "dim is above authorship")
        XCTAssertEqual(color(7), p.posVerb.hexString, "inside the focus range nothing is dimmed")
        XCTAssertEqual(color(12), p.focusDim.hexString, "dimmed text shows no part-of-speech colour")
        o.setFocus(nil)
        o.apply()
        XCTAssertEqual(color(12), p.posConjunction.hexString, "and it comes back when focus mode goes")
        o.setPos([])
        o.setAuthorship([])
        o.apply()
        XCTAssertEqual((0..<text.count).compactMap(color), [])
    }

    func testTextTypedInsideAnOverlaidRunIsPaintedLikeItsNeighbours() {
        let text = "one two three four five six seven eight"
        let e = Editor(text: text)
        let o = e.session.overlay
        let lm = e.session.layoutManager
        o.setFocus([NSRange(location: 0, length: 7)])
        o.apply()
        func dimmed(_ i: Int) -> Bool { lm.temporaryAttribute(.foregroundColor, atCharacterIndex: i, effectiveRange: nil) != nil }
        // Typing in the dimmed part: AppKit gives inserted text no temporary colour; the overlay
        // puts the dimming back once the edit is over.
        e.edit(range: NSRange(location: 20, length: 0), with: "XYZ")
        o.apply()
        for i in 20..<23 { XCTAssertTrue(dimmed(i), "inserted character \(i)") }
        XCTAssertTrue(dimmed(30))
        XCTAssertFalse(dimmed(3))
        // Typing at the end of the focus range stays in it (no flash of dim before the next query).
        e.edit(range: NSRange(location: 7, length: 0), with: "!")
        o.apply()
        XCTAssertFalse(dimmed(7), "typed at the edge of the focus range")
        XCTAssertEqual(o.layers.focus, [NSRange(location: 0, length: 8)])
    }

    func testTheSessionNeverWritesColoursIntoTheStorage() {
        let e = Editor(text: "# Title\n\nSome words here. And more words there.\n\n- item\n")
        let before = e.signature()
        let text = e.string
        e.session.setFocusEnabled(true)
        e.select(15)
        e.settle()
        e.session.setSyntaxEnabled(true)
        XCTAssertTrue(e.session.pos.waitUntilSettled())
        XCTAssertFalse(e.session.overlay.layers.pos.isEmpty)
        XCTAssertEqual(e.signature(), before, "no stored attribute changed")
        XCTAssertEqual(e.string, text)
        XCTAssertFalse(e.um.canUndo, "nothing to undo")
    }
}
