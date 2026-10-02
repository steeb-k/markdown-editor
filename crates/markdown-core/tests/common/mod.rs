#![allow(dead_code)]
use markdown_core::*;

/// Valid unit offsets (code point boundaries) for `text`, computed independently of the core.
pub fn boundaries(text: &str, enc: OffsetEncoding) -> Vec<u32> {
    let mut v = vec![0u32];
    let mut u = 0u32;
    for ch in text.chars() {
        u += match enc {
            OffsetEncoding::Utf8 => ch.len_utf8() as u32,
            OffsetEncoding::Utf16 => ch.len_utf16() as u32,
            OffsetEncoding::Utf32 => 1,
        };
        v.push(u);
    }
    v
}

/// Slice a string by unit offsets (independent implementation).
pub fn slice_units(text: &str, enc: OffsetEncoding, r: TextRange) -> String {
    let mut out = String::new();
    let mut u = 0u32;
    for ch in text.chars() {
        let w = match enc {
            OffsetEncoding::Utf8 => ch.len_utf8() as u32,
            OffsetEncoding::Utf16 => ch.len_utf16() as u32,
            OffsetEncoding::Utf32 => 1,
        };
        if u >= r.start && u + w <= r.end {
            out.push(ch);
        }
        u += w;
    }
    out
}

/// The span-list contract; returns an error message instead of panicking.
pub fn check_spans(doc: &Document, spans: &[Span]) -> Result<(), String> {
    let len = doc.len();
    let ok = boundaries(doc.text(), doc.encoding());
    let mut stack: Vec<TextRange> = Vec::new();
    let mut prev: Option<&Span> = None;
    for s in spans {
        let r = s.range;
        if r.start >= r.end {
            return Err(format!("empty/inverted span {s:?}"));
        }
        if r.end > len {
            return Err(format!("span out of bounds {s:?} len {len}"));
        }
        if ok.binary_search(&r.start).is_err() || ok.binary_search(&r.end).is_err() {
            return Err(format!("span off code point boundary {s:?}"));
        }
        if let Some(p) = prev.filter(|p| {
            (r.start, std::cmp::Reverse(r.end)) < (p.range.start, std::cmp::Reverse(p.range.end))
        }) {
            return Err(format!("unsorted: {p:?} before {s:?}"));
        }
        while let Some(top) = stack.last() {
            if top.end <= r.start {
                stack.pop();
            } else {
                break;
            }
        }
        if let Some(top) = stack.last().filter(|t| r.end > t.end) {
            return Err(format!("partial overlap of {s:?} with {top:?}"));
        }
        stack.push(r);
        prev = Some(s);
    }
    Ok(())
}

pub fn check_everything(doc: &Document) -> Result<(), String> {
    let spans = doc.spans(None);
    check_spans(doc, &spans)?;
    let len = doc.len();
    let ok = boundaries(doc.text(), doc.encoding());
    for b in doc.blocks() {
        if b.range.start >= b.range.end || b.range.end > len {
            return Err(format!("bad block {b:?}"));
        }
        if ok.binary_search(&b.range.start).is_err() || ok.binary_search(&b.range.end).is_err() {
            return Err(format!("block off boundary {b:?}"));
        }
    }
    let markup: Vec<_> = spans.iter().filter(|s| s.kind == SpanKind::Markup).collect();
    let mut last_end = 0;
    for p in doc.prose_ranges(None) {
        if p.start >= p.end || p.end > len || p.start < last_end {
            return Err(format!("bad prose range {p:?}"));
        }
        last_end = p.end;
        if ok.binary_search(&p.start).is_err() || ok.binary_search(&p.end).is_err() {
            return Err(format!("prose off boundary {p:?}"));
        }
        for m in &markup {
            if m.range.start < p.end && p.start < m.range.end {
                return Err(format!("prose {p:?} overlaps markup {m:?}"));
            }
        }
    }
    for im in doc.images() {
        if im.range.end > len || im.range.start >= im.range.end {
            return Err(format!("bad image {im:?}"));
        }
    }
    for m in doc.markup_spans(None) {
        if m.owner.end > len || m.owner.start >= m.owner.end {
            return Err(format!("bad markup owner {m:?}"));
        }
        if !(m.owner.start <= m.range.start && m.range.end <= m.owner.end) {
            return Err(format!("markup outside its owner {m:?}"));
        }
    }
    Ok(())
}

/// One line per span: `start..end Kind "text"`, in span order.
pub fn fmt_spans(doc: &Document) -> Vec<String> {
    doc.spans(None)
        .iter()
        .map(|s| {
            format!(
                "{}..{} {:?} {:?}",
                s.range.start,
                s.range.end,
                s.kind,
                slice_units(doc.text(), doc.encoding(), s.range)
            )
        })
        .collect()
}

/// Compact (kind, text) pairs for hand-written expectations.
pub fn spans_of(text: &str) -> Vec<(String, String)> {
    let doc = Document::new(text, OffsetEncoding::Utf8);
    check_everything(&doc).unwrap();
    doc.spans(None)
        .iter()
        .map(|s| (kind_name(s.kind), text[s.range.start as usize..s.range.end as usize].to_owned()))
        .collect()
}

pub fn kind_name(k: SpanKind) -> String {
    match k {
        SpanKind::Heading { level } => format!("Heading{level}"),
        SpanKind::ListMarker { ordered } => if ordered { "OrderedMarker" } else { "BulletMarker" }.into(),
        SpanKind::TaskMarker { checked } => if checked { "TaskChecked" } else { "TaskOpen" }.into(),
        other => format!("{other:?}"),
    }
}

/// Texts of all spans of one kind name.
pub fn texts(text: &str, kind: &str) -> Vec<String> {
    spans_of(text).into_iter().filter(|(k, _)| k == kind).map(|(_, t)| t).collect()
}

pub fn markup_texts(text: &str) -> Vec<String> {
    texts(text, "Markup")
}

pub fn fixtures() -> Vec<(String, String)> {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let mut v = Vec::new();
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.extension().is_some_and(|x| x == "md") {
            v.push((p.file_stem().unwrap().to_string_lossy().into_owned(), std::fs::read_to_string(&p).unwrap()));
        }
    }
    v.sort();
    v
}

/// Apply an edit and verify the dirty-range contract:
/// * the dirty range lies within the new text, on line boundaries, and covers the inserted text;
/// * the incrementally maintained analysis equals a fresh analysis of the new text;
/// * spans of the new text entirely outside `dirty` equal the old spans (shifted by the length
///   delta) entirely outside the corresponding old range.
pub fn check_edit(old: &str, enc: OffsetEncoding, range: TextRange, with: &str) -> Result<Update, String> {
    let mut doc = Document::new(old, enc);
    let old_spans = doc.spans(None);
    let old_len = doc.len() as i64;
    let b = boundaries(old, enc);
    let (bs, be) = (
        b.iter().position(|&x| x == range.start).ok_or("start not on boundary")?,
        b.iter().position(|&x| x == range.end).ok_or("end not on boundary")?,
    );
    let chars: Vec<char> = old.chars().collect();
    let mut expected: String = chars[..bs].iter().collect();
    expected.push_str(with);
    expected.extend(chars[be..].iter());

    let upd = doc.replace(range, with).map_err(|e| format!("replace failed: {e}"))?;
    if doc.text() != expected {
        return Err("text differs from string edit".into());
    }
    let fresh = Document::new(&expected, enc);
    let new_spans = fresh.spans(None);
    if doc.spans(None) != new_spans {
        return Err(format!("incremental spans differ from fresh analysis\n{:?}\n{:?}", doc.spans(None), new_spans));
    }
    if doc.blocks() != fresh.blocks() || doc.prose_ranges(None) != fresh.prose_ranges(None) || doc.images() != fresh.images() {
        return Err("blocks/prose/images differ from fresh analysis".into());
    }
    let new_len = doc.len() as i64;
    let delta = new_len - old_len;
    let ins_units = with.chars().map(|c| match enc {
        OffsetEncoding::Utf8 => c.len_utf8(),
        OffsetEncoding::Utf16 => c.len_utf16(),
        OffsetEncoding::Utf32 => 1,
    }).sum::<usize>() as u32;

    let d = upd.dirty;
    if d.start > range.start || d.end < range.start + ins_units || d.end as i64 > new_len {
        return Err(format!("dirty {d:?} does not cover edit {range:?}+{ins_units} (len {new_len})"));
    }
    let nb = boundaries(&expected, enc);
    let at_line_start = |u: u32| -> bool {
        let i = nb.iter().position(|&x| x == u).unwrap();
        // line start: 0, or previous char is \n, or previous is \r not followed by \n
        let nchars: Vec<char> = expected.chars().collect();
        i == 0 || nchars[i - 1] == '\n' || (nchars[i - 1] == '\r' && nchars.get(i) != Some(&'\n'))
    };
    if !at_line_start(d.start) || !(d.end as i64 == new_len || at_line_start(d.end)) {
        return Err(format!("dirty {d:?} is not whole lines in {expected:?}"));
    }

    let old_hi = (d.end as i64 - delta) as u32;
    let outside_old: Vec<Span> = old_spans
        .iter()
        .filter(|s| s.range.end <= d.start || s.range.start >= old_hi)
        .map(|s| {
            if s.range.start >= old_hi {
                Span { range: TextRange::new((s.range.start as i64 + delta) as u32, (s.range.end as i64 + delta) as u32), kind: s.kind }
            } else {
                *s
            }
        })
        .collect();
    let outside_new: Vec<Span> =
        new_spans.iter().filter(|s| s.range.end <= d.start || s.range.start >= d.end).copied().collect();
    if outside_old != outside_new {
        let a: Vec<_> = outside_old.iter().filter(|s| !outside_new.contains(s)).collect();
        let b: Vec<_> = outside_new.iter().filter(|s| !outside_old.contains(s)).collect();
        return Err(format!("spans outside dirty {d:?} differ\n old-only: {a:?}\n new-only: {b:?}\n old: {old:?}\n new: {expected:?}"));
    }
    Ok(upd)
}

// ----- editing-command helpers ------------------------------------------------------------------

pub const CARET: char = '\u{2038}'; // ‸
pub const SEL_OPEN: char = '\u{ab}'; // «
pub const SEL_CLOSE: char = '\u{bb}'; // »

/// Split `‸` (caret) or `«...»` (selection) markers from a text: (plain text, byte selection).
pub fn parse_marked(marked: &str) -> (String, (usize, usize)) {
    let mut text = String::new();
    let (mut s, mut e) = (None, None);
    for c in marked.chars() {
        match c {
            CARET => {
                s = Some(text.len());
                e = Some(text.len());
            }
            SEL_OPEN => s = Some(text.len()),
            SEL_CLOSE => e = Some(text.len()),
            c => text.push(c),
        }
    }
    let s = s.expect("no selection marker");
    (text, (s, e.unwrap_or(s)))
}

pub fn render_marked(text: &str, sel: (usize, usize)) -> String {
    let mut out = String::new();
    for (i, c) in text.char_indices() {
        if sel.0 == sel.1 && i == sel.0 {
            out.push(CARET);
        } else {
            if i == sel.0 {
                out.push(SEL_OPEN);
            }
            if i == sel.1 {
                out.push(SEL_CLOSE);
            }
        }
        out.push(c);
    }
    if sel.0 == sel.1 && sel.0 == text.len() {
        out.push(CARET);
    } else if sel.0 != sel.1 {
        if sel.0 == text.len() {
            out.push(SEL_OPEN);
        }
        if sel.1 == text.len() {
            out.push(SEL_CLOSE);
        }
    }
    out
}

/// Byte offset to unit offset in `enc` (independent implementation).
pub fn byte_to_unit(text: &str, enc: OffsetEncoding, byte: usize) -> u32 {
    text[..byte]
        .chars()
        .map(|c| match enc {
            OffsetEncoding::Utf8 => c.len_utf8() as u32,
            OffsetEncoding::Utf16 => c.len_utf16() as u32,
            OffsetEncoding::Utf32 => 1,
        })
        .sum()
}

pub fn unit_to_byte(text: &str, enc: OffsetEncoding, unit: u32) -> usize {
    let mut u = 0;
    for (i, c) in text.char_indices() {
        if u == unit {
            return i;
        }
        u += match enc {
            OffsetEncoding::Utf8 => c.len_utf8() as u32,
            OffsetEncoding::Utf16 => c.len_utf16() as u32,
            OffsetEncoding::Utf32 => 1,
        };
    }
    assert_eq!(u, unit, "unit offset {unit} is not on a code point boundary of {text:?}");
    text.len()
}

/// Apply an edit to `text` through `Document::replace` and return the new text and the
/// selection as byte offsets, checking that the edit is valid and the selection in bounds.
pub fn apply_edit(text: &str, enc: OffsetEncoding, edit: &TextEdit) -> Result<(String, (usize, usize)), String> {
    let mut doc = Document::new(text, enc);
    doc.replace(edit.range, &edit.replacement).map_err(|e| format!("replace failed: {e} for {edit:?}"))?;
    let new = doc.text().to_owned();
    let len = doc.len();
    let ok = boundaries(&new, enc);
    let sel = edit.selection;
    if sel.start > sel.end || sel.end > len || ok.binary_search(&sel.start).is_err() || ok.binary_search(&sel.end).is_err() {
        return Err(format!("selection {sel:?} out of bounds or off a boundary in {new:?} (len {len})"));
    }
    Ok((new.clone(), (unit_to_byte(&new, enc, sel.start), unit_to_byte(&new, enc, sel.end))))
}

pub const ALL_ENCODINGS: [OffsetEncoding; 3] = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32];

/// Run `f(doc, selection)` on a marked text in every encoding; returns the marked result
/// (or "None"). All encodings must agree.
pub fn run_marked(
    before: &str,
    f: impl Fn(&Document, TextRange) -> Option<TextEdit>,
) -> String {
    let (text, sel) = parse_marked(before);
    let mut results: Vec<String> = Vec::new();
    for enc in ALL_ENCODINGS {
        let doc = Document::new(&text, enc);
        let range = TextRange::new(byte_to_unit(&text, enc, sel.0), byte_to_unit(&text, enc, sel.1));
        results.push(match f(&doc, range) {
            None => "None".to_owned(),
            Some(edit) => match apply_edit(&text, enc, &edit) {
                Ok((new, nsel)) => render_marked(&new, nsel),
                Err(e) => panic!("{enc:?} {before:?}: {e}"),
            },
        });
    }
    assert!(results.iter().all(|r| *r == results[0]), "encodings disagree for {before:?}: {results:?}");
    results.remove(0)
}

// ----- random documents (shared by the robustness, rendering and fuzz tests) ----------------------

pub fn lcg(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    *seed >> 33
}

pub const TOKENS: &[&str] = &[
    "# ", "## ", "> ", "- ", "* ", "1. ", "- [ ] ", "- [x] ", "```", "```rs\n", "~~~", "---\n", "***", "\n", "\n\n",
    "\r\n", "\r", "  \n", "*", "**", "_", "__", "~~", "`", "``", "[", "](", ")", "![", "]", "[^1]", "[^1]: ", "|",
    "| a | b |\n", "|---|---|\n", "<div>", "</div>", "<b>", "<!--", "-->", "<http://a.b>", "www.a.b/c", "https://a.b/x_y ", "\\", "\\*", "word ",
    "text", " ", "    ", "\t", "=== ", "===\n", "[r]: /u\n", "[r]", "[r][]", "[t][r]", "\u{1F389}", "e\u{301}",
    "&amp;", "&#", "#", ":", "\"t\"", "'", "(", "<", ">", "\\\n", "x\\|y", "\u{0}", "\u{FEFF}", "+++\n", "...\n",
];

pub fn token_doc(seed: &mut u64, bytes: usize, tokens: &[&str]) -> String {
    let mut s = String::with_capacity(bytes + 64);
    while s.len() < bytes {
        s.push_str(tokens[(lcg(seed) as usize) % tokens.len()]);
    }
    s
}

pub fn random_unicode(seed: &mut u64, chars: usize) -> String {
    (0..chars)
        .map(|_| {
            let r = lcg(seed);
            match r % 4 {
                0 => char::from((r >> 8) as u8 & 0x7f),
                1 => char::from_u32(((r >> 8) % 0x800) as u32).unwrap_or('x'),
                2 => char::from_u32(((r >> 8) % 0x10000) as u32).unwrap_or('\u{FFFD}'),
                _ => char::from_u32(0x10000 + ((r >> 8) % 0x10000) as u32).unwrap_or('\u{1F600}'),
            }
        })
        .collect()
}

