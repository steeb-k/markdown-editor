//! The export formats: plain text, Word and the HTML export's embedded pictures.
//!
//! Word is tested by opening the package again (the `zip` crate reads what it writes) and checking the XML as text:
//! a tag-balance check stands in for a parser, so no XML crate is needed.
mod common;
use common::*;
use markdown_core::*;
use std::collections::HashMap;
use std::io::Read;

fn doc(text: &str) -> Document {
    Document::new(text, OffsetEncoding::Utf16)
}

fn export_fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/macos/ui/fixtures").join(name);
    std::fs::read_to_string(path).unwrap()
}

fn picture() -> Vec<u8> {
    std::fs::read(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/macos/ui/fixtures/pictures/small.png")).unwrap()
}

fn academic() -> template::TemplateSpec {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("templates/Academic.mdtemplate/template.toml");
    template::Template::parse(&std::fs::read_to_string(path).unwrap()).unwrap().spec
}

// ----- plain text -------------------------------------------------------------------------------

fn plain(text: &str) -> String {
    doc(text).render_plain()
}

#[test]
fn plain_snapshots() {
    let mut inputs = fixtures();
    inputs.push(("export-formats".to_owned(), export_fixture("export-formats.md")));
    for (name, text) in inputs {
        insta::assert_snapshot!(format!("plain_{name}"), plain(&text));
    }
}

#[test]
fn plain_blocks() {
    assert_eq!(plain(""), "");
    assert_eq!(plain("---\ntitle: T\n---\n\n# Head\n\nBody\n"), "Head\n\nBody\n");
    assert_eq!(plain("# One\n## Two ###\n"), "One\n\nTwo\n");
    assert_eq!(plain("a\n\n\n\nb\n"), "a\n\nb\n");
    assert_eq!(plain("a  \nb\nc\n"), "a\nb\nc\n");
    assert_eq!(plain("> quoted\n> more\n"), "    quoted\n    more\n");
    assert_eq!(plain("```rust\nfn main() {\n\n}\n```\n"), "    fn main() {\n\n    }\n");
    assert_eq!(plain("    indented\n"), "    indented\n");
    assert_eq!(plain("a\n\n---\n\nb\n"), "a\n\n---\n\nb\n");
    assert_eq!(plain("<div>raw</div>\n\ntext <b>bold</b>\n"), "text bold\n");
}

#[test]
fn plain_lists() {
    assert_eq!(plain("- a\n- b\n  - c\n    - d\n- e\n"), "- a\n- b\n  - c\n    - d\n- e\n");
    assert_eq!(plain("3. a\n4. b\n"), "3. a\n4. b\n");
    assert_eq!(plain("- [ ] open\n- [x] done\n"), "- [ ] open\n- [x] done\n");
    assert_eq!(plain("- a\n\n  more\n\n- b\n"), "- a\n\n  more\n\n- b\n");
    assert_eq!(plain("1. a\n   - b\n"), "1. a\n  - b\n");
}

#[test]
fn plain_inline() {
    assert_eq!(plain("*a* **b** ~~c~~ `d`\n"), "a b c d\n");
    assert_eq!(plain("[label](https://x.org/p)\n"), "label (https://x.org/p)\n");
    assert_eq!(plain("[https://x.org](https://x.org)\n"), "https://x.org\n");
    assert_eq!(plain("<https://x.org>\n"), "https://x.org\n");
    assert_eq!(plain("<me@x.org>\n"), "me@x.org\n");
    assert_eq!(plain("see https://x.org/a now\n"), "see https://x.org/a now\n");
    assert_eq!(plain("![alt words](p.png)\n"), "alt words\n");
    assert_eq!(plain("[[Note|shown]] and [[Other]] and #tag\n"), "shown and Other and #tag\n");
    assert_eq!(plain("a\\*b &amp; c\n"), "a*b & c\n");
}

#[test]
fn plain_tables_pad_by_display_width() {
    let t = plain("| Name | Qty |\n| :-- | --: |\n| 日本語 | 7 |\n| ab | 123 |\n");
    assert_eq!(t, "Name    Qty\n------  ---\n日本語    7\nab      123\n");
}

#[test]
fn plain_footnotes() {
    let t = plain("a[^x] b[^y] c[^x]\n\n[^y]: second\n[^x]: first\n");
    assert_eq!(t, "a[1] b[2] c[1]\n\n[1] first\n[2] second\n");
    assert_eq!(plain("a[^n]\n\n[^n]: one\n\n    two\n"), "a[1]\n\n[1] one\n\n    two\n");
}

#[test]
fn plain_has_unix_line_endings_and_no_bom() {
    let t = plain("a\r\nb\r\n\r\nc\r\n");
    assert!(!t.contains('\r') && !t.starts_with('\u{feff}'));
    assert_eq!(t, "a\nb\n\nc\n");
}

#[test]
fn plain_survives_what_panics_the_parser() {
    // `>1. [r]:u\n\t` panics pulldown-cmark 0.13.4: the text is what the reader gets.
    assert!(!plain(">1. [r]:u\n\t").is_empty());
}

// ----- the HTML export's pictures ---------------------------------------------------------------

fn html_with(text: &str, data: Vec<ImageData>) -> String {
    doc(text).render_html(&RenderOptions { image_data: data, ..Default::default() })
}

#[test]
fn html_embeds_a_picture_as_a_data_uri() {
    let data = vec![ImageData { destination: "a.png".into(), mime: "image/png".into(), bytes: b"Man".to_vec() }];
    assert_eq!(html_with("![x](a.png)", data.clone()), "<p><img src=\"data:image/png;base64,TWFu\" alt=\"x\" /></p>\n");
    // Padding for the lengths that are not a multiple of three.
    let two = vec![ImageData { bytes: b"Ma".to_vec(), ..data[0].clone() }];
    assert!(html_with("![x](a.png)", two).contains("base64,TWE=\""));
    let one = vec![ImageData { bytes: b"M".to_vec(), ..data[0].clone() }];
    assert!(html_with("![x](a.png)", one).contains("base64,TQ==\""));
}

#[test]
fn html_leaves_other_pictures_as_written() {
    let data = vec![ImageData { destination: "a.png".into(), mime: "image/png".into(), bytes: vec![1, 2, 3] }];
    let h = html_with("![x](b.png) ![y](https://x.org/c.png) ![z](a.png)", data);
    assert!(h.contains("src=\"b.png\"") && h.contains("src=\"https://x.org/c.png\"") && h.contains("src=\"data:image/png;base64,AQID\""));
    // One with no bytes (it could not be read) stays as written.
    let none = vec![ImageData { destination: "a.png".into(), mime: "image/png".into(), bytes: Vec::new() }];
    assert!(html_with("![z](a.png)", none).contains("src=\"a.png\""));
}

#[test]
fn html_embedded_picture_keeps_its_size() {
    let o = RenderOptions {
        image_sizes: vec![ImageSize { destination: "a.png".into(), width: 10, height: 20 }],
        image_data: vec![ImageData { destination: "a.png".into(), mime: "image/png".into(), bytes: vec![0] }],
        ..Default::default()
    };
    assert!(doc("![x](a.png)").render_html(&o).contains("alt=\"x\" width=\"10\" height=\"20\""));
}

// ----- Word -------------------------------------------------------------------------------------

fn unzip(bytes: &[u8]) -> HashMap<String, Vec<u8>> {
    let mut z = zip::ZipArchive::new(std::io::Cursor::new(bytes)).expect("a zip");
    let mut parts = HashMap::new();
    for i in 0..z.len() {
        let mut f = z.by_index(i).unwrap();
        let mut data = Vec::new();
        f.read_to_end(&mut data).unwrap();
        parts.insert(f.name().to_owned(), data);
    }
    parts
}

/// A tag-balance check: every start tag closed by its own end tag, in order, and nothing left open.
fn well_formed(xml: &str) -> Result<(), String> {
    let mut stack: Vec<String> = Vec::new();
    let mut rest = xml;
    while let Some(open) = rest.find('<') {
        rest = &rest[open..];
        let close = rest.find('>').ok_or("a tag never ends")?;
        let tag = &rest[1..close];
        rest = &rest[close + 1..];
        if tag.starts_with('?') || tag.starts_with('!') {
            continue;
        }
        if let Some(name) = tag.strip_prefix('/') {
            match stack.pop() {
                Some(top) if top == name.trim() => {}
                other => return Err(format!("</{name}> closes {other:?}")),
            }
        } else if !tag.ends_with('/') {
            stack.push(tag.split_whitespace().next().unwrap_or("").to_owned());
        }
    }
    if stack.is_empty() { Ok(()) } else { Err(format!("left open: {stack:?}")) }
}

struct Docx {
    parts: HashMap<String, Vec<u8>>,
}

impl Docx {
    fn part(&self, name: &str) -> String {
        String::from_utf8(self.parts.get(name).unwrap_or_else(|| panic!("no part {name}")).clone()).unwrap()
    }
    fn document(&self) -> String {
        self.part("word/document.xml")
    }
    fn styles(&self) -> String {
        self.part("word/styles.xml")
    }
    fn numbering(&self) -> String {
        self.part("word/numbering.xml")
    }
    fn footnotes(&self) -> String {
        self.part("word/footnotes.xml")
    }
    fn rels(&self) -> String {
        self.part("word/_rels/document.xml.rels")
    }
    /// The `<w:style ...>...</w:style>` element of a style id.
    fn style(&self, id: &str) -> String {
        let s = self.styles();
        let at = s.find(&format!("w:styleId=\"{id}\"")).unwrap_or_else(|| panic!("no style {id}"));
        let start = s[..at].rfind("<w:style ").unwrap();
        let end = at + s[at..].find("</w:style>").unwrap();
        s[start..end].to_owned()
    }
}

fn docx_with(text: &str, options: &DocxOptions) -> Docx {
    let bytes = doc(text).render_docx(options);
    let d = Docx { parts: unzip(&bytes) };
    for (name, data) in &d.parts {
        if name.ends_with(".xml") || name.ends_with(".rels") {
            let xml = std::str::from_utf8(data).unwrap_or_else(|_| panic!("{name} is not UTF-8"));
            well_formed(xml).unwrap_or_else(|e| panic!("{name}: {e}"));
        }
    }
    d
}

fn docx(text: &str) -> Docx {
    docx_with(text, &DocxOptions::default())
}

fn small_png() -> ImageData {
    ImageData { destination: "pictures/small.png".into(), mime: "image/png".into(), bytes: picture() }
}

fn count(haystack: &str, needle: &str) -> usize {
    haystack.matches(needle).count()
}

#[test]
fn docx_is_a_package_with_every_part() {
    let d = docx("Hello\n");
    for name in [
        "[Content_Types].xml",
        "_rels/.rels",
        "word/document.xml",
        "word/styles.xml",
        "word/numbering.xml",
        "word/footnotes.xml",
        "word/settings.xml",
        "word/_rels/document.xml.rels",
    ] {
        assert!(d.parts.contains_key(name), "{name}");
    }
    let types = d.part("[Content_Types].xml");
    for part in ["document", "styles", "numbering", "footnotes", "settings"] {
        assert!(types.contains(&format!("/word/{part}.xml")), "{part}");
    }
    assert!(d.part("_rels/.rels").contains("word/document.xml"));
    // The content types come first in the archive, as the format asks.
    let bytes = doc("x").render_docx(&DocxOptions::default());
    assert!(bytes.starts_with(b"PK") && String::from_utf8_lossy(&bytes[..60]).contains("[Content_Types].xml"));
    for rel in ["styles", "numbering", "footnotes", "settings"] {
        assert!(d.rels().contains(&format!("relationships/{rel}\"")), "{rel}");
    }
}

#[test]
fn docx_of_nothing_is_valid() {
    for text in ["", "---\ntitle: T\n---\n", "<div>only html</div>\n"] {
        let d = docx(text);
        assert!(d.document().contains("<w:body>") && d.document().contains("<w:sectPr>"), "{text:?}");
        assert!(!d.document().contains("<w:t"), "{text:?}");
    }
}

#[test]
fn docx_headings_and_paragraphs() {
    let d = docx("# One\n\n## Two\n\n###### Six\n\nBody text\n");
    let x = d.document();
    for n in [1, 2, 6] {
        assert!(x.contains(&format!("<w:pStyle w:val=\"Heading{n}\"/>")), "{n}");
    }
    assert!(x.contains("<w:pStyle w:val=\"Normal\"/>"));
    assert!(x.contains(">One</w:t>") && x.contains(">Body text</w:t>"));
    // Every style the body uses is defined.
    for id in ["Normal", "Heading1", "Heading2", "Heading3", "Heading4", "Heading5", "Heading6", "Quote", "Code", "ListParagraph", "TableCell", "TableHeader", "FootnoteText", "InlineCode", "Hyperlink", "FootnoteReference", "HorizontalRule"] {
        d.style(id);
    }
}

#[test]
fn docx_front_matter_html_and_math_are_not_text() {
    let d = docx("---\ntitle: Secret\n---\n\n<div>raw</div>\n\nA <b>word</b> and $x^2$ end\n");
    let x = d.document();
    assert!(!x.contains("Secret") && !x.contains(">raw<") && !x.contains("<b>"), "{x}");
    // Inline HTML is dropped, its text kept; math is its text.
    assert!(x.contains(">A </w:t>") && x.contains(">word</w:t>") && x.contains("$x^2$"));
}

#[test]
fn docx_inline_formatting() {
    let d = docx("*em* **strong** ~~gone~~ `code` ***both***\n");
    let x = d.document();
    assert!(x.contains("<w:rPr><w:i/><w:iCs/></w:rPr><w:t xml:space=\"preserve\">em</w:t>"));
    assert!(x.contains("<w:rPr><w:b/><w:bCs/></w:rPr><w:t xml:space=\"preserve\">strong</w:t>"));
    assert!(x.contains("<w:strike/></w:rPr><w:t xml:space=\"preserve\">gone</w:t>"));
    assert!(x.contains("<w:rStyle w:val=\"InlineCode\"/></w:rPr><w:t xml:space=\"preserve\">code</w:t>"));
    assert!(x.contains("<w:b/><w:bCs/><w:i/><w:iCs/></w:rPr><w:t xml:space=\"preserve\">both</w:t>"));
    // Inline code is set in the mono family.
    assert!(d.style("InlineCode").contains("w:ascii=\"Menlo\""));
}

#[test]
fn docx_links_are_relationships() {
    let d = docx("[a](https://x.org/a) [again](https://x.org/a) <https://y.org> <me@x.org> bare https://z.org/p [in page](#head)\n");
    let (x, rels) = (d.document(), d.rels());
    assert_eq!(count(&x, "<w:hyperlink "), 5);
    // The same address twice is one relationship; three more addresses; a link within the page is none.
    assert_eq!(count(&rels, "TargetMode=\"External\""), 4);
    assert!(rels.contains("Target=\"https://x.org/a\"") && rels.contains("Target=\"mailto:me@x.org\"") && rels.contains("Target=\"https://z.org/p\""));
    assert!(x.contains("<w:rStyle w:val=\"Hyperlink\"/>"));
    assert!(x.contains(">in page</w:t>"));
    // Ampersands in an address are escaped.
    let d = docx("[q](https://x.org/?a=1&b=2)\n");
    assert!(d.rels().contains("Target=\"https://x.org/?a=1&amp;b=2\""));
}

#[test]
fn docx_wikilinks_are_their_label() {
    let x = docx("see [[Target|the label]] and [[Plain]]\n").document();
    assert!(x.contains(">the label</w:t>") && x.contains(">Plain</w:t>") && !x.contains("[["));
    assert!(!x.contains("<w:hyperlink"));
}

#[test]
fn docx_hard_and_soft_breaks() {
    let x = docx("one  \ntwo\nthree\n").document();
    assert_eq!(count(&x, "<w:br/>"), 1);
    assert!(x.contains(">two</w:t>") && x.contains("> </w:t>"));
}

#[test]
fn docx_footnotes_are_real_footnotes() {
    let d = docx("A[^a] and B[^b] and A again[^a].\n\n[^b]: Second *note*.\n[^a]: First note.\n");
    let x = d.document();
    // Numbered by first reference; the second reference to a note is its number in the text.
    assert!(x.contains("<w:footnoteReference w:id=\"1\"/>") && x.contains("<w:footnoteReference w:id=\"2\"/>"));
    assert_eq!(count(&x, "<w:footnoteReference"), 2);
    let f = d.footnotes();
    assert!(f.contains("w:type=\"separator\"") && f.contains("w:type=\"continuationSeparator\""));
    let first = f.find("<w:footnote w:id=\"1\">").unwrap();
    let second = f.find("<w:footnote w:id=\"2\">").unwrap();
    assert!(f[first..second].contains("First note.") && f[second..].contains("Second ") && f[second..].contains("<w:i/>"));
    assert_eq!(count(&f, "<w:footnoteRef/>"), 2);
    assert!(f.contains("<w:pStyle w:val=\"FootnoteText\"/>"));
    assert!(d.part("word/settings.xml").contains("<w:footnotePr>"));
}

#[test]
fn docx_lists_use_numbering() {
    let d = docx("- a\n  - b\n- c\n\nText\n\n1. one\n2. two\n\nText\n\n3. three\n4. four\n");
    let x = d.document();
    let n = d.numbering();
    assert!(x.contains("<w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/>") && x.contains("<w:ilvl w:val=\"1\"/><w:numId w:val=\"1\"/>"));
    // One bullet definition, one decimal definition, six levels each.
    assert_eq!(count(&n, "<w:abstractNum "), 3);
    assert_eq!(count(&n, "<w:lvl w:ilvl=\"5\">"), 3);
    assert!(n.contains("w:numFmt w:val=\"bullet\"") && n.contains("w:numFmt w:val=\"decimal\""));
    // Each numbered list is an instance of its own; the one that starts at 3 says so.
    assert!(x.contains("<w:numId w:val=\"3\"/>") && x.contains("<w:numId w:val=\"4\"/>"));
    assert!(n.contains("<w:startOverride w:val=\"1\"/>") && n.contains("<w:startOverride w:val=\"3\"/>"));
    assert!(n.contains("<w:start w:val=\"3\"/>"));
    assert_eq!(count(&x, "<w:pStyle w:val=\"ListParagraph\"/>"), 7);
}

#[test]
fn docx_loose_items_keep_their_paragraphs() {
    let x = docx("- one\n\n  second paragraph\n\n- two\n").document();
    // The marker is on the first paragraph only; the second is indented under it.
    assert_eq!(count(&x, "<w:numPr>"), 2);
    assert!(x.contains(">second paragraph</w:t>") && x.contains("<w:ind w:left=\"720\"/>"));
}

#[test]
fn docx_task_items_are_box_glyphs() {
    let x = docx("- [ ] open\n- [x] done\n").document();
    assert!(x.contains("\u{2610}") && x.contains("\u{2611}") && !x.contains("<w:numPr>"));
    assert!(x.contains(">open</w:t>") && x.contains(">done</w:t>"));
}

#[test]
fn docx_block_quote_and_code() {
    let d = docx("> quoted\n>\n> > deeper\n\n```\nline one\n\tline two\n\nline four\n```\n");
    let x = d.document();
    assert!(x.contains("<w:pStyle w:val=\"Quote\"/>") && x.contains(">quoted</w:t>"));
    // A quote inside a quote is further in.
    assert!(x.contains("<w:pStyle w:val=\"Quote\"/><w:ind w:left=\"720\"/>"));
    // One paragraph, its lines kept as breaks and its tab as a tab.
    assert_eq!(count(&x, "<w:pStyle w:val=\"Code\"/>"), 1);
    assert_eq!(count(&x, "<w:br/>"), 3);
    assert!(x.contains("<w:tab/>") && x.contains(">line four</w:t>"));
    assert!(d.style("Code").contains("<w:shd ") && d.style("Code").contains("Menlo"));
}

#[test]
fn docx_tables() {
    let d = docx("| A | B | C |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |\n|   | x |   |\n");
    let x = d.document();
    assert_eq!(count(&x, "<w:tbl>"), 1);
    assert_eq!(count(&x, "<w:tr>"), 3);
    assert_eq!(count(&x, "<w:tblHeader/>"), 1);
    assert_eq!(count(&x, "<w:tc>"), 9);
    assert_eq!(count(&x, "<w:gridCol "), 3);
    assert!(x.contains("<w:top w:val=\"single\"") && x.contains("<w:insideV w:val=\"single\""));
    // The header's paragraphs are in the header style; the alignment is each column's.
    assert_eq!(count(&x, "<w:pStyle w:val=\"TableHeader\"/>"), 3);
    assert!(x.contains("<w:jc w:val=\"center\"/>") && x.contains("<w:jc w:val=\"right\"/>") && x.contains("<w:jc w:val=\"left\"/>"));
    // An empty cell still has its paragraph, and the body ends with one after the table.
    assert_eq!(count(&x, "</w:tc>"), count(&x, "<w:tc>"));
    assert!(x.contains("</w:tbl><w:p/><w:sectPr>"));
    assert!(d.style("TableHeader").contains("<w:b/>"));
}

#[test]
fn docx_rules() {
    let d = docx("a\n\n---\n\nb\n");
    assert!(d.document().contains("<w:pStyle w:val=\"HorizontalRule\"/>"));
    assert!(d.style("HorizontalRule").contains("<w:bottom "));
}

#[test]
fn docx_pictures() {
    let opts = DocxOptions {
        image_data: vec![small_png()],
        image_sizes: vec![ImageSize { destination: "pictures/small.png".into(), width: 100, height: 50 }],
        ..Default::default()
    };
    let d = docx_with("![A small picture](pictures/small.png) and again ![x](pictures/small.png)\n", &opts);
    let x = d.document();
    assert_eq!(count(&x, "<w:drawing>"), 2);
    // 100 x 50 points in EMU; the same file twice is one part and one relationship.
    assert!(x.contains("<wp:extent cx=\"1270000\" cy=\"635000\"/>"));
    assert!(x.contains("descr=\"A small picture\""));
    assert_eq!(d.parts.keys().filter(|k| k.starts_with("word/media/")).count(), 1);
    assert_eq!(d.parts["word/media/image1.png"], picture());
    assert_eq!(count(&d.rels(), "relationships/image\""), 1);
    assert!(d.rels().contains("Target=\"media/image1.png\""));
    assert!(d.part("[Content_Types].xml").contains("Extension=\"png\" ContentType=\"image/png\""));
}

#[test]
fn docx_picture_wider_than_the_page_is_scaled_to_the_text() {
    let opts = DocxOptions {
        image_data: vec![small_png()],
        image_sizes: vec![ImageSize { destination: "pictures/small.png".into(), width: 2000, height: 1000 }],
        ..Default::default()
    };
    let x = docx_with("![w](pictures/small.png)\n", &opts).document();
    // Letter with one-inch margins: 6.5 inches of text, 5943600 EMU, and the height keeps the ratio.
    assert!(x.contains("<wp:extent cx=\"5943600\" cy=\"2971800\"/>"), "{x}");
}

#[test]
fn docx_picture_without_a_size_uses_its_own_pixels() {
    let opts = DocxOptions { image_data: vec![small_png()], ..Default::default() };
    let x = docx_with("![w](pictures/small.png)\n", &opts).document();
    let (w, h) = png_size(&picture());
    assert!(x.contains(&format!("<wp:extent cx=\"{}\" cy=\"{}\"/>", w * 9525, h * 9525)), "{x}");
}

fn png_size(b: &[u8]) -> (u32, u32) {
    (u32::from_be_bytes(b[16..20].try_into().unwrap()), u32::from_be_bytes(b[20..24].try_into().unwrap()))
}

#[test]
fn docx_picture_that_could_not_be_read_is_its_alt_text() {
    let x = docx("![the alt text](missing.png)\n").document();
    assert!(!x.contains("<w:drawing>") && x.contains(">the alt text</w:t>"));
    // Bytes that are not a picture Word reads (SVG) are the same.
    let opts = DocxOptions { image_data: vec![ImageData { destination: "a.svg".into(), mime: "image/svg+xml".into(), bytes: b"<svg/>".to_vec() }], ..Default::default() };
    let d = docx_with("![vector](a.svg)\n", &opts);
    assert!(!d.document().contains("<w:drawing>") && d.document().contains(">vector</w:t>"));
    assert!(!d.parts.keys().any(|k| k.starts_with("word/media/")));
}

#[test]
fn docx_escapes_what_xml_cannot_carry() {
    let x = docx("a < b & c > d \"q\" 'r'\u{c}\n").document();
    assert!(x.contains("a &lt; b &amp; c &gt; d &quot;q&quot; &apos;r&apos;"));
    assert!(!x.contains('\u{c}'));
}

#[test]
fn docx_default_template_styles() {
    let d = docx("# H\n\ntext\n");
    // The editor's 11 pt, headings at the preview's scale, bold, in the Light theme's colours.
    assert!(d.styles().contains("<w:sz w:val=\"22\"/>"));
    let h1 = d.style("Heading1");
    assert!(h1.contains("<w:sz w:val=\"37\"/>") && h1.contains("<w:b/>") && h1.contains("w:val=\"111214\""));
    assert!(h1.contains("<w:outlineLvl w:val=\"0\"/>") && h1.contains("<w:keepNext/>"));
    assert!(!h1.contains("<w:numPr>"));
    assert!(d.style("Heading6").contains("w:val=\"585D66\""));
    assert!(d.style("Normal").contains("w:val=\"26282B\""));
    assert!(d.style("Quote").contains("w:val=\"585D66\"") && d.style("Quote").contains("<w:left w:val=\"single\""));
    assert!(d.style("Hyperlink").contains("w:val=\"1859C9\""));
    // Letter, one-inch margins.
    let x = d.document();
    assert!(x.contains("<w:pgSz w:w=\"12240\" w:h=\"15840\"/>") && x.contains("w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\""));
}

#[test]
fn docx_takes_the_editors_fonts_where_the_template_says_body_and_mono() {
    let typography = Typography {
        font_family: "\"Bundled Quattro\", -apple-system, \"Helvetica Neue\", sans-serif".into(),
        mono_family: "ui-monospace, SFMono-Regular, Menlo, monospace".into(),
        ..Typography::default()
    };
    let d = docx_with("text\n", &DocxOptions { typography, ..Default::default() });
    assert!(d.style("Normal").contains("w:ascii=\"Bundled Quattro\""));
    // The system aliases are skipped for the first real name.
    assert!(d.style("Code").contains("w:ascii=\"Menlo\""));
}

#[test]
fn docx_in_the_academic_template_looks_like_academic() {
    let opts = DocxOptions { spec: academic(), ..Default::default() };
    let d = docx_with("# T\n\n## S\n\n### U\n\n#### V\n\ntext\n\n> q\n\n| a |\n| - |\n| b |\n", &opts);
    // The family, the line height and the justified body.
    let normal = d.style("Normal");
    assert!(normal.contains("w:ascii=\"Charter\"") && normal.contains("<w:jc w:val=\"both\"/>") && normal.contains("w:line=\"372\""));
    // Heading sizes: 1.9em, 1.45em and 1.2em of 11 pt, left aligned, the numbered ones tied to the outline numbering.
    let h1 = d.style("Heading1");
    assert!(h1.contains("<w:sz w:val=\"42\"/>") && h1.contains("<w:jc w:val=\"left\"/>") && h1.contains("<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"2\"/>"));
    assert!(d.style("Heading2").contains("<w:sz w:val=\"32\"/>") && d.style("Heading2").contains("<w:ilvl w:val=\"1\"/>"));
    let h3 = d.style("Heading3");
    assert!(h3.contains("<w:sz w:val=\"26\"/>") && h3.contains("<w:i/>"));
    assert!(d.style("Heading4").contains("<w:i/>") && !d.style("Heading4").contains("<w:numPr>"));
    // The headings' numbering: `1.`, `1.1`, `1.1.1`.
    let n = d.numbering();
    assert!(n.contains("<w:lvlText w:val=\"%1.\"/>") && n.contains("<w:lvlText w:val=\"%1.%2\"/>") && n.contains("<w:lvlText w:val=\"%1.%2.%3\"/>"));
    assert!(n.contains("<w:pStyle w:val=\"Heading2\"/>"));
    // The quote is italic; the code block's radius is no concern of Word's; the table's heavy top rule and the header's.
    assert!(d.style("Quote").contains("<w:i/>"));
    let x = d.document();
    assert!(x.contains("<w:top w:val=\"single\" w:sz=\"12\" w:space=\"0\" w:color=\"26282B\"/>"), "{x}");
    assert!(x.contains("<w:tcBorders><w:bottom w:val=\"single\" w:sz=\"6\""));
    // The footnotes are small.
    assert!(d.style("FootnoteText").contains("<w:sz w:val=\"16\"/>") || d.style("FootnoteText").contains("<w:sz w:val=\"18\"/>"));
}

#[test]
fn docx_page_comes_from_the_template_and_the_paper() {
    // 66 characters of 11 pt text on Letter: a narrower column than the default one-inch margins give.
    let d = docx_with("x\n", &DocxOptions { spec: academic(), ..Default::default() });
    let x = d.document();
    let left: i64 = x.split("w:left=\"").nth(1).unwrap().split('"').next().unwrap().parse().unwrap();
    assert!(left > 1440 && left <= 2880, "{left}");
    // A paper the shell names (A4), and a template that fixes the column's padding.
    let mut spec = template::TemplateSpec::default();
    spec.page.side_padding = Some(template::Length::new(0.5, template::Unit::Em));
    let d = docx_with("x\n", &DocxOptions { spec, page_width_pt: 595.0, page_height_pt: 842.0, ..Default::default() });
    let x = d.document();
    assert!(x.contains("<w:pgSz w:w=\"11900\" w:h=\"16840\"/>"));
    assert!(x.contains("w:left=\"1550\""), "{x}");
}

#[test]
fn docx_template_colours_resolve_through_the_light_theme() {
    let mut spec = template::TemplateSpec::default();
    let link = template::ElementStyle { color: Some(template::ColorRef::Theme(template::ThemeColor::Link)), ..Default::default() };
    spec.elements.insert(template::ElementKind::H2, link);
    let own = template::ElementStyle {
        color: Some(template::ColorRef::Fixed(template::Rgb(0x12, 0x34, 0x56))),
        font_family: Some(template::FontFamily::Named("Georgia, serif".into())),
        font_size: Some(template::Length::new(24.0, template::Unit::Pt)),
        transform: Some(template::Transform::SmallCaps),
        ..Default::default()
    };
    spec.elements.insert(template::ElementKind::H3, own);
    let d = docx_with("## a\n", &DocxOptions { spec, ..Default::default() });
    assert!(d.style("Heading2").contains("w:val=\"1859C9\""));
    let h3 = d.style("Heading3");
    assert!(h3.contains("w:val=\"123456\"") && h3.contains("w:ascii=\"Georgia\"") && h3.contains("<w:sz w:val=\"48\"/>") && h3.contains("<w:smallCaps/>"));
}

#[test]
fn docx_title_is_in_the_properties() {
    let d = docx_with("x\n", &DocxOptions { title: "A & B".into(), ..Default::default() });
    assert!(d.part("docProps/core.xml").contains("<dc:title>A &amp; B</dc:title>"));
}

#[test]
fn docx_of_every_fixture_is_well_formed() {
    let mut inputs = fixtures();
    inputs.push(("export-formats".to_owned(), export_fixture("export-formats.md")));
    inputs.push(("tour".to_owned(), export_fixture("tour.md")));
    for (name, text) in inputs {
        let opts = DocxOptions { spec: academic(), image_data: vec![small_png()], ..Default::default() };
        let d = docx_with(&text, &opts);
        assert!(d.document().len() > 100, "{name}");
    }
}

#[test]
fn docx_survives_what_panics_the_parser() {
    let d = docx(">1. [r]:u\n\t");
    assert!(d.document().contains("<w:p>"));
}

#[test]
fn docx_odd_structure_does_not_lose_markers_or_break() {
    // An item that starts with a block of its own, a list that starts with a list, a table in a quote, empty items.
    for text in ["- ```\n  code\n  ```\n", "- - nested first\n", "-\n- \n", "> | a |\n> | - |\n> | b |\n", "1. # heading in item\n", "- ![p](a.png)\n", "- > quote in item\n"] {
        let d = docx(text);
        assert!(d.document().contains("<w:body>"), "{text:?}");
    }
    let x = docx("- ```\n  code\n  ```\n").document();
    assert!(x.contains("<w:numPr>") && x.contains(">code</w:t>"));
}

#[test]
fn docx_is_deterministic() {
    let text = export_fixture("export-formats.md");
    let opts = DocxOptions { spec: academic(), image_data: vec![small_png()], ..Default::default() };
    assert_eq!(doc(&text).render_docx(&opts), doc(&text).render_docx(&opts));
}

#[test]
fn docx_fixture_has_every_construct() {
    let opts = DocxOptions { spec: academic(), image_data: vec![small_png()], ..Default::default() };
    let d = docx_with(&export_fixture("export-formats.md"), &opts);
    let x = d.document();
    for needle in [
        "Heading1", "Heading2", "Heading3", "Quote", "Code", "TableHeader", "<w:tbl>", "<w:hyperlink", "<w:footnoteReference", "<w:drawing>", "HorizontalRule",
        "<w:strike/>", "InlineCode", "\u{2610}", "\u{2611}", "<w:br/>",
    ] {
        assert!(x.contains(needle), "{needle}");
    }
    assert!(!x.contains("Raw HTML") && !x.contains("Export Formats</w:t></w:r></w:p><w:p><w:pPr><w:pStyle w:val=\"Normal\"/></w:pPr><w:r><w:t xml:space=\"preserve\">---"));
    assert_eq!(count(&d.rels(), "relationships/hyperlink\""), 2);
}
