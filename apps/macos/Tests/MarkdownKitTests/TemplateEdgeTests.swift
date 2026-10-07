import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Templates at their edges (the Opus pass, 7 October): names that make the same folder, folders that do not match their
/// names, long and odd names, a rename into an occupied folder, an export onto itself, a zipped export imported again,
/// numbers that would not read back, and a package that cannot be read.
@MainActor
final class TemplateEdgeTests: XCTestCase {
    private var tmp: URL!
    private var yours: URL { tmp.appendingPathComponent("yours") }
    private var builtIn: URL { Fixtures.root.appendingPathComponent("apps/macos/Resources/Templates") }
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("template-edge-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    private func store() -> TemplateStore { TemplateStore(builtInDirectory: builtIn, userDirectory: yours) }

    private func packages() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: yours.path)) ?? []).sorted()
    }

    /// A package written by hand (as in Finder): `folder.mdtemplate` whose `template.toml` says `name`.
    private func handMade(folder: String, name: String, css: String? = nil) throws {
        let p = yours.appendingPathComponent("\(folder).mdtemplate")
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        try "[template]\nname = \"\(name)\"\n".write(to: p.appendingPathComponent("template.toml"), atomically: true, encoding: .utf8)
        if let css { try css.write(to: p.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8) }
    }

    // MARK: folders

    func testNamesThatMakeTheSameFolderDoNotOverwriteEachOther() throws {
        let s = store()
        let ab = try s.create("A-B")
        try "/* a-b */".write(to: ab.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        // `A/B` and `A:B` are names of their own, but their folder was `A-B.mdtemplate`: `create` wrote over the first.
        let slash = try s.create("A/B")
        let colon = try s.create("A:B")
        XCTAssertEqual(Set(s.yours.map(\.name)), ["A-B", "A/B", "A:B"])
        XCTAssertEqual(Set([ab.url, slash.url, colon.url].map(\.lastPathComponent)).count, 3)
        XCTAssertEqual(s.template(named: "A-B")?.customCSS, "/* a-b */")
        XCTAssertEqual(s.template(named: "A/B")?.name, "A/B")
        XCTAssertNil(s.template(named: "A/B")?.customCSS)
    }

    func testAFolderThatDoesNotMatchItsNameIsNotWrittenOver() throws {
        // Renamed in its `template.toml` by hand: the folder `Foo` holds the template `Bar`.
        try handMade(folder: "Foo", name: "Bar", css: "/* bar */")
        let s = store()
        XCTAssertEqual(s.yours.map(\.name), ["Bar"])
        let foo = try s.create("Foo")
        XCTAssertEqual(Set(s.yours.map(\.name)), ["Bar", "Foo"])
        XCTAssertEqual(s.template(named: "Bar")?.customCSS, "/* bar */")
        XCTAssertNotEqual(foo.url, s.template(named: "Bar")?.url)
        // Duplicate and import take the same care.
        let copy = try s.duplicate(try XCTUnwrap(s.template(named: "Academic")), as: "foo 2")
        XCTAssertEqual(Set(s.yours.map(\.name)), ["Bar", "Foo", "foo 2"])
        XCTAssertEqual(s.template(named: "Bar")?.customCSS, "/* bar */")
        XCTAssertFalse(copy.isBuiltIn)
    }

    func testARenameIntoAnOccupiedFolderKeepsBothTemplates() throws {
        try handMade(folder: "Taken", name: "Something Else", css: "/* else */")
        let s = store()
        let mine = try s.create("Mine")
        // Before, the move to `Taken.mdtemplate` failed after the package had gone to a hidden temporary name: the
        // template vanished from the list (and from every document that named it).
        let renamed = try s.rename(mine, to: "Taken")
        XCTAssertEqual(renamed.name, "Taken")
        XCTAssertEqual(Set(s.yours.map(\.name)), ["Something Else", "Taken"])
        XCTAssertEqual(s.template(named: "Something Else")?.customCSS, "/* else */")
        XCTAssertFalse(packages().contains { $0.hasPrefix(".rename-") }, "\(packages())")
        // A change of capitals only stays in its own folder.
        let recased = try s.rename(renamed, to: "TAKEN")
        XCTAssertEqual(recased.name, "TAKEN")
        XCTAssertEqual(recased.url.deletingLastPathComponent().standardizedFileURL, yours.standardizedFileURL)
        XCTAssertEqual(s.yours.count, 2)
    }

    func testLongAndOddNames() throws {
        let s = store()
        // A file name holds 255 characters: a longer name could not be made at all ("File name too long"). The folder is
        // cut; the name is not.
        let ascii = String(repeating: "x", count: 300)
        let t = try s.create(ascii)
        XCTAssertEqual(t.name, ascii)
        XCTAssertLessThanOrEqual(t.url.lastPathComponent.precomposedStringWithCanonicalMapping.count, 255)
        XCTAssertEqual(s.template(named: ascii)?.url, t.url)
        let long = String(repeating: "\u{e9}", count: 250)
        XCTAssertEqual(try s.create(long).name, long)
        XCTAssertEqual(try s.create(long + "!").name, long + "!", "cut to the same folder, numbered")
        // A leading dot would hide the folder; a newline is no file name.
        let dot = try s.create(".hidden")
        XCTAssertEqual(dot.name, ".hidden")
        XCTAssertFalse(dot.url.lastPathComponent.hasPrefix("."))
        let odd = try s.create("Two\nLines")
        XCTAssertEqual(odd.name, "Two\nLines")
        XCTAssertFalse(odd.url.lastPathComponent.contains("\n"))
        XCTAssertEqual(store().yours.count, 5, "all of them read back")
    }

    // MARK: names

    func testARenameToABuiltInsNameOrToNothing() throws {
        let s = store()
        let mine = try s.create("Mine")
        XCTAssertEqual(try s.rename(mine, to: "academic").name, "academic 2", "a built-in's name, in any case, is taken")
        let again = try XCTUnwrap(s.template(named: "academic 2"))
        XCTAssertEqual(try s.rename(again, to: "   ").name, "academic 2", "an empty name changes nothing")
        XCTAssertEqual(try s.rename(again, to: "DEFAULT").name, "DEFAULT 2")
    }

    // MARK: import and export

    func testAZippedExportImportsAgain() throws {
        let s = store()
        let t = try s.duplicate(try XCTUnwrap(s.template(named: "Academic")), as: "Shared")
        try "/* shared */".write(to: t.url.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        s.reload()
        let zip = tmp.appendingPathComponent("Shared.mdtemplate.zip")
        try s.export(try XCTUnwrap(s.template(named: "Shared")), to: zip, zipped: true)
        // Before, a zip was read as an `.iatemplate` bundle and refused: what Export wrote could not be imported.
        let back = try s.importTemplate(at: zip)
        XCTAssertEqual(back.name, "Shared 2")
        XCTAssertEqual(back.spec, s.template(named: "Academic")?.spec)
        XCTAssertEqual(back.customCSS, "/* shared */")
        // A zip of an `.iatemplate` bundle too, and a zip with nothing in it is refused with a reason.
        let bundleZip = tmp.appendingPathComponent("Sample.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", fixtures.appendingPathComponent("Sample.iatemplate").path, bundleZip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(try s.importTemplate(at: bundleZip).name, "Sample Look")
        let junk = tmp.appendingPathComponent("junk.zip")
        try Data("not a zip".utf8).write(to: junk)
        XCTAssertThrowsError(try s.importTemplate(at: junk)) { XCTAssertEqual($0 as? TemplateStoreError, .nothingToImport("junk.zip")) }
    }

    func testAnExportOntoItsOwnPackageKeepsIt() throws {
        let s = store()
        let t = try s.create("Mine")
        XCTAssertThrowsError(try s.export(t, to: t.url, zipped: false))
        XCTAssertThrowsError(try s.export(t, to: t.url.appendingPathComponent("inside.zip"), zipped: true))
        XCTAssertTrue(fm.fileExists(atPath: t.url.appendingPathComponent("template.toml").path), "the package is still there")
        XCTAssertNotNil(store().template(named: "Mine"))
    }

    func testAnIATemplateFixtureBuiltHereImportsWithItsName() throws {
        // `style.css`, `title.css` and an `Info.plist` naming it, as the bundles people share are laid out.
        let contents = tmp.appendingPathComponent("Shared Look.iatemplate/Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try "body { color: #111111; }".write(to: contents.appendingPathComponent("Resources/style.css"), atomically: true, encoding: .utf8)
        try "h1 { color: #222222; } </style><script>alert(1)</script>".write(to: contents.appendingPathComponent("Resources/title.css"), atomically: true, encoding: .utf8)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Academic"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let s = store()
        let t = try s.importTemplate(at: tmp.appendingPathComponent("Shared Look.iatemplate"))
        XCTAssertEqual(t.name, "Academic 2", "the plist's name, made unique against the built-in")
        XCTAssertEqual(t.customCSS, "body { color: #111111; }\nh1 { color: #222222; } </style><script>alert(1)</script>")
        // The stylesheet as a page carries it: it cannot end the style element.
        let appearance = EditorAppearance(settings: isolatedSettings(), appearance: NSAppearance(named: .aqua))
        let css = s.css(for: t, theme: appearance.theme, typography: PreviewTypography.make(from: appearance))
        let page = TemplateStore.replacingStyle(inPage: "<html><head>\n<style>\nx\n</style>\n</head><body></body></html>", with: css)
        XCTAssertEqual(page.components(separatedBy: "</style>").count, 2)
        let script = try XCTUnwrap(page.range(of: "<script>"))
        XCTAssertLessThan(script.lowerBound, try XCTUnwrap(page.range(of: "</style>")).lowerBound, "text inside the style element")
    }

    // MARK: packages that cannot be read

    func testAPackageWithOnlyCustomCSSIsListedWithItsError() throws {
        let p = yours.appendingPathComponent("Only CSS.mdtemplate")
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        try "p { color: red; }".write(to: p.appendingPathComponent("custom.css"), atomically: true, encoding: .utf8)
        let s = store()
        let t = try XCTUnwrap(s.yours.first)
        XCTAssertEqual(t.name, "Only CSS")
        XCTAssertFalse(t.isUsable)
        XCTAssertNotNil(t.error)
        XCTAssertNil(s.template(named: "Only CSS"), "left out of resolution")
    }
}

/// The Templates window's model at its edges.
@MainActor
final class TemplateEditorEdgeTests: XCTestCase {
    private var tmp: URL!
    private var yours: URL { tmp.appendingPathComponent("yours") }
    private var builtIn: URL { Fixtures.root.appendingPathComponent("apps/macos/Resources/Templates") }
    private var controller: TemplatesWindowController!
    private var editor: TemplateEditor { controller.editor }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("template-editor-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        controller = TemplatesWindowController(store: TemplateStore(builtInDirectory: builtIn, userDirectory: yours))
    }

    override func tearDownWithError() throws {
        controller.window?.orderOut(nil)
        controller = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func spin(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }

    private func diskTOML() throws -> String {
        try String(contentsOf: try XCTUnwrap(editor.working).url.appendingPathComponent("template.toml"), encoding: .utf8)
    }

    func testNumbersThatWouldNotReadBackAreRefused() throws {
        editor.newTemplate()
        editor.selectTarget("h1")
        let size = editor.binding(.h1, .fontSize, \.fontSize)
        size.wrappedValue = TemplateLength(value: 2, unit: .em)
        // The number fields parse `nan`, `∞` and `1e400`. Written, `infem` made the core refuse the whole file on the
        // next read: the template turned unreadable and its documents fell back to the default.
        for bad in [Double.nan, .infinity, -.infinity] {
            size.wrappedValue = TemplateLength(value: bad, unit: .em)
            XCTAssertEqual(editor.style(for: .h1).fontSize?.value, 2, "\(bad)")
            editor.binding(.h1, .lineHeight, \.lineHeight).wrappedValue = bad
            XCTAssertNil(editor.style(for: .h1).lineHeight, "\(bad)")
            editor.pageBinding(.measureCh, "Column Width", \.measureCh).wrappedValue = bad
            XCTAssertNil(editor.page.measureCh, "\(bad)")
        }
        editor.flush()
        let reread = TemplateStore.readPackage(try XCTUnwrap(editor.working).url, builtIn: false)
        XCTAssertNil(reread?.error)
        XCTAssertEqual(reread?.spec.elements.first { $0.kind == .h1 }?.style.fontSize?.value, 2)
        // Extremes that are numbers are taken.
        size.wrappedValue = TemplateLength(value: 1e300, unit: .px)
        XCTAssertEqual(editor.style(for: .h1).fontSize?.value, 1e300)
    }

    func testATemplateThatCannotBeReadIsNotWrittenOver() throws {
        let p = yours.appendingPathComponent("Broken.mdtemplate")
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        let broken = "[template]\nname = \"Broken\"\n[elements.h1]\nfont_size = \"huge\"\n"
        try broken.write(to: p.appendingPathComponent("template.toml"), atomically: true, encoding: .utf8)
        editor.store.reload()
        XCTAssertTrue(editor.select(named: "Broken"))
        XCTAssertNotNil(editor.working?.error)
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(editor.isReadOnly, "it can still be deleted")
        // Before, a field or the description set here wrote an empty template over the file, typo and all.
        editor.selectTarget("h2")
        editor.binding(.h2, .weight, \.weight).wrappedValue = 700
        editor.descriptionBinding.wrappedValue = "x"
        editor.flush()
        spin(TemplateEditor.saveDelay + 0.2)
        XCTAssertEqual(try String(contentsOf: p.appendingPathComponent("template.toml"), encoding: .utf8), broken)
        XCTAssertFalse(editor.undoManager.canUndo)
    }

    func testNewAndAtOnceCloseLeavesAWholePackage() throws {
        controller.show()
        editor.newTemplate()
        editor.selectTarget("h1")
        editor.binding(.h1, .weight, \.weight).wrappedValue = 600
        controller.window?.close()
        let t = try XCTUnwrap(TemplateStore(builtInDirectory: builtIn, userDirectory: yours).template(named: "Untitled"))
        XCTAssertNil(t.error)
        XCTAssertEqual(t.spec.elements.first { $0.kind == .h1 }?.style.weight, 600)
    }

    func testAnEditInFinderWhileTheWindowShowsTheTemplate() throws {
        controller.show()
        editor.newTemplate()
        let url = try XCTUnwrap(editor.working).url
        // Written by another program, with nothing unsaved here: the window takes it.
        try "[template]\nname = \"Untitled\"\n[elements.h2]\nweight = 300\n".write(to: url.appendingPathComponent("template.toml"), atomically: true, encoding: .utf8)
        editor.store.reloadIfChanged()
        spin(0.1)
        XCTAssertEqual(editor.style(for: .h2).weight, 300)
        XCTAssertTrue(editor.css.contains("font-weight: 300"))
        // Made unreadable outside: shown with its error, no crash, nothing written over it.
        try "not = [toml".write(to: url.appendingPathComponent("template.toml"), atomically: true, encoding: .utf8)
        editor.store.reloadIfChanged()
        spin(0.1)
        XCTAssertNotNil(editor.working?.error)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(try diskTOML(), "not = [toml")
        // Deleted outside: the Default is selected.
        try FileManager.default.removeItem(at: url)
        editor.store.reloadIfChanged()
        spin(0.1)
        XCTAssertEqual(editor.working?.name, "Default")
    }
}
