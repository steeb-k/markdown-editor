//! Property tests: analysis never panics, the span contract holds, prose ranges avoid markup,
//! and dirty ranges are sound.
mod common;
use common::*;
use markdown_core::*;
use proptest::prelude::*;

const ENCODINGS: [OffsetEncoding; 3] = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32];

/// Markdown-heavy alphabet.
fn alphabet() -> Vec<char> {
    let mut v: Vec<char> = "*_`#>[]()!-|~\n \\<>:^.+=\"'&$".chars().collect();
    v.extend("0123456789".chars());
    v.extend("abcxyzAB".chars());
    v.extend(['\r', '\t', '\u{e9}', '\u{65E5}', '\u{1F389}', '\u{301}', '\u{200D}']);
    v
}

fn md_chars(max: usize) -> impl Strategy<Value = String> {
    let a = alphabet();
    prop::collection::vec(prop::sample::select(a), 0..max).prop_map(|v| v.into_iter().collect())
}

/// Concatenation of Markdown-ish tokens: reaches multi-character constructs far more often.
fn md_tokens(max: usize) -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "# ", "## ", "> ", "- ", "* ", "1. ", "- [ ] ", "- [x] ", "```", "```rs\n", "~~~", "---\n", "***", "\n", "\n\n",
        "\r\n", "  \n", "*", "**", "_", "~~", "`", "[", "](", ")", "![", "]", "[^1]", "[^1]: ", "|", "| a | b |\n", "|---|---|\n",
        "<div>", "</div>", "<b>", "<http://a.b>", "www.a.b/c", "http://a.b/x_y ", "(www.a.b)", "\\", "\\*", "word ", "text", " ", "    ", "=== ", "===\n", "[r]: /u\n",
        "[r]", "\u{1F389}", "\u{65E5}\u{672C}", "e\u{301}", "&amp;", "#",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat())
}

fn any_md() -> impl Strategy<Value = String> {
    prop_oneof![any::<String>(), md_chars(160), md_tokens(40)]
}

proptest! {
    // PROPTEST_CASES overrides the default of 600 (an explicit `cases` would ignore it).
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(600)
    ))]

    #[test]
    fn analysis_never_panics_and_holds_the_contract(text in any_md()) {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            if let Err(e) = check_everything(&doc) {
                return Err(TestCaseError::fail(format!("{enc:?} {text:?}: {e}")));
            }
        }
    }

    #[test]
    fn within_queries_are_consistent(text in md_tokens(30), a in 0u32..120, b in 0u32..120) {
        let doc = Document::new(&text, OffsetEncoding::Utf16);
        let len = doc.len();
        let (s, e) = (a.min(len), b.min(len));
        let all = doc.spans(None);
        let got = doc.spans(Some(TextRange::new(s, e)));
        // Subsequence of the full list, all intersecting (when the window is non-empty and aligned).
        let mut it = all.iter();
        for g in &got {
            prop_assert!(it.any(|x| x == g), "not a subsequence: {g:?}");
        }
        if s < e {
            for g in &got {
                // mid-code-point endpoints snap outward, so allow equality slack of one unit
                prop_assert!(g.range.start < e + 1 && g.range.end + 1 > s);
            }
        }
        let prose = doc.prose_ranges(Some(TextRange::new(s, e)));
        for p in prose {
            prop_assert!(p.start >= s.saturating_sub(1) && p.end <= e + 1 && p.start < p.end);
        }
    }

    #[test]
    fn dirty_range_is_sound_for_random_edits(
        text in prop_oneof![md_chars(120), md_tokens(30)],
        with in prop_oneof![md_chars(8), md_tokens(4)],
        a in 0usize..200, b in 0usize..200, enc_i in 0usize..3,
    ) {
        let enc = ENCODINGS[enc_i];
        let bounds = boundaries(&text, enc);
        let (mut i, mut j) = (a % bounds.len(), b % bounds.len());
        if i > j { std::mem::swap(&mut i, &mut j); }
        let range = TextRange::new(bounds[i], bounds[j]);
        if let Err(e) = check_edit(&text, enc, range, &with) {
            return Err(TestCaseError::fail(format!("{enc:?} edit {range:?} -> {with:?}: {e}")));
        }
    }

    #[test]
    fn edit_sequences_stay_consistent(
        text in md_tokens(20),
        edits in prop::collection::vec((0usize..400, 0usize..400, md_tokens(3)), 1..6),
    ) {
        let mut doc = Document::new(&text, OffsetEncoding::Utf16);
        let mut expected = text.clone();
        for (n, (a, b, with)) in edits.into_iter().enumerate() {
            let bounds = boundaries(&expected, OffsetEncoding::Utf16);
            let (mut i, mut j) = (a % bounds.len(), b % bounds.len());
            if i > j { std::mem::swap(&mut i, &mut j); }
            let chars: Vec<char> = expected.chars().collect();
            let mut next: String = chars[..i].iter().collect();
            next.push_str(&with);
            next.extend(chars[j..].iter());
            let u = doc.replace(TextRange::new(bounds[i], bounds[j]), &with).unwrap();
            expected = next;
            prop_assert_eq!(doc.text(), expected.as_str());
            prop_assert_eq!(u.revision, n as u64 + 1);
            let fresh = Document::new(&expected, OffsetEncoding::Utf16);
            prop_assert_eq!(doc.spans(None), fresh.spans(None));
            if let Err(e) = check_everything(&doc) {
                return Err(TestCaseError::fail(e));
            }
        }
    }

    #[test]
    fn invalid_ranges_are_errors_not_panics(text in md_chars(40), a in any::<u32>(), b in any::<u32>(), enc_i in 0usize..3) {
        let enc = ENCODINGS[enc_i];
        let mut doc = Document::new(&text, enc);
        let before = doc.text().to_owned();
        let bounds = boundaries(&text, enc);
        let valid = |x: u32| bounds.binary_search(&x).is_ok();
        let r = doc.replace(TextRange::new(a, b), "x");
        if a <= b && valid(a) && valid(b) {
            prop_assert!(r.is_ok());
        } else {
            prop_assert!(r.is_err());
            prop_assert_eq!(doc.text(), before.as_str());
            prop_assert_eq!(doc.revision(), 0);
        }
    }
}

/// Per-unit styling a shell would hold: for every unit, the kinds of the spans covering it
/// (outermost first).
fn attributes(doc: &Document, within: TextRange) -> Vec<Vec<SpanKind>> {
    let mut out = vec![Vec::new(); (within.end - within.start) as usize];
    for s in doc.spans(Some(within)) {
        for u in s.range.start.max(within.start)..s.range.end.min(within.end) {
            out[(u - within.start) as usize].push(s.kind);
        }
    }
    out
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).map_or(150, |n: u32| n / 4 + 1)
    ))]

    /// A shell that restyles only `dirty` after each edit (its attributes move with the
    /// text, like NSTextStorage's) ends up with exactly the styling of a fresh analysis;
    /// and the incrementally edited document equals a fresh one in every respect.
    #[test]
    fn restyling_only_the_dirty_range_is_enough(
        text in md_tokens(30),
        edits in prop::collection::vec((0usize..1000, 0usize..1000, prop_oneof![md_tokens(4), md_chars(6)]), 1..40),
        enc_i in 0usize..3,
    ) {
        let enc = ENCODINGS[enc_i];
        let mut doc = Document::new(&text, enc);
        let mut shell = attributes(&doc, TextRange::new(0, doc.len()));
        for (a, b, with) in edits {
            let bounds = boundaries(doc.text(), enc);
            let (mut i, mut j) = (a % bounds.len(), b % bounds.len());
            if i > j { std::mem::swap(&mut i, &mut j); }
            let (s, e) = (bounds[i], bounds[j]);
            let u = doc.replace(TextRange::new(s, e), &with).unwrap();
            // The text storage moves attributes with the text; inserted text gets placeholders.
            let ins = doc.len() as usize + (e - s) as usize - shell.len();
            shell.splice(s as usize..e as usize, std::iter::repeat_n(vec![SpanKind::Markup, SpanKind::Markup], ins));
            prop_assert_eq!(shell.len(), doc.len() as usize);
            let fresh_dirty = attributes(&doc, u.dirty);
            shell.splice(u.dirty.start as usize..u.dirty.end as usize, fresh_dirty);

            let fresh = Document::new(doc.text(), enc);
            prop_assert_eq!(&shell, &attributes(&fresh, TextRange::new(0, fresh.len())), "after {:?} -> {:?}", (s, e), with);
            prop_assert_eq!(doc.spans(None), fresh.spans(None));
            prop_assert_eq!(doc.markup_spans(None), fresh.markup_spans(None));
            prop_assert_eq!(doc.blocks(), fresh.blocks());
            prop_assert_eq!(doc.images(), fresh.images());
            prop_assert_eq!(doc.prose_ranges(None), fresh.prose_ranges(None));
        }
    }
}
