//! HTML rendering for the preview, export and the clipboard.
//!
//! The same parser, with the same options, that feeds the editor's spans (`analysis::options`),
//! so the two cannot disagree about what a construct is. The writer follows pulldown-cmark's own
//! HTML writer (whitespace included, which is what lets the CommonMark spec examples compare
//! equal), with these differences:
//!
//! * bare `http://`, `https://` and `www.` URLs become links, found by [`crate::autolink`] over
//!   the same runs of plain text the analysis searches;
//! * headings get stable GitHub-style `id`s;
//! * footnotes are collected into a section at the end, numbered by first reference, with
//!   back-references;
//! * task list items get a disabled checkbox (and the class `task-list-item`);
//! * fenced code is highlighted ([`crate::highlight`]), class-based;
//! * with [`RenderOptions::source_lines`], block elements carry `data-line="N"`, the 0-based line
//!   their source starts on (for scroll sync);
//! * with [`RenderOptions::sanitize`], raw HTML is filtered ([`crate::sanitize`]);
//! * front matter is omitted.
//!
//! Raw HTML otherwise passes through verbatim. **A shell must show this HTML with page
//! JavaScript disabled** (the macOS shell sets `allowsContentJavaScript = false`; a WebKitGTK
//! shell sets `enable-javascript` to false): a document is not trusted. The sanitizer exists for
//! HTML that leaves the preview (the clipboard), not as the preview's defence.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::panic::{catch_unwind, AssertUnwindSafe};

use pulldown_cmark::{Alignment, CodeBlockKind, Event, LinkType, MetadataBlockKind, Parser, Tag, TagEnd};
use pulldown_cmark_escape::{escape_href, escape_html, escape_html_body_text};

use crate::analysis::options;
use crate::autolink;
use crate::document::Document;
use crate::highlight;
use crate::lines::LineIndex;
use crate::preview_css::{preview_css, PreviewStyle};
use crate::sanitize::{is_dangerous_url, HtmlFilter};
use crate::types::TextRange;

/// What to render and how. `Default` is the plain body, as the clipboard wants it.
#[derive(Debug, Clone)]
pub struct RenderOptions {
    /// Add `data-line="N"` (0-based first source line) to every block-level element.
    pub source_lines: bool,
    /// A complete HTML5 document (charset, viewport, title, inline stylesheet) instead of the body.
    pub standalone: bool,
    /// Filter raw HTML and `javascript:` URLs (for fragments that leave the preview).
    pub sanitize: bool,
    /// Highlight fenced code (class-based; see [`crate::highlight`]).
    pub highlight: bool,
    /// The `<title>` when the document has neither a front-matter `title` nor a heading.
    pub fallback_title: String,
    /// Theme and typography of the standalone document's stylesheet (`None`: Light, defaults).
    pub style: Option<PreviewStyle>,
}

impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            source_lines: false,
            standalone: false,
            sanitize: false,
            highlight: true,
            fallback_title: String::new(),
            style: None,
        }
    }
}

impl Document {
    /// The whole document as HTML: the body, or with [`RenderOptions::standalone`] a complete page.
    /// Front matter is omitted. See the module docs: show it with page JavaScript disabled.
    pub fn render_html(&self, options: &RenderOptions) -> String {
        render(self.text(), None, options)
    }

    /// The blocks that `range` touches, whole (the range is widened to the top-level blocks it
    /// overlaps: selecting a few words of a list item renders the whole list). An empty range
    /// renders the whole document. Heading ids, footnote numbers and link references are those
    /// of the full document; the footnotes section holds the footnotes the fragment refers to.
    pub fn render_html_fragment(&self, range: TextRange, options: &RenderOptions) -> String {
        if range.is_empty() {
            return render(self.text(), None, options);
        }
        let start = self.byte_snapped(range.start, false);
        let end = self.byte_snapped(range.end, true);
        render(self.text(), Some((start, end)), options)
    }
}

/// GitHub-style heading slug: lower case, letters and digits kept, spaces and hyphens become
/// hyphens, underscores kept, every other character dropped. (Uniqueness is the caller's.)
pub fn slug(text: &str) -> String {
    let mut s = String::with_capacity(text.len());
    for c in text.trim().chars() {
        if c.is_alphanumeric() {
            s.extend(c.to_lowercase());
        } else if c == ' ' || c == '-' {
            s.push('-');
        } else if c == '_' {
            s.push('_');
        }
    }
    s
}

fn render(text: &str, window: Option<(usize, usize)>, opts: &RenderOptions) -> String {
    // pulldown-cmark 0.13.4 can panic on some input (see analysis.rs): show the text, escaped.
    let parsed = catch_unwind(AssertUnwindSafe(|| Parser::new_ext(text, options()).into_offset_iter().collect::<Vec<_>>()));
    let (body, title) = match parsed {
        Ok(events) => {
            let mut r = Renderer::new(text, events, window, opts);
            let body = r.run();
            (body, r.title())
        }
        Err(_) => {
            let mut body = String::from("<pre class=\"unparsed\">");
            let _ = escape_html_body_text(&mut body, text);
            body.push_str("</pre>\n");
            (body, None)
        }
    };
    if !opts.standalone {
        return body;
    }
    let default_style;
    let style = match &opts.style {
        Some(s) => s,
        None => {
            default_style = PreviewStyle::default();
            &default_style
        }
    };
    let title = title.filter(|t| !t.trim().is_empty()).unwrap_or_else(|| opts.fallback_title.clone());
    let mut page = String::with_capacity(body.len() + 8192);
    page.push_str("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    page.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    let _ = escape_html_body_text(&mut page, &title);
    page.push_str("</title>\n<style>\n");
    page.push_str(&preview_css(&style.theme, &style.typography));
    page.push_str("</style>\n</head>\n<body>\n<main class=\"md\" id=\"md\">\n");
    page.push_str(&body);
    page.push_str("</main>\n</body>\n</html>\n");
    page
}

type Item<'a> = (Event<'a>, Range<usize>);

struct FootnoteDef {
    name: String,
    /// Event indices of the children (after the start, before the end).
    children: Range<usize>,
    line: usize,
    /// Its own block is inside the window (or there is none).
    touched: bool,
}

#[derive(Default)]
struct Table {
    alignments: Vec<Alignment>,
    in_head: bool,
    cell: usize,
}

struct Renderer<'a, 'o> {
    src: &'a str,
    lines: LineIndex,
    events: Vec<Item<'a>>,
    /// For a start event, the index of its end event.
    end_of: Vec<u32>,
    window: Option<(usize, usize)>,
    opts: &'o RenderOptions,
    out: String,
    end_newline: bool,
    table: Table,
    heading_ids: HashMap<usize, String>,
    /// Footnote name -> number (1-based, in order of first reference).
    numbers: HashMap<String, usize>,
    order: Vec<String>,
    ref_counts: HashMap<String, usize>,
    defs: Vec<FootnoteDef>,
    def_index: HashMap<String, usize>,
    /// Inside a link or an image: no bare-URL linking.
    link_depth: u32,
    filter: HtmlFilter,
    /// A task checkbox waiting for the paragraph that follows it.
    pending_task: Option<bool>,
}

impl<'a, 'o> Renderer<'a, 'o> {
    fn new(src: &'a str, events: Vec<Item<'a>>, window: Option<(usize, usize)>, opts: &'o RenderOptions) -> Self {
        let mut end_of = vec![0u32; events.len()];
        let mut stack: Vec<usize> = Vec::new();
        let mut defs = Vec::new();
        let mut def_index = HashMap::new();
        for (i, (ev, _)) in events.iter().enumerate() {
            match ev {
                Event::Start(_) => stack.push(i),
                Event::End(_) => {
                    if let Some(s) = stack.pop() {
                        end_of[s] = i as u32;
                    }
                }
                _ => {}
            }
        }
        let lines = LineIndex::new(src);
        for (i, (ev, r)) in events.iter().enumerate() {
            if let Event::Start(Tag::FootnoteDefinition(name)) = ev {
                // The first definition of a label wins, as in the parser.
                if let std::collections::hash_map::Entry::Vacant(e) = def_index.entry(name.to_string()) {
                    e.insert(defs.len());
                    defs.push(FootnoteDef {
                        name: name.to_string(),
                        children: i + 1..end_of[i] as usize,
                        line: lines.line_of(r.start),
                        touched: window.is_none_or(|(ws, we)| r.start < we && ws < r.end),
                    });
                }
            }
        }
        let mut r = Renderer {
            src,
            lines,
            events,
            end_of,
            window,
            opts,
            out: String::new(),
            end_newline: true,
            table: Table::default(),
            heading_ids: HashMap::new(),
            numbers: HashMap::new(),
            order: Vec::new(),
            ref_counts: HashMap::new(),
            defs,
            def_index,
            link_depth: 0,
            filter: HtmlFilter::default(),
            pending_task: None,
        };
        r.assign_heading_ids();
        r
    }

    fn assign_heading_ids(&mut self) {
        let mut used: HashSet<String> = HashSet::new();
        // The next suffix to try for a base: repeated headings do not rescan from 1 (a document of
        // thousands of identical headings would be quadratic).
        let mut next: HashMap<String, usize> = HashMap::new();
        for i in 0..self.events.len() {
            if matches!(self.events[i].0, Event::Start(Tag::Heading { .. })) {
                let text = self.plain_text(i + 1, self.end_of[i] as usize);
                let mut base = slug(&text);
                if base.is_empty() {
                    base = "section".to_owned();
                }
                let mut id = base.clone();
                if !used.insert(id.clone()) {
                    let n = next.entry(base.clone()).or_insert(1);
                    loop {
                        id = format!("{base}-{n}");
                        *n += 1;
                        if used.insert(id.clone()) {
                            break;
                        }
                    }
                }
                self.heading_ids.insert(i, id);
            }
        }
    }

    /// The text of events `from..to`: what a reader would read, no markup.
    fn plain_text(&self, from: usize, to: usize) -> String {
        let mut s = String::new();
        for (ev, _) in &self.events[from..to] {
            match ev {
                Event::Text(t) | Event::Code(t) => s.push_str(t),
                Event::SoftBreak | Event::HardBreak => s.push(' '),
                _ => {}
            }
        }
        s
    }

    /// Front-matter `title:`, else the first heading's text.
    fn title(&self) -> Option<String> {
        for (i, (ev, _)) in self.events.iter().enumerate() {
            if let Event::Start(Tag::MetadataBlock(MetadataBlockKind::YamlStyle)) = ev {
                let body = self.plain_text(i + 1, self.end_of[i] as usize);
                for line in body.lines() {
                    if let Some(v) = line.strip_prefix("title:") {
                        let v = v.trim().trim_matches(|c| c == '"' || c == '\'').trim();
                        if !v.is_empty() {
                            return Some(v.to_owned());
                        }
                    }
                }
            }
        }
        let i = self.events.iter().position(|(e, _)| matches!(e, Event::Start(Tag::Heading { .. })))?;
        Some(self.plain_text(i + 1, self.end_of[i] as usize))
    }

    // ----- output helpers ----------------------------------------------------------------------

    fn write(&mut self, s: &str) {
        self.out.push_str(s);
        if !s.is_empty() {
            self.end_newline = s.ends_with('\n');
        }
    }

    fn newline(&mut self) {
        self.out.push('\n');
        self.end_newline = true;
    }

    fn text(&mut self, s: &str) {
        let _ = escape_html_body_text(&mut self.out, s);
        if !s.is_empty() {
            self.end_newline = s.ends_with('\n');
        }
    }

    fn attr(&mut self, s: &str) {
        let _ = escape_html(&mut self.out, s);
    }

    fn href(&mut self, s: &str) {
        let _ = escape_href(&mut self.out, s);
    }

    /// ` data-line="N"` for a block starting at byte `start` (empty unless requested).
    fn line_attr(&self, start: usize) -> String {
        if self.opts.source_lines { format!(" data-line=\"{}\"", self.lines.line_of(start.min(self.src.len()))) } else { String::new() }
    }

    /// `<tag attrs data-line>` after a newline if the last write did not end one.
    fn open_block(&mut self, tag: &str, attrs: &str, start: usize, tail: &str) {
        if !self.end_newline {
            self.out.push('\n');
        }
        let line = self.line_attr(start);
        self.out.push('<');
        self.out.push_str(tag);
        self.out.push_str(attrs);
        self.out.push_str(&line);
        self.out.push('>');
        self.write_tail(tail);
    }

    fn write_tail(&mut self, tail: &str) {
        self.out.push_str(tail);
        self.end_newline = tail.ends_with('\n');
    }

    fn selected(&self, r: &Range<usize>) -> bool {
        self.window.is_none_or(|(ws, we)| r.start < we && ws < r.end)
    }

    // ----- the document ------------------------------------------------------------------------

    fn run(&mut self) -> String {
        let mut i = 0;
        let n = self.events.len();
        while i < n {
            let r = self.events[i].1.clone();
            match &self.events[i].0 {
                Event::Start(_) => {
                    let end = self.end_of[i] as usize;
                    if self.selected(&r) {
                        self.render_range(i, end + 1);
                    }
                    i = end + 1;
                }
                _ => {
                    if self.selected(&r) {
                        self.render_range(i, i + 1);
                    }
                    i += 1;
                }
            }
        }
        self.footnotes();
        std::mem::take(&mut self.out)
    }

    fn footnotes(&mut self) {
        if self.defs.is_empty() {
            return;
        }
        let mut items = String::new();
        let mut k = 0;
        let mut added_unreferenced = false;
        loop {
            if k == self.order.len() {
                if added_unreferenced {
                    break;
                }
                added_unreferenced = true;
                let extra: Vec<String> = self
                    .defs
                    .iter()
                    .filter(|d| d.touched && !self.numbers.contains_key(&d.name))
                    .map(|d| d.name.clone())
                    .collect();
                for name in extra {
                    self.number_of(&name);
                }
                if k == self.order.len() {
                    break;
                }
            }
            let name = self.order[k].clone();
            k += 1;
            let Some(&di) = self.def_index.get(&name) else { continue };
            let (children, line) = (self.defs[di].children.clone(), self.defs[di].line);
            let saved = std::mem::take(&mut self.out);
            let saved_nl = std::mem::replace(&mut self.end_newline, true);
            self.render_range(children.start, children.end);
            let mut body = std::mem::replace(&mut self.out, saved);
            self.end_newline = saved_nl;
            // The back-references go at the end of the last paragraph.
            let mut backrefs = String::new();
            let count = self.ref_counts.get(&name).copied().unwrap_or(1).max(1);
            for c in 1..=count {
                let mut id = String::new();
                self.footnote_ref_id(&mut id, &name, c);
                backrefs.push_str(" <a href=\"#");
                let _ = escape_href(&mut backrefs, &id);
                backrefs.push_str("\" class=\"footnote-backref\" aria-label=\"Back to reference\">\u{21a9}");
                if c > 1 {
                    backrefs.push_str(&format!("<sup>{c}</sup>"));
                }
                backrefs.push_str("</a>");
            }
            if body.ends_with("</p>\n") {
                body.insert_str(body.len() - 5, &backrefs);
            } else {
                body.push_str(&format!("<p>{}</p>\n", backrefs.trim_start()));
            }
            items.push_str("<li id=\"fn-");
            let _ = escape_html(&mut items, &name);
            items.push('"');
            if self.opts.source_lines {
                items.push_str(&format!(" data-line=\"{line}\""));
            }
            items.push_str(">\n");
            items.push_str(&body);
            items.push_str("</li>\n");
        }
        if items.is_empty() {
            return;
        }
        self.write("<section class=\"footnotes\">\n<ol>\n");
        self.out.push_str(&items);
        self.write("</ol>\n</section>\n");
    }

    fn number_of(&mut self, name: &str) -> usize {
        if let Some(&n) = self.numbers.get(name) {
            return n;
        }
        let n = self.order.len() + 1;
        self.numbers.insert(name.to_owned(), n);
        self.order.push(name.to_owned());
        n
    }

    /// `fnref-NAME` for the first reference, `fnref-NAME-2`... after it.
    fn footnote_ref_id(&self, out: &mut String, name: &str, k: usize) {
        out.push_str("fnref-");
        out.push_str(name);
        if k > 1 {
            out.push_str(&format!("-{k}"));
        }
    }

    // ----- events ------------------------------------------------------------------------------

    fn render_range(&mut self, from: usize, to: usize) {
        let mut i = from;
        while i < to {
            let end = self.end_of[i] as usize;
            let (ev, range) = (&self.events[i].0, self.events[i].1.clone());
            match ev {
                Event::Start(Tag::MetadataBlock(_)) | Event::Start(Tag::FootnoteDefinition(_)) => {
                    i = end + 1;
                }
                Event::Start(Tag::HtmlBlock) if self.opts.sanitize => {
                    let mut raw = String::new();
                    for (e, _) in &self.events[i + 1..end] {
                        if let Event::Html(h) = e {
                            raw.push_str(h);
                        }
                    }
                    let clean = self.filter.filter(&raw);
                    self.filter.reset();
                    self.write(&clean);
                    i = end + 1;
                }
                Event::Start(Tag::CodeBlock(kind)) => {
                    let info = match kind {
                        CodeBlockKind::Fenced(info) => info.to_string(),
                        CodeBlockKind::Indented => String::new(),
                    };
                    let mut code = String::new();
                    for (e, _) in &self.events[i + 1..end] {
                        if let Event::Text(t) = e {
                            code.push_str(t);
                        }
                    }
                    self.code_block(&info, &code, range.start);
                    i = end + 1;
                }
                Event::Start(Tag::Image { dest_url, title, .. }) => {
                    let (dest, title) = (dest_url.to_string(), title.to_string());
                    self.image(&dest, &title, i + 1, end);
                    i = end + 1;
                }
                Event::Start(tag) => {
                    let tag = tag.clone();
                    self.start_tag(tag, i, &range);
                    i += 1;
                }
                Event::End(tag) => {
                    let tag = *tag;
                    self.end_tag(tag);
                    i += 1;
                }
                Event::Text(_) => {
                    i = self.text_run(i, to);
                }
                Event::Code(t) => {
                    if !self.filter.is_skipping() {
                        let t = t.clone();
                        self.write("<code>");
                        self.text(&t);
                        self.write("</code>");
                    }
                    i += 1;
                }
                Event::InlineMath(t) | Event::DisplayMath(t) => {
                    let t = t.clone();
                    let display = matches!(self.events[i].0, Event::DisplayMath(_));
                    self.write(if display { "<span class=\"math math-display\">" } else { "<span class=\"math math-inline\">" });
                    self.attr(&t);
                    self.write("</span>");
                    i += 1;
                }
                Event::Html(h) | Event::InlineHtml(h) => {
                    let h = h.clone();
                    if self.opts.sanitize {
                        let clean = self.filter.filter(&h);
                        self.write(&clean);
                    } else {
                        self.write(&h);
                    }
                    i += 1;
                }
                Event::SoftBreak => {
                    if !self.filter.is_skipping() {
                        self.newline();
                    }
                    i += 1;
                }
                Event::HardBreak => {
                    if !self.filter.is_skipping() {
                        self.write("<br />\n");
                    }
                    i += 1;
                }
                Event::Rule => {
                    if !self.end_newline {
                        self.out.push('\n');
                    }
                    let line = self.line_attr(range.start);
                    self.out.push_str(&format!("<hr{line} />\n"));
                    self.end_newline = true;
                    i += 1;
                }
                Event::FootnoteReference(name) => {
                    let name = name.to_string();
                    let n = self.number_of(&name);
                    let count = self.ref_counts.entry(name.clone()).or_insert(0);
                    *count += 1;
                    let count = *count;
                    let mut id = String::new();
                    self.footnote_ref_id(&mut id, &name, count);
                    self.write("<sup class=\"footnote-ref\" id=\"");
                    self.attr(&id);
                    self.write("\"><a href=\"#fn-");
                    self.href(&name);
                    self.write(&format!("\">{n}</a></sup>"));
                    i += 1;
                }
                Event::TaskListMarker(checked) => {
                    let checked = *checked;
                    let next_is_paragraph = matches!(self.events.get(i + 1), Some((Event::Start(Tag::Paragraph), _)));
                    if next_is_paragraph {
                        self.pending_task = Some(checked);
                    } else {
                        self.checkbox(checked);
                    }
                    i += 1;
                }
            }
        }
    }

    fn checkbox(&mut self, checked: bool) {
        self.write(if checked { "<input disabled=\"\" type=\"checkbox\" checked=\"\" /> " } else { "<input disabled=\"\" type=\"checkbox\" /> " });
        self.end_newline = false;
    }

    /// A run of plain text starting at event `i`: bare URLs inside it become links. Returns the
    /// index after the run.
    fn text_run(&mut self, i: usize, to: usize) -> usize {
        let mut j = i;
        let one_to_one = |this: &Self, k: usize| -> bool {
            matches!(&this.events[k], (Event::Text(t), r) if this.src.get(r.clone()) == Some(&**t))
        };
        if self.filter.is_skipping() {
            while j < to && matches!(self.events[j].0, Event::Text(_)) {
                j += 1;
            }
            return j.max(i + 1);
        }
        if self.link_depth > 0 || !one_to_one(self, i) {
            let Event::Text(t) = &self.events[i].0 else { return i + 1 };
            let t = t.clone();
            self.text(&t);
            return i + 1;
        }
        // Contiguous in the source and equal to it: searched as one piece, as the analysis does.
        j = i + 1;
        while j < to && one_to_one(self, j) && self.events[j].1.start == self.events[j - 1].1.end {
            j += 1;
        }
        let (s, e) = (self.events[i].1.start, self.events[j - 1].1.end);
        let links = autolink::find_in(self.src, s, e);
        let mut pos = s;
        for l in links {
            let before = &self.src[pos..l.start];
            self.text(before);
            self.write("<a href=\"");
            self.href(&l.destination);
            self.write("\">");
            let label = &self.src[l.start..l.end];
            self.text(label);
            self.write("</a>");
            pos = l.end;
        }
        let rest = &self.src[pos..e];
        self.text(rest);
        j
    }

    fn code_block(&mut self, info: &str, code: &str, start: usize) {
        if !self.end_newline {
            self.newline();
        }
        let lang = info.split(' ').next().unwrap_or("");
        let line = self.line_attr(start);
        self.out.push_str(&format!("<pre{line}><code"));
        if !lang.is_empty() {
            self.out.push_str(" class=\"language-");
            self.attr(lang);
            self.out.push('"');
        }
        self.out.push('>');
        match self.opts.highlight.then(|| highlight::highlight(info, code)).flatten() {
            Some(html) => self.out.push_str(&html),
            None => {
                let _ = escape_html_body_text(&mut self.out, code);
            }
        }
        self.write("</code></pre>\n");
    }

    fn image(&mut self, dest: &str, title: &str, from: usize, end: usize) {
        self.write("<img src=\"");
        if !(self.opts.sanitize && is_dangerous_url(dest)) {
            self.href(dest);
        }
        self.write("\" alt=\"");
        // The alt text is the content as plain text.
        for k in from..end {
            let (ev, _) = &self.events[k];
            match ev {
                Event::InlineHtml(t) | Event::Code(t) | Event::Text(t) => {
                    let t = t.clone();
                    self.attr(&t);
                }
                Event::InlineMath(t) => {
                    let t = format!("${t}$");
                    self.attr(&t);
                }
                Event::DisplayMath(t) => {
                    let t = format!("$${t}$$");
                    self.attr(&t);
                }
                Event::SoftBreak | Event::HardBreak | Event::Rule => self.out.push(' '),
                Event::FootnoteReference(name) => {
                    let n = self.numbers.get(&name.to_string()).copied().unwrap_or(self.order.len() + 1);
                    self.out.push_str(&format!("[{n}]"));
                }
                Event::TaskListMarker(c) => self.out.push_str(if *c { "[x]" } else { "[ ]" }),
                _ => {}
            }
        }
        if !title.is_empty() {
            self.write("\" title=\"");
            self.attr(title);
        }
        self.write("\" />");
    }

    fn start_tag(&mut self, tag: Tag<'a>, index: usize, range: &Range<usize>) {
        match tag {
            Tag::HtmlBlock => {}
            Tag::Paragraph => {
                self.open_block("p", "", range.start, "");
                if let Some(c) = self.pending_task.take() {
                    self.checkbox(c);
                }
            }
            Tag::Heading { level, .. } => {
                let id = self.heading_ids.get(&index).cloned().unwrap_or_default();
                let attrs = if id.is_empty() {
                    String::new()
                } else {
                    let mut a = String::from(" id=\"");
                    let _ = escape_html(&mut a, &id);
                    a.push('"');
                    a
                };
                self.open_block(&level.to_string(), &attrs, range.start, "");
            }
            Tag::Table(alignments) => {
                self.table = Table { alignments, in_head: true, cell: 0 };
                self.open_block("table", "", range.start, "");
            }
            Tag::TableHead => {
                self.table.in_head = true;
                self.table.cell = 0;
                self.write("<thead>");
                let line = self.line_attr(range.start);
                self.write(&format!("<tr{line}>"));
            }
            Tag::TableRow => {
                self.table.cell = 0;
                let line = self.line_attr(range.start);
                self.write(&format!("<tr{line}>"));
            }
            Tag::TableCell => {
                self.write(if self.table.in_head { "<th" } else { "<td" });
                match self.table.alignments.get(self.table.cell) {
                    Some(Alignment::Left) => self.write(" style=\"text-align: left\">"),
                    Some(Alignment::Center) => self.write(" style=\"text-align: center\">"),
                    Some(Alignment::Right) => self.write(" style=\"text-align: right\">"),
                    _ => self.write(">"),
                }
            }
            Tag::BlockQuote(_) => self.open_block("blockquote", "", range.start, "\n"),
            Tag::CodeBlock(_) | Tag::Image { .. } | Tag::MetadataBlock(_) | Tag::FootnoteDefinition(_) => {}
            Tag::List(Some(1)) => self.open_plain("ol", ""),
            Tag::List(Some(start)) => self.open_plain("ol", &format!(" start=\"{start}\"")),
            Tag::List(None) => self.open_plain("ul", ""),
            Tag::Item => {
                let task = matches!(self.events.get(index + 1), Some((Event::TaskListMarker(_), _)));
                self.open_block("li", if task { " class=\"task-list-item\"" } else { "" }, range.start, "");
            }
            Tag::DefinitionList => self.open_plain("dl", ""),
            Tag::DefinitionListTitle => self.open_block("dt", "", range.start, ""),
            Tag::DefinitionListDefinition => self.open_block("dd", "", range.start, ""),
            Tag::Subscript => self.write("<sub>"),
            Tag::Superscript => self.write("<sup>"),
            Tag::Emphasis => self.write("<em>"),
            Tag::Strong => self.write("<strong>"),
            Tag::Strikethrough => self.write("<del>"),
            Tag::Link { link_type, dest_url, title, .. } => {
                self.link_depth += 1;
                self.write("<a");
                let dangerous = self.opts.sanitize && is_dangerous_url(&dest_url);
                if !dangerous {
                    self.write(" href=\"");
                    if link_type == LinkType::Email {
                        self.write("mailto:");
                    }
                    self.href(&dest_url);
                    self.write("\"");
                }
                if !title.is_empty() {
                    self.write(" title=\"");
                    self.attr(&title);
                    self.write("\"");
                }
                self.write(">");
            }
        }
    }

    /// `<tag attrs>\n` (lists, definition lists).
    fn open_plain(&mut self, tag: &str, attrs: &str) {
        if !self.end_newline {
            self.out.push('\n');
        }
        self.out.push_str(&format!("<{tag}{attrs}>\n"));
        self.end_newline = true;
    }

    fn end_tag(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::HtmlBlock | TagEnd::Image | TagEnd::MetadataBlock(_) | TagEnd::FootnoteDefinition | TagEnd::CodeBlock => {}
            TagEnd::Paragraph => {
                self.filter.reset();
                self.write("</p>\n");
            }
            TagEnd::Heading(level) => {
                self.filter.reset();
                self.write(&format!("</{level}>\n"));
            }
            TagEnd::Table => self.write("</tbody></table>\n"),
            TagEnd::TableHead => {
                self.write("</tr></thead><tbody>\n");
                self.table.in_head = false;
            }
            TagEnd::TableRow => self.write("</tr>\n"),
            TagEnd::TableCell => {
                self.filter.reset();
                self.write(if self.table.in_head { "</th>" } else { "</td>" });
                self.table.cell += 1;
            }
            TagEnd::BlockQuote(_) => self.write("</blockquote>\n"),
            TagEnd::List(true) => self.write("</ol>\n"),
            TagEnd::List(false) => self.write("</ul>\n"),
            TagEnd::Item => {
                self.filter.reset();
                self.pending_task = None;
                self.write("</li>\n");
            }
            TagEnd::DefinitionList => self.write("</dl>\n"),
            TagEnd::DefinitionListTitle => self.write("</dt>\n"),
            TagEnd::DefinitionListDefinition => self.write("</dd>\n"),
            TagEnd::Emphasis => self.write("</em>"),
            TagEnd::Superscript => self.write("</sup>"),
            TagEnd::Subscript => self.write("</sub>"),
            TagEnd::Strong => self.write("</strong>"),
            TagEnd::Strikethrough => self.write("</del>"),
            TagEnd::Link => {
                self.link_depth = self.link_depth.saturating_sub(1);
                self.write("</a>");
            }
        }
    }
}
