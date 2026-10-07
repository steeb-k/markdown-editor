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
}
