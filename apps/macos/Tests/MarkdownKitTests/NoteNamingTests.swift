import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The daily note's file name, the template variables and what a rename asks.
final class NoteNamingTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")

    /// Saturday 3 October 2026, 09:05:07 UTC.
    private var date: Date {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 10, day: 3, hour: 9, minute: 5, second: 7))!
    }

    private func name(_ format: String) -> String { DailyNote.name(for: date, format: format, calendar: calendar, locale: locale) }

    func testTheDefaultFormatIsTheIsoDate() {
        XCTAssertEqual(DailyNote.defaultFormat, "YYYY-MM-DD")
        XCTAssertEqual(name("YYYY-MM-DD"), "2026-10-03")
    }

    func testTokens() {
        XCTAssertEqual(name("YY"), "26")
        XCTAssertEqual(name("M/D"), "10-3", "a slash cannot be in a file name")
        XCTAssertEqual(name("MMMM D, YYYY"), "October 3, 2026")
        XCTAssertEqual(name("MMM DD"), "Oct 03")
        XCTAssertEqual(name("dddd"), "Saturday")
        XCTAssertEqual(name("ddd YYYY-MM-DD"), "Sat 2026-10-03")
        XCTAssertEqual(name("YYYYMMDD-HHmm"), "20261003-0905")
    }

    func testTextInBracketsIsKeptAsWritten() {
        XCTAssertEqual(name("[Week of] YYYY-MM-DD"), "Week of 2026-10-03")
        XCTAssertEqual(name("[YYYY] YYYY"), "YYYY 2026", "tokens in brackets are not filled in")
        XCTAssertEqual(name("YYYY [unclosed"), "2026 [unclosed")
        XCTAssertEqual(name("Daily YYYY"), "3aily 2026", "the D of a word is the day: brackets keep a word as written")
        XCTAssertEqual(name("[Daily] YYYY"), "Daily 2026")
    }

    func testTheNameIsAFileName() {
        XCTAssertEqual(name("HH:mm"), "09-05", "a colon is a slash to Finder")
        XCTAssertEqual(name("YYYY/MM/DD"), "2026-10-03")
        XCTAssertEqual(name("  YYYY  "), "2026")
        XCTAssertEqual(name(""), "2026-10-03", "an empty format falls back to the default")
        XCTAssertEqual(name("   "), "2026-10-03")
    }

    // MARK: templates

    func testTemplateVariables() {
        let v = NoteTemplates.variables(title: "My Note", date: date, dailyFormat: "DD.MM.YYYY", calendar: calendar, locale: locale)
        XCTAssertEqual(v["date"], "2026-10-03")
        XCTAssertEqual(v["time"], "09:05")
        XCTAssertEqual(v["title"], "My Note")
        XCTAssertEqual(v["today"], "03.10.2026", "today is in the daily note's format")
        XCTAssertEqual(Set(v.keys), ["date", "time", "title", "today"])
    }

    func testTemplatesExpandThroughTheCore() {
        let t = NoteTemplates.expand("# {{title}}\n\n{{date}} {{time}} ({{today}})\n\n{{cursor}}\n{{nothing}}", title: "Plan", date: date,
                                     dailyFormat: "YYYY-MM-DD", calendar: calendar, locale: locale)
        XCTAssertEqual(t.text, "# Plan\n\n2026-10-03 09:05 (2026-10-03)\n\n\n{{nothing}}")
        XCTAssertEqual(Int(t.cursor), ("# Plan\n\n2026-10-03 09:05 (2026-10-03)\n\n" as NSString).length)
    }

    func testTheCursorIsInUtf16Units() {
        let t = NoteTemplates.expand("\u{1F389}\u{65E5}{{cursor}}x", title: "t", date: date, dailyFormat: "YYYY", calendar: calendar, locale: locale)
        XCTAssertEqual(t.text, "\u{1F389}\u{65E5}x")
        XCTAssertEqual(t.cursor, 3, "the emoji is two units, the ideograph one")
    }

    func testTheTemplatesFolderListsNotesByName() throws {
        let lib = try TempLibrary(["T/Meeting.md": "m", "T/Daily.md": "d", "T/10 later.md": "x", "T/2 sooner.md": "x", "T/readme.png": "x", "T/.hidden.md": "x"])
        defer { lib.remove() }
        let names = NoteTemplates.list(in: lib.url.appendingPathComponent("T")).map(\.lastPathComponent)
        XCTAssertEqual(names, ["2 sooner.md", "10 later.md", "Daily.md", "Meeting.md"])
        XCTAssertEqual(NoteTemplates.list(in: lib.url.appendingPathComponent("Missing")), [])
    }

    // MARK: names

    func testWhatTheUserTypedAsAName() {
        XCTAssertEqual(NoteNaming.fileName(from: "  Plan B  "), "Plan B")
        XCTAssertEqual(NoteNaming.fileName(from: "a/b"), "a-b")
        XCTAssertEqual(NoteNaming.fileName(from: "Note: Colon"), "Note- Colon")
        XCTAssertNil(NoteNaming.fileName(from: ""))
        XCTAssertNil(NoteNaming.fileName(from: "   "))
        XCTAssertNil(NoteNaming.fileName(from: ".hidden"), "the library does not show hidden files")
        XCTAssertNil(NoteNaming.fileName(from: ".."))
    }

    func testRenamingKeepsTheExtensionUnlessAnotherNoteExtensionIsTyped() throws {
        let lib = try TempLibrary(["Idea.md": "x", "plain.txt": "x", "Folder/n.md": "x"])
        defer { lib.remove() }
        let md = lib.url.appendingPathComponent("Idea.md"), txt = lib.url.appendingPathComponent("plain.txt")
        XCTAssertEqual(NoteNaming.renamed(md, to: "Plan")?.lastPathComponent, "Plan.md")
        XCTAssertEqual(NoteNaming.renamed(md, to: "Plan.txt")?.lastPathComponent, "Plan.txt")
        XCTAssertEqual(NoteNaming.renamed(md, to: "v1.2")?.lastPathComponent, "v1.2.md", "a dot in a name is not an extension")
        XCTAssertEqual(NoteNaming.renamed(txt, to: "other")?.lastPathComponent, "other.txt")
        XCTAssertEqual(NoteNaming.renamed(txt, to: "other.markdown")?.lastPathComponent, "other.markdown")
        XCTAssertEqual(NoteNaming.renamed(lib.url.appendingPathComponent("Folder"), to: "Dir.md")?.lastPathComponent, "Dir.md", "a folder is renamed as typed")
        XCTAssertNil(NoteNaming.renamed(md, to: ""))
        XCTAssertEqual(NoteNaming.renamed(md, to: "x")?.deletingLastPathComponent().path, lib.url.path)
    }

    func testTheQuestionARenameAsks() {
        func edit(_ path: String) -> LibraryEdit { LibraryEdit(note: NoteRef(root: "r", path: path), range: Utf16Range(start: 0, end: 1), replacement: "x") }
        XCTAssertEqual(NoteNaming.linkUpdateQuestion([edit("a.md")]), "Update 1 link in 1 note?")
        XCTAssertEqual(NoteNaming.linkUpdateQuestion([edit("a.md"), edit("a.md"), edit("b.md")]), "Update 3 links in 2 notes?")
    }
}
