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
use std::time::{Duration, Instant};

use pulldown_cmark::{Alignment, CodeBlockKind, Event, LinkType, MetadataBlockKind, Parser, Tag, TagEnd};
use pulldown_cmark_escape::{escape_href, escape_html, escape_html_body_text};

use crate::analysis::options;
use crate::autolink;
use crate::document::Document;
use crate::highlight;
use crate::lines::LineIndex;
use crate::preview_css::{preview_css, PreviewStyle};
use crate::sanitize::{is_safe_url, HtmlFilter};
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
    page.push_str(CONTENT_SECURITY_POLICY);
    page.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    let _ = escape_html_body_text(&mut page, &title);
    page.push_str("</title>\n<style>\n");
    page.push_str(&preview_css(&style.theme, &style.typography));
    page.push_str("</style>\n</head>\n<body>\n<main class=\"md\" id=\"md\">\n");
    page.push_str(&body);
    page.push_str("</main>\n</body>\n</html>\n");
    page
}

/// The standalone page's policy, in its head before anything a document can write (a later
/// policy can only narrow it). Page JavaScript is off in every shell; this is the second wall:
/// no script, frame, plugin, form submission or `<base>`; fonts and stylesheets only from the
/// page's own origin (the shell's scheme, which serves the document's folder and the bundled
/// fonts) or inline; pictures and media from there, `http(s):` and `data:`. So a document's raw
/// HTML cannot embed a local file in a frame, load a web font that reports which characters a
/// page holds, or post a form anywhere.
pub const CONTENT_SECURITY_POLICY: &str = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'self' https: http: data:; media-src 'self' https: http:; style-src 'self' 'unsafe-inline'; font-src 'self'; frame-src 'none'; child-src 'none'; form-action 'none'; base-uri 'none'\">\n";

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
    /// Footnote name -> number (1-based, in order of first reference in the whole document, as
    /// a reader meets them: the text first, then the notes in the order they are listed).
    numbers: HashMap<String, usize>,
    /// For a footnote reference's event index: which reference to its note it is (1-based), in
    /// the same order. Fragments use the whole document's numbers and ids.
    ref_occurrence: HashMap<usize, usize>,
    /// The footnotes referred to inside each note (for a fragment's section).
    refs_in_def: HashMap<String, Vec<String>>,
    /// References written to the output so far: note name -> which occurrences.
    rendered_refs: HashMap<String, Vec<usize>>,
    defs: Vec<FootnoteDef>,
    def_index: HashMap<String, usize>,
    /// Inside a link or an image: no bare-URL linking.
    link_depth: u32,
    filter: HtmlFilter,
    /// A task checkbox waiting for the paragraph that follows it.
    pending_task: Option<bool>,
    /// Bytes of fenced code highlighted so far; past [`HIGHLIGHT_BUDGET_BYTES`] the rest is plain.
    highlighted_bytes: usize,
    /// Code blocks shown plain because the budget ran out.
    pub(crate) unhighlighted_blocks: usize,
    /// When this render's highlighting must stop (set at the first highlighted block).
    highlight_deadline: Option<Instant>,
}

/// Fenced code highlighted per render, in bytes (a line counts extra, see `highlight::cost`).
/// Ordinary code highlights at roughly 1 MB/s with a cold cache, so this bounds a render of a
/// document full of code to some tens of milliseconds; the blocks after it are shown plain and
/// marked `data-highlight="skipped"`. It counts bytes, not time, so the same text renders the
/// same way on every machine and whether or not its blocks are cached.
pub const HIGHLIGHT_BUDGET_BYTES: usize = 128 * 1024;

/// And a cap in time, for the languages and shapes of code that highlight ten times slower than
/// that (LaTeX, long minified lines): highlighting stops for the rest of the render once this much
/// time has gone into it. Only a pathological document reaches it, and only then does its output
/// depend on the machine and on what is cached (a block answered from the cache costs nothing,
/// so later renders highlight further).
pub const HIGHLIGHT_BUDGET_TIME: Duration = Duration::from_millis(40);

/// The code always highlighted, time or not (in the units of [`HIGHLIGHT_BUDGET_BYTES`]): about
/// 150 lines. The slowest language measured (LaTeX) takes some 30 ms for it in a release build.
pub const HIGHLIGHT_FLOOR_BYTES: usize = 12 * 1024;

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
            ref_occurrence: HashMap::new(),
            refs_in_def: HashMap::new(),
            rendered_refs: HashMap::new(),
            defs,
            def_index,
            link_depth: 0,
            filter: HtmlFilter::default(),
            pending_task: None,
            highlighted_bytes: 0,
            unhighlighted_blocks: 0,
            highlight_deadline: None,
        };
        r.number_footnotes();
        r.assign_heading_ids();
        r
    }

    /// Numbers every footnote and every reference to one over the whole document, in the order
    /// the full render meets them: references in the text, then in each note as the notes are
    /// listed (by number), then the notes nobody refers to, in document order.
    fn number_footnotes(&mut self) {
        let mut order: Vec<String> = Vec::new();
        let mut counts: HashMap<String, usize> = HashMap::new();
        // References in events `from..to`, skipping notes (listed separately), pictures (their alt
        // text is plain) and code; the names found, in order.
        let walk = |this: &mut Self, from: usize, to: usize, order: &mut Vec<String>, counts: &mut HashMap<String, usize>| -> Vec<String> {
            let mut found = Vec::new();
            let mut i = from;
            while i < to {
                match &this.events[i].0 {
                    Event::Start(Tag::FootnoteDefinition(_) | Tag::Image { .. } | Tag::MetadataBlock(_) | Tag::CodeBlock(_)) => {
                        i = this.end_of[i] as usize + 1;
                        continue;
                    }
                    Event::FootnoteReference(name) => {
                        let name = name.to_string();
                        let k = counts.entry(name.clone()).or_insert(0);
                        *k += 1;
                        this.ref_occurrence.insert(i, *k);
                        if !this.numbers.contains_key(&name) {
                            this.numbers.insert(name.clone(), order.len() + 1);
                            order.push(name.clone());
                        }
                        found.push(name);
                    }
                    _ => {}
                }
                i += 1;
            }
            found
        };
        walk(self, 0, self.events.len(), &mut order, &mut counts);
        let mut k = 0;
        let mut added_unreferenced = false;
        loop {
            if k == order.len() {
                if added_unreferenced {
                    break;
                }
                added_unreferenced = true;
                let extra: Vec<String> = self.defs.iter().filter(|d| !self.numbers.contains_key(&d.name)).map(|d| d.name.clone()).collect();
                for name in extra {
                    self.numbers.insert(name.clone(), order.len() + 1);
                    order.push(name);
                }
                if k == order.len() {
                    break;
                }
            }
            let name = order[k].clone();
            k += 1;
            let Some(&di) = self.def_index.get(&name) else { continue };
            let children = self.defs[di].children.clone();
            let found = walk(self, children.start, children.end, &mut order, &mut counts);
            self.refs_in_def.insert(name, found);
        }
    }

    fn assign_heading_ids(&mut self) {
        // The footnotes' own ids are taken: a heading called "fn-1" must not steal the note's.
        let mut used: HashSet<String> = HashSet::new();
        for d in &self.defs {
            used.insert(format!("fn-{}", d.name));
        }
        for (&i, &k) in &self.ref_occurrence {
            if let Event::FootnoteReference(name) = &self.events[i].0 {
                let mut id = String::new();
                Self::footnote_ref_id(&mut id, name, k);
                used.insert(id);
            }
        }
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
        // What raw HTML blocks opened and never closed (sanitized output only).
        let closers = self.filter.finish();
        self.out.push_str(&closers);
        self.footnotes();
        let closers = self.filter.finish();
        self.out.push_str(&closers);
        std::mem::take(&mut self.out)
    }

    /// The notes section: every note the output refers to (and the notes those refer to), and
    /// the notes whose own definition is inside the window; in the order of their numbers.
    fn footnotes(&mut self) {
        if self.defs.is_empty() {
            return;
        }
        let mut shown: HashSet<String> = self.rendered_refs.keys().cloned().collect();
        shown.extend(self.defs.iter().filter(|d| d.touched).map(|d| d.name.clone()));
        let mut queue: Vec<String> = shown.iter().cloned().collect();
        while let Some(name) = queue.pop() {
            for inner in self.refs_in_def.get(&name).cloned().unwrap_or_default() {
                if shown.insert(inner.clone()) {
                    queue.push(inner);
                }
            }
        }
        let mut names: Vec<(usize, String)> =
            shown.into_iter().filter(|n| self.def_index.contains_key(n)).map(|n| (self.numbers.get(&n).copied().unwrap_or(usize::MAX), n)).collect();
        names.sort();
        // Render the bodies first: a body's references are what its back-links point at.
        let mut bodies = Vec::with_capacity(names.len());
        for (_, name) in &names {
            let di = self.def_index[name];
            let children = self.defs[di].children.clone();
            let saved = std::mem::take(&mut self.out);
            let saved_nl = std::mem::replace(&mut self.end_newline, true);
            self.filter.enter();
            self.render_range(children.start, children.end);
            let closers = self.filter.end_block() + &self.filter.leave();
            self.out.push_str(&closers);
            bodies.push(std::mem::replace(&mut self.out, saved));
            self.end_newline = saved_nl;
        }
        let mut items = String::new();
        for (position, ((number, name), mut body)) in names.into_iter().zip(bodies).enumerate() {
            let line = self.defs[self.def_index[&name]].line;
            // The back-references (to the references in the output only) go at the end of the
            // last paragraph.
            let mut backrefs = String::new();
            let mut occurrences = self.rendered_refs.get(&name).cloned().unwrap_or_default();
            occurrences.sort_unstable();
            occurrences.dedup();
            for c in occurrences {
                let mut id = String::new();
                Self::footnote_ref_id(&mut id, &name, c);
                backrefs.push_str(" <a href=\"#");
                let _ = escape_href(&mut backrefs, &id);
                backrefs.push_str("\" class=\"footnote-backref\" aria-label=\"Back to reference\">\u{21a9}");
                if c > 1 {
                    backrefs.push_str(&format!("<sup>{c}</sup>"));
                }
                backrefs.push_str("</a>");
            }
            if !backrefs.is_empty() {
                if body.ends_with("</p>\n") {
                    body.insert_str(body.len() - 5, &backrefs);
                } else {
                    body.push_str(&format!("<p>{}</p>\n", backrefs.trim_start()));
                }
            }
            items.push_str("<li id=\"fn-");
            let _ = escape_html(&mut items, &name);
            items.push('"');
            // The list numbers by position; a note's number is its first reference's.
            if number != position + 1 {
                items.push_str(&format!(" value=\"{number}\""));
            }
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

    /// `fnref-NAME` for the first reference, `fnref-NAME-2`... after it.
    fn footnote_ref_id(out: &mut String, name: &str, k: usize) {
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
                    let clean = self.filter.filter(&raw, false);
                    self.filter.end_html_block();
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
                        let inline = matches!(self.events[i].0, Event::InlineHtml(_));
                        let clean = self.filter.filter(&h, inline);
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
                    let n = self.numbers.get(&name).copied().unwrap_or(0);
                    let count = self.ref_occurrence.get(&i).copied().unwrap_or(1);
                    self.rendered_refs.entry(name.clone()).or_default().push(count);
                    let mut id = String::new();
                    Self::footnote_ref_id(&mut id, &name, count);
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

    /// End of a block of inline content: what the sanitizer's inline HTML left open is closed (and
    /// a dropped element left open stops swallowing).
    fn end_inline_html(&mut self) {
        let closers = self.filter.end_block();
        self.out.push_str(&closers);
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
        // Highlighting is bounded per render (see HIGHLIGHT_BUDGET_BYTES): counted in the same
        // units whether or not the block is cached, so the output depends on the text alone.
        let mut highlighted = None;
        let mut skipped = false;
        if self.opts.highlight && highlight::is_highlightable(info, code) {
            let cost = highlight::cost(code);
            if self.highlighted_bytes + cost <= HIGHLIGHT_BUDGET_BYTES {
                let deadline = *self.highlight_deadline.get_or_insert_with(|| Instant::now() + HIGHLIGHT_BUDGET_TIME);
                // A block wholly inside the floor is always highlighted, so an ordinary document
                // renders the same way every time (on first use a language's patterns compile,
                // which can take longer than the cap in a debug build).
                let capped = self.highlighted_bytes + cost > HIGHLIGHT_FLOOR_BYTES;
                self.highlighted_bytes += cost;
                highlighted = highlight::highlight_until(info, code, capped.then_some(deadline));
                skipped = highlighted.is_none();
            } else {
                skipped = true;
            }
            if skipped {
                self.unhighlighted_blocks += 1;
            }
        }
        self.out.push_str(&format!("<pre{line}"));
        if skipped {
            self.out.push_str(" data-highlight=\"skipped\"");
        }
        self.out.push_str("><code");
        if !lang.is_empty() {
            self.out.push_str(" class=\"language-");
            self.attr(lang);
            self.out.push('"');
        }
        self.out.push('>');
        match highlighted {
            Some(html) => self.out.push_str(&html),
            None => {
                let _ = escape_html_body_text(&mut self.out, code);
            }
        }
        self.write("</code></pre>\n");
    }

    fn image(&mut self, dest: &str, title: &str, from: usize, end: usize) {
        self.write("<img src=\"");
        if !self.opts.sanitize || is_safe_url(dest, true) {
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
                    let n = self.numbers.get(&name.to_string()).copied().unwrap_or(0);
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
            Tag::BlockQuote(_) => {
                self.filter.enter();
                self.open_block("blockquote", "", range.start, "\n");
            }
            Tag::CodeBlock(_) | Tag::Image { .. } | Tag::MetadataBlock(_) | Tag::FootnoteDefinition(_) => {}
            Tag::List(Some(1)) => self.open_plain("ol", "", range.start),
            Tag::List(Some(start)) => self.open_plain("ol", &format!(" start=\"{start}\""), range.start),
            Tag::List(None) => self.open_plain("ul", "", range.start),
            Tag::Item => {
                self.filter.enter();
                let task = matches!(self.events.get(index + 1), Some((Event::TaskListMarker(_), _)));
                self.open_block("li", if task { " class=\"task-list-item\"" } else { "" }, range.start, "");
            }
            Tag::DefinitionList => self.open_plain("dl", "", range.start),
            Tag::DefinitionListTitle => self.open_block("dt", "", range.start, ""),
            Tag::DefinitionListDefinition => self.open_block("dd", "", range.start, ""),
            Tag::Subscript => self.open_inline("sub"),
            Tag::Superscript => self.open_inline("sup"),
            Tag::Emphasis => self.open_inline("em"),
            Tag::Strong => self.open_inline("strong"),
            Tag::Strikethrough => self.open_inline("del"),
            Tag::Link { link_type, dest_url, title, .. } => {
                if self.opts.sanitize {
                    self.filter.open_own("a");
                }
                self.link_depth += 1;
                self.write("<a");
                // An e-mail autolink is written with `mailto:`, which is safe.
                let dangerous = self.opts.sanitize && link_type != LinkType::Email && !is_safe_url(&dest_url, false);
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

    /// `<tag>` for one of our inline elements (the sanitizer keeps raw HTML nested inside it).
    fn open_inline(&mut self, tag: &str) {
        if self.opts.sanitize {
            self.filter.open_own(tag);
        }
        self.write(&format!("<{tag}>"));
    }

    /// `</tag>` for one of our inline elements, after what raw HTML left open inside it.
    fn close_inline(&mut self, tag: &str) {
        if self.opts.sanitize {
            let closers = self.filter.close_own();
            self.out.push_str(&closers);
        }
        self.write(&format!("</{tag}>"));
    }

    /// `<tag attrs data-line>\n` (lists, definition lists).
    fn open_plain(&mut self, tag: &str, attrs: &str, start: usize) {
        if !self.end_newline {
            self.out.push('\n');
        }
        let line = self.line_attr(start);
        self.out.push_str(&format!("<{tag}{attrs}{line}>\n"));
        self.end_newline = true;
    }

    fn end_tag(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::HtmlBlock | TagEnd::Image | TagEnd::MetadataBlock(_) | TagEnd::FootnoteDefinition | TagEnd::CodeBlock => {}
            TagEnd::Paragraph => {
                self.end_inline_html();
                self.write("</p>\n");
            }
            TagEnd::Heading(level) => {
                self.end_inline_html();
                self.write(&format!("</{level}>\n"));
            }
            TagEnd::Table => self.write("</tbody></table>\n"),
            TagEnd::TableHead => {
                self.write("</tr></thead><tbody>\n");
                self.table.in_head = false;
            }
            TagEnd::TableRow => self.write("</tr>\n"),
            TagEnd::TableCell => {
                self.end_inline_html();
                self.write(if self.table.in_head { "</th>" } else { "</td>" });
                self.table.cell += 1;
            }
            TagEnd::BlockQuote(_) => {
                let closers = self.filter.leave();
                self.out.push_str(&closers);
                self.write("</blockquote>\n");
            }
            TagEnd::List(true) => self.write("</ol>\n"),
            TagEnd::List(false) => self.write("</ul>\n"),
            TagEnd::Item => {
                self.end_inline_html();
                let closers = self.filter.leave();
                self.out.push_str(&closers);
                self.pending_task = None;
                self.write("</li>\n");
            }
            TagEnd::DefinitionList => self.write("</dl>\n"),
            TagEnd::DefinitionListTitle => {
                self.end_inline_html();
                self.write("</dt>\n");
            }
            TagEnd::DefinitionListDefinition => {
                self.end_inline_html();
                self.write("</dd>\n");
            }
            TagEnd::Emphasis => self.close_inline("em"),
            TagEnd::Superscript => self.close_inline("sup"),
            TagEnd::Subscript => self.close_inline("sub"),
            TagEnd::Strong => self.close_inline("strong"),
            TagEnd::Strikethrough => self.close_inline("del"),
            TagEnd::Link => {
                self.link_depth = self.link_depth.saturating_sub(1);
                self.close_inline("a");
            }
        }
    }
}
