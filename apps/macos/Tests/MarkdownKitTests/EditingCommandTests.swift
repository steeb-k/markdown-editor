import XCTest
import MarkdownCore

/// The editing commands through the UniFFI bindings. An edit is applied to an
/// `NSMutableString` exactly as the shell would apply it to its text storage (UTF-16
/// offsets, no conversion), then checked against the selection the edit asks for.
final class EditingCommandTests: XCTestCase {
    private func nsRange(_ r: Utf16Range) -> NSRange {
        NSRange(location: Int(r.start), length: Int(r.end - r.start))
    }

    /// `‸` is the caret, `«…»` a selection.
    private func parse(_ marked: String) -> (text: String, selection: Utf16Range) {
        var text = ""
        var start: UInt32?
        var end: UInt32?
        var units: UInt32 = 0
        for ch in marked {
            switch ch {
            case "‸": start = units; end = units
            case "«": start = units
            case "»": end = units
            default:
                text.append(ch)
                units += UInt32(String(ch).utf16.count)
            }
        }
        return (text, Utf16Range(start: start!, end: end ?? start!))
    }

    private func render(_ text: NSString, _ sel: Utf16Range) -> String {
        let s = Int(sel.start), e = Int(sel.end)
        let before = text.substring(to: s)
        if s == e { return before + "‸" + text.substring(from: s) }
        return before + "«" + text.substring(with: NSRange(location: s, length: e - s)) + "»" + text.substring(from: e)
    }

    /// Run a command, apply its edit to an NSMutableString, and re-sync a Document with the
    /// result through `replace` (which must accept it). Returns the marked result or "None".
    private func apply(_ marked: String, _ command: (Document, Utf16Range) -> TextEdit?) throws -> String {
        let (text, sel) = parse(marked)
        let doc = Document(text: text)
        guard let edit = command(doc, sel) else { return "None" }
        let storage = NSMutableString(string: text)
        storage.replaceCharacters(in: nsRange(edit.range), with: edit.replacement)
        _ = try doc.replace(range: edit.range, with: edit.replacement)
        XCTAssertEqual(doc.text(), storage as String, "the core's text and the shell's agree")
        XCTAssertLessThanOrEqual(edit.selection.end, doc.len())
        return render(storage, edit.selection)
    }

    func testStrongWrapsAndUnwraps() throws {
        XCTAssertEqual(try apply("a «word» b") { $0.format(command: .strong, selection: $1) }, "a **«word»** b")
        XCTAssertEqual(try apply("a **«word»** b") { $0.format(command: .strong, selection: $1) }, "a «word» b")
        // The selection survives emoji (surrogate pairs) before it.
        XCTAssertEqual(try apply("🎉 é «日本» 👩‍💻") { $0.format(command: .emphasis, selection: $1) }, "🎉 é *«日本»* 👩‍💻")
    }

    func testLinkImageAndHeading() throws {
        XCTAssertEqual(try apply("see «text» now") { $0.format(command: .link, selection: $1) }, "see [text](‸) now")
        XCTAssertEqual(
            try apply("‸") { $0.format(command: .image(destination: "img/a b.png", alt: "pic"), selection: $1) },
            "![pic](<img/a b.png>)‸")
        XCTAssertEqual(try apply("te‸xt") { $0.format(command: .heading(level: 2), selection: $1) }, "## te‸xt")
        XCTAssertEqual(try apply("## te‸xt") { $0.format(command: .heading(level: 2), selection: $1) }, "te‸xt")
    }

    func testBlockCommands() throws {
        XCTAssertEqual(try apply("«a\nb»") { $0.format(command: .orderedList, selection: $1) }, "1. «a\n2. b»")
        XCTAssertEqual(try apply("a‸") { $0.format(command: .blockQuote, selection: $1) }, "> a‸")
        XCTAssertEqual(try apply("a‸") { $0.format(command: .taskList, selection: $1) }, "- [ ] a‸")
        XCTAssertEqual(try apply("«a\nb»") { $0.format(command: .codeBlock, selection: $1) }, "```\n«a\nb»\n```")
    }

    func testReturnContinuesAndEndsLists() throws {
        XCTAssertEqual(try apply("1. a‸\n2. b") { $0.newline(selection: $1) }, "1. a\n2. ‸\n3. b")
        XCTAssertEqual(try apply("- [x] a 🎉‸") { $0.newline(selection: $1) }, "- [x] a 🎉\n- [ ] ‸")
        XCTAssertEqual(try apply("- a\n- ‸") { $0.newline(selection: $1) }, "- a\n‸")
        XCTAssertEqual(try apply("plain‸") { $0.newline(selection: $1) }, "None")
    }

    func testTabIndentsListItems() throws {
        XCTAssertEqual(try apply("- a\n- b‸") { $0.indent(selection: $1, outdent: false) }, "- a\n  - b‸")
        XCTAssertEqual(try apply("- a\n  - b‸") { $0.indent(selection: $1, outdent: true) }, "- a\n- b‸")
        XCTAssertEqual(try apply("text‸") { $0.indent(selection: $1, outdent: false) }, "None")
    }

    func testToggleTaskFlipsTheBox() throws {
        let doc = Document(text: "x 🎉\n- [ ] todo")
        let at = UInt32("x 🎉\n- [ ] todo".utf16.count) - 2
        let edit = try XCTUnwrap(doc.toggleTask(at: at))
        let storage = NSMutableString(string: doc.text())
        storage.replaceCharacters(in: nsRange(edit.range), with: edit.replacement)
        XCTAssertEqual(storage as String, "x 🎉\n- [x] todo")
        XCTAssertEqual(edit.selection, Utf16Range(start: at, end: at))
        XCTAssertNil(doc.toggleTask(at: 0))
    }

    func testFormatState() {
        func state(_ marked: String) -> FormatState {
            let (text, sel) = parse(marked)
            return Document(text: text).formatState(selection: sel)
        }
        let bold = state("**bo‸ld**")
        XCTAssertTrue(bold.strong)
        XCTAssertFalse(bold.emphasis)
        XCTAssertEqual(state("### h‸").headingLevel, 3)
        XCTAssertEqual(state("1. a‸").list, .ordered)
        XCTAssertEqual(state("- [ ] a‸").list, .task)
        XCTAssertTrue(state("> q‸").inQuote)
        XCTAssertTrue(state("```\nco‸de\n```").inCodeBlock)
        XCTAssertTrue(state("| a |\n|---|\n| ‸1 |").inTable)
        XCTAssertTrue(state("see www.a.com/‸x").link)
        XCTAssertEqual(state("plain ‸text"), FormatState(
            strong: false, emphasis: false, strikethrough: false, inlineCode: false, link: false,
            headingLevel: 0, inQuote: false, list: .none, inCodeBlock: false, inTable: false))
    }

    func testTableCommands() throws {
        let t = "| ‸a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(
            try apply(t) { $0.tableCommand(command: .realign, selection: $1) },
            "| ‸a   | b   |\n| --- | --- |\n| 1   | 2   |")
        XCTAssertEqual(
            try apply(t) { $0.tableCommand(command: .setAlignment(alignment: .right), selection: $1) },
            "|   ‸a | b   |\n| --: | --- |\n|   1 | 2   |")
        XCTAssertEqual(
            try apply(t) { $0.tableCommand(command: .nextCell, selection: $1) },
            "| a   | «b»   |\n| --- | --- |\n| 1   | 2   |")
        // From the last cell a row is appended and its first cell gets the caret.
        XCTAssertEqual(
            try apply("| a | b |\n|---|---|\n| 1 | ‸2 |") { $0.tableCommand(command: .nextCell, selection: $1) },
            "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| ‸    |     |")
        XCTAssertEqual(
            try apply("| a | b |\n|---|---|\n| 1 | ‸2 |") { $0.tableCommand(command: .addColumnRight, selection: $1) },
            "| a   | b   |     |\n| --- | --- | --- |\n| 1   | 2   | ‸    |")
        XCTAssertEqual(try apply("outside‸") { $0.tableCommand(command: .addRowBelow, selection: $1) }, "None")
        XCTAssertEqual(
            try apply("‸") { $0.tableCommand(command: .insert(rows: 1, columns: 2), selection: $1) },
            "| ‸    |     |\n| --- | --- |\n|     |     |")
        // Display columns: CJK and emoji are two wide.
        XCTAssertEqual(
            try apply("| ‸日本 | b |\n|---|---|\n| x | 😀 |") { $0.tableCommand(command: .realign, selection: $1) },
            "| ‸日本 | b   |\n| ---- | --- |\n| x    | 😀  |")
    }

    func testNextCellWithoutTextChangeIsASelectionChange() throws {
        let aligned = "| a   | b   |\n| --- | --- |\n| 1   | 2   |"
        let doc = Document(text: aligned)
        let edit = try XCTUnwrap(doc.tableCommand(command: .nextCell, selection: Utf16Range(start: 2, end: 2)))
        XCTAssertEqual(edit.range.start, edit.range.end)
        XCTAssertEqual(edit.replacement, "")
        XCTAssertEqual(edit.selection, Utf16Range(start: 8, end: 9))
        XCTAssertNil(doc.tableCommand(command: .realign, selection: Utf16Range(start: 2, end: 2)))
    }

    func testTableInfo() throws {
        let text = "intro\n\n| a | b |\n|:-:|---|\n| 1 | 2 |"
        let doc = Document(text: text)
        XCTAssertNil(doc.tableAt(offset: 2))
        let info = try XCTUnwrap(doc.tableAt(offset: 9))
        XCTAssertEqual(info.rows, 2)
        XCTAssertEqual(info.columns, 2)
        XCTAssertEqual(info.row, 0)
        XCTAssertEqual(info.column, 0)
        XCTAssertEqual(info.alignments, [.center, .none])
    }

    func testBareURLIsALinkSpan() {
        let text = "see 🎉 https://example.com/a_b, ok"
        let doc = Document(text: text)
        let link = doc.spans(within: nil).first { $0.kind == .link }
        let u = Array(text.utf16)
        let r = try! XCTUnwrap(link).range
        XCTAssertEqual(String(decoding: u[Int(r.start)..<Int(r.end)], as: UTF16.self), "https://example.com/a_b")
        XCTAssertTrue(doc.spans(within: nil).filter { $0.kind == .markup }.isEmpty)
        let prose = doc.proseRanges(within: nil).map { String(decoding: u[Int($0.start)..<Int($0.end)], as: UTF16.self) }
        XCTAssertEqual(prose, ["see 🎉 ", ", ok"])
    }

    func testThemesLoad() throws {
        let themes = builtinThemes()
        XCTAssertEqual(themes.map { $0.id }, ["light", "dark", "sepia"])
        XCTAssertEqual(themes.map { $0.isDark }, [false, true, false])
        let dark = try XCTUnwrap(themeById(id: "dark"))
        XCTAssertEqual(dark.name, "Dark")
        XCTAssertEqual(dark.colors.background.a, 255)
        XCTAssertNotEqual(dark.colors.background, dark.colors.text)
        XCTAssertNil(themeById(id: "missing"))
        // Every theme paints a caret and a selection distinct from the page.
        for t in themes {
            XCTAssertNotEqual(t.colors.caret, t.colors.background)
            XCTAssertNotEqual(t.colors.selection, t.colors.background)
        }
    }
}
