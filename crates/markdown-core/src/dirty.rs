//! Dirty-range computation: compare old and new span lists around an edit.

use crate::analysis::{Analysis, ISpan};

/// Smallest range of the NEW text, extended to whole lines, outside which every span is
/// identical (kind and extent, old ones shifted by the length delta) in old and new.
/// `(bs, be)` is the replaced byte range of the old text, `ins` the inserted byte length.
pub(crate) fn dirty_range(
    old: &Analysis,
    new: &Analysis,
    bs: usize,
    be: usize,
    ins: usize,
    new_len: usize,
) -> (usize, usize) {
    let delta = ins as isize - (be - bs) as isize;
    let shift = |x: usize| (x as isize + delta) as usize;
    let mut lo = bs;
    let mut hi = bs + ins;

    // Skip the common head (spans entirely before the edit, unchanged) and tail (spans
    // entirely after it, unchanged once shifted); only the middle needs the full comparison.
    let (old_all, new_all) = (&old.spans, &new.spans);
    let mut head = 0;
    while head < old_all.len()
        && head < new_all.len()
        && old_all[head].end <= bs
        && old_all[head].cmp_key(&new_all[head]).is_eq()
    {
        head += 1;
    }
    let (mut ot, mut nt) = (old_all.len(), new_all.len());
    while ot > head && nt > head && old_all[ot - 1].start >= be {
        let o = &old_all[ot - 1];
        let shifted = ISpan { start: shift(o.start), end: shift(o.end), kind: o.kind, meta: None };
        if shifted.cmp_key(&new_all[nt - 1]).is_eq() {
            ot -= 1;
            nt -= 1;
        } else {
            break;
        }
    }
    let (old_mid, new_mid) = (&old_all[head..ot], &new_all[head..nt]);

    // Old spans mapped into new coordinates; spans with an endpoint inside the edited
    // region have no mapping and simply count as changed.
    let mut mapped: Vec<ISpan> = Vec::with_capacity(old_mid.len());
    for s in old_mid {
        let ms = if s.start < bs {
            Some(s.start)
        } else if s.start >= be {
            Some(shift(s.start))
        } else {
            None
        };
        let me = if s.end <= bs {
            Some(s.end)
        } else if s.end >= be {
            Some(shift(s.end))
        } else {
            None
        };
        match (ms, me) {
            (Some(a), Some(b)) if a < b => {
                mapped.push(ISpan { start: a, end: b, kind: s.kind, meta: None });
            }
            _ => {
                let a = ms.unwrap_or(bs);
                let b = me.unwrap_or(bs + ins);
                if a <= b {
                    lo = lo.min(a);
                    hi = hi.max(b);
                }
            }
        }
    }
    mapped.sort_by(|a, b| a.cmp_key(b));

    // Merge: anything present on only one side is dirty.
    let (a, b) = (&mapped, new_mid);
    let (mut i, mut j) = (0, 0);
    while i < a.len() || j < b.len() {
        let only: Option<&ISpan> = if i == a.len() {
            j += 1;
            Some(&b[j - 1])
        } else if j == b.len() {
            i += 1;
            Some(&a[i - 1])
        } else {
            match a[i].cmp_key(&b[j]) {
                std::cmp::Ordering::Equal => {
                    i += 1;
                    j += 1;
                    None
                }
                std::cmp::Ordering::Less => {
                    i += 1;
                    Some(&a[i - 1])
                }
                std::cmp::Ordering::Greater => {
                    j += 1;
                    Some(&b[j - 1])
                }
            }
        };
        if let Some(s) = only {
            lo = lo.min(s.start);
            hi = hi.max(s.end);
        }
    }

    // Whole lines.
    let lines = &new.lines;
    let lo = lines.line_start(lo.min(new_len));
    let hi = hi.min(new_len);
    let hi = if hi > lo && lines.is_line_start(hi) { hi } else { lines.next_line_start(hi) };
    (lo, hi.max(lo))
}
