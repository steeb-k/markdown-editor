import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The core's copy of the text (and the analysis queue's mirror of it) must always equal the
/// text storage, whatever path an edit takes: typing, deleting, pasting, IME composition,
/// core commands, table helpers, undo and redo, and direct storage edits (find and replace).
final class MirrorTests: XCTestCase {
    private let base = """
    # Title

    Some *text* with **bold** and `code`, 日本語 and 🎉.

    - one
    - two
      - nested

    1. first
    2. second

    > quoted line

    | a | b |
    |---|---|
    | 1 | 2 |

    ```
    code
    ```
    """

    func testCoreTextFollowsEveryEditPath() {
        var rng = SplitMix(seed: 0x5EED)
        for round in 0..<10 {
            let e = Editor(text: base)
            e.session.coordinator.verifiesMirror = true
            let pb = NSPasteboard(name: NSPasteboard.Name("markdown-tests-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            for step in 0..<70 {
                if step % 9 == 0 { e.session.coordinator.artificialDelay = (round % 2 == 0) ? 0.004 : 0 }
                let len = e.session.storage.length
                let ns = e.string as NSString
                // A position on a composed character boundary.
                func pos(_ x: Int) -> Int {
                    guard len > 0 else { return 0 }
                    let p = x % (len + 1)
                    return p == len ? p : ns.rangeOfComposedCharacterSequence(at: p).location
                }
                let a = pos(Int(rng.next() % 10_000)), b = pos(Int(rng.next() % 10_000))
                let sel = NSRange(location: min(a, b), length: abs(a - b) > 12 ? 0 : abs(a - b))
                e.select(sel.location, sel.length)
                let op = rng.next() % 16
                e.grouped {
                    switch op {
                    case 0, 1: e.tv.insertText(["x", "**", "\n", "- ", "| c |", "é", "🎉", "日本", "\t"][Int(rng.next() % 9)], replacementRange: sel)
                    case 2: e.tv.insertText("", replacementRange: NSRange(location: sel.location, length: max(sel.length, sel.location < len ? 1 : 0)))
                    case 3:
                        pb.clearContents()
                        pb.setString(["pasted\ntext", "**p**", "| x | y |\n|---|---|\n", "\r\nCR"][Int(rng.next() % 4)], forType: .string)
                        _ = e.tv.readSelection(from: pb, type: .string)
                    case 4:
                        e.tv.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: sel)
                        e.tv.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                        if rng.next() % 2 == 0 { e.tv.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0)) } else { e.tv.unmarkText() }
                    case 5: e.tv.toggleStrong(nil)
                    case 6: e.tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    case 7: e.tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
                    case 8: e.tv.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
                    case 9: e.tv.setHeading(level: Int(rng.next() % 4))
                    case 10: e.tv.toggleBlockQuote(nil)
                    case 11: e.tv.tableAddRowBelow(nil); e.tv.tableAddColumnRight(nil)
                    case 12:
                        // Find and replace writes to the storage directly.
                        e.session.storage.replaceCharacters(in: sel, with: "REPLACED")
                    default: break
                    }
                }
                if op == 13, e.um.canUndo { e.um.undo() }
                if op == 14, e.um.canRedo { e.um.redo() }
                if op == 15 { _ = spin(timeout: 0.05) { false } }
                if ProcessInfo.processInfo.environment["MIRROR_TRACE"] != nil {
                    let delay = e.session.coordinator.artificialDelay
                    e.session.coordinator.artificialDelay = 0
                    _ = e.session.waitUntilStyled(timeout: 10)
                    e.session.coordinator.artificialDelay = delay
                    let mine = e.signature(), fresh = Editor(text: e.string).signature()
                    if mine != fresh {
                        print("TRACE round \(round) step \(step) op \(op) sel \(sel) text \(e.string.debugDescription) before \((ns as String).debugDescription)")
                        let i = zip(mine, fresh).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1
                        print("TRACE first diff at \(i): \(i >= 0 ? mine[i] : "") vs \(i >= 0 ? fresh[i] : "")")
                        return
                    }
                }
            }
            e.session.coordinator.artificialDelay = 0
            XCTAssertTrue(e.session.waitUntilStyled(timeout: 30))
            XCTAssertEqual(e.session.coordinator.coreText(), e.string, "round \(round): core text drifted")
            XCTAssertEqual(e.session.coordinator.mirrorText(), e.string, "round \(round): mirror drifted")
            XCTAssertEqual(e.session.coordinator.mirrorMismatches, 0, "round \(round): mirror and core disagreed after some edit")
            let mine = e.signature(), fresh = Editor(text: e.string).signature()
            if let i = zip(mine, fresh).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                let ns = e.string as NSString
                let para = ns.paragraphRange(for: NSRange(location: min(i, ns.length - 1), length: 0))
                XCTFail("round \(round): styling differs from a fresh analysis at \(i) in paragraph \(ns.substring(with: para).debugDescription): \(mine[i]) vs \(fresh[i]); text \(e.string.debugDescription)")
            }
        }
    }
}

/// Small deterministic generator (tests must be reproducible).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class BoundedWaitTests: XCTestCase {
    /// When analysis takes longer than the bounded wait (a big document), keystrokes stop
    /// paying the wait: the answer would not come in time anyway.
    func testKeystrokesSkipTheWaitOnceAnalysisIsSlowerThanIt() {
        let e = Editor(text: "# T\n\ntext\n")
        let c = e.session.coordinator
        e.edit(range: NSRange(location: 0, length: 0), with: "a") // fast: within the wait
        c.artificialDelay = c.syncWait * 4
        e.edit(range: NSRange(location: 0, length: 0), with: "b") // slow: learns it
        XCTAssertTrue(spin { c.isIdle })
        let t0 = CFAbsoluteTimeGetCurrent()
        e.edit(range: NSRange(location: 0, length: 0), with: "c")
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - t0, c.syncWait, "no wait for a known-slow analysis")
        c.artificialDelay = 0
        XCTAssertTrue(e.session.waitUntilStyled())
        XCTAssertEqual(c.coreText(), e.string)
    }
}
