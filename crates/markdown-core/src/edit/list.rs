//! Return, Tab and Shift-Tab in lists, block quotes and fenced code; task toggling.

use super::block::fenced_around;
use super::*;

/// Column of `abs` on its line, counted from the end of the block quote markers.
fn col(cx: &Ctx, info: &LineInfo, abs: usize) -> usize {
    cx.ws_width(info.qp_end, abs.max(info.qp_end))
}

/// Indentation (columns) of a line's first non-blank character after the quote markers.
fn indent_cols(cx: &Ctx, info: &LineInfo) -> usize {
    col(cx, info, info.ind_end)
}

fn same_quote(cx: &Ctx, a: &LineInfo, b: &LineInfo) -> bool {
    cx.text[a.start..a.qp_end] == cx.text[b.start..b.qp_end]
}

// ----- Return ---------------------------------------------------------------------------------

pub(crate) fn newline(cx: &Ctx, s: usize, e: usize) -> Option<TextEdit> {
    let line = cx.line_of(s);
    let info = cx.info(line);
    let eol = cx.eol_near(line);

    // Fenced code: keep the indentation (and the quote prefix of the fence), nothing else.
    if let Some((open, closing, _)) = fenced_around(cx, s) {
        if closing == Some(line) {
            return None;
        }
        let oi = cx.info(open);
        let quote = &cx.text[oi.start..oi.qp_end];
        let mut prefix = String::new();
        let mut from = info.start;
        if !quote.is_empty() && cx.text[info.start..info.end].starts_with(quote) {
            prefix.push_str(quote);
            from += quote.len();
        }
        let ws_end = {
            let mut i = from;
            while i < s.min(info.end) && matches!(cx.b[i], b' ' | b'\t') {
                i += 1;
            }
            i
        };
        prefix.push_str(&cx.text[from.min(ws_end)..ws_end]);
        if s < from || prefix.is_empty() {
            return None;
        }
        let ins = format!("{eol}{prefix}");
        let caret = s + ins.len();
        return Some(cx.finish(vec![Splice::replace(s, e - s, ins)], (caret, caret)));
    }

    if let Some(m) = info.marker {
        let empty_item = m.content >= info.end;
        if empty_item {
            if s < m.end || s != e {
                return None;
            }
            // End the list, or move the empty item out one level (only when it is nested: an
            // indented top-level list just ends).
            if col(cx, &info, m.start) > 0
                && has_parent_item(cx, &info, &m)
                && let Some(ed) = indent(cx, s, e, true)
            {
                return Some(ed);
            }
            let sp = vec![Splice::delete(info.ind_end, info.end - info.ind_end)];
            return Some(cx.finish(sp, (info.ind_end, info.ind_end)));
        }
        if s < m.content {
            return None;
        }
        // Continue the list: same quote prefix, indentation and marker.
        let gap = |a: usize, b: usize| if a == b { " " } else { &cx.text[a..b] };
        let mut new_marker = match m.ordered {
            false => (m.ch as char).to_string(),
            true => String::new(),
        };
        let mut renumber: Vec<Splice> = Vec::new();
        if m.ordered {
            let (next, fix) = following_numbers(cx, &info, &m);
            new_marker = format!("{next}{}", m.ch as char);
            renumber = fix;
        }
        let mut prefix = String::new();
        prefix.push_str(&cx.text[info.start..m.start]);
        prefix.push_str(&new_marker);
        prefix.push_str(gap(m.end, m.gap_end));
        if let Some(t) = m.task {
            prefix.push_str("[ ]");
            prefix.push_str(gap(t.start + 3, m.content));
        }
        let ins = format!("{eol}{prefix}");
        let caret = s + ins.len();
        let mut sp = vec![Splice::replace(s, e - s, ins.clone())];
        sp.extend(renumber);
        let sp = normalize(sp);
        // `s` is before every renumbered marker, so the caret is just after the new prefix.
        return Some(cx.finish(sp, (caret, caret)));
    }

    if info.has_quote() {
        if s < info.qp_end {
            return None;
        }
        if info.blank && s == e {
            // An empty quote line leaves the quote, one level.
            let q = &cx.text[info.start..info.qp_end];
            let k = q.rfind('>')?;
            // The only marker also takes its indentation with it.
            let piece = if q[..k].contains('>') { info.start + k } else { info.start };
            let sp = vec![Splice::delete(piece, info.end - piece)];
            return Some(cx.finish(sp, (piece, piece)));
        }
        let ws = &cx.text[info.qp_end..s.min(info.ind_end).max(info.qp_end)];
        let ins = format!("{eol}{}{ws}", &cx.text[info.start..info.qp_end]);
        let caret = s + ins.len();
        return Some(cx.finish(vec![Splice::replace(s, e - s, ins)], (caret, caret)));
    }
    None
}

/// Is the item at `m` nested in another list item?
fn has_parent_item(cx: &Ctx, info: &LineInfo, m: &Marker) -> bool {
    let w = col(cx, info, m.start);
    for l in (0..info.line).rev() {
        let li = cx.info(l);
        if li.blank {
            continue;
        }
        if !same_quote(cx, info, &li) {
            return false;
        }
        match li.marker {
            Some(lm) if col(cx, &li, lm.start) < w => return true,
            Some(_) => {}
            None if indent_cols(cx, &li) == 0 => return false,
            None => {}
        }
    }
    false
}

/// Number for a new item after `m` and the edits renumbering the items that follow it in the
/// same list (only those that were numbered consecutively).
fn following_numbers(cx: &Ctx, info: &LineInfo, m: &Marker) -> (u64, Vec<Splice>) {
    let w = col(cx, info, m.start);
    let sibs = following_siblings(cx, info, m, w);
    let Some(first) = sibs.first() else { return (m.number + 1, Vec::new()) };
    if first.1 == m.number {
        // `1. 1. 1.` style: keep the number.
        return (m.number, Vec::new());
    }
    let mut fix = Vec::new();
    for (&(at, n, len), expected) in sibs.iter().zip(m.number + 1..) {
        if n != expected {
            break;
        }
        fix.push(Splice::replace(at, len, (n + 1).to_string()));
    }
    (m.number + 1, fix)
}

/// Later items of the list `m` belongs to, at the same indentation and with the same
/// delimiter: (number start, number, number length).
fn following_siblings(cx: &Ctx, info: &LineInfo, m: &Marker, w: usize) -> Vec<(usize, u64, usize)> {
    let mut out = Vec::new();
    for l in info.line + 1..cx.line_count() {
        let li = cx.info(l);
        if li.blank {
            continue;
        }
        if !same_quote(cx, info, &li) {
            break;
        }
        let lw = indent_cols(cx, &li);
        match li.marker {
            Some(lm) if lw == w => {
                if lm.ordered && lm.ch == m.ch {
                    out.push((lm.start, lm.number, lm.end - 1 - lm.start));
                } else {
                    break;
                }
            }
            _ if lw > w => {}
            _ => break,
        }
    }
    out
}

// ----- Tab ------------------------------------------------------------------------------------

/// The last line of the item rooted at `root` (its children and continuation lines).
fn subtree_end(cx: &Ctx, root: &LineInfo) -> usize {
    let w = indent_cols(cx, root);
    let mut last = root.line;
    for l in root.line + 1..cx.line_count() {
        let li = cx.info(l);
        if li.blank {
            continue;
        }
        if !same_quote(cx, root, &li) || indent_cols(cx, &li) <= w {
            break;
        }
        last = l;
    }
    last
}

pub(crate) fn indent(cx: &Ctx, s: usize, e: usize, outdent: bool) -> Option<TextEdit> {
    let (l0, l1) = cx.affected(s, e);
    let infos: Vec<LineInfo> = (l0..=l1).map(|l| cx.info(l)).collect();
    let roots: Vec<&LineInfo> = infos.iter().filter(|i| i.marker.is_some()).collect();
    if let Some(first) = roots.first() {
        return shift_items(cx, &roots, first, s, e, outdent);
    }
    // Not a list.
    let multi = l0 != l1;
    let mut sp = Vec::new();
    for i in infos.iter().filter(|i| !i.blank) {
        if !outdent {
            if multi {
                sp.push(Splice::insert(i.qp_end, "    "));
            }
        } else {
            let mut j = i.qp_end;
            let mut w = 0;
            while j < i.ind_end && w < 4 {
                w += if cx.b[j] == b'\t' { 4 } else { 1 };
                j += 1;
            }
            if j > i.qp_end {
                sp.push(Splice::delete(i.qp_end, j - i.qp_end));
            }
        }
    }
    if sp.is_empty() {
        return None;
    }
    let sel = (map_pos(&sp, s, true), map_pos(&sp, e, true));
    Some(cx.finish(sp, sel))
}

fn shift_items(cx: &Ctx, roots: &[&LineInfo], first: &LineInfo, s: usize, e: usize, outdent: bool) -> Option<TextEdit> {
    let fm = first.marker?;
    let fw = col(cx, first, fm.start);
    // The neighbour that decides how far to move: the previous sibling (to nest under its
    // content) or the parent (to move out to its level).
    let mut anchor: Option<(LineInfo, usize)> = None;
    for l in (0..first.line).rev() {
        let li = cx.info(l);
        if li.blank || !same_quote(cx, first, &li) {
            continue;
        }
        let Some(lm) = li.marker else { continue };
        let lw = col(cx, &li, lm.start);
        if !outdent {
            if lw == fw {
                anchor = Some((li, lw));
                break;
            }
            if lw < fw {
                return None; // first child: nothing to nest under
            }
        } else if lw < fw {
            anchor = Some((li, lw));
            break;
        }
    }
    let delta = if !outdent {
        let (p, pw) = anchor.as_ref()?;
        let pm = p.marker?;
        (col(cx, p, pm.gap_end) - pw).max(1)
    } else {
        match &anchor {
            Some((_, pw)) => fw - pw,
            None if fw > 0 => fw,
            None => return None,
        }
    };

    // Lines that move: each selected item with everything nested in it.
    let mut moving: Vec<usize> = Vec::new();
    let mut covered_to = None::<usize>;
    for r in roots {
        if covered_to.is_some_and(|c| r.line <= c) {
            continue;
        }
        let end = subtree_end(cx, r);
        moving.extend(r.line..=end);
        covered_to = Some(end);
    }
    let mut sp = Vec::new();
    for &l in &moving {
        let li = cx.info(l);
        if li.blank {
            continue;
        }
        if !outdent {
            sp.push(Splice::insert(li.qp_end, " ".repeat(delta)));
        } else {
            let mut j = li.qp_end;
            let mut w = 0;
            while j < li.ind_end && w < delta {
                w += if cx.b[j] == b'\t' { 4 } else { 1 };
                j += 1;
            }
            if j > li.qp_end {
                sp.push(Splice::delete(li.qp_end, j - li.qp_end));
            }
        }
    }

    // Renumber ordered items: the moved roots in their new list, and the old neighbours.
    let new_w = if outdent { fw - delta.min(fw) } else { fw + delta };
    let mut num_edits: Vec<Splice> = Vec::new();
    let moved: Vec<&&LineInfo> = roots.iter().filter(|r| moving.contains(&r.line) && col(cx, r, r.marker.unwrap().start) == fw).collect();
    if let Some(fm) = first.marker.filter(|m| m.ordered && m.task.is_none()) {
        let mut next = if !outdent {
            // Continue the previous sibling's children, if it has numbered ones at this level.
            let (p, _) = anchor.as_ref()?;
            let mut last: Option<u64> = None;
            for l in p.line + 1..first.line {
                let li = cx.info(l);
                if let Some(lm) = li.marker
                    && lm.ordered
                    && lm.ch == fm.ch
                    && col(cx, &li, lm.start) == new_w
                {
                    last = Some(lm.number);
                }
            }
            last.map_or(1, |n| n + 1)
        } else {
            match &anchor {
                Some((q, _)) if q.marker.is_some_and(|qm| qm.ordered && qm.ch == fm.ch) => q.marker.unwrap().number + 1,
                _ => fm.number,
            }
        };
        for r in &moved {
            if let Some(rm) = r.marker.filter(|m| m.ordered && m.ch == fm.ch) {
                num_edits.push(Splice::replace(rm.start, rm.end - 1 - rm.start, next.to_string()));
                next += 1;
            }
        }
        // Neighbours that follow: the old list lost `moved.len()` items (indent) or the
        // parent's list gained them (outdent); shift sequentially numbered ones.
        let count = moved.len() as u64;
        let (from_line, from_w, start_expected, up) = if !outdent {
            let last_moved = moved.last().copied().copied().unwrap_or(first);
            (subtree_end(cx, last_moved), fw, last_moved.marker.map_or(fm.number, |m| m.number) + 1, false)
        } else {
            let (q, qw) = anchor.as_ref()?;
            (subtree_end(cx, q), *qw, q.marker.map_or(0, |m| m.number) + 1, true)
        };
        let template = Marker { number: 0, ..fm };
        let probe = LineInfo { line: from_line, ..*first };
        let sibs = following_siblings(cx, &probe, &template, from_w);
        for ((at, n, len), expected) in sibs.into_iter().zip(start_expected..) {
            if n != expected || (!up && n <= count) {
                break;
            }
            let new = if up { n + count } else { n - count };
            num_edits.push(Splice::replace(at, len, new.to_string()));
        }
    }
    sp.extend(num_edits);
    if sp.is_empty() {
        return None;
    }
    let sp = normalize(sp);
    let sel = (map_pos(&sp, s, true), map_pos(&sp, e, true));
    Some(cx.finish(sp, sel))
}

// ----- tasks ----------------------------------------------------------------------------------

pub(crate) fn toggle_task(cx: &Ctx, at: u32) -> Option<TextEdit> {
    let p = cx.doc.byte_snapped(at, false);
    let line = cx.line_of(p);
    let (ls, le) = (cx.line_start(line), cx.next_start(line));
    let tasks: Vec<&crate::analysis::ISpan> = cx
        .spans_touching(ls, le)
        .into_iter()
        .filter(|sp| matches!(sp.kind, SpanKind::TaskMarker { .. }) && sp.start >= ls && sp.start < le)
        .collect();
    let t = tasks.iter().find(|t| t.start <= p && p < t.end).or(tasks.first())?;
    let checked = matches!(t.kind, SpanKind::TaskMarker { checked: true });
    let new = if checked { " " } else { "x" };
    Some(cx.finish(vec![Splice::replace(t.start + 1, 1, new)], (p, p)))
}
