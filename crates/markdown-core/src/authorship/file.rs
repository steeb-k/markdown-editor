//! The annotation block on disk.
//!
//! # What the format says, and what this module does
//!
//! A file is a text, then an annotation block, then the end of the file. The block is a `---`
//! line, annotations, and a `...` line. The first annotation is the hash annotation
//! (`Annotations: 0,95 SHA-256 1132bf5e...`): a grapheme-cluster range of the text, the
//! algorithm, and the first 20 to 64 hex digits of the SHA-256 of the UTF-8 bytes of that
//! range. Author annotations (`@` human, `&` AI, `*` reference) list `start,length` ranges in
//! grapheme clusters. The range may leave out the text's last newline, so a tool can put an
//! empty line between the text and `---`.
//!
//! **The body** (what the editor shows and what a [`Document`](crate::Document) holds) is
//! everything before the `---` line, minus one line terminator when the text before `---`
//! ends in a blank line. That is the separator iA puts there: the spec's own README is
//! `text + "\n" + "\n---"` with a range that stops before the text's last newline.
//!
//! **Writing**: for a body that ends in a newline the file is `body + "\n---\n...`; the hashed
//! range is the body without that newline (like the spec's example), unless an author range includes it,
//! then the whole body. For a body that does not end in a newline the file is
//! `body + "\n\n---\n..."` and the range is the whole body; it reads back with one newline
//! more (the spec's own example has this shape). Every annotation line ends in two spaces,
//! like the spec's example. The hash is written as 32 hex digits. In a CRLF file the block and its
//! hashed bytes use CRLF.
//!
//! **Reading** recognises a block only at the very end of the file (trailing blank lines are
//! allowed): the last non-blank line is `...`, the nearest unindented `---` line above it is
//! followed immediately by a hash annotation whose value is `range algorithm hex`, and either
//! that is SHA-256 with 20 to 64 hex digits or author annotations follow it. Anything
//! else is just text. A look-alike inside a closed code fence is not at the end of the file,
//! so it is text. One in a fence left open at the end of the file is text too unless its hash
//! is right (fences are the only Markdown looked at here); likewise one at the very start.

use sha2::{Digest, Sha256};
use unicode_segmentation::UnicodeSegmentation;

use super::{Author, AuthorEntry, AuthorKind, Authorship, Origin, Run};
use crate::types::OffsetEncoding;

/// Line terminator of the file the text is written to. The editor holds `\n` only; the hash
/// is over the bytes of the file, so it depends on this.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LineEnding {
    Lf,
    CrLf,
    Cr,
    /// Mixed endings, kept as they are: the text is hashed as it is.
    Preserve,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnnotationStatus {
    /// No annotation block.
    Absent,
    /// A block whose hash matches.
    Valid,
    /// A block whose hash does not match the text: the text was changed outside.
    HashMismatch,
    /// A block that is not usable as written (unknown algorithm, bad hash, an author range
    /// beyond the text).
    Malformed(String),
}

/// Start and length, in grapheme clusters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GraphemeRange {
    pub start: u32,
    pub length: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedAuthor {
    pub kind: AuthorKind,
    /// The key after its prefix character: name, identifier and all, colons unescaped.
    pub name: String,
    pub ranges: Vec<GraphemeRange>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedAnnotations {
    /// The hash annotation's key as written ("Annotations", or a translation of it).
    pub hash_key: String,
    pub hash_range: GraphemeRange,
    pub algorithm: String,
    pub hash: String,
    pub authors: Vec<ParsedAuthor>,
    /// Annotation lines that are not authorship (other keys, author lines with content,
    /// continuation lines): kept verbatim and written back.
    pub unknown: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SplitFile {
    pub body: String,
    pub annotations: Option<ParsedAnnotations>,
    pub status: AnnotationStatus,
    /// The file's bytes after the body, exactly (the separator and the block), when there
    /// was one. `body + raw_tail` is the original file.
    pub raw_tail: Option<String>,
}

// ----- lines -----------------------------------------------------------------------------

struct Line {
    start: usize,
    end: usize,
}

fn lines(text: &str) -> Vec<Line> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\n' => {
                out.push(Line { start, end: i });
                start = i + 1;
            }
            b'\r' => {
                out.push(Line { start, end: i });
                if b.get(i + 1) == Some(&b'\n') {
                    i += 1;
                }
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    if start < b.len() {
        out.push(Line { start, end: b.len() });
    }
    out
}

fn is_blank(s: &str) -> bool {
    s.chars().all(|c| c == ' ' || c == '\t')
}

fn trim_end_ws(s: &str) -> &str {
    s.trim_end_matches([' ', '\t'])
}

fn strip_one_eol(s: &str) -> &str {
    if let Some(r) = s.strip_suffix("\r\n") {
        r
    } else if let Some(r) = s.strip_suffix('\n') {
        r
    } else if let Some(r) = s.strip_suffix('\r') {
        r
    } else {
        s
    }
}

fn ends_with_eol(s: &str) -> bool {
    s.ends_with('\n') || s.ends_with('\r')
}

// ----- annotation grammar ----------------------------------------------------------------

/// Key and value of an annotation line, or `None` without an unescaped colon.
fn key_value(line: &str) -> Option<(String, &str)> {
    let mut key = String::new();
    let mut chars = line.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        // `\:` is a colon in the name (the spec's rule). `\\` is a backslash, so that a name that ends
        // in one can be written (`x\\` then the separator) and read back; a backslash before anything
        // else stands for itself, as the spec reads it.
        if c == '\\' && matches!(chars.peek(), Some((_, ':' | '\\'))) {
            key.push(chars.next().map_or(c, |(_, n)| n));
        } else if c == ':' {
            return Some((key.trim().to_string(), line[i + 1..].trim_start_matches(' ')));
        } else {
            key.push(c);
        }
    }
    None
}

fn parse_number(s: &str) -> Option<u32> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn parse_range(tok: &str) -> Option<GraphemeRange> {
    match tok.split_once(',') {
        Some((a, l)) => Some(GraphemeRange { start: parse_number(a)?, length: parse_number(l)? }),
        None => Some(GraphemeRange { start: parse_number(tok)?, length: 1 }),
    }
}

fn author_prefix(key: &str) -> Option<(AuthorKind, &str)> {
    let mut c = key.chars();
    let kind = match c.next()? {
        '@' => AuthorKind::Human,
        '&' => AuthorKind::Ai,
        '*' => AuthorKind::Reference,
        _ => return None,
    };
    Some((kind, c.as_str().trim_start_matches([' ', '\t'])))
}

struct Annotation<'a> {
    lines: Vec<&'a str>,
}

/// `line` without up to `n` bytes of leading spaces and tabs.
fn dedent(line: &str, n: usize) -> &str {
    let k = indent_of(line).min(n);
    &line[k..]
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start_matches([' ', '\t']).len()
}

/// Splits the lines between `---` and `...` into annotations. The first line's indentation
/// is the keys' indentation; a line indented two or more beyond it (or a blank one) continues
/// the annotation before it.
fn group_annotations<'a>(raw: &[&'a str]) -> Option<Vec<Annotation<'a>>> {
    let base = indent_of(raw.first()?);
    if raw[0].trim().is_empty() {
        return None;
    }
    let mut out: Vec<Annotation<'a>> = Vec::new();
    for (i, &l) in raw.iter().enumerate() {
        let blank = l.trim().is_empty();
        if blank || indent_of(l) >= base + 2 {
            if i == 0 {
                return None;
            }
            out.last_mut()?.lines.push(l);
        } else {
            out.push(Annotation { lines: vec![l] });
        }
    }
    Some(out)
}

fn is_hex(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The hash annotation of a block: its key and value fields, if well formed enough to
/// recognise.
fn parse_hash_annotation(a: &Annotation<'_>) -> Option<(String, GraphemeRange, String, String)> {
    if a.lines.len() != 1 {
        return None;
    }
    let (key, value) = key_value(a.lines[0].trim_start_matches([' ', '\t']))?;
    if author_prefix(&key).is_some() {
        return None;
    }
    let toks: Vec<&str> = value.split_whitespace().collect();
    if toks.len() != 3 {
        return None;
    }
    let range = parse_range(toks[0])?;
    if !is_hex(toks[2]) {
        return None;
    }
    Some((key, range, toks[1].to_string(), toks[2].to_ascii_lowercase()))
}

fn parse_author(a: &Annotation<'_>) -> Option<ParsedAuthor> {
    let (key, value) = key_value(a.lines[0].trim_start_matches([' ', '\t']))?;
    let (kind, name) = author_prefix(&key)?;
    let mut ranges = Vec::new();
    // Ranges may continue on indented lines.
    let rest = a.lines[1..].iter().flat_map(|l| l.split_whitespace());
    for tok in value.split_whitespace().chain(rest) {
        ranges.push(parse_range(tok)?);
    }
    Some(ParsedAuthor { kind, name: name.to_string(), ranges })
}

// ----- hashing ---------------------------------------------------------------------------

fn hex16(data: &[u8]) -> String {
    let d = Sha256::digest(data);
    d.iter().take(16).map(|b| format!("{b:02x}")).collect()
}

/// Bytes `[a, b)` of `s` covering grapheme clusters `loc..loc + len`, and the total count.
fn grapheme_slice(s: &str, loc: u32, len: u32) -> (Option<(usize, usize)>, usize) {
    let (loc, end) = (loc as usize, loc as usize + len as usize);
    let (mut from, mut to) = (None, None);
    let mut count = 0usize;
    for (i, (b, _)) in s.grapheme_indices(true).enumerate() {
        if i == loc {
            from = Some(b);
        }
        if i == end {
            to = Some(b);
        }
        count = i + 1;
    }
    if loc == count {
        from = Some(s.len());
    }
    if end == count {
        to = Some(s.len());
    }
    (from.zip(to), count)
}

// ----- split -----------------------------------------------------------------------------

/// Separates the annotation block from the text of a file as read from disk (line endings
/// as they are on disk).
pub fn split_annotations(file: &str) -> SplitFile {
    match try_split(file) {
        Some(s) => s,
        None => SplitFile {
            body: file.to_string(),
            annotations: None,
            status: AnnotationStatus::Absent,
            raw_tail: None,
        },
    }
}

fn try_split(file: &str) -> Option<SplitFile> {
    // Cheap exit for the common case: the file does not end in `...`.
    let trimmed = file.trim_end_matches([' ', '\t', '\r', '\n']);
    if !trimmed.ends_with("...") {
        return None;
    }
    let all = lines(file);
    let dots = all.iter().rposition(|l| !is_blank(&file[l.start..l.end]))?;
    if trim_end_ws(&file[all[dots].start..all[dots].end]) != "..." {
        return None;
    }
    let open = (0..dots).rev().find(|&i| {
        let l = &file[all[i].start..all[i].end];
        trim_end_ws(l) == "---"
    })?;
    if open + 1 >= dots {
        return None;
    }
    let raw: Vec<&str> = (open + 1..dots).map(|i| &file[all[i].start..all[i].end]).collect();
    let anns = group_annotations(&raw)?;
    let base = indent_of(raw[0]);
    let (hash_key, hash_range, algorithm, hash) = parse_hash_annotation(&anns[0])?;

    let pre = &file[..all[open].start];
    let mut body_end = pre.len();
    let stripped = strip_one_eol(pre);
    if stripped.len() < pre.len() && ends_with_eol(stripped) {
        body_end = stripped.len();
    }
    let body = &file[..body_end];

    let mut authors = Vec::new();
    let mut unknown = Vec::new();
    for a in &anns[1..] {
        match parse_author(a) {
            Some(p) => authors.push(p),
            // Kept relative to the block's indentation: the block is written back unindented,
            // and a line still indented by the block's own indentation would then read as a
            // continuation of the annotation before it.
            None => unknown.extend(a.lines.iter().map(|l| dedent(l, base).to_string())),
        }
    }

    // A hash line that is not SHA-256 with 20 to 64 hex digits is only taken for a block's
    // when author annotations follow it: `date: 2024 10 01` in a YAML metadata block closed by
    // `...` at the end of a document (Pandoc allows them anywhere) has the same shape.
    let well_formed_hash = algorithm.eq_ignore_ascii_case("SHA-256") && (20..=64).contains(&hash.len());
    if !well_formed_hash && authors.is_empty() {
        return None;
    }

    // Validate.
    let mut status = AnnotationStatus::Valid;
    let (slice, _) = grapheme_slice(pre, hash_range.start, hash_range.length);
    if !algorithm.eq_ignore_ascii_case("SHA-256") {
        status = AnnotationStatus::Malformed(format!("unsupported hash algorithm {algorithm}"));
    } else if !(20..=64).contains(&hash.len()) {
        status = AnnotationStatus::Malformed("the hash has the wrong length".to_string());
    } else if let Some((a, b)) = slice {
        let full = Sha256::digest(&pre.as_bytes()[a..b]);
        let hex: String = full.iter().map(|b| format!("{b:02x}")).collect();
        if !hex.starts_with(&hash) {
            status = AnnotationStatus::HashMismatch;
        }
    } else {
        // The text is shorter than it was when the marks were written.
        status = AnnotationStatus::HashMismatch;
    }
    if status == AnnotationStatus::Valid {
        let body_graphemes = body.graphemes(true).count();
        let beyond = authors.iter().flat_map(|a| &a.ranges).any(|r| {
            r.start as usize + r.length as usize > body_graphemes
        });
        if beyond {
            status = AnnotationStatus::Malformed("an author range lies beyond the text".to_string());
        }
    }
    // A block at the very start of a file is only taken for one when its hash is right:
    // otherwise it is much more likely YAML front matter. Likewise a look-alike inside a code
    // fence that is still open (an example of the format being written): taking it for a block
    // would hide it from the editor, and Discard would delete it. A right hash settles it.
    if status != AnnotationStatus::Valid && (open == 0 || inside_open_fence(pre)) {
        return None;
    }

    Some(SplitFile {
        body: body.to_string(),
        annotations: Some(ParsedAnnotations { hash_key, hash_range, algorithm, hash, authors, unknown }),
        status,
        raw_tail: Some(file[body_end..].to_string()),
    })
}

/// Does `text` end inside a fenced code block (a ```` ``` ```` or `~~~` fence opened and not
/// closed)? CommonMark's fence rules, without container prefixes (a fence in a list item or a
/// quote is still seen when its marker is indented by at most three spaces).
fn inside_open_fence(text: &str) -> bool {
    let mut open: Option<(u8, usize)> = None;
    for l in lines(text) {
        let line = &text[l.start..l.end];
        let indent = line.len() - line.trim_start_matches(' ').len();
        if indent > 3 {
            continue;
        }
        let rest = &line[indent..];
        let Some(&c) = rest.as_bytes().first() else { continue };
        if c != b'`' && c != b'~' {
            continue;
        }
        let run = rest.bytes().take_while(|&b| b == c).count();
        if run < 3 {
            continue;
        }
        match open {
            None => {
                // A backtick fence's info string may not hold backticks.
                if c == b'~' || !rest[run..].contains('`') {
                    open = Some((c, run));
                }
            }
            Some((oc, olen)) => {
                if c == oc && run >= olen && rest[run..].trim().is_empty() {
                    open = None;
                }
            }
        }
    }
    open.is_some()
}

// ----- Authorship from and to annotations ---------------------------------------------------

fn unit_len(enc: OffsetEncoding, g: &str) -> u32 {
    match enc {
        OffsetEncoding::Utf8 => g.len() as u32,
        OffsetEncoding::Utf16 => g.encode_utf16().count() as u32,
        OffsetEncoding::Utf32 => g.chars().count() as u32,
    }
}

/// Start offset (in units) of every grapheme cluster of `text`.
fn grapheme_starts(text: &str, enc: OffsetEncoding) -> (Vec<u32>, u32) {
    let mut starts = Vec::new();
    let mut acc = 0u32;
    for g in text.graphemes(true) {
        starts.push(acc);
        acc += unit_len(enc, g);
    }
    (starts, acc)
}

fn to_file_ending(text: &str, ending: LineEnding) -> String {
    match ending {
        LineEnding::Lf | LineEnding::Preserve => text.to_string(),
        LineEnding::CrLf => text.replace('\n', "\r\n"),
        LineEnding::Cr => text.replace('\n', "\r"),
    }
}

fn eol(ending: LineEnding) -> &'static str {
    match ending {
        LineEnding::Lf | LineEnding::Preserve => "\n",
        LineEnding::CrLf => "\r\n",
        LineEnding::Cr => "\r",
    }
}

/// An author's name as an annotation key: colons escaped, and anything that would end the line
/// (a name pasted into a settings field can hold a line break) turned into a space. A backslash is
/// doubled where it would otherwise be read as part of an escape: before a colon or another backslash,
/// or at the end of the name (the separator follows it). Names without those are written as they are,
/// as the spec has it, and names the spec's rule wrote (`a\:b` for `a:b`) read back the same.
fn escape_key(name: &str) -> String {
    let chars: Vec<char> = name.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let mut out = String::with_capacity(name.len() + 2);
    for (i, &c) in chars.iter().enumerate() {
        match c {
            ':' => out.push_str("\\:"),
            '\\' if matches!(chars.get(i + 1), None | Some(':' | '\\')) => out.push_str("\\\\"),
            _ => out.push(c),
        }
    }
    out
}

impl Authorship {
    /// The attribution a file's annotations describe, for the body they were split from.
    /// Author ranges are converted from grapheme clusters to this encoding's units; ranges
    /// beyond the text are clamped; where ranges overlap the later one wins. `me` is the
    /// name of the Human author whose text is Me's.
    pub fn from_annotations(
        body: &str,
        parsed: &ParsedAnnotations,
        encoding: OffsetEncoding,
        me: &str,
    ) -> Self {
        let mut a = Authorship::with_me(encoding, me);
        a.hash_key = parsed.hash_key.clone();
        a.unknown = parsed.unknown.clone();
        a.order.clear();
        let (starts, total) = grapheme_starts(body, encoding);
        let g = starts.len();
        let unit_at = |i: usize| if i >= g { total } else { starts[i] };

        let mut spans: Vec<(u32, u32, u32)> = Vec::new();
        for p in &parsed.authors {
            let author = Author::new(p.kind, p.name.clone());
            let idx = if p.kind == AuthorKind::Human && p.name == me {
                0
            } else if let Some(i) = a.authors.iter().position(|e| e.author == author) {
                i as u32
            } else {
                a.authors.push(AuthorEntry { author, from_file: true });
                a.authors.len() as u32 - 1
            };
            a.authors[idx as usize].from_file = true;
            if !a.order.contains(&idx) {
                a.order.push(idx);
            }
            for r in &p.ranges {
                let s = unit_at(r.start as usize);
                let e = unit_at((r.start as usize).saturating_add(r.length as usize));
                if e > s {
                    spans.push((s, e, idx));
                }
            }
        }
        if !a.order.contains(&0) {
            a.order.insert(0, 0);
        }
        // Later ranges win: with no overlaps (the normal case) this is just a sort.
        let mut sorted = spans.clone();
        sorted.sort_by_key(|s| s.0);
        let disjoint = sorted.windows(2).all(|w| w[0].1 <= w[1].0);
        if disjoint {
            a.runs = sorted.into_iter().map(|(s, e, x)| Run { start: s, end: e, author: x }).collect();
            a.merge();
        } else {
            for (s, e, x) in spans {
                a.paint(s, e, Some(x));
            }
        }
        a
    }

    /// The annotation block for `text` as it will be written, or `None` when no text is
    /// attributed to anyone but Me. `text` is the editor's text (`\n` line endings);
    /// `ending` is how the file will write them, which is what the hash covers. The result
    /// is what follows the body in the file: the separating newline(s), `---`, the
    /// annotations and `...`.
    pub fn annotation_block(&self, text: &str, ending: LineEnding) -> Option<String> {
        if !self.has_marks() {
            return None;
        }
        let (starts, total) = grapheme_starts(text, self.encoding);
        let g = starts.len();
        // Grapheme ranges per author.
        let mut per: Vec<Vec<(usize, usize)>> = vec![Vec::new(); self.authors.len()];
        for r in &self.runs {
            let (s, e) = (r.start.min(total), r.end.min(total));
            let gi = starts.partition_point(|&u| u < s);
            let gj = starts.partition_point(|&u| u < e);
            if gj <= gi {
                continue;
            }
            let list = &mut per[r.author as usize];
            match list.last_mut() {
                Some(l) if l.1 == gi => l.1 = gj,
                _ => list.push((gi, gj)),
            }
        }
        let max_end = per.iter().flat_map(|l| l.iter().map(|r| r.1)).max().unwrap_or(0);

        let final_eol = if text.ends_with("\r\n") {
            2
        } else if text.ends_with('\n') || text.ends_with('\r') {
            1
        } else {
            0
        };
        let (hashed_text, hashed_g) = if final_eol > 0 && max_end < g {
            (&text[..text.len() - final_eol], g - 1)
        } else {
            (text, g)
        };
        let hash = hex16(to_file_ending(hashed_text, ending).as_bytes());

        let nl = eol(ending);
        let mut out = String::new();
        out.push_str(nl);
        if final_eol == 0 {
            out.push_str(nl);
        }
        out.push_str("---");
        out.push_str(nl);
        out.push_str(&format!("{}: 0,{} SHA-256 {}  ", self.hash_key, hashed_g, hash));
        out.push_str(nl);
        for &i in &self.order {
            let entry = &self.authors[i as usize];
            let ranges = &per[i as usize];
            if ranges.is_empty() && !entry.from_file {
                continue;
            }
            let prefix = match entry.author.kind {
                AuthorKind::Human => '@',
                AuthorKind::Ai => '&',
                AuthorKind::Reference => '*',
            };
            out.push(prefix);
            out.push_str(&escape_key(&entry.author.name));
            out.push(':');
            for &(s, e) in ranges {
                if e - s == 1 {
                    out.push_str(&format!(" {s}"));
                } else {
                    out.push_str(&format!(" {s},{}", e - s));
                }
            }
            out.push_str("  ");
            out.push_str(nl);
        }
        for l in &self.unknown {
            out.push_str(l);
            out.push_str(nl);
        }
        out.push_str("...");
        out.push_str(nl);
        Some(out)
    }

    /// Remembers the file this attribution was loaded from (`body` as the editor holds it,
    /// `raw_tail` as it was on disk), so that [`Authorship::file_tail`] can give the file
    /// back byte for byte while neither has changed. Call it right after loading.
    pub fn set_origin(&mut self, body: &str, raw_tail: &str, ending: LineEnding) {
        let canonical = self.annotation_block(body, ending);
        self.origin = Some(Origin { body: body.to_string(), tail: raw_tail.to_string(), canonical });
    }

    /// Forgets the original block (the user discarded it).
    pub fn clear_origin(&mut self) {
        self.origin = None;
    }

    /// What to write after `text`: the original tail if neither the text nor the written
    /// attribution has changed since [`Authorship::set_origin`], otherwise the canonical
    /// block (nothing when there are no marks).
    pub fn file_tail(&self, text: &str, ending: LineEnding) -> String {
        let canonical = self.annotation_block(text, ending);
        if let Some(o) = &self.origin
            && o.canonical == canonical
            && o.body == text
        {
            return o.tail.clone();
        }
        canonical.unwrap_or_default()
    }
}
