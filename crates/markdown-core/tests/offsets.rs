//! Offset encodings: UTF-16 and UTF-32 results must equal an independent recomputation
//! from the UTF-8 results; edits in those units behave like the equivalent string edit.
mod common;
use common::*;
use markdown_core::*;

const SAMPLES: &[&str] = &[
    "# Title \u{1F389}\r\n\r\nEmoji **\u{1F469}\u{200D}\u{1F4BB} bold** \u{1F1EF}\u{1F1F5} and *e\u{301}\u{301}* `\u{65E5}\u{672C}\u{8A9E}` [\u{30EA}\u{30F3}\u{30AF}](http://\u{4F8B}\u{3048}.jp \"\u{30BF}\u{30A4}\u{30C8}\u{30EB}\")\r\n> quote \u{1F600}\r\n> more\r\n\r\n- [x] \u{4E2D}\u{6587} item\r\n- caf\u{E9} ~~\u{1F9EA}~~\r\n\r\n![\u{1F5BC} alt](img/\u{1F5BC}.png)\r\n\r\n| \u{1F34E} | b |\r\n|---|---|\r\n| \u{1D54F} | \u{FF21} |\r\n\r\ntext[^1]\r\n\r\n[^1]: \u{1F4DD} note\r\n",
    "\u{1F1FA}\u{1F1F8}\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467} **\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}**\n\n```rs\n\u{1F980} let x = \"\u{1F9E1}\";\n```\n",
    "a\u{301}\u{302}\u{303} _b\u{308}_\r\rlone cr \u{1F389} # not heading\r# heading \u{1F389}\r",
    "---\ntitle: \u{1F389}\n---\n\n\u{65E5}\u{672C}\u{8A9E}\u{306E}**\u{592A}\u{5B57}**\u{3002}\u{4E2D}\u{6587}\n",
    "",
    "\u{1F389}",
    // NUL (pulldown-cmark replaces it with U+FFFD in its output, not in the ranges), BOM.
    "\u{FEFF}# BOM *heading*\n\na\u{0}b *c\u{0}d* `\u{0}`\n",
    "\u{0}",
    "\n\n\n\n",
    "\r\r\n\n\r",
    // Flags, skin tones, ZWJ families, keycaps, variation selectors, combining marks.
    "\u{1F1E9}\u{1F1EA}\u{1F1EB}\u{1F1F7} **\u{1F44D}\u{1F3FD}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}** 1\u{FE0F}\u{20E3} \u{2764}\u{FE0F} _Z\u{351}\u{36B}\u{343}\u{36A}_\n",
];

/// Long lines of multi-byte text: spans that start and end far from the offset table's
/// checkpoints (every 256 bytes), on lines much longer than a stride.
fn long_samples() -> Vec<String> {
    let emoji_line: String = (0..400).map(|i| if i % 7 == 0 { " *\u{1F389}\u{1F389}* ".to_string() } else { "\u{1F469}\u{200D}\u{1F4BB}".to_string() }).collect();
    let mixed: String = (0..300).map(|i| format!("caf\u{e9} \u{65E5}{i} `\u{1F600}` [\u{30EA}](u{i}) e\u{301}\r\n")).collect();
    vec![emoji_line.clone() + "\n\n" + &emoji_line, mixed, "\u{10FFFF}".repeat(5000) + " **x**"]
}

fn width(ch: char, enc: OffsetEncoding) -> u32 {
    match enc {
        OffsetEncoding::Utf8 => ch.len_utf8() as u32,
        OffsetEncoding::Utf16 => ch.len_utf16() as u32,
        OffsetEncoding::Utf32 => 1,
    }
}

/// Independent: units before a byte offset.
fn units_before(text: &str, byte: u32, enc: OffsetEncoding) -> u32 {
    text[..byte as usize].chars().map(|c| width(c, enc)).sum()
}

fn convert(text: &str, r: TextRange, enc: OffsetEncoding) -> TextRange {
    TextRange::new(units_before(text, r.start, enc), units_before(text, r.end, enc))
}

/// Independent: byte offset of a unit offset, if on a boundary.
fn byte_of(text: &str, unit: u32, enc: OffsetEncoding) -> Option<usize> {
    let mut u = 0;
    for (i, c) in text.char_indices() {
        if u == unit {
            return Some(i);
        }
        u += width(c, enc);
    }
    (u == unit).then_some(text.len())
}

#[test]
fn spans_blocks_prose_images_match_independent_conversion() {
    let long = long_samples();
    for text in SAMPLES.iter().copied().chain(long.iter().map(String::as_str)) {
        let d8 = Document::new(text, OffsetEncoding::Utf8);
        for enc in [OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            let d = Document::new(text, enc);
            assert_eq!(d.len(), units_before(text, text.len() as u32, enc), "len in {enc:?}");
            check_everything(&d).unwrap();

            let want: Vec<Span> = d8
                .spans(None)
                .into_iter()
                .map(|s| Span { range: convert(text, s.range, enc), kind: s.kind })
                .collect();
            assert_eq!(d.spans(None), want, "spans {enc:?} of {text:?}");

            let want: Vec<Block> = d8
                .blocks()
                .into_iter()
                .map(|b| Block { range: convert(text, b.range, enc), ..b })
                .collect();
            assert_eq!(d.blocks(), want, "blocks {enc:?}");

            let want: Vec<TextRange> = d8.prose_ranges(None).into_iter().map(|r| convert(text, r, enc)).collect();
            assert_eq!(d.prose_ranges(None), want, "prose {enc:?}");

            let want: Vec<ImageRef> = d8
                .images()
                .into_iter()
                .map(|i| ImageRef { range: convert(text, i.range, enc), ..i })
                .collect();
            assert_eq!(d.images(), want, "images {enc:?}");

            let want: Vec<MarkupSpan> = d8
                .markup_spans(None)
                .into_iter()
                .map(|m| MarkupSpan { range: convert(text, m.range, enc), owner: convert(text, m.owner, enc), ..m })
                .collect();
            assert_eq!(d.markup_spans(None), want, "markup {enc:?}");
        }
    }
}

#[test]
fn span_text_is_identical_in_every_encoding() {
    for text in SAMPLES {
        let docs = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32].map(|e| Document::new(text, e));
        let views: Vec<Vec<String>> = docs.iter().map(fmt_spans).collect();
        let strip = |v: &Vec<String>| -> Vec<String> {
            v.iter().map(|l| l.split_once(' ').unwrap().1.to_owned()).collect()
        };
        assert_eq!(strip(&views[0]), strip(&views[1]));
        assert_eq!(strip(&views[0]), strip(&views[2]));
    }
}

#[test]
fn within_queries_match_filtering_the_full_list() {
    let text = SAMPLES[0];
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let d = Document::new(text, enc);
        let all = d.spans(None);
        let len = d.len();
        let bounds = boundaries(text, enc);
        let step = (bounds.len() / 23).max(1);
        for &a in bounds.iter().step_by(step) {
            for &b in bounds.iter().step_by(step) {
                if a >= b {
                    continue;
                }
                let want: Vec<Span> =
                    all.iter().filter(|s| s.range.start < b && s.range.end > a).copied().collect();
                assert_eq!(d.spans(Some(TextRange::new(a, b))), want, "{enc:?} within {a}..{b} of {len}");
            }
        }
    }
}

#[test]
fn within_inside_a_surrogate_pair_snaps_outward() {
    let t = "a **\u{1F389}** b";
    let d = Document::new(t, OffsetEncoding::Utf16);
    // 4 is the middle of the surrogate pair: the window covers the whole emoji.
    let inside = d.spans(Some(TextRange::new(5, 6)));
    assert!(inside.iter().any(|s| s.kind == SpanKind::Strong));
    assert!(inside.iter().all(|s| s.kind != SpanKind::Markup));
}

#[test]
fn replace_with_utf16_ranges_equals_string_edit() {
    let base = "# H \u{1F389}\n\nsome *text* \u{1F469}\u{200D}\u{1F4BB} here `c` \u{65E5}\u{672C}\n\n> q\n";
    let edits: &[(u32, u32, &str)] = &[
        (0, 0, "x"),
        (4, 6, "\u{1F600}\u{1F600}"),
        (10, 10, "**"),
        (14, 30, ""),
        (0, 40, "new"),
        (0, 0, ""),
    ];
    for enc in [OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        for &(s, e, with) in edits {
            let mut d = Document::new(base, enc);
            let (bs, be) = (byte_of(base, s, enc), byte_of(base, e, enc));
            let r = d.replace(TextRange::new(s, e), with);
            match (bs, be) {
                (Some(bs), Some(be)) => {
                    let mut want = base.to_owned();
                    want.replace_range(bs..be, with);
                    r.unwrap_or_else(|e| panic!("{enc:?} {s}..{e:?}: unexpected error {e}"));
                    assert_eq!(d.text(), want);
                    assert_eq!(d.revision(), 1);
                    // Analysis of the edited document equals analysis from scratch.
                    let fresh = Document::new(&want, enc);
                    assert_eq!(d.spans(None), fresh.spans(None));
                    assert_eq!(d.blocks(), fresh.blocks());
                    assert_eq!(d.len(), fresh.len());
                }
                _ => {
                    assert!(r.is_err());
                    assert_eq!(d.text(), base);
                    assert_eq!(d.revision(), 0);
                }
            }
        }
    }
}

#[test]
fn replace_errors_never_panic_and_leave_the_document_unchanged() {
    let t = "a\u{1F389}b"; // utf16: a=0..1, emoji=1..3, b=3..4
    let mut d = Document::new(t, OffsetEncoding::Utf16);
    assert_eq!(d.len(), 4);
    assert_eq!(d.replace(TextRange::new(2, 2), "x"), Err(EditError::NotOnCodePointBoundary));
    assert_eq!(d.replace(TextRange::new(0, 2), "x"), Err(EditError::NotOnCodePointBoundary));
    assert_eq!(d.replace(TextRange::new(2, 4), "x"), Err(EditError::NotOnCodePointBoundary));
    assert_eq!(d.replace(TextRange::new(3, 1), "x"), Err(EditError::InvertedRange));
    assert_eq!(d.replace(TextRange::new(0, 5), "x"), Err(EditError::OutOfBounds));
    assert_eq!(d.replace(TextRange::new(9, 9), "x"), Err(EditError::OutOfBounds));
    assert_eq!(d.replace(TextRange::new(u32::MAX, u32::MAX), "x"), Err(EditError::OutOfBounds));
    assert_eq!(d.text(), t);
    assert_eq!(d.revision(), 0);
    // Valid edits around the pair still work.
    d.replace(TextRange::new(1, 3), "").unwrap();
    assert_eq!(d.text(), "ab");

    // The same positions are fine in UTF-32 and UTF-8 where they do not split a code point.
    let mut d32 = Document::new(t, OffsetEncoding::Utf32);
    assert_eq!(d32.len(), 3);
    assert_eq!(d32.replace(TextRange::new(2, 3), "").map(|u| u.revision), Ok(1));
    assert_eq!(d32.text(), "a\u{1F389}");
    let mut d8 = Document::new(t, OffsetEncoding::Utf8);
    assert_eq!(d8.replace(TextRange::new(2, 3), "x"), Err(EditError::NotOnCodePointBoundary));
    assert_eq!(d8.replace(TextRange::new(1, 5), "x").map(|u| u.revision), Ok(1));
    assert_eq!(d8.text(), "axb");
}

#[test]
fn crlf_can_be_split_between_cr_and_lf() {
    // CR and LF are separate code points: an edit between them is legal.
    let mut d = Document::new("a\r\nb", OffsetEncoding::Utf16);
    d.replace(TextRange::new(2, 2), "x").unwrap();
    assert_eq!(d.text(), "a\rx\nb");
}

#[test]
fn multi_byte_replacement_text() {
    let mut d = Document::new("hello", OffsetEncoding::Utf16);
    let u = d.replace(TextRange::new(1, 4), "\u{1F469}\u{200D}\u{1F4BB}").unwrap();
    assert_eq!(d.text(), "h\u{1F469}\u{200D}\u{1F4BB}o");
    assert_eq!(d.len(), 7);
    assert_eq!(u.dirty, TextRange::new(0, 7));
}

#[test]
fn set_text_replaces_everything() {
    let mut d = Document::new("a *b*", OffsetEncoding::Utf16);
    let u = d.set_text("\u{1F389} **c** d");
    assert_eq!(u.revision, 1);
    assert_eq!(u.dirty, TextRange::new(0, d.len()));
    assert_eq!(d.text(), "\u{1F389} **c** d");
    assert_eq!(d.spans(None).len(), 3);
}

#[test]
fn replace_at_every_boundary_of_nasty_text() {
    let text = "\u{1F1EF}\u{1F1F5}\r\n*\u{1F469}\u{200D}\u{1F4BB}*\re\u{301}\u{0}`\u{FEFF}`\n> \u{10FFFF}";
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let b = boundaries(text, enc);
        let len = *b.last().unwrap();
        for &at in &b {
            for with in ["", "x", "*", "\n", "\u{1F389}", "\r"] {
                check_edit(text, enc, TextRange::new(at, at), with).unwrap_or_else(|e| panic!("{enc:?} {at} {with:?}: {e}"));
            }
            check_edit(text, enc, TextRange::new(at, len), "").unwrap();
            check_edit(text, enc, TextRange::new(0, at), "**").unwrap();
        }
        // Every unit that is not a boundary is rejected, for both endpoints.
        for u in 0..=len + 2 {
            let mut d = Document::new(text, enc);
            let r = d.replace(TextRange::new(u, u), "x");
            assert_eq!(r.is_ok(), b.binary_search(&u).is_ok(), "{enc:?} {u}");
            if u <= len && b.binary_search(&u).is_err() {
                assert_eq!(r, Err(EditError::NotOnCodePointBoundary));
                assert_eq!(d.replace(TextRange::new(0, u), ""), Err(EditError::NotOnCodePointBoundary));
                assert_eq!(d.replace(TextRange::new(u, len), ""), Err(EditError::NotOnCodePointBoundary));
            }
            assert!(d.text() == text || r.is_ok());
        }
    }
}

#[test]
fn huge_insert_and_delete_all() {
    let big: String = "word \u{1F389} *em* `c`\n".repeat(60_000); // ~1.3 MB
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let mut d = Document::new("a\nb", enc);
        let u = d.replace(TextRange::new(2, 2), &big).unwrap();
        // The inserted lines; the untouched last line `b` stays clean.
        assert_eq!(u.dirty, TextRange::new(2, d.len() - 1));
        let fresh = Document::new(d.text(), enc);
        assert_eq!(d.spans(None), fresh.spans(None));
        let len = d.len();
        let u = d.replace(TextRange::new(0, len), "").unwrap();
        assert_eq!(u.dirty, TextRange::new(0, 0));
        assert!(d.is_empty());
        assert!(d.spans(None).is_empty() && d.blocks().is_empty() && d.prose_ranges(None).is_empty());
        check_everything(&d).unwrap();
    }
}

#[test]
fn queries_on_an_empty_document() {
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let d = Document::new("", enc);
        assert_eq!(d.len(), 0);
        for w in [None, Some(TextRange::new(0, 0)), Some(TextRange::new(0, 5)), Some(TextRange::new(7, 3))] {
            assert!(d.spans(w).is_empty());
            assert!(d.markup_spans(w).is_empty());
            assert!(d.prose_ranges(w).is_empty());
        }
    }
}
