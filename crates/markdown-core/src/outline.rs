//! The text of a heading for an outline: what a reader reads in the rendered heading, without rendering the
//! document. The heading's own source is parsed again; what only the whole document decides is passed in from
//! the analysis: which bracketed pieces are reference links (their definitions are elsewhere) and where footnote
//! references are. Wikilinks show their label, as the preview and Live mode show them.

use pulldown_cmark::{BrokenLink, CowStr, Event, Parser, Tag, TagEnd};

use crate::analysis::options;
use crate::wiki;

/// What the analysis of the whole document knows about a heading, in byte offsets relative to its source.
#[derive(Default)]
pub(crate) struct HeadingContext {
    /// Where a link or an image starts (a reference link resolves only against the whole document).
    pub links: Vec<usize>,
    /// Footnote references: the renderer shows a number, not text.
    pub footnotes: Vec<(usize, usize)>,
}

/// The plain text of the heading written as `source` (its block's source range). `contained`: the heading is
/// inside a quote or a list item, so lines after the first of a setext heading may start with the container's
/// markers, which are not part of it.
pub(crate) fn heading_text(source: &str, contained: bool, context: &HeadingContext) -> String {
    // (offset in the normalized source, bytes removed before it): to map back to `source`'s offsets.
    let mut shifts: Vec<(usize, usize)> = Vec::new();
    let normalized;
    let text = if contained && source.contains(['\n', '\r']) {
        let mut lines = source.split_inclusive(['\n', '\r']);
        let mut out = String::with_capacity(source.len());
        if let Some(first) = lines.next() {
            out.push_str(first);
        }
        let mut removed = 0;
        for line in lines {
            let kept = line.trim_start_matches([' ', '\t', '>']);
            removed += line.len() - kept.len();
            shifts.push((out.len(), removed));
            out.push_str(kept);
        }
        normalized = out;
        normalized.as_str()
    } else {
        source
    };
    let original = |at: usize| at + shifts.iter().rev().find(|s| s.0 <= at).map_or(0, |s| s.1);
    // pulldown-cmark panics on some inputs (see `analyze`): a heading that does that is shown as written.
    let parsed = std::panic::catch_unwind(|| {
        let mut resolve = |l: BrokenLink<'_>| {
            context.links.contains(&original(l.span.start)).then_some((CowStr::Borrowed(""), CowStr::Borrowed("")))
        };
        let events: Vec<(Event<'_>, std::ops::Range<usize>)> =
            Parser::new_with_broken_link_callback(text, options(), Some(&mut resolve)).into_offset_iter().collect();
        let in_footnote = |r: &std::ops::Range<usize>| {
            let (s, e) = (original(r.start), original(r.end.max(r.start + 1) - 1) + 1);
            context.footnotes.iter().any(|f| f.0 <= s && e <= f.1)
        };
        let one_to_one = |k: usize| matches!(&events[k], (Event::Text(t), r) if text.get(r.clone()) == Some(&**t));
        let mut out = String::new();
        let mut inside = false;
        let mut link_depth = 0;
        let mut i = 0;
        while i < events.len() {
            match &events[i] {
                (Event::Start(Tag::Heading { .. }), _) => inside = true,
                (Event::End(TagEnd::Heading(_)), _) => break,
                (Event::Start(Tag::Link { .. }), _) => link_depth += 1,
                (Event::End(TagEnd::Link), _) => link_depth -= 1,
                (Event::Text(_), r) if inside && in_footnote(r) => {}
                (Event::Text(t), _) if inside && (link_depth > 0 || !one_to_one(i)) => out.push_str(t),
                (Event::Text(_), r) if inside => {
                    // A run of text as it is in the source, searched as one piece for wikilinks, as the renderer does.
                    let mut j = i + 1;
                    while j < events.len() && one_to_one(j) && events[j].1.start == events[j - 1].1.end && !in_footnote(&events[j].1) {
                        j += 1;
                    }
                    let (s, e) = (r.start, events[j - 1].1.end);
                    let mut pos = s;
                    for found in wiki::find_in(text, s, e, &[], false) {
                        if let wiki::Found::Wikilink(w) = found {
                            out.push_str(&text[pos..w.start]);
                            out.push_str(wikilink_shown(text, &w));
                            pos = w.end;
                        }
                    }
                    out.push_str(&text[pos..e]);
                    i = j;
                    continue;
                }
                (Event::Code(t), _) if inside => out.push_str(t),
                (Event::SoftBreak | Event::HardBreak, _) if inside => out.push(' '),
                _ => {}
            }
            i += 1;
        }
        out
    });
    match parsed {
        Ok(text) => text.trim().to_owned(),
        Err(_) => source.trim_matches(|c: char| c == '#' || c.is_whitespace()).to_owned(),
    }
}

/// What the preview shows for a wikilink: the label, else the target, else the heading.
fn wikilink_shown<'a>(text: &'a str, w: &wiki::Wikilink) -> &'a str {
    let shown = match w.label {
        Some(l) => &text[l.0..l.1],
        None => &text[w.target.0..w.target.1],
    };
    if shown.is_empty() { w.heading.map_or("", |h| &text[h.0..h.1]) } else { shown }
}
