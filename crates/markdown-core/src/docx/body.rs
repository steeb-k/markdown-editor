//! `word/document.xml`'s body and the notes' bodies: the events walked into paragraphs, runs, lists and tables.
//!
//! A paragraph is open from its first run to the next block. Inline text outside a paragraph event (a tight list item, a
//! table cell) opens one of its own, so the same code writes both. The containers around the text (quotes, lists, items,
//! cells) are a stack of frames; a paragraph asks it for its style, its list marker and its indent when it opens.

use std::collections::HashSet;
use std::fmt::Write;

use pulldown_cmark::{Alignment, Event, LinkType, Tag, TagEnd};

use crate::render::ImageData;
use crate::template::{ElementKind, ThemeColor};
use crate::walk::{Notes, Piece, Tree};

use super::look::Look;
use super::media;
use super::numbering::{level_indent, Numbering};
use super::package::Resources;
use super::xml::escape;

/// What encloses the text being written.
enum Frame {
    Quote,
    List { num_id: u32, level: usize },
    /// `pending`: its marker is still to be written, on its first paragraph.
    Item { num_id: u32, level: usize, pending: bool, task: Option<bool> },
    /// A table cell: whether it is in the header row, and its column's alignment (a `w:jc` value).
    Cell { head: bool, jc: Option<&'static str> },
}

/// The paragraph being written: its properties and its runs.
struct Open {
    ppr: String,
    runs: String,
    /// Written even when it holds no runs (it carries a list marker, or is a code block).
    keep: bool,
}

#[derive(Default)]
struct Format {
    bold: u32,
    italic: u32,
    strike: u32,
    sup: u32,
    sub: u32,
    code: u32,
    link: u32,
}

/// What a paragraph is, besides what encloses it.
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Auto,
    Heading(u8),
    Code,
}

struct TableCtx {
    col_width: i64,
    aligns: Vec<Alignment>,
    col: usize,
    head: bool,
}

pub(crate) struct Body<'t, 'a, 'o> {
    tree: &'t Tree<'a>,
    look: &'t Look<'o>,
    res: &'t mut Resources,
    numbering: &'t mut Numbering,
    notes: Notes,
    out: String,
    open: Option<Open>,
    frames: Vec<Frame>,
    fmt: Format,
    /// For each link met and not yet ended: whether it became a hyperlink.
    links: Vec<bool>,
    table: Option<TableCtx>,
    /// Where the output stood when the current cell began (an empty cell still needs a paragraph).
    cell_mark: usize,
    referenced: HashSet<String>,
    in_footnote: bool,
    /// The first paragraph of a note starts with the note's own number.
    note_mark_pending: bool,
    drawing_id: u32,
    text_width: i64,
}

impl<'t, 'a, 'o> Body<'t, 'a, 'o> {
    pub fn new(tree: &'t Tree<'a>, look: &'t Look<'o>, res: &'t mut Resources, numbering: &'t mut Numbering) -> Self {
        Body {
            notes: Notes::new(tree),
            tree,
            look,
            res,
            numbering,
            out: String::new(),
            open: None,
            frames: Vec::new(),
            fmt: Format::default(),
            links: Vec::new(),
            table: None,
            cell_mark: 0,
            referenced: HashSet::new(),
            in_footnote: false,
            note_mark_pending: false,
            drawing_id: 0,
            text_width: look.page().text_width(),
        }
    }

    /// The main body: the whole document.
    pub fn document(&mut self) -> String {
        self.walk(0, self.tree.events.len());
        // A table cannot be the last thing in the body: Word wants a paragraph after it.
        if self.out.ends_with("</w:tbl>") {
            self.out.push_str("<w:p/>");
        }
        std::mem::take(&mut self.out)
    }

    /// A body for text the parser could not take: one paragraph per line, as written.
    pub fn lines(&mut self, text: &str) -> String {
        for line in text.lines() {
            self.open_para(Kind::Auto);
            self.text(line);
            self.close_para();
        }
        std::mem::take(&mut self.out)
    }

    /// The `<w:footnote>` elements of the notes the body referred to, in the order of their numbers.
    pub fn footnotes(&mut self) -> String {
        let mut x = String::new();
        for (k, name) in self.notes.order.clone().into_iter().enumerate() {
            let Some(range) = self.notes.defs.get(&name).cloned() else { continue };
            self.in_footnote = true;
            self.note_mark_pending = true;
            self.walk(range.start, range.end);
            // A note with no text still has its number.
            if self.note_mark_pending {
                self.open_para(Kind::Auto);
                self.close_para();
            }
            self.in_footnote = false;
            let _ = write!(x, "<w:footnote w:id=\"{}\">{}</w:footnote>", k + 1, std::mem::take(&mut self.out));
        }
        x
    }

    // ----- paragraphs --------------------------------------------------------------------------------------

    fn quote_depth(&self) -> i64 {
        self.frames.iter().filter(|f| matches!(f, Frame::Quote)).count() as i64
    }

    /// Opens a paragraph (closing the one before), with the style, marker and indent its surroundings give it.
    fn open_para(&mut self, kind: Kind) {
        self.close_para();
        let depth = self.quote_depth();
        let mut keep = kind == Kind::Code;
        let mut prefix = String::new();
        let mut num_pr = String::new();
        let mut indent: Option<(i64, i64)> = None;
        let mut jc = None;
        let style = if let Kind::Heading(n) = kind {
            format!("Heading{n}")
        } else {
            let mut base = None;
            let item = self.frames.iter_mut().rev().find_map(|f| match f {
                Frame::Item { num_id, level, pending, task } => Some((*num_id, *level, pending, task)),
                _ => None,
            });
            if let Some((num_id, level, pending, task)) = item {
                let (left, hanging) = level_indent(level);
                indent = Some((left + 360 * depth, 0));
                if std::mem::replace(pending, false) {
                    keep = true;
                    match task {
                        Some(checked) => {
                            // The box stands where a marker would: hung left of the text.
                            indent = Some((left, hanging));
                            let glyph = if *checked { "\u{2611}" } else { "\u{2610}" };
                            prefix = format!("<w:r><w:t>{glyph}</w:t></w:r><w:r><w:tab/></w:r>");
                        }
                        None => {
                            num_pr = format!("<w:numPr><w:ilvl w:val=\"{level}\"/><w:numId w:val=\"{num_id}\"/></w:numPr>");
                            // Numbering gives the indent, unless a quote pushes the text further in.
                            indent = (depth > 0).then_some((left + 360 * depth, hanging));
                        }
                    }
                }
                base = Some("ListParagraph");
            } else if depth > 1 {
                indent = Some((360 * depth, 0));
            }
            if let Some(Frame::Cell { head, jc: j }) = self.frames.last() {
                base = Some(if *head { "TableHeader" } else { "TableCell" });
                jc = *j;
                indent = None;
            } else if matches!(self.frames.last(), Some(Frame::Quote)) {
                base = Some("Quote");
            }
            match (kind, base) {
                (Kind::Code, _) => "Code".to_owned(),
                (_, Some(b)) => b.to_owned(),
                _ if self.in_footnote => "FootnoteText".to_owned(),
                _ => "Normal".to_owned(),
            }
        };
        let mut ppr = format!("<w:pStyle w:val=\"{style}\"/>{num_pr}");
        match indent {
            Some((left, hanging)) if hanging > 0 => {
                let _ = write!(ppr, "<w:ind w:left=\"{left}\" w:hanging=\"{hanging}\"/>");
            }
            Some((left, _)) if left > 0 => {
                let _ = write!(ppr, "<w:ind w:left=\"{left}\"/>");
            }
            _ => {}
        }
        if let Some(j) = jc {
            let _ = write!(ppr, "<w:jc w:val=\"{j}\"/>");
        }
        let mut runs = prefix;
        if std::mem::replace(&mut self.note_mark_pending, false) {
            runs.push_str("<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r><w:r><w:t xml:space=\"preserve\"> </w:t></w:r>");
        }
        self.open = Some(Open { ppr, runs, keep });
    }

    fn ensure_para(&mut self) {
        if self.open.is_none() {
            self.open_para(Kind::Auto);
        }
    }

    fn close_para(&mut self) {
        if let Some(p) = self.open.take()
            && (p.keep || !p.runs.is_empty())
        {
            let _ = write!(self.out, "<w:p><w:pPr>{}</w:pPr>{}</w:p>", p.ppr, p.runs);
        }
    }

    /// Before a block that is not a paragraph: an item whose first child it is has its marker written on a paragraph
    /// of its own, so the marker is not lost.
    fn before_block(&mut self) {
        self.close_para();
        let pending = self.frames.iter().rev().find_map(|f| match f {
            Frame::Item { pending, .. } => Some(*pending),
            _ => None,
        });
        if pending == Some(true) {
            self.open_para(Kind::Auto);
            self.close_para();
        }
    }

    // ----- runs --------------------------------------------------------------------------------------------

    fn rpr(&self) -> String {
        let f = &self.fmt;
        let mut x = String::new();
        if f.code > 0 {
            x.push_str("<w:rStyle w:val=\"InlineCode\"/>");
        } else if f.link > 0 {
            x.push_str("<w:rStyle w:val=\"Hyperlink\"/>");
        }
        let mut color = None;
        if f.bold > 0 {
            x.push_str("<w:b/><w:bCs/>");
            color = self.look.element(ElementKind::Strong).and_then(|e| e.color);
        }
        if f.italic > 0 {
            x.push_str("<w:i/><w:iCs/>");
            color = color.or_else(|| self.look.element(ElementKind::Emphasis).and_then(|e| e.color));
        }
        if f.strike > 0 {
            x.push_str("<w:strike/>");
        }
        if let (Some(c), 0) = (color, f.link) {
            let _ = write!(x, "<w:color w:val=\"{}\"/>", self.look.color(c));
        }
        if f.sup > 0 {
            x.push_str("<w:vertAlign w:val=\"superscript\"/>");
        } else if f.sub > 0 {
            x.push_str("<w:vertAlign w:val=\"subscript\"/>");
        }
        if x.is_empty() { x } else { format!("<w:rPr>{x}</w:rPr>") }
    }

    /// One run holding `content` (already `w:t`, `w:tab`, `w:br` elements) in the current formatting.
    fn run(&mut self, content: &str) {
        self.ensure_para();
        let rpr = self.rpr();
        if let Some(p) = self.open.as_mut() {
            let _ = write!(p.runs, "<w:r>{rpr}{content}</w:r>");
        }
    }

    fn text(&mut self, s: &str) {
        let mut content = String::new();
        let mut chunk = String::new();
        let flush = |content: &mut String, chunk: &mut String| {
            if !chunk.is_empty() {
                let _ = write!(content, "<w:t xml:space=\"preserve\">{}</w:t>", escape(chunk));
                chunk.clear();
            }
        };
        for c in s.chars() {
            match c {
                '\t' => {
                    flush(&mut content, &mut chunk);
                    content.push_str("<w:tab/>");
                }
                '\n' => {
                    flush(&mut content, &mut chunk);
                    content.push_str("<w:br/>");
                }
                '\r' => {}
                c => chunk.push(c),
            }
        }
        flush(&mut content, &mut chunk);
        if !content.is_empty() {
            self.run(&content);
        }
    }

    /// Opens a hyperlink to `url`; false (and nothing opened) for an address within the page, which has nothing to
    /// point at in a file.
    fn begin_link(&mut self, url: &str) -> bool {
        if url.is_empty() || url.starts_with('#') {
            return false;
        }
        self.ensure_para();
        let id = self.res.hyperlink(url);
        if let Some(p) = self.open.as_mut() {
            let _ = write!(p.runs, "<w:hyperlink r:id=\"{id}\" w:history=\"1\">");
        }
        self.fmt.link += 1;
        true
    }

    fn end_link(&mut self) {
        self.fmt.link = self.fmt.link.saturating_sub(1);
        if let Some(p) = self.open.as_mut() {
            p.runs.push_str("</w:hyperlink>");
        }
    }

    // ----- pictures ----------------------------------------------------------------------------------------

    /// The room a picture has here, in twips.
    fn available_width(&self) -> i64 {
        if let (Some(t), Some(Frame::Cell { .. })) = (&self.table, self.frames.last()) {
            return (t.col_width - 216).max(720);
        }
        let item = self.frames.iter().rev().find_map(|f| match f {
            Frame::Item { level, .. } => Some(level_indent(*level).0),
            _ => None,
        });
        (self.text_width - item.unwrap_or(0) - 360 * self.quote_depth()).max(720)
    }

    /// A picture as an inline drawing, or `false` when its bytes were not given (or are not a format Word reads).
    fn picture(&mut self, dest: &str, alt: &str) -> bool {
        let opts = self.look.opts;
        let Some(data): Option<&ImageData> = opts.image_data.iter().find(|d| d.destination == dest && !d.bytes.is_empty()) else {
            return false;
        };
        let Some(ext) = media::extension(&data.mime, &data.bytes) else { return false };
        // Points: the size the shell gave, else the picture's own pixels (at 96 to the inch).
        let given = opts.image_sizes.iter().find(|s| s.destination == dest && s.width > 0 && s.height > 0).map(|s| (f64::from(s.width), f64::from(s.height)));
        let (w_pt, h_pt) = given
            .or_else(|| media::dimensions(&data.bytes).filter(|d| d.0 > 0 && d.1 > 0).map(|(w, h)| (f64::from(w) * 0.75, f64::from(h) * 0.75)))
            .unwrap_or((288.0, 216.0));
        let (mut cx, mut cy) = ((w_pt * 12700.0).round() as i64, (h_pt * 12700.0).round() as i64);
        // The text column in EMU (635 to the twip): a wider picture is scaled down to it.
        let max = self.available_width() * 635;
        if cx > max {
            cy = (cy as f64 * max as f64 / cx as f64).round() as i64;
            cx = max;
        }
        let (cx, cy) = (cx.max(12700), cy.max(12700));
        let rid = self.res.picture(dest, ext, &data.bytes);
        self.drawing_id += 1;
        let id = self.drawing_id;
        let descr = escape(alt);
        let drawing = format!(
            "<w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"{cx}\" cy=\"{cy}\"/>\
<wp:docPr id=\"{id}\" name=\"Picture {id}\" descr=\"{descr}\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>\
<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>\
<pic:nvPicPr><pic:cNvPr id=\"{id}\" name=\"Picture {id}\" descr=\"{descr}\"/><pic:cNvPicPr/></pic:nvPicPr>\
<pic:blipFill><a:blip r:embed=\"{rid}\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{cx}\" cy=\"{cy}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>\
</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>"
        );
        self.run(&drawing);
        true
    }

    /// The text of the inline events `from..to`, as a picture's alternative text.
    fn alt_text(&self, from: usize, to: usize) -> String {
        let mut s = String::new();
        for (ev, _) in &self.tree.events[from..to] {
            match ev {
                Event::Text(t) | Event::Code(t) | Event::InlineMath(t) | Event::DisplayMath(t) => s.push_str(t),
                Event::SoftBreak | Event::HardBreak => s.push(' '),
                _ => {}
            }
        }
        s
    }

    // ----- the walk ----------------------------------------------------------------------------------------

    fn walk(&mut self, from: usize, to: usize) {
        let tree = self.tree;
        let mut i = from;
        while i < to {
            let end = tree.end_of[i];
            match &tree.events[i].0 {
                Event::Text(_) => {
                    let (pieces, next) = tree.text_run(i, to, self.fmt.link > 0);
                    for piece in pieces {
                        match piece {
                            Piece::Text(t) => self.text(&t),
                            Piece::Url { label, destination } => {
                                let linked = self.begin_link(&destination);
                                self.text(&label);
                                if linked {
                                    self.end_link();
                                }
                            }
                        }
                    }
                    i = next;
                    continue;
                }
                Event::Code(t) => {
                    self.fmt.code += 1;
                    self.text(t);
                    self.fmt.code -= 1;
                }
                // Math has no Word form here: it is written as its text.
                Event::InlineMath(t) | Event::DisplayMath(t) => self.text(t),
                Event::SoftBreak => self.text(" "),
                Event::HardBreak => self.run("<w:br/>"),
                Event::Html(_) | Event::InlineHtml(_) => {}
                Event::FootnoteReference(name) => self.footnote_reference(name),
                Event::Rule => {
                    self.before_block();
                    self.out.push_str("<w:p><w:pPr><w:pStyle w:val=\"HorizontalRule\"/></w:pPr></w:p>");
                }
                Event::TaskListMarker(checked) => {
                    if let Some(Frame::Item { task, .. }) = self.frames.iter_mut().rev().find(|f| matches!(f, Frame::Item { .. })) {
                        *task = Some(*checked);
                    }
                }
                Event::Start(tag) => {
                    // A block ends the paragraph that the text before it was in.
                    if !tree.is_inline(i) {
                        self.close_para();
                    }
                    if let Some(next) = self.start(tag, i, end) {
                        i = next;
                        continue;
                    }
                }
                Event::End(tag) => self.end(*tag),
            }
            i += 1;
        }
        self.close_para();
    }

    fn footnote_reference(&mut self, name: &str) {
        if self.notes.defs.contains_key(name) && !self.in_footnote && self.referenced.insert(name.to_owned()) {
            let n = self.notes.number(name);
            self.ensure_para();
            if let Some(p) = self.open.as_mut() {
                let _ = write!(p.runs, "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"{n}\"/></w:r>");
            }
            return;
        }
        // Word cannot refer to one note twice, nor from inside a note: the number is written in the text instead.
        let n = self.notes.order.iter().position(|x| x == name).map_or_else(|| name.to_owned(), |p| (p + 1).to_string());
        self.fmt.sup += 1;
        self.text(&n);
        self.fmt.sup -= 1;
    }

    /// Handles a start event. Returns the index to go on from when it took its whole content with it.
    fn start(&mut self, tag: &Tag<'a>, i: usize, end: usize) -> Option<usize> {
        let tree = self.tree;
        match tag {
            Tag::Paragraph => self.open_para(Kind::Auto),
            Tag::Heading { level, .. } => {
                self.before_block();
                self.open_para(Kind::Heading(*level as u8));
            }
            Tag::BlockQuote(_) => self.frames.push(Frame::Quote),
            Tag::CodeBlock(_) => {
                self.before_block();
                let mut code = String::new();
                for (e, _) in &tree.events[i + 1..end] {
                    if let Event::Text(t) = e {
                        code.push_str(t);
                    }
                }
                self.open_para(Kind::Code);
                self.text(code.strip_suffix('\n').unwrap_or(&code));
                self.close_para();
                return Some(end + 1);
            }
            Tag::List(start) => {
                self.before_block();
                let level = self.frames.iter().filter(|f| matches!(f, Frame::List { .. })).count().min(5);
                let num_id = match start {
                    Some(first) => self.numbering.numbered(level, *first),
                    None => self.numbering.bullet_id(),
                };
                self.frames.push(Frame::List { num_id, level });
            }
            Tag::Item => {
                if let Some(&Frame::List { num_id, level }) = self.frames.iter().rev().find(|f| matches!(f, Frame::List { .. })) {
                    self.frames.push(Frame::Item { num_id, level, pending: true, task: None });
                }
            }
            Tag::Table(aligns) => {
                self.before_block();
                self.start_table(aligns);
            }
            Tag::TableHead => {
                if let Some(t) = self.table.as_mut() {
                    t.head = true;
                    t.col = 0;
                }
                self.out.push_str("<w:tr><w:trPr><w:cantSplit/><w:tblHeader/></w:trPr>");
            }
            Tag::TableRow => {
                if let Some(t) = self.table.as_mut() {
                    t.col = 0;
                }
                self.out.push_str("<w:tr><w:trPr><w:cantSplit/></w:trPr>");
            }
            Tag::TableCell => self.start_cell(),
            Tag::Emphasis => self.fmt.italic += 1,
            Tag::Strong => self.fmt.bold += 1,
            Tag::Strikethrough => self.fmt.strike += 1,
            Tag::Superscript => self.fmt.sup += 1,
            Tag::Subscript => self.fmt.sub += 1,
            Tag::Link { link_type, dest_url, .. } => {
                let url = if *link_type == LinkType::Email { format!("mailto:{dest_url}") } else { dest_url.to_string() };
                let opened = self.begin_link(&url);
                self.links.push(opened);
            }
            Tag::Image { dest_url, .. } => {
                let alt = self.alt_text(i + 1, end);
                if !self.picture(dest_url, &alt) {
                    self.text(&alt);
                }
                return Some(end + 1);
            }
            // Raw HTML, front matter and the notes (written where they are referred to) are not part of the body.
            Tag::HtmlBlock | Tag::MetadataBlock(_) | Tag::FootnoteDefinition(_) => return Some(end + 1),
            Tag::DefinitionList | Tag::DefinitionListTitle | Tag::DefinitionListDefinition => {}
        }
        None
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph | TagEnd::Heading(_) => self.close_para(),
            TagEnd::BlockQuote(_) | TagEnd::List(_) | TagEnd::Item => {
                self.close_para();
                self.frames.pop();
            }
            TagEnd::Table => {
                self.out.push_str("</w:tbl>");
                self.table = None;
            }
            TagEnd::TableHead => {
                self.out.push_str("</w:tr>");
                if let Some(t) = self.table.as_mut() {
                    t.head = false;
                }
            }
            TagEnd::TableRow => self.out.push_str("</w:tr>"),
            TagEnd::TableCell => self.end_cell(),
            TagEnd::Emphasis => self.fmt.italic = self.fmt.italic.saturating_sub(1),
            TagEnd::Strong => self.fmt.bold = self.fmt.bold.saturating_sub(1),
            TagEnd::Strikethrough => self.fmt.strike = self.fmt.strike.saturating_sub(1),
            TagEnd::Superscript => self.fmt.sup = self.fmt.sup.saturating_sub(1),
            TagEnd::Subscript => self.fmt.sub = self.fmt.sub.saturating_sub(1),
            TagEnd::Link => {
                let opened = self.links.pop() == Some(true);
                if opened {
                    self.end_link();
                }
            }
            _ => {}
        }
    }

    // ----- tables ------------------------------------------------------------------------------------------

    fn start_table(&mut self, aligns: &[Alignment]) {
        let cols = aligns.len().max(1);
        let col_width = self.available_width() / cols as i64;
        let grid = self.look.theme_hex(ThemeColor::Border);
        let mut borders: Vec<(&str, String, i64)> = ["top", "left", "bottom", "right", "insideH", "insideV"].iter().map(|s| (*s, grid.clone(), 4)).collect();
        // The template's rule on one side of a table (Academic's heavy top line) replaces that side of the grid.
        if let Some(b) = self.look.element(ElementKind::Table).and_then(|e| e.border) {
            let (side, _, size, color, _) = self.look.border(b);
            if let Some(entry) = borders.iter_mut().find(|e| e.0 == side) {
                *entry = (entry.0, color, size);
            }
        }
        let _ = write!(self.out, "<w:tbl><w:tblPr><w:tblW w:w=\"{}\" w:type=\"dxa\"/><w:tblBorders>", col_width * cols as i64);
        for (side, color, size) in &borders {
            let _ = write!(self.out, "<w:{side} w:val=\"single\" w:sz=\"{size}\" w:space=\"0\" w:color=\"{color}\"/>");
        }
        self.out.push_str("</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblLook w:val=\"04A0\"/></w:tblPr><w:tblGrid>");
        for _ in 0..cols {
            let _ = write!(self.out, "<w:gridCol w:w=\"{col_width}\"/>");
        }
        self.out.push_str("</w:tblGrid>");
        self.table = Some(TableCtx { col_width, aligns: aligns.to_vec(), col: 0, head: false });
    }

    fn start_cell(&mut self) {
        let Some(t) = self.table.as_ref() else { return };
        let (head, width) = (t.head, t.col_width);
        let jc = match t.aligns.get(t.col) {
            Some(Alignment::Left) => Some("left"),
            Some(Alignment::Center) => Some("center"),
            Some(Alignment::Right) => Some("right"),
            _ => None,
        };
        let _ = write!(self.out, "<w:tc><w:tcPr><w:tcW w:w=\"{width}\" w:type=\"dxa\"/>");
        if head {
            let header = self.look.element(ElementKind::TableHeader);
            if let Some(b) = header.and_then(|e| e.border) {
                let (side, line, size, color, _) = self.look.border(b);
                let _ = write!(self.out, "<w:tcBorders><w:{side} w:val=\"{line}\" w:sz=\"{size}\" w:space=\"0\" w:color=\"{color}\"/></w:tcBorders>");
            }
            let fill = match header.and_then(|e| e.background) {
                Some(c) => self.look.color(c),
                None => self.look.theme_hex(ThemeColor::CodeBackground),
            };
            let _ = write!(self.out, "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"{fill}\"/>");
        }
        self.out.push_str("</w:tcPr>");
        self.cell_mark = self.out.len();
        self.frames.push(Frame::Cell { head, jc });
    }

    fn end_cell(&mut self) {
        self.close_para();
        // A cell with nothing in it still needs its paragraph.
        if self.out.len() == self.cell_mark {
            self.out.push_str("<w:p><w:pPr><w:pStyle w:val=\"TableCell\"/></w:pPr></w:p>");
        }
        self.out.push_str("</w:tc>");
        self.frames.pop();
        if let Some(t) = self.table.as_mut() {
            t.col += 1;
        }
    }
}
