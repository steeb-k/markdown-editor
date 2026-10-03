//! Wikilinks (`[[Title]]`, `[[Title|label]]`, `[[Title#Heading]]`) and inline tags (`#tag`).
//!
//! Like bare URLs ([`crate::autolink`]) they are not part of the parser: they are found in the
//! runs of plain text the parser reports, so they never occur inside code, links, images, raw
//! HTML or front matter. The analysis, the HTML renderer and the library index all use [`find_in`],
//! so the editor, the preview and the index cannot disagree about what is a link or a tag.
//!
//! * A wikilink is `[[`, a non-empty target and/or `#heading`, an optional `|label`, `]]`, all on
//!   one line and without brackets inside (in a table cell a `|` ends the cell, so a label
//!   cannot be written there). `[[#Heading]]` links into the same note. A `|` with
//!   an empty label does not make a link.
//! * A tag is a `#` that is not preceded by a letter, digit, `#`, `&` (an entity such as
//!   `&#x41;`) or an odd run of backslashes, followed by a letter, then letters, digits, `_`,
//!   `-` and `/` (`#a/b` nests); trailing `-` and `/` are not part of it. A combining mark counts
//!   as part of the letter before it. A tag never starts
//!   inside a wikilink or one of the `exclude` ranges (bare URLs), and callers do not ask for
//!   tags on a heading line.

/// A wikilink. Offsets are UTF-8 byte offsets into the searched string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wikilink {
    /// The whole `[[...]]`.
    pub start: usize,
    pub end: usize,
    /// The target without surrounding blanks (empty for `[[#Heading]]`).
    pub target: (usize, usize),
    /// The heading after `#`, without blanks.
    pub heading: Option<(usize, usize)>,
    /// The label after `|`, without blanks.
    pub label: Option<(usize, usize)>,
    /// Where `#heading` starts (at the `#`), when there is a heading.
    hash: Option<usize>,
    /// Where `|label` starts (at the `|`), when there is a label.
    pipe: Option<usize>,
}

impl Wikilink {
    /// The syntax Live mode may hide, in order: `[[`; the target and heading together with the
    /// `|` when there is a label (only the label is then shown), else just `#heading` (just the
    /// `#` for `[[#Heading]]`, which has no target to show); `]]`.
    pub fn markup(&self) -> Vec<(usize, usize)> {
        let mut v = vec![(self.start, self.start + 2)];
        if let Some(p) = self.pipe {
            v.push((self.start + 2, p + 1));
        } else if let Some(h) = self.hash {
            // `[[#Heading]]` shows the heading: only the `#` goes.
            let to = match self.heading {
                Some(head) if self.target.0 >= self.target.1 => head.0,
                _ => self.end - 2,
            };
            v.push((h, to));
        }
        v.push((self.end - 2, self.end));
        v
    }
}

/// An inline tag, `#` included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tag {
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Found {
    Wikilink(Wikilink),
    Tag(Tag),
}

impl Found {
    pub fn start(&self) -> usize {
        match self {
            Found::Wikilink(w) => w.start,
            Found::Tag(t) => t.start,
        }
    }
}

/// The wikilink starting at `start` (which must hold `[[`) and ending no later than `to`.
pub fn parse_wikilink(text: &str, start: usize, to: usize) -> Option<Wikilink> {
    let b = &text.as_bytes()[..to];
    if !b[start..].starts_with(b"[[") {
        return None;
    }
    let mut close = start + 2;
    while close < to && !matches!(b[close], b'[' | b']' | b'\n' | b'\r') {
        close += 1;
    }
    if close + 1 >= to || b[close] != b']' || b[close + 1] != b']' {
        return None;
    }
    let (is, ie) = (start + 2, close);
    let pipe = b[is..ie].iter().position(|&c| c == b'|').map(|p| is + p);
    let left_end = pipe.unwrap_or(ie);
    let hash = b[is..left_end].iter().position(|&c| c == b'#').map(|p| is + p);
    let trim = |mut s: usize, mut e: usize| {
        while s < e && matches!(b[s], b' ' | b'\t') {
            s += 1;
        }
        while e > s && matches!(b[e - 1], b' ' | b'\t') {
            e -= 1;
        }
        (s, e)
    };
    let target = trim(is, hash.unwrap_or(left_end));
    let heading = hash.map(|h| trim(h + 1, left_end)).filter(|h| h.0 < h.1);
    let label = pipe.map(|p| trim(p + 1, ie));
    if label.is_some_and(|l| l.0 >= l.1) || (target.0 >= target.1 && heading.is_none()) {
        return None;
    }
    // `[[a#]]` has a hash and no heading: the `#` stays visible, so it is not markup.
    let hash = hash.filter(|_| heading.is_some());
    Some(Wikilink { start, end: close + 2, target, heading, label, hash, pipe })
}

/// Wikilinks and, when `tags` is set, tags inside `text[from..to]` (byte offsets on char
/// boundaries), in order. The character before `from` decides whether a tag may start there.
/// Nothing overlaps an `exclude` range (sorted, disjoint).
pub fn find_in(text: &str, from: usize, to: usize, exclude: &[(usize, usize)], tags: bool) -> Vec<Found> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = from;
    let mut skip = exclude.partition_point(|x| x.1 <= from);
    while i < to {
        // The cheap filter: only `[` and `#` start anything.
        let c = b[i];
        if c != b'[' && !(tags && c == b'#') {
            i += 1;
            continue;
        }
        while skip < exclude.len() && exclude[skip].1 <= i {
            skip += 1;
        }
        if let Some(&(xs, xe)) = exclude.get(skip)
            && xs <= i
            && i < xe
        {
            i = xe;
            continue;
        }
        let limit = exclude.get(skip).map_or(to, |x| x.0.clamp(i, to));
        if c == b'[' {
            if b.get(i + 1) == Some(&b'[')
                && !escaped(b, i)
                && let Some(w) = parse_wikilink(text, i, limit)
            {
                i = w.end;
                out.push(Found::Wikilink(w));
                continue;
            }
        } else if let Some(end) = tag_end(text, i, limit) {
            out.push(Found::Tag(Tag { start: i, end }));
            i = end;
            continue;
        }
        i += 1;
    }
    out
}

/// Is the byte at `i` escaped by an odd run of backslashes before it?
fn escaped(b: &[u8], i: usize) -> bool {
    b[..i].iter().rev().take_while(|&&c| c == b'\\').count() % 2 == 1
}

/// End of the tag starting with the `#` at `i`, if there is one.
fn tag_end(text: &str, i: usize, to: usize) -> Option<usize> {
    let b = text.as_bytes();
    if let Some(p) = text[..i].chars().next_back()
        && (p.is_alphanumeric() || is_combining(p) || matches!(p, '#' | '&'))
    {
        return None;
    }
    if escaped(b, i) {
        return None;
    }
    let mut chars = text[i + 1..to].char_indices();
    let (_, first) = chars.next()?;
    if !first.is_alphabetic() {
        return None;
    }
    // `keep` is the end after the last letter, digit or `_`: a trailing `-` or `/` is left out.
    let mut keep = i + 1 + first.len_utf8();
    for (k, c) in chars {
        if c.is_alphanumeric() || c == '_' || is_combining(c) {
            keep = i + 1 + k + c.len_utf8();
        } else if !matches!(c, '-' | '/') {
            break;
        }
    }
    Some(keep)
}

/// Combining marks, which belong to the letter before them: `#cafe\u{301}` is one tag, `e\u{301}#b`
/// none (a decomposed `\u{e9}`, as file names on macOS and some pasted text have it).
pub(crate) fn is_combining(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}
