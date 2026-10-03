//! Quick open's matcher: a subsequence match of the query in a title or path, the best
//! alignment by score. Contiguous runs and word starts score higher, gaps cost a little.

const NEG: i32 = i32::MIN / 2;
const CONSECUTIVE: i32 = 16;
const GAP: i32 = 1;
/// Longest target looked at, in characters; the rest of a longer one cannot be matched.
const MAX_TARGET: usize = 256;

/// The score of the best alignment of `query` (case-folded characters) in `target`, and the
/// matched character indices of `target`. `None` if `query` is not a subsequence.
pub(crate) fn fuzzy(query: &[char], target: &str) -> Option<(i32, Vec<usize>)> {
    let chars: Vec<char> = target.chars().take(MAX_TARGET).collect();
    let (n, m) = (query.len(), chars.len());
    if n == 0 || n > m {
        return None;
    }
    let lower: Vec<char> = chars.iter().map(|c| c.to_lowercase().next().unwrap_or(*c)).collect();
    // Cheap rejection: a subsequence test first.
    let mut k = 0;
    for &c in &lower {
        if k < n && c == query[k] {
            k += 1;
        }
    }
    if k < n {
        return None;
    }
    let bonus = |j: usize| -> i32 {
        if j == 0 {
            return 8;
        }
        let p = chars[j - 1];
        if matches!(p, ' ' | '/' | '-' | '_' | '.' | '\\') {
            8
        } else if p.is_lowercase() && chars[j].is_uppercase() {
            6
        } else {
            0
        }
    };
    // m_[i][j]: best score with query[i] matched at target[j]; g[i][j]: best over k <= j of
    // m_[i][k] minus the gap since; gk: the k that gave it.
    let mut m_ = vec![NEG; n * m];
    let mut g = vec![NEG; n * m];
    let mut gk = vec![0usize; n * m];
    let mut from_gap = vec![false; n * m];
    for i in 0..n {
        for j in i..m {
            let at = i * m + j;
            if lower[j] == query[i] {
                let prev = if i == 0 {
                    Some((0, false))
                } else if j == 0 {
                    None
                } else {
                    let consecutive = m_[(i - 1) * m + j - 1];
                    let gap = g[(i - 1) * m + j - 1];
                    let c = (consecutive > NEG).then_some(consecutive + CONSECUTIVE);
                    let d = (gap > NEG).then_some(gap);
                    match (c, d) {
                        (Some(c), Some(d)) if d > c => Some((d, true)),
                        (Some(c), _) => Some((c, false)),
                        (None, Some(d)) => Some((d, true)),
                        (None, None) => None,
                    }
                };
                if let Some((p, gapped)) = prev {
                    m_[at] = p + 1 + bonus(j);
                    from_gap[at] = gapped;
                }
            }
            // The best end for query[..=i] at or before j.
            let (own, carried) = (m_[at], if j > 0 && g[at - 1] > NEG { g[at - 1] - GAP } else { NEG });
            if own >= carried {
                g[at] = own;
                gk[at] = j;
            } else {
                g[at] = carried;
                gk[at] = gk[at - 1];
            }
        }
    }
    // The best place for the last character.
    let last = (n - 1) * m;
    let (mut best, mut bj) = (NEG, 0);
    for j in n - 1..m {
        if m_[last + j] > best {
            best = m_[last + j];
            bj = j;
        }
    }
    if best <= NEG {
        return None;
    }
    let mut pos = vec![0usize; n];
    let (mut i, mut j) = (n - 1, bj);
    loop {
        pos[i] = j;
        if i == 0 {
            break;
        }
        j = if from_gap[i * m + j] { gk[(i - 1) * m + j - 1] } else { j - 1 };
        i -= 1;
    }
    // An exact start of the whole target is the best match there is.
    let prefix = if pos.iter().enumerate().all(|(i, &p)| p == i) { 10 } else { 0 };
    // Shorter targets first among equals.
    Some((best + prefix - (m as i32) / 8, pos))
}
