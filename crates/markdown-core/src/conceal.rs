//! Live mode: which source a shell should not draw for a given selection, which lines
//! collapse, and what is drawn in its place.
//!
//! Everything is derived from the current analysis for the requested window, so the answer
//! is correct by construction after any edit (the dirty range of an edit speaks for spans
//! only; owners and blocks can change outside it).
//!
//! The rules, in short:
//! * a `Markup` span (and a link's destination, title included) is hidden unless the
//!   selection touches its owner; inline owners are touched at both edges, a caret
//!   immediately before or after `**bold**` reveals it;
//! * line-scoped markup (ATX `#`, quote `>`) is revealed by the line, fences and front
//!   matter delimiters by anywhere in their block, a setext underline by its heading;
//! * a non-empty selection reveals every owner it overlaps;
//! * never concealed: anything in a table, link reference definitions, footnote labels and
//!   references, raw HTML, indented code.

use std::ops::Range;

use crate::analysis::MarkupRole;
use crate::types::MarkupScope;
use crate::document::Document;
use crate::types::*;

pub(crate) fn compute(doc: &Document, selection: TextRange, within: Option<TextRange>) -> Concealment {
    let a = doc.analysis();
    let b = doc.text().as_bytes();
    let len = b.len();

    let (s0, s1) = if selection.start <= selection.end {
        (selection.start, selection.end)
    } else {
        (selection.end, selection.start)
    };
    let empty = s0 == s1;
    let sel_a = doc.byte_snapped(s0, false);
    let sel_b = if empty { sel_a } else { doc.byte_snapped(s1, true) };
    // An owner is touched by a caret at either edge; by a range only when they overlap.
    let touch = |o: (usize, usize)| {
        if empty {
            o.0 <= sel_a && sel_a <= o.1
        } else {
            sel_a < o.1 && o.0 < sel_b
        }
    };

    let window = doc.within_bytes(within);
    let in_window = |s: usize, e: usize| match window {
        None => true,
        Some((ws, we)) if ws == we => s <= ws && ws < e,
        Some((ws, we)) => s < we && e > ws,
    };
    // Look a little beyond the window: a list marker needs the task marker after it.
    let search = window.map(|(ws, we)| (ws.saturating_sub(64), (we + 64).min(len)));
    let (lo, hi) = doc.span_indices_bytes(search);
    let spans = &a.spans[lo..hi];

    // Task markers by start, with where the blanks after them end.
    let tasks: std::collections::HashMap<usize, usize> = spans
        .iter()
        .filter(|s| matches!(s.kind, SpanKind::TaskMarker { .. }))
        .map(|s| {
            let mut e = s.end;
            while e < len && matches!(b[e], b' ' | b'\t') {
                e += 1;
            }
            (s.start, e)
        })
        .collect();

    let mut hidden: Vec<Range<usize>> = Vec::new();
    let mut candidates: Vec<usize> = Vec::new(); // starts of lines that may collapse
    let mut decorations: Vec<(usize, usize, DecorationKind)> = Vec::new();
    let mut stack: Vec<(usize, SpanKind, usize)> = Vec::new(); // (end, kind, start) of enclosing spans

    let line_of = |pos: usize| a.lines.line_range(a.lines.line_of(pos.min(len)), b);
    let nearest = |stack: &[(usize, SpanKind, usize)], pred: &dyn Fn(SpanKind) -> bool| {
        stack.iter().rev().find(|(_, k, _)| pred(*k)).map(|&(e, _, s)| (s, e))
    };

    for sp in spans {
        while let Some(&(end, _, _)) = stack.last() {
            if end <= sp.start {
                stack.pop();
            } else {
                break;
            }
        }
        let in_table = stack.iter().any(|(_, k, _)| *k == SpanKind::Table);
        match sp.kind {
            SpanKind::Markup => {
                let Some(m) = sp.meta else { continue };
                if m.in_table || in_table || m.role == MarkupRole::Pinned {
                    continue;
                }
                let owner = match m.role {
                    MarkupRole::Fence => nearest(&stack, &|k| k == SpanKind::CodeBlock),
                    MarkupRole::FrontMatter => nearest(&stack, &|k| k == SpanKind::FrontMatter),
                    _ => None,
                }
                .unwrap_or(m.owner);
                // A setext underline is owned by its heading, up to the end of its own line (the
                // heading's range stops before the underline's trailing blanks).
                let owner = if m.scope == MarkupScope::Block && m.role == MarkupRole::Plain {
                    (owner.0, owner.1.max(line_of(sp.start).1))
                } else {
                    owner
                };
                if touch(owner) {
                    continue;
                }
                hidden.push(sp.start..sp.end);
                let fence_like = matches!(m.role, MarkupRole::Fence | MarkupRole::FrontMatter);
                if fence_like || (m.scope == MarkupScope::Block && m.role == MarkupRole::Plain) {
                    let (ls, le) = line_of(sp.start);
                    if fence_like && sp.end < le {
                        hidden.push(sp.end..le); // the info string and trailing blanks
                    }
                    candidates.push(ls);
                }
            }
            SpanKind::LinkDestination => {
                if in_table {
                    continue;
                }
                let Some(link) = nearest(&stack, &|k| matches!(k, SpanKind::Link | SpanKind::Image)) else {
                    continue; // a link reference definition: always visible
                };
                // `<url>`: only the brackets are syntax, the URL is the text.
                if b[link.0] == b'<' && link.0 + 1 == sp.start && link.1 == sp.end + 1 {
                    continue;
                }
                if !touch(link) {
                    hidden.push(sp.start..sp.end);
                }
            }
            SpanKind::ListMarker { ordered: false } => {
                if in_table {
                    continue;
                }
                let mut q = sp.end;
                while q < len && matches!(b[q], b' ' | b'\t') {
                    q += 1;
                }
                if let Some(&prefix_end) = tasks.get(&q) {
                    // A task item shows only its checkbox: the marker, the `[ ]` and the blanks
                    // around them are hidden, the checkbox is drawn at the bullet's place.
                    hidden.push(sp.start..prefix_end);
                } else {
                    decorations.push((sp.start, sp.end, DecorationKind::Bullet));
                }
            }
            SpanKind::TaskMarker { checked } if !in_table => {
                decorations.push((sp.start, sp.end, DecorationKind::Checkbox { checked }));
            }
            SpanKind::ThematicBreak if !in_table => {
                if !touch(line_of(sp.start)) {
                    hidden.push(sp.start..sp.end);
                    decorations.push((sp.start, sp.end, DecorationKind::Rule));
                }
            }
            SpanKind::BlockQuote => {
                let depth = stack.iter().filter(|(_, k, _)| *k == SpanKind::BlockQuote).count().min(255) as u8;
                decorations.push((sp.start, sp.end, DecorationKind::QuoteBar { depth }));
            }
            SpanKind::Image if !in_table => {
                let idx = a.images.partition_point(|im| im.start < sp.start);
                if let Some(im) = a.images.get(idx).filter(|im| im.start == sp.start && im.end == sp.end && im.standalone) {
                    // The owner is the image's paragraph: entering it shows the source.
                    let bi = a.blocks.partition_point(|bl| bl.start <= sp.start).saturating_sub(1);
                    let owner = a
                        .blocks
                        .get(bi)
                        .filter(|bl| bl.kind == BlockKind::Paragraph && bl.start <= im.start && im.end <= bl.end)
                        .map_or((im.start, im.end), |bl| (bl.start, bl.end));
                    if !touch(owner) {
                        hidden.push(im.start..im.end);
                        decorations.push((im.start, im.end, DecorationKind::Image { index: idx as u32 }));
                    }
                }
            }
            _ => {}
        }
        stack.push((sp.end, sp.kind, sp.start));
    }

    // Split at line terminators, sort, merge, and keep what the window sees.
    let mut pieces: Vec<(usize, usize)> = Vec::with_capacity(hidden.len());
    for r in hidden {
        let mut s = r.start;
        for i in r.clone() {
            if matches!(b[i], b'\n' | b'\r') {
                if s < i {
                    pieces.push((s, i));
                }
                s = i + 1;
            }
        }
        if s < r.end {
            pieces.push((s, r.end));
        }
    }
    pieces.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::with_capacity(pieces.len());
    for (s, e) in pieces {
        match merged.last_mut() {
            Some(last) if s <= last.1 => last.1 = last.1.max(e),
            _ => merged.push((s, e)),
        }
    }

    // A line collapses when nothing but blanks stays visible on it.
    candidates.sort_unstable();
    candidates.dedup();
    let covered = |p: usize| {
        let i = merged.partition_point(|h| h.1 <= p);
        merged.get(i).is_some_and(|h| h.0 <= p)
    };
    let mut collapsed_bytes: Vec<(usize, usize)> = Vec::new();
    for ls in candidates {
        let (_, le) = line_of(ls);
        if (ls..le).all(|p| matches!(b[p], b' ' | b'\t') || covered(p)) {
            let next = a.lines.next_line_start(ls);
            if in_window(ls, next.max(ls + 1)) {
                collapsed_bytes.push((ls, next));
            }
        }
    }

    let clipped: Vec<(usize, usize)> = match window {
        None => merged,
        Some((ws, we)) => merged
            .into_iter()
            .filter_map(|(s, e)| {
                let (s, e) = (s.max(ws), e.min(we));
                (s < e).then_some((s, e))
            })
            .collect(),
    };

    decorations.sort_by_key(|&(s, e, k)| (s, std::cmp::Reverse(e), kind_rank(k)));
    decorations.retain(|&(s, e, _)| in_window(s, e));

    let unit = |p: usize| doc.unit_of(p);
    Concealment {
        hidden: clipped.into_iter().map(|(s, e)| TextRange::new(unit(s), unit(e))).collect(),
        collapsed: collapsed_bytes.into_iter().map(|(s, e)| TextRange::new(unit(s), unit(e))).collect(),
        decorations: decorations
            .into_iter()
            .map(|(s, e, kind)| Decoration { range: TextRange::new(unit(s), unit(e)), kind })
            .collect(),
    }
}

fn kind_rank(k: DecorationKind) -> u8 {
    match k {
        DecorationKind::QuoteBar { depth } => depth,
        DecorationKind::Bullet => 100,
        DecorationKind::Checkbox { .. } => 101,
        DecorationKind::Rule => 102,
        DecorationKind::Image { .. } => 103,
    }
}

// ----- links ---------------------------------------------------------------------------------

/// The link under `offset` and where it points; see [`Document::link_at`].
pub(crate) fn link_at(doc: &Document, offset: u32) -> Option<LinkTarget> {
    let a = doc.analysis();
    let text = doc.text();
    let b = text.as_bytes();
    let p = doc.byte_snapped(offset, false);
    let (lo, hi) = doc.span_indices_bytes(Some((p, p)));
    let spans = &a.spans[lo..hi];
    // The innermost link containing the offset (spans are sorted outer first).
    let link = spans.iter().rfind(|s| s.kind == SpanKind::Link && s.start <= p && p < s.end)?;
    let (ls, le) = (link.start, link.end);
    let (ilo, ihi) = doc.span_indices_bytes(Some((ls, le)));
    let inner = &a.spans[ilo..ihi];
    let images: Vec<(usize, usize)> =
        inner.iter().filter(|s| s.kind == SpanKind::Image && s.start >= ls && s.end <= le).map(|s| (s.start, s.end)).collect();
    let dest = inner
        .iter()
        .filter(|s| s.kind == SpanKind::LinkDestination && s.start > ls && s.end < le)
        .rfind(|s| !images.iter().any(|&(is, ie)| is <= s.start && s.end <= ie));
    let raw = &text[ls..le];
    let destination = match dest {
        Some(d) => {
            let dtext = &text[d.start..d.end];
            if b[ls] == b'<' {
                // An autolink: the URL itself (an email address gets its scheme).
                if !dtext.contains(':') && dtext.contains('@') { format!("mailto:{dtext}") } else { dtext.to_owned() }
            } else if d.start > 0 && b[d.start - 1] == b'[' {
                definition_for(text, dtext)?
            } else if let Some(rest) = dtext.strip_prefix('<') {
                rest.split('>').next().unwrap_or("").to_owned()
            } else {
                dtext.split(char::is_whitespace).next().unwrap_or("").to_owned()
            }
        }
        None if raw.starts_with('[') => {
            // `[label]` or `[label][]`.
            let end = raw.find(']')?;
            definition_for(text, &raw[1..end])?
        }
        None => raw.to_owned(), // a bare URL
    };
    if destination.is_empty() {
        return None;
    }
    Some(LinkTarget { range: TextRange::new(doc.unit_of(ls), doc.unit_of(le)), destination })
}

fn normalize_label(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// The destination of the link reference definition `[label]: dest "title"`.
fn definition_for(text: &str, label: &str) -> Option<String> {
    let want = normalize_label(label);
    for line in text.lines() {
        let l = line.trim_start_matches([' ', '\t', '>']);
        let Some(rest) = l.strip_prefix('[') else { continue };
        let Some(close) = rest.find("]:") else { continue };
        if normalize_label(&rest[..close]) != want {
            continue;
        }
        let after = rest[close + 2..].trim_start();
        let dest = match after.strip_prefix('<') {
            Some(r) => r.split('>').next().unwrap_or(""),
            None => after.split_whitespace().next().unwrap_or(""),
        };
        return (!dest.is_empty()).then(|| dest.to_owned());
    }
    None
}
