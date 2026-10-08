//! `word/styles.xml`: one Word style for every kind of element the template styles, built from the resolved template and
//! the editor's typography. What the template leaves unsaid is what the preview's stylesheet does (heading sizes and
//! margins, the quote's bar, the code panel), set in Word's terms.

use std::fmt::Write;

use crate::template::ElementKind;

use super::look::{Face, Look, Para, DEFAULT_BODY_PT};
use super::xml::{escape, half_points, twips, val, NAMESPACES, XML_DECLARATION};

/// Which of the three heading levels with numbering the template asks for (`numbered = true`).
pub(crate) fn numbered_levels(look: &Look) -> [bool; 3] {
    let n = |kind| look.element(kind).and_then(|e| e.numbered) == Some(true);
    [n(ElementKind::H1), n(ElementKind::H2), n(ElementKind::H3)]
}

/// The run properties of a face, in the order the schema wants them.
pub(crate) fn rpr_xml(face: &Face, with_family: bool) -> String {
    let mut x = String::new();
    if with_family {
        let f = escape(&face.family);
        let _ = write!(x, "<w:rFonts w:ascii=\"{f}\" w:hAnsi=\"{f}\" w:eastAsia=\"{f}\" w:cs=\"{f}\"/>");
    }
    if face.bold {
        x.push_str("<w:b/><w:bCs/>");
    }
    if face.italic {
        x.push_str("<w:i/><w:iCs/>");
    }
    if face.caps {
        x.push_str("<w:caps/>");
    }
    if face.small_caps {
        x.push_str("<w:smallCaps/>");
    }
    let _ = write!(x, "<w:color w:val=\"{}\"/>", face.color);
    if let Some(s) = face.spacing_pt {
        x.push_str(&val("spacing", twips(s)));
    }
    let size = half_points(face.size_pt);
    let _ = write!(x, "<w:sz w:val=\"{size}\"/><w:szCs w:val=\"{size}\"/>");
    if face.underline {
        x.push_str("<w:u w:val=\"single\"/>");
    }
    x
}

/// The paragraph properties of `para`; `num_pr` and `outline` are the numbering and outline level of a heading.
pub(crate) fn ppr_xml(para: &Para, num_pr: &str, outline: Option<u8>) -> String {
    let mut x = String::new();
    if para.keep_with_next {
        x.push_str("<w:keepNext/><w:keepLines/>");
    }
    x.push_str(num_pr);
    if !para.borders.is_empty() {
        x.push_str("<w:pBdr>");
        for side in ["top", "left", "bottom", "right"] {
            for (s, line, size, color, space) in &para.borders {
                if *s == side {
                    let _ = write!(x, "<w:{s} w:val=\"{line}\" w:sz=\"{size}\" w:space=\"{space}\" w:color=\"{color}\"/>");
                }
            }
        }
        x.push_str("</w:pBdr>");
    }
    if let Some(fill) = &para.shade {
        let _ = write!(x, "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"{fill}\"/>");
    }
    let _ = write!(x, "<w:spacing w:before=\"{}\" w:after=\"{}\"", twips(para.before_pt), twips(para.after_pt));
    if let Some(l) = para.line {
        let _ = write!(x, " w:line=\"{}\" w:lineRule=\"auto\"", (l * 240.0).round() as i64);
    }
    x.push_str("/>");
    if para.left_pt != 0.0 || para.first_line_pt.is_some() {
        let _ = write!(x, "<w:ind w:left=\"{}\"", twips(para.left_pt));
        if let Some(f) = para.first_line_pt {
            let _ = write!(x, " w:firstLine=\"{}\"", twips(f));
        }
        x.push_str("/>");
    }
    if let Some(a) = para.align {
        x.push_str(&val("jc", a));
    }
    if let Some(l) = outline {
        x.push_str(&val("outlineLvl", l));
    }
    x
}

struct Writer {
    out: String,
}

impl Writer {
    /// A paragraph style. `heading` is a heading's numbering and outline level.
    fn paragraph(&mut self, id: &str, name: &str, based: Option<&str>, face: &Face, para: &Para, heading: Option<(&str, u8)>) {
        let (num_pr, outline) = heading.map_or(("", None), |(n, l)| (n, Some(l)));
        let _ = write!(self.out, "<w:style w:type=\"paragraph\" w:styleId=\"{id}\"><w:name w:val=\"{}\"/>", escape(name));
        if let Some(b) = based {
            let _ = write!(self.out, "<w:basedOn w:val=\"{b}\"/>");
        }
        self.out.push_str("<w:next w:val=\"Normal\"/><w:qFormat/>");
        let _ = write!(self.out, "<w:pPr>{}</w:pPr><w:rPr>{}</w:rPr></w:style>", ppr_xml(para, num_pr, outline), rpr_xml(face, true));
    }

    fn character(&mut self, id: &str, name: &str, rpr: &str) {
        let _ = write!(
            self.out,
            "<w:style w:type=\"character\" w:styleId=\"{id}\"><w:name w:val=\"{}\"/><w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"99\"/><w:rPr>{rpr}</w:rPr></w:style>",
            escape(name)
        );
    }
}

/// The whole of `styles.xml`. `heading_num` is the `numId` of the heading numbering when the template asks for one.
pub(crate) fn styles_xml(look: &Look, heading_num: Option<u32>) -> String {
    let t = &look.opts.typography;
    let c = |tc| look.theme_hex(tc);
    use crate::template::ThemeColor as T;

    // The body: the page's alignment, then the Body element, then the paragraph's own.
    let mut body_face = Face {
        family: look.body_family(),
        size_pt: DEFAULT_BODY_PT,
        bold: false,
        italic: false,
        color: c(T::Text),
        caps: false,
        small_caps: false,
        underline: false,
        spacing_pt: None,
    };
    let mut normal = Para { after_pt: look.body_pt, line: Some(t.line_height), ..Para::default() };
    if let Some(a) = look.opts.spec.page.align {
        normal.align = Some(super::look::align(a));
    }
    if let Some(e) = look.element(ElementKind::Body) {
        look.apply(e, ElementKind::Body, &mut body_face, &mut normal, DEFAULT_BODY_PT);
    }
    body_face.size_pt = look.body_pt;
    if let Some(e) = look.element(ElementKind::Paragraph) {
        look.apply(e, ElementKind::Paragraph, &mut body_face, &mut normal, look.body_pt);
    }

    let mut w = Writer { out: String::new() };
    w.out.push_str(XML_DECLARATION);
    let _ = write!(w.out, "<w:styles {NAMESPACES}>");
    let family = escape(&body_face.family);
    let _ = write!(
        w.out,
        "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"{family}\" w:hAnsi=\"{family}\" w:eastAsia=\"{family}\" w:cs=\"{family}\"/>\
<w:sz w:val=\"{0}\"/><w:szCs w:val=\"{0}\"/><w:lang w:val=\"en-US\" w:eastAsia=\"en-US\" w:bidi=\"ar-SA\"/></w:rPr></w:rPrDefault>\
<w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>",
        half_points(look.body_pt)
    );
    w.out.push_str("<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/>");
    let _ = write!(w.out, "<w:pPr>{}</w:pPr><w:rPr>{}</w:rPr></w:style>", ppr_xml(&normal, "", None), rpr_xml(&body_face, true));
    w.out.push_str(
        "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/></w:style>\
<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/>\
<w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>\
<w:style w:type=\"numbering\" w:default=\"1\" w:styleId=\"NoList\"><w:name w:val=\"No List\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/></w:style>",
    );

    // Headings: the preview's sizes and margins, the heading colour (the sixth level's in the quote colour).
    let sizes = [1.7, 1.4, 1.2, 1.1, 1.0, 1.0];
    let kinds = [ElementKind::H1, ElementKind::H2, ElementKind::H3, ElementKind::H4, ElementKind::H5, ElementKind::H6];
    let numbered = numbered_levels(look);
    for (n, kind) in kinds.into_iter().enumerate() {
        let mut face = Face { size_pt: look.body_pt * sizes[n], bold: true, color: c(if n == 5 { T::Quote } else { T::Heading }), ..body_face.clone() };
        let mut para = Para {
            before_pt: look.body_pt * if n < 3 { 0.55 } else { 0.35 },
            after_pt: look.body_pt * 0.6,
            line: Some(1.3),
            keep_with_next: true,
            align: normal.align,
            ..Para::default()
        };
        if let Some(e) = look.element(kind) {
            look.apply(e, kind, &mut face, &mut para, look.body_pt);
        }
        let num_pr = match heading_num {
            Some(id) if n < 3 && numbered[n] => format!("<w:numPr><w:ilvl w:val=\"{n}\"/><w:numId w:val=\"{id}\"/></w:numPr>"),
            _ => String::new(),
        };
        let level = n + 1;
        w.paragraph(&format!("Heading{level}"), &format!("heading {level}"), Some("Normal"), &face, &para, Some((&num_pr, n as u8)));
    }

    // Block quote: the bar and the indent of the preview, in the quote colour.
    let mut face = Face { color: c(T::Quote), ..body_face.clone() };
    let mut para = Para { left_pt: 18.0, after_pt: look.body_pt, line: normal.line, align: normal.align, ..Para::default() };
    para.borders.push(("left", "single", 18, c(T::Rule), 8));
    if let Some(e) = look.element(ElementKind::BlockQuote) {
        look.apply(e, ElementKind::BlockQuote, &mut face, &mut para, look.body_pt);
    }
    w.paragraph("Quote", "Quote", Some("Normal"), &face, &para, None);

    // Code: the panel's colour behind the mono face, boxed in its own colour so the panel has room around the text.
    let code_pt = look.body_pt * if look.body_is_mono() { 1.0 } else { 0.92 };
    let mut face = Face { family: look.mono_family(), size_pt: code_pt, color: c(T::Text), ..body_face.clone() };
    let mut para = Para { after_pt: look.body_pt, line: Some(1.4), shade: Some(c(T::CodeBackground)), ..Para::default() };
    for side in ["top", "left", "bottom", "right"] {
        para.borders.push((side, "single", 4, c(T::CodeBackground), 4));
    }
    if let Some(e) = look.element(ElementKind::CodeBlock) {
        look.apply(e, ElementKind::CodeBlock, &mut face, &mut para, look.body_pt);
    }
    // The block is left-aligned whatever the page's alignment is: justified code stretches its lines apart.
    para.align = None;
    w.paragraph("Code", "Code", Some("Normal"), &face, &para, None);

    // Lists, table cells, the footnotes and the rule.
    let para = Para { after_pt: look.body_pt * 0.15, line: normal.line, align: normal.align, ..Para::default() };
    w.paragraph("ListParagraph", "List Paragraph", Some("Normal"), &body_face, &para, None);

    let cell = Para { line: normal.line, ..Para::default() };
    w.paragraph("TableCell", "Table Cell", Some("Normal"), &body_face, &cell, None);
    let mut face = Face { bold: true, ..body_face.clone() };
    let mut para = cell.clone();
    if let Some(e) = look.element(ElementKind::TableHeader) {
        look.apply(e, ElementKind::TableHeader, &mut face, &mut para, look.body_pt);
    }
    // The header's border is a cell's, drawn by the table; a paragraph does not carry it.
    para.borders.clear();
    w.paragraph("TableHeader", "Table Header", Some("TableCell"), &face, &para, None);

    let mut face = Face { size_pt: look.body_pt * 0.9, color: c(T::Quote), ..body_face.clone() };
    let mut para = Para { after_pt: look.body_pt * 0.4, line: normal.line, align: normal.align, ..Para::default() };
    if let Some(e) = look.element(ElementKind::Footnotes) {
        look.apply(e, ElementKind::Footnotes, &mut face, &mut para, look.body_pt);
    }
    para.borders.clear();
    w.paragraph("FootnoteText", "footnote text", Some("Normal"), &face, &para, None);

    let mut rule = Para { before_pt: look.body_pt, after_pt: look.body_pt, line: Some(1.0), ..Para::default() };
    rule.borders.push(("bottom", "single", 6, c(T::Rule), 1));
    if let Some(e) = look.element(ElementKind::Rule) {
        let mut face = body_face.clone();
        look.apply(e, ElementKind::Rule, &mut face, &mut rule, look.body_pt);
    }
    w.paragraph("HorizontalRule", "Horizontal Rule", Some("Normal"), &Face { size_pt: 2.0, ..body_face.clone() }, &rule, None);

    // Character styles: inline code, links, the footnote's number.
    let mut face = Face { family: look.mono_family(), size_pt: code_pt, color: c(T::CodeText), ..body_face.clone() };
    let mut unused = Para::default();
    if let Some(e) = look.element(ElementKind::InlineCode) {
        look.apply(e, ElementKind::InlineCode, &mut face, &mut unused, look.body_pt);
    }
    let shade = unused.shade.take().unwrap_or_else(|| c(T::CodeBackground));
    // Run properties: the face, then the panel's shading (after underline in the schema's order).
    w.character("InlineCode", "Inline Code", &format!("{}<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"{shade}\"/>", rpr_xml(&face, true)));

    let mut face = Face { color: c(T::Link), underline: true, ..body_face.clone() };
    if let Some(e) = look.element(ElementKind::Link) {
        look.apply(e, ElementKind::Link, &mut face, &mut Para::default(), look.body_pt);
    }
    // Only what differs from the paragraph it sits in: colour, underline and a template's weight or case.
    let mut link = format!("<w:color w:val=\"{}\"/>", face.color);
    if face.underline {
        link.push_str("<w:u w:val=\"single\"/>");
    }
    if face.bold != body_face.bold {
        link = format!("{}{link}", if face.bold { "<w:b/>" } else { "" });
    }
    w.character("Hyperlink", "Hyperlink", &link);
    w.character("FootnoteReference", "footnote reference", "<w:vertAlign w:val=\"superscript\"/>");

    w.out.push_str("</w:styles>");
    w.out
}
