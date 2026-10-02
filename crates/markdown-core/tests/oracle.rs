//! Oracle tests: the derived spans are checked against pulldown-cmark's raw event stream.
//!
//! * `Markup` spans contain only syntax characters (ASCII punctuation and blanks), never
//!   text that pulldown-cmark reports as a `Text` event.
//! * Text that reaches the rendered output as prose is never covered by a non-prose span,
//!   so prose ranges lose nothing.
//! * Every non-blank source byte is accounted for: it is text, or covered by a span that
//!   says what it is (so no syntax character is left unclassified and visible in Live mode).
//! * Every `Markup` span sits inside its owner; Line-scoped owners are exactly one line.
mod common;
use common::*;
use markdown_core::*;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

fn options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
}

/// Kinds whose source text is not prose (mirrors the core's definition).
fn non_prose(k: SpanKind) -> bool {
    !matches!(
        k,
        SpanKind::Heading { .. }
            | SpanKind::Emphasis
            | SpanKind::Strong
            | SpanKind::Strikethrough
            | SpanKind::Link
            | SpanKind::BlockQuote
            | SpanKind::Table
            | SpanKind::FootnoteDefinition
    )
}

/// Kinds that classify every byte they cover (as opposed to containers whose bytes are
/// classified by their children).
fn classifying(k: SpanKind) -> bool {
    non_prose(k) && !matches!(k, SpanKind::Image)
}

#[derive(Default, Debug, Clone)]
pub struct Report {
    pub markup_chars: Vec<String>,
    pub markup_over_text: Vec<String>,
    pub prose_text_lost: Vec<String>,
    pub uncovered: Vec<String>,
    pub owners: Vec<String>,
    pub prose_mismatch: Vec<String>,
}

impl Report {
    fn is_empty(&self) -> bool {
        self.markup_chars.is_empty()
            && self.markup_over_text.is_empty()
            && self.prose_text_lost.is_empty()
            && self.uncovered.is_empty()
            && self.owners.is_empty()
            && self.prose_mismatch.is_empty()
    }

    /// Everything except `uncovered` (see `known_pulldown_quirks`).
    fn is_empty_but_uncovered(&self) -> bool {
        Report { uncovered: Vec::new(), ..self.clone() }.is_empty()
    }
}

fn overlaps(a: (usize, usize), b: (usize, usize)) -> bool {
    a.0 < b.1 && b.0 < a.1
}

pub fn examine(text: &str) -> Report {
    let mut rep = Report::default();
    let doc = Document::new(text, OffsetEncoding::Utf8);
    let spans: Vec<(usize, usize, SpanKind)> =
        doc.spans(None).iter().map(|s| (s.range.start as usize, s.range.end as usize, s.kind)).collect();
    let b = text.as_bytes();

    // 1. Markup is syntax characters only.
    for &(s, e, k) in &spans {
        if k == SpanKind::Markup && !b[s..e].iter().all(|c| c.is_ascii_punctuation() || matches!(c, b' ' | b'\t')) {
            rep.markup_chars.push(format!("{s}..{e} {:?}", &text[s..e]));
        }
    }

    // Event walk.
    let mut covered = vec![false; b.len()];
    let mut prose_expected = vec![false; b.len()];
    // Justified exception: GFM drops table cells beyond the header's column count; they are
    // not rendered and get no span. Mark everything in a table row outside its cells as
    // covered here; the pipes are checked separately by the markup expectations.
    let mut row: Option<(usize, usize)> = None;
    let mut cells: Vec<(usize, usize)> = Vec::new();
    let (mut code, mut html, mut meta, mut image, mut autolink) = (0, 0, 0, 0, 0);
    // pulldown-cmark itself panics on a few inputs (see robustness.rs); the core then has
    // no structure for them and there is nothing to compare.
    let Ok(events) = std::panic::catch_unwind(|| Parser::new_ext(text, options()).into_offset_iter().collect::<Vec<_>>())
    else {
        return rep;
    };
    for (ev, r) in events {
        let r = (r.start, r.end);
        match &ev {
            Event::Start(Tag::TableHead | Tag::TableRow) => {
                row = Some(r);
                cells.clear();
            }
            Event::Start(Tag::TableCell) => cells.push(r),
            Event::End(TagEnd::TableHead | TagEnd::TableRow) => {
                if let (Some(row), Some(last)) = (row.take(), cells.last()) {
                    for c in &mut covered[last.1..row.1] {
                        *c = true;
                    }
                }
            }
            Event::Start(Tag::CodeBlock(_)) => code += 1,
            Event::End(TagEnd::CodeBlock) => code -= 1,
            Event::Start(Tag::HtmlBlock) => html += 1,
            Event::End(TagEnd::HtmlBlock) => html -= 1,
            Event::Start(Tag::MetadataBlock(_)) => meta += 1,
            Event::End(TagEnd::MetadataBlock(_)) => meta -= 1,
            Event::Start(Tag::Image { .. }) => image += 1,
            Event::End(TagEnd::Image) => image -= 1,
            Event::Start(Tag::Link {
                link_type: pulldown_cmark::LinkType::Autolink | pulldown_cmark::LinkType::Email, ..
            }) => autolink += 1,
            Event::End(TagEnd::Link) if autolink > 0 => {
                // Autolinks contain no nested links, so the innermost open link is the autolink.
                autolink -= 1
            }
            Event::Text(_) if code == 0 && html == 0 && meta == 0 => {
                for c in &mut covered[r.0..r.1] {
                    *c = true;
                }
                if image == 0 && autolink == 0 {
                    for c in &mut prose_expected[r.0..r.1] {
                        *c = true;
                    }
                }
                for &(s, e, k) in &spans {
                    if k == SpanKind::Markup && overlaps((s, e), r) {
                        rep.markup_over_text.push(format!("markup {s}..{e} {:?} over text {r:?} {:?}", &text[s..e], &text[r.0..r.1]));
                    } else if image == 0 && autolink == 0 && non_prose(k) && overlaps((s, e), r) {
                        rep.prose_text_lost.push(format!("{k:?} {s}..{e} {:?} over text {r:?} {:?}", &text[s..e], &text[r.0..r.1]));
                    }
                }
            }
            _ => {}
        }
        if matches!(
            ev,
            Event::Code(_) | Event::InlineHtml(_) | Event::Html(_) | Event::FootnoteReference(_) | Event::Rule | Event::TaskListMarker(_)
        ) || (matches!(ev, Event::Text(_)) && (code > 0 || html > 0 || meta > 0))
        {
            for c in &mut covered[r.0..r.1] {
                *c = true;
            }
        }
    }
    for &(s, e, k) in &spans {
        if classifying(k) {
            for c in &mut covered[s..e] {
                *c = true;
            }
        }
    }
    // Justified exception: the label of a link reference definition or footnote definition
    // (`[label]:`, `[^label]:`) is a name, neither text nor syntax, and has no span of its own.
    let markup: Vec<(usize, usize)> = spans.iter().filter(|s| s.2 == SpanKind::Markup).map(|s| (s.0, s.1)).collect();
    for w in markup.windows(2) {
        let (m1, m2) = (&text[w[0].0..w[0].1], &text[w[1].0..w[1].1]);
        if matches!(m1, "[" | "[^") && m2 == "]:" {
            for c in &mut covered[w[0].1..w[1].0] {
                *c = true;
            }
        }
    }
    let mut i = 0;
    while i < b.len() {
        if !covered[i] && !b[i].is_ascii_whitespace() {
            let s = i;
            while i < b.len() && !covered[i] && !b[i].is_ascii_whitespace() {
                i += 1;
            }
            rep.uncovered.push(format!("{s}..{i} {:?}", &text[s..i]));
        } else {
            i += 1;
        }
    }

    // Prose is exactly the text that is rendered as prose (not code, URLs, alt text, HTML).
    let mut prose_got = vec![false; b.len()];
    for p in doc.prose_ranges(None) {
        for c in &mut prose_got[p.start as usize..p.end as usize] {
            *c = true;
        }
    }
    if prose_got != prose_expected {
        let diff: Vec<usize> = (0..b.len()).filter(|&i| prose_got[i] != prose_expected[i]).collect();
        rep.prose_mismatch.push(format!("prose differs from rendered text at bytes {diff:?}"));
    }

    // Owners.
    for m in doc.markup_spans(None) {
        let (o, r) = (m.owner, m.range);
        if !(o.start <= r.start && r.end <= o.end) {
            rep.owners.push(format!("{m:?} outside owner"));
        }
        let owner_text = &text[o.start as usize..o.end as usize];
        match m.scope {
            MarkupScope::Line => {
                let ls = text[..o.start as usize].rfind(['\n', '\r']).map_or(0, |p| p + 1);
                let le = text[o.end as usize..].find(['\n', '\r']).map_or(text.len(), |p| p + o.end as usize);
                if owner_text.contains(['\n', '\r']) || ls != o.start as usize || le != o.end as usize {
                    rep.owners.push(format!("Line owner is not exactly one line: {m:?} {owner_text:?}"));
                }
            }
            MarkupScope::Inline => {
                // The owner must be an inline element span (or the escape it belongs to).
                let found = spans.iter().any(|&(s, e, k)| {
                    s == o.start as usize
                        && e == o.end as usize
                        && matches!(
                            k,
                            SpanKind::Emphasis
                                | SpanKind::Strong
                                | SpanKind::Strikethrough
                                | SpanKind::InlineCode
                                | SpanKind::Link
                                | SpanKind::Image
                                | SpanKind::FootnoteReference
                        )
                });
                let escape = o.end - o.start == 2 && text.as_bytes()[o.start as usize] == b'\\';
                if !found && !escape {
                    rep.owners.push(format!("Inline owner is not an inline element: {m:?} {owner_text:?}"));
                }
                // ... and the innermost such element containing the markup.
                let innermost = spans
                    .iter()
                    .filter(|&&(s, e, k)| {
                        s <= r.start as usize
                            && r.end as usize <= e
                            && matches!(
                                k,
                                SpanKind::Emphasis
                                    | SpanKind::Strong
                                    | SpanKind::Strikethrough
                                    | SpanKind::InlineCode
                                    | SpanKind::Link
                                    | SpanKind::Image
                                    | SpanKind::FootnoteReference
                            )
                    })
                    .min_by_key(|&&(s, e, _)| e - s);
                if found && innermost.is_some_and(|&(s, e, _)| (s, e) != (o.start as usize, o.end as usize)) {
                    rep.owners.push(format!("Inline owner is not the innermost element: {m:?} {owner_text:?}"));
                }
            }
            MarkupScope::Block => {}
        }
    }
    rep
}

fn spec_examples() -> Vec<(u64, String)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/commonmark-spec.json");
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    json.as_array()
        .unwrap()
        .iter()
        .map(|e| (e["example"].as_u64().unwrap(), e["markdown"].as_str().unwrap().to_owned()))
        .collect()
}

fn all_inputs() -> Vec<(String, String)> {
    let mut inputs: Vec<(String, String)> =
        spec_examples().into_iter().map(|(n, t)| (format!("spec example {n}"), t)).collect();
    inputs.extend(fixtures());
    inputs.extend(REGRESSIONS.iter().map(|t| (format!("regression {t:?}"), t.to_string())));
    inputs
}

/// Inputs on which earlier versions of the derivation failed the oracle.
const REGRESSIONS: &[&str] = &[
    // `#` without a space is text, so this is a setext heading, not an ATX one.
    "#foo\n===\n",
    "##***---\n===\n",
    // pulldown-cmark only accepts a closing `#` sequence after a space.
    "## (\t# ",
    "## a\t#",
    // A code span at the end of a heading with a trailing tab.
    "## text`\"t\"\t`\t",
    // Nested list item indented with a tab, or after `>` and a tab.
    "- a\n\t- b\n",
    "- [x] a\n\t- [x] b\n",
    ">\t- x\n",
    ">\t1. x\n",
    // Link reference definitions over several lines, in containers, and duplicates.
    "   [foo]: \n      /url  \n           'the title'  \n\n[foo]\n",
    "> [foo]:\n> /url\n> 'title'\n\n[foo]\n",
    "- a\n- b\n\n  [ref]: /url\n- d\n",
    "[a]: /u\n[a]: /v\n\n[a]\n",
    "1. [r]: /u\n1. [r]: /v\n",
    "[^1]: [r]: /u\n\n[r]\n",
    "[\nfoo\n]: /url\nbar\n",
    // A `>` on a lazy continuation line is text.
    "> a\n    >\n",
    ">1. ]***|---|---|\n|---|---|\n\t* > [^1]'~~~| a | b |\n=== ",
    ">[r]:```rs\n    [^1]: > *#",
    // A quote inside a footnote definition.
    "[^1]: > quoted\n\n[^1]\n",
    // Inline link destinations across lines: no markup may include a line break.
    "[a](\n/url\n)\n",
    "![](~~~:```rs\n)",
    // Collapsed reference followed by literal brackets, and nested in a reference image.
    "[a][][]\n\n[a]: /u\n",
    "[r]: /u\n![[r][]][r]: /u\n",
    // pulldown-cmark accepts `[^1]\[r]` and `[r]\[r]` as reference links.
    "[r]: /u\n`[t][r]**=== )[^1]\\[r]",
    "[r]: /u\n>~~~  \n|---|---|\n [r]\\[r]<http://a.b>1. \u{1F389}](\"t\"   <```",
    // Inline link destination continued on a quoted line.
    "> [a](\n> /url\n> )\n",
    "> [a](/url\n> \"title\")\n",
    "\n\n> [r]- [ ] * textx\\|y:<http://a.b># ***[^1]([r][]***[^1]x\\|y'\n> )[^1]: ",
    // A trailing tab after the last inline element of a heading.
    "# ***:`#[^1]: <b>*\t",
    "# *a*\t",
    // A setext heading whose range pulldown-cmark starts at a line terminator.
    "[r]: /u\n    \r\n<'===\n===\n[t][r]",
    // A metadata block in a list item without a closing delimiter.
    "* ---\n\t* <http://a.b>\n---\nword |---|---|\n",
    // Duplicate definition with its title on the next line.
    "[r]: /u\n(x[r]: /u\n## _\\* word\n[r]: /u\n\"t\"",
];

#[test]
fn spec_examples_fixtures_and_regressions_pass_the_oracle() {
    let mut failures = Vec::new();
    for (name, text) in all_inputs() {
        let r = examine(&text);
        if !r.is_empty() {
            failures.push(format!("{name}: {text:?}\n{r:#?}"));
        }
    }
    assert!(failures.is_empty(), "{} inputs fail the oracle:\n{}", failures.len(), failures.join("\n"));
}

/// Places where pulldown-cmark drops source text from its output altogether (no event at
/// all), so neither the preview nor the spans account for it. Pinned here so an upgrade
/// that changes them is noticed.
#[test]
fn known_pulldown_quirks() {
    let cases: &[(&str, &[&str])] = &[
        // A task marker directly before a table in a list item is not rendered.
        ("- [x] | a | b |\n    |---|---|\n", &["2..5 \"[x]\""]),
        // A tab-indented footnote definition right after a link reference definition.
        ("[r]: /u\n\t[^1]: [r][]", &["9..14 \"[^1]:\"", "15..20 \"[r][]\""]),
        // `\\|` in a table row renders as `|`; neither backslash appears in the output.
        ("x\n\n| a | b |\n|---|---|\n\\\\|---|---|\n", &["23..25 \"\\\\\\\\\""]),
    ];
    for (text, uncovered) in cases {
        let r = examine(text);
        assert!(r.is_empty_but_uncovered(), "{text:?}: {r:#?}");
        assert_eq!(r.uncovered, *uncovered, "{text:?}");
    }
}

const TOKENS: &[&str] = &[
    "# ", "## ", "> ", "- ", "* ", "1. ", "- [ ] ", "- [x] ", "```", "```rs\n", "~~~", "---\n", "***", "\n", "\n\n",
    "\r\n", "  \n", "*", "**", "_", "~~", "`", "[", "](", ")", "![", "]", "[^1]", "[^1]: ", "|", "| a | b |\n", "|---|---|\n",
    "<div>", "</div>", "<b>", "<http://a.b>", "\\", "\\*", "word ", "text", " ", "    ", "\t", "=== ", "===\n", "[r]: /u\n",
    "[r]", "[r][]", "[t][r]", "\u{1F389}", "e\u{301}", "&amp;", "#", ":", "\"t\"", "'", "(", "<", ">", "\\\n", "x\\|y",
];

fn lcg(seed: &mut u64) -> u64 {
    *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    *seed >> 33
}

fn random_doc(seed: &mut u64) -> String {
    let len = (lcg(seed) % 25) as usize;
    (0..len).map(|_| TOKENS[(lcg(seed) as usize) % TOKENS.len()]).collect()
}

/// Random token soup through the oracle. Unaccounted text (`uncovered`) is not asserted
/// here because pulldown-cmark itself drops text in rare shapes (see
/// `known_pulldown_quirks`); `explore_random` lists those.
/// `ORACLE_CASES=300000 cargo test --profile fuzz -p markdown-core --test oracle`
#[test]
fn random_documents_pass_the_oracle() {
    let n: usize = std::env::var("ORACLE_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(3000);
    let mut seed = 7u64;
    for _ in 0..n {
        let text = random_doc(&mut seed);
        let r = examine(&text);
        assert!(r.is_empty_but_uncovered(), "{text:?}\n{r:#?}");
    }
}

#[test]
#[ignore]
fn explore_random() {
    let n: usize = std::env::var("ORACLE_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(20000);
    let mut seed = 42u64;
    let mut seen = std::collections::HashMap::<String, usize>::new();
    for _ in 0..n {
        let text = random_doc(&mut seed);
        let Ok(r) = std::panic::catch_unwind(|| examine(&text)) else {
            println!("PANIC: {text:?}");
            continue;
        };
        for (cat, v) in [
            ("markup_chars", &r.markup_chars),
            ("markup_over_text", &r.markup_over_text),
            ("prose_text_lost", &r.prose_text_lost),
            ("uncovered", &r.uncovered),
            ("owners", &r.owners),
            ("prose_mismatch", &r.prose_mismatch),
        ] {
            if !v.is_empty() {
                let c = seen.entry(cat.to_string()).or_default();
                *c += 1;
                if *c <= 40 {
                    println!("{cat}: {text:?}\n   {v:?}");
                }
            }
        }
    }
    println!("{seen:?}");
}
