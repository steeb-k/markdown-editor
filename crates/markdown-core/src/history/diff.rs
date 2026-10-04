//! A line-based diff (Myers' O(ND) algorithm) with no dependency. Lines keep their terminators, so a
//! CRLF line and an LF line differ and a text without a final newline differs from one with it.
//! Common leading and trailing lines are trimmed first, which makes the usual case (a small edit in
//! a large document) cost one pass over the lines. When the middle is so different that the search
//! would pass `MAX_EDITS` it is reported as one removal followed by one addition: still a correct
//! script, only not minimal.

use std::collections::HashMap;
use std::ops::Range;

/// Edit distance past which the differing middle is replaced wholesale instead of searched.
const MAX_EDITS: usize = 2000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffKind {
    Equal,
    Added,
    Removed,
}

/// A run of whole lines. `old_range` and `new_range` are byte ranges into the old and the new text;
/// an `Added` hunk has an empty `old_range` at its insertion point and a `Removed` hunk an empty
/// `new_range`. `text` is the lines themselves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunk {
    pub kind: DiffKind,
    pub old_range: Range<usize>,
    pub new_range: Range<usize>,
    pub text: String,
}

/// Lines added and removed between two texts.
pub fn line_counts(old: &str, new: &str) -> (u32, u32) {
    let (mut added, mut removed) = (0u32, 0u32);
    for h in diff_lines(old, new) {
        let n = h.text.split_inclusive('\n').count() as u32;
        match h.kind {
            DiffKind::Added => added += n,
            DiffKind::Removed => removed += n,
            DiffKind::Equal => {}
        }
    }
    (added, removed)
}

/// The script turning `old` into `new`, as hunks in order. Applying `Equal` and `Added` text gives
/// `new`; applying `Equal` and `Removed` text gives `old`.
pub fn diff_lines<'a>(old: &'a str, new: &'a str) -> Vec<DiffHunk> {
    let a: Vec<&str> = old.split_inclusive('\n').collect();
    let b: Vec<&str> = new.split_inclusive('\n').collect();
    // Intern the lines so the search compares integers.
    let mut ids: HashMap<&str, u32> = HashMap::new();
    let mut intern = |ls: &[&'a str]| -> Vec<u32> {
        ls.iter()
            .map(|l| {
                let n = ids.len() as u32;
                *ids.entry(*l).or_insert(n)
            })
            .collect()
    };
    let ia = intern(&a);
    let ib = intern(&b);

    let mut pre = 0;
    while pre < ia.len() && pre < ib.len() && ia[pre] == ib[pre] {
        pre += 1;
    }
    let mut suf = 0;
    while suf < ia.len() - pre && suf < ib.len() - pre && ia[ia.len() - 1 - suf] == ib[ib.len() - 1 - suf] {
        suf += 1;
    }
    let ma = &ia[pre..ia.len() - suf];
    let mb = &ib[pre..ib.len() - suf];
    // `ops[i]`: 0 keep, 1 delete from old, 2 insert from new, over the middle.
    let ops = middle_script(ma, mb);

    let mut offs_a = Vec::with_capacity(a.len() + 1);
    let mut o = 0;
    offs_a.push(0);
    for l in &a {
        o += l.len();
        offs_a.push(o);
    }
    let mut offs_b = Vec::with_capacity(b.len() + 1);
    o = 0;
    offs_b.push(0);
    for l in &b {
        o += l.len();
        offs_b.push(o);
    }

    let mut hunks: Vec<DiffHunk> = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    let push = |kind: DiffKind, i0: usize, i1: usize, j0: usize, j1: usize, hunks: &mut Vec<DiffHunk>| {
        if i0 == i1 && j0 == j1 {
            return;
        }
        let (or, nr) = (offs_a[i0]..offs_a[i1], offs_b[j0]..offs_b[j1]);
        if let Some(last) = hunks.last_mut()
            && last.kind == kind
            && last.old_range.end == or.start
            && last.new_range.end == nr.start
        {
            last.old_range.end = or.end;
            last.new_range.end = nr.end;
            last.text.push_str(&match kind {
                DiffKind::Removed => old[or].to_string(),
                _ => new[nr].to_string(),
            });
            return;
        }
        let text = match kind {
            DiffKind::Removed => old[or.clone()].to_string(),
            _ => new[nr.clone()].to_string(),
        };
        hunks.push(DiffHunk { kind, old_range: or, new_range: nr, text });
    };
    push(DiffKind::Equal, 0, pre, 0, pre, &mut hunks);
    i += pre;
    j += pre;
    let mut k = 0;
    while k < ops.len() {
        let kind = ops[k];
        let mut n = 0;
        while k + n < ops.len() && ops[k + n] == kind {
            n += 1;
        }
        match kind {
            0 => push(DiffKind::Equal, i, i + n, j, j + n, &mut hunks),
            1 => push(DiffKind::Removed, i, i + n, j, j, &mut hunks),
            _ => push(DiffKind::Added, i, i, j, j + n, &mut hunks),
        }
        if kind != 2 {
            i += n;
        }
        if kind != 1 {
            j += n;
        }
        k += n;
    }
    push(DiffKind::Equal, a.len() - suf, a.len(), b.len() - suf, b.len(), &mut hunks);
    hunks
}

fn middle_script(a: &[u32], b: &[u32]) -> Vec<u8> {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return vec![2; m];
    }
    if m == 0 {
        return vec![1; n];
    }
    let max = (n + m).min(MAX_EDITS);
    let off = max as isize + 1;
    let mut v = vec![0isize; 2 * max + 3];
    // `trace[d]` is the part of `v` that round `d` could have touched, saved before the round.
    let mut trace: Vec<Vec<isize>> = Vec::new();
    let mut found = None;
    'outer: for d in 0..=max as isize {
        trace.push(v[(off - d - 1) as usize..=(off + d + 1) as usize].to_vec());
        let mut k = -d;
        while k <= d {
            let mut x = if k == -d || (k != d && v[(off + k - 1) as usize] < v[(off + k + 1) as usize]) {
                v[(off + k + 1) as usize]
            } else {
                v[(off + k - 1) as usize] + 1
            };
            let mut y = x - k;
            while (x as usize) < n && (y as usize) < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            v[(off + k) as usize] = x;
            if x as usize >= n && y as usize >= m {
                found = Some(d);
                break 'outer;
            }
            k += 2;
        }
    }
    let Some(d_end) = found else {
        let mut ops = vec![1; n];
        ops.extend(std::iter::repeat_n(2, m));
        return ops;
    };
    // Walk back through the saved rounds.
    let mut ops: Vec<u8> = Vec::new();
    let (mut x, mut y) = (n as isize, m as isize);
    for d in (0..=d_end).rev() {
        let tr = &trace[d as usize];
        let at = |k: isize| tr[(k + d + 1) as usize];
        let k = x - y;
        let prev_k = if k == -d || (k != d && at(k - 1) < at(k + 1)) { k + 1 } else { k - 1 };
        let px = at(prev_k);
        let py = px - prev_k;
        while x > px && y > py {
            x -= 1;
            y -= 1;
            ops.push(0);
        }
        if d > 0 {
            if x == px {
                ops.push(2);
            } else {
                ops.push(1);
            }
        }
        x = px;
        y = py;
    }
    ops.reverse();
    // Within a run of changes, removals come before additions, so a replaced line reads "old, then new".
    let mut k = 0;
    while k < ops.len() {
        if ops[k] == 0 {
            k += 1;
            continue;
        }
        let start = k;
        while k < ops.len() && ops[k] != 0 {
            k += 1;
        }
        ops[start..k].sort_unstable();
    }
    ops
}
