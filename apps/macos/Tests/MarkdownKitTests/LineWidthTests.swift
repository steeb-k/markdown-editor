import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// View > Line Width and the document's own `line_width:` (PLAN 3.24): the presets and their checks, the front matter
/// edit as one undo step, and the editor's measure taking the document's width in place of the setting's.
@MainActor
final class LineWidthTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func open(_ text: String, settings: Settings = isolatedSettings()) throws -> (MarkdownDocument, EditorWindowController) {
        let doc = MarkdownDocument(settings: settings)
        try doc.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        _ = wc.window
        XCTAssertTrue(doc.session.waitUntilStyled())
        return (doc, wc)
    }

    private func lineWidthMenu() throws -> NSMenu {
        let view = MainMenu.build().items.first { $0.title == "View" }?.submenu
        let menu = try XCTUnwrap(view?.items.first { $0.title == "Line Width" }?.submenu)
        let actual = try XCTUnwrap(view?.items.firstIndex { $0.title == "Actual Size" })
        XCTAssertEqual(view?.items[actual + 1].title, "Line Width", "the submenu comes right after Actual Size")
        return menu
    }

    /// The items before the separator, or after "This Document".
    private func items(_ menu: NSMenu, document: Bool) throws -> [NSMenuItem] {
        let split = try XCTUnwrap(menu.items.firstIndex(where: \.isSeparatorItem))
        return document ? Array(menu.items[(split + 2)...]) : Array(menu.items[..<split])
    }

    /// The titles checked in a section after the menu is validated the way AppKit does it.
    private func checked(_ menu: NSMenu, document: Bool, in wc: EditorWindowController?) throws -> [String] {
        LineWidthMenu.shared.refresh(menu, for: wc)
        return try items(menu, document: document).filter { !$0.isHidden }.compactMap { item in
            if item.action != nil, item.action != LineWidthMenu.infoAction {
                if document { _ = wc?.validateMenuItem(item) } else { _ = AppDelegate().validateMenuItem(item) }
            }
            return item.state == .on ? item.title : nil
        }
    }

    private func withSetting(_ width: Int, _ body: () throws -> Void) rethrows {
        let old = Settings.shared.lineWidth
        Settings.shared.lineWidth = width
        defer { Settings.shared.lineWidth = old }
        try body()
    }

    func testTheMenuHasThePresetsTheHeaderAndUseSetting() throws {
        let menu = try lineWidthMenu()
        let titles = menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title }
        XCTAssertEqual(titles, ["Narrow", "Normal", "Wide", "-", "This Document", "Narrow", "Normal", "Wide", "Use Setting"])
        let choices = { (document: Bool) in try self.items(menu, document: document).filter { $0.action != LineWidthMenu.infoAction } }
        XCTAssertEqual(try choices(false).map(\.tag), [56, 72, 96])
        XCTAssertEqual(try choices(true).map(\.tag), [56, 72, 96, 0])
        let header = try XCTUnwrap(menu.items.first { $0.title == "This Document" })
        XCTAssertFalse(AppDelegate().validateMenuItem(header), "the header is never enabled")
        XCTAssertEqual(try choices(false).map(\.keyEquivalent), ["-", "0", "="])
        for item in try choices(false) {
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .control, .option])
        }
    }

    func testTheShortcutsAreNotTakenByAnotherItem() throws {
        let main = MainMenu.build()
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        for key in ["-", "0", "="] {
            let same = all(main).filter { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == [.command, .control, .option] }
            XCTAssertEqual(same.count, 1, "\(key) with Control-Option-Command")
        }
    }

    func testTheSettingsChecksFollowTheSetting() throws {
        let menu = try lineWidthMenu()
        for (title, width) in [("Narrow", 56), ("Normal", 72), ("Wide", 96)] {
            try withSetting(width) { XCTAssertEqual(try checked(menu, document: false, in: nil), [title]) }
        }
        try withSetting(80) {
            XCTAssertEqual(try checked(menu, document: false, in: nil), ["Custom (80)"])
            let custom = try XCTUnwrap(try items(menu, document: false).first { !$0.isHidden && $0.state == .on })
            XCTAssertFalse(AppDelegate().validateMenuItem(custom), "Custom is shown, checked and disabled")
        }
    }

    func testAPresetSetsTheSetting() throws {
        let menu = try lineWidthMenu()
        try withSetting(72) {
            let wide = try XCTUnwrap(try items(menu, document: false).first { $0.title == "Wide" })
            AppDelegate().setLineWidthPreset(wide)
            XCTAssertEqual(Settings.shared.lineWidth, 96)
        }
    }

    func testTheDocumentChecksFollowTheFrontMatter() throws {
        let menu = try lineWidthMenu()
        let (_, plain) = try open("# Title\n")
        XCTAssertEqual(try checked(menu, document: true, in: plain), ["Use Setting"])
        for (key, title) in [("56", "Narrow"), ("72", "Normal"), ("96", "Wide"), ("\"96\"", "Wide"), ("80", "Custom (80)")] {
            let (_, wc) = try open("---\nline_width: \(key)\n---\n\n# Title\n")
            XCTAssertEqual(try checked(menu, document: true, in: wc), [title], key)
        }
        // Anything the core does not read as a width is no key.
        for bad in ["abc", "0", "999", "56px"] {
            let (_, wc) = try open("---\nline_width: \(bad)\n---\n\n# Title\n")
            XCTAssertEqual(try checked(menu, document: true, in: wc), ["Use Setting"], bad)
        }
    }

    func testTheMeasureTakesTheDocumentsWidthOverTheSetting() throws {
        let settings = isolatedSettings()
        settings.lineWidth = 72
        let (_, plain) = try open("# Title\n", settings: settings)
        XCTAssertEqual(plain.session.appearance.maxCharacters, 72)
        let (_, narrow) = try open("---\nline_width: 56\n---\n\n# Title\n", settings: settings)
        XCTAssertEqual(narrow.session.appearance.maxCharacters, 56)
        XCTAssertEqual(narrow.session.appearance.settingsCharacters, 72)
        let zero = ("0" as NSString).size(withAttributes: [.font: narrow.session.appearance.fonts.body]).width
        XCTAssertEqual(narrow.session.appearance.measure, (zero * 56).rounded())
        // The setting still moves the documents without a key and leaves the one with it.
        settings.lineWidth = 96
        plain.session.refreshAppearance()
        narrow.session.refreshAppearance()
        XCTAssertEqual(plain.session.appearance.maxCharacters, 96)
        XCTAssertEqual(narrow.session.appearance.maxCharacters, 56)
        // The preview's column is the setting's whatever the document says.
        XCTAssertEqual(PreviewTypography.make(from: narrow.session.appearance).measureCh, 96)
    }

    func testAChoiceIsOneUndoStepAndTheMeasureFollowsIt() throws {
        let (doc, wc) = try open("# Title\n")
        let session = wc.session
        let before = session.appearance.maxCharacters
        let menu = try lineWidthMenu()
        let narrow = try XCTUnwrap(try items(menu, document: true).first { $0.title == "Narrow" })
        XCTAssertTrue(wc.validateMenuItem(narrow))
        wc.setDocumentLineWidth(narrow)
        XCTAssertEqual(session.text, "---\nline_width: 56\n---\n\n# Title\n")
        XCTAssertTrue(spin { session.appearance.maxCharacters == 56 })
        let um = try XCTUnwrap(doc.undoManager)
        XCTAssertEqual(um.undoActionName, "Change Line Width")
        um.undo()
        XCTAssertEqual(session.text, "# Title\n")
        XCTAssertTrue(spin { session.appearance.maxCharacters == before })
        um.redo()
        XCTAssertTrue(spin { session.appearance.maxCharacters == 56 })
        let use = try XCTUnwrap(try items(menu, document: true).first { $0.title == "Use Setting" })
        wc.setDocumentLineWidth(use)
        XCTAssertEqual(session.text, "# Title\n")
        XCTAssertTrue(spin { session.appearance.maxCharacters == before })
    }

    func testAKeyEditedByHandMovesTheColumn() throws {
        let (_, wc) = try open("---\nline_width: 56\n---\n\n# Title\n")
        let session = wc.session
        XCTAssertEqual(session.appearance.maxCharacters, 56)
        let at = (session.text as NSString).range(of: "56")
        // The core is asked on its own queue after the edit, so the column follows a moment later.
        session.storage.replaceCharacters(in: at, with: "90")
        XCTAssertTrue(spin { session.appearance.maxCharacters == 90 })
        session.storage.replaceCharacters(in: NSRange(location: at.location, length: 2), with: "9x")
        XCTAssertTrue(spin { session.appearance.maxCharacters == session.settings.lineWidth }, "an unreadable value is no key")
    }

    func testTwoDocumentsKeepTheirOwnWidths() throws {
        let settings = isolatedSettings()
        let (_, a) = try open("---\nline_width: 56\n---\n\nA\n", settings: settings)
        let (_, b) = try open("B\n", settings: settings)
        settings.lineWidth = 96
        a.session.refreshAppearance()
        b.session.refreshAppearance()
        XCTAssertEqual(a.session.appearance.maxCharacters, 56)
        XCTAssertEqual(b.session.appearance.maxCharacters, 96)
    }
}
