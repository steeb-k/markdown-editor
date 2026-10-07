//! Broad property tests added in the overnight bug-hunting pass: the outline, code highlighting
//! (fresh against incremental), the sanitizer and the balance of the HTML, the highlighter on any
//! input, the library with odd paths, the history against a model with damaged indexes, and the
//! annotation block's byte-for-byte round trip. `PROPTEST_CASES` scales them all.
//!
//! `PROPTEST_CASES=20000 cargo test --profile fuzz -p markdown-core --test fuzz`
mod common;
use common::*;
use markdown_core::authorship::{self as au, Author, AuthorKind, AnnotationStatus, Authorship, LineEnding};
use markdown_core::history::{History, Reason};
use markdown_core::library::{Library, NoteRef};
use markdown_core::*;
use proptest::prelude::*;
use std::collections::BTreeMap;

const ENCODINGS: [OffsetEncoding; 3] = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32];

fn cases(default: u32) -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).map_or(default, |n: u32| n.max(1))
}

const TOKENS: &[&str] = &[
    "# ", "## ", "###### ", "####### ", "> ", "> > ", "- ", "* ", "1. ", "- [ ] ", "  ", "    ", "\t", "```", "```rs\n", "~~~", "~~~~py\n", "---\n", "===\n", "\n", "\n",
    "\n\n", "\r\n", "\r", "*", "**", "_", "~~", "`", "``", "[", "](", ")", "![", "]", "| a | b |\n", "|---|---|\n", "|", "word", "word ", " ", "www.a.b/c", "http://a.b ",
    "<b>", "</b>", "<!--", "-->", "<!a ", "<?x ", ">", "\\", "\u{1F389}", "\u{65E5}\u{672C}", "e\u{301}", "\u{e9}", "\u{feff}", "&amp;", "&#106;", "[^1]", "[^1]: x\n",
    "[r]: /u\n", "[r]", "<http://a.b>", "[[a]]", "[[a|b]]", "[[a#h]]", "#tag", "#a/b ", "[[", "]]", "#", "{#id}", "$", "$$", ":", "\0",
];

fn soup(max: usize) -> impl Strategy<Value = String> {
    prop_oneof![
        4 => prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat()),
        1 => any::<String>(),
        1 => "[ -~\n\r\t\u{e9}\u{65E5}\u{1F389}]{0,80}",
    ]
}

fn heading_soup(max: usize) -> impl Strategy<Value = String> {
    const H: &[&str] = &[
        "# ", "## ", "### ", "#### ", "##### ", "###### ", "# ", "#\n", "Title\n===\n", "Sub\n---\n", "\n", "\n\n", "text ", "**b** ", "*e* ", "`c` ", "[l](u) ", "![a](p) ",
        "[r] ", "[r]: /u\n", "[^1] ", "[^1]: n\n", "[[w]] ", "[[w|label]] ", "&amp; ", "\\# ", "> ", "- ", "1. ", "```\n", "<b>", "</b>", " #", " ##\n", "\u{1F389}", "\u{e9}", "\r\n", "\r",
        "  ", "\t", "<h1>", "|", "~~x~~ ", "=", "-", "\\",
    ];
    prop::collection::vec(prop::sample::select(H), 0..max).prop_map(|v| v.concat())
}

// ----- the outline ------------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(800)))]

    /// Entries are in bounds on code point boundaries, sorted and disjoint, with levels 1 to 6, a
    /// single-line trimmed text, a line that matches the range, and the heading's id in the preview.
    #[test]
    fn outline_entries_are_in_bounds_sorted_and_agree_with_the_preview(text in heading_soup(40)) {
        for enc in ENCODINGS {
            let d = Document::new(&text, enc);
            let html = d.render_html(&RenderOptions::default());
            let ok = boundaries(d.text(), enc);
            let mut prev_end = 0u32;
            let mut prev_line = None;
            for e in d.outline() {
                prop_assert!((1..=6).contains(&e.level), "{e:?}");
                prop_assert!(e.range.start < e.range.end && e.range.end <= d.len(), "{e:?} len {}", d.len());
                prop_assert!(ok.binary_search(&e.range.start).is_ok() && ok.binary_search(&e.range.end).is_ok(), "{e:?}");
                prop_assert!(e.range.start >= prev_end, "unsorted or overlapping: {e:?}");
                prev_end = e.range.end;
                prop_assert!(prev_line.is_none_or(|l| e.line > l), "lines not increasing: {e:?}");
                prev_line = Some(e.line);
                prop_assert!(!e.text.contains(['\n', '\r']) && e.text == e.text.trim(), "{:?}", e.text);
                // The line is the number of line ends before the heading, counting CRLF as one.
                let before = slice_units(d.text(), enc, TextRange::new(0, e.range.start));
                let b = before.as_bytes();
                let mut lines = 0u32;
                let mut i = 0;
                while i < b.len() {
                    if b[i] == b'\r' && b.get(i + 1) == Some(&b'\n') { i += 1; }
                    if matches!(b[i], b'\r' | b'\n') { lines += 1; }
                    i += 1;
                }
                prop_assert_eq!(e.line, lines, "line of {:?}", e);
                // A heading with text has an id the preview made from that text.
                // (The preview's id is made from the heading's source text, a wikilink's brackets included, so a
                // heading with a wikilink is left out: see the report.)
                // (A setext heading right after a reference definition and a tab-indented line reads "# Title" to the renderer and
                // "Title" to the outline: see the report.)
                // A heading in a footnote definition the renderer drops (a label defined twice) is the outline's, not the page's.
                // And pulldown-cmark's own reading of a bare `\r` after an empty list item (`- \r\nTitle\n===` is a heading
                // "- Title" to its renderer, "Title" to the CommonMark spec and the analysis) is not the outline's.
                if !e.text.is_empty() && !slug(&e.text).is_empty() && !slice_units(d.text(), enc, e.range).contains("[[") && !d.text().contains(['\r', '^']) && !d.text().contains("]:") {
                    prop_assert!(html.contains(&format!("id=\"{}", slug(&e.text))), "{:?} not in {html}", e.text);
                }
            }
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(500)))]

    /// After any edits the outline is the one a fresh document gives, and the wikilinks and tags found are too.
    #[test]
    fn the_outline_after_edits_equals_a_fresh_one(
        text in heading_soup(30),
        edits in prop::collection::vec((any::<u32>(), any::<u32>(), heading_soup(4)), 1..5),
        enc_i in 0usize..3,
    ) {
        let enc = ENCODINGS[enc_i];
        let mut d = Document::new(&text, enc);
        for (a, b, with) in edits {
            let bounds = boundaries(d.text(), enc);
            let (x, y) = (bounds[a as usize % bounds.len()], bounds[b as usize % bounds.len()]);
            if d.replace(TextRange::new(x.min(y), x.max(y)), &with).is_err() {
                continue;
            }
            let fresh = Document::new(d.text(), enc);
            prop_assert_eq!(d.outline(), fresh.outline());
        }
    }
}

// ----- code highlighting --------------------------------------------------------------------------

fn info_string() -> impl Strategy<Value = String> {
    let names: Vec<String> = markdown_core::languages().iter().flat_map(|(a, b)| [a.clone(), b.clone()]).collect();
    prop_oneof![
        4 => prop::sample::select(names.clone()),
        2 => (prop::sample::select(names), "[ ,{}.=a-z0-9\"'-]{0,12}").prop_map(|(n, r)| format!("{n}{r}")),
        1 => "[ -~\u{e9}\u{1F389}]{0,16}",
        1 => Just(String::new()),
    ]
}

fn code_line() -> impl Strategy<Value = String> {
    prop_oneof![
        2 => "[ -~]{0,30}",
        1 => prop::sample::select(vec!["fn main() {", "}", "/* open", "close */", "\"unterminated", "'", "#include <x>", "<?php", "?>", "<div class=\"a\">", "</div>", "{\"a\": [1, 2]}", "--", "```", "~~~", "\t", "\u{1F389} \u{65E5}", "e\u{301}", "\\", "<!--", "-->", "r#\"", "\"\"\"", "$(", "`"]).prop_map(String::from),
    ]
}

fn fenced_doc() -> impl Strategy<Value = String> {
    let block = (info_string(), prop::collection::vec(code_line(), 0..6), prop::sample::select(vec!["```", "````", "~~~", "~~~~~"]), prop::sample::select(vec!["", "> ", "- ", "  ", "> > ", "1. "]), any::<bool>())
        .prop_map(|(info, lines, fence, prefix, close)| {
            let mut s = format!("{prefix}{fence}{info}\n");
            for l in lines {
                s.push_str(&format!("{prefix}{l}\n"));
            }
            if close {
                s.push_str(&format!("{prefix}{fence}\n"));
            }
            s
        });
    let prose = prop::sample::select(vec!["text\n", "\n", "# h\n", "<div>\n", "| a |\n"]).prop_map(String::from);
    (prop::collection::vec(prop_oneof![3 => block, 1 => prose], 1..6), prop::sample::select(vec!["\n", "\r\n", "\r"]))
        .prop_map(|(v, nl)| v.concat().replace('\n', nl))
}

fn check_runs(d: &Document) -> Result<(), String> {
    let hs = d.code_highlights(None);
    let text = d.text();
    let blocks: Vec<Block> = d.blocks().into_iter().filter(|b| b.kind == BlockKind::CodeBlock).collect();
    let mut prev_end = 0;
    for h in &hs {
        if !(h.range.start < h.range.end && h.range.end <= d.len()) {
            return Err(format!("out of bounds {h:?} len {}", d.len()));
        }
        if h.range.start < prev_end {
            return Err(format!("unsorted or overlapping at {h:?}"));
        }
        prev_end = h.range.end;
        let s = slice_units(text, d.encoding(), h.range);
        if s.contains(['\n', '\r']) {
            return Err(format!("a run spans a line end: {h:?} {s:?}"));
        }
        if !blocks.iter().any(|b| b.range.start <= h.range.start && h.range.end <= b.range.end) {
            return Err(format!("{h:?} is not inside a code block"));
        }
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(500)))]

    /// Every run is in bounds and inside a code block, and after any edit the incremental answer
    /// is the fresh one.
    #[test]
    fn code_runs_are_sound_and_incremental_equals_fresh(
        text in prop_oneof![3 => fenced_doc(), 1 => soup(30)],
        edits in prop::collection::vec((any::<u32>(), any::<u32>(), soup(4)), 0..4),
        enc_i in 0usize..3,
    ) {
        let enc = ENCODINGS[enc_i];
        let mut d = Document::new(&text, enc);
        prop_assert_eq!(check_runs(&d), Ok(()));
        for (a, b, with) in edits {
            let bounds = boundaries(d.text(), enc);
            let (x, y) = (bounds[a as usize % bounds.len()], bounds[b as usize % bounds.len()]);
            let r = TextRange::new(x.min(y), x.max(y));
            if d.replace(r, &with).is_err() {
                continue;
            }
            prop_assert_eq!(check_runs(&d), Ok(()));
            let fresh = Document::new(d.text(), enc);
            prop_assert_eq!(d.code_highlights(None), fresh.code_highlights(None));
            prop_assert_eq!(d.blocks(), fresh.blocks());
        }
    }

    /// The highlighter, whatever the info string and code, never panics (it runs behind the
    /// FFI) and answers with roles in bounds.
    #[test]
    fn the_highlighter_survives_any_input(info in info_string(), code in prop_oneof![soup(40), prop::collection::vec(code_line(), 0..20).prop_map(|v| v.join("\n"))]) {
        let r = std::panic::catch_unwind(|| {
            let _ = markdown_core::highlight::is_highlightable(&info, &code);
            let _ = markdown_core::highlight::info_token(&info);
            let _ = markdown_core::highlight::language_name(&info);
            let html = markdown_core::highlight::highlight(&info, &code);
            let runs = markdown_core::highlight::roles_cached(&info, &code);
            (html, runs)
        });
        prop_assert!(r.is_ok(), "panicked on info {info:?} code {code:?}");
        let (_, runs) = r.unwrap();
        if let Some(runs) = runs {
            let mut prev = 0;
            for run in runs.iter() {
                prop_assert!(run.start >= prev && run.start < run.end && run.end as usize <= code.len(), "{run:?} in {} bytes", code.len());
                prop_assert!(code.is_char_boundary(run.start as usize) && code.is_char_boundary(run.end as usize), "{run:?}");
                prev = run.end;
            }
        }
    }
}

// ----- the sanitizer and the shape of the HTML ----------------------------------------------------------

const VOID: &[&str] = &["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"];

/// Every tag in `html` as (closing, name, attributes), by a browser-like reading.
#[allow(clippy::type_complexity)]
fn tags_of(html: &str) -> Vec<(bool, String, Vec<(String, String)>)> {
    let b = html.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'<' {
            i += 1;
            continue;
        }
        if html[i..].starts_with("<!--") {
            i = html[i + 4..].find("-->").map_or(b.len(), |e| i + 4 + e + 3);
            continue;
        }
        let closing = b.get(i + 1) == Some(&b'/');
        let s = i + 1 + usize::from(closing);
        if s < b.len() && b[s].is_ascii_alphabetic() {
            let mut j = s;
            while j < b.len() && !b[j].is_ascii_whitespace() && b[j] != b'/' && b[j] != b'>' {
                j += 1;
            }
            let name = html[s..j].to_ascii_lowercase();
            let mut attrs = Vec::new();
            loop {
                while j < b.len() && (b[j].is_ascii_whitespace() || b[j] == b'/') {
                    j += 1;
                }
                if j >= b.len() || b[j] == b'>' {
                    break;
                }
                let ns = j;
                while j < b.len() && !b[j].is_ascii_whitespace() && b[j] != b'=' && b[j] != b'>' && b[j] != b'/' {
                    j += 1;
                }
                let an = html[ns..j].to_ascii_lowercase();
                let mut val = String::new();
                while j < b.len() && b[j].is_ascii_whitespace() {
                    j += 1;
                }
                if j < b.len() && b[j] == b'=' {
                    j += 1;
                    while j < b.len() && b[j].is_ascii_whitespace() {
                        j += 1;
                    }
                    if j < b.len() && (b[j] == b'"' || b[j] == b'\'') {
                        let q = b[j];
                        let vs = j + 1;
                        j = vs;
                        while j < b.len() && b[j] != q {
                            j += 1;
                        }
                        val = html[vs..j.min(b.len())].to_string();
                        j = (j + 1).min(b.len());
                    } else {
                        let vs = j;
                        while j < b.len() && !b[j].is_ascii_whitespace() && b[j] != b'>' {
                            j += 1;
                        }
                        val = html[vs..j].to_string();
                    }
                }
                if an.is_empty() {
                    j += 1;
                } else {
                    attrs.push((an, val));
                }
            }
            out.push((closing, name, attrs));
            i = (j + 1).min(b.len().max(j + 1));
            continue;
        }
        i += 1;
    }
    out
}

fn decode_simple(v: &str) -> String {
    v.replace("&amp;", "&").replace("&colon;", ":").replace("&Tab;", "").replace("&NewLine;", "").replace("&quot;", "\"").replace("&#58;", ":").replace("&#x3a;", ":")
}

fn html_soup(max: usize) -> impl Strategy<Value = String> {
    const H: &[&str] = &[
        "<script>", "</script>", "<SCRIPT SRC=//x>", "<style>", "</style>", "<iframe src=x>", "</iframe>", "<img src=x onerror=alert(1)>", "<a href=\"javascript:alert(1)\">", "<a href='  JaVa\tScript:x'>",
        "<a href=\"&#106;avascript:x\">", "<a href=\"java&Tab;script&colon;x\">", "</a>", "<div onclick=x>", "<div\nonmouseover=\"a\">", "</div>", "<p title=\">\" onload=x>", "[x](javascript:alert(1))",
        "[x](  JAVASCRIPT:alert(1))", "![x](javascript:a)", "[x](data:text/html,x)", "<a href=vbscript:x>", "<object data=x>", "<embed src=x>", "<form action=x>", "<svg onload=x>", "<math>", "<base href=//e>",
        "<meta http-equiv=refresh content=0>", "<link rel=stylesheet href=x>", "<b>", "</b>", "<p>", "</p>", "<!--", "-->", "<![CDATA[", "<?x?>", "<!doctype html>", "text ", "\n", "\n\n", "> ", "- ", "`", "```\n",
        "<", ">", "\"", "'", "=", "&lt;script&gt;", "&#x3C;script>", "<scr\0ipt>", "<script/x>", "<a/href=javascript:x>", "<img/src=x/onerror=y>", "<x onclick=y>", "<ONCLICK=y>",
    ];
    prop_oneof![
        3 => prop::collection::vec(prop::sample::select(H), 0..max).prop_map(|v| v.concat()),
        1 => soup(30),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(1500)))]

    /// Whatever the document says, sanitized output has no script-like element, no event
    /// attribute, no script URL in `href` or `src`, and no `<script` or `javascript:` at all.
    #[test]
    fn the_sanitizer_leaves_nothing_that_runs(text in html_soup(40), enc_i in 0usize..3) {
        let d = Document::new(&text, ENCODINGS[enc_i]);
        for opts in [
            RenderOptions { sanitize: true, ..Default::default() },
            RenderOptions { sanitize: true, standalone: true, source_lines: true, ..Default::default() },
            RenderOptions { sanitize: true, highlight: false, ..Default::default() },
        ] {
            let standalone = opts.standalone;
            let h = d.render_html(&opts);
            let lower = h.to_ascii_lowercase();
            // The standalone page carries its own stylesheet; the body is what the document wrote.
            let body = if standalone { lower.split_once("</style>").map_or(lower.as_str(), |x| x.1) } else { lower.as_str() };
            prop_assert!(!body.contains("<script"), "{text:?} -> {h}");
            for (closing, name, attrs) in tags_of(&h) {
                if standalone && matches!(name.as_str(), "meta" | "style" | "html" | "head" | "title") {
                    continue;
                }
                prop_assert!(!matches!(name.as_str(), "script" | "iframe" | "object" | "embed" | "style" | "frame" | "frameset" | "base" | "form" | "link" | "meta" | "svg" | "math" | "applet"), "{name} (closing {closing}) in {h} from {text:?}");
                for (an, v) in attrs {
                    prop_assert!(!an.starts_with("on"), "{an}={v} in {h} from {text:?}");
                    if matches!(an.as_str(), "href" | "src" | "action" | "formaction" | "xlink:href" | "srcdoc" | "data" | "poster") {
                        let flat: String = decode_simple(&v).chars().filter(|c| !c.is_whitespace() && !c.is_control()).collect::<String>().to_ascii_lowercase();
                        prop_assert!(!flat.starts_with("javascript:") && !flat.starts_with("vbscript:") && !flat.starts_with("data:text/html"), "{an}={v} in {h} from {text:?}");
                        prop_assert!(an != "srcdoc", "srcdoc in {h}");
                    }
                }
            }
        }
    }

    /// Markdown without raw HTML renders to balanced tags (void elements aside), whether or not
    /// it is sanitized.
    #[test]
    fn rendered_html_is_balanced(text in soup(40), sanitize in any::<bool>(), enc_i in 0usize..3) {
        // Raw HTML is the author's own (it may be unbalanced and still pass through): take it out.
        let text = text.replace(['<', '\0'], "");
        let d = Document::new(&text, ENCODINGS[enc_i]);
        let h = d.render_html(&RenderOptions { sanitize, source_lines: true, ..Default::default() });
        let mut stack: Vec<String> = Vec::new();
        for (closing, name, _) in tags_of(&h) {
            if VOID.contains(&name.as_str()) {
                continue;
            }
            if closing {
                let top = stack.pop();
                prop_assert_eq!(top.as_deref(), Some(name.as_str()), "closing {} in {} from {:?}", name, h, text);
            } else {
                stack.push(name);
            }
        }
        prop_assert!(stack.is_empty(), "unclosed {stack:?} in {h} from {text:?}");
    }
}

// ----- the library, with odd paths --------------------------------------------------------------------

fn odd_path() -> impl Strategy<Value = String> {
    prop_oneof![
        3 => prop::sample::select(vec!["a.md", "A.md", "a.MD", "b.md", "x/a.md", "X/a.md", "x//a.md", "x/./a.md", "../a.md", "..", ".", "", "/", "x/", " .md", "a b.md", "a%20b.md", "e\u{301}.md", "\u{e9}.md", "\u{1F389}.md", "\u{65E5}/\u{672C}.md", "\u{130}.md", "i\u{307}.md", "\u{df}.md", "SS.md", "ss.md", "a.md ", " a.md", "a\u{0}b.md", "a\\b.md", "[[x]].md", "#tag.md", "a|b.md"]).prop_map(String::from),
        2 => "[a-zA-Z0-9 ./%\u{e9}\u{301}\u{1F389}-]{0,14}",
    ]
}

#[derive(Debug, Clone)]
enum LibOp {
    Upsert(String, bool, String),
    Remove(String, bool),
    Rename(String, bool, String, bool),
    DropRoot(bool),
}

fn lib_op() -> impl Strategy<Value = LibOp> {
    let text = prop::collection::vec(prop::sample::select(vec!["[[a]] ", "[[x/a]] ", "[[e\u{301}]] ", "[[\u{e9}]] ", "[[A#h]] ", "#t ", "# a\n", "# \u{e9}\n", "word ", "\n", "[[a%20b]] ", "[[ss]] ", "[[../a]] ", "[[/]] ", "[[]] "]), 0..8).prop_map(|v| v.concat());
    prop_oneof![
        4 => (odd_path(), any::<bool>(), text).prop_map(|(p, r, t)| LibOp::Upsert(p, r, t)),
        2 => (odd_path(), any::<bool>()).prop_map(|(p, r)| LibOp::Remove(p, r)),
        2 => (odd_path(), any::<bool>(), odd_path(), any::<bool>()).prop_map(|(a, r, b, s)| LibOp::Rename(a, r, b, s)),
        1 => any::<bool>().prop_map(LibOp::DropRoot),
    ]
}

fn root(second: bool) -> &'static str {
    if second { "s" } else { "r" }
}

fn lib_snapshot(lib: &Library) -> String {
    let mut out = String::new();
    for info in lib.notes(&library::Filter::default(), library::Sort::NameAscending) {
        out.push_str(&format!("{:?}\n  backlinks {:?}\n  mentions {:?}\n", lib.note(&info.note).unwrap(), lib.backlinks(&info.note), lib.mentions(&info.note)));
    }
    out.push_str(&format!("tags {:?}\n", lib.tags()));
    for q in ["a", "e", "\u{e9}", "x", "ss", "word", ""] {
        out.push_str(&format!("search {q} {:?}\nquick {q} {:?}\n", lib.search(q, 50), lib.quick_open(q, 50)));
    }
    for t in ["a", "x/a", "\u{e9}", "A#h"] {
        out.push_str(&format!("rename {t} {:?}\n", lib.rename_targets(t, "New")));
    }
    out
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(400) / 4 + 1))]

    /// Upsert, remove, rename and removing a whole root, with odd paths: the library equals one
    /// built from the notes that are left, and no answer panics.
    #[test]
    fn library_updates_with_odd_paths_equal_a_rebuild(ops in prop::collection::vec(lib_op(), 1..30), enc_i in 0usize..3) {
        let enc = ENCODINGS[enc_i];
        let mut lib = Library::new(enc);
        lib.add_root("r", "/r");
        lib.add_root("s", "/s");
        let mut model: BTreeMap<NoteRef, (String, i64)> = BTreeMap::new();
        for (step, op) in ops.into_iter().enumerate() {
            let t = step as i64;
            match op {
                LibOp::Upsert(p, s, text) => {
                    let n = NoteRef::new(root(s), &p);
                    lib.upsert(&n, &text, t).unwrap();
                    model.insert(n, (text, t));
                }
                LibOp::Remove(p, s) => {
                    let n = NoteRef::new(root(s), &p);
                    prop_assert_eq!(lib.remove(&n), model.remove(&n).is_some(), "remove {:?}", n);
                }
                LibOp::Rename(a, sa, b, sb) => {
                    let (from, to) = (NoteRef::new(root(sa), &a), NoteRef::new(root(sb), &b));
                    let had = model.contains_key(&from);
                    match lib.rename(&from, &to) {
                        Ok(()) => {
                            prop_assert!(had);
                            let v = model.remove(&from).unwrap();
                            model.insert(to, v);
                        }
                        Err(_) => prop_assert!(!had, "rename {from:?} -> {to:?} refused although it exists"),
                    }
                }
                LibOp::DropRoot(s) => {
                    // Removing a root takes its notes with it; the root comes back empty.
                    lib.remove_root(root(s));
                    lib.add_root(root(s), if s { "/s" } else { "/r" });
                    model.retain(|n, _| n.root != root(s));
                }
            }
            prop_assert_eq!(lib.len(), model.len());
        }
        let mut fresh = Library::new(enc);
        // Roots in the order the library has them (dropping a root and adding it again moves it last).
        for root in lib.roots() {
            fresh.add_root(&root.id, &root.path);
        }
        for (n, (t, m)) in model.iter().rev() {
            fresh.upsert(n, t, *m).unwrap();
        }
        prop_assert_eq!(lib_snapshot(&lib), lib_snapshot(&fresh));
    }
}

// ----- the library, in either Unicode form ---------------------------------------------------------------

const FORM_PATHS: [&str; 6] = [
    "Caf\u{e9}.md",
    "x/Ren\u{e9}e.md",
    "Plain.md",
    "\u{c5}ngstr\u{f6}m/Note.md",
    "y/z/T\u{e9}st.md",
    "Note.md",
];

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(300) / 3 + 1))]

    /// Run every path and every text through NFD and the library answers the same: the same links resolve to the
    /// same notes (in the other form), the same backlinks, tags and search hits.
    #[test]
    fn the_library_does_not_care_which_unicode_form_a_name_is_in(
        notes in prop::collection::vec((0usize..6, prop::collection::vec(prop::sample::select(vec![
            "[[Caf\u{e9}]] ", "[[Cafe\u{301}]] ", "[[x/Ren\u{e9}e]] ", "[[Rene\u{301}e]] ", "[[\u{c5}ngstr\u{f6}m/Note]] ", "[[T\u{e9}st#h]] ", "[[plain]] ",
            "#caf\u{e9} ", "#cafe\u{301} ", "# T\u{e9}st\n", "# Cafe\u{301}\n", "word ", "\n", "[[note]] ",
        ]), 0..8).prop_map(|v| v.concat())), 1..10),
    ) {
        use unicode_normalization::UnicodeNormalization;
        let nfd = |s: &str| s.nfd().collect::<String>();
        let mut a = Library::new(OffsetEncoding::Utf8);
        let mut b = Library::new(OffsetEncoding::Utf8);
        a.add_root("r", "/r");
        b.add_root("r", "/r");
        let mut model: BTreeMap<NoteRef, String> = BTreeMap::new();
        for (i, (p, text)) in notes.iter().enumerate() {
            let n = NoteRef::new("r", FORM_PATHS[*p]);
            a.upsert(&n, text, i as i64).unwrap();
            b.upsert(&NoteRef::new("r", &nfd(&n.path)), &nfd(text), i as i64).unwrap();
            model.insert(n, text.clone());
        }
        prop_assert_eq!(a.tags(), b.tags());
        for n in model.keys() {
            let nb = NoteRef::new("r", &nfd(&n.path));
            let links = |l: &Library, n: &NoteRef| l.note(n).unwrap().links.into_iter().map(|k| k.resolved.map(|r| nfd(&r.path))).collect::<Vec<_>>();
            prop_assert_eq!(links(&a, n), links(&b, &nb), "links of {:?}", n);
            let back = |l: &Library, n: &NoteRef| {
                let mut v = l.backlinks(n).into_iter().map(|k| nfd(&k.from.path)).collect::<Vec<_>>();
                v.sort();
                v
            };
            prop_assert_eq!(back(&a, n), back(&b, &nb), "backlinks of {:?}", n);
        }
        for q in ["caf\u{e9}", "cafe\u{301}", "t\u{e9}st", "word"] {
            // (Equal scores are ordered by path, and the two forms sort differently: compare the sets.)
            let hits = |l: &Library| {
                let mut v = l.search(q, 50).into_iter().map(|m| nfd(&m.note.path)).collect::<Vec<_>>();
                v.sort();
                v
            };
            prop_assert_eq!(hits(&a), hits(&b), "search {}", q);
        }
    }
}

// ----- unlinked mentions --------------------------------------------------------------------------------

const MENTION_NOTES: [&str; 5] = ["Alpha.md", "x/Beta Gamma.md", "y/Alpha.md", "Caf\u{e9}.md", "Other.md"];
const MENTION_ALIASES: [&str; 5] = ["aliases: [Ay, \"Beta\"]\n", "aliases:\n  - Gamma Ray\n", "alias: cafe\u{301}\n", "aliases: [al]\n", ""];

fn mention_text() -> impl Strategy<Value = String> {
    (
        0usize..5,
        prop::collection::vec(
            prop::sample::select(vec![
                "Alpha ", "alpha ", "ALPHA", "Alphabet ", "(alpha)", "Beta Gamma ", "beta gamma, ", "Beta ", "Gamma Ray ", "Ay ", "caf\u{e9} ", "Cafe\u{301} ", "caf\u{e9}s ", "Cafe\u{301}\u{301} ",
                "[Alpha](u) ", "[x][r] ", "![Alpha](i) ", "[[Alpha]] ", "[[Alpha|beta gamma]] ", "`alpha` ", "<b>alpha</b> ", "<i x=\"Alpha\">", "http://a.b/Alpha ", "<http://a.b/Alpha> ", "#alpha ",
                "\n", "\n\n", "\n```\nAlpha\n```\n", "\n    Alpha\n", "# Alpha\n", "> alpha ", "- alpha ", "| alpha | Beta Gamma |\n", "[r]: /u\n", "*alpha* ", "\\", "[", "]", "[[", "\u{1F389} ", "\u{3b1}\u{3c2} ",
            ]),
            0..14,
        )
        .prop_map(|v| v.concat()),
    )
        .prop_map(|(front, body)| if front < 4 { format!("---\n{}---\n{body}", MENTION_ALIASES[front]) } else { body })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(300)))]

    /// Every mention is a real, whole-word occurrence of a name of the mentioned note, outside what the parse calls a link,
    /// code, HTML, front matter or a tag; linking it (when the edit exists) turns it into a backlink and nothing else.
    #[test]
    fn mentions_are_real_occurrences_and_linking_them_makes_backlinks(
        texts in prop::collection::vec((0usize..5, any::<bool>(), mention_text()), 1..7),
        enc_i in 0usize..3,
    ) {
        use unicode_normalization::UnicodeNormalization;
        let enc = ENCODINGS[enc_i];
        let fold = |s: &str| s.nfc().collect::<String>().to_lowercase();
        let mut lib = Library::new(enc);
        lib.add_root("r", "/r");
        lib.add_root("s", "/s");
        let mut model: BTreeMap<NoteRef, String> = BTreeMap::new();
        for (i, (p, second, text)) in texts.iter().enumerate() {
            let n = NoteRef::new(root(*second), MENTION_NOTES[*p]);
            lib.upsert(&n, text, i as i64).unwrap();
            model.insert(n, text.clone());
        }
        for to in model.keys() {
            let meta = lib.note(to).unwrap();
            let mut names: Vec<String> = vec![meta.info.title.clone()];
            names.push(to.path.rsplit('/').next().unwrap().trim_end_matches(".md").to_owned());
            names.extend(meta.info.aliases.iter().cloned());
            let found = lib.mentions(to);
            let mut last: Option<(usize, usize, u32)> = None;
            for m in &found {
                prop_assert!(m.from != *to && m.to == *to);
                let text = &model[&m.from];
                let matched = slice_units(text, enc, m.range);
                prop_assert!(!matched.is_empty());
                prop_assert!(names.iter().any(|n| fold(n) == fold(&matched)), "{matched:?} is not a name of {to:?}: {names:?}");
                prop_assert!(names.iter().any(|n| *n == m.name && fold(n) == fold(&matched)), "name {:?}", m.name);
                // Whole word: the units around the range are not letters or marks.
                let before = slice_units(text, enc, TextRange::new(0, m.range.start));
                let after = slice_units(text, enc, TextRange::new(m.range.end, u32::MAX));
                let word = |c: char| c.is_alphanumeric() || ('\u{300}'..='\u{36f}').contains(&c);
                prop_assert!(!before.chars().next_back().is_some_and(word), "before {matched:?} in {text:?}");
                prop_assert!(!after.chars().next().is_some_and(word), "after {matched:?} in {text:?}");
                // Outside everything the parse reports as a link or code.
                let doc = Document::new(text, enc);
                for sp in doc.spans(None) {
                    if matches!(sp.kind, SpanKind::Link | SpanKind::LinkDestination | SpanKind::Image | SpanKind::Wikilink | SpanKind::InlineCode | SpanKind::CodeBlock | SpanKind::Html | SpanKind::FrontMatter | SpanKind::Tag) {
                        prop_assert!(m.range.end <= sp.range.start || sp.range.end <= m.range.start, "{matched:?} in {:?} {:?} of {text:?}", sp.kind, sp.range);
                    }
                }
                // Sorted, and not overlapping.
                if let Some((_, _, end)) = last.filter(|l| l.0 == root_rank(&m.from.root) && l.1 == path_id(&m.from)) {
                    prop_assert!(end <= m.range.start, "overlap in {text:?}");
                }
                last = Some((root_rank(&m.from.root), path_id(&m.from), m.range.end));
                // Linking: the mention becomes a backlink and the others stay.
                let Some(edit) = lib.link_mention_edit(m) else { continue };
                prop_assert_eq!((&edit.note, edit.range), (&m.from, m.range));
                let (s, e) = (units_to_byte(text, enc, edit.range.start), units_to_byte(text, enc, edit.range.end));
                let mut changed = text.clone();
                changed.replace_range(s..e, &edit.replacement);
                let mut after_lib = lib.clone();
                after_lib.upsert(&m.from, &changed, 99).unwrap();
                let count = |l: &Library| l.backlinks(to).iter().filter(|b| b.from == m.from).count();
                prop_assert_eq!(count(&after_lib), count(&lib) + 1, "{} in {:?}", edit.replacement, text);
                let left = |l: &Library| l.mentions(to).iter().filter(|x| x.from == m.from).count();
                // (Not exactly one fewer: the link can turn the text after it into a tag, `ALPHA#alpha`.)
                prop_assert!(left(&after_lib) < left(&lib), "{} in {:?}", edit.replacement, text);
            }
        }
    }
}

fn root_rank(root: &str) -> usize {
    usize::from(root == "s")
}

fn path_id(n: &NoteRef) -> usize {
    MENTION_NOTES.iter().position(|p| *p == n.path).unwrap()
}

/// The byte offset of a unit offset in `text`.
fn units_to_byte(text: &str, enc: OffsetEncoding, unit: u32) -> usize {
    let mut u = 0;
    for (i, c) in text.char_indices() {
        if u >= unit {
            return i;
        }
        u += match enc {
            OffsetEncoding::Utf8 => c.len_utf8() as u32,
            OffsetEncoding::Utf16 => c.len_utf16() as u32,
            OffsetEncoding::Utf32 => 1,
        };
    }
    text.len()
}

// ----- the history against a model, and damaged indexes ----------------------------------------------------

static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn temp_store() -> (History, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("md-fuzz-history-{}-{}", std::process::id(), COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)));
    let _ = std::fs::remove_dir_all(&dir);
    (History::open(&dir).unwrap(), dir)
}

#[derive(Debug, Clone)]
enum HOp {
    Record(u8, u8, Option<u8>),
    Prune(u8),
    Rekey(u8, u8),
    Forget(u8),
    Advance(u32),
    Reopen,
}

fn h_op() -> impl Strategy<Value = HOp> {
    prop_oneof![
        6 => (0u8..3, 0u8..6, prop::option::of(0u8..2)).prop_map(|(k, t, m)| HOp::Record(k, t, m)),
        2 => (0u8..3).prop_map(HOp::Prune),
        2 => (0u8..3, 0u8..3).prop_map(|(a, b)| HOp::Rekey(a, b)),
        1 => (0u8..3).prop_map(HOp::Forget),
        3 => prop_oneof![Just(60u32), Just(3600), Just(86_400), Just(8 * 86_400), Just(40 * 86_400)].prop_map(HOp::Advance),
        1 => Just(HOp::Reopen),
    ]
}

const HKEYS: [&str; 3] = ["notes/a.md", "\u{e9}/../b.md", "\u{1F389} c"];

fn h_text(t: u8) -> String {
    format!("version {t}\nline \u{e9}\r\n{}\n", "x".repeat(t as usize * 7))
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(300) / 3 + 1))]

    /// Record, prune, rekey, forget and reopen under a synthetic clock: every listed version
    /// reads back, ids are unique and newest first, versions with messages survive pruning,
    /// a rekey moves the whole history, and a record of the text just recorded is a no-op.
    #[test]
    fn history_sequences_keep_their_promises(ops in prop::collection::vec(h_op(), 1..40)) {
        let (mut h, dir) = temp_store();
        let mut now = 1_000_000i64;
        // key -> (text id -> text), only what was recorded.
        let mut texts: BTreeMap<usize, BTreeMap<u64, String>> = BTreeMap::new();
        let mut messages: BTreeMap<usize, Vec<u64>> = BTreeMap::new();
        let mut last: BTreeMap<usize, String> = BTreeMap::new();
        for op in ops {
            match op {
                HOp::Record(k, t, m) => {
                    let k = k as usize;
                    let text = h_text(t);
                    let msg = m.map(|m| format!("milestone {m}"));
                    let id = h.record_at(HKEYS[k], &text, Reason::Pause, msg.as_deref(), now);
                    if let Some(id) = id {
                        texts.entry(k).or_default().insert(id, text.clone());
                        if msg.is_some() {
                            messages.entry(k).or_default().push(id);
                        }
                        last.insert(k, text);
                    } else if let Some(known) = last.get(&k) {
                        prop_assert_eq!(known, &text, "a record was refused for a new text");
                    }
                }
                HOp::Prune(k) => {
                    h.prune_at(HKEYS[k as usize], now);
                }
                HOp::Rekey(a, b) => {
                    let (a, b) = (a as usize, b as usize);
                    let moved = h.rekey(HKEYS[a], HKEYS[b]);
                    if a != b && texts.contains_key(&a) {
                        prop_assert!(moved, "rekey {a} -> {b} refused");
                    }
                    if a != b && moved {
                        // The ids of a merged history are the store's to renumber: stop tracking both keys.
                        for k in [a, b] {
                            texts.remove(&k);
                            messages.remove(&k);
                            last.remove(&k);
                        }
                    }
                }
                HOp::Forget(k) => {
                    h.forget(HKEYS[k as usize]);
                    texts.remove(&(k as usize));
                    messages.remove(&(k as usize));
                    last.remove(&(k as usize));
                }
                HOp::Advance(s) => now += s as i64,
                HOp::Reopen => {
                    drop(h);
                    h = History::open(&dir).unwrap();
                }
            }
            for (k, key) in HKEYS.iter().enumerate() {
                let v = h.versions(key);
                let mut ids: Vec<u64> = v.iter().map(|x| x.id).collect();
                let n = ids.len();
                ids.sort();
                ids.dedup();
                prop_assert_eq!(ids.len(), n, "duplicate ids for key {}", k);
                prop_assert!(v.windows(2).all(|w| w[0].id > w[1].id), "not newest first for key {k}: {:?}", v.iter().map(|x| x.id).collect::<Vec<_>>());
                for x in &v {
                    let t = h.text(key, x.id);
                    prop_assert!(t.is_some(), "version {} of key {k} has no text", x.id);
                    if let Some(want) = texts.get(&k).and_then(|m| m.get(&x.id)) {
                        prop_assert_eq!(t.as_ref(), Some(want));
                    }
                }
                for id in messages.get(&k).into_iter().flatten() {
                    prop_assert!(v.iter().any(|x| x.id == *id), "a version with a message was pruned (key {k}, id {id})");
                }
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An index damaged in any way (truncated anywhere, bytes flipped, random bytes) never
    /// panics a query or a record, and the store goes on working.
    #[test]
    fn history_survives_a_damaged_index(cut in any::<u16>(), flips in prop::collection::vec((any::<u16>(), any::<u8>()), 0..4), garbage in prop::collection::vec(any::<u8>(), 0..64), mode in 0u8..3) {
        let (h, dir) = temp_store();
        h.record_at("k", "one\n", Reason::Pause, Some("m"), 10).unwrap();
        h.record_at("k", "two\n", Reason::Save, None, 20).unwrap();
        let key_dir = std::fs::read_dir(&dir).unwrap().next().unwrap().unwrap().path();
        let good = std::fs::read(key_dir.join("index.json")).unwrap();
        let bad: Vec<u8> = match mode {
            0 => good[..cut as usize % (good.len() + 1)].to_vec(),
            1 => {
                let mut b = good.clone();
                for (i, v) in flips {
                    let n = b.len();
                    b[i as usize % n] = v;
                }
                b
            }
            _ => garbage,
        };
        std::fs::write(key_dir.join("index.json"), &bad).unwrap();
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let v = h.versions("k");
            for x in &v {
                let _ = h.text("k", x.id);
                let _ = h.diff("k", x.id, "current\n");
            }
            h.prune_at("k", 100);
            h.record_at("k", "three\n", Reason::Pause, None, 30);
            let v = h.versions("k");
            let mut ids: Vec<u64> = v.iter().map(|x| x.id).collect();
            ids.sort();
            ids.dedup();
            (ids.len() == v.len(), h.versions("k").iter().any(|x| h.text("k", x.id).as_deref() == Some("three\n")))
        }));
        prop_assert!(r.is_ok(), "panicked on index {:?}", String::from_utf8_lossy(&bad));
        let (unique, has_three) = r.unwrap();
        prop_assert!(unique && has_three, "ids unique {unique}, the new version present {has_three}, index {:?}", String::from_utf8_lossy(&bad));
        let _ = std::fs::remove_dir_all(&dir);
    }
}

// ----- the annotation block ---------------------------------------------------------------------------------

fn file_text() -> impl Strategy<Value = String> {
    const T: &[&str] = &[
        "word ", "line\n", "\n", "\n\n", "\u{1F389}", "e\u{301}", "\u{65E5}\u{672C}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "---\n", "...\n", "Annotations: 0,1 SHA-256 00\n", "&AI: 0 1\n", "&: ", "\\", ":",
        "```\n", "\t", "  ", "# h\n", "\u{feff}", "x",
    ];
    prop::collection::vec(prop::sample::select(T), 0..14).prop_map(|v| v.concat())
}

fn convert(text: &str, ending: LineEnding) -> String {
    match ending {
        LineEnding::CrLf => text.replace('\n', "\r\n"),
        LineEnding::Cr => text.replace('\n', "\r"),
        _ => text.to_string(),
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases(1000)))]

    /// A written file reads back valid, `body + raw_tail` is the file byte for byte, the marks
    /// come back, and writing the unchanged document again gives the same bytes; for LF, CRLF and
    /// CR files, with a byte-order mark, with and without a final newline.
    #[test]
    fn the_annotation_block_round_trips_byte_for_byte(
        text in file_text(),
        marks in prop::collection::vec((any::<u16>(), any::<u16>(), 0u8..3), 1..5),
        ending_i in 0usize..3,
        bom in any::<bool>(),
        final_newline in any::<bool>(),
        enc_i in 0usize..3,
    ) {
        let enc = ENCODINGS[enc_i];
        let ending = [LineEnding::Lf, LineEnding::CrLf, LineEnding::Cr][ending_i];
        let mut text = text;
        if bom { text.insert(0, '\u{feff}'); }
        if final_newline && !text.ends_with('\n') { text.push('\n'); }
        if !final_newline { while text.ends_with('\n') { text.pop(); } }
        let who = [Author::new(AuthorKind::Ai, "Claude"), Author::new(AuthorKind::Reference, "Ref: a\\b"), Author::new(AuthorKind::Ai, "Odd: name")];
        let bounds = boundaries(&text, enc);
        let mut a = Authorship::new(enc);
        for (x, y, w) in &marks {
            let (p, q) = (bounds[*x as usize % bounds.len()], bounds[*y as usize % bounds.len()]);
            a.mark(TextRange::new(p.min(q), p.max(q)), Some(&who[*w as usize]));
        }
        let tail = a.file_tail(&text, ending);
        let file = format!("{}{}", convert(&text, ending), tail);
        let s = au::split_annotations(&file);
        if !a.has_marks() {
            prop_assert_eq!(tail.as_str(), "");
            return Ok(());
        }
        prop_assert_eq!(s.status, AnnotationStatus::Valid, "file {:?}", file);
        let raw = s.raw_tail.clone().unwrap();
        prop_assert_eq!(format!("{}{}", s.body, raw), file.clone());
        // The editor holds LF; the body on disk has the file's endings.
        let editor_body = match ending {
            LineEnding::CrLf => s.body.replace("\r\n", "\n"),
            LineEnding::Cr => s.body.replace('\r', "\n"),
            _ => s.body.clone(),
        };
        let mut b = Authorship::from_annotations(&editor_body, s.annotations.as_ref().unwrap(), enc, "Me");
        b.set_origin(&editor_body, &raw, ending);
        prop_assert_eq!(format!("{}{}", convert(&editor_body, ending), b.file_tail(&editor_body, ending)), file.clone(), "unchanged document must be written back as it was");
        // The same marks, by author and range.
        let runs = |x: &Authorship| -> Vec<(u32, u32, Author)> {
            let list = x.authors();
            x.runs(None).into_iter().map(|r| (r.range.start, r.range.end, list[r.author_index as usize].clone())).collect()
        };
        let (ra, rb) = (runs(&a), runs(&b));
        // Cluster edges: a mark inside a cluster comes back on the cluster's first scalar, so compare per grapheme.
        let per_grapheme = |v: &[(u32, u32, Author)]| -> Vec<(usize, Author)> {
            use unicode_segmentation::UnicodeSegmentation;
            let mut out = Vec::new();
            let mut unit = 0u32;
            for (gi, g) in editor_body.graphemes(true).enumerate() {
                let n = match enc { OffsetEncoding::Utf8 => g.len(), OffsetEncoding::Utf16 => g.encode_utf16().count(), OffsetEncoding::Utf32 => g.chars().count() } as u32;
                if let Some((_, _, w)) = v.iter().find(|(s, e, _)| *s <= unit && unit < *e) {
                    out.push((gi, w.clone()));
                }
                unit += n;
            }
            out
        };
        let _ = (ra.len(), rb.len());
        prop_assert_eq!(per_grapheme(&ra), per_grapheme(&rb), "marks changed in the round trip for {:?}", file);
        // Changing the document by one character rewrites the block: still valid after the round trip.
        let edited = format!("{editor_body}z");
        // (A mark inside one grapheme cluster has no cluster to name: the block then has no authors and reads back with no marks.)
        if b.has_marks() {
            let t2 = b.file_tail(&edited, ending);
            let f2 = format!("{}{}", convert(&edited, ending), t2);
            prop_assert_eq!(au::split_annotations(&f2).status, AnnotationStatus::Valid);
        }
    }
}
