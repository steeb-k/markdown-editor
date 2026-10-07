import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// What a click on the Templates window's sample page selects, for elements inside others (the Opus pass, 7 October).
@MainActor
final class TemplateSampleClickTests: XCTestCase {
    private var tmp: URL!
    private var controller: TemplatesWindowController!
    private var sample: TemplateSampleController { controller.sample }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("template-click-\(UUID().uuidString)")
        let builtIn = Fixtures.root.appendingPathComponent("apps/macos/Resources/Templates")
        controller = TemplatesWindowController(store: TemplateStore(builtInDirectory: builtIn, userDirectory: tmp))
        XCTAssertTrue(sample.waitUntilSettled())
    }

    override func tearDownWithError() throws {
        controller.window?.orderOut(nil)
        controller = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The innermost element with a kind is what a click names (PLAN 3.21), through elements inside others.
    func testNestedElementsNameTheInnermostKind() throws {
        // The sample has no heading with a link, quote with code or list item with a tag: they are put on the page.
        _ = sample.evaluate("""
            const m = document.getElementById('md');
            m.insertAdjacentHTML('beforeend', '<h2 id="t-h2">Head <a id="t-h2a" href="#">link</a></h2>'
              + '<blockquote><p id="t-qp">quoted <code id="t-qc">code</code></p></blockquote>'
              + '<ul><li id="t-li">item <a class="tag" id="t-tag" href="#">#tag</a></li></ul>');
            return true;
            """)
        let want: [(String, String)] = [
            ("#t-h2a", "link"), ("#t-h2", "h2"), ("#t-qc", "inline_code"), ("#t-tag", "tag"), ("#t-li", "bullet_list"),
            ("img", "image"), ("th", "table_header"), ("td", "table"), ("pre code span", "code_block"),
            ("li.task-list-item input", "task_item"), ("sup a", "link"), ("hr", "rule"), ("p em", "emphasis"),
            // A paragraph inside a quote, a loose list item or the footnotes names the container (PLAN 3.22); one in the body is a paragraph.
            ("blockquote p", "block_quote"), ("li > p", "bullet_list"), (".footnotes p", "footnotes"), ("#t-qp", "block_quote"),
            ("#md > p", "paragraph"),
        ]
        for (selector, kind) in want { XCTAssertEqual(sample.kind(atSelector: selector), kind, selector) }
        // What the page reports for a click is what the inspector shows, and the outline follows.
        let editor = controller.editor
        _ = sample.evaluate("document.getElementById('t-h2a').click(); return true;")
        let end = Date(timeIntervalSinceNow: 2)
        while editor.targetKey != "link", Date() < end { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertEqual(editor.targetKey, "link")
        XCTAssertEqual(sample.pageOutline(), "a")
    }

    /// A paragraph names the nearest container it is the text of, through containers inside others (the M11d pass).
    func testAParagraphNamesItsNearestContainer() throws {
        // What the renderer writes for these, put on the page: a quote in a loose list item, a loose list in a quote, a
        // loose task list, a quote holding a heading and a code block, and a footnote's own list and back link.
        _ = sample.evaluate("""
            const m = document.getElementById('md');
            m.insertAdjacentHTML('beforeend',
                '<ul><li><p id="t-lp">item</p><blockquote><p id="t-lqp">quote in a list <em id="t-lqe">em</em></p></blockquote></li></ul>'
              + '<blockquote><ol><li><p id="t-qlp">list in a quote <a id="t-qla" href="#">a</a></p></li></ol></blockquote>'
              + '<ul><li class="task-list-item"><p id="t-tp"><input type="checkbox" disabled> loose task</p></li></ul>'
              + '<blockquote id="t-q"><h3 id="t-qh">Heading in a quote</h3><pre id="t-qpre"><code>code</code></pre></blockquote>');
            return true;
            """)
        let want: [(String, String)] = [
            ("#t-lp", "bullet_list"), ("#t-lqp", "block_quote"), ("#t-lqe", "emphasis"),
            ("#t-qlp", "numbered_list"), ("#t-qla", "link"),
            ("#t-tp", "task_item"), ("#t-tp input", "task_item"),
            ("#t-qh", "h3"), ("#t-qpre", "code_block"), ("#t-q", "block_quote"),
            // The footnotes' list and items are the section; an inline element in them is its own kind.
            (".footnotes ol", "footnotes"), (".footnotes li", "footnotes"), (".footnote-backref", "link"),
            (".footnotes", "footnotes"),
        ]
        for (selector, kind) in want { XCTAssertEqual(sample.kind(atSelector: selector), kind, selector) }
    }
}
