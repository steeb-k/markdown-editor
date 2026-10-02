//! `format_state`: what is active at the selection.

use super::*;

pub(crate) fn format_state(doc: &Document, selection: TextRange) -> FormatState {
    let cx = Ctx::new(doc);
    let (s, e) = cx.sel(selection);
    let line = cx.line_of(s);
    let info = cx.info(line);
    let touches = |kind: BlockKind| {
        cx.leaf_block_at(s).is_some_and(|b| b.kind == kind)
            || (s > 0 && cx.leaf_block_at(s - 1).is_some_and(|b| b.kind == kind && b.end >= s))
    };
    // The heading block on this line (blocks are sorted and disjoint).
    let heading_level = {
        let blocks = &cx.a.blocks;
        let i = blocks.partition_point(|b| b.start < cx.next_start(line));
        blocks[i.saturating_sub(3)..i]
            .iter()
            .rev()
            .find(|b| b.kind == BlockKind::Heading && cx.line_of(b.end.saturating_sub(1)) >= line)
            .and_then(|b| b.heading_level)
            .unwrap_or(0)
    };
    let in_code_block = touches(BlockKind::CodeBlock);
    FormatState {
        strong: inline::is_active(&cx, inline::Kind::Strong, s, e),
        emphasis: inline::is_active(&cx, inline::Kind::Emphasis, s, e),
        strikethrough: inline::is_active(&cx, inline::Kind::Strike, s, e),
        inline_code: inline::is_active(&cx, inline::Kind::Code, s, e),
        link: is_link(&cx, s, e),
        heading_level,
        // A `> ` inside a fenced code block is code, not a quote.
        in_quote: (info.has_quote() && !in_code_block && !cx.is_opaque_block(info.start))
            || cx.spans_touching(s, s).iter().any(|sp| sp.kind == SpanKind::BlockQuote),
        list: list_kind(&cx, &info),
        in_code_block,
        in_table: cx.a.tables.iter().any(|t| {
            let last = t.rows.last().map_or(t.end, |r| r.end).max(t.end);
            cx.line_start(cx.line_of(t.start)) <= s && s <= cx.line_end(cx.line_of(last.min(cx.b.len())))
        }),
    }
}

#[cfg(test)]
pub(crate) fn is_link_for_tests(cx: &Ctx, s: usize, e: usize) -> bool {
    is_link(cx, s, e)
}

fn is_link(cx: &Ctx, s: usize, e: usize) -> bool {
    // A link that holds the selection holds its start: only the spans at that point need looking at.
    cx.spans_touching(s, s).iter().any(|sp| sp.kind == SpanKind::Link && sp.start <= s && e <= sp.end)
}

/// The list the line belongs to: its own marker, or the item it continues.
fn list_kind(cx: &Ctx, info: &LineInfo) -> ListKind {
    let own = info.list_kind();
    if own != ListKind::None || info.blank {
        return own;
    }
    // The first paragraph of an item (also on lazy continuation lines).
    if let Some(b) = cx.leaf_block_at(info.ind_end) {
        let fi = cx.info(cx.line_of(b.start));
        if fi.marker.is_some_and(|m| m.content <= b.start) {
            return fi.list_kind();
        }
    }
    // Indented continuation: the nearest item whose content column is at or before this line's.
    let w = cx.ws_width(info.qp_end, info.ind_end);
    if w == 0 {
        return ListKind::None;
    }
    for l in (0..info.line).rev() {
        let li = cx.info(l);
        if li.blank {
            continue;
        }
        match li.marker {
            Some(m) if cx.ws_width(li.qp_end, m.content) <= w => return li.list_kind(),
            Some(_) => {}
            None if cx.ws_width(li.qp_end, li.ind_end) == 0 => return ListKind::None,
            None => {}
        }
    }
    ListKind::None
}
