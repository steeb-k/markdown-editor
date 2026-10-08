import AppKit
import XCTest
@testable import MarkdownKit

/// The Settings window as panes (PLAN 3.25): every preference has a row, the pane is remembered, the search finds rows by
/// title, section, pane and keyword, and the window's title follows the pane.
@MainActor
final class SettingsWindowTests: XCTestCase {
    /// The stored keys that are not preferences with a row of their own: geometry and sort order the windows keep for
    /// themselves, the library's folder grants, the older spellings of the side column's keys (read once, never written),
    /// and the pane memory.
    private let exempt: Set<String> = [
        "previewSplitRatio", "sidebarWidth", "sideColumnWidth", "outlineWidth", "outlineByDefault",
        "libraryFolders", "noteSort", "settingsPane",
    ]

    /// Every key the `Key` enum of `Settings` declares, read from the source so that a key added there is seen here.
    private func declaredKeys() throws -> Set<String> {
        let source = try String(contentsOf: Fixtures.root.appendingPathComponent("apps/macos/Sources/MarkdownKit/Settings.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "enum Key {"))
        let end = try XCTUnwrap(source.range(of: "static func syntaxClass", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let regex = try NSRegularExpression(pattern: #"static let \w+ = "([^"]+)""#)
        let found = regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { m in
            Range(m.range(at: 1), in: body).map { String(body[$0]) }
        }
        return Set(found).union(SyntaxClass.allCases.map { Settings.Key.syntaxClass($0) })
    }

    func testEveryPreferenceHasARow() throws {
        let declared = try declaredKeys()
        XCTAssertGreaterThan(declared.count, 25, "the scan of Settings.swift found too few keys")
        let rowKeys = Set(SettingsCatalog.rows.flatMap(\.keys))
        let missing = declared.subtracting(rowKeys).subtracting(exempt)
        XCTAssertTrue(missing.isEmpty, "Settings keys with no row in the Settings window and no exemption: \(missing.sorted())")
        let unknown = rowKeys.subtracting(declared)
        XCTAssertTrue(unknown.isEmpty, "rows name keys Settings does not declare: \(unknown.sorted())")
        XCTAssertTrue(rowKeys.isDisjoint(with: exempt), "a row for an exempt key: \(rowKeys.intersection(exempt).sorted())")
    }

    func testRowsAreDeclaredOnceAndBelongToAPane() {
        let ids = SettingsCatalog.rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two rows share a pane and title")
        for pane in SettingsPane.allCases {
            XCTAssertFalse(SettingsCatalog.rows.filter { $0.pane == pane }.isEmpty, "\(pane.rawValue) has no rows")
        }
    }

    func testPaneMemory() {
        let settings = isolatedSettings()
        XCTAssertEqual(SettingsModel(settings: settings).pane, .general)
        let model = SettingsModel(settings: settings)
        model.pane = .editor
        XCTAssertEqual(settings.settingsPane, "Editor")
        XCTAssertEqual(SettingsModel(settings: settings).pane, .editor, "a new window opens on the pane left")
        settings.settingsPane = "Nonsense"
        XCTAssertEqual(SettingsModel(settings: settings).pane, .general, "an unknown name falls back to General")
    }

    func testSearchMatchesTitleSectionPaneAndKeyword() {
        let settings = isolatedSettings()
        func titles(_ q: String) -> [String] { SettingsPane.allCases.flatMap { SettingsCatalog.rows(in: $0, matching: q, settings: settings).map(\.title) } }
        XCTAssertEqual(titles("spell"), ["Check spelling while typing", "Correct spelling automatically"])
        XCTAssertEqual(titles("width"), ["Line width"])
        XCTAssertEqual(titles("dark"), ["Theme"], "a keyword")
        XCTAssertEqual(titles("QUIT"), ["Ask before quitting"], "in any case")
        XCTAssertEqual(titles("exit"), ["Ask before quitting"], "a keyword of the row")
        XCTAssertEqual(titles("authorship").first, "Name for my text", "a pane's name finds its rows")
        XCTAssertEqual(titles("Chrome").count, 3, "a section's name finds its rows")
        XCTAssertEqual(titles("spelling typing"), ["Check spelling while typing"], "every word must be found, in any of the places")
        XCTAssertEqual(titles("").count, SettingsCatalog.rows.filter { $0.when(settings) }.count, "an empty query shows every row")
        XCTAssertTrue(titles("zzz").isEmpty)
    }

    func testDiacriticsAreIgnored() {
        let settings = isolatedSettings()
        // "centred" has no accent, so the query carries one the row does not: both ways must find it.
        XCTAssertEqual(SettingsCatalog.rows(in: .editor, matching: "cêntred", settings: settings).map(\.title), ["Keep the focused line centred"])
        XCTAssertEqual(SettingsCatalog.panes(matching: "RÉOPEN", settings: settings), [.general])
    }

    func testFamilyRowOnlyForACustomFont() {
        let settings = isolatedSettings()
        settings.fontChoice = .iaQuattro
        XCTAssertFalse(SettingsCatalog.rows(in: .appearance, matching: "", settings: settings).map(\.title).contains("Family"))
        settings.fontChoice = .custom
        XCTAssertTrue(SettingsCatalog.rows(in: .appearance, matching: "", settings: settings).map(\.title).contains("Family"))
    }

    func testSearchSelectsTheFirstMatchingPane() {
        let model = SettingsModel(settings: isolatedSettings())
        model.pane = .general
        model.query = "spell"
        XCTAssertEqual(model.pane, .checking)
        XCTAssertEqual(model.panes, [.checking])
        XCTAssertEqual(model.rows.map(\.title), ["Check spelling while typing", "Correct spelling automatically"])
        model.query = "width"
        XCTAssertEqual(model.pane, .appearance)
        model.query = ""
        XCTAssertEqual(model.pane, .appearance, "clearing keeps the pane")
        XCTAssertEqual(model.panes, SettingsPane.allCases)
        // A pane that still has a match is not left.
        model.pane = .editor
        model.query = "highlight"
        XCTAssertEqual(model.pane, .editor)
    }

    /// A pane's name typed while another pane is shown goes to that pane, not to the first pane with a row that mentions it
    /// ("Notes" went to General for its "Open new windows in Notes mode").
    func testAPanesNameSelectsThatPane() {
        let model = SettingsModel(settings: isolatedSettings())
        model.pane = .appearance
        model.query = "notes"
        XCTAssertEqual(model.pane, .notes)
        XCTAssertEqual(model.panes, [.general, .notes], "the other pane with a match is still listed")
        model.pane = .appearance
        model.query = "Authorsh"
        XCTAssertEqual(model.pane, .authorship, "as it is typed")
        model.pane = .general
        model.query = "notes"
        XCTAssertEqual(model.pane, .general, "a shown pane with a match is not left")
    }

    func testNoMatchAtAll() {
        let model = SettingsModel(settings: isolatedSettings())
        model.pane = .notes
        model.query = "zzz"
        XCTAssertTrue(model.panes.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.pane, .notes, "no pane to move to: the selection stays")
    }

    func testWindowTitleFollowsThePane() {
        let settings = isolatedSettings()
        settings.settingsPane = "Notes"
        let controller = SettingsWindowController(settings: settings)
        XCTAssertEqual(controller.window?.title, "Notes", "opens on the remembered pane")
        controller.model.pane = .documents
        XCTAssertEqual(controller.window?.title, "Documents")
        XCTAssertFalse(controller.window!.styleMask.contains(.resizable))
    }

    func testARowNamesTheKeyItEdits() {
        let row = SettingsCatalog.rows.first { $0.title == "Ask before quitting" }!
        XCTAssertEqual(row.keys, ["askBeforeQuitting"])
    }

    /// The window keeps the place it was moved to, when shown again and in the next launch: AppKit saves the frame under
    /// the autosave name, and a saved frame is not centred over.
    func testFrameIsKeptWhereItWasMoved() throws {
        let name = "MarkdownSettingsTest"
        let key = "NSWindow Frame \(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let controller = SettingsWindowController(settings: isolatedSettings(), frameName: name)
        let window = try XCTUnwrap(controller.window)
        controller.show()
        let moved = NSPoint(x: window.screen!.visibleFrame.minX + 40, y: window.screen!.visibleFrame.minY + 60)
        window.setFrameOrigin(moved)
        controller.close()
        controller.show()
        XCTAssertEqual(window.frame.origin, moved, "shown again where it was left, not centred")
        controller.close()
        // One window holds a name at a time in a process; the next launch's window is a new one in a new process.
        controller.windowFrameAutosaveName = ""
        let next = SettingsWindowController(settings: isolatedSettings(), frameName: name)
        next.show()
        XCTAssertEqual(next.window?.frame.origin, moved, "the next launch's window opens where it was left")
        next.close()
    }
}
