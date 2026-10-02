//! Editing commands: pure queries on a [`Document`] that return a [`TextEdit`].
//!
//! Everything here computes in UTF-8 byte offsets and converts at the edge. Commands build a
//! list of [`Splice`]s (non-overlapping replacements in the current text); [`Ctx::finish`]
//! merges them into one contiguous edit, shrinks it to the part that really changes, and
//! converts offsets to the document's unit.

mod block;
mod inline;
mod list;
mod state;
mod table;

use crate::analysis::{Analysis, IBlock};
use crate::document::Document;
use crate::types::*;

pub(crate) use state::format_state;
pub(crate) use table::{table_at, table_command};

pub(crate) fn format(doc: &Document, cmd: FormatCommand, selection: TextRange) -> Option<TextEdit> {
    let cx = Ctx::new(doc);
    let (s, e) = cx.sel(selection);
    match cmd {
        FormatCommand::Strong => inline::toggle(&cx, inline::Kind::Strong, s, e),
        FormatCommand::Emphasis => inline::toggle(&cx, inline::Kind::Emphasis, s, e),
        FormatCommand::Strikethrough => inline::toggle(&cx, inline::Kind::Strike, s, e),
        FormatCommand::InlineCode => inline::toggle(&cx, inline::Kind::Code, s, e),
        FormatCommand::Link => inline::link(&cx, s, e),
        FormatCommand::Image { destination, alt } => inline::image(&cx, &destination, &alt, s, e),
        FormatCommand::LinkTo { destination, text } => inline::link_to(&cx, &destination, &text, s, e),
        FormatCommand::Heading { level } => block::heading(&cx, level, s, e),
        FormatCommand::BlockQuote => block::quote(&cx, s, e),
        FormatCommand::BulletList => block::list(&cx, ListKind::Bullet, s, e),
        FormatCommand::OrderedList => block::list(&cx, ListKind::Ordered, s, e),
        FormatCommand::TaskList => block::list(&cx, ListKind::Task, s, e),
        FormatCommand::CodeBlock => block::code_block(&cx, s, e),
    }
}

pub(crate) fn newline(doc: &Document, selection: TextRange) -> Option<TextEdit> {
    let cx = Ctx::new(doc);
    let (s, e) = cx.sel(selection);
    list::newline(&cx, s, e)
}

pub(crate) fn indent(doc: &Document, selection: TextRange, outdent: bool) -> Option<TextEdit> {
    let cx = Ctx::new(doc);
    let (s, e) = cx.sel(selection);
    list::indent(&cx, s, e, outdent)
}

pub(crate) fn toggle_task(doc: &Document, at: u32) -> Option<TextEdit> {
    let cx = Ctx::new(doc);
    list::toggle_task(&cx, at)
}

// ----- splices ------------------------------------------------------------------------------

/// Replace `text[at..at + remove]` with `insert`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Splice {
    pub at: usize,
    pub remove: usize,
    pub insert: String,
}

impl Splice {
    pub fn insert(at: usize, s: impl Into<String>) -> Self {
        Self { at, remove: 0, insert: s.into() }
    }
    pub fn delete(at: usize, remove: usize) -> Self {
        Self { at, remove, insert: String::new() }
    }
    pub fn replace(at: usize, remove: usize, s: impl Into<String>) -> Self {
        Self { at, remove, insert: s.into() }
    }
}

/// Where old offset `p` ends up after all `splices` (sorted, non-overlapping). A position
/// inside removed text goes to the start of its replacement (or its end if `after`); a
/// position exactly at a pure insertion goes before it (or after it if `after`).
pub(crate) fn map_pos(splices: &[Splice], p: usize, after: bool) -> usize {
    let mut delta: isize = 0;
    for sp in splices {
        if p < sp.at {
            break;
        }
        if p == sp.at {
            if sp.remove == 0 {
                if after {
                    delta += sp.insert.len() as isize;
                }
                continue;
            }
            break;
        }
        if p >= sp.at + sp.remove {
            delta += sp.insert.len() as isize - sp.remove as isize;
        } else {
            let base = (sp.at as isize + delta) as usize;
            return if after { base + sp.insert.len() } else { base };
        }
    }
    (p as isize + delta) as usize
}

/// Sort splices and merge those that touch or overlap into one (an insertion at the same
/// place as another splice keeps its place in the sorted order).
pub(crate) fn normalize(mut v: Vec<Splice>) -> Vec<Splice> {
    v.sort_by_key(|s| (s.at, s.remove));
    let mut out: Vec<Splice> = Vec::with_capacity(v.len());
    for sp in v {
        match out.last_mut() {
            Some(last) if sp.at < last.at + last.remove => {
                // Overlap: extend the previous splice over this one.
                let end = (last.at + last.remove).max(sp.at + sp.remove);
                last.remove = end - last.at;
                last.insert.push_str(&sp.insert);
            }
            _ => out.push(sp),
        }
    }
    out
}

// ----- context ------------------------------------------------------------------------------

pub(crate) struct Ctx<'a> {
    pub doc: &'a Document,
    pub text: &'a str,
    pub b: &'a [u8],
    pub a: &'a Analysis,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Task {
    pub start: usize,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct Marker {
    pub start: usize,
    /// After the marker characters (`-`, `12.`).
    pub end: usize,
    pub ordered: bool,
    pub number: u64,
    /// `-`, `+`, `*`, `.` or `)`.
    pub ch: u8,
    /// After the blanks that follow the marker.
    pub gap_end: usize,
    pub task: Option<Task>,
    /// Start of the item's text: after the marker, the checkbox and their blanks.
    pub content: usize,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct LineInfo {
    pub line: usize,
    pub start: usize,
    /// End of the content, before the line terminator.
    pub end: usize,
    /// After the block quote markers (and the blank that follows each).
    pub qp_end: usize,
    /// After the blanks that follow the quote markers.
    pub ind_end: usize,
    pub marker: Option<Marker>,
    /// Nothing but blanks after the quote markers.
    pub blank: bool,
}

impl LineInfo {
    pub fn has_quote(&self) -> bool {
        self.qp_end > self.start
    }

    pub fn list_kind(&self) -> ListKind {
        match &self.marker {
            None => ListKind::None,
            Some(m) if m.task.is_some() => ListKind::Task,
            Some(m) if m.ordered => ListKind::Ordered,
            Some(_) => ListKind::Bullet,
        }
    }

    /// Start of the text: after the list marker if there is one.
    pub fn content_start(&self) -> usize {
        self.marker.map_or(self.ind_end, |m| m.content)
    }
}

impl<'a> Ctx<'a> {
    pub fn new(doc: &'a Document) -> Self {
        Self { doc, text: doc.text(), b: doc.text().as_bytes(), a: doc.analysis() }
    }

    /// Selection in bytes: ordered, on code point boundaries, never inside a CRLF.
    pub fn sel(&self, r: TextRange) -> (usize, usize) {
        let (us, ue) = if r.start <= r.end { (r.start, r.end) } else { (r.end, r.start) };
        let mut s = self.doc.byte_snapped(us, false);
        let mut e = self.doc.byte_snapped(ue, true).max(s);
        let mid_crlf = |p: usize| p > 0 && p < self.b.len() && self.b[p - 1] == b'\r' && self.b[p] == b'\n';
        if s == e {
            if mid_crlf(s) {
                s -= 1;
                e = s;
            }
        } else {
            if mid_crlf(s) {
                s -= 1;
            }
            if mid_crlf(e) {
                e += 1;
            }
        }
        (s, e)
    }

    // ----- lines ----------------------------------------------------------------------------

    pub fn line_count(&self) -> usize {
        self.a.lines.count()
    }
    pub fn line_of(&self, p: usize) -> usize {
        self.a.lines.line_of(p.min(self.b.len()))
    }
    pub fn line_start(&self, line: usize) -> usize {
        self.a.lines.start(line)
    }
    pub fn line_end(&self, line: usize) -> usize {
        self.a.lines.line_range(line, self.b).1
    }
    /// Start of the next line (or the text length).
    pub fn next_start(&self, line: usize) -> usize {
        if line + 1 < self.line_count() { self.a.lines.start(line + 1) } else { self.b.len() }
    }

    /// The line terminator to use next to `line`: its own, else another one in the document.
    pub fn eol_near(&self, line: usize) -> &'static str {
        let own = &self.text[self.line_end(line)..self.next_start(line)];
        let kind = |s: &str| match s {
            "\r\n" => Some("\r\n"),
            "\n" => Some("\n"),
            "\r" => Some("\r"),
            _ => None,
        };
        if let Some(k) = kind(own) {
            return k;
        }
        let mut l = line;
        while l > 0 {
            l -= 1;
            if let Some(k) = kind(&self.text[self.line_end(l)..self.next_start(l)]) {
                return k;
            }
        }
        "\n"
    }

    /// First and last line a line-based command touches: a selection that ends at the very
    /// start of a line does not include that line.
    pub fn affected(&self, s: usize, e: usize) -> (usize, usize) {
        let first = self.line_of(s);
        let mut last = self.line_of(e);
        if e > s && last > first && e == self.line_start(last) {
            last -= 1;
        }
        (first, last)
    }

    /// Spans that touch `lo..=hi` (start <= hi, end >= lo), in document order. Cost is local
    /// to the position, not the document, unless a span encloses most of it.
    pub fn spans_touching(&self, lo: usize, hi: usize) -> Vec<&'a crate::analysis::ISpan> {
        let a = self.a;
        let upper = a.spans.partition_point(|s| s.start <= hi);
        let mut i = upper;
        let mut out = Vec::new();
        while i > 0 && a.prefix_max_end[i - 1] >= lo {
            i -= 1;
            if a.spans[i].end >= lo {
                out.push(&a.spans[i]);
            }
        }
        out.reverse();
        out
    }

    /// The leaf block containing byte `pos`.
    pub fn leaf_block_at(&self, pos: usize) -> Option<&'a IBlock> {
        let blocks = &self.a.blocks;
        let i = blocks.partition_point(|b| b.start <= pos);
        blocks[i.saturating_sub(4)..i].iter().rev().find(|b| b.start <= pos && pos < b.end)
    }

    /// Is the text of this line (from `pos`) code, HTML, front matter or a table row, which
    /// block-level formatting should leave alone?
    pub fn is_opaque_block(&self, pos: usize) -> bool {
        self.leaf_block_at(pos).is_some_and(|b| {
            matches!(b.kind, BlockKind::CodeBlock | BlockKind::HtmlBlock | BlockKind::FrontMatter | BlockKind::Table)
        })
    }

    pub fn info(&self, line: usize) -> LineInfo {
        let (start, end) = (self.line_start(line), self.line_end(line));
        let b = self.b;
        let mut i = start;
        loop {
            let mut j = i;
            let mut n = 0;
            while j < end && b[j] == b' ' && n < 3 {
                j += 1;
                n += 1;
            }
            if j < end && b[j] == b'>' {
                i = j + 1;
                if i < end && b[i] == b' ' {
                    i += 1;
                }
            } else {
                break;
            }
        }
        let qp_end = i;
        while i < end && matches!(b[i], b' ' | b'\t') {
            i += 1;
        }
        let ind_end = i;
        let blank = ind_end >= end;
        let marker = if blank { None } else { self.parse_marker(ind_end, end) };
        LineInfo { line, start, end, qp_end, ind_end, marker, blank }
    }

    fn parse_marker(&self, i: usize, end: usize) -> Option<Marker> {
        let b = self.b;
        let ws = |p: usize| p == end || matches!(b[p], b' ' | b'\t');
        let (m_end, ordered, number, ch) = match b[i] {
            c @ (b'-' | b'+' | b'*') if ws(i + 1) => (i + 1, false, 0, c),
            b'0'..=b'9' => {
                let mut j = i;
                while j < end && b[j].is_ascii_digit() {
                    j += 1;
                }
                if j - i > 9 || j >= end || !matches!(b[j], b'.' | b')') || !ws(j + 1) {
                    return None;
                }
                let n = self.text[i..j].parse().unwrap_or(0);
                (j + 1, true, n, b[j])
            }
            _ => return None,
        };
        // A marker inside a leaf block (a paragraph that cannot be interrupted by it, code, a
        // table, a thematic break, ...) is text, not a list marker. An empty item is let through
        // unless it is in code and the like: CommonMark reads `a` + `-` as a setext heading, but
        // someone who just pressed Return in a list means a list item.
        let empty = (m_end..end).all(|k| matches!(b[k], b' ' | b'\t'));
        if let Some(bl) = self.leaf_block_at(i) {
            let opaque = matches!(
                bl.kind,
                BlockKind::CodeBlock | BlockKind::HtmlBlock | BlockKind::FrontMatter | BlockKind::Table
            );
            if !empty || opaque {
                return None;
            }
        }
        let mut g = m_end;
        while g < end && matches!(b[g], b' ' | b'\t') {
            g += 1;
        }
        let spaces = g - m_end;
        let gap_end = if g >= end { end } else if spaces >= 5 { m_end + 1 } else { g };
        let mut task = None;
        let mut content = gap_end;
        if gap_end + 3 <= end
            && b[gap_end] == b'['
            && matches!(b[gap_end + 1], b' ' | b'x' | b'X')
            && b[gap_end + 2] == b']'
            && (gap_end + 3 == end || matches!(b[gap_end + 3], b' ' | b'\t'))
        {
            task = Some(Task { start: gap_end });
            content = gap_end + 3;
            while content < end && matches!(b[content], b' ' | b'\t') {
                content += 1;
            }
        }
        Some(Marker { start: i, end: m_end, ordered, number, ch, gap_end, task, content })
    }

    /// Display width of blanks (tab stops every 4 columns).
    pub fn ws_width(&self, s: usize, e: usize) -> usize {
        let mut w = 0;
        for &c in &self.b[s..e] {
            if c == b'\t' {
                w = (w / 4 + 1) * 4;
            } else {
                w += 1;
            }
        }
        w
    }

    // ----- results --------------------------------------------------------------------------

    /// Turn splices plus the selection after the edit (in NEW-text byte offsets) into a
    /// [`TextEdit`]. No splices: a selection-only edit (`sel` is then in old = new text).
    pub fn finish(&self, splices: Vec<Splice>, sel: (usize, usize)) -> TextEdit {
        let splices = normalize(splices);
        let (hs, he) = match (splices.first(), splices.last()) {
            (Some(f), Some(l)) => (f.at, l.at + l.remove),
            _ => (sel.0.min(self.b.len()), sel.0.min(self.b.len())),
        };
        let mut repl = String::new();
        let mut pos = hs;
        for sp in &splices {
            repl.push_str(&self.text[pos..sp.at]);
            repl.push_str(&sp.insert);
            pos = sp.at + sp.remove;
        }
        // Shrink to what actually changes.
        let old = &self.text[hs..he];
        let mut pre = old.bytes().zip(repl.bytes()).take_while(|(a, b)| a == b).count();
        while !(old.is_char_boundary(pre) && repl.is_char_boundary(pre)) {
            pre -= 1;
        }
        let max_suf = old.len().min(repl.len()) - pre;
        let mut suf = old.bytes().rev().zip(repl.bytes().rev()).take(max_suf).take_while(|(a, b)| a == b).count();
        while !(old.is_char_boundary(old.len() - suf) && repl.is_char_boundary(repl.len() - suf)) {
            suf -= 1;
        }
        // Never start or end the edit between the halves of a CRLF.
        let mid = |p: usize| p > 0 && p < self.b.len() && self.b[p - 1] == b'\r' && self.b[p] == b'\n';
        while pre > 0 && mid(hs + pre) {
            pre -= 1;
        }
        while suf > 0 && mid(he - suf) {
            suf -= 1;
        }
        let (es, ee) = (hs + pre, he - suf);
        let repl = &repl[pre..repl.len() - suf];

        let new_len = self.b.len() - (ee - es) + repl.len();
        let conv = |nb: usize| -> u32 {
            let nb = nb.min(new_len);
            let doc = self.doc;
            if nb <= es {
                doc.unit_of(nb)
            } else if nb <= es + repl.len() {
                let mut k = nb - es;
                while !repl.is_char_boundary(k) {
                    k -= 1;
                }
                doc.unit_of(es) + doc.units_in(&repl[..k])
            } else {
                let ob = nb - repl.len() + (ee - es);
                doc.unit_of(ob) + doc.units_in(repl) - (doc.unit_of(ee) - doc.unit_of(es))
            }
        };
        let (a, b) = (conv(sel.0), conv(sel.1));
        TextEdit {
            range: TextRange::new(self.doc.unit_of(es), self.doc.unit_of(ee)),
            replacement: repl.to_owned(),
            selection: TextRange::new(a.min(b), a.max(b)),
        }
    }
}
