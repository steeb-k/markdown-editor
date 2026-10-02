//! GFM "extended autolinks" for bare `http://`, `https://` and `www.` URLs.
//!
//! pulldown-cmark 0.13 only knows `<...>` autolinks, so the core finds bare URLs itself.
//! The rules follow the GFM spec (section 6.9):
//!
//! * the URL starts with `http://`, `https://` or `www.` (case-insensitive) and is
//!   preceded by the start of a line, whitespace, or one of `*`, `_`, `~`, `(`;
//! * a valid domain follows: segments of alphanumerics, `_` and `-` separated by `.`, at
//!   least one period (the one in `www.` counts; after `http://` none is needed, as in
//!   cmark-gfm), and no `_` in the last two segments;
//! * the URL continues to the next whitespace or `<`;
//! * trailing `?`, `!`, `.`, `,`, `:`, `*`, `_`, `~` (and, as in cmark-gfm, `'` and `"`)
//!   are not part of it, nor is a trailing
//!   `)` that has no opening `(` in the URL, nor a trailing `&entity;`.
//!
//! The analysis applies this to runs of plain text (outside code, links, raw HTML and front
//! matter) and the HTML renderer can use [`find`] for the same decisions. Email autolinks
//! (`foo@bar.baz`) are not implemented.

/// A bare URL found in text. Offsets are UTF-8 byte offsets into the searched string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Autolink {
    pub start: usize,
    pub end: usize,
    /// The `href` to emit: the matched text, with `http://` prepended for `www.` URLs.
    pub destination: String,
}

/// All bare URLs in `text`, in order. The start of `text` counts as the start of a line.
pub fn find(text: &str) -> Vec<Autolink> {
    find_in(text, 0, text.len())
}

/// Bare URLs inside `text[from..to]` (byte offsets on char boundaries). The character
/// before `from` (if any) decides whether a URL may start at `from`.
pub fn find_in(text: &str, from: usize, to: usize) -> Vec<Autolink> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = from;
    while i < to {
        // Cheap filter: only `h`/`w` can start a URL.
        if !matches!(b[i], b'h' | b'H' | b'w' | b'W') || !valid_predecessor(text, i) {
            i += 1;
            continue;
        }
        match match_at(text, i, to) {
            Some(end) => {
                let mut dest = String::new();
                if b[i] | 0x20 == b'w' {
                    dest.push_str("http://");
                }
                dest.push_str(&text[i..end]);
                out.push(Autolink { start: i, end, destination: dest });
                i = end;
            }
            None => i += 1,
        }
    }
    out
}

fn valid_predecessor(text: &str, i: usize) -> bool {
    match text[..i].chars().next_back() {
        None => true,
        Some(c) => c.is_whitespace() || matches!(c, '*' | '_' | '~' | '('),
    }
}

fn starts_with_ci(b: &[u8], i: usize, pat: &[u8]) -> bool {
    b.len() >= i + pat.len() && b[i..i + pat.len()].eq_ignore_ascii_case(pat)
}

/// End of the URL starting at `i`, if one does.
fn match_at(text: &str, i: usize, to: usize) -> Option<usize> {
    let b = &text.as_bytes()[..to];
    let domain_start = if starts_with_ci(b, i, b"https://") {
        i + 8
    } else if starts_with_ci(b, i, b"http://") {
        i + 7
    } else if starts_with_ci(b, i, b"www.") {
        i
    } else {
        return None;
    };
    // As in cmark-gfm (and so on GitHub), a scheme makes a dotless host fine:
    // `http://localhost:8080/x`.
    let domain_end = check_domain(text, domain_start, to, domain_start > i)?;
    // The URL runs to the next whitespace or `<`.
    let mut end = domain_end;
    for (k, c) in text[domain_end..to].char_indices() {
        if c.is_whitespace() || c == '<' {
            break;
        }
        end = domain_end + k + c.len_utf8();
    }
    // Trailing punctuation never reaches into the domain.
    while end > domain_end {
        let c = b[end - 1];
        match c {
            // The spec's list, plus quotes as in cmark-gfm (`"see https://a.b"`).
            b'?' | b'!' | b'.' | b',' | b':' | b'*' | b'_' | b'~' | b'\'' | b'"' => end -= 1,
            b')' => {
                let url = &b[i..end];
                let open = url.iter().filter(|&&c| c == b'(').count();
                let close = url.iter().filter(|&&c| c == b')').count();
                if close > open {
                    end -= 1;
                } else {
                    break;
                }
            }
            b';' => {
                // `&name;` looks like an entity reference: leave it out.
                let mut k = end - 1;
                while k > domain_end && b[k - 1].is_ascii_alphanumeric() {
                    k -= 1;
                }
                if k < end - 1 && k > domain_end && b[k - 1] == b'&' {
                    end = k - 1;
                } else {
                    break;
                }
            }
            _ => break,
        }
    }
    Some(end.max(domain_end))
}

/// Validate the domain starting at `s`; returns its end (without trailing periods).
fn check_domain(text: &str, s: usize, to: usize, allow_short: bool) -> Option<usize> {
    let mut e = s;
    for (k, c) in text[s..to].char_indices() {
        if c.is_alphanumeric() || matches!(c, '-' | '_' | '.') {
            e = s + k + c.len_utf8();
        } else {
            break;
        }
    }
    // Trailing periods and underscores are punctuation, trimmed below; they must not decide
    // whether the domain is valid.
    while e > s && matches!(text.as_bytes()[e - 1], b'.' | b'_') {
        e -= 1;
    }
    let domain = &text[s..e];
    let segments: Vec<&str> = domain.split('.').collect();
    if (segments.len() < 2 && !allow_short) || segments.iter().any(|s| s.is_empty()) {
        return None;
    }
    if segments.iter().rev().take(2).any(|s| s.contains('_')) {
        return None;
    }
    if !domain.chars().any(|c| c.is_alphanumeric()) {
        return None;
    }
    Some(e)
}
