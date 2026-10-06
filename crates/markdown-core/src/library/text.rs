//! Text helpers of the library index: tokenizing for search, front matter tags, headings and
//! the context around a link.

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

// Combining marks stay with the letter before them (`e` + U+0301), in words as in tags.
use crate::wiki::is_combining;

/// Longest term kept in the index, in bytes; longer runs (base64, hashes) are noise.
const MAX_TERM_BYTES: usize = 64;

/// Han, kana and Hangul-free scripts that are written without spaces: every such character is
/// a term of its own, so a prefix search finds them anywhere in a run.
fn is_ideographic(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FFFF)
}

fn is_word_char(c: char) -> bool {
    (c.is_alphanumeric() && !is_ideographic(c)) || is_combining(c)
}

/// What the library compares names, paths, tags and words by: Unicode-normalised (NFC), then case-folded. File
/// systems, git checkouts and zips disagree about the form of an accented name (`\u{e9}` or `e\u{301}`), and a link
/// typed in one must find the note named in the other. Only comparison keys go through this, never text shown or paths
/// returned.
pub(crate) fn key(s: &str) -> String {
    if s.is_ascii() {
        s.to_ascii_lowercase()
    } else {
        s.nfc().collect::<String>().to_lowercase()
    }
}

/// Calls `f(start, end, lower)` for every word of `text`: runs of letters and digits, and each
/// ideographic character, case-folded (`lower`). Byte offsets.
pub(crate) fn for_each_word(text: &str, mut f: impl FnMut(usize, usize, &str)) {
    let mut buf = String::new();
    let mut start = 0;
    let mut in_word = false;
    let mut flush = |end: usize, buf: &mut String, start: usize| {
        // Offsets stay those of the text; only the term is normalised, so `e\u{301}` and `\u{e9}` are one word.
        if buf.is_ascii() {
            f(start, end, buf);
        } else {
            f(start, end, &buf.nfc().collect::<String>());
        }
        buf.clear();
    };
    for (i, c) in text.char_indices() {
        if is_word_char(c) {
            if !in_word {
                in_word = true;
                start = i;
            }
            if c.is_ascii() {
                buf.push(c.to_ascii_lowercase());
            } else {
                buf.extend(c.to_lowercase());
            }
            continue;
        }
        if in_word {
            in_word = false;
            flush(i, &mut buf, start);
        }
        if is_ideographic(c) {
            buf.extend(c.to_lowercase());
            flush(i + c.len_utf8(), &mut buf, i);
        }
    }
    if in_word {
        flush(text.len(), &mut buf, start);
    }
}

/// The distinct terms of `text` with their counts, and the number of words.
pub(crate) fn term_counts(text: &str) -> (Vec<(String, u32)>, u32) {
    let mut map: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    let mut words = 0u32;
    for_each_word(text, |_, _, w| {
        words = words.saturating_add(1);
        if w.len() <= MAX_TERM_BYTES {
            match map.get_mut(w) {
                Some(n) => *n += 1,
                None => {
                    map.insert(w.to_owned(), 1);
                }
            }
        }
    });
    (map.into_iter().collect(), words)
}

/// The case-folded words of a query or a title.
pub(crate) fn words_of(text: &str) -> Vec<String> {
    let mut v = Vec::new();
    for_each_word(text, |_, _, w| v.push(w.to_owned()));
    v
}

/// A tag as the index keeps it: no leading `#`, case-folded.
pub(crate) fn normalize_tag(tag: &str) -> String {
    key(tag.trim().trim_start_matches('#').trim())
}

/// The tags of a YAML front matter block (delimiters included): `tags:` or `tag:` as a flow list
/// (`[a, b]`), a comma string (`a, b`) or a block list (`- a` lines).
pub(crate) fn front_matter_tags(block: &str) -> Vec<String> {
    let lines: Vec<&str> = block.lines().collect();
    let mut out: Vec<String> = Vec::new();
    let push = |item: &str, out: &mut Vec<String>| {
        let item = item.trim().trim_matches(['"', '\'']);
        let t = normalize_tag(item);
        // YAML's nulls are no tag.
        if !t.is_empty() && t != "~" && t != "null" {
            out.push(t);
        }
    };
    let mut i = 1; // the opening delimiter
    while i < lines.len() {
        let line = lines[i];
        let lower = line.to_ascii_lowercase();
        let rest = lower.strip_prefix("tags:").or_else(|| lower.strip_prefix("tag:")).map(|r| &line[line.len() - r.len()..]);
        i += 1;
        let Some(rest) = rest else { continue };
        let rest = rest.split(" #").next().unwrap_or("").trim();
        if rest.is_empty() {
            // A block list: `- a` lines, indented or not.
            while i < lines.len() {
                let t = lines[i].trim();
                if let Some(item) = t.strip_prefix('-').filter(|r| r.is_empty() || r.starts_with(' ')) {
                    push(item, &mut out);
                } else if !t.is_empty() {
                    break;
                }
                i += 1;
            }
        } else if rest.starts_with(['>', '|']) {
            // A block scalar is one string, not a list: no tags rather than a tag called `>`.
            continue;
        } else if let Some(flow) = rest.strip_prefix('[') {
            // A flow list, possibly continued on the next lines.
            let mut text = flow.to_owned();
            while !text.contains(']') && i < lines.len() && !lines[i].trim().starts_with("---") {
                text.push(' ');
                text.push_str(lines[i].trim());
                i += 1;
            }
            for item in text.split(']').next().unwrap_or("").split(',') {
                push(item, &mut out);
            }
        } else {
            for item in rest.split(',') {
                push(item, &mut out);
            }
        }
    }
    out
}

/// The sentence (or line, if it is shorter) around `start..end`, trimmed, and at most about
/// `max` characters: the context a backlink shows.
pub(crate) fn context(text: &str, start: usize, end: usize, max: usize) -> String {
    let b = text.as_bytes();
    let mut ls = start;
    while ls > 0 && !matches!(b[ls - 1], b'\n' | b'\r') {
        ls -= 1;
    }
    let mut le = end;
    while le < b.len() && !matches!(b[le], b'\n' | b'\r') {
        le += 1;
    }
    let line = &text[ls..le];
    let (rs, re) = (start - ls, end - ls);
    let mut from = 0;
    let mut to = line.len();
    for (s, sentence) in line.split_sentence_bound_indices() {
        let e = s + sentence.len();
        if s <= rs && rs < e {
            from = s;
            to = e.max(re);
            break;
        }
    }
    let mut sentence = &line[from..to];
    // Too long: a window around the link.
    if sentence.chars().count() > max {
        let before: usize = sentence[..rs - from].chars().rev().take(max / 3).map(char::len_utf8).sum();
        let ws = rs - from - before;
        let link = sentence[rs - from..re - from].chars().count();
        let after: usize = sentence[re - from..].chars().take((max - max / 3).saturating_sub(link)).map(char::len_utf8).sum();
        let we = re - from + after;
        sentence = &sentence[ws..we];
    }
    sentence.trim().to_owned()
}
