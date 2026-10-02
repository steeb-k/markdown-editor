//! Parsing and derivation of spans, blocks, prose ranges and images.
//!
//! Everything here works in UTF-8 byte offsets. pulldown-cmark reports element ranges;
//! the syntax characters (`Markup`) are derived from the gaps between an element and
//! its children plus line scanning.

use std::ops::Range;

use pulldown_cmark::{
    CodeBlockKind, Event, LinkType, MetadataBlockKind, Options, Parser, Tag, TagEnd,
};

use crate::autolink;
use crate::lines::LineIndex;
use crate::types::{BlockKind, ColumnAlignment, MarkupScope, SpanKind};

/// Markup bookkeeping kept next to each `Markup` span for Live mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct MarkupMeta {
    pub owner: (usize, usize),
    pub scope: MarkupScope,
    pub in_table: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ISpan {
    pub start: usize,
    pub end: usize,
    pub kind: SpanKind,
    /// `Some` exactly for `SpanKind::Markup`.
    pub meta: Option<MarkupMeta>,
}

impl ISpan {
    /// Total order: start ascending, end descending, then kind. Equality under this
    /// order is the identity used for dirty-range comparison (ignores `meta`).
    #[inline]
    pub fn cmp_key(&self, other: &Self) -> std::cmp::Ordering {
        self.start
            .cmp(&other.start)
            .then_with(|| other.end.cmp(&self.end))
            .then_with(|| kind_key(self.kind).cmp(&kind_key(other.kind)))
    }
}

/// Total order on kinds for deterministic sorting of equal ranges (outer first).
pub(crate) fn kind_key(kind: SpanKind) -> (u8, u8) {
    use SpanKind::*;
    match kind {
        FrontMatter => (0, 0),
        Heading { level } => (1, level),
        BlockQuote => (2, 0),
        CodeBlock => (3, 0),
        Table => (4, 0),
        FootnoteDefinition => (5, 0),
        Html => (6, 0),
        ThematicBreak => (7, 0),
        TableDelimiterRow => (8, 0),
        Link => (9, 0),
        Image => (10, 0),
        Emphasis => (11, 0),
        Strong => (12, 0),
        Strikethrough => (13, 0),
        InlineCode => (14, 0),
        FootnoteReference => (15, 0),
        ListMarker { ordered } => (16, ordered as u8),
        TaskMarker { checked } => (17, checked as u8),
        HardBreak => (18, 0),
        CodeInfo => (19, 0),
        LinkDestination => (20, 0),
        Markup => (21, 0),
    }
}

#[derive(Debug, Clone)]
pub(crate) struct IBlock {
    pub kind: BlockKind,
    pub start: usize,
    pub end: usize,
    pub line: u32,
    pub heading_level: Option<u8>,
    pub depth: u8,
}

#[derive(Debug, Clone)]
pub(crate) struct IImage {
    pub start: usize,
    pub end: usize,
    pub destination: String,
    pub alt: String,
    pub title: Option<String>,
    pub standalone: bool,
}

/// One table row (header or body): the line without its container prefix and the cells the
/// parser reported (raw ranges, including the blanks around the content).
#[derive(Debug, Clone)]
pub(crate) struct IRow {
    pub start: usize,
    pub end: usize,
    pub cells: Vec<(usize, usize)>,
}

#[derive(Debug, Clone)]
pub(crate) struct ITable {
    pub start: usize,
    pub end: usize,
    pub alignments: Vec<ColumnAlignment>,
    /// Header row first, then body rows. The delimiter row is not among them.
    pub rows: Vec<IRow>,
    /// The `|---|---|` line without its container prefix.
    pub delimiter: Option<(usize, usize)>,
}

#[derive(Debug, Clone)]
pub(crate) struct Analysis {
    /// Sorted by (start asc, end desc, kind rank); disjoint or properly nested.
    pub spans: Vec<ISpan>,
    /// `prefix_max_end[i]` = max end of `spans[..=i]` (for intersection queries).
    pub prefix_max_end: Vec<usize>,
    pub blocks: Vec<IBlock>,
    pub prose: Vec<(usize, usize)>,
    pub images: Vec<IImage>,
    pub tables: Vec<ITable>,
    pub lines: LineIndex,
}

/// Block quotes nested deeper than this get their element span but no `>` markup.
const MAX_QUOTE_MARKUP_DEPTH: usize = 32;

fn options() -> Options {
    // GFM-style bare URL autolinks (`https://example.com` without angle brackets) are
    // not offered by pulldown-cmark 0.13; only `<...>` autolinks are recognised. The core
    // finds bare URLs itself (see `autolink`).
    Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
}

pub(crate) fn analyze(text: &str) -> Analysis {
    // pulldown-cmark 0.13.4 panics on some inputs (e.g. `>1. [r]:u\n\t`, an unwrap in
    // `parse.rs`). A panic must not reach the shell (through FFI it aborts the app) or leave
    // the document half-updated, so the parse is isolated and a failed one yields an
    // analysis without structure: the text is still edited and shown, just unstyled.
    // Only the parser runs under `catch_unwind`; the derivation below is not shielded, so
    // its own assertions still fail tests.
    let parsed = std::panic::catch_unwind(|| {
        let mut events = Parser::new_ext(text, options()).into_offset_iter();
        let list: Vec<(Event<'_>, Range<usize>)> = events.by_ref().collect();
        let mut defs: Vec<(usize, usize)> =
            events.reference_definitions().iter().map(|(_, d)| (d.span.start, d.span.end)).collect();
        defs.sort_unstable();
        (list, defs)
    });
    let mut b = Builder::new(text);
    match parsed {
        Ok((events, defs)) => {
            for (ev, r) in events {
                b.event(ev, r);
            }
            b.finish(&defs)
        }
        Err(_) => b.finish(&[]),
    }
}

struct Para {
    start: usize,
    end: usize,
    /// Block already pushed (explicit `Paragraph` tag) vs. synthesized (tight list item).
    explicit: bool,
    depth: u8,
    children: u32,
    sole_image: Option<usize>,
}

struct LinkFrame {
    range: Range<usize>,
    link_type: LinkType,
    is_image: bool,
    ev_mark: usize,
    /// Index of the element's span in `spans` (its end may be extended for `[a][]`).
    span_idx: usize,
}

struct Builder<'a> {
    text: &'a str,
    b: &'a [u8],
    lines: LineIndex,
    spans: Vec<ISpan>,
    blocks: Vec<IBlock>,
    prose: Vec<(usize, usize)>,
    images: Vec<IImage>,
    tables: Vec<ITable>,
    cur_table: Option<ITable>,
    /// The current run of source-contiguous plain text, searched for bare URLs.
    run: Option<(usize, usize)>,
    /// Ranges of bare URLs (excluded from prose).
    bare_urls: Vec<(usize, usize)>,

    quote_depth: usize,
    container_depth: usize,
    in_table: bool,
    table_range: (usize, usize),
    in_code: bool,
    in_html: bool,
    in_meta: bool,
    autolink_depth: usize,
    image_stack: Vec<usize>,
    inline_depth: usize,
    leaf_open: bool,
    para: Option<Para>,
    link_stack: Vec<LinkFrame>,
    ev_count: usize,
    prev_end: usize,
    row_cells: Vec<(usize, usize)>,
    /// Open heading: trimmed range and the event count at its start.
    heading: Option<((usize, usize), usize)>,
    /// Block quotes (trimmed range, nesting index); their `>` markup is derived at the end.
    quotes: Vec<((usize, usize), usize)>,
    /// Source ranges of all text-like events, in document order: a `>` inside one of them
    /// is content (e.g. on a lazy continuation line), never a quote marker.
    texts: Vec<(usize, usize)>,
    /// The last run of backslashes looked at by `escape_markup`, `start..end`.
    backslash_run: (usize, usize),
    /// Set by an `End` event whose element was extended past its reported range.
    extended_end: Option<usize>,
}

#[inline]
fn is_ws(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r')
}

impl<'a> Builder<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            b: text.as_bytes(),
            lines: LineIndex::new(text),
            spans: Vec::new(),
            blocks: Vec::new(),
            prose: Vec::new(),
            images: Vec::new(),
            tables: Vec::new(),
            cur_table: None,
            run: None,
            bare_urls: Vec::new(),
            quote_depth: 0,
            container_depth: 0,
            in_table: false,
            table_range: (0, 0),
            in_code: false,
            in_html: false,
            in_meta: false,
            autolink_depth: 0,
            image_stack: Vec::new(),
            inline_depth: 0,
            leaf_open: false,
            para: None,
            link_stack: Vec::new(),
            ev_count: 0,
            prev_end: 0,
            row_cells: Vec::new(),
            heading: None,
            quotes: Vec::new(),
            texts: Vec::new(),
            backslash_run: (0, 0),
            extended_end: None,
        }
    }

    // ----- emit helpers -------------------------------------------------------------

    fn push(&mut self, start: usize, end: usize, kind: SpanKind) {
        if start < end && end <= self.b.len() {
            self.spans.push(ISpan { start, end, kind, meta: None });
        }
    }

    /// A `Markup` span. Never includes a line terminator (concealing one would join lines
    /// in Live mode): a range that crosses lines is split, and its terminators left out.
    fn markup(&mut self, start: usize, end: usize, owner: (usize, usize), scope: MarkupScope) {
        if start >= end || end > self.b.len() {
            return;
        }
        let meta = Some(MarkupMeta { owner, scope, in_table: self.in_table });
        let mut s = start;
        for i in start..end {
            if matches!(self.b[i], b'\n' | b'\r') {
                if s < i {
                    self.spans.push(ISpan { start: s, end: i, kind: SpanKind::Markup, meta });
                }
                s = i + 1;
            }
        }
        if s < end {
            self.spans.push(ISpan { start: s, end, kind: SpanKind::Markup, meta });
        }
    }

    fn line_owner(&self, pos: usize) -> (usize, usize) {
        let l = self.lines.line_of(pos.min(self.b.len()));
        self.lines.line_range(l, self.b)
    }

    /// An inline element's range without trailing blanks. pulldown-cmark extends the last
    /// element of an ATX heading over a trailing tab (`# *a*\t`); no inline element ends
    /// in a blank, so trimming is always safe.
    fn trim_inline(&self, mut r: Range<usize>) -> Range<usize> {
        while r.end > r.start && is_ws(self.b[r.end - 1]) {
            r.end -= 1;
        }
        r
    }

    /// Block range without line terminators at either end. (No block starts with one, but
    /// pulldown-cmark sometimes starts a range at the previous line's terminator: a nested
    /// list item indented with a tab, a setext heading after a blank-ish line.)
    fn trim_eol(&self, r: &Range<usize>) -> (usize, usize) {
        let mut e = r.end.min(self.b.len());
        while e > r.start && matches!(self.b[e - 1], b'\n' | b'\r') {
            e -= 1;
        }
        let mut s = r.start;
        while s < e && matches!(self.b[s], b'\n' | b'\r') {
            s += 1;
        }
        (s, e)
    }

    fn depth(&self) -> u8 {
        self.container_depth.min(255) as u8
    }

    fn push_block(&mut self, kind: BlockKind, (s, e): (usize, usize), level: Option<u8>, depth: u8) {
        if s < e {
            let line = self.lines.line_of(s) as u32;
            self.blocks.push(IBlock { kind, start: s, end: e, line, heading_level: level, depth });
        }
    }

    // ----- inline bookkeeping ---------------------------------------------------------

    /// Called for every inline event; maintains the (possibly implicit) paragraph.
    fn touch_inline(&mut self, r: &Range<usize>, countable: bool, image: Option<usize>) {
        if self.para.is_none() && !self.leaf_open {
            self.para = Some(Para {
                start: r.start,
                end: r.end,
                explicit: false,
                depth: self.depth(),
                children: 0,
                sole_image: None,
            });
        }
        let top = self.inline_depth == 0;
        if let Some(p) = &mut self.para {
            p.end = p.end.max(r.end);
            if top && countable {
                p.children += 1;
                p.sole_image = image;
            }
        }
    }

    fn flush_para(&mut self) {
        if let Some(p) = self.para.take() {
            if let (1, Some(i)) = (p.children, p.sole_image) {
                self.images[i].standalone = true;
            }
            if !p.explicit {
                let (s, e) = self.trim_eol(&(p.start..p.end));
                self.push_block(BlockKind::Paragraph, (s, e), None, p.depth);
            }
        }
    }

    // ----- event dispatch -------------------------------------------------------------

    fn event(&mut self, ev: Event<'_>, r: Range<usize>) {
        self.ev_count += 1;
        let end = r.end;
        if r.start <= r.end && r.end <= self.b.len() {
            self.dispatch(ev, r);
        }
        // An element whose range was extended (`[a][]`) ends later than pulldown-cmark says.
        self.prev_end = end.max(self.extended_end.take().unwrap_or(0));
    }

    /// Search the finished text run for bare URLs.
    fn flush_run(&mut self) {
        if let Some((s, e)) = self.run.take() {
            for a in autolink::find_in(self.text, s, e) {
                self.push(a.start, a.end, SpanKind::Link);
                self.bare_urls.push((a.start, a.end));
            }
        }
    }

    fn dispatch(&mut self, ev: Event<'_>, r: Range<usize>) {
        if !matches!(ev, Event::Text(_)) {
            self.flush_run();
        }
        if matches!(ev, Event::Text(_) | Event::Code(_) | Event::Html(_) | Event::InlineHtml(_)) && r.start < r.end {
            self.texts.push((r.start, r.end));
        }
        match ev {
            Event::Start(tag) => self.start(tag, r),
            Event::End(tag) => self.end(tag, r),
            Event::Text(t) => {
                if self.in_code || self.in_meta || self.in_html {
                    return;
                }
                if r.start < r.end {
                    self.escape_markup(&r);
                    if self.autolink_depth == 0 && self.image_stack.is_empty() {
                        self.prose.push((r.start, r.end));
                    }
                    for &i in &self.image_stack {
                        self.images[i].alt.push_str(&t);
                    }
                    self.touch_inline(&r, !t.trim().is_empty(), None);
                    if self.link_stack.is_empty() {
                        match &mut self.run {
                            Some(run) if run.1 == r.start => run.1 = r.end,
                            _ => {
                                self.flush_run();
                                self.run = Some((r.start, r.end));
                            }
                        }
                    } else {
                        self.flush_run();
                    }
                }
            }
            Event::Code(t) => {
                let r = self.trim_inline(r);
                for &i in &self.image_stack {
                    self.images[i].alt.push_str(&t);
                }
                self.touch_inline(&r, true, None);
                self.push(r.start, r.end, SpanKind::InlineCode);
                let mut n = 0;
                while r.start + n < r.end && self.b[r.start + n] == b'`' {
                    n += 1;
                }
                if n > 0 && 2 * n < r.end - r.start {
                    let owner = (r.start, r.end);
                    self.markup(r.start, r.start + n, owner, MarkupScope::Inline);
                    self.markup(r.end - n, r.end, owner, MarkupScope::Inline);
                }
            }
            Event::InlineHtml(_) => {
                self.touch_inline(&r, true, None);
                self.push(r.start, r.end, SpanKind::Html);
            }
            Event::Html(_) => {}
            Event::FootnoteReference(_) => {
                self.touch_inline(&r, true, None);
                self.push(r.start, r.end, SpanKind::FootnoteReference);
                if r.end - r.start >= 4 && self.b[r.start] == b'[' && self.b[r.start + 1] == b'^' {
                    let owner = (r.start, r.end);
                    self.markup(r.start, r.start + 2, owner, MarkupScope::Inline);
                    self.markup(r.end - 1, r.end, owner, MarkupScope::Inline);
                }
            }
            Event::SoftBreak => {
                for &i in &self.image_stack {
                    self.images[i].alt.push(' ');
                }
                self.touch_inline(&r, false, None);
            }
            Event::HardBreak => {
                for &i in &self.image_stack {
                    self.images[i].alt.push(' ');
                }
                self.touch_inline(&r, false, None);
                self.push(r.start, r.end, SpanKind::HardBreak);
            }
            Event::Rule => {
                self.flush_para();
                let t = self.trim_eol(&r);
                self.push(t.0, t.1, SpanKind::ThematicBreak);
                let d = self.depth();
                self.push_block(BlockKind::ThematicBreak, t, None, d);
            }
            Event::TaskListMarker(checked) => {
                self.push(r.start, r.end, SpanKind::TaskMarker { checked });
            }
            _ => {}
        }
    }

    fn start(&mut self, tag: Tag<'_>, r: Range<usize>) {
        let r = match tag {
            Tag::Emphasis | Tag::Strong | Tag::Strikethrough | Tag::Link { .. } | Tag::Image { .. } => self.trim_inline(r),
            _ => r,
        };
        match tag {
            Tag::Paragraph => {
                self.flush_para();
                let t = self.trim_eol(&r);
                let d = self.depth();
                self.push_block(BlockKind::Paragraph, t, None, d);
                self.leaf_open = true;
                self.para = Some(Para {
                    start: r.start,
                    end: r.end,
                    explicit: true,
                    depth: d,
                    children: 0,
                    sole_image: None,
                });
            }
            Tag::Heading { level, .. } => {
                self.flush_para();
                let mut t = self.trim_eol(&r);
                while t.1 > t.0 && matches!(self.b[t.1 - 1], b' ' | b'\t') {
                    t.1 -= 1;
                }
                let lv = level as u8;
                self.push(t.0, t.1, SpanKind::Heading { level: lv });
                let d = self.depth();
                self.push_block(BlockKind::Heading, t, Some(lv), d);
                self.heading = Some((t, self.ev_count));
                self.leaf_open = true;
            }
            Tag::BlockQuote(_) => {
                self.flush_para();
                let t = self.trim_eol(&r);
                self.push(t.0, t.1, SpanKind::BlockQuote);
                self.quotes.push((t, self.quote_depth));
                self.quote_depth += 1;
                self.container_depth += 1;
            }
            Tag::CodeBlock(kind) => {
                self.flush_para();
                let t = self.trim_eol(&r);
                self.push(t.0, t.1, SpanKind::CodeBlock);
                let d = self.depth();
                self.push_block(BlockKind::CodeBlock, t, None, d);
                if matches!(kind, CodeBlockKind::Fenced(_)) {
                    self.fence_markup(t);
                }
                self.in_code = true;
            }
            Tag::HtmlBlock => {
                self.flush_para();
                let t = self.trim_eol(&r);
                self.push(t.0, t.1, SpanKind::Html);
                let d = self.depth();
                self.push_block(BlockKind::HtmlBlock, t, None, d);
                self.in_html = true;
            }
            Tag::List(_) => self.flush_para(),
            Tag::Item => {
                self.flush_para();
                self.list_marker(&r);
                self.container_depth += 1;
            }
            Tag::FootnoteDefinition(_) => {
                self.flush_para();
                let t = self.trim_eol(&r);
                self.push(t.0, t.1, SpanKind::FootnoteDefinition);
                self.footnote_def_markup(t);
                self.container_depth += 1;
            }
            Tag::Table(aligns) => {
                self.flush_para();
                let t = self.trim_eol(&r);
                self.push(t.0, t.1, SpanKind::Table);
                let d = self.depth();
                self.push_block(BlockKind::Table, t, None, d);
                self.in_table = true;
                self.table_range = t;
                self.cur_table = Some(ITable {
                    start: t.0,
                    end: t.1,
                    alignments: aligns
                        .iter()
                        .map(|a| match a {
                            pulldown_cmark::Alignment::None => ColumnAlignment::None,
                            pulldown_cmark::Alignment::Left => ColumnAlignment::Left,
                            pulldown_cmark::Alignment::Center => ColumnAlignment::Center,
                            pulldown_cmark::Alignment::Right => ColumnAlignment::Right,
                        })
                        .collect(),
                    rows: Vec::new(),
                    delimiter: None,
                });
            }
            Tag::TableHead | Tag::TableRow => self.row_cells.clear(),
            Tag::TableCell => {
                self.row_cells.push((r.start, r.end));
                self.leaf_open = true;
            }
            Tag::Emphasis | Tag::Strong | Tag::Strikethrough => {
                self.touch_inline(&r, true, None);
                let (kind, d) = match tag {
                    Tag::Emphasis => (SpanKind::Emphasis, 1),
                    Tag::Strong => (SpanKind::Strong, 2),
                    _ => {
                        let n = if self.b.get(r.start + 1) == Some(&b'~') { 2 } else { 1 };
                        (SpanKind::Strikethrough, n)
                    }
                };
                self.push(r.start, r.end, kind);
                if r.end - r.start > 2 * d {
                    let owner = (r.start, r.end);
                    self.markup(r.start, r.start + d, owner, MarkupScope::Inline);
                    self.markup(r.end - d, r.end, owner, MarkupScope::Inline);
                }
                self.inline_depth += 1;
            }
            Tag::Link { link_type, .. } => {
                self.touch_inline(&r, true, None);
                let span_idx = self.spans.len();
                self.push(r.start, r.end, SpanKind::Link);
                if matches!(link_type, LinkType::Autolink | LinkType::Email) {
                    self.autolink_depth += 1;
                }
                self.link_stack.push(LinkFrame {
                    range: r,
                    link_type,
                    is_image: false,
                    ev_mark: self.ev_count,
                    span_idx,
                });
                self.inline_depth += 1;
            }
            Tag::Image { link_type, dest_url, title, .. } => {
                let idx = self.images.len();
                self.touch_inline(&r, true, Some(idx));
                self.images.push(IImage {
                    start: r.start,
                    end: r.end,
                    destination: dest_url.to_string(),
                    alt: String::new(),
                    title: if title.is_empty() { None } else { Some(title.to_string()) },
                    standalone: false,
                });
                self.image_stack.push(idx);
                let span_idx = self.spans.len();
                self.push(r.start, r.end, SpanKind::Image);
                self.link_stack.push(LinkFrame {
                    range: r,
                    link_type,
                    is_image: true,
                    ev_mark: self.ev_count,
                    span_idx,
                });
                self.inline_depth += 1;
            }
            Tag::MetadataBlock(kind) => {
                self.flush_para();
                let t = self.trim_eol(&r);
                self.push(t.0, t.1, SpanKind::FrontMatter);
                let d = self.depth();
                self.push_block(BlockKind::FrontMatter, t, None, d);
                if matches!(kind, MetadataBlockKind::YamlStyle | MetadataBlockKind::PlusesStyle) {
                    self.front_matter_markup(t);
                }
                self.in_meta = true;
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd, r: Range<usize>) {
        match tag {
            TagEnd::Paragraph => {
                self.flush_para();
                self.leaf_open = false;
            }
            TagEnd::Heading(_) => {
                if let Some((t, mark)) = self.heading.take() {
                    let content_end = (self.ev_count > mark + 1).then_some(self.prev_end);
                    self.heading_markup(t, content_end);
                }
                self.leaf_open = false;
            }
            TagEnd::BlockQuote(_) => {
                self.flush_para();
                self.quote_depth = self.quote_depth.saturating_sub(1);
                self.container_depth = self.container_depth.saturating_sub(1);
            }
            TagEnd::CodeBlock => self.in_code = false,
            TagEnd::HtmlBlock => self.in_html = false,
            TagEnd::List(_) => self.flush_para(),
            TagEnd::Item | TagEnd::FootnoteDefinition => {
                self.flush_para();
                self.container_depth = self.container_depth.saturating_sub(1);
            }
            TagEnd::Table => {
                self.in_table = false;
                if let Some(t) = self.cur_table.take() {
                    self.tables.push(t);
                }
            }
            TagEnd::TableHead => {
                self.record_row(&r);
                self.row_pipes(&r);
                let d = self.delimiter_row(&r);
                if let Some(t) = &mut self.cur_table {
                    t.delimiter = d;
                }
            }
            TagEnd::TableRow => {
                self.record_row(&r);
                self.row_pipes(&r);
            }
            TagEnd::TableCell => self.leaf_open = false,
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => {
                self.inline_depth = self.inline_depth.saturating_sub(1);
            }
            TagEnd::Link | TagEnd::Image => {
                self.inline_depth = self.inline_depth.saturating_sub(1);
                let is_image = matches!(tag, TagEnd::Image);
                let image_idx = if is_image { self.image_stack.pop() } else { None };
                if let Some(mut f) = self.link_stack.pop() {
                    // pulldown-cmark leaves the trailing `[]` of `[a][]` outside the element.
                    if f.link_type == LinkType::Collapsed && self.b[f.range.end..].starts_with(b"[]") {
                        f.range.end += 2;
                        self.extended_end = Some(f.range.end);
                        if let Some(sp) = self.spans.get_mut(f.span_idx) {
                            sp.end = f.range.end;
                        }
                        if let Some(i) = image_idx {
                            self.images[i].end = f.range.end;
                        }
                    }
                    if matches!(f.link_type, LinkType::Autolink | LinkType::Email) && !is_image {
                        self.autolink_depth = self.autolink_depth.saturating_sub(1);
                    }
                    let no_children = self.ev_count == f.ev_mark + 1;
                    let last_child_end = if no_children { 0 } else { self.prev_end };
                    self.link_markup(&f, last_child_end);
                }
            }
            TagEnd::MetadataBlock(_) => self.in_meta = false,
            _ => {}
        }
    }

    // ----- block-level markup ---------------------------------------------------------

    /// `content_end`: end of the heading's last inline event, if it has any.
    fn heading_markup(&mut self, (s, e): (usize, usize), content_end: Option<usize>) {
        let b = self.b;
        let (ls, le) = self.line_owner(s);
        if e <= le {
            // ATX (always one line; a setext heading has at least two).
            let mut i = s;
            while i < le && matches!(b[i], b' ' | b'\t') {
                i += 1;
            }
            let mut j = i;
            while j < le && b[j] == b'#' {
                j += 1;
            }
            if j == i {
                return;
            }
            while j < le && matches!(b[j], b' ' | b'\t') {
                j += 1;
            }
            let owner = (ls, le);
            self.markup(i, j, owner, MarkupScope::Line);
            // Closing sequence: whatever `#`s follow the content (pulldown-cmark decides what
            // is content, so the preview and the editor agree), up to trailing blanks.
            let mut ce = e.min(le);
            while ce > j && matches!(b[ce - 1], b' ' | b'\t') {
                ce -= 1;
            }
            let mut k = content_end.unwrap_or(j).max(j);
            while k < ce && matches!(b[k], b' ' | b'\t') {
                k += 1;
            }
            if k < ce && b[k..ce].iter().all(|&c| c == b'#') {
                self.markup(k, ce, owner, MarkupScope::Line);
            }
        } else {
            // Setext: the underline is the last line.
            let ll = self.lines.line_start(e.saturating_sub(1));
            if ll > s {
                let mut p = ll;
                while p < e && matches!(b[p], b' ' | b'\t' | b'>') {
                    p += 1;
                }
                if p < e && matches!(b[p], b'=' | b'-') {
                    let c = b[p];
                    let mut q = p;
                    while q < e && b[q] == c {
                        q += 1;
                    }
                    self.markup(p, q, (s, e), MarkupScope::Block);
                }
            }
        }
    }

    /// `>` (plus one following space) on every line of the quote that has one for this
    /// nesting level. Lazy continuation lines have none.
    fn quote_markup(&mut self, (s, e): (usize, usize), nth: usize) {
        if e == 0 {
            return;
        }
        // Pathologically deep nesting would make this quadratic; real documents stay far below.
        if nth >= MAX_QUOTE_MARKUP_DEPTH {
            return;
        }
        let first = self.lines.line_of(s);
        let last = self.lines.line_of(e - 1);
        for line in first..=last {
            let (ls, le) = self.lines.line_range(line, self.b);
            if let Some((ms, me)) = nth_quote_marker(self.b, ls, le, nth) {
                let i = self.texts.partition_point(|t| t.1 <= ms);
                // pulldown-cmark 0.13 sometimes puts a tab-indented `>` line inside an HTML or
                // code block of the quote without reporting its text; four columns of
                // indentation there make it block content, not a marker.
                let indent = self.b[ls..ms].iter().fold(0, |c, &x| if x == b'\t' { (c / 4 + 1) * 4 } else { c + 1 });
                let in_block = indent >= 4
                    && self.spans.iter().any(|sp| matches!(sp.kind, SpanKind::Html | SpanKind::CodeBlock) && sp.start < ms && ms < sp.end);
                if !in_block && self.texts.get(i).is_none_or(|t| t.0 >= me) {
                    self.markup(ms, me, (ls, le), MarkupScope::Line);
                }
            }
        }
    }

    fn fence_markup(&mut self, (s, e): (usize, usize)) {
        let b = self.b;
        let (fls, fle) = self.line_owner(s);
        let fle = fle.min(e);
        let mut i = s;
        while i < fle && matches!(b[i], b' ' | b'\t') {
            i += 1;
        }
        if i >= fle || !matches!(b[i], b'`' | b'~') {
            return;
        }
        let c = b[i];
        let mut j = i;
        while j < fle && b[j] == c {
            j += 1;
        }
        let n = j - i;
        if n < 3 {
            return;
        }
        let owner = (fls, fle);
        self.markup(i, j, owner, MarkupScope::Line);
        let mut is = j;
        while is < fle && matches!(b[is], b' ' | b'\t') {
            is += 1;
        }
        let mut ie = fle;
        while ie > is && matches!(b[ie - 1], b' ' | b'\t') {
            ie -= 1;
        }
        self.push(is, ie, SpanKind::CodeInfo);

        // Closing fence on the last line, if it is a different line.
        let ll = self.lines.line_start(e.saturating_sub(1));
        if ll > fls {
            let (_, lle) = self.lines.line_range(self.lines.line_of(ll), b);
            let lle = lle.min(e);
            let mut p = ll;
            while p < lle && matches!(b[p], b' ' | b'\t' | b'>') {
                p += 1;
            }
            let mut q = p;
            while q < lle && b[q] == c {
                q += 1;
            }
            if q - p >= n && b[q..lle].iter().all(|&x| matches!(x, b' ' | b'\t')) {
                self.markup(p, q, (ll, lle), MarkupScope::Line);
            }
        }
    }

    fn front_matter_markup(&mut self, (s, e): (usize, usize)) {
        let b = self.b;
        let (fls, fle) = self.line_owner(s);
        let mut fe = fle.min(e);
        while fe > s && matches!(b[fe - 1], b' ' | b'\t') {
            fe -= 1;
        }
        self.markup(s, fe, (fls, fle), MarkupScope::Line);
        let ll = self.lines.line_start(e.saturating_sub(1));
        // The closing delimiter, if the block has one (pulldown-cmark can end a metadata
        // block without one, e.g. at the end of a list item).
        let closing = b[ll..e].iter().filter(|c| !matches!(c, b' ' | b'\t')).copied().collect::<Vec<u8>>();
        if ll > fls && matches!(closing.as_slice(), b"---" | b"..." | b"+++") {
            let mut p = ll;
            while p < e && matches!(b[p], b' ' | b'\t') {
                p += 1;
            }
            let mut q = e;
            while q > p && matches!(b[q - 1], b' ' | b'\t') {
                q -= 1;
            }
            self.markup(p, q, (ll, e), MarkupScope::Line);
        }
    }

    fn list_marker(&mut self, r: &Range<usize>) {
        let b = self.b;
        // A nested item indented with a tab starts at the previous line's terminator.
        let mut start = r.start;
        while start < r.end && matches!(b[start], b'\n' | b'\r') {
            start += 1;
        }
        let fle = self.line_owner(start).1.min(r.end);
        let mut i = start;
        // The range can also start at an enclosing quote's `>` (`>\t- item`).
        while i < fle && matches!(b[i], b' ' | b'\t' | b'>') {
            i += 1;
        }
        if i >= fle {
            return;
        }
        match b[i] {
            b'-' | b'+' | b'*' => {
                self.push(i, i + 1, SpanKind::ListMarker { ordered: false });
            }
            b'0'..=b'9' => {
                let mut j = i;
                while j < fle && b[j].is_ascii_digit() {
                    j += 1;
                }
                if j < fle && matches!(b[j], b'.' | b')') {
                    self.push(i, j + 1, SpanKind::ListMarker { ordered: true });
                }
            }
            _ => {}
        }
    }

    fn footnote_def_markup(&mut self, (s, e): (usize, usize)) {
        let b = self.b;
        if e - s >= 4 && b[s] == b'[' && b[s + 1] == b'^' {
            let owner = self.line_owner(s);
            let mut k = s + 2;
            while k < e && b[k] != b']' && b[k] != b'\n' {
                k += 1;
            }
            if k + 1 < e && b[k] == b']' && b[k + 1] == b':' {
                self.markup(s, s + 2, owner, MarkupScope::Line);
                self.markup(k, k + 2, owner, MarkupScope::Line);
            }
        }
    }

    fn row_pipes(&mut self, r: &Range<usize>) {
        let (s, e) = self.trim_eol(r);
        let owner = self.table_range;
        let cells = std::mem::take(&mut self.row_cells);
        let mut cursor = s;
        for &(cs, ce) in &cells {
            for k in cursor..cs.min(e) {
                if self.b[k] == b'|' {
                    self.markup(k, k + 1, owner, MarkupScope::Block);
                }
            }
            cursor = cursor.max(ce);
        }
        for k in cursor..e {
            if self.b[k] == b'|' {
                self.markup(k, k + 1, owner, MarkupScope::Block);
            }
        }
        self.row_cells = cells;
        self.row_cells.clear();
    }

    /// Remember the row for the table model. The parser appends an empty cell positioned at the
    /// row's end to rows that have fewer cells than the header; those are not real cells.
    fn record_row(&mut self, r: &Range<usize>) {
        let (s, e) = self.trim_eol(r);
        let cells: Vec<(usize, usize)> =
            self.row_cells.iter().copied().filter(|&(cs, ce)| !(cs == ce && cs >= e) && ce <= self.b.len()).collect();
        if let Some(t) = &mut self.cur_table {
            t.rows.push(IRow { start: s, end: e, cells });
        }
    }

    fn delimiter_row(&mut self, head: &Range<usize>) -> Option<(usize, usize)> {
        let (_, he) = self.trim_eol(head);
        let l = self.lines.line_of(he.saturating_sub(1)) + 1;
        if l >= self.lines.count() {
            return None;
        }
        let (ls, le) = self.lines.line_range(l, self.b);
        let mut s = ls;
        while s < le && matches!(self.b[s], b' ' | b'\t' | b'>') {
            s += 1;
        }
        let mut e = le;
        while e > s && matches!(self.b[e - 1], b' ' | b'\t') {
            e -= 1;
        }
        if e > s && e <= self.table_range.1 {
            self.push(s, e, SpanKind::TableDelimiterRow);
            let owner = self.table_range;
            for k in s..e {
                if self.b[k] == b'|' {
                    self.markup(k, k + 1, owner, MarkupScope::Block);
                }
            }
            return Some((s, e));
        }
        None
    }

    // ----- inline markup --------------------------------------------------------------

    /// Backslash of a backslash escape: the Text event of an escaped character starts
    /// right after an odd-length run of backslashes.
    fn escape_markup(&mut self, r: &Range<usize>) {
        let s = r.start;
        if s == 0 || self.b[s - 1] != b'\\' || !self.b[s].is_ascii_punctuation() {
            return;
        }
        // Start of the backslash run ending at `s`. Events arrive in order, so remembering
        // the last run keeps a long run of backslashes linear rather than quadratic.
        let run_start = match self.backslash_run {
            (rs, re) if rs < s && s <= re => rs,
            _ => {
                let mut rs = s - 1;
                while rs > 0 && self.b[rs - 1] == b'\\' {
                    rs -= 1;
                }
                let mut re = s;
                while re < self.b.len() && self.b[re] == b'\\' {
                    re += 1;
                }
                self.backslash_run = (rs, re);
                rs
            }
        };
        let n = s - run_start;
        if n % 2 == 1 {
            self.markup(s - 1, s, (s - 1, s + 1), MarkupScope::Inline);
        }
    }

    fn link_markup(&mut self, f: &LinkFrame, last_child_end: usize) {
        let b = self.b;
        let r = &f.range;
        let owner = (r.start, r.end);
        if matches!(f.link_type, LinkType::Autolink | LinkType::Email) {
            if r.end - r.start >= 2 {
                self.markup(r.start, r.start + 1, owner, MarkupScope::Inline);
                self.markup(r.end - 1, r.end, owner, MarkupScope::Inline);
                self.push(r.start + 1, r.end - 1, SpanKind::LinkDestination);
            }
            return;
        }
        let open = if f.is_image { 2 } else { 1 };
        if r.end - r.start < open + 1 {
            return;
        }
        self.markup(r.start, r.start + open, owner, MarkupScope::Inline);
        let mut p = last_child_end.max(r.start + open);
        while p < r.end && b[p] != b']' {
            p += 1;
        }
        if p >= r.end {
            return;
        }
        let close = p;
        match f.link_type {
            LinkType::Inline => {
                if b.get(close + 1) != Some(&b'(') || b[r.end - 1] != b')' || r.end < close + 3 {
                    self.markup(close, close + 1, owner, MarkupScope::Inline);
                    return;
                }
                // Destination and title, without surrounding whitespace. Either may sit on a
                // continuation line, whose quote prefix (`> `) belongs to the quote.
                let (is, ie) = (close + 2, r.end - 1);
                let lines = &self.lines;
                let prefix_only = |p: usize| {
                    let ls = lines.line_start(p);
                    ls > close && b[ls..p].iter().all(|&c| matches!(c, b' ' | b'\t' | b'>'))
                };
                let mut ds = is;
                while ds < ie && (is_ws(b[ds]) || (b[ds] == b'>' && prefix_only(ds))) {
                    ds += 1;
                }
                let mut de = ie;
                while de > ds && (is_ws(b[de - 1]) || (b[de - 1] == b'>' && prefix_only(de - 1))) {
                    de -= 1;
                }
                let open_end = ds.min(self.line_owner(close).1);
                self.markup(close, open_end, owner, MarkupScope::Inline);
                self.push(ds, de, SpanKind::LinkDestination);
                let last_line = self.lines.line_start(r.end - 1);
                let close_start = if last_line > de {
                    let mut p = last_line;
                    while p < r.end - 1 && matches!(b[p], b' ' | b'\t' | b'>') {
                        p += 1;
                    }
                    p
                } else {
                    de
                };
                self.markup(close_start, r.end, owner, MarkupScope::Inline);
            }
            LinkType::Reference | LinkType::ReferenceUnknown => {
                // `][label]`: the label's opening bracket is the first `[` after the text's
                // closing `]`. It is normally right after it, but pulldown-cmark also accepts
                // `[^1]\[r]` (and `[a][x\[]` has an escaped bracket inside the label).
                let lb = if b[r.end - 1] == b']' { (close + 1..r.end - 1).find(|&k| b[k] == b'[') } else { None };
                match lb {
                    Some(lb) if lb + 1 < r.end - 1 => {
                        self.markup(close, lb + 1, owner, MarkupScope::Inline);
                        self.push(lb + 1, r.end - 1, SpanKind::LinkDestination);
                        self.markup(r.end - 1, r.end, owner, MarkupScope::Inline);
                    }
                    _ => self.markup(close, r.end, owner, MarkupScope::Inline),
                }
            }
            LinkType::Collapsed | LinkType::CollapsedUnknown => {
                self.markup(close, r.end, owner, MarkupScope::Inline);
            }
            _ => {
                self.markup(close, close + 1, owner, MarkupScope::Inline);
            }
        }
    }

    // ----- finish ---------------------------------------------------------------------

    /// Link reference definitions produce no events. pulldown-cmark reports the source
    /// range of each definition it keeps (`defs`, sorted); a later definition with a
    /// duplicate label is dropped there, so lines that no block or reported definition
    /// covers are also tried as one-line definitions `[label]: destination "title"` (the
    /// title may be on the next line).
    fn link_definitions(&mut self, defs: &[(usize, usize)]) {
        for &(s, e) in defs {
            self.definition(s, e);
        }
        let mut ranges: Vec<(usize, usize)> = self.blocks.iter().map(|b| (b.start, b.end)).collect();
        ranges.extend_from_slice(defs);
        ranges.sort_unstable();
        let mut free = Vec::new(); // lines no block or reported definition touches
        let mut next_line = 0;
        for (s, e) in ranges {
            let first = self.lines.line_of(s);
            let last = self.lines.line_of(e.saturating_sub(1).max(s));
            free.extend(next_line..first);
            next_line = next_line.max(last + 1);
        }
        free.extend(next_line..self.lines.count());
        for (n, &line) in free.iter().enumerate() {
            let content = |line: usize| {
                let (ls, le) = self.lines.line_range(line, self.b);
                let i = container_prefix_end(self.b, ls, le);
                (i, le, self.b.get(i).copied().filter(|_| i < le))
            };
            let (i, mut le, first) = content(line);
            if first != Some(b'[') {
                continue;
            }
            // A title may sit on the following line.
            if free.get(n + 1) == Some(&(line + 1)) {
                let (_, nle, c) = content(line + 1);
                if matches!(c, Some(b'"' | b'\'' | b'(')) {
                    le = nle;
                }
            }
            self.definition(i, le);
        }
    }

    /// Markup and destination of the definition `[label]: dest "title"` in `s..e`, which
    /// starts at `[` and may span lines (continuation lines may carry container prefixes).
    /// Does nothing if the range does not have that shape.
    fn definition(&mut self, s: usize, e: usize) {
        let b = self.b;
        if s >= e || b[s] != b'[' || b.get(s + 1) == Some(&b'^') {
            return;
        }
        // Label: up to the first unescaped `]` (labels cannot contain unescaped brackets).
        let mut i = s + 1;
        while i < e && b[i] != b']' && b[i] != b'[' {
            i += if b[i] == b'\\' { 2 } else { 1 };
        }
        if i + 1 >= e || b[i] != b']' || i == s + 1 || b[i + 1] != b':' {
            return;
        }
        let close = i;
        // Blanks, at most one line break and the next line's container prefix.
        let skip = |mut i: usize, this: &Self| -> usize {
            while i < e && matches!(b[i], b' ' | b'\t') {
                i += 1;
            }
            if i < e && matches!(b[i], b'\n' | b'\r') {
                i = this.lines.next_line_start(i);
                let le = this.lines.line_range(this.lines.line_of(i.min(b.len())), b).1;
                i = container_prefix_end(b, i, le.min(e));
            }
            i
        };
        let ds = skip(close + 2, self);
        if ds >= e {
            return;
        }
        let mut de = ds;
        if b[ds] == b'<' {
            while de < e && b[de] != b'>' && !matches!(b[de], b'\n' | b'\r') {
                de += if b[de] == b'\\' { 2 } else { 1 };
            }
            if de >= e || b[de] != b'>' {
                return;
            }
            de += 1;
        } else {
            while de < e && !b[de].is_ascii_whitespace() {
                de += 1;
            }
        }
        let de = de.min(e);
        // Title: the rest of the range, if anything follows the destination.
        let ts = skip(de, self);
        let owner = |p: usize| self.line_owner(p);
        let (o1, o2) = (owner(s), owner(close));
        self.markup(s, s + 1, o1, MarkupScope::Line);
        self.markup(close, close + 2, o2, MarkupScope::Line);
        let mut te = e;
        while te > ts && b[te - 1].is_ascii_whitespace() {
            te -= 1;
        }
        let title = ts < te && matches!(b[ts], b'"' | b'\'' | b'(') && de < ts;
        if title && self.lines.line_of(de) == self.lines.line_of(ts) {
            self.push(ds, te, SpanKind::LinkDestination);
        } else {
            self.push(ds, de, SpanKind::LinkDestination);
            if title {
                self.push(ts, te, SpanKind::LinkDestination);
            }
        }
    }

    fn finish(mut self, defs: &[(usize, usize)]) -> Analysis {
        self.flush_run();
        self.flush_para();
        self.link_definitions(defs);
        // Inline events arrive in document order; keep the list sorted regardless.
        if !self.texts.is_sorted() {
            self.texts.sort_unstable();
        }
        for (t, nth) in std::mem::take(&mut self.quotes) {
            self.quote_markup(t, nth);
        }
        let spans = sanitize(self.text, std::mem::take(&mut self.spans));
        let mut prefix_max_end = Vec::with_capacity(spans.len());
        let mut m = 0;
        for s in &spans {
            m = m.max(s.end);
            prefix_max_end.push(m);
        }
        let prose = prose_ranges(&self.prose, &spans, &self.bare_urls);
        Analysis {
            spans,
            prefix_max_end,
            blocks: self.blocks,
            prose,
            images: self.images,
            tables: self.tables,
            lines: self.lines,
        }
    }
}

/// One container marker at `i` (after blanks): `>`, a bullet or ordered list marker
/// followed by a blank or the line end, or a footnote definition label `[^label]:`.
/// Returns the position after it and whether it is a block-quote marker.
fn container_marker(b: &[u8], i: usize, le: usize) -> Option<(usize, bool)> {
    let blank_or_end = |j: usize| j == le || matches!(b[j], b' ' | b'\t');
    match *b.get(i).filter(|_| i < le)? {
        b'>' => Some((i + 1, true)),
        b'-' | b'+' | b'*' if blank_or_end(i + 1) => Some((i + 1, false)),
        b'0'..=b'9' => {
            let mut j = i;
            while j < le && b[j].is_ascii_digit() && j - i < 9 {
                j += 1;
            }
            (j < le && matches!(b[j], b'.' | b')') && blank_or_end(j + 1)).then_some((j + 1, false))
        }
        b'[' if b.get(i + 1) == Some(&b'^') => {
            let mut j = i + 2;
            while j < le && !matches!(b[j], b']' | b'[') {
                j += if b[j] == b'\\' { 2 } else { 1 };
            }
            (j + 1 < le && b[j] == b']' && b[j + 1] == b':' && j > i + 2).then_some((j + 2, false))
        }
        _ => None,
    }
}

/// End of the container prefix (blanks, `>`, list markers, footnote labels) of a line.
fn container_prefix_end(b: &[u8], ls: usize, le: usize) -> usize {
    let mut i = ls;
    loop {
        while i < le && matches!(b[i], b' ' | b'\t') {
            i += 1;
        }
        match container_marker(b, i, le) {
            Some((next, _)) => i = next,
            None => return i,
        }
    }
}

/// The `nth` (0-based) block-quote marker, with one following space, in the container
/// prefix of a line.
fn nth_quote_marker(b: &[u8], ls: usize, le: usize, nth: usize) -> Option<(usize, usize)> {
    let mut i = ls;
    let mut count = 0;
    loop {
        while i < le && matches!(b[i], b' ' | b'\t') {
            i += 1;
        }
        let (next, quote) = container_marker(b, i, le)?;
        if quote {
            if count == nth {
                let end = if next < le && b[next] == b' ' { next + 1 } else { next };
                return Some((i, end));
            }
            count += 1;
        }
        i = next;
    }
}

/// Drops spans that violate the contract (empty, out of bounds, off a code point
/// boundary, partially overlapping) and sorts the rest. A debug build asserts that
/// nothing had to be dropped, so derivation bugs surface in tests.
fn sanitize(text: &str, mut spans: Vec<ISpan>) -> Vec<ISpan> {
    let len = text.len();
    let before = spans.len();
    spans.retain(|s| {
        s.start < s.end && s.end <= len && text.is_char_boundary(s.start) && text.is_char_boundary(s.end)
    });
    let mut dropped = before - spans.len();
    spans.sort_by(|a, b| a.cmp_key(b));
    spans.dedup_by(|a, b| a.cmp_key(b).is_eq());
    let mut out: Vec<ISpan> = Vec::with_capacity(spans.len());
    let mut stack: Vec<usize> = Vec::new();
    for s in spans {
        while let Some(&top) = stack.last() {
            if top <= s.start {
                stack.pop();
            } else {
                break;
            }
        }
        if stack.last().is_some_and(|&top| s.end > top) {
            dropped += 1;
            continue;
        }
        stack.push(s.end);
        out.push(s);
    }
    debug_assert_eq!(dropped, 0, "span derivation produced invalid spans for {text:?}");
    out
}

/// Is this a span kind whose text is not human prose?
fn non_prose(kind: SpanKind) -> bool {
    !matches!(
        kind,
        SpanKind::Heading { .. }
            | SpanKind::Emphasis
            | SpanKind::Strong
            | SpanKind::Strikethrough
            | SpanKind::Link
            | SpanKind::BlockQuote
            | SpanKind::Table
            | SpanKind::FootnoteDefinition
    )
}

/// Text ranges with every non-prose span subtracted, adjacent pieces merged.
fn prose_ranges(texts: &[(usize, usize)], spans: &[ISpan], bare_urls: &[(usize, usize)]) -> Vec<(usize, usize)> {
    // Union of exclusion intervals, sorted by start: non-prose spans and bare URLs.
    let mut raw: Vec<(usize, usize)> = spans.iter().filter(|s| non_prose(s.kind)).map(|s| (s.start, s.end)).collect();
    if !bare_urls.is_empty() {
        raw.extend_from_slice(bare_urls);
        raw.sort_unstable();
    }
    let mut excl: Vec<(usize, usize)> = Vec::new();
    for (start, end) in raw {
        match excl.last_mut() {
            Some(last) if start <= last.1 => last.1 = last.1.max(end),
            _ => excl.push((start, end)),
        }
    }
    let mut out: Vec<(usize, usize)> = Vec::new();
    let emit = |s: usize, e: usize, out: &mut Vec<(usize, usize)>| {
        if s >= e {
            return;
        }
        match out.last_mut() {
            Some(last) if last.1 == s => last.1 = e,
            _ => out.push((s, e)),
        }
    };
    for &(ts, te) in texts {
        let mut cur = ts;
        let mut i = excl.partition_point(|x| x.1 <= ts);
        while i < excl.len() && excl[i].0 < te {
            if excl[i].0 > cur {
                emit(cur, excl[i].0, &mut out);
            }
            cur = cur.max(excl[i].1);
            i += 1;
        }
        if cur < te {
            emit(cur, te, &mut out);
        }
    }
    out
}
