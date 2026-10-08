import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The Templates window (PLAN 3.21): the list, the read-only built-ins, a field change reaching the sample page and the disk,
/// undo, a click on the page choosing the element, the Light/Dark switch, delete with its confirmation, and the save on close.
@MainActor
final class TemplatesWindowTests: XCTestCase {
    private var tmp: URL!
    private var yours: URL { tmp.appendingPathComponent("yours") }
    private var builtIn: URL { Fixtures.root.appendingPathComponent("apps/macos/Resources/Templates") }
    private var controller: TemplatesWindowController!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("templates-window-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        controller = TemplatesWindowController(store: TemplateStore(builtInDirectory: builtIn, userDirectory: yours))
    }

    override func tearDownWithError() throws {
        controller.window?.orderOut(nil)
        controller = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private var editor: TemplateEditor { controller.editor }
    private var sample: TemplateSampleController { controller.sample }

    private func spin(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }

    /// Makes a template of your own and selects the h1 element.
    private func editableTemplate() throws {
        editor.newTemplate()
        XCTAssertFalse(editor.isReadOnly)
        editor.selectTarget("h1")
    }

    private func setH1Size(_ value: Double) {
        editor.binding(.h1, .fontSize, \.fontSize).wrappedValue = TemplateLength(value: value, unit: .em)
    }

    private func diskTOML() throws -> String {
        let package = try XCTUnwrap(editor.working).url
        return try String(contentsOf: package.appendingPathComponent("template.toml"), encoding: .utf8)
    }

    func testTheListHasTheBuiltInsAndYours() throws {
        XCTAssertEqual(editor.builtIn.map(\.name), ["Academic", "Default", "Letter", "Typewriter"])
        XCTAssertTrue(editor.yours.isEmpty)
        try editableTemplate()
        XCTAssertEqual(editor.yours.map(\.name), ["Untitled"])
        XCTAssertEqual(editor.working?.name, "Untitled")
        XCTAssertTrue(editor.select(named: "Academic"))
        XCTAssertEqual(editor.working?.name, "Academic")
    }

    func testABuiltInIsReadOnly() throws {
        XCTAssertTrue(editor.select(named: "Academic"))
        XCTAssertTrue(editor.isReadOnly)
        let css = editor.css
        setH1Size(9)
        XCTAssertEqual(editor.css, css)
        XCTAssertEqual(editor.style(for: .h1).fontSize, TemplateLength(value: 1.9, unit: .em))
        // Duplicate to edit: the copy is yours and takes the selection.
        editor.duplicateSelected()
        XCTAssertFalse(editor.isReadOnly)
        XCTAssertEqual(editor.working?.name, "Academic Copy")
        XCTAssertEqual(editor.style(for: .h1).weight, 700)
    }

    func testAFieldChangeRegeneratesTheCSSAndSavesAfterThePause() throws {
        try editableTemplate()
        setH1Size(2.6)
        XCTAssertTrue(editor.css.contains("font-size: 2.6em"))
        XCTAssertTrue(sample.pageStyle().contains("font-size: 2.6em"))
        // Not yet on disk: the pause has not passed.
        XCTAssertFalse(try diskTOML().contains("2.6em"))
        spin(TemplateEditor.saveDelay + 0.4)
        XCTAssertTrue(try diskTOML().contains("font_size = \"2.6em\""))
        // The store was told and still agrees with the editor.
        XCTAssertEqual(editor.store.template(named: "Untitled")?.style(.h1)?.fontSize, TemplateLength(value: 2.6, unit: .em))
    }

    func testUndoRevertsTheFieldAndTheCSS() throws {
        try editableTemplate()
        setH1Size(2.6)
        XCTAssertTrue(editor.undoManager.canUndo)
        editor.undoManager.undo()
        XCTAssertNil(editor.style(for: .h1).fontSize)
        XCTAssertFalse(editor.css.contains("font-size: 2.6em"))
        XCTAssertFalse(sample.pageStyle().contains("font-size: 2.6em"))
        editor.undoManager.redo()
        XCTAssertTrue(editor.css.contains("font-size: 2.6em"))
        // A run of changes to one field is one step; another field is another step.
        setH1Size(2.8)
        setH1Size(3)
        editor.binding(.h1, .weight, \.weight).wrappedValue = 800
        editor.undoManager.undo()
        XCTAssertNil(editor.style(for: .h1).weight)
        XCTAssertEqual(editor.style(for: .h1).fontSize?.value, 3)
        editor.undoManager.undo()
        XCTAssertEqual(editor.style(for: .h1).fontSize?.value, 2.6)
    }

    func testAClickOnThePageSelectsTheKind() throws {
        XCTAssertTrue(sample.waitUntilSettled())
        editor.selectTarget("body")
        _ = sample.evaluate("document.querySelector('h2').click(); return true;")
        spin(0.3)
        XCTAssertEqual(sample.clicks.last, "h2")
        XCTAssertEqual(editor.targetKey, "h2")
        XCTAssertEqual(sample.pageOutline(), "h2")
        // The innermost kind wins: a link inside a paragraph is the link, a tag is a tag (not the link it is also).
        XCTAssertEqual(sample.kind(atSelector: "p a"), "link")
        XCTAssertEqual(sample.kind(atSelector: ".tag"), "tag")
        XCTAssertEqual(sample.kind(atSelector: "p em"), "emphasis")
        XCTAssertEqual(sample.kind(atSelector: "p"), "paragraph")
    }

    func testLightAndDarkSwitchTheSampleTheme() throws {
        editor.setSampleDark(true)
        XCTAssertEqual(editor.sampleTheme.id, "dark")
        XCTAssertTrue(sample.pageStyle().contains("color-scheme: dark"))
        editor.setSampleDark(false)
        XCTAssertEqual(editor.sampleTheme.id, "light")
        XCTAssertTrue(sample.pageStyle().contains("color-scheme: light"))
    }

    func testDeleteAsksFirstAndThenRemoves() throws {
        try editableTemplate()
        controller.show()
        controller.confirmDelete()
        let window = try XCTUnwrap(controller.window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        // Cancel keeps it.
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        spin(0.2)
        XCTAssertEqual(editor.yours.map(\.name), ["Untitled"])
        controller.confirmDelete()
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        spin(0.3)
        XCTAssertTrue(editor.yours.isEmpty)
        XCTAssertEqual(editor.working?.name, "Default")
        XCTAssertFalse(FileManager.default.fileExists(atPath: yours.appendingPathComponent("Untitled.mdtemplate").path))
    }

    func testTheEditorSavesWhenTheWindowCloses() throws {
        try editableTemplate()
        controller.show()
        setH1Size(2.2)
        XCTAssertFalse(try diskTOML().contains("2.2em"))
        controller.window?.close()
        XCTAssertTrue(try diskTOML().contains("font_size = \"2.2em\""))
    }

    func testRenameKeepsTheSelectionAndTheStyles() throws {
        try editableTemplate()
        setH1Size(2.2)
        editor.rename(to: "Mine")
        XCTAssertEqual(editor.working?.name, "Mine")
        XCTAssertEqual(editor.yours.map(\.name), ["Mine"])
        XCTAssertEqual(editor.style(for: .h1).fontSize?.value, 2.2)
        XCTAssertTrue(try diskTOML().contains("2.2em"))
    }

    /// The window keeps the place it was moved to when shown again (its frame saved under the autosave name, which a
    /// window controller replaces with its own when it takes the window).
    func testFrameIsKeptWhereItWasMoved() throws {
        let key = "NSWindow Frame MarkdownTemplatesTest"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let controller = TemplatesWindowController(store: TemplateStore(builtInDirectory: builtIn, userDirectory: yours), frameName: "MarkdownTemplatesTest")
        defer { controller.window?.orderOut(nil); controller.windowFrameAutosaveName = "" }
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frameAutosaveName, "MarkdownTemplatesTest")
        controller.show()
        let moved = NSPoint(x: window.screen!.visibleFrame.minX + 30, y: window.screen!.visibleFrame.minY + 20)
        window.setFrameOrigin(moved)
        controller.close()
        controller.show()
        XCTAssertEqual(window.frame.origin, moved, "shown again where it was left, not centred")
    }
}

private extension InstalledTemplate {
    func style(_ kind: TemplateElementKind) -> TemplateElementStyle? { spec.elements.first { $0.kind == kind }?.style }
}
