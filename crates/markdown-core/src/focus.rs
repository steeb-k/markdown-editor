//! Focus mode: which text stays at full strength for a selection.
//!
//! The unit is a leaf block (paragraph scope) or a sentence inside one (sentence scope). Both
//! are *line based at their edges*: a unit starts at the beginning of its first line and ends
//! at the end of its last, so list markers, `>` prefixes, indentation and heading `#`s light
//! up with their text.
//!
//! # Sentences
//!
//! Sentences come from Unicode sentence segmentation (UAX #29, `unicode-segmentation`),
//! applied to a *flattened* copy of the block that is built for the purpose:
//!
//! * prose is kept as it is;
//! * a soft line break (with its container prefix) becomes one space, so a sentence runs on
//!   across lines of a paragraph, a quote or a list item;
//! * inline code, raw inline HTML, images and bare URLs become one U+FFFC each (neither a
//!   letter nor a terminator, so they neither join a sentence to the next nor split one);
//! * all other markup (`**`, link brackets and destinations, list markers, footnote
//!   references...) is left out, so `**Bold.** Next` segments as `Bold. Next`.
//!
//! The cuts found in the flat text are carried back to the document. The sentences *partition*
//! the unit: sentence `i` runs from cut `i` to cut `i + 1`, the first starts at the unit's
//! first line start and the last ends at its last line end. Between two sentences:
//!
//! * trailing whitespace, a line break included, belongs to the sentence before (UAX #29's
//!   own choice);
//! * markup that closes an inline element opened inside the sentence before (the `**` of
//!   `**Bold.**Next`) belongs to it; any other markup (the `**` of `Done. **Next**`, the `> `
//!   of the next line) belongs to the sentence after.
//!
//! A caret belongs to the sentence whose range contains it, one that stands exactly on a cut
//! to the sentence that starts there. Every caret position of a sentence therefore gives the
//! same answer, and the end of the document belongs to the last sentence. Abbreviations are
//! whatever UAX #29 says (`Dr. Smith` splits only when a capital follows, as in the standard).
//!
//! Headings and list items hold their own sentences. Code blocks, tables, front matter, raw
//! HTML blocks and thematic breaks are focused whole, in either scope.
//!
//! # Selections
//!
//! A non-empty selection lights up every unit it overlaps, and the selection itself; touching
//! ranges are merged. A caret on a blank line, or between blocks, lights up nothing.

use unicode_segmentation::UnicodeSegmentation;

use crate::analysis::Analysis;
use crate::document::Document;
use crate::types::*;

/// A block longer than this is segmented only around the caret (and the sentence there ends
/// at the edge of that window if it reaches it): a paragraph of a megabyte must not cost
/// milliseconds on every caret move.
const GIANT_BLOCK: usize = 48 * 1024;
const GIANT_REACH: usize = 16 * 1024;

/// A leaf block's lines: from the start of its first line to the end of its last.
fn extent(a: &Analysis, b: &[u8], i: usize) -> (usize, usize) {
    let bl = &a.blocks[i];
    let start = a.lines.line_start(bl.start);
    let last = bl.end.saturating_sub(1).max(bl.start);
    let (_, line_end) = a.lines.line_range(a.lines.line_of(last), b);
    (start, line_end.max(bl.end))
}

/// First block index in `0..n` for which `pred` is false (`pred` must be monotone).
fn partition(n: usize, pred: impl Fn(usize) -> bool) -> usize {
    let (mut lo, mut hi) = (0, n);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if pred(mid) { lo = mid + 1 } else { hi = mid }
    }
    lo
}

pub(crate) fn focus_ranges(doc: &Document, selection: TextRange, scope: FocusScope, within: Option<TextRange>) -> Vec<TextRange> {
    let a = doc.analysis();
    let b = doc.text().as_bytes();
    let n = a.blocks.len();
    let (s0, s1) = if selection.start <= selection.end { (selection.start, selection.end) } else { (selection.end, selection.start) };
    // A position between the CR and the LF of a line break is the one before the CR.
    let unsplit = |p: usize| if p > 0 && b.get(p) == Some(&b'\n') && b[p - 1] == b'\r' { p - 1 } else { p };
    let sel_a = unsplit(doc.byte_snapped(s0, false));
    let sel_b = if s0 == s1 { sel_a } else { unsplit(doc.byte_snapped(s1, true)) };
    let empty = sel_a == sel_b;
    let window = doc.within_bytes(within);

    let mut found: Vec<(usize, usize)> = Vec::new();
    let unit = |i: usize, found: &mut Vec<(usize, usize)>| {
        let (es, ee) = extent(a, b, i);
        let sentence_kind = matches!(a.blocks[i].kind, BlockKind::Paragraph | BlockKind::Heading);
        if scope == FocusScope::Paragraph || !sentence_kind {
            found.push((es, ee));
            return;
        }
        let (mut bs, mut be) = (es, ee);
        if empty && be - bs > GIANT_BLOCK {
            let lo = sel_a.saturating_sub(GIANT_REACH).max(bs);
            let hi = (sel_a + GIANT_REACH).min(be);
            bs = a.lines.line_start(lo);
            be = a.lines.line_range(a.lines.line_of(hi.min(be)), b).1.max(sel_a.min(be));
        }
        let cuts = sentence_cuts(doc, bs, be);
        let sentences = cuts.len() - 1;
        if empty {
            let j = cuts[..sentences].partition_point(|&c| c <= sel_a).saturating_sub(1);
            found.push((cuts[j], cuts[j + 1]));
        } else {
            for j in 0..sentences {
                if cuts[j] < sel_b && cuts[j + 1] > sel_a {
                    found.push((cuts[j], cuts[j + 1]));
                }
            }
        }
    };

    if empty {
        let i = partition(n, |i| extent(a, b, i).1 < sel_a);
        if i < n && extent(a, b, i).0 <= sel_a {
            unit(i, &mut found);
        }
    } else {
        let lo = window.map_or(sel_a, |w| w.0.max(sel_a));
        let hi = window.map_or(sel_b, |w| w.1.min(sel_b));
        let mut i = partition(n, |i| extent(a, b, i).1 <= lo);
        while i < n {
            let (es, _) = extent(a, b, i);
            if es >= hi.max(lo + 1) {
                break;
            }
            unit(i, &mut found);
            i += 1;
        }
        found.push((sel_a, sel_b));
    }

    found.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::with_capacity(found.len());
    for (s, e) in found {
        match merged.last_mut() {
            Some(last) if s <= last.1 => last.1 = last.1.max(e),
            _ => merged.push((s, e)),
        }
    }
    doc.convert_nested(&merged).into_iter().map(|(s, e)| TextRange::new(s, e)).collect()
}

enum Item {
    Prose,
    Placeholder,
}

/// The cuts that partition `bs..be` (a block's lines) into sentences: `cuts[0] == bs`, the last
/// is `be`, strictly increasing. At least one sentence.
fn sentence_cuts(doc: &Document, bs: usize, be: usize) -> Vec<usize> {
    let a = doc.analysis();
    let text = doc.text();
    let b = text.as_bytes();

    // What the block is made of.
    let mut items: Vec<(usize, usize, Item)> = Vec::new();
    let lo = a.prose.partition_point(|p| p.1 <= bs);
    for &(s, e) in &a.prose[lo..] {
        if s >= be {
            break;
        }
        items.push((s.max(bs), e.min(be), Item::Prose));
    }
    let (slo, shi) = doc.span_indices_bytes(Some((bs, be)));
    let mut inline: Vec<(usize, usize)> = Vec::new();
    let mut placeholder_end = 0;
    for sp in &a.spans[slo..shi] {
        if sp.start >= be || sp.end <= bs {
            continue;
        }
        match sp.kind {
            SpanKind::InlineCode | SpanKind::Html | SpanKind::Image => {}
            SpanKind::Link if b[sp.start] != b'[' => {}
            SpanKind::Link | SpanKind::Emphasis | SpanKind::Strong | SpanKind::Strikethrough => {
                inline.push((sp.start, sp.end));
                continue;
            }
            _ => continue,
        }
        if sp.start >= placeholder_end {
            placeholder_end = sp.end;
            items.push((sp.start.max(bs), sp.end.min(be), Item::Placeholder));
        }
    }
    items.sort_by_key(|&(s, e, _)| (s, e));

    // The flattened text, and for each of its characters where it came from.
    let mut flat = String::with_capacity(be - bs);
    let mut starts: Vec<usize> = Vec::new();
    let mut origin: Vec<(usize, usize)> = Vec::new();
    let mut push = |ch: char, from: usize, to: usize, flat: &mut String| {
        starts.push(flat.len());
        origin.push((from, to));
        flat.push(ch);
    };
    // Line breaks between the items (and inside prose, should a text hold one).
    let breaks = |from: usize, to: usize, push: &mut dyn FnMut(char, usize, usize, &mut String), flat: &mut String| {
        let mut i = from;
        while i < to {
            match b[i] {
                b'\r' if i + 1 < to && b[i + 1] == b'\n' => {
                    push(' ', i, i + 2, flat);
                    i += 2;
                }
                b'\n' | b'\r' => {
                    push(' ', i, i + 1, flat);
                    i += 1;
                }
                _ => i += 1,
            }
        }
    };
    let mut pos = bs;
    for (s, e, item) in items {
        let s = s.max(pos);
        if s >= e {
            continue;
        }
        breaks(pos, s, &mut push, &mut flat);
        match item {
            Item::Placeholder => push('\u{FFFC}', s, e, &mut flat),
            Item::Prose => {
                let mut off = s;
                let mut chars = text[s..e].chars().peekable();
                while let Some(ch) = chars.next() {
                    let w = ch.len_utf8();
                    match ch {
                        '\r' if chars.peek() == Some(&'\n') => {
                            chars.next();
                            push(' ', off, off + 2, &mut flat);
                            off += 2;
                        }
                        '\n' | '\r' => {
                            push(' ', off, off + 1, &mut flat);
                            off += 1;
                        }
                        _ => {
                            push(ch, off, off + w, &mut flat);
                            off += w;
                        }
                    }
                }
            }
        }
        pos = e;
    }
    breaks(pos, be, &mut push, &mut flat);

    let mut cuts = vec![bs];
    if !flat.is_empty() {
        for (at, _) in flat.split_sentence_bound_indices().skip(1) {
            let Ok(c) = starts.binary_search(&at) else { continue };
            if c == 0 {
                continue;
            }
            let first = origin[c].0;
            let before = origin[c - 1].1;
            // Closing markup of an element that opened before the cut goes with the sentence
            // that ends; everything else with the one that starts.
            let mut cut = before;
            for &(s, e) in &inline {
                if s < before && e > before {
                    cut = cut.max(e);
                }
            }
            let cut = cut.min(first);
            if cut > *cuts.last().unwrap() && cut < be {
                cuts.push(cut);
            }
        }
    }
    cuts.push(be);
    cuts
}
