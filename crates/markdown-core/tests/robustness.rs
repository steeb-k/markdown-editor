//! Robustness: inputs that once crashed or stalled the core, plus (ignored, release-only)
//! fuzz loops for panics and super-linear time.
//!
//! `cargo test --profile fuzz -p markdown-core --test robustness -- --include-ignored --nocapture`
mod common;
use common::*;
use markdown_core::*;
use std::time::Instant;

/// pulldown-cmark 0.13.4 panics (`Option::unwrap` on `None` in parse.rs) on these. The core
/// must not: through FFI a panic aborts the app, and a panic inside `replace` would leave
/// the text changed but the analysis stale.
const PARSER_PANICS: &[&str] = &[
    ">1. [r]:u\n\t",
    "\n\n]**=== *word <b>text_~~~\\*[t][r]*===\n>1. [r]: /u\n\t",
    // Panics in pulldown-cmark only with debug assertions (dev builds of the app).
    "x\\|y    - > > e\u{301}![:|---|---|\n# ***:`#[^1]: <b>*\t\n\n\r\n:```rs\n ",
];

#[test]
fn parser_panics_do_not_escape_the_core() {
    for text in PARSER_PANICS {
        for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            let doc = Document::new(text, enc);
            assert_eq!(doc.text(), *text);
            check_everything(&doc).unwrap();
        }
    }
}

#[test]
fn typing_into_a_parser_panic_keeps_the_document_consistent() {
    // Type the minimal crashing input one character at a time, then keep editing.
    let target = ">1. [r]:u\n\t";
    let mut doc = Document::new("", OffsetEncoding::Utf16);
    for (i, ch) in target.chars().enumerate() {
        let at = doc.len();
        let u = doc.replace(TextRange::new(at, at), &ch.to_string()).unwrap();
        assert_eq!(u.revision, i as u64 + 1);
        check_everything(&doc).unwrap();
    }
    assert_eq!(doc.text(), target);
    let at = doc.len();
    doc.replace(TextRange::new(at, at), "x").unwrap();
    assert_eq!(doc.text(), ">1. [r]:u\n\tx");
    // Back out of the bad state: structure returns.
    let len = doc.len();
    doc.replace(TextRange::new(0, len), "*a*").unwrap();
    assert_eq!(doc.spans(None).len(), 3);
}

// ----- release-only fuzzing ---------------------------------------------------------------

/// Analysis and a mid-document edit of a 1 MB document, for one generator. Returns the
/// slower of the two and the time pulldown-cmark alone takes to parse the text.
fn time_one(name: &str, text: &str) -> (f64, f64) {
    let opts = pulldown_cmark::Options::ENABLE_TABLES
        | pulldown_cmark::Options::ENABLE_FOOTNOTES
        | pulldown_cmark::Options::ENABLE_STRIKETHROUGH
        | pulldown_cmark::Options::ENABLE_TASKLISTS
        | pulldown_cmark::Options::ENABLE_YAML_STYLE_METADATA_BLOCKS;
    let t = Instant::now();
    let events = pulldown_cmark::Parser::new_ext(text, opts).into_offset_iter().count();
    let t_parse = t.elapsed().as_secs_f64() * 1e3;
    let t = Instant::now();
    let mut doc = Document::new(text, OffsetEncoding::Utf16);
    let t_new = t.elapsed().as_secs_f64() * 1e3;
    let b = boundaries(text, OffsetEncoding::Utf16);
    let mid = b[b.len() / 2];
    let t = Instant::now();
    doc.replace(TextRange::new(mid, mid), "*").unwrap();
    let t_edit = t.elapsed().as_secs_f64() * 1e3;
    let t = Instant::now();
    let n = doc.spans(None).len();
    let t_spans = t.elapsed().as_secs_f64() * 1e3;
    println!(
        "{name:>28}: {:>8} bytes  parser alone {t_parse:6.1} ms ({events} events)  new {t_new:6.1} ms  edit {t_edit:6.1} ms  spans {t_spans:5.1} ms ({n})",
        text.len()
    );
    (t_new.max(t_edit), t_parse)
}

#[test]
#[ignore]
fn one_megabyte_documents_are_analyzed_in_linear_time() {
    const MB: usize = 1 << 20;
    let mut seed = 1u64;
    let mut cases: Vec<(String, String)> = vec![
        ("token soup".into(), token_doc(&mut seed, MB, TOKENS)),
        ("brackets and parens".into(), token_doc(&mut seed, MB, &["[", "]", "(", ")", "](", "![", "a", " "])),
        ("emphasis delimiters".into(), token_doc(&mut seed, MB, &["*", "**", "_", "__", "a", " ", "~~"])),
        ("backticks".into(), token_doc(&mut seed, MB, &["`", "``", "```", "a", " "])),
        ("quotes and lists".into(), token_doc(&mut seed, MB, &["> ", "- ", "1. ", "  ", "\t", "a", "\n"])),
        ("html-ish".into(), token_doc(&mut seed, MB, &["<", ">", "<a ", "</", "<!--", "-->", "=\"", "a"])),
        ("tables".into(), token_doc(&mut seed, MB, &["|", "|---", ":--", "\\|", "a", "\n", " "])),
        ("random unicode".into(), random_unicode(&mut seed, MB / 3)),
        ("nested quotes".into(), "> ".repeat(MB / 2)),
        ("nested quotes, many lines".into(), (0..MB / 64).map(|_| "> ".repeat(30) + "x\n").collect()),
        ("nested lists".into(), (0..MB / 40).map(|i| format!("{}- x\n", "  ".repeat(i % 40))).collect()),
        ("open links".into(), "[a](".repeat(MB / 4)),
        ("link openers".into(), "[".repeat(MB)),
        ("image openers".into(), "![".repeat(MB / 2)),
        ("unclosed emphasis".into(), "*a ".repeat(MB / 3)),
        ("alternating delimiters".into(), "*_".repeat(MB / 2)),
        ("backslashes".into(), "\\".repeat(MB)),
        ("escapes".into(), "\\*".repeat(MB / 2)),
        ("one long line".into(), "word ".repeat(MB / 5)),
        ("only newlines".into(), "\n".repeat(MB)),
        ("only CRs".into(), "\r".repeat(MB)),
        ("definitions".into(), "[a]: /u\n".repeat(MB / 8)),
        ("definitions, titles below".into(), "[a]: /u\n\"t\"\n".repeat(MB / 12)),
        ("table rows".into(), String::from("| a | b |\n|---|---|\n") + &"| x \\| y | z |\n".repeat(MB / 16)),
        ("fence in quote".into(), String::from("> ```\n") + &"> > x\n".repeat(MB / 6)),
        ("setext".into(), "a\n=\n".repeat(MB / 4)),
        ("footnotes".into(), (0..MB / 24).map(|i| format!("[^{i}]: > x[^{i}]\n")).collect()),
        ("autolinks".into(), "<http://a.b>".repeat(MB / 12)),
        ("entities".into(), "&amp;&#35;&#x1F600;".repeat(MB / 20)),
    ];
    for i in 0..10 {
        cases.push((format!("token soup #{i}"), token_doc(&mut seed, MB, TOKENS)));
    }
    // The core's own work (everything but pulldown-cmark's parse) must stay well under
    // 100 ms per MB; the parser's share is reported but is upstream's to fix. Known
    // upstream cost: many footnote definitions with the SAME label are quadratic in
    // pulldown-cmark 0.13.4 (75k duplicates: ~1.3 s), see `duplicate_footnote_labels`.
    let mut worst = (0.0, String::new());
    for (name, text) in &cases {
        let (t, parse) = time_one(name, text);
        if t - parse > worst.0 {
            worst = (t - parse, name.clone());
        }
    }
    println!("worst core overhead: {:.1} ms ({})", worst.0, worst.1);
    assert!(worst.0 < 100.0, "{}: core overhead {:.1} ms", worst.1, worst.0);
}

#[test]
#[ignore]
fn duplicate_footnote_labels() {
    // Upstream quadratic behaviour, recorded rather than asserted.
    for n in [5_000, 20_000, 75_000] {
        time_one(&format!("{n} duplicate footnote labels"), &"[^a]: x\n".repeat(n));
    }
}

#[test]
#[ignore]
fn random_documents_and_edits_never_panic() {
    let n: usize = std::env::var("FUZZ_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(200_000);
    let mut seed = 99u64;
    for i in 0..n {
        let size = lcg(&mut seed) as usize;
        let text = match i % 3 {
            0 => token_doc(&mut seed, size % 200, TOKENS),
            1 => random_unicode(&mut seed, size % 60),
            _ => {
                let len = (lcg(&mut seed) % 120) as usize;
                let bytes: Vec<u8> = (0..len).map(|_| { const A: &[u8] = b"*_`#>[]()!-|~\n \\<:^.+=\"'&1a\r\t"; A[lcg(&mut seed) as usize % A.len()] }).collect();
                String::from_utf8(bytes).unwrap()
            }
        };
        let enc = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32][i % 3];
        let mut doc = Document::new(&text, enc);
        if let Err(e) = check_everything(&doc) {
            panic!("{text:?} {enc:?}: {e}");
        }
        let b = boundaries(&text, enc);
        let (x, y) = (b[lcg(&mut seed) as usize % b.len()], b[lcg(&mut seed) as usize % b.len()]);
        let size = lcg(&mut seed) as usize;
        let with = token_doc(&mut seed, size % 6, TOKENS);
        let r = TextRange::new(x.min(y), x.max(y));
        if let Err(e) = check_edit(&text, enc, r, &with) {
            panic!("{text:?} {enc:?} edit {r:?} -> {with:?}: {e}");
        }
        doc.replace(r, &with).unwrap();
    }
}

/// A tab-indented `>` line in a quoted HTML block: pulldown-cmark keeps it in the block
/// without reporting its text; it must not become a quote marker overlapping the block.
#[test]
fn tab_indented_marker_inside_quoted_html_block() {
    let text = "word\n> <div>\n\t>  ";
    let doc = markdown_core::Document::new(text, markdown_core::OffsetEncoding::Utf8);
    let spans = doc.spans(None);
    assert!(spans.iter().any(|s| s.kind == markdown_core::SpanKind::Html));
}
