//! A small character diff, so a programmatic replacement keeps the attribution of the text
//! it did not change. Prefix and suffix are trimmed, then Myers' O(ND) runs on the middle;
//! a replacement too different to diff cheaply is one hunk.

use crate::types::OffsetEncoding;

const MAX_D: usize = 600;

fn unit_len(enc: OffsetEncoding, c: char) -> u32 {
    match enc {
        OffsetEncoding::Utf8 => c.len_utf8() as u32,
        OffsetEncoding::Utf16 => c.len_utf16() as u32,
        OffsetEncoding::Utf32 => 1,
    }
}

/// `(offset in old, units deleted, units inserted)`, in ascending order; offsets are in the
/// old text. Hunks never start or end inside a code point.
pub(crate) fn hunks(enc: OffsetEncoding, old: &str, new: &str) -> Vec<(u32, u32, u32)> {
    let a: Vec<char> = old.chars().collect();
    let b: Vec<char> = new.chars().collect();
    let mut pre = 0;
    while pre < a.len() && pre < b.len() && a[pre] == b[pre] {
        pre += 1;
    }
    let mut suf = 0;
    while suf < a.len() - pre && suf < b.len() - pre && a[a.len() - 1 - suf] == b[b.len() - 1 - suf] {
        suf += 1;
    }
    let am = &a[pre..a.len() - suf];
    let bm = &b[pre..b.len() - suf];
    let mid = if am.is_empty() || bm.is_empty() {
        vec![(0, am.len(), bm.len(), 0)]
    } else {
        myers(am, bm).unwrap_or_else(|| vec![(0, am.len(), bm.len(), 0)])
    };
    // Char hunks -> unit hunks.
    let mut a_units = Vec::with_capacity(a.len() + 1);
    let mut b_units = Vec::with_capacity(b.len() + 1);
    let mut acc = 0u32;
    a_units.push(0);
    for &c in &a {
        acc += unit_len(enc, c);
        a_units.push(acc);
    }
    acc = 0;
    b_units.push(0);
    for &c in &b {
        acc += unit_len(enc, c);
        b_units.push(acc);
    }
    mid.into_iter()
        .filter(|&(_, dl, il, _)| dl > 0 || il > 0)
        .map(|(at, dl, il, bat)| {
            let (aa, ab) = (pre + at, pre + at + dl);
            let (ba, bb) = (pre + bat, pre + bat + il);
            (a_units[aa], a_units[ab] - a_units[aa], b_units[bb] - b_units[ba])
        })
        .collect()
}

/// `(a position, a deleted, b inserted, b position)` hunks.
fn myers(a: &[char], b: &[char]) -> Option<Vec<(usize, usize, usize, usize)>> {
    let (n, m) = (a.len() as isize, b.len() as isize);
    let max_d = MAX_D.min((n + m) as usize) as isize;
    let off = max_d + 1;
    let mut v = vec![0isize; (2 * max_d + 3) as usize];
    let mut trace: Vec<Vec<isize>> = Vec::new();
    let mut found = None;
    'outer: for d in 0..=max_d {
        trace.push(v.clone());
        let mut k = -d;
        while k <= d {
            let mut x = if k == -d || (k != d && v[(k - 1 + off) as usize] < v[(k + 1 + off) as usize]) {
                v[(k + 1 + off) as usize]
            } else {
                v[(k - 1 + off) as usize] + 1
            };
            let mut y = x - k;
            while x < n && y < m && a[x as usize] == b[y as usize] {
                x += 1;
                y += 1;
            }
            v[(k + off) as usize] = x;
            if x >= n && y >= m {
                found = Some(d);
                break 'outer;
            }
            k += 2;
        }
    }
    let d_end = found?;
    // Backtrack into per-step operations: (is_insert, a index, b index).
    let (mut x, mut y) = (n, m);
    let mut ops: Vec<(bool, usize, usize)> = Vec::new();
    for d in (1..=d_end).rev() {
        let v = &trace[d as usize];
        let k = x - y;
        let prev_k = if k == -d || (k != d && v[(k - 1 + off) as usize] < v[(k + 1 + off) as usize]) {
            k + 1
        } else {
            k - 1
        };
        let prev_x = v[(prev_k + off) as usize];
        let prev_y = prev_x - prev_k;
        while x > prev_x && y > prev_y {
            x -= 1;
            y -= 1;
        }
        if x == prev_x {
            ops.push((true, prev_x as usize, prev_y as usize));
        } else {
            ops.push((false, prev_x as usize, prev_y as usize));
        }
        x = prev_x;
        y = prev_y;
    }
    ops.reverse();
    let mut out: Vec<(usize, usize, usize, usize)> = Vec::new();
    for (ins, ai, bi) in ops {
        match out.last_mut() {
            Some(h) if h.0 + h.1 == ai && h.3 + h.2 == bi => {
                if ins {
                    h.2 += 1;
                } else {
                    h.1 += 1;
                }
            }
            _ => out.push(if ins { (ai, 0, 1, bi) } else { (ai, 1, 0, bi) }),
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply(old: &str, new: &str, enc: OffsetEncoding) {
        // Rebuild `new` from old + hunks to check they are consistent.
        let hs = hunks(enc, old, new);
        let a: Vec<char> = old.chars().collect();
        let b: Vec<char> = new.chars().collect();
        // Walk in chars (units == chars for this check, all-BMP test strings).
        let mut out = String::new();
        let mut ai = 0usize;
        let mut bi = 0usize;
        for (at, del, ins) in hs {
            let (at, del, ins) = (at as usize, del as usize, ins as usize);
            while ai < at {
                out.push(a[ai]);
                ai += 1;
                bi += 1;
            }
            ai += del;
            for _ in 0..ins {
                out.push(b[bi]);
                bi += 1;
            }
        }
        while ai < a.len() {
            out.push(a[ai]);
            ai += 1;
        }
        assert_eq!(out, new, "{old:?} -> {new:?}");
    }

    #[test]
    fn hunks_reproduce_new() {
        for (o, n) in [
            ("foo", "**foo**"),
            ("| a | b |\n|-|-|", "| a   | b |\n|-----|---|"),
            ("1. a\n1. b", "1. a\n2. b"),
            ("", "x"),
            ("x", ""),
            ("abcdef", "azcxef"),
        ] {
            apply(o, n, OffsetEncoding::Utf16);
        }
    }

    #[test]
    fn wrapping_is_two_insertions() {
        assert_eq!(hunks(OffsetEncoding::Utf16, "foo", "**foo**"), vec![(0, 0, 2), (3, 0, 2)]);
    }
}
