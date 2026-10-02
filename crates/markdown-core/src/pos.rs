//! Parts of speech: what a platform tagger should look at, and how to bring its answer back.
//!
//! The core does not tag. A shell takes [`Document::pos_units`], builds each unit's text (see
//! [`PosUnit`]), tags it with whatever its platform offers, and hands the words to
//! [`PosUnit::map_tags`], which returns document ranges. A word cut by inline markup comes
//! back as one tag per piece.

use crate::document::Document;
use crate::types::*;

impl PosUnit {
    /// Where each piece starts in the joined text, and the joined length.
    fn joined_starts(&self) -> (Vec<u32>, u32) {
        let mut starts = Vec::with_capacity(self.prose.len());
        let mut at = 0u32;
        for (i, p) in self.prose.iter().enumerate() {
            if self.separated.get(i).copied().unwrap_or(false) && i > 0 {
                at += 1;
            }
            starts.push(at);
            at += p.len();
        }
        (starts, at)
    }

    /// Length of the joined text, in offset units.
    pub fn joined_len(&self) -> u32 {
        self.joined_starts().1
    }

    /// Words of the joined text (`range` in its coordinates) as document ranges. A word that
    /// spans pieces gives one tag per piece; a range that lies in a separator, or beyond the
    /// text, gives none. Tags come out in the order of the words and pieces.
    pub fn map_tags(&self, words: &[PosTag]) -> Vec<PosTag> {
        let (starts, _) = self.joined_starts();
        let mut out = Vec::with_capacity(words.len());
        for w in words {
            if w.range.is_empty() {
                continue;
            }
            let first = starts.partition_point(|&s| s <= w.range.start).saturating_sub(1);
            for (i, p) in self.prose.iter().enumerate().skip(first) {
                let js = starts[i];
                if js >= w.range.end {
                    break;
                }
                let je = js + p.len();
                let (s, e) = (w.range.start.max(js), w.range.end.min(je));
                if s < e {
                    out.push(PosTag { range: TextRange::new(p.start + (s - js), p.start + (e - js)), class: w.class });
                }
            }
        }
        out
    }
}

/// A block (or lone piece of prose), its pieces and where each is set off from the one before.
type Group = ((usize, usize), Vec<(usize, usize)>, Vec<bool>);

/// A block with more prose than this (bytes) comes as several units.
const LONG_UNIT: usize = 12 * 1024;

/// Cuts of a long block are at least this far apart (bytes), even in text so regular that
/// every word start qualifies.
const MIN_UNIT: usize = 512;

/// Where a long block is cut into units: at the start of a word (a prose position after
/// whitespace), chosen by a hash of the sixteen bytes before it, so the cuts depend only on
/// the text right there (the bytes before it, and the candidates within [`MIN_UNIT`] before
/// it): an edit moves no cut more than about `MIN_UNIT` after it, and the units elsewhere keep
/// their text (and the shell's cache of their tags). After a sentence's
/// end about one word start in sixteen qualifies (units of a dozen sentences or so); elsewhere
/// one in a thousand (text without terminators still comes in pieces of a few kilobytes).
fn is_cut(b: &[u8], p: usize) -> bool {
    let ws = |c: u8| matches!(c, b' ' | b'\t' | b'\n' | b'\r');
    if p == 0 || p >= b.len() || ws(b[p]) || (0x80..0xC0).contains(&b[p]) {
        return false;
    }
    let cjk_stop = |end: usize| ["\u{3002}", "\u{FF01}", "\u{FF1F}"].iter().any(|t| b[..end].ends_with(t.as_bytes()));
    let terminated = if ws(b[p - 1]) {
        let mut q = p - 1;
        while q > 0 && ws(b[q]) {
            q -= 1;
        }
        matches!(b[q], b'.' | b'!' | b'?') || cjk_stop(q + 1)
    } else if cjk_stop(p) {
        true
    } else {
        return false;
    };
    // FNV-1a.
    let mut h: u32 = 0x811c_9dc5;
    for &c in &b[p.saturating_sub(16)..p] {
        h = (h ^ c as u32).wrapping_mul(0x0100_0193);
    }
    h ^= h >> 13;
    h.is_multiple_of(if terminated { 16 } else { 1024 })
}

/// Cuts a long block's group into units at [`is_cut`] positions; a piece holding a cut is
/// split there (the pieces of all units still cover exactly the block's prose).
fn split_long(b: &[u8], (range, pieces, separated): Group) -> Vec<Group> {
    let mut out: Vec<Group> = Vec::new();
    let mut cur: Group = ((range.0, range.1), Vec::new(), Vec::new());
    let cut_at = |p: usize, cur: &mut Group, out: &mut Vec<Group>| {
        if cur.1.is_empty() {
            return;
        }
        let done = std::mem::replace(cur, ((p, range.1), Vec::new(), Vec::new()));
        out.push(((done.0.0, p), done.1, done.2));
    };
    // A candidate is a cut unless another candidate lies less than MIN_UNIT before it: a rule
    // that looks only at the text just before, so an edit cannot move cuts further on.
    let mut last_candidate: Option<usize> = None;
    let mut cut_here = |p: usize| {
        if !is_cut(b, p) {
            return false;
        }
        let spaced = last_candidate.is_none_or(|c| p - c >= MIN_UNIT);
        last_candidate = Some(p);
        spaced
    };
    for (i, &(s, e)) in pieces.iter().enumerate() {
        let mut start = s;
        let mut sep = separated[i];
        if cut_here(s) {
            cut_at(s, &mut cur, &mut out);
            sep = false;
        }
        for p in s + 1..e {
            if cut_here(p) {
                cur.2.push(if cur.1.is_empty() { false } else { sep });
                cur.1.push((start, p));
                cut_at(p, &mut cur, &mut out);
                start = p;
                sep = false;
            }
        }
        cur.2.push(if cur.1.is_empty() { false } else { sep });
        cur.1.push((start, e));
    }
    if !cur.1.is_empty() {
        out.push(cur);
    }
    out
}

pub(crate) fn pos_units(doc: &Document, within: Option<TextRange>) -> Vec<PosUnit> {
    let a = doc.analysis();
    let b = doc.text().as_bytes();
    let prose = &a.prose;
    let block_of = |s: usize, e: usize| -> Option<usize> {
        let i = a.blocks.partition_point(|bl| bl.start <= s).checked_sub(1)?;
        (a.blocks[i].end >= e).then_some(i)
    };
    let (mut lo, mut hi) = match doc.within_bytes(within) {
        None => (0, prose.len()),
        Some((ws, we)) => (
            prose.partition_point(|p| p.1 <= ws),
            prose.partition_point(|p| p.0 < we.max(ws + 1)),
        ),
    };
    // Whole units: reach out to the other pieces of the first and last block.
    if lo < hi {
        let first = block_of(prose[lo].0, prose[lo].1);
        while lo > 0 && first.is_some() && block_of(prose[lo - 1].0, prose[lo - 1].1) == first {
            lo -= 1;
        }
        let last = block_of(prose[hi - 1].0, prose[hi - 1].1);
        while hi < prose.len() && last.is_some() && block_of(prose[hi].0, prose[hi].1) == last {
            hi += 1;
        }
    }
    // Group by block (a piece outside every block is a unit of its own).
    let mut groups: Vec<Group> = Vec::new();
    let mut current: Option<usize> = None;
    for &(s, e) in &prose[lo..hi] {
        let bi = block_of(s, e);
        match (bi, current, groups.last_mut()) {
            (Some(bi), Some(cur), Some(g)) if bi == cur => {
                let table = a.blocks[bi].kind == BlockKind::Table;
                let last_end = g.1.last().map_or(s, |p| p.1);
                let gap = &b[last_end..s];
                // Inline code between two pieces that touch it (`word`code`word`) sets them apart: it is
                // drawn as a separate thing, so a tagger must not read the two pieces as one word. (Markup
                // that only styles, `**`, `_`, link brackets, leaves a word whole.) Where a piece already
                // ends or starts with a blank, the words are apart anyway.
                let blank = |c: u8| matches!(c, b' ' | b'\t' | b'\n' | b'\r');
                let by_code = gap.contains(&b'`') && last_end > 0 && !blank(b[last_end - 1]) && s < b.len() && !blank(b[s]);
                g.2.push(table || by_code || gap.iter().any(|&c| matches!(c, b'\n' | b'\r')));
                g.1.push((s, e));
            }
            (Some(bi), _, _) => {
                let bl = &a.blocks[bi];
                groups.push(((bl.start, bl.end), vec![(s, e)], vec![false]));
                current = Some(bi);
            }
            (None, _, _) => {
                groups.push(((s, e), vec![(s, e)], vec![false]));
                current = None;
            }
        }
    }
    // A very long block is tagged in pieces, so an edit re-tags a few kilobytes, not all of it.
    let window = doc.within_bytes(within);
    let groups: Vec<Group> = groups
        .into_iter()
        .flat_map(|g| {
            let long = g.1.iter().map(|p| p.1 - p.0).sum::<usize>() > LONG_UNIT;
            if !long {
                return vec![g];
            }
            let mut subs = split_long(b, g);
            if let Some((ws, we)) = window {
                subs.retain(|g| g.1.iter().any(|p| p.1 > ws && p.0 < we.max(ws + 1)));
            }
            subs
        })
        .collect();
    let ranges: Vec<(usize, usize)> = groups.iter().map(|g| g.0).collect();
    let pieces: Vec<(usize, usize)> = groups.iter().flat_map(|g| g.1.iter().copied()).collect();
    let unit_ranges = doc.convert_nested(&ranges);
    let piece_ranges = doc.convert_nested(&pieces);
    let mut next = 0;
    groups
        .into_iter()
        .zip(unit_ranges)
        .map(|((_, ps, separated), (us, ue))| {
            let prose = piece_ranges[next..next + ps.len()].iter().map(|&(s, e)| TextRange::new(s, e)).collect();
            next += ps.len();
            PosUnit { range: TextRange::new(us, ue), prose, separated }
        })
        .collect()
}
