//! Plain-text export: the text a reader would want from the document, with no markup left in it.
//!
//! Walked from the same events as the HTML renderer's (see [`crate::walk`]). Front matter and raw HTML are left out;
//! headings are lines of their own, paragraphs are separated by one blank line, lists keep their markers (`- `, `1. `,
//! `[ ]`/`[x]` for tasks) and nest by two spaces, quotes and code are indented by four, tables are columns padded to
//! their widest cell, links are their label (and the address after it in parentheses when the label is not the
//! address), pictures are their alt text, and footnotes are `[n]` in the text and `[n] note` at the end.

use pulldown_cmark::{Alignment, Event, Tag};
use unicode_width::UnicodeWidthStr;

use crate::document::Document;
use crate::walk::{Notes, Piece, Tree};

impl Document {
    /// The document as plain text: `\n` line endings, one trailing newline (none for an empty document).
    pub fn render_plain(&self) -> String {
        let text = self.text();
        let Some(tree) = Tree::parse(text) else {
            // The parser failed on this text: it is what the reader gets, as it is.
            return text.replace("\r\n", "\n");
        };
        let mut plain = Plain { notes: Notes::new(&tree), tree: &tree };
        let mut blocks = plain.blocks(0, tree.events.len());
        // Notes may refer to further notes: the list grows as it is written.
        let mut k = 0;
        let mut notes: Vec<Vec<String>> = Vec::new();
        while k < plain.notes.order.len() {
            let name = plain.notes.order[k].clone();
            k += 1;
            let Some(range) = plain.notes.defs.get(&name).cloned() else { continue };
            let body = plain.blocks(range.start, range.end);
            let mut lines: Vec<String> = Vec::new();
            for (n, block) in body.into_iter().enumerate() {
                lines.extend(block.into_iter().enumerate().map(|(i, l)| match (n, i) {
                    (0, 0) => format!("[{k}] {l}"),
                    _ if l.is_empty() => l,
                    _ => format!("    {l}"),
                }));
                // Paragraphs of one note are told apart by a blank line inside it.
                lines.push(String::new());
            }
            while lines.last().is_some_and(|l| l.is_empty()) {
                lines.pop();
            }
            if lines.is_empty() {
                lines.push(format!("[{k}]"));
            }
            notes.push(lines);
        }
        // The notes sit together, one after another, after the text.
        if !notes.is_empty() {
            blocks.push(notes.into_iter().flatten().collect());
        }
        let blocks: Vec<Vec<String>> = blocks.into_iter().filter(|b| !b.is_empty()).collect();
        let mut out = String::new();
        for (n, block) in blocks.iter().enumerate() {
            if n > 0 {
                out.push('\n');
            }
            for line in block {
                out.push_str(line);
                out.push('\n');
            }
        }
        out
    }
}

struct Plain<'t, 'a> {
    tree: &'t Tree<'a>,
    notes: Notes,
}

fn indented(lines: Vec<String>, by: &str) -> Vec<String> {
    lines.into_iter().map(|l| if l.is_empty() { l } else { format!("{by}{l}") }).collect()
}

fn width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

impl Plain<'_, '_> {
    /// The blocks of events `from..to`, each as its lines.
    fn blocks(&mut self, from: usize, to: usize) -> Vec<Vec<String>> {
        let tree = self.tree;
        let mut out: Vec<Vec<String>> = Vec::new();
        let mut run: Option<usize> = None;
        let mut i = from;
        while i < to {
            if tree.is_inline(i) {
                run.get_or_insert(i);
                i = if matches!(tree.events[i].0, Event::Start(_)) { tree.after(i) } else { i + 1 };
                continue;
            }
            if let Some(start) = run.take() {
                self.paragraph(start, i, &mut out);
            }
            let end = tree.end_of[i];
            match &tree.events[i].0 {
                Event::Start(Tag::Paragraph) => self.paragraph(i + 1, end, &mut out),
                Event::Start(Tag::Heading { .. }) => {
                    let line = self.inline(i + 1, end, false).replace('\n', " ");
                    out.push(vec![line.trim().to_owned()]);
                }
                Event::Start(Tag::BlockQuote(_)) => {
                    let inner = self.blocks(i + 1, end);
                    out.push(indented(join(inner, true), "    "));
                }
                Event::Start(Tag::CodeBlock(_)) => {
                    let mut code = String::new();
                    for (e, _) in &tree.events[i + 1..end] {
                        if let Event::Text(t) = e {
                            code.push_str(t);
                        }
                    }
                    let code = code.strip_suffix('\n').unwrap_or(&code);
                    out.push(indented(code.split('\n').map(str::to_owned).collect(), "    "));
                }
                Event::Start(Tag::List(start)) => {
                    let lines = self.list(i, *start);
                    out.push(lines);
                }
                Event::Start(Tag::Table(aligns)) => {
                    let aligns = aligns.clone();
                    out.push(self.table(i, &aligns));
                }
                Event::Start(Tag::DefinitionList) => out.extend(self.blocks(i + 1, end)),
                Event::Start(Tag::DefinitionListTitle) => {
                    let line = self.inline(i + 1, end, false).replace('\n', " ");
                    out.push(vec![line]);
                }
                Event::Start(Tag::DefinitionListDefinition) => {
                    let inner = self.blocks(i + 1, end);
                    out.push(indented(join(inner, true), "    "));
                }
                Event::Rule => out.push(vec!["---".to_owned()]),
                // Front matter, notes (listed at the end), raw HTML and anything else with no text of its own.
                _ => {}
            }
            i = if matches!(tree.events[i].0, Event::Start(_)) { tree.after(i) } else { i + 1 };
        }
        if let Some(start) = run {
            self.paragraph(start, to, &mut out);
        }
        out
    }

    fn paragraph(&mut self, from: usize, to: usize, out: &mut Vec<Vec<String>>) {
        let text = self.inline(from, to, false);
        let text = text.trim_matches(|c| c == '\n' || c == ' ');
        if !text.is_empty() {
            out.push(text.split('\n').map(str::to_owned).collect());
        }
    }

    /// A list with its markers, the item's own lines after the marker and the rest under it.
    fn list(&mut self, at: usize, start: Option<u64>) -> Vec<String> {
        let tree = self.tree;
        let end = tree.end_of[at];
        // Loose when any item holds a paragraph of its own: the items are then set apart by a blank line.
        let mut items: Vec<(usize, usize)> = Vec::new();
        let mut i = at + 1;
        while i < end {
            if matches!(tree.events[i].0, Event::Start(Tag::Item)) {
                items.push((i, tree.end_of[i]));
            }
            i = tree.after(i);
        }
        let has_paragraph = |&(s, e): &(usize, usize)| {
            let mut k = s + 1;
            while k < e {
                if matches!(tree.events[k].0, Event::Start(Tag::Paragraph)) {
                    return true;
                }
                k = if matches!(tree.events[k].0, Event::Start(_)) { tree.after(k) } else { k + 1 };
            }
            false
        };
        let loose = items.iter().any(has_paragraph);
        let mut lines: Vec<String> = Vec::new();
        for (n, (s, e)) in items.into_iter().enumerate() {
            let marker = match start {
                Some(first) => format!("{}. ", first + n as u64),
                None => "- ".to_owned(),
            };
            let (task, from) = match tree.events.get(s + 1) {
                Some((Event::TaskListMarker(c), _)) => (Some(*c), s + 2),
                _ => (None, s + 1),
            };
            // Within an item the blocks are set apart by a blank line only when the item holds paragraphs of its own.
            let mut body = join(self.blocks(from, e), has_paragraph(&(s, e)));
            if let Some(checked) = task {
                let box_ = if checked { "[x]" } else { "[ ]" };
                match body.first_mut() {
                    Some(first) => *first = format!("{box_} {first}"),
                    None => body.push(box_.to_owned()),
                }
            }
            if body.is_empty() {
                body.push(String::new());
            }
            if loose && n > 0 {
                lines.push(String::new());
            }
            for (k, l) in body.into_iter().enumerate() {
                lines.push(match (k, l.is_empty()) {
                    (0, _) => format!("{marker}{l}").trim_end().to_owned(),
                    (_, true) => l,
                    _ => format!("  {l}"),
                });
            }
        }
        lines
    }

    /// A table as columns padded to their widest cell, the header, a line of dashes, the rows.
    fn table(&mut self, at: usize, aligns: &[Alignment]) -> Vec<String> {
        let tree = self.tree;
        let end = tree.end_of[at];
        let mut rows: Vec<Vec<String>> = Vec::new();
        let mut i = at + 1;
        while i < end {
            if matches!(tree.events[i].0, Event::Start(Tag::TableHead | Tag::TableRow)) {
                let row_end = tree.end_of[i];
                let mut cells = Vec::new();
                let mut k = i + 1;
                while k < row_end {
                    if matches!(tree.events[k].0, Event::Start(Tag::TableCell)) {
                        cells.push(self.inline(k + 1, tree.end_of[k], false).replace('\n', " ").trim().to_owned());
                    }
                    k = tree.after(k);
                }
                rows.push(cells);
            }
            i = tree.after(i);
        }
        let columns = rows.iter().map(Vec::len).max().unwrap_or(0).max(aligns.len().min(1));
        let widths: Vec<usize> = (0..columns).map(|c| rows.iter().filter_map(|r| r.get(c)).map(|s| width(s)).max().unwrap_or(0).max(3)).collect();
        let pad = |cell: &str, c: usize| {
            let gap = widths[c].saturating_sub(width(cell));
            match aligns.get(c) {
                Some(Alignment::Right) => format!("{}{cell}", " ".repeat(gap)),
                Some(Alignment::Center) => format!("{}{cell}{}", " ".repeat(gap / 2), " ".repeat(gap - gap / 2)),
                _ => format!("{cell}{}", " ".repeat(gap)),
            }
        };
        let line = |cells: &[String]| (0..columns).map(|c| pad(cells.get(c).map_or("", String::as_str), c)).collect::<Vec<_>>().join("  ").trim_end().to_owned();
        let mut out = Vec::new();
        for (n, row) in rows.iter().enumerate() {
            out.push(line(row));
            if n == 0 {
                out.push(widths.iter().map(|w| "-".repeat(*w)).collect::<Vec<_>>().join("  "));
            }
        }
        out
    }

    /// The text of the inline events `from..to`.
    fn inline(&mut self, from: usize, to: usize, in_link: bool) -> String {
        let tree = self.tree;
        let mut s = String::new();
        let mut i = from;
        while i < to {
            match &tree.events[i].0 {
                Event::Text(_) => {
                    let (pieces, next) = tree.text_run(i, to, in_link);
                    for p in pieces {
                        match p {
                            Piece::Text(t) => s.push_str(&t),
                            Piece::Url { label, .. } => s.push_str(&label),
                        }
                    }
                    i = next;
                    continue;
                }
                Event::Code(t) | Event::InlineMath(t) | Event::DisplayMath(t) => s.push_str(t),
                Event::SoftBreak | Event::HardBreak => s.push('\n'),
                Event::FootnoteReference(name) => {
                    let n = self.notes.number(name);
                    s.push_str(&format!("[{n}]"));
                }
                Event::Start(Tag::Link { dest_url, link_type, .. }) => {
                    let end = tree.end_of[i];
                    let label = self.inline(i + 1, end, true);
                    let address = if *link_type == pulldown_cmark::LinkType::Email { format!("mailto:{dest_url}") } else { dest_url.to_string() };
                    let same = label.trim() == &**dest_url || label.trim() == address;
                    s.push_str(&label);
                    if !same && !address.is_empty() {
                        s.push_str(&format!(" ({address})"));
                    }
                    i = end + 1;
                    continue;
                }
                Event::Start(Tag::Image { .. }) => {
                    let end = tree.end_of[i];
                    s.push_str(&self.inline(i + 1, end, true).replace('\n', " "));
                    i = end + 1;
                    continue;
                }
                _ => {}
            }
            i += 1;
        }
        s
    }
}

/// The blocks as one list of lines, with a blank line between them when `apart`.
fn join(blocks: Vec<Vec<String>>, apart: bool) -> Vec<String> {
    let mut out = Vec::new();
    for (n, b) in blocks.into_iter().filter(|b| !b.is_empty()).enumerate() {
        if n > 0 && apart {
            out.push(String::new());
        }
        out.extend(b);
    }
    out
}
