//! The parsed document as the plain-text and Word writers walk it: pulldown-cmark's events with the end of every
//! start, the footnotes numbered as a reader meets them, and the runs of text where bare URLs and wikilinks hide.
//!
//! The HTML renderer keeps its own copy of this (it also renders fragments and sanitizes); these two writers share
//! one so they cannot disagree with each other about what a construct is.

use std::collections::HashMap;
use std::ops::Range;
use std::panic::{catch_unwind, AssertUnwindSafe};

use pulldown_cmark::{Event, Parser, Tag};

use crate::analysis::options;
use crate::{autolink, wiki};

pub(crate) type Item<'a> = (Event<'a>, Range<usize>);

pub(crate) struct Tree<'a> {
    pub src: &'a str,
    pub events: Vec<Item<'a>>,
    /// For a start event, the index of its end event; for any other, its own index.
    pub end_of: Vec<usize>,
}

impl<'a> Tree<'a> {
    /// The events of `src`, or `None` when the parser panics (pulldown-cmark 0.13.4 can; see `analysis.rs`).
    pub fn parse(src: &'a str) -> Option<Tree<'a>> {
        let events = catch_unwind(AssertUnwindSafe(|| Parser::new_ext(src, options()).into_offset_iter().collect::<Vec<_>>())).ok()?;
        let mut end_of: Vec<usize> = (0..events.len()).collect();
        let mut stack = Vec::new();
        for (i, (ev, _)) in events.iter().enumerate() {
            match ev {
                Event::Start(_) => stack.push(i),
                Event::End(_) => {
                    if let Some(s) = stack.pop() {
                        end_of[s] = i;
                    }
                }
                _ => {}
            }
        }
        Some(Tree { src, events, end_of })
    }

    /// Whether the event at `i` belongs to a line of text rather than being a block of its own.
    pub fn is_inline(&self, i: usize) -> bool {
        match &self.events[i].0 {
            Event::Text(_)
            | Event::Code(_)
            | Event::InlineMath(_)
            | Event::DisplayMath(_)
            | Event::SoftBreak
            | Event::HardBreak
            | Event::FootnoteReference(_)
            | Event::InlineHtml(_) => true,
            Event::Start(t) => matches!(
                t,
                Tag::Emphasis | Tag::Strong | Tag::Strikethrough | Tag::Link { .. } | Tag::Image { .. } | Tag::Subscript | Tag::Superscript
            ),
            _ => false,
        }
    }

    /// The index after the event at `i` and everything it holds.
    pub fn after(&self, i: usize) -> usize {
        self.end_of[i] + 1
    }

    /// The front matter's `title:`, else the text of the first heading: what the HTML export names its page by.
    pub fn title(&self) -> Option<String> {
        let plain = |from: usize, to: usize| {
            let mut s = String::new();
            for (ev, _) in &self.events[from..to] {
                match ev {
                    Event::Text(t) | Event::Code(t) => s.push_str(t),
                    Event::SoftBreak | Event::HardBreak => s.push(' '),
                    _ => {}
                }
            }
            s
        };
        // Read as the `template:` key is, so a quoted title loses its quotes and nothing else (`'It''s'`, a comment).
        if let Some(title) = crate::front_matter::front_matter_value(self.src, "title") {
            return Some(title);
        }
        let i = self.events.iter().position(|(e, _)| matches!(e, Event::Start(Tag::Heading { .. })))?;
        Some(plain(i + 1, self.end_of[i])).filter(|t| !t.trim().is_empty())
    }

    fn one_to_one(&self, k: usize) -> bool {
        matches!(&self.events[k], (Event::Text(t), r) if self.src.get(r.clone()) == Some(&**t))
    }

    /// The run of text starting at event `i` (events up to `to`), cut where a bare URL or a wikilink lies, and the
    /// index after it. Inside a link, or where the text is not the source's (an escape, an entity), it is one piece
    /// of text, as the HTML renderer treats it.
    pub fn text_run(&self, i: usize, to: usize, in_link: bool) -> (Vec<Piece>, usize) {
        let Event::Text(t) = &self.events[i].0 else { return (Vec::new(), i + 1) };
        if in_link || !self.one_to_one(i) {
            return (vec![Piece::Text(t.to_string())], i + 1);
        }
        let mut j = i + 1;
        while j < to && self.one_to_one(j) && self.events[j].1.start == self.events[j - 1].1.end {
            j += 1;
        }
        let (s, e) = (self.events[i].1.start, self.events[j - 1].1.end);
        let links = autolink::find_in(self.src, s, e);
        let exclude: Vec<(usize, usize)> = links.iter().map(|l| (l.start, l.end)).collect();
        let found = wiki::find_in(self.src, s, e, &exclude, false);
        let mut cuts: Vec<(usize, usize, Piece)> = Vec::new();
        for l in &links {
            cuts.push((l.start, l.end, Piece::Url { label: self.src[l.start..l.end].to_owned(), destination: l.destination.clone() }));
        }
        for f in &found {
            if let wiki::Found::Wikilink(w) = f {
                cuts.push((w.start, w.end, Piece::Text(wiki::wikilink_shown(self.src, w).to_owned())));
            }
        }
        cuts.sort_by_key(|c| c.0);
        let mut pieces = Vec::new();
        let mut pos = s;
        for (start, end, piece) in cuts {
            if start > pos {
                pieces.push(Piece::Text(self.src[pos..start].to_owned()));
            }
            pieces.push(piece);
            pos = end;
        }
        if pos < e {
            pieces.push(Piece::Text(self.src[pos..e].to_owned()));
        }
        (pieces, j)
    }
}

/// A part of a run of text.
pub(crate) enum Piece {
    Text(String),
    /// A bare URL: its text and the address to link to.
    Url { label: String, destination: String },
}

/// The footnotes: where each one's definition lies and the order a reader meets them in, which is their number.
pub(crate) struct Notes {
    /// Name -> the events of the definition's content (the first definition of a name wins, as in the parser).
    pub defs: HashMap<String, Range<usize>>,
    /// Names in the order of first reference.
    pub order: Vec<String>,
}

impl Notes {
    pub fn new(tree: &Tree) -> Notes {
        let mut defs = HashMap::new();
        for (i, (ev, _)) in tree.events.iter().enumerate() {
            if let Event::Start(Tag::FootnoteDefinition(name)) = ev {
                defs.entry(name.to_string()).or_insert(i + 1..tree.end_of[i]);
            }
        }
        Notes { defs, order: Vec::new() }
    }

    /// The 1-based number of the note `name`, given the next one when it is met for the first time.
    pub fn number(&mut self, name: &str) -> usize {
        match self.order.iter().position(|n| n == name) {
            Some(p) => p + 1,
            None => {
                self.order.push(name.to_owned());
                self.order.len()
            }
        }
    }
}
