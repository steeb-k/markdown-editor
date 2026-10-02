//! Block commands on whole lines: headings, block quotes, lists, code blocks.

use super::*;

/// Lines a block command should touch: blank lines are skipped (unless the selection is a
/// single line), and so are lines inside code, HTML, front matter and tables when
/// `skip_opaque` is set.
fn target_lines(cx: &Ctx, s: usize, e: usize, skip_opaque: bool) -> Vec<LineInfo> {
    let (l0, l1) = cx.affected(s, e);
    let single = l0 == l1;
    (l0..=l1)
        .map(|l| cx.info(l))
        .filter(|i| single || !i.blank)
        // A blank line inside a code block is code too.
        .filter(|i| {
            let at = if i.blank { i.start } else { i.content_start().min(i.end.saturating_sub(1)).max(i.start) };
            !(skip_opaque && cx.is_opaque_block(at))
        })
        .collect()
}

fn map_sel(sp: &[Splice], s: usize, e: usize) -> (usize, usize) {
    (map_pos(sp, s, true), map_pos(sp, e, true))
}

// ----- headings -------------------------------------------------------------------------------

/// ATX heading prefix on a line: (level, `#` start, end of `#`s and blanks).
fn atx_prefix(cx: &Ctx, info: &LineInfo) -> Option<(u8, usize, usize)> {
    let b = cx.b;
    let s = info.content_start();
    let mut i = s;
    while i < info.end && b[i] == b'#' {
        i += 1;
    }
    let n = i - s;
    if n == 0 || n > 6 || !(i == info.end || matches!(b[i], b' ' | b'\t')) {
        return None;
    }
    let mut j = i;
    while j < info.end && matches!(b[j], b' ' | b'\t') {
        j += 1;
    }
    Some((n as u8, s, j))
}

/// Start and end of a closing `#` sequence of an ATX heading line.
pub(super) fn atx_closing(cx: &Ctx, from: usize, end: usize) -> Option<(usize, usize)> {
    let b = cx.b;
    let mut e = end;
    while e > from && matches!(b[e - 1], b' ' | b'\t') {
        e -= 1;
    }
    let mut s = e;
    while s > from && b[s - 1] == b'#' {
        s -= 1;
    }
    if s == e || s == from || !matches!(b[s - 1], b' ' | b'\t') {
        return None;
    }
    let mut t = s;
    while t > from && matches!(b[t - 1], b' ' | b'\t') {
        t -= 1;
    }
    Some((t, end))
}

pub(crate) fn heading(cx: &Ctx, level: u8, s: usize, e: usize) -> Option<TextEdit> {
    let level = level.min(6);
    let lines = target_lines(cx, s, e, true);
    if lines.is_empty() {
        return None;
    }
    // Current level of each line, and for setext headings the block they belong to.
    struct L {
        info: LineInfo,
        atx: Option<(u8, usize, usize)>,
        setext: Option<(usize, usize, u8)>, // block range and level
    }
    let ls: Vec<L> = lines
        .into_iter()
        .map(|info| {
            let atx = atx_prefix(cx, &info);
            let setext = if atx.is_none() {
                cx.leaf_block_at(info.content_start().min(info.end.saturating_sub(1)).max(info.start))
                    .filter(|b| b.kind == BlockKind::Heading && cx.line_of(b.end.saturating_sub(1)) > cx.line_of(b.start))
                    .map(|b| (b.start, b.end, b.heading_level.unwrap_or(1)))
            } else {
                None
            };
            L { info, atx, setext }
        })
        .collect();
    let cur = |l: &L| l.atx.map(|a| a.0).or(l.setext.map(|s| s.2)).unwrap_or(0);
    let target = if level > 0 && ls.iter().all(|l| cur(l) == level) { 0 } else { level };

    let mut sp: Vec<Splice> = Vec::new();
    let mut done_blocks: Vec<(usize, usize)> = Vec::new();
    // Setext headings replaced as a whole: (old range, new length).
    let mut whole: Vec<(usize, usize, usize)> = Vec::new();
    for l in &ls {
        let i = &l.info;
        if let Some((_, hs, he)) = l.atx {
            if target == 0 {
                // Remove the prefix and the closing sequence.
                let close = atx_closing(cx, he, i.end);
                sp.push(Splice::delete(hs, he - hs));
                if let Some((a, b)) = close {
                    sp.push(Splice::delete(a, b - a));
                }
            } else {
                sp.push(Splice::replace(hs, he - hs, format!("{} ", "#".repeat(target as usize))));
            }
        } else if let Some((bs, be, _)) = l.setext {
            if done_blocks.contains(&(bs, be)) {
                continue;
            }
            done_blocks.push((bs, be));
            // Join the text lines (everything but the underline) into one.
            let last = cx.line_of(be.saturating_sub(1));
            let first = cx.line_of(bs);
            let mut parts: Vec<&str> = Vec::new();
            for ln in first..last {
                let from = if ln == first { bs } else { cx.info(ln).ind_end };
                let t = cx.text[from.min(cx.line_end(ln))..cx.line_end(ln)].trim();
                if !t.is_empty() {
                    parts.push(t);
                }
            }
            let body = parts.join(" ");
            let new = if target == 0 { body } else { format!("{} {}", "#".repeat(target as usize), body) };
            whole.push((bs, be, new.len()));
            sp.push(Splice::replace(bs, be - bs, new));
        } else if target > 0 {
            sp.push(Splice::insert(i.content_start(), format!("{} ", "#".repeat(target as usize))));
        }
    }
    if sp.is_empty() {
        return None;
    }
    let sp = normalize(sp);
    let mut sel = map_sel(&sp, s, e);
    // A selection touching a replaced setext heading covers its replacement.
    for &(bs, be, len) in &whole {
        if bs <= s && s <= be {
            sel.0 = map_pos(&sp, bs, false);
            if s == e {
                sel.0 += len;
            }
        }
        if bs <= e && e <= be {
            sel.1 = map_pos(&sp, bs, false) + len;
        }
    }
    Some(cx.finish(sp, (sel.0, sel.1.max(sel.0))))
}

// ----- block quotes ---------------------------------------------------------------------------

pub(crate) fn quote(cx: &Ctx, s: usize, e: usize) -> Option<TextEdit> {
    let (mut l0, mut l1) = cx.affected(s, e);
    // Code, HTML and tables go into or out of a quote whole: quoting one line of a fenced block
    // would turn the rest of it into something else. Front matter cannot be quoted.
    let mut whole: Option<(usize, usize)> = None; // lines of such blocks, blank ones included
    for l in [l0, l1] {
        let i = cx.info(l);
        let at = i.content_start().min(i.end.saturating_sub(1)).max(i.start);
        if let Some(bl) = cx.leaf_block_at(at) {
            match bl.kind {
                BlockKind::FrontMatter => return None,
                BlockKind::CodeBlock | BlockKind::HtmlBlock | BlockKind::Table => {
                    let (a, mut b) = (cx.line_of(bl.start), cx.line_of(bl.end.saturating_sub(1).max(bl.start)));
                    // An unclosed fence runs to the end of the text, blank lines included.
                    if bl.kind == BlockKind::CodeBlock && fenced_around(cx, bl.start).is_some_and(|f| f.1.is_none()) {
                        b = cx.line_of(cx.b.len().saturating_sub(1));
                    }
                    l0 = l0.min(a);
                    l1 = l1.max(b);
                    whole = Some(whole.map_or((a, b), |w| (w.0.min(a), w.1.max(b))));
                }
                _ => {}
            }
        }
    }
    let infos: Vec<LineInfo> = (l0..=l1).map(|l| cx.info(l)).collect();
    // A `>` that really is a quote marker (not code text that starts with one).
    let hq = |i: &LineInfo| {
        i.has_quote() && {
            let gt = i.start + cx.text[i.start..i.qp_end].find('>').unwrap_or(0);
            cx.spans_touching(gt, gt).iter().any(|sp| sp.kind == SpanKind::BlockQuote && sp.start <= gt && gt < sp.end)
        }
    };
    // Truly empty lines (no `>` either) at the edges of a multi-line selection stay out; those
    // between paragraphs join the quote, so it stays one quote.
    let empty = |i: &LineInfo| i.blank && !hq(i);
    let lines: &[LineInfo] = if l0 == l1 {
        &infos
    } else {
        let mut a = infos.iter().position(|i| !empty(i))?;
        let mut b = infos.iter().rposition(|i| !empty(i)).unwrap_or(a);
        if let Some((wa, wb)) = whole {
            a = a.min(wa - l0);
            b = b.max(wb - l0);
        }
        &infos[a..=b]
    };
    // A quote inside a list item (`- > x`) counts as quoted, so the toggle matches the toolbar.
    let inner = |i: &LineInfo| -> Option<(usize, usize)> {
        let m = i.marker?;
        if hq(i) || cx.b.get(m.content) != Some(&b'>') {
            return None;
        }
        let n = if cx.b.get(m.content + 1) == Some(&b' ') { 2 } else { 1 };
        Some((m.content, n))
    };
    let quoted = |i: &LineInfo| hq(i) || inner(i).is_some();
    let all_quoted = lines.iter().any(|i| !empty(i)) && lines.iter().filter(|i| !empty(i)).all(quoted);
    let mut sp = Vec::new();
    for i in lines {
        if all_quoted {
            if hq(i) {
                // Remove the first marker: up to three blanks, `>`, one blank.
                let b = cx.b;
                let mut j = i.start;
                while j < i.end && b[j] == b' ' && j - i.start < 3 {
                    j += 1;
                }
                j += 1; // `>`
                if j < i.end && b[j] == b' ' {
                    j += 1;
                }
                sp.push(Splice::delete(i.start, j - i.start));
            } else if let Some((at, n)) = inner(i) {
                sp.push(Splice::delete(at, n));
            }
        } else if !hq(i) {
            // A bare `>` on a blank line between paragraphs; inside code every blank counts.
            let in_block = whole.is_some_and(|(a, b)| a <= i.line && i.line <= b);
            sp.push(Splice::insert(i.start, if empty(i) && lines.len() > 1 && !in_block { ">" } else { "> " }));
        }
    }
    if sp.is_empty() {
        return None;
    }
    let sp = normalize(sp);
    let sel = map_sel(&sp, s, e);
    Some(cx.finish(sp, sel))
}

// ----- lists ----------------------------------------------------------------------------------

pub(crate) fn list(cx: &Ctx, which: ListKind, s: usize, e: usize) -> Option<TextEdit> {
    let lines = target_lines(cx, s, e, true);
    if lines.is_empty() {
        return None;
    }
    let all_match = lines.iter().all(|i| i.list_kind() == which);
    let mut sp = Vec::new();
    if all_match {
        for i in &lines {
            let m = i.marker.as_ref()?;
            sp.push(Splice::delete(m.start, m.content - m.start));
        }
    } else {
        let bullet = lines.iter().filter_map(|i| i.marker).find(|m| !m.ordered).map_or('-', |m| m.ch as char);
        let delim = lines.iter().filter_map(|i| i.marker).find(|m| m.ordered).map_or('.', |m| m.ch as char);
        // Ordered numbering restarts per nesting width.
        let mut stack: Vec<(usize, u64)> = Vec::new();
        for i in &lines {
            let width = cx.ws_width(i.qp_end, i.ind_end);
            match which {
                ListKind::Bullet => match i.list_kind() {
                    ListKind::Bullet => {}
                    ListKind::None => sp.push(Splice::insert(i.ind_end, format!("{bullet} "))),
                    ListKind::Ordered => {
                        let m = i.marker?;
                        sp.push(Splice::replace(m.start, m.end - m.start, bullet.to_string()));
                    }
                    _ => {
                        // Task to bullet: drop the checkbox.
                        let m = i.marker?;
                        sp.push(Splice::delete(m.gap_end, m.content - m.gap_end));
                    }
                },
                ListKind::Task => match i.list_kind() {
                    ListKind::Task => {}
                    ListKind::None => sp.push(Splice::insert(i.ind_end, format!("{bullet} [ ] "))),
                    ListKind::Bullet => {
                        let m = i.marker?;
                        sp.push(Splice::insert(m.content, "[ ] "));
                    }
                    _ => {
                        let m = i.marker?;
                        sp.push(Splice::replace(m.start, m.content - m.start, format!("{bullet} [ ] ")));
                    }
                },
                ListKind::Ordered => {
                    while stack.last().is_some_and(|t| t.0 > width) {
                        stack.pop();
                    }
                    let n = match stack.last_mut() {
                        Some(t) if t.0 == width => {
                            t.1 += 1;
                            t.1
                        }
                        _ => {
                            stack.push((width, 1));
                            1
                        }
                    };
                    let num = format!("{n}{delim}");
                    match i.marker {
                        None => sp.push(Splice::insert(i.ind_end, format!("{num} "))),
                        Some(m) if m.task.is_some() => {
                            sp.push(Splice::replace(m.start, m.content - m.start, format!("{num} ")));
                        }
                        Some(m) => sp.push(Splice::replace(m.start, m.end - m.start, num)),
                    }
                }
                ListKind::None => return None,
            }
        }
    }
    if sp.is_empty() {
        return None;
    }
    let sp = normalize(sp);
    let sel = map_sel(&sp, s, e);
    Some(cx.finish(sp, sel))
}

// ----- code blocks ----------------------------------------------------------------------------

/// A fenced code block around byte `p`: (opening line, closing line if terminated, start of
/// the opening fence).
pub(super) fn fenced_around(cx: &Ctx, p: usize) -> Option<(usize, Option<usize>, usize)> {
    let sp = cx
        .spans_touching(p, p)
        .into_iter()
        .filter(|sp| sp.kind == SpanKind::CodeBlock && sp.start <= p && p <= sp.end)
        .min_by_key(|sp| sp.end - sp.start)?;
    let open = cx.line_of(sp.start);
    let info = cx.info(open);
    let b = cx.b;
    let mut i = sp.start.max(info.qp_end);
    while i < info.end && matches!(b[i], b' ' | b'\t') {
        i += 1;
    }
    if i >= info.end || !matches!(b[i], b'`' | b'~') {
        return None;
    }
    let c = b[i];
    let n = b[i..info.end].iter().take_while(|&&x| x == c).count();
    if n < 3 {
        return None;
    }
    let last = cx.line_of(sp.end.saturating_sub(1));
    let closing = (last > open)
        .then(|| {
            let li = cx.info(last);
            let t = cx.text[li.ind_end..li.end].trim_end();
            // Four columns of indentation make it code, not a closing fence.
            let indented = cx.ws_width(li.qp_end, li.ind_end) >= 4;
            (!indented && t.len() >= n && t.bytes().all(|x| x == c)).then_some(last)
        })
        .flatten();
    Some((open, closing, i))
}

pub(crate) fn code_block(cx: &Ctx, s: usize, e: usize) -> Option<TextEdit> {
    let (l0, l1) = cx.affected(s, e);
    if let Some((open, closing, fence)) = fenced_around(cx, s) {
        // Take the fences off, keep the content. A fence after a container prefix (`- `, `> `)
        // keeps the prefix: the first content line moves up into its place, without its own
        // copy of the prefix, so a list item stays a list item.
        let os = cx.line_start(open);
        let k = fence - os;
        let first = if k == 0 {
            Splice::delete(os, cx.next_start(open) - os)
        } else if open + 1 < cx.line_count() && closing != Some(open + 1) {
            let ns = cx.next_start(open);
            let ne = cx.line_end(open + 1);
            let mut j = ns;
            while j < ne && j - ns < k && matches!(cx.b[j], b' ' | b'\t' | b'>') {
                j += 1;
            }
            Splice::delete(fence, j - fence)
        } else {
            Splice::delete(fence, cx.line_end(open) - fence)
        };
        let mut sp = vec![first];
        if let Some(c) = closing {
            if c + 1 < cx.line_count() {
                sp.push(Splice::delete(cx.line_start(c), cx.next_start(c) - cx.line_start(c)));
            } else {
                let from = cx.line_end(c - 1);
                sp.push(Splice::delete(from, cx.line_end(c) - from));
            }
        }
        let sp = normalize(sp);
        let sel = (map_pos(&sp, s, true), map_pos(&sp, e, false));
        return Some(cx.finish(sp, (sel.0, sel.1.max(sel.0))));
    }
    // Wrap the selected lines in a fence longer than any backtick run inside.
    let (start, end) = (cx.line_start(l0), cx.line_end(l1));
    let mut longest = 0;
    let mut run = 0;
    for c in cx.text[start..end].chars() {
        run = if c == '`' { run + 1 } else { 0 };
        longest = longest.max(run);
    }
    let fence = "`".repeat(if longest >= 3 { longest + 1 } else { 3 });
    let first = cx.info(l0);
    let width = cx.ws_width(first.qp_end, first.ind_end);
    let prefix = if width < 4 { &cx.text[first.start..first.ind_end] } else { &cx.text[first.start..first.qp_end] };
    let eol = cx.eol_near(l0);
    let head = format!("{prefix}{fence}{eol}");
    let tail = format!("{eol}{prefix}{fence}");
    let sp = vec![Splice::insert(start, head.clone()), Splice::insert(end, tail)];
    let sel = (s + head.len(), e + head.len());
    Some(cx.finish(sp, sel))
}
