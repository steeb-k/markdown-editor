import XCTest
import MarkdownCore

/// Exercises the analysis API through the UniFFI bindings (UTF-16 offsets).
final class AnalysisTests: XCTestCase {
    /// UTF-16 slice of `text`.
    private func slice(_ text: String, _ r: Utf16Range) -> String {
        let u = Array(text.utf16)
        return String(decoding: u[Int(r.start)..<Int(r.end)], as: UTF16.self)
    }

    func testSpansUseUTF16Offsets() {
        let text = "# Héllo 🎉\n\nSome **bold 👩‍💻** and `code`"
        let doc = Document(text: text)
        XCTAssertEqual(doc.len(), UInt32(text.utf16.count))
        let spans = doc.spans(within: nil)

        let heading = spans.first { if case .heading(level: 1) = $0.kind { return true } else { return false } }
        XCTAssertEqual(slice(text, try XCTUnwrap(heading).range), "# Héllo 🎉")

        let strong = try! XCTUnwrap(spans.first { $0.kind == .strong })
        XCTAssertEqual(slice(text, strong.range), "**bold 👩‍💻**")

        let code = try! XCTUnwrap(spans.first { $0.kind == .inlineCode })
        XCTAssertEqual(slice(text, code.range), "`code`")

        let markup = spans.filter { $0.kind == .markup }.map { slice(text, $0.range) }
        XCTAssertEqual(markup, ["# ", "**", "**", "`", "`"])
    }

    func testSpanContract() {
        let text = "> - *a **b** c* [d](e \"f\")\n>   ```rs\n>   x\n>   ```\n\n| a | b |\n|---|---|\n| 🎉 | `c` |\n"
        let doc = Document(text: text)
        let spans = doc.spans(within: nil)
        XCTAssertFalse(spans.isEmpty)
        var stack: [Utf16Range] = []
        var prev: Span?
        for s in spans {
            XCTAssertLessThan(s.range.start, s.range.end)
            XCTAssertLessThanOrEqual(s.range.end, doc.len())
            if let p = prev {
                XCTAssertTrue(s.range.start > p.range.start || (s.range.start == p.range.start && s.range.end <= p.range.end))
            }
            while let top = stack.last, top.end <= s.range.start { stack.removeLast() }
            if let top = stack.last { XCTAssertLessThanOrEqual(s.range.end, top.end) }
            stack.append(s.range)
            prev = s
        }
    }

    func testSpansWithinWindow() {
        let text = "aa *b* cc `d` ee"
        let doc = Document(text: text)
        let w = doc.spans(within: Utf16Range(start: 10, end: 13))
        XCTAssertEqual(w.map { $0.kind }, [.inlineCode, .markup, .markup])
        XCTAssertTrue(doc.spans(within: Utf16Range(start: 0, end: 3)).isEmpty)
    }

    func testListAndTaskMarkers() {
        let text = "- [x] done\n1. one\n"
        let kinds = Document(text: text).spans(within: nil).map { $0.kind }
        XCTAssertEqual(kinds, [
            .listMarker(ordered: false), .taskMarker(checked: true), .listMarker(ordered: true),
        ])
    }

    func testReplaceReturnsDirtyRangeInNewText() throws {
        let doc = Document(text: "para one\n\npara 🎉 two\n\nlast *x*\n")
        XCTAssertEqual(doc.revision(), 0)
        // Insert after the emoji (10 for the first paragraph, 5 for "para ", 2 for the emoji, 1 for the space).
        let u = try doc.replace(range: Utf16Range(start: 18, end: 18), with: "Z")
        XCTAssertEqual(u.revision, 1)
        XCTAssertEqual(doc.revision(), 1)
        XCTAssertEqual(doc.text(), "para one\n\npara 🎉 Ztwo\n\nlast *x*\n")
        XCTAssertEqual(slice(doc.text(), u.dirty), "para 🎉 Ztwo\n")
    }

    func testOpeningAFenceDirtiesTheRestOfTheDocument() throws {
        let doc = Document(text: "intro\n\n\n\nafter *x*\n")
        let u = try doc.replace(range: Utf16Range(start: 7, end: 7), with: "```")
        XCTAssertEqual(u.dirty.start, 7)
        XCTAssertEqual(u.dirty.end, doc.len())
        // The emphasis is now inside the code block.
        XCTAssertFalse(doc.spans(within: nil).contains { $0.kind == .emphasis })
    }

    func testReplaceErrorsDoNotCrash() {
        let doc = Document(text: "a🎉b")   // UTF-16: a=0..1 🎉=1..3 b=3..4
        XCTAssertThrowsError(try doc.replace(range: Utf16Range(start: 2, end: 2), with: "x")) {
            XCTAssertEqual($0 as? EditError, .NotOnCodePointBoundary)
        }
        XCTAssertThrowsError(try doc.replace(range: Utf16Range(start: 3, end: 1), with: "x")) {
            XCTAssertEqual($0 as? EditError, .InvertedRange)
        }
        XCTAssertThrowsError(try doc.replace(range: Utf16Range(start: 0, end: 9), with: "x")) {
            XCTAssertEqual($0 as? EditError, .OutOfBounds)
        }
        XCTAssertEqual(doc.text(), "a🎉b")
        XCTAssertEqual(doc.revision(), 0)
        XCTAssertNoThrow(try doc.replace(range: Utf16Range(start: 1, end: 3), with: ""))
        XCTAssertEqual(doc.text(), "ab")
    }

    func testSetText() {
        let doc = Document(text: "a")
        let u = doc.setText(text: "# New 🎉")
        XCTAssertEqual(u.dirty, Utf16Range(start: 0, end: doc.len()))
        XCTAssertEqual(u.revision, 1)
        XCTAssertEqual(doc.spans(within: nil).count, 2)
    }

    func testBlocks() {
        let text = "# Title\n\npara\n\n> quoted\n\n```\ncode\n```\n"
        let blocks = Document(text: text).blocks()
        XCTAssertEqual(blocks.map { $0.kind }, [.heading, .paragraph, .paragraph, .codeBlock])
        XCTAssertEqual(blocks[0].headingLevel, 1)
        XCTAssertNil(blocks[1].headingLevel)
        XCTAssertEqual(blocks.map { $0.line }, [0, 2, 4, 6])
        XCTAssertEqual(blocks.map { $0.depth }, [0, 0, 1, 0])
        XCTAssertEqual(slice(text, blocks[3].range), "```\ncode\n```")
    }

    func testImages() {
        let text = "![alt *e*](p/😀.png \"T\")\n\ntext ![i](j) text\n"
        let images = Document(text: text).images()
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].destination, "p/😀.png")
        XCTAssertEqual(images[0].alt, "alt e")
        XCTAssertEqual(images[0].title, "T")
        XCTAssertTrue(images[0].standalone)
        XCTAssertEqual(slice(text, images[0].range), "![alt *e*](p/😀.png \"T\")")
        XCTAssertNil(images[1].title)
        XCTAssertFalse(images[1].standalone)
    }

    func testProseRanges() {
        let text = "See [docs](http://x.y) and `code`."
        let prose = Document(text: text).proseRanges(within: nil).map { slice(text, $0) }
        XCTAssertEqual(prose, ["See ", "docs", " and ", "."])
    }

    func testMarkupSpansCarryOwnerAndScope() {
        let text = "x *a* y\n\n| *b* |\n|---|\n"
        let m = Document(text: text).markupSpans(within: nil)
        let star = m.filter { slice(text, $0.range) == "*" }
        XCTAssertEqual(star.count, 4)
        XCTAssertEqual(star[0].owner, Utf16Range(start: 2, end: 5))
        XCTAssertEqual(star[0].scope, MarkupScope.inline)
        XCTAssertFalse(star[0].inTable)
        XCTAssertTrue(star[2].inTable)
    }
}
