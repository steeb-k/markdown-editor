import Foundation
import XCTest
import MarkdownCore

/// UTF-16 ranges from the core must index `NSString` (what `NSTextView` uses) directly, and
/// one `Document` must be usable from several threads at once.
final class UnicodeAndThreadingTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        // Tests/MarkdownKitTests/<this file> -> repository root -> fixtures/
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("fixtures/\(name)"), encoding: .utf8)
    }

    private func ns(_ r: Utf16Range) -> NSRange {
        NSRange(location: Int(r.start), length: Int(r.end - r.start))
    }

    func testUnicodeFixtureSpansIndexNSString() throws {
        let text = try fixture("unicode.md")
        let s = text as NSString
        let doc = Document(text: text)
        XCTAssertEqual(Int(doc.len()), s.length)

        let spans = doc.spans(within: nil)
        XCTAssertFalse(spans.isEmpty)
        for span in spans {
            XCTAssertLessThanOrEqual(Int(span.range.end), s.length)
            // A range inside a surrogate pair would make NSString return a lone surrogate.
            let sub = s.substring(with: ns(span.range))
            XCTAssertFalse(sub.unicodeScalars.contains { $0.value == 0xFFFD }, "\(span)")
        }
        func texts(_ kind: SpanKind) -> [String] {
            spans.filter { $0.kind == kind }.map { s.substring(with: ns($0.range)) }
        }
        XCTAssertEqual(texts(.heading(level: 1)), ["# Unicode 🎉"])
        XCTAssertEqual(texts(.strong), ["**太字**"])
        XCTAssertEqual(texts(.emphasis), ["*✨*"])
        XCTAssertEqual(texts(.markup), ["# ", "**", "**", "*", "*"])
        XCTAssertEqual(texts(.listMarker(ordered: false)), ["-", "-"])

        // Prose and blocks index NSString the same way.
        let prose = doc.proseRanges(within: nil).map { s.substring(with: ns($0)) }
        XCTAssertTrue(prose.contains("Emoji: 👩‍💻 🇯🇵 🎉"), "\(prose)")
        XCTAssertTrue(prose.contains("太字"))
        let heading = try XCTUnwrap(doc.blocks().first)
        XCTAssertEqual(s.substring(with: ns(heading.range)), "# Unicode 🎉")
    }

    func testEditsInNSStringUnitsMatchNSStringEdits() throws {
        let text = try fixture("unicode.md")
        let doc = Document(text: text)
        let storage = NSMutableString(string: text)
        // Replace each emoji/flag/ZWJ sequence's whole UTF-16 range, as NSTextView would.
        for needle in ["👩‍💻", "🇯🇵", "é", "**太字**"] {
            let r = (storage as NSString).range(of: needle)
            XCTAssertNotEqual(r.location, NSNotFound)
            let u = try doc.replace(range: Utf16Range(start: UInt32(r.location), end: UInt32(r.location + r.length)), with: "<\(needle.count)>")
            storage.replaceCharacters(in: r, with: "<\(needle.count)>")
            XCTAssertEqual(doc.text(), storage as String)
            XCTAssertLessThanOrEqual(Int(u.dirty.start), r.location)
            XCTAssertLessThanOrEqual(Int(u.dirty.end), storage.length)
        }
    }

    func testRangeInsideASurrogatePairIsASwiftError() {
        let doc = Document(text: "a🎉b")
        do {
            _ = try doc.replace(range: Utf16Range(start: 2, end: 2), with: "x")
            XCTFail("expected an error")
        } catch let e as EditError {
            XCTAssertEqual(e, .NotOnCodePointBoundary)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
        XCTAssertEqual(doc.text(), "a🎉b")
    }

    func testParserPanicDoesNotCrashTheApp() throws {
        // pulldown-cmark 0.13.4 panics on this text; the core must contain it.
        let doc = Document(text: ">1. [r]:u\n")
        let u = try doc.replace(range: Utf16Range(start: doc.len(), end: doc.len()), with: "\t")
        XCTAssertEqual(u.revision, 1)
        XCTAssertEqual(doc.text(), ">1. [r]:u\n\t")
        _ = doc.spans(within: nil)
    }

    func testDocumentIsUsableFromManyThreads() throws {
        let doc = Document(text: String(repeating: "para *em* `c` 🎉\n\n", count: 200))
        let writers = 8, perWriter = 50
        DispatchQueue.concurrentPerform(iterations: writers * 2) { i in
            if i < writers {
                for _ in 0..<perWriter {
                    // Insert at the start: always a valid boundary whatever others did.
                    _ = try? doc.replace(range: Utf16Range(start: 0, end: 0), with: "x")
                }
            } else {
                for _ in 0..<perWriter {
                    let len = doc.len()
                    for s in doc.spans(within: nil) { XCTAssertLessThanOrEqual(s.range.end, max(len, doc.len())) }
                    _ = doc.blocks()
                    _ = doc.proseRanges(within: Utf16Range(start: 0, end: len / 2))
                    _ = doc.markupSpans(within: nil)
                }
            }
        }
        XCTAssertEqual(doc.revision(), UInt64(writers * perWriter))
        XCTAssertTrue(doc.text().hasPrefix(String(repeating: "x", count: writers * perWriter) + "para"))
        // The final state equals a fresh analysis of the final text.
        let fresh = Document(text: doc.text())
        XCTAssertEqual(doc.spans(within: nil), fresh.spans(within: nil))
    }
}
