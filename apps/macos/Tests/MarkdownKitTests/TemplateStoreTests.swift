import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// The template store (PLAN 3.21): the built-in and the user's packages, unique names, copies, import and export, the CSS
/// a template gives and which template a document gets.
@MainActor
final class TemplateStoreTests: XCTestCase {
    private var tmp: URL!
    private var yours: URL { tmp.appendingPathComponent("yours") }
    private var builtIn: URL { Fixtures.root.appendingPathComponent("apps/macos/Resources/Templates") }
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("template-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func store() -> TemplateStore { TemplateStore(builtInDirectory: builtIn, userDirectory: yours) }

    private func theme() -> (Theme, Typography) {
        let appearance = EditorAppearance(settings: isolatedSettings(), appearance: NSAppearance(named: .aqua))
        return (appearance.theme, PreviewTypography.make(from: appearance))
    }

    // MARK: reading

    func testTheFourBuiltInsLoadReadOnlyAndDefaultIsEmpty() throws {
        let s = store()
        XCTAssertEqual(s.builtIn.map(\.name).sorted(), ["Academic", "Default", "Letter", "Typewriter"])
        XCTAssertTrue(s.builtIn.allSatisfy { $0.isBuiltIn && $0.isUsable })
        XCTAssertTrue(s.yours.isEmpty)
        let d = try XCTUnwrap(s.template(named: "Default"))
        XCTAssertEqual(d.spec, TemplateStore.emptySpec)
        XCTAssertFalse(try XCTUnwrap(s.template(named: "Academic")).spec.elements.isEmpty)
        XCTAssertThrowsError(try s.save(d)) { XCTAssertEqual($0 as? TemplateStoreError, .readOnly("Default")) }
        XCTAssertThrowsError(try s.delete(d))
        XCTAssertThrowsError(try s.rename(d, to: "Other"))
    }

    func testAMissingBuiltInFolderStillHasADefault() {
        let s = TemplateStore(builtInDirectory: tmp.appendingPathComponent("nothing"), userDirectory: yours)
        XCTAssertEqual(s.builtInDefault.name, "Default")
        XCTAssertEqual(s.builtInDefault.spec, TemplateStore.emptySpec)
    }

    func testTheUserFolderIsMadeOnFirstWrite() throws {
        let s = store()
        XCTAssertFalse(FileManager.default.fileExists(atPath: yours.path))
        let t = try s.create("Mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: yours.appendingPathComponent("Mine.mdtemplate/template.toml").path))
        XCTAssertEqual(s.yours.map(\.name), ["Mine"])
        XCTAssertFalse(t.isBuiltIn)
        XCTAssertFalse(t.hasCustomCSS)
    }

    func testNamesAreUniqueCaseInsensitively() throws {
        let s = store()
        XCTAssertEqual(s.uniqueName(), "Untitled")
        XCTAssertEqual(try s.create().name, "Untitled")
        XCTAssertEqual(try s.create().name, "Untitled 2")
        XCTAssertEqual(try s.create("untitled").name, "untitled 3")
        XCTAssertEqual(s.uniqueName("ACADEMIC"), "ACADEMIC", "a built-in's name is free: yours takes its place")
        XCTAssertEqual(s.uniqueName("  "), "Untitled 4")
    }

    // MARK: yours overrides a built-in of the same name (PLAN 3.22)

    func testYoursTakesTheNameOfABuiltIn() throws {
        let s = store()
        let builtInAcademic = try XCTUnwrap(s.template(named: "Academic"))
        XCTAssertTrue(builtInAcademic.isBuiltIn)
        let copy = try s.duplicate(builtInAcademic, as: "Academic")
        XCTAssertEqual(copy.name, "Academic", "unique among yours only")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(try XCTUnwrap(s.template(named: "academic")).url, copy.url, "yours is what the name means")
        XCTAssertEqual(s.usable.filter { $0.name == "Academic" }.map(\.isBuiltIn), [false], "listed once, as yours")
        XCTAssertEqual(s.usable.map(\.name), ["Academic", "Default", "Letter", "Typewriter"])
        XCTAssertEqual(s.resolve(frontMatterName: "ACADEMIC", defaultName: "Default").template.url, copy.url)
        // The built-in is still in the list, hidden.
        XCTAssertEqual(s.builtIn.map(\.name).sorted(), ["Academic", "Default", "Letter", "Typewriter"])
        XCTAssertTrue(s.isHidden(builtInAcademic))
        XCTAssertFalse(s.isHidden(try XCTUnwrap(s.template(named: "Letter"))))
        XCTAssertFalse(s.isHidden(copy))
        // A second of yours by that name is still made unique.
        XCTAssertEqual(try s.duplicate(builtInAcademic, as: "Academic").name, "Academic 2")
        // Deleting yours brings the built-in back.
        try s.delete(copy)
        try s.delete(try XCTUnwrap(s.yours.first))
        XCTAssertTrue(try XCTUnwrap(s.template(named: "Academic")).isBuiltIn)
        XCTAssertFalse(s.isHidden(builtInAcademic))
    }

    func testRenamingToABuiltInsNameTakesItsPlaceAndTheBuiltInDefaultCanBeOverridden() throws {
        let s = store()
        let mine = try s.create("Mine")
        let renamed = try s.rename(mine, to: "Default")
        XCTAssertEqual(renamed.name, "Default")
        XCTAssertFalse(try XCTUnwrap(s.template(named: "Default")).isBuiltIn)
        XCTAssertTrue(s.builtInDefault.isBuiltIn, "the bundle's Default is still the built-in default")
        XCTAssertEqual(s.usable.filter { $0.name == "Default" }.count, 1)
    }

    func testAnImportNamedLikeABuiltInTakesItsPlace() throws {
        let s = store()
        let css = tmp.appendingPathComponent("Letter.css")
        try "body { color: red; }".write(to: css, atomically: true, encoding: .utf8)
        let imported = try s.importTemplate(at: css)
        XCTAssertEqual(imported.name, "Letter")
        XCTAssertEqual(try XCTUnwrap(s.template(named: "Letter")).url, imported.url)
    }

    // MARK: packages with a stylesheet only

    func testAPackageWithOnlyCustomCSSIsATemplateUnderItsFolderName() throws {
        let package = yours.appendingPathComponent("Sheet Only.mdtemplate")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "body { color: blue; }".write(to: package.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        let s = store()
        let t = try XCTUnwrap(s.template(named: "Sheet Only"))
        XCTAssertTrue(t.isUsable)
        XCTAssertNil(t.error)
        XCTAssertEqual(t.spec, TemplateStore.emptySpec)
        XCTAssertEqual(t.customCSS, "body { color: blue; }")
        XCTAssertTrue(s.usable.contains { $0.name == "Sheet Only" })
        // Editable: the first save writes the TOML; the CSS is left.
        try s.save(t)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("template.toml").path))
        XCTAssertEqual(try String(contentsOf: package.appendingPathComponent("custom.css"), encoding: .utf8), "body { color: blue; }")
        // Exportable.
        let out = tmp.appendingPathComponent("out.mdtemplate")
        try s.export(t, to: out, zipped: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("custom.css").path))
    }

    func testAPackageWithNeitherFileIsUnreadable() throws {
        let package = yours.appendingPathComponent("Empty.mdtemplate")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let s = store()
        let t = try XCTUnwrap(s.yours.first { $0.name == "Empty" })
        XCTAssertEqual(t.error, "no template.toml or custom.css")
        XCTAssertNil(s.template(named: "Empty"))
    }

    func testDuplicateRenameSaveDeleteRoundTrip() throws {
        let s = store()
        let academic = try XCTUnwrap(s.template(named: "Academic"))
        var copy = try s.duplicate(academic, as: "Thesis")
        XCTAssertEqual(copy.name, "Thesis")
        XCTAssertEqual(copy.spec, academic.spec)
        XCTAssertEqual(copy.meta.name, "Thesis")
        XCTAssertEqual(try s.duplicate(academic, as: "thesis").name, "thesis 2")

        // Saved, then read back by another store.
        copy.spec.page.measureCh = 50
        try s.save(copy)
        XCTAssertEqual(store().template(named: "Thesis")?.spec.page.measureCh, 50)

        let renamed = try s.rename(try XCTUnwrap(s.template(named: "Thesis")), to: "Dissertation")
        XCTAssertEqual(renamed.name, "Dissertation")
        XCTAssertNil(s.template(named: "Thesis"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: yours.appendingPathComponent("Dissertation.mdtemplate/template.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: yours.appendingPathComponent("Thesis.mdtemplate").path))
        XCTAssertEqual(renamed.spec.page.measureCh, 50)

        // A change of capitals only keeps the name asked for.
        XCTAssertEqual(try s.rename(renamed, to: "dissertation").name, "dissertation")
        XCTAssertEqual(s.yours.count, 2)

        let before = s.templates.count
        try s.delete(try XCTUnwrap(s.template(named: "dissertation")))
        XCTAssertEqual(s.templates.count, before - 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: yours.appendingPathComponent("Dissertation.mdtemplate").path))
    }

    func testDuplicateKeepsCustomCSS() throws {
        let s = store()
        let t = try s.create("Base")
        try "p { color: red; }".write(to: t.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        s.reload()
        let copy = try s.duplicate(try XCTUnwrap(s.template(named: "Base")), as: "Base copy")
        XCTAssertEqual(copy.customCSS, "p { color: red; }")
        XCTAssertTrue(copy.hasCustomCSS)
    }

    func testABrokenPackageIsListedWithItsErrorAndLeftOutOfResolution() throws {
        let broken = yours.appendingPathComponent("Broken.mdtemplate")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "this is [not toml".write(to: broken.appendingPathComponent("template.toml"), atomically: true, encoding: .utf8)
        let badValue = yours.appendingPathComponent("Bad Value.mdtemplate")
        try FileManager.default.createDirectory(at: badValue, withIntermediateDirectories: true)
        try "[template]\nname = \"Bad Value\"\n[elements.h1]\nweight = 5000\n".write(to: badValue.appendingPathComponent("template.toml"), atomically: true, encoding: .utf8)
        let s = store()
        let listed = try XCTUnwrap(s.yours.first { $0.name == "Broken" })
        XCTAssertNotNil(listed.error)
        XCTAssertFalse(listed.isUsable)
        XCTAssertNil(s.template(named: "Broken"))
        XCTAssertFalse(s.usable.contains { $0.name == "Broken" })
        XCTAssertTrue(try XCTUnwrap(s.yours.first { $0.name == "Bad Value" }).error?.contains("weight") ?? false)
        let r = s.resolve(frontMatterName: "Broken", defaultName: "Default")
        XCTAssertEqual(r.template.name, "Default")
        XCTAssertEqual(r.note, "Broken (could not be read)")
    }

    func testChangesMadeOutsideTheAppAreSeen() throws {
        let s = store()
        let t = try s.create("Outside")
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: TemplateStore.didChangeNotification, object: s, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        s.reloadIfChanged()
        XCTAssertEqual(posted, 0, "nothing changed")
        Thread.sleep(forTimeInterval: 0.02)
        try "h1 { color: blue; }".write(to: t.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        s.reloadIfChanged()
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(s.template(named: "Outside")?.customCSS, "h1 { color: blue; }")
    }

    // MARK: import and export

    func testImportsAnIATemplateBundle() throws {
        let s = store()
        let t = try s.importTemplate(at: fixtures.appendingPathComponent("Sample.iatemplate"))
        XCTAssertEqual(t.name, "Sample Look", "from Info.plist's CFBundleName")
        XCTAssertEqual(t.spec, TemplateStore.emptySpec)
        XCTAssertEqual(t.customCSS, "body { color: #123456; }\n\nh1 { letter-spacing: 3px; }\n", "style.css, then title.css")
        XCTAssertEqual(store().template(named: "Sample Look")?.customCSS, t.customCSS, "on disk")
        XCTAssertEqual(try s.importTemplate(at: fixtures.appendingPathComponent("Sample.iatemplate")).name, "Sample Look 2")
    }

    func testAnIATemplateWithoutAPlistTakesTheFolderName() throws {
        let bundle = tmp.appendingPathComponent("Plain Look.iatemplate/Contents/Resources")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "p { margin: 0; }".write(to: bundle.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        let t = try store().importTemplate(at: tmp.appendingPathComponent("Plain Look.iatemplate"))
        XCTAssertEqual(t.name, "Plain Look")
        XCTAssertEqual(t.customCSS, "p { margin: 0; }")
        let empty = tmp.appendingPathComponent("Empty.iatemplate/Contents")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store().importTemplate(at: tmp.appendingPathComponent("Empty.iatemplate")))
    }

    func testImportsAPlainCSSFile() throws {
        let css = tmp.appendingPathComponent("Noir.css")
        try "body { background: black; }".write(to: css, atomically: true, encoding: .utf8)
        let t = try store().importTemplate(at: css)
        XCTAssertEqual(t.name, "Noir")
        XCTAssertEqual(t.customCSS, "body { background: black; }")
        XCTAssertEqual(t.spec, TemplateStore.emptySpec)
    }

    func testExportsAsAFolderAndAsAZip() throws {
        let s = store()
        let t = try s.create("Shared")
        try "p { color: red; }".write(to: t.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        s.reload()
        let t2 = try XCTUnwrap(s.template(named: "Shared"))

        let folder = tmp.appendingPathComponent("out/Shared.mdtemplate")
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.export(t2, to: folder, zipped: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("template.toml").path))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("custom.css"), encoding: .utf8), "p { color: red; }")

        let zip = tmp.appendingPathComponent("out/Shared.mdtemplate.zip")
        try s.export(t2, to: zip, zipped: true)
        let unpacked = tmp.appendingPathComponent("unpacked")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, unpacked.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("Shared.mdtemplate/template.toml").path))

        // The exported folder imports again (a package copies in under a name of its own).
        XCTAssertEqual(try s.importTemplate(at: folder).name, "Shared 2")
    }

    func testBuiltInsCanBeExported() throws {
        let out = tmp.appendingPathComponent("Academic.mdtemplate")
        let s = store()
        try s.export(try XCTUnwrap(s.template(named: "Academic")), to: out, zipped: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("template.toml").path))
    }

    // MARK: CSS and resolution

    func testCSSIsTheCoresThenCustomCSSUntouched() throws {
        let s = store()
        let (theme, type) = theme()
        let plain = try XCTUnwrap(s.template(named: "Default"))
        XCTAssertEqual(s.css(for: plain, theme: theme, typography: type), previewCss(theme: theme, typography: type), "the Default is the preview as it is")

        let t = try s.create("Styled")
        try "/* mine */\nh1 { color: red !important; }\n".write(to: t.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        s.reload()
        let styled = try XCTUnwrap(s.template(named: "Styled"))
        let css = s.css(for: styled, theme: theme, typography: type)
        XCTAssertEqual(css, templateCss(spec: styled.spec, theme: theme, typography: type) + "\n/* mine */\nh1 { color: red !important; }\n")
        XCTAssertTrue(css.hasSuffix("h1 { color: red !important; }\n"), "after everything the core wrote, so it wins")

        let academic = s.css(for: try XCTUnwrap(s.template(named: "Academic")), theme: theme, typography: type)
        XCTAssertNotEqual(academic, previewCss(theme: theme, typography: type))
    }

    func testResolutionOrder() throws {
        let s = store()
        _ = try s.create("Mine")
        // The front matter's name, case-insensitively.
        XCTAssertEqual(s.resolve(frontMatterName: "academic", defaultName: "Typewriter").template.name, "Academic")
        XCTAssertNil(s.resolve(frontMatterName: "ACADEMIC", defaultName: "Typewriter").note)
        XCTAssertEqual(s.resolve(frontMatterName: " mine ", defaultName: "Default").template.name, "Mine")
        // Else the app's default.
        XCTAssertEqual(s.resolve(frontMatterName: nil, defaultName: "Typewriter").template.name, "Typewriter")
        XCTAssertEqual(s.resolve(frontMatterName: "", defaultName: "letter").template.name, "Letter")
        // Else the built-in Default.
        XCTAssertEqual(s.resolve(frontMatterName: nil, defaultName: "Gone").template.name, "Default")
        XCTAssertNil(s.resolve(frontMatterName: nil, defaultName: "Gone").note)
        // A name that is not installed: the default, and the note.
        let missing = s.resolve(frontMatterName: "Nowhere", defaultName: "Typewriter")
        XCTAssertEqual(missing.template.name, "Typewriter")
        XCTAssertEqual(missing.note, "Nowhere (not installed)")
    }

    func testTheDefaultTemplateSettingStartsAtDefault() {
        let settings = isolatedSettings()
        XCTAssertEqual(settings.defaultTemplate, "Default")
        settings.defaultTemplate = "Letter"
        XCTAssertEqual(settings.defaultTemplate, "Letter")
    }
}
