import AppKit
import XCTest
import MarkdownCore
@testable import MarkdownKit

/// Wikilinks and tags in the editor and the preview: how they are styled, what a click does, and the
/// `mdoc://` addresses the preview's links come through.
final class WikilinkTests: XCTestCase {
    private func attrs(_ e: Editor, at needle: String, offset: Int = 0) -> [NSAttributedString.Key: Any] {
        let r = (e.string as NSString).range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, needle)
        return e.session.storage.attributes(at: r.location + offset, effectiveRange: nil)
    }

    // MARK: styling

    func testAWikilinkIsStyledLikeALinkAndItsBracketsAreDimmed() {
        let e = Editor(text: "See [[Alpha|the label]] and [[Beta]] here.\n")
        let p = e.session.appearance.palette
        XCTAssertEqual((attrs(e, at: "the label")[.foregroundColor] as! NSColor).hexString, p.link.hexString)
        XCTAssertEqual((attrs(e, at: "Beta")[.foregroundColor] as! NSColor).hexString, p.link.hexString)
        XCTAssertEqual((attrs(e, at: "[[Alpha")[.foregroundColor] as! NSColor).hexString, p.markup.hexString, "the brackets are markup")
        XCTAssertEqual((attrs(e, at: "Alpha|")[.foregroundColor] as! NSColor).hexString, p.markup.hexString, "so is the target before a label")
        XCTAssertEqual((attrs(e, at: "here")[.foregroundColor] as! NSColor).hexString, p.text.hexString)
    }

    func testATagIsMutedAndNeverInCode() {
        let e = Editor(text: "A #real tag, `#not-a-tag`, and #nested/tag.\n")
        let p = e.session.appearance.palette
        XCTAssertEqual((attrs(e, at: "#real")[.foregroundColor] as! NSColor).hexString, p.quote.hexString)
        XCTAssertEqual((attrs(e, at: "#nested/tag")[.foregroundColor] as! NSColor).hexString, p.quote.hexString)
        XCTAssertEqual((attrs(e, at: "#not-a-tag")[.foregroundColor] as! NSColor).hexString, p.codeText.hexString)
        XCTAssertNotEqual(p.quote.hexString, p.text.hexString)
    }

    func testTheThreeThemesStyleThemAlike() {
        for theme in ThemeChoice.allCases where theme != .system {
            let s = isolatedSettings()
            s.theme = theme
            let e = Editor(text: "[[Link]] #tag\n", settings: s)
            let p = e.session.appearance.palette
            XCTAssertEqual((attrs(e, at: "Link")[.foregroundColor] as! NSColor).hexString, p.link.hexString, theme.rawValue)
            XCTAssertEqual((attrs(e, at: "#tag")[.foregroundColor] as! NSColor).hexString, p.quote.hexString, theme.rawValue)
        }
    }

    // MARK: clicking

    private func click(_ e: Editor, on needle: String) throws -> Bool {
        let i = (e.string as NSString).range(of: needle).location
        let g = e.session.layoutManager.glyphIndexForCharacter(at: i)
        let r = e.session.layoutManager.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: try XCTUnwrap(e.tv.textContainer))
        let o = e.tv.textContainerOrigin
        return e.tv.openLink(at: NSPoint(x: r.midX + o.x, y: r.midY + o.y))
    }

    func testCommandClickOnAWikilinkAsksTheWindowToOpenIt() throws {
        let e = Editor(text: "See [[Folder/Alpha#Goals|the plan]] or [[Beta]] and [web](https://example.com/).\n")
        var opened: [WikilinkRef] = []
        e.session.onOpenWikilink = { opened.append($0) }
        var external: [URL] = []
        LinkOpener.opened = { external.append($0); return true }
        defer { LinkOpener.opened = nil }
        XCTAssertTrue(try click(e, on: "the plan"))
        XCTAssertTrue(try click(e, on: "Beta"))
        XCTAssertEqual(opened.map(\.target), ["Folder/Alpha", "Beta"])
        XCTAssertEqual(opened.first?.heading, "Goals")
        XCTAssertEqual(opened.first?.label, "the plan")
        XCTAssertEqual(external, [], "a wikilink is not a URL")
        XCTAssertTrue(try click(e, on: "web"))
        XCTAssertEqual(external.map(\.host), ["example.com"], "an ordinary link still goes to the browser")
        XCTAssertEqual(opened.count, 2)
        XCTAssertFalse(try click(e, on: "See"), "plain text is not a link")
    }

    func testAWikilinkInCodeIsNotALink() throws {
        let e = Editor(text: "`[[not]]` and\n\n```\n[[also not]]\n```\n")
        var opened = 0
        e.session.onOpenWikilink = { _ in opened += 1 }
        XCTAssertFalse(try click(e, on: "not]]"))
        XCTAssertFalse(try click(e, on: "also"))
        XCTAssertEqual(opened, 0)
    }

    func testTheCoreAnswersForEveryOffsetOfALink() {
        let doc = Document(text: "a [[Alpha|label]] b")
        XCTAssertNil(doc.wikilinkAt(offset: 1))
        XCTAssertEqual(doc.wikilinkAt(offset: 2)?.target, "Alpha")
        XCTAssertEqual(doc.wikilinkAt(offset: 8)?.label, "label")
        XCTAssertEqual(doc.wikilinkAt(offset: 16)?.range, Utf16Range(start: 2, end: 17))
        XCTAssertNil(doc.wikilinkAt(offset: 17))
    }

    // MARK: the preview's addresses

    func testNoteLinksAsThePreviewSpellsThem() {
        func link(_ href: String) -> String? { LinkPolicy.noteLink(href: href).map { "\($0.target)#\($0.fragment ?? "")" } }
        XCTAssertEqual(link("Title.md"), "Title.md#")
        XCTAssertEqual(link("Folder/Title.md#goals"), "Folder/Title.md#goals")
        XCTAssertEqual(link("50%25.md"), "50%.md#", "%25 is a percent sign in the name")
        XCTAssertEqual(link("Why%3F.md"), "Why?.md#", "%3F is a question mark in the name, not a query")
        XCTAssertEqual(link("a%20b.md"), "a b.md#")
        XCTAssertEqual(link("./Note: Title.md"), "Note: Title.md#", "./ keeps a colon from reading as a scheme")
        XCTAssertEqual(link(".//host/x.md"), "host/x.md#", ".// keeps // from reading as another host")
        XCTAssertEqual(link("././/x.md"), "x.md#")
        XCTAssertEqual(link("Notes.TXT"), "Notes.TXT#")
        XCTAssertEqual(link("#only-a-fragment"), nil)
        XCTAssertEqual(link("page.html"), nil, "not a note")
        XCTAssertEqual(link("picture.png"), nil)
        XCTAssertEqual(link("https://example.com/a.md"), nil)
        XCTAssertEqual(link("mailto:me@example.com"), nil)
        XCTAssertEqual(link("javascript:x.md"), nil)
        XCTAssertEqual(link("../up.md"), nil, "out of the folder")
        XCTAssertEqual(link("a/../../b.md"), nil)
        XCTAssertEqual(link("/abs/x.md"), nil)
        XCTAssertEqual(link("~/x.md"), nil)
        XCTAssertEqual(link(""), nil)
        // The same ways out spelled with escapes, which are decoded once.
        XCTAssertEqual(link("%2Fetc%2Fx.md"), nil, "an escaped absolute path")
        XCTAssertEqual(link("./%2F%2Fhost/x.md"), nil)
        XCTAssertEqual(link("%2E%2E/up.md"), nil)
        XCTAssertEqual(link("a/%2E%2E/%2E%2E/b.md"), nil)
        XCTAssertEqual(link("..%2Fup.md"), nil)
        XCTAssertEqual(link("%7E/x.md"), nil)
        XCTAssertEqual(link("a%2Fb.md"), "a/b.md#", "an escaped slash inside is a folder, as written unescaped")
    }

    func testTheSchemeHandlerDecodesWhatTheAddressesEscape() throws {
        // The page's script routes a link by `encodeURIComponent(href as written)`; the handler hands
        // back the href as written, and the policy decodes the name once.
        func routed(_ raw: String) throws -> URL {
            var c = URLComponents()
            c.scheme = PreviewURL.scheme
            c.host = PreviewURL.host
            c.path = "/link"
            c.percentEncodedQueryItems = [URLQueryItem(name: "href", value: raw.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")))]
            return try XCTUnwrap(c.url)
        }
        let doc = URL(fileURLWithPath: "/notes/Links.md")
        for (raw, name) in [("50%25.md", "50%.md"), ("Why%3F.md", "Why?.md"), ("./Note: Title.md", "Note: Title.md"), (".//host/x.md", "host/x.md"),
                            ("Folder/Sub%20Folder/Note.md", "Folder/Sub Folder/Note.md")] {
            let url = try routed(raw)
            XCTAssertEqual(PreviewURL.resolve(url, documentURL: doc), .link(raw), raw)
            XCTAssertEqual(LinkPolicy.decide(url: url, isLinkActivation: true, isMainFrame: true, isInitialLoad: false, documentURL: doc, notes: true),
                           .openNote(target: name, fragment: nil), raw)
        }
        let withHeading = try routed("Alpha.md#the-goals")
        XCTAssertEqual(LinkPolicy.decide(url: withHeading, isLinkActivation: true, isMainFrame: true, isInitialLoad: false, documentURL: doc, notes: true),
                       .openNote(target: "Alpha.md", fragment: "the-goals"))
    }

    func testOutsideNotesModeALinkToANoteOpensTheFileAsBefore() throws {
        let doc = URL(fileURLWithPath: "/notes/Links.md")
        let url = try XCTUnwrap(URL(string: "mdoc://doc/link?href=Alpha.md"))
        XCTAssertEqual(LinkPolicy.decide(url: url, isLinkActivation: true, isMainFrame: true, isInitialLoad: false, documentURL: doc),
                       .open(URL(fileURLWithPath: "/notes/Alpha.md")))
        // A path out of the folder is a file even in notes mode.
        let up = try XCTUnwrap(URL(string: "mdoc://doc/link?href=..%2Fup.md"))
        XCTAssertEqual(LinkPolicy.decide(url: up, isLinkActivation: true, isMainFrame: true, isInitialLoad: false, documentURL: doc, notes: true),
                       .open(URL(fileURLWithPath: "/up.md")))
        // And nothing but a click opens anything.
        XCTAssertEqual(LinkPolicy.decide(url: url, isLinkActivation: false, isMainFrame: true, isInitialLoad: false, documentURL: doc, notes: true), .ignore)
    }

    func testTheEditorsOwnRuleDecodesANameWithAQuestionMark() {
        let doc = URL(fileURLWithPath: "/notes/Links.md")
        XCTAssertEqual(LinkOpener.url(for: "Why%3F.md", documentURL: doc)?.lastPathComponent, "Why?.md", "%3F is part of the name")
        XCTAssertEqual(LinkOpener.url(for: "50%25.md", documentURL: doc)?.lastPathComponent, "50%.md")
        XCTAssertEqual(LinkOpener.url(for: "a.md?x=1", documentURL: doc)?.lastPathComponent, "a.md", "a real query is cut off")
        XCTAssertEqual(LinkOpener.url(for: "a.md#sec", documentURL: doc)?.lastPathComponent, "a.md")
        XCTAssertEqual(LinkOpener.url(for: "a%23b.md", documentURL: doc)?.lastPathComponent, "a#b.md", "%23 is part of the name")
    }

    // MARK: beside the document

    func testWithoutALibraryANameIsLookedForBesideTheDocument() throws {
        let lib = try TempLibrary(["Links.md": "x", "Alpha.md": "a", "Why?.md": "w", "Sub/Beta.md": "b", "Sub/Deep/Gamma.txt": "g", "pic.png": "p"])
        defer { lib.remove() }
        let doc = lib.url.appendingPathComponent("Links.md")
        func found(_ name: String, _ from: URL? = doc) -> String? { WikilinkResolver.resolve(name, besides: from)?.path.replacingOccurrences(of: lib.url.path + "/", with: "") }
        XCTAssertEqual(found("Alpha"), "Alpha.md")
        XCTAssertEqual(found("alpha"), "Alpha.md", "case does not matter")
        XCTAssertEqual(found("Alpha.md"), "Alpha.md", "a name that already has its extension")
        XCTAssertEqual(found("Why?"), "Why?.md")
        XCTAssertEqual(found("Sub/Beta"), "Sub/Beta.md")
        XCTAssertEqual(found("sub/deep/gamma"), "Sub/Deep/Gamma.txt")
        XCTAssertNil(found("Beta"), "only beside the document, not in every folder")
        XCTAssertNil(found("pic"), "not a note")
        XCTAssertNil(found("Missing"))
        XCTAssertNil(found("../x"))
        XCTAssertNil(found("/Alpha"))
        XCTAssertNil(found("Alpha", nil), "an unsaved document has no neighbours")
        XCTAssertEqual(WikilinkResolver.name(of: "  ./Alpha "), "Alpha")
    }
}
