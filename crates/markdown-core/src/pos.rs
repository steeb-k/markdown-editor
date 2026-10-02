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
                g.2.push(table || b[last_end..s].iter().any(|&c| matches!(c, b'\n' | b'\r')));
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
