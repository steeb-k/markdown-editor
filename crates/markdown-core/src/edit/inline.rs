//! Inline commands: strong, emphasis, strikethrough, inline code, link, image.

use super::*;
use crate::autolink;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Strong,
    Emphasis,
    Strike,
    Code,
}

impl Kind {
    pub fn span(self) -> SpanKind {
        match self {
            Kind::Strong => SpanKind::Strong,
            Kind::Emphasis => SpanKind::Emphasis,
            Kind::Strike => SpanKind::Strikethrough,
            Kind::Code => SpanKind::InlineCode,
        }
    }

    /// Opening and closing delimiter for wrapping `inner`.
    fn wrap(self, inner: &str) -> (String, String) {
        match self {
            Kind::Strong => ("**".into(), "**".into()),
            Kind::Emphasis => ("*".into(), "*".into()),
            Kind::Strike => ("~~".into(), "~~".into()),
            Kind::Code => {
                // A fence longer than any backtick run inside; blanks keep a leading or
                // trailing backtick from merging with the fence.
                let mut longest = 0;
                let mut run = 0;
                for c in inner.chars() {
                    run = if c == '`' { run + 1 } else { 0 };
                    longest = longest.max(run);
                }
                let fence = "`".repeat(longest + 1);
                let pad = if inner.starts_with('`') || inner.ends_with('`') { " " } else { "" };
                (format!("{fence}{pad}"), format!("{pad}{fence}"))
            }
        }
    }
}

type R = (usize, usize);

/// The opening and closing delimiter ranges of the element `a..b`, if it has some.
fn delims(cx: &Ctx, kind: Kind, a: usize, b: usize) -> Option<(R, R)> {
    let bytes = cx.b;
    match kind {
        Kind::Strong | Kind::Emphasis | Kind::Strike => {
            let d = match kind {
                Kind::Strong => 2,
                Kind::Emphasis => 1,
                _ => {
                    if bytes.get(a + 1) == Some(&b'~') {
                        2
                    } else {
                        1
                    }
                }
            };
            (b - a > 2 * d).then_some(((a, a + d), (b - d, b)))
        }
        Kind::Code => {
            let n = bytes[a..b].iter().take_while(|&&c| c == b'`').count();
            if n == 0 || 2 * n >= b - a || !bytes[..b].ends_with(&vec![b'`'; n]) {
                return None;
            }
            let inner = &cx.text[a + n..b - n];
            let pad = inner.len() >= 2 && inner.starts_with(' ') && inner.ends_with(' ') && !inner.trim().is_empty();
            let p = pad as usize;
            Some(((a, a + n + p), (b - n - p, b)))
        }
    }
}

/// Elements of `kind` that have removable delimiters, sorted by start then end descending.
fn elements(cx: &Ctx, kind: Kind, lo: usize, hi: usize) -> Vec<R> {
    let want = kind.span();
    cx.spans_touching(lo, hi)
        .into_iter()
        .filter(|s| s.kind == want && delims(cx, kind, s.start, s.end).is_some())
        .map(|s| (s.start, s.end))
        .collect()
}

enum Cover {
    Container(usize),
    Contained(Vec<usize>),
    No,
}

/// Is the segment inside one element, or entirely made of whole elements (and blanks)?
fn cover(cx: &Ctx, elems: &[R], seg: R) -> Cover {
    let container = elems
        .iter()
        .enumerate()
        .filter(|(_, el)| el.0 <= seg.0 && seg.1 <= el.1)
        .min_by_key(|(_, el)| el.1 - el.0);
    if let Some((i, _)) = container {
        return Cover::Container(i);
    }
    let inside: Vec<usize> =
        elems.iter().enumerate().filter(|(_, el)| seg.0 <= el.0 && el.1 <= seg.1).map(|(i, _)| i).collect();
    if inside.is_empty() {
        return Cover::No;
    }
    let mut pos = seg.0;
    let mut clean = true;
    for &i in &inside {
        let el = elems[i];
        if el.0 < pos {
            continue; // nested in the previous one
        }
        clean &= cx.text[pos..el.0].trim().is_empty();
        pos = el.1;
    }
    clean &= cx.text[pos..seg.1].trim().is_empty();
    if clean { Cover::Contained(inside) } else { Cover::No }
}

/// Does inline formatting of `kind` apply (is it already on) for this selection? Shared
/// with `format_state`.
pub(crate) fn is_active(cx: &Ctx, kind: Kind, s: usize, e: usize) -> bool {
    let elems = elements(cx, kind, s, e);
    if s == e {
        return elems.iter().any(|el| el.0 <= s && s <= el.1);
    }
    let segs = segments(cx, s, e);
    if segs.is_empty() {
        return elems.iter().any(|el| el.0 <= e && e <= el.1);
    }
    segs.iter().all(|&sg| !matches!(cover(cx, &elems, sg), Cover::No))
}

fn trim_range(cx: &Ctx, a: usize, b: usize) -> R {
    let t = &cx.text[a..b];
    let lead = t.len() - t.trim_start().len();
    let a2 = a + lead;
    let t2 = t.trim_start().trim_end();
    (a2, a2 + t2.len())
}

/// The parts of the selection that formatting applies to: one per paragraph (or line, when
/// a container prefix intervenes), without container markers, heading markers or blanks.
/// Table lines yield one segment per selected cell; code, HTML and front matter yield none.
pub(crate) fn segments(cx: &Ctx, s: usize, e: usize) -> Vec<R> {
    let (l0, l1) = cx.affected(s, e);
    let mut out: Vec<R> = Vec::new();
    let mut prev: Option<(usize, usize)> = None; // (line, leaf block start) of the last segment
    for l in l0..=l1 {
        let info = cx.info(l);
        let lo = s.max(info.start);
        let mut hi = e.min(info.end);
        if lo >= hi {
            continue;
        }
        let mut cs = info.content_start();
        let mut block = cx.leaf_block_at(lo.max(cs).min(info.end.saturating_sub(1)));
        // On the block's first line its text starts where the block does: after a quote or a
        // nested item inside a list item (`1. > text`, `1. - [ ] text`) too.
        let blocks = &cx.a.blocks;
        let here = blocks.partition_point(|b| b.start < cs);
        let starts_here = blocks.get(here).is_some_and(|bl| bl.start < info.end);
        if block.is_none() && !starts_here {
            // Only container markers on this line (`1. 1.`): nothing to format.
            prev = None;
            continue;
        }
        if let Some(bl) = blocks.get(here)
            && bl.start < info.end
            && (block.is_none() || block.is_some_and(|b| b.start == bl.start))
        {
            // Between the line's first container marker and its block: more markers (`> `,
            // `- `, a task box), never text.
            cs = bl.start;
            block = Some(bl);
            let t = &cx.text[cs..info.end];
            for task in ["[ ] ", "[x] ", "[X] ", "[ ]\t", "[x]\t", "[X]\t"] {
                if t.starts_with(task) {
                    cs += 4;
                    break;
                }
            }
        }
        if let Some(bl) = block {
            match bl.kind {
                BlockKind::CodeBlock | BlockKind::HtmlBlock | BlockKind::FrontMatter => {
                    prev = None;
                    continue;
                }
                BlockKind::Table => {
                    prev = None;
                    for t in cx.a.tables.iter().filter(|t| t.start <= bl.start && bl.start < t.end) {
                        for row in t.rows.iter().filter(|r| r.start >= info.start && r.end <= info.end) {
                            for &(ca, cb) in &row.cells {
                                let (ta, tb) = trim_range(cx, ca, cb.min(cx.b.len()));
                                let (ta, tb) = (ta.max(lo), tb.min(hi));
                                if ta < tb {
                                    let (ta, tb) = trim_range(cx, ta, tb);
                                    if ta < tb {
                                        out.push((ta, tb));
                                    }
                                }
                            }
                        }
                    }
                    continue;
                }
                BlockKind::Heading if cx.b.get(cs) == Some(&b'#') => {
                    while cs < info.end && cx.b[cs] == b'#' {
                        cs += 1;
                    }
                    // Nor is the closing sequence (`# Title #`).
                    if let Some((close, _)) = super::block::atx_closing(cx, cs, info.end) {
                        hi = hi.min(close);
                    }
                }
                _ => {}
            }
        }
        let (a, b) = trim_range(cx, lo.max(cs).min(hi), hi);
        if a >= b {
            continue;
        }
        let key = block.filter(|bl| bl.kind == BlockKind::Paragraph).map(|bl| bl.start);
        match (prev, key) {
            (Some((pl, pk)), Some(k)) if pl + 1 == l && pk == k && info.qp_end == info.start && info.marker.is_none() => {
                if let Some(last) = out.last_mut() {
                    last.1 = b;
                }
            }
            _ => out.push((a, b)),
        }
        prev = key.map(|k| (l, k));
    }
    out
}

fn removal(cx: &Ctx, kind: Kind, elems: &[R], idx: &[usize], out: &mut Vec<Splice>) {
    for &i in idx {
        let (a, b) = elems[i];
        if let Some((o, c)) = delims(cx, kind, a, b) {
            out.push(Splice::delete(o.0, o.1 - o.0));
            out.push(Splice::delete(c.0, c.1 - c.0));
        }
    }
}

pub(crate) fn toggle(cx: &Ctx, kind: Kind, s: usize, e: usize) -> Option<TextEdit> {
    let elems = elements(cx, kind, s, e);
    if s == e {
        return empty_selection(cx, kind, &elems, s);
    }
    let segs = segments(cx, s, e);
    if segs.is_empty() {
        return empty_selection(cx, kind, &elems, e);
    }
    let covers: Vec<Cover> = segs.iter().map(|&sg| cover(cx, &elems, sg)).collect();
    if covers.iter().all(|c| !matches!(c, Cover::No)) {
        // Every part is formatted: remove the delimiters.
        let mut idx: Vec<usize> = Vec::new();
        for c in &covers {
            match c {
                Cover::Container(i) => idx.push(*i),
                Cover::Contained(v) => idx.extend(v),
                Cover::No => {}
            }
        }
        idx.sort_unstable();
        idx.dedup();
        let mut sp = Vec::new();
        removal(cx, kind, &elems, &idx, &mut sp);
        let sp = normalize(sp);
        let sel = (map_pos(&sp, s, false), map_pos(&sp, e, false));
        return Some(cx.finish(sp, sel));
    }
    // Wrap every part that is not formatted yet, dropping delimiters of the same kind inside.
    let mut sp = Vec::new();
    let mut delta: isize = 0;
    let mut sel: Option<(usize, usize)> = None;
    let mut floor = 0; // end of the previous wrapped part
    for (&sg, c) in segs.iter().zip(&covers) {
        if !matches!(c, Cover::No) {
            continue;
        }
        let sg = grow_over_straddlers(&elems, sg, floor);
        let sg = if kind == Kind::Code { sg } else { snap_flanking(cx, grow_over_atoms(cx, snap_flanking(cx, sg))) };
        let sg = (sg.0.max(floor), sg.1);
        if sg.0 >= sg.1 {
            continue;
        }
        floor = sg.1;
        let mut inner = String::new();
        let mut cut: Vec<R> = Vec::new();
        if kind != Kind::Code {
            for &(a, b) in elems.iter().filter(|el| sg.0 <= el.0 && el.1 <= sg.1) {
                if let Some((o, c)) = delims(cx, kind, a, b) {
                    cut.push(o);
                    cut.push(c);
                }
            }
        }
        cut.sort_unstable();
        let mut pos = sg.0;
        for (a, b) in cut {
            if a >= pos {
                inner.push_str(&cx.text[pos..a]);
                pos = b;
            }
        }
        inner.push_str(&cx.text[pos..sg.1]);
        let (mut open, mut close) = kind.wrap(&inner);
        // Text that starts or ends with a `*` run would merge with new `*` delimiters into one
        // ambiguous run (`***a** b*`); underscores stay apart, where no letter is next to them.
        let outer_word = cx.text[..sg.0].chars().next_back().is_some_and(is_word) || cx.text[sg.1..].chars().next().is_some_and(is_word);
        if matches!(kind, Kind::Strong | Kind::Emphasis) && (inner.starts_with('*') || inner.ends_with('*')) && !outer_word && !inner.contains('_') {
            open = open.replace('*', "_");
            close = close.replace('*', "_");
        }
        let start = (sg.0 as isize + delta) as usize + open.len();
        let end = start + inner.len();
        sel = Some((sel.map_or(start, |p| p.0), end));
        delta += (open.len() + inner.len() + close.len()) as isize - (sg.1 - sg.0) as isize;
        sp.push(Splice::replace(sg.0, sg.1 - sg.0, format!("{open}{inner}{close}")));
    }
    let sel = sel?;
    Some(cx.finish(sp, sel))
}

/// An element of the same kind that starts or ends inside the segment, or touches it (and does
/// not contain it), would end up with a delimiter inside or against the new one. Take it in
/// whole instead, so that `**a«b**c»d` becomes `**«abc»**d`. Does not grow below `floor`.
fn grow_over_straddlers(elems: &[R], mut sg: R, floor: usize) -> R {
    loop {
        let hit = elems.iter().find(|&&(a, b)| {
            // Touching counts too: `**a**«b»` must become `**ab**`, not `**a****b**`.
            let straddles = (a < sg.0 && sg.0 <= b && b < sg.1) || (sg.0 < a && a <= sg.1 && sg.1 < b);
            straddles && a >= floor
        });
        match hit {
            Some(&(a, b)) => sg = (sg.0.min(a), sg.1.max(b)),
            None => return sg,
        }
    }
}

/// Inline elements that wrapping must never cut through: a delimiter inside a code span is
/// literal text, one inside a link's brackets or destination breaks the link, and one between
/// another format's delimiters and its text (`*«**a» b**`) breaks that format. A part that
/// starts or ends inside one (on a single line) takes it in whole.
fn grow_over_atoms(cx: &Ctx, mut sg: R) -> R {
    loop {
        let hit = cx.spans_touching(sg.0, sg.1).into_iter().find(|sp| {
            matches!(
                sp.kind,
                SpanKind::InlineCode | SpanKind::Link | SpanKind::Image | SpanKind::Strong | SpanKind::Emphasis | SpanKind::Strikethrough
            )
                && ((sp.start < sg.0 && sg.0 < sp.end) || (sp.start < sg.1 && sg.1 < sp.end))
                && !cx.text[sp.start..sp.end].contains(['\n', '\r'])
        });
        // Exactly the text of another format (`*«em»*`): wrap the whole element (`~~*em*~~`), as
        // delimiters squeezed between its own and a neighbouring letter could not open.
        let filled = cx.spans_touching(sg.0, sg.1).into_iter().find(|sp| {
            matches!(sp.kind, SpanKind::Strong | SpanKind::Emphasis | SpanKind::Strikethrough)
                && sp.start < sg.0
                && sg.1 < sp.end
                && cx.text[sp.start..sg.0].bytes().all(|c| matches!(c, b'*' | b'_' | b'~'))
                && cx.text[sg.1..sp.end].bytes().all(|c| matches!(c, b'*' | b'_' | b'~'))
        });
        match hit.or(filled) {
            Some(sp) => sg = (sg.0.min(sp.start), sg.1.max(sp.end)),
            None => return sg,
        }
    }
}

/// CommonMark's flanking rules: a delimiter between a letter and punctuation (`é**`c`**`,
/// `word**_u_**`) cannot open or close, and an intraword `_` next to a new `*` stops being
/// literal. A part whose edge is like that takes in the rest of the word at that edge.
fn snap_flanking(cx: &Ctx, sg: R) -> R {
    let (mut a, mut b) = sg;
    let t = cx.text;
    let wordish = |c: char| is_word(c);
    let punct = |c: char| !is_word(c) && !c.is_whitespace();
    let (before, first) = (t[..a].chars().next_back(), t[a..].chars().next());
    if before.is_some_and(wordish) && first.is_some_and(punct) || t[..a].ends_with('_') && first.is_some_and(wordish) {
        a = word_at(cx, a).map_or(a, |w| w.0.min(a));
    }
    let (last, after) = (t[..b].chars().next_back(), t[b..].chars().next());
    if after.is_some_and(wordish) && last.is_some_and(punct) || t[b..].starts_with('_') && last.is_some_and(wordish) {
        b = word_at(cx, b).map_or(b, |w| w.1.max(b));
    }
    (a, b)
}

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || is_mark(c)
}

/// Combining marks and joiners that `is_alphanumeric` does not count (`e` + U+0301 is one
/// letter to a reader).
fn is_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F | 0xFE00..=0xFE0F | 0x200C | 0x200D)
}

/// Bounds of the word touching `p`. An apostrophe or underscore between two letters belongs
/// to the word (`don't`, `l’homme`, `snake_case`: an intraword `_` is literal in Markdown).
fn word_at(cx: &Ctx, p: usize) -> Option<R> {
    let t = cx.text;
    let prev = |i: usize| t[..i].chars().next_back();
    let next = |i: usize| t[i..].chars().next();
    // `c` starts at `i`.
    let wordy = |i: usize, c: char| {
        is_word(c)
            || (matches!(c, '\'' | '\u{2019}' | '_')
                && prev(i).is_some_and(is_word)
                && next(i + c.len_utf8()).is_some_and(is_word))
    };
    let before = prev(p).is_some_and(|c| wordy(p - c.len_utf8(), c));
    let after = next(p).is_some_and(|c| wordy(p, c));
    if !before && !after {
        return None;
    }
    let mut a = p;
    while let Some(c) = prev(a) {
        if !wordy(a - c.len_utf8(), c) {
            break;
        }
        a -= c.len_utf8();
    }
    let mut b = p;
    while let Some(c) = next(b) {
        if !wordy(b, c) {
            break;
        }
        b += c.len_utf8();
    }
    Some((a, b))
}

/// Where the text of line `l` starts: after its container markers (quotes, list markers, task
/// boxes, nested ones too) and a heading's `#`s. `None` when the line has no text.
fn text_start(cx: &Ctx, l: usize) -> Option<usize> {
    let info = cx.info(l);
    if info.blank {
        return None;
    }
    let mut cs = info.content_start().min(info.end);
    let inside = cx.leaf_block_at(cs).is_some_and(|b| b.start <= cs);
    if !inside {
        let blocks = &cx.a.blocks;
        let here = blocks.partition_point(|b| b.start < cs);
        let bl = blocks.get(here).filter(|bl| bl.start < info.end)?;
        cs = bl.start;
        let t = &cx.text[cs..info.end];
        if ["[ ] ", "[x] ", "[X] "].iter().any(|task| t.starts_with(task)) {
            cs += 4;
        }
    }
    if cx.b.get(cs) == Some(&b'#') && cx.leaf_block_at(cs).is_some_and(|b| b.kind == BlockKind::Heading) {
        while cs < info.end && cx.b[cs] == b'#' {
            cs += 1;
        }
        while cs < info.end && matches!(cx.b[cs], b' ' | b'\t') {
            cs += 1;
        }
    }
    Some(cs)
}

fn in_opaque(cx: &Ctx, p: usize) -> bool {
    cx.leaf_block_at(p).is_some_and(|b| matches!(b.kind, BlockKind::CodeBlock | BlockKind::HtmlBlock | BlockKind::FrontMatter))
        || cx.leaf_block_at(p.saturating_sub(1)).is_some_and(|b| {
            matches!(b.kind, BlockKind::CodeBlock | BlockKind::HtmlBlock | BlockKind::FrontMatter) && b.end >= p
        })
}

fn empty_selection(cx: &Ctx, kind: Kind, elems: &[R], p: usize) -> Option<TextEdit> {
    if in_opaque(cx, p) {
        return None;
    }
    // Inside an element: take its delimiters off.
    let hit = elems.iter().enumerate().filter(|(_, el)| el.0 <= p && p <= el.1).min_by_key(|(_, el)| el.1 - el.0);
    if let Some((i, _)) = hit {
        let mut sp = Vec::new();
        removal(cx, kind, elems, &[i], &mut sp);
        let sp = normalize(sp);
        let q = map_pos(&sp, p, false);
        return Some(cx.finish(sp, (q, q)));
    }
    // A caret in a line's prefix (`> `, `1. `, `# `) acts at the start of the text: a marker is
    // not a word to format.
    let p = {
        let line = cx.line_of(p);
        p.max(text_start(cx, line).unwrap_or_else(|| cx.line_end(line)))
    };
    // The text may start inside code (an indented code block's indentation is not code yet).
    if in_opaque(cx, p) {
        return None;
    }
    // Right after toggling on with nothing selected (`**‸**`): toggling again takes the empty
    // pair away. Only an exact pair, and not the middle of a real delimiter: `**‸**` is not an
    // empty emphasis, and neither is `*‸*text**`.
    let (open, close) = kind.wrap("");
    let in_delimiter = cx.spans_touching(p, p).iter().any(|sp| sp.kind == SpanKind::Markup && sp.start < p && p < sp.end);
    if !in_delimiter && cx.text[..p].ends_with(open.as_str()) && cx.text[p..].starts_with(close.as_str()) {
        let d = open.chars().next().unwrap_or('*');
        let (a, b) = (p - open.len(), p + close.len());
        if !cx.text[..a].ends_with(d) && !cx.text[b..].starts_with(d) {
            return Some(cx.finish(vec![Splice::delete(a, b - a)], (a, a)));
        }
    }
    // In a code span the "word" is the whole span: a delimiter inside it would be literal.
    if kind != Kind::Code
        && let Some(code) = cx.spans_touching(p, p).into_iter().find(|sp| sp.kind == SpanKind::InlineCode && sp.start < p && p < sp.end)
    {
        let (a, b) = snap_flanking(cx, (code.start, code.end));
        let inner = &cx.text[a..b];
        let caret = p + open.len();
        return Some(cx.finish(vec![Splice::replace(a, b - a, format!("{open}{inner}{close}"))], (caret, caret)));
    }
    if let Some((a, b)) = word_at(cx, p) {
        // A word touching an element of the same kind (`word‸**st**`) joins it, like a selection.
        if kind != Kind::Code && (elements(cx, kind, a, b).iter().any(|el| el.1 == a || el.0 == b) || grow_over_atoms(cx, (a, b)) != (a, b)) {
            return toggle(cx, kind, a, b);
        }
        let word = &cx.text[a..b];
        let (open, close) = kind.wrap(word);
        let caret = p + open.len();
        return Some(cx.finish(vec![Splice::replace(a, b - a, format!("{open}{word}{close}"))], (caret, caret)));
    }
    let caret = p + open.len();
    Some(cx.finish(vec![Splice::insert(p, format!("{open}{close}"))], (caret, caret)))
}

// ----- links and images -----------------------------------------------------------------------

/// Markup spans owned by the element `a..b`, in order.
fn markups_of(cx: &Ctx, a: usize, b: usize) -> Vec<R> {
    let spans = &cx.a.spans;
    let lo = spans.partition_point(|s| s.start < a);
    spans[lo..]
        .iter()
        .take_while(|s| s.start < b)
        .filter(|s| s.kind == SpanKind::Markup && s.meta.is_some_and(|m| m.owner == (a, b)))
        .map(|s| (s.start, s.end))
        .collect()
}

pub(crate) fn link(cx: &Ctx, s: usize, e: usize) -> Option<TextEdit> {
    let mut links: Vec<R> = cx
        .spans_touching(s, e)
        .into_iter()
        .filter(|sp| sp.kind == SpanKind::Link && sp.start <= s && e <= sp.end)
        .map(|sp| (sp.start, sp.end))
        .collect();
    links.sort_by_key(|l| l.1 - l.0);
    let (mut s2, mut e2) = (s, e);
    for &(a, b) in &links {
        let m = markups_of(cx, a, b);
        if m.len() >= 2 {
            // Remove the link syntax, keep the text.
            let sp = vec![Splice::delete(a, m[0].1 - a), Splice::delete(m[1].0, b - m[1].0)];
            let sel = (map_pos(&sp, s, false), map_pos(&sp, e, false));
            return Some(cx.finish(sp, sel));
        }
        if m.is_empty() {
            // A bare URL: the whole URL is what gets linked.
            s2 = a;
            e2 = b;
            break;
        }
    }
    if s2 == e2 {
        if in_opaque(cx, s2) {
            return None;
        }
        if let Some((a, b)) = word_at(cx, s2) {
            let word = &cx.text[a..b];
            let caret = a + 1 + word.len() + 2;
            return Some(cx.finish(vec![Splice::replace(a, b - a, format!("[{word}]()"))], (caret, caret)));
        }
        let caret = s2 + 1;
        return Some(cx.finish(vec![Splice::insert(s2, "[]()")], (caret, caret)));
    }
    let segs = segments(cx, s2, e2);
    let Some(&(a, b)) = segs.first() else {
        let caret = e2 + 1;
        return if in_opaque(cx, e2) { None } else { Some(cx.finish(vec![Splice::insert(e2, "[]()")], (caret, caret))) };
    };
    let t = &cx.text[a..b];
    if let Some(m) = autolink::find(t).first()
        && m.start == 0
        && m.end == t.len()
    {
        // `www.` URLs need the scheme in a link, or they are relative paths.
        let dest = &m.destination;
        return Some(cx.finish(vec![Splice::replace(a, b - a, format!("[]({dest})"))], (a + 1, a + 1)));
    }
    let caret = a + 1 + t.len() + 2;
    Some(cx.finish(vec![Splice::replace(a, b - a, format!("[{t}]()"))], (caret, caret)))
}

fn escape_alt(alt: &str) -> String {
    let mut out = String::new();
    for c in alt.chars() {
        match c {
            '\\' | '[' | ']' => {
                out.push('\\');
                out.push(c);
            }
            '\n' | '\r' => out.push(' '),
            _ => out.push(c),
        }
    }
    out
}

fn format_destination(d: &str) -> String {
    let enc = |c: char| match c {
        '<' => "%3C".to_owned(),
        '>' => "%3E".to_owned(),
        '\n' => "%0A".to_owned(),
        '\r' => "%0D".to_owned(),
        // A backslash before punctuation would be read as an escape.
        '\\' => "\\\\".to_owned(),
        c => c.to_string(),
    };
    let body: String = d.chars().map(enc).collect();
    if body.chars().any(|c| matches!(c, ' ' | '\t' | '(' | ')')) { format!("<{body}>") } else { body }
}

pub(crate) fn image(cx: &Ctx, destination: &str, alt: &str, s: usize, e: usize) -> Option<TextEdit> {
    let selected = &cx.text[s..e];
    let alt = if alt.is_empty() && !selected.contains(['\n', '\r']) { selected } else { alt };
    let alt = escape_alt(alt);
    let dest = format_destination(destination);
    let text = format!("![{alt}]({dest})");
    let caret = if dest.is_empty() { s + 2 + alt.len() + 2 } else { s + text.len() };
    Some(cx.finish(vec![Splice::replace(s, e - s, text)], (caret, caret)))
}

pub(crate) fn link_to(cx: &Ctx, destination: &str, text: &str, s: usize, e: usize) -> Option<TextEdit> {
    let selected = &cx.text[s..e];
    let text = if text.is_empty() && !selected.contains(['\n', '\r']) { selected } else { text };
    let text = if text.is_empty() { destination } else { text };
    let label = escape_alt(text);
    let dest = format_destination(destination);
    let out = format!("[{label}]({dest})");
    let caret = s + out.len();
    Some(cx.finish(vec![Splice::replace(s, e - s, out)], (caret, caret)))
}
