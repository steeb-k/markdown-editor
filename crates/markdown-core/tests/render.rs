//! HTML rendering: snapshots of every fixture, CommonMark conformance, the GFM extensions,
//! `data-line`, slugs, the sanitizer, fragments, highlighting and robustness.
mod common;
use common::*;
use markdown_core::*;

fn doc(text: &str) -> Document {
    Document::new(text, OffsetEncoding::Utf16)
}

fn plain() -> RenderOptions {
    RenderOptions { highlight: false, ..Default::default() }
}

fn lines() -> RenderOptions {
    RenderOptions { source_lines: true, ..Default::default() }
}

fn body(text: &str) -> String {
    doc(text).render_html(&RenderOptions::default())
}

fn sanitized(text: &str) -> String {
    doc(text).render_html(&RenderOptions { sanitize: true, ..Default::default() })
}

// ----- snapshots ------------------------------------------------------------------------------

fn snapshot_inputs() -> Vec<(String, String)> {
    let mut v = fixtures();
    let ui = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/macos/ui/fixtures/tour.md");
    v.push(("tour".to_owned(), std::fs::read_to_string(ui).unwrap()));
    v
}

#[test]
fn fixture_snapshots() {
    let inputs = snapshot_inputs();
    assert!(inputs.len() >= 5);
    for (name, text) in inputs {
        let d = doc(&text);
        insta::assert_snapshot!(format!("render_{name}"), d.render_html(&RenderOptions::default()));
        insta::assert_snapshot!(format!("render_{name}_lines"), d.render_html(&lines()));
    }
}

#[test]
fn authorship_fixtures_render_without_annotations() {
    // The core's text never holds the annotation block (the shell splits it off), but a file's
    // raw text, rendered by mistake, would show it: this pins what the split does.
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/authorship");
    let mut checked = 0;
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let raw = std::fs::read_to_string(&p).unwrap();
        let split = authorship::split_annotations(&raw);
        if split.annotations.is_some() {
            let html = doc(&split.body).render_html(&RenderOptions::default());
            assert!(!html.contains("Annotations:"), "{}", p.display());
            checked += 1;
        }
    }
    assert!(checked >= 3);
}

// ----- CommonMark ------------------------------------------------------------------------------

fn strip_heading_ids(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    while let Some(i) = rest.find("<h") {
        let after = &rest[i + 2..];
        out.push_str(&rest[..i + 2]);
        let b = after.as_bytes();
        if b.first().is_some_and(u8::is_ascii_digit) && after[1..].starts_with(" id=\"") {
            out.push(b[0] as char);
            let skip = after[6..].find('"').map_or(after.len(), |q| 6 + q + 1);
            rest = &after[skip..];
        } else {
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

fn pulldown_html(md: &str) -> String {
    use pulldown_cmark::Options as O;
    let o = O::ENABLE_TABLES | O::ENABLE_FOOTNOTES | O::ENABLE_STRIKETHROUGH | O::ENABLE_TASKLISTS | O::ENABLE_YAML_STYLE_METADATA_BLOCKS;
    let mut s = String::new();
    pulldown_cmark::html::push_html(&mut s, pulldown_cmark::Parser::new_ext(md, o));
    s
}

/// Every CommonMark 0.31.2 example, rendered with the options the editor parses with.
///
/// Our additions are normalised away (heading `id`s), and examples with a bare URL in them are set
/// aside (we link those, GFM does too; the spec does not). What remains must equal either the
/// spec's HTML or pulldown-cmark's own HTML for it: the renderer deviates from the spec only where
/// the parser itself does, and the examples that do are counted, not hidden. Deliberate deviations
/// from the spec's HTML, all of them additions: heading ids, bare URLs as links, and (not in the
/// spec's examples) footnotes, task checkboxes, front matter dropped.
#[test]
fn commonmark_spec_examples() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/commonmark-spec.json");
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let (mut total, mut equal_spec, mut parser_gap, mut skipped_urls) = (0, 0, 0, 0);
    let mut gaps = Vec::new();
    for e in json.as_array().unwrap() {
        let md = e["markdown"].as_str().unwrap();
        let spec = e["html"].as_str().unwrap();
        let n = e["example"].as_u64().unwrap();
        total += 1;
        let ours = doc(md).render_html(&plain());
        if !autolink::find(md).is_empty() {
            skipped_urls += 1;
            continue;
        }
        let ours = strip_heading_ids(&ours);
        if ours == spec {
            equal_spec += 1;
        } else if ours == pulldown_html(md) {
            parser_gap += 1;
            gaps.push(n);
        } else {
            panic!("example {n}: {md:?}\n  ours  {ours:?}\n  spec  {spec:?}\n  pulldown  {:?}", pulldown_html(md));
        }
    }
    println!("{total} examples: {equal_spec} equal the spec, {parser_gap} follow pulldown-cmark where it differs from the spec {gaps:?}, {skipped_urls} with bare URLs set aside");
    assert!(total > 600);
    assert!(skipped_urls <= 12, "{skipped_urls}");
    assert_eq!(equal_spec + parser_gap + skipped_urls, total);
    assert!(parser_gap <= 70, "pulldown-cmark deviates from the spec more than before ({parser_gap})");
}

// ----- GFM -------------------------------------------------------------------------------------

#[test]
fn tables_with_alignment() {
    let h = body("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n");
    assert_eq!(
        h,
        "<table><thead><tr><th style=\"text-align: left\">a</th><th style=\"text-align: center\">b</th><th style=\"text-align: right\">c</th></tr></thead><tbody>\n<tr><td style=\"text-align: left\">1</td><td style=\"text-align: center\">2</td><td style=\"text-align: right\">3</td></tr>\n</tbody></table>\n"
    );
}

#[test]
fn task_lists_render_disabled_checkboxes() {
    let h = body("- [ ] open\n- [x] done\n- plain\n");
    assert!(h.contains("<li class=\"task-list-item\"><input disabled=\"\" type=\"checkbox\" /> open</li>"), "{h}");
    assert!(h.contains("<li class=\"task-list-item\"><input disabled=\"\" type=\"checkbox\" checked=\"\" /> done</li>"), "{h}");
    assert!(h.contains("<li>plain</li>"), "{h}");
    // A loose item: the checkbox sits in the paragraph, not above it.
    let h = body("- [x] loose\n\n- other\n");
    assert!(h.contains("<p><input disabled=\"\" type=\"checkbox\" checked=\"\" /> loose</p>"), "{h}");
}

#[test]
fn strikethrough_and_front_matter() {
    assert_eq!(body("a ~~b~~ c\n"), "<p>a <del>b</del> c</p>\n");
    assert_eq!(body("---\ntitle: T\n---\n\n# H\n"), "<h1 id=\"h\">H</h1>\n");
    assert_eq!(body("---\ntitle: T\n---\n"), "");
}

#[test]
fn footnotes_are_collected_at_the_end_with_back_references() {
    let h = body("One[^b] and two[^a] and again[^b].\n\n[^a]: Alpha *note*.\n[^b]: Beta.\n\nAfter.\n");
    // Numbered by first reference; the definitions are not where they were written.
    assert!(h.contains("<sup class=\"footnote-ref\" id=\"fnref-b\"><a href=\"#fn-b\">1</a></sup>"), "{h}");
    assert!(h.contains("<sup class=\"footnote-ref\" id=\"fnref-a\"><a href=\"#fn-a\">2</a></sup>"), "{h}");
    assert!(h.contains("<sup class=\"footnote-ref\" id=\"fnref-b-2\"><a href=\"#fn-b\">1</a></sup>"), "{h}");
    let section = h.find("<section class=\"footnotes\">").expect("a footnotes section");
    assert!(h[..section].contains("<p>After.</p>"), "{h}");
    let tail = &h[section..];
    assert!(tail.find("id=\"fn-b\"").unwrap() < tail.find("id=\"fn-a\"").unwrap(), "{tail}");
    assert!(tail.contains("<li id=\"fn-b\">\n<p>Beta. <a href=\"#fnref-b\" class=\"footnote-backref\""), "{tail}");
    assert!(tail.contains("<a href=\"#fnref-b-2\" class=\"footnote-backref\" aria-label=\"Back to reference\">\u{21a9}<sup>2</sup></a>"), "{tail}");
    assert!(tail.contains("Alpha <em>note</em>."), "{tail}");
    assert!(!h[..section].contains("footnote-definition"), "{h}");
    // No footnotes, no section.
    assert!(!body("plain\n").contains("footnotes"));
}

#[test]
fn bare_urls_become_links_outside_code_links_and_html() {
    let h = body("See https://example.com/a_b, www.example.org. and (https://x.io/p).\n");
    assert!(h.contains("<a href=\"https://example.com/a_b\">https://example.com/a_b</a>,"), "{h}");
    assert!(h.contains("<a href=\"http://www.example.org\">www.example.org</a>."), "{h}");
    assert!(h.contains("(<a href=\"https://x.io/p\">https://x.io/p</a>)."), "{h}");
    let h = body("`https://a.b` [https://c.d](https://e.f) <span>https://g.h</span> <https://i.j>\n\n```\nhttps://k.l\n```\n");
    assert_eq!(h.matches("<a ").count(), 2, "{h}");
    assert!(h.contains("<code>https://a.b</code>") && h.contains("<a href=\"https://e.f\">https://c.d</a>"), "{h}");
    assert!(h.contains("<a href=\"https://i.j\">https://i.j</a>"), "{h}");
    // In emphasis, headings and table cells.
    let h = body("*www.a.com* and # x\n\n# https://h.io\n\n| a |\n|---|\n| https://t.io |\n");
    assert_eq!(h.matches("<a href").count(), 3, "{h}");
}

#[test]
fn bare_urls_agree_with_the_analysis() {
    let mut total = 0;
    // Wherever the analysis finds a bare URL (a Link span with no markup), the renderer links the same text.
    for (_, text) in snapshot_inputs() {
        let d = Document::new(&text, OffsetEncoding::Utf8);
        let html = d.render_html(&plain());
        let links: Vec<Span> = d.spans(None).into_iter().filter(|s| s.kind == SpanKind::Link).collect();
        let mut seen = 0;
        for l in autolink::find(&text) {
            // A bare URL is a Link span that is exactly the URL (no brackets around it).
            if links.iter().any(|s| s.range.start as usize == l.start && s.range.end as usize == l.end) {
                let probe = format!("<a href=\"{}\">", l.destination);
                assert!(html.contains(&probe), "{probe} missing");
                seen += 1;
            }
        }
        total += seen;
    }
    assert!(total >= 3, "the fixtures hold bare URLs ({total})");
}

#[test]
fn images_links_and_escaping() {
    assert_eq!(
        body("![alt *em*](<a b.png> \"T&C\") [l](<x y> \"t\") <me@a.b>\n"),
        "<p><img src=\"a%20b.png\" alt=\"alt em\" title=\"T&amp;C\" /> <a href=\"x%20y\" title=\"t\">l</a> <a href=\"mailto:me@a.b\">me@a.b</a></p>\n"
    );
    assert_eq!(body("a < b & c > d\n"), "<p>a &lt; b &amp; c &gt; d</p>\n");
}

// ----- slugs -----------------------------------------------------------------------------------

#[test]
fn slug_rules() {
    for (input, want) in [
        ("Hello, World!", "hello-world"),
        ("  Trim me  ", "trim-me"),
        ("a  b", "a--b"),
        ("Snake_case and kebab-case", "snake_case-and-kebab-case"),
        ("Caf\u{e9} \u{65E5}\u{672C}\u{8A9E}", "caf\u{e9}-\u{65E5}\u{672C}\u{8A9E}"),
        ("What's new? (v2.0)", "whats-new-v20"),
        ("\u{1F389} party", "-party"),
        ("100%", "100"),
        ("", ""),
        ("!!!", ""),
    ] {
        assert_eq!(slug(input), want, "{input:?}");
    }
}

#[test]
fn heading_ids_are_unique_and_stable() {
    let h = body("# Intro\n\n## Intro\n\n### Intro\n\n# Intro 1\n\n# !!!\n\n# !!!\n\n# *Em* `code` [link](x)\n");
    let ids: Vec<&str> = h.lines().filter_map(|l| l.split("id=\"").nth(1)).filter_map(|r| r.split('"').next()).collect();
    assert_eq!(ids, ["intro", "intro-1", "intro-2", "intro-1-1", "section", "section-1", "em-code-link"]);
    // The same text gives the same ids.
    assert_eq!(h, body("# Intro\n\n## Intro\n\n### Intro\n\n# Intro 1\n\n# !!!\n\n# !!!\n\n# *Em* `code` [link](x)\n"));
    // Setext headings and headings in containers get ids too.
    let h = body("Title\n=====\n\n> # Quoted\n\n- # Listed\n");
    assert!(h.contains("<h1 id=\"title\">") && h.contains("<h1 id=\"quoted\">") && h.contains("<h1 id=\"listed\">"), "{h}");
}

// ----- data-line -------------------------------------------------------------------------------

/// `(tag, line)` of every element that carries `data-line`, in document order.
fn data_lines(html: &str) -> Vec<(String, u32)> {
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(i) = rest.find(" data-line=\"") {
        let before = &rest[..i];
        let tag_start = before.rfind('<').unwrap();
        let tag: String = before[tag_start + 1..].chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
        let after = &rest[i + 12..];
        let n: u32 = after[..after.find('"').unwrap()].parse().unwrap();
        out.push((tag, n));
        rest = after;
    }
    out
}

fn check_data_lines(text: &str) -> Result<(), String> {
    let d = doc(text);
    let html = d.render_html(&lines());
    let got = data_lines(&html);
    let blocks = d.blocks();
    let sorted = |tags: &[&str]| -> Vec<u32> {
        let mut v: Vec<u32> = got.iter().filter(|(t, _)| tags.contains(&t.as_str())).map(|(_, n)| *n).collect();
        v.sort_unstable();
        v
    };
    let want = |kind: BlockKind| -> Vec<u32> {
        let mut v: Vec<u32> = blocks.iter().filter(|b| b.kind == kind).map(|b| b.line).collect();
        v.sort_unstable();
        v
    };
    for (kind, tags) in [
        (BlockKind::Heading, &["h1", "h2", "h3", "h4", "h5", "h6"][..]),
        (BlockKind::CodeBlock, &["pre"][..]),
        (BlockKind::Table, &["table"][..]),
        (BlockKind::ThematicBreak, &["hr"][..]),
    ] {
        let (g, w) = (sorted(tags), want(kind));
        if g != w {
            return Err(format!("{kind:?} lines: html {g:?}, blocks() {w:?}"));
        }
    }
    // A paragraph's element names the paragraph's line; a tight list item has no paragraph element
    // and its item carries the line (blocks() lists a paragraph for it).
    let paragraphs = want(BlockKind::Paragraph);
    let p_lines = sorted(&["p"]);
    for l in &p_lines {
        if !paragraphs.contains(l) {
            return Err(format!("<p data-line={l}> is not a paragraph's line {paragraphs:?}"));
        }
    }
    let covering = sorted(&["p", "li", "blockquote", "td", "th", "tr", "dd", "dt", "h1", "h2", "h3", "h4", "h5", "h6"]);
    for l in &paragraphs {
        if !covering.contains(l) && !text.contains("[^") {
            // Paragraphs of a table row, a footnote or an HTML block have no element of their own.
            let line_text = text.lines().nth(*l as usize).unwrap_or("");
            if !line_text.trim_start().starts_with('<') && !line_text.contains('|') {
                return Err(format!("paragraph at line {l} has no element with its line; html lines {covering:?}"));
            }
        }
    }
    // Every line is a real line of the document.
    let line_count = text.replace("\r\n", "\n").replace('\r', "\n").split('\n').count() as u32;
    if let Some((t, n)) = got.iter().find(|(_, n)| *n >= line_count) {
        return Err(format!("<{t} data-line={n}> beyond {line_count} lines"));
    }
    Ok(())
}

#[test]
fn data_line_matches_the_blocks() {
    for (name, text) in snapshot_inputs() {
        check_data_lines(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
    }
    let doc = "# A\n\npara one\nstill one\n\n> quote\n> more\n\n- item\n- item two\n\n  second para\n\n```rust\ncode\n```\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nSetext\n======\n\n    indented\n\n[^n]: note\n";
    check_data_lines(doc).unwrap();
    let got = data_lines(&Document::new(doc, OffsetEncoding::Utf16).render_html(&lines()));
    assert_eq!(got[0], ("h1".to_owned(), 0));
    assert!(got.contains(&("li".to_owned(), 8)) && got.contains(&("li".to_owned(), 9)), "{got:?}");
    assert!(got.contains(&("tr".to_owned(), 19)) && got.contains(&("tr".to_owned(), 21)), "{got:?}");
    assert!(got.contains(&("hr".to_owned(), 17)), "{got:?}");
    assert!(got.contains(&("blockquote".to_owned(), 5)), "{got:?}");
    // The clean output carries none.
    assert!(!body(doc).contains("data-line"));
}

#[test]
fn data_line_counts_every_kind_of_line_ending() {
    for sep in ["\n", "\r\n", "\r"] {
        let text = ["# H", "", "text", "", "- x", "- y", "", "> q"].join(sep);
        let got = data_lines(&doc(&text).render_html(&lines()));
        let lines: Vec<u32> = got.iter().map(|g| g.1).collect();
        // h1, p, ul and its first li, the second li, blockquote and its p.
        assert_eq!(lines, [0, 2, 4, 4, 5, 7, 7], "{sep:?}: {got:?}");
        check_data_lines(&text).unwrap();
    }
}

// ----- sanitizer -------------------------------------------------------------------------------

/// An element named `name` (an open or a close tag, any case) is in `html`, tokenised as a browser
/// would: comments are inert, a tag name runs to whitespace, `/` or `>`, a tag to its `>` outside quotes.
fn has_tag(html: &str, name: &str) -> bool {
    let b = html.as_bytes();
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
        let s = i + 1 + usize::from(b.get(i + 1) == Some(&b'/'));
        if s < b.len() && b[s].is_ascii_alphabetic() {
            let n = b[s..].iter().take_while(|c| !c.is_ascii_whitespace() && **c != b'/' && **c != b'>').count();
            if html[s..s + n].eq_ignore_ascii_case(name) {
                return true;
            }
            let mut q: Option<u8> = None;
            i = s + n;
            while i < b.len() {
                match (q, b[i]) {
                    (Some(c), x) if c == x => q = None,
                    (None, b'"' | b'\'') => q = Some(b[i]),
                    (None, b'>') => break,
                    _ => {}
                }
                i += 1;
            }
        }
        i += 1;
    }
    false
}

#[test]
fn raw_html_passes_through_unless_sanitized() {
    let md = "<script>alert(1)</script>\n\n<div onclick=\"x()\">hi</div>\n";
    let h = body(md);
    assert!(h.contains("<script>alert(1)</script>") && h.contains("onclick"), "{h}");
    let h = sanitized(md);
    assert!(!h.contains("script") && !h.contains("alert") && !h.contains("onclick"), "{h}");
    assert!(h.contains("<div>hi</div>"), "{h}");
}

#[test]
fn the_sanitizer_drops_what_can_run() {
    for (md, absent) in [
        ("<script>alert(1)</script>", "script"),
        ("<SCRIPT SRC=//evil></SCRIPT>", "evil"),
        ("<style>body{display:none}</style>\n\ntext", "display"),
        ("<iframe src=\"https://evil\"></iframe>", "evil"),
        ("<object data=\"x\"><param name=y></object>", "object"),
        ("<embed src=\"x.swf\">", "embed"),
        ("a <script>alert(1)</script> b", "alert"),
        ("a <span onclick=\"x()\">b</span>", "onclick"),
        ("a <img src=x onerror=alert(1)>", "onerror"),
        ("<a href=\"javascript:alert(1)\">x</a>", "javascript"),
        ("<a href=\"  JaVa\tScript:alert(1)\">x</a>", "alert"),
        ("<a href=\"&#106;avascript:alert(1)\">x</a>", "alert"),
        ("<a href=\"java&Tab;script&colon;alert(1)\">x</a>", "alert"),
        ("[x](javascript:alert(1))", "javascript"),
        ("![x](javascript:alert(1))", "javascript"),
        ("<a href=\"data:text/html,<script>alert(1)</script>\">x</a>", "alert"),
        ("<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>", "alert"),
        ("<div\nonmouseover=\"alert(1)\">x</div>", "alert"),
        ("<div title=\">\" onclick=x>t</div>", "onclick"),
        ("<link rel=stylesheet href=x.css><meta http-equiv=refresh content=0><base href=//e>", "stylesheet"),
    ] {
        let h = sanitized(md);
        assert!(!h.contains(absent), "{md:?} -> {h:?} still has {absent:?}");
        for name in ["script", "iframe", "style", "object", "embed"] {
            assert!(!has_tag(&h, name), "{md:?} -> {h:?}");
        }
    }
}

#[test]
fn the_sanitizer_keeps_what_is_safe() {
    let md = "<div class=\"a\" id=b>\n<p>text <b>bold</b> <a href=\"https://ok.example/x?y=1\" title=\"t\">link</a></p>\n<img src=\"pic.png\" alt=\"p\" />\n<img src=\"data:image/png;base64,AAAA\">\n</div>\n\n[ok](https://a.b) [rel](../x.md) [frag](#h) ![i](img/a.png) [mail](mailto:a@b.c)\n";
    let h = sanitized(md);
    // Kept tags are written anew, attributes quoted.
    for keep in ["<div class=\"a\" id=\"b\">","<b>bold</b>", "href=\"https://ok.example/x?y=1\" title=\"t\"", "<img src=\"pic.png\" alt=\"p\" />", "data:image/png;base64,AAAA", "href=\"https://a.b\"", "href=\"../x.md\"", "href=\"#h\"", "src=\"img/a.png\"", "href=\"mailto:a@b.c\""] {
        assert!(h.contains(keep), "{keep:?} missing from {h}");
    }
    // Text that merely mentions script elements is text.
    let h = sanitized("The `<script>` element and \\<script> too.\n");
    assert!(h.contains("<code>&lt;script&gt;</code>") && h.contains("&lt;script&gt; too"), "{h}");
}

#[test]
fn an_unclosed_blocked_element_does_not_swallow_later_blocks() {
    let h = sanitized("a <script>x\n\nnext paragraph\n\n- item\n");
    assert!(h.contains("next paragraph") && h.contains("<li>item</li>"), "{h}");
    let h = sanitized("<style>\np{}\n</style>\n\nafter\n");
    assert!(h.contains("after") && !h.contains("p{}"), "{h}");
}

/// What a browser's tokenizer reads from `html` (HTML content, scripting irrelevant): the start
/// and end tags with their attributes (names lower-cased, character references in values left
/// as written), and whether it met a comment, a doctype or a bogus comment. Written from the
/// WHATWG tokenizer states, independently of the sanitizer.
/// (is an end tag, name, attributes)
type BrowserTag = (bool, String, Vec<(String, String)>);

#[derive(Debug, Default)]
struct Tokens {
    tags: Vec<BrowserTag>,
    comments: usize,
}

fn browser_tokens(html: &str) -> Tokens {
    let c: Vec<char> = html.chars().collect();
    let mut t = Tokens::default();
    let mut i = 0;
    let space = |ch: char| matches!(ch, '\t' | '\n' | '\x0c' | '\r' | ' ');
    while i < c.len() {
        if c[i] != '<' {
            i += 1;
            continue;
        }
        let rest: String = c[i..c.len().min(i + 4)].iter().collect();
        if rest.starts_with("<!--") {
            t.comments += 1;
            let mut j = i + 4;
            // `<!-->` and `<!--->` end at once.
            if c.get(j) == Some(&'>') {
                i = j + 1;
                continue;
            }
            if c.get(j) == Some(&'-') && c.get(j + 1) == Some(&'>') {
                i = j + 2;
                continue;
            }
            loop {
                if j >= c.len() {
                    break;
                }
                let s: String = c[j..c.len().min(j + 4)].iter().collect();
                if s.starts_with("-->") {
                    j += 3;
                    break;
                }
                if s.starts_with("--!>") {
                    j += 4;
                    break;
                }
                j += 1;
            }
            i = j;
            continue;
        }
        match c.get(i + 1) {
            Some('!') | Some('?') => {
                t.comments += 1;
                i = c[i..].iter().position(|&x| x == '>').map_or(c.len(), |p| i + p + 1);
                continue;
            }
            Some('/') if c.get(i + 2).is_some_and(|x| !x.is_ascii_alphabetic()) => {
                if c.get(i + 2) != Some(&'>') {
                    t.comments += 1;
                }
                i = c[i..].iter().position(|&x| x == '>').map_or(c.len(), |p| i + p + 1);
                continue;
            }
            Some(x) if x.is_ascii_alphabetic() || *x == '/' => {}
            _ => {
                i += 1;
                continue;
            }
        }
        let end_tag = c[i + 1] == '/';
        let mut j = i + 1 + usize::from(end_tag);
        let mut name = String::new();
        while j < c.len() && !space(c[j]) && c[j] != '/' && c[j] != '>' {
            name.push(c[j].to_ascii_lowercase());
            j += 1;
        }
        let mut attrs: Vec<(String, String)> = Vec::new();
        let mut complete = false;
        while j < c.len() {
            while j < c.len() && (space(c[j]) || c[j] == '/') {
                j += 1;
            }
            if j >= c.len() {
                break;
            }
            if c[j] == '>' {
                complete = true;
                j += 1;
                break;
            }
            let mut an = String::from(c[j].to_ascii_lowercase());
            j += 1;
            while j < c.len() && !space(c[j]) && !matches!(c[j], '/' | '>' | '=') {
                an.push(c[j].to_ascii_lowercase());
                j += 1;
            }
            while j < c.len() && space(c[j]) {
                j += 1;
            }
            let mut av = String::new();
            if c.get(j) == Some(&'=') {
                j += 1;
                while j < c.len() && space(c[j]) {
                    j += 1;
                }
                match c.get(j) {
                    Some(&q) if q == '"' || q == '\'' => {
                        j += 1;
                        while j < c.len() && c[j] != q {
                            av.push(c[j]);
                            j += 1;
                        }
                        j += 1;
                    }
                    _ => {
                        while j < c.len() && !space(c[j]) && c[j] != '>' {
                            av.push(c[j]);
                            j += 1;
                        }
                    }
                }
            }
            if !attrs.iter().any(|(n, _)| *n == an) {
                attrs.push((an, av));
            }
        }
        if complete {
            t.tags.push((end_tag, name, attrs));
        }
        i = j.max(i + 1);
    }
    t
}

/// The elements sanitized output may hold: the sanitizer's allowlist and the renderer's own.
const SANITIZED_ELEMENTS: &[&str] = &[
    "a", "abbr", "b", "bdi", "bdo", "blockquote", "br", "caption", "center", "cite", "code", "col", "colgroup", "dd",
    "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
    "i", "img", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "rp", "rt", "ruby", "s", "samp", "small", "span",
    "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "time", "tr", "tt",
    "u", "ul", "var", "wbr", // the renderer's own:
    "input", "section",
];

/// Decodes character references the way a browser would before it reads a URL's scheme (all of
/// them, with or without `;`), then drops whitespace and controls and lower-cases.
fn browser_url(v: &str) -> String {
    let mut out = String::new();
    let mut it = v.chars().peekable();
    while let Some(ch) = it.next() {
        if ch == '&' {
            let mut r = String::new();
            while let Some(&n) = it.peek() {
                if n == ';' {
                    it.next();
                    break;
                }
                if !(n.is_ascii_alphanumeric() || n == '#') {
                    break;
                }
                r.push(n);
                it.next();
            }
            let d = if let Some(h) = r.strip_prefix("#x").or_else(|| r.strip_prefix("#X")) {
                u32::from_str_radix(h, 16).ok().and_then(char::from_u32)
            } else if let Some(d) = r.strip_prefix('#') {
                d.parse::<u32>().ok().and_then(char::from_u32)
            } else {
                match r.to_ascii_lowercase().as_str() {
                    "colon" => Some(':'),
                    "tab" | "newline" => Some(' '),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "amp" => Some('&'),
                    "quot" => Some('"'),
                    "apos" => Some('\''),
                    _ => None,
                }
            };
            match d {
                Some(d) => out.push(d),
                // Not a reference a browser knows: the text as written.
                None => {
                    out.push('&');
                    out.push_str(&r);
                }
            }
            continue;
        }
        out.push(ch);
    }
    out.chars().filter(|c| *c as u32 > 0x20 && *c != '\u{7f}').collect::<String>().to_ascii_lowercase()
}

/// Everything in sanitized output is on the allowlist, read as a browser reads it.
fn assert_clean(input: &str, html: &str) {
    let t = browser_tokens(html);
    assert_eq!(t.comments, 0, "{input:?} -> {html:?}: a comment or bogus comment survived");
    for (_, name, attrs) in &t.tags {
        assert!(SANITIZED_ELEMENTS.contains(&name.as_str()), "{input:?} -> {html:?}: <{name}>");
        for (a, v) in attrs {
            assert!(!a.starts_with("on"), "{input:?} -> {html:?}: {a}");
            assert!(!["srcset", "srcdoc", "formaction", "action", "xlink:href", "data", "background", "poster"].contains(&a.as_str()), "{input:?} -> {html:?}: {a}");
            if ["href", "src", "cite"].contains(&a.as_str()) {
                let u = browser_url(v);
                // The URL parser's scheme: a letter, then letters, digits, `+-.`, then `:`.
                let scheme = u
                    .split_once(':')
                    .filter(|(s, _)| s.starts_with(|c: char| c.is_ascii_alphabetic()) && s.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c)))
                    .map(|(s, _)| s.to_owned());
                let ok = match scheme.as_deref() {
                    None | Some("http" | "https" | "mailto" | "tel") => true,
                    Some("data") => a == "src" && ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"].iter().any(|t| u[5..].starts_with(t)),
                    _ => false,
                };
                assert!(ok, "{input:?} -> {html:?}: {a}={v:?}");
            }
            if a == "style" {
                let s = browser_url(v);
                assert!(!s.contains("url(") && !s.contains("expression") && !s.contains('\\') && !s.contains("@import"), "{input:?} -> {html:?}: style {v:?}");
            }
        }
    }
}

const BYPASSES: &[&str] = &[
    // Comments as a browser ends them.
    "<!--><img src=x onerror=alert(1)>-->",
    "<!---><img src=x onerror=alert(1)>-->",
    "<!-- a --!><img src=x onerror=alert(1)>",
    "a <!--><img src=x onerror=alert(1)>--> b",
    "<!-- unterminated <img src=x onerror=alert(1)>",
    "<![CDATA[><img src=x onerror=alert(1)>]]>",
    "<?xml x><img src=x onerror=alert(1)>",
    "</3 x><img src=x onerror=alert(1)>",
    // Case, entities, whitespace and controls in schemes.
    "<a href=\"JaVaScRiPt:alert(1)\">x</a>",
    "<a href=\" \njavascript:alert(1)\">x</a>",
    "<a href=\"java\tscript:alert(1)\">x</a>",
    "<a href=\"java\u{0}script:alert(1)\">x</a>",
    "<a href=\"\u{1}javascript:alert(1)\">x</a>",
    "<a href=\"&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1)\">x</a>",
    "<a href=\"&#0000106avascript:alert(1)\">x</a>",
    "<a href=\"&#x6A;avascript&#x3A;alert(1)\">x</a>",
    "<a href=\"javascript&colon;alert(1)\">x</a>",
    "<a href=\"jav&#x09;ascript:alert(1)\">x</a>",
    "<a href=javascript:alert(1)>x</a>",
    "<a href = 'javascript:alert(1)'>x</a>",
    "<a/href=\"javascript:alert(1)\">x</a>",
    "<a href=\"https://ok\" href=\"javascript:alert(1)\">first wins</a>",
    "<a href=\"javascript:alert(1)\" href=\"https://ok\">first wins</a>",
    "<a href=\"vbscript:msgbox(1)\">x</a>",
    "<a href=\"data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==\">x</a>",
    "<a href=\"file:///etc/passwd\">x</a>",
    "<a href=\"ms-msdt:/id PCWDiagnostic\">x</a>",
    "<a href=\"x-apple.systempreferences:com.apple.preference\">x</a>",
    // A scheme of any length is a scheme.
    "<a href=\"an-application-with-a-very-long-custom-scheme-name-indeed:run\">x</a> [y](an-application-with-a-very-long-custom-scheme-name-indeed:run)",
    "<a href=\"&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;&#x20;javascript:alert(1)\">x</a>",
    "[x](JaVaScRiPt:alert(1)) [y](vbscript:x) [z](data:text/html,x) ![i](data:image/svg+xml,<svg onload=alert(1)>)",
    "<javascript:alert(1)>",
    "[x](&#106;avascript:alert(1))",
    // SVG and MathML, and what foreign content does differently.
    "<svg onload=alert(1)>",
    "<svg><script>alert(1)</script></svg>",
    "<svg><a xlink:href=\"javascript:alert(1)\"><text>x</text></a></svg>",
    "<svg><style><img src=x onerror=alert(1)></style></svg>",
    "<math><mtext><table><mglyph><style><img src=x onerror=alert(1)>",
    "<math href=\"javascript:alert(1)\">x</math>",
    "<a xlink:href=\"javascript:alert(1)\">x</a>",
    // Styles that load or run.
    "<div style=\"background:url(javascript:alert(1))\">x</div>",
    "<div style=\"width: expression(alert(1))\">x</div>",
    "<div style=\"background: u\\rl(http://e)\">x</div>",
    "<div style=\"background:&#117;rl(http://e)\">x</div>",
    "<div style=\"behavior: url(x.htc)\">x</div>",
    "<div style=\"@import 'http://e'\">x</div>",
    "<div style=\"background-image: image-set('http://e' 1x)\">x</div>",
    "<p style=\"color: red\">kept</p>",
    // Pictures.
    "<img src=\"data:image/svg+xml,&lt;svg onload=alert(1)&gt;\">",
    "<img srcset=\"javascript:alert(1) 1x, x.png 2x\">",
    "<img src=x:alert(1) onerror=eval(src)>",
    "<img src=\"data:image/png;base64,AAAA\" alt=ok>",
    "<img src=\"data:image/pngx,AAAA\">",
    // Elements that load, run, submit or navigate.
    "<base href=\"javascript:/\">",
    "<form action=\"javascript:alert(1)\"><button formaction=javascript:alert(1)>x</button><input onfocus=alert(1) autofocus></form>",
    "<iframe src=\"javascript:alert(1)\"></iframe><frameset><frame src=x></frameset>",
    "<object data=\"x.swf\"></object><embed src=\"x.swf\"><applet code=x></applet>",
    "<meta http-equiv=\"refresh\" content=\"0;url=javascript:alert(1)\">",
    "<link rel=import href=x><link rel=stylesheet href=//e/x.css>",
    "<video poster=javascript:alert(1)><source src=x></video><audio src=x onerror=alert(1)>",
    "<details open ontoggle=alert(1)>x</details>",
    "<marquee onstart=alert(1)>x</marquee>",
    "<isindex action=javascript:alert(1) type=image>",
    "<table background=\"javascript:alert(1)\"><tr><td>x</td></tr></table>",
    // Raw text elements whose content a browser would not read as tags.
    "<textarea><script>alert(1)</script></textarea>",
    "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\"></noscript>",
    "<title><img src=x onerror=alert(1)></title>",
    "<xmp><img src=x onerror=alert(1)></xmp>",
    "<template><img src=x onerror=alert(1)></template>",
    "<plaintext><img src=x onerror=alert(1)>",
    "<noembed><img src=x onerror=alert(1)></noembed><noframes><img src=x onerror=alert(1)></noframes>",
    // Unclosed, unquoted, nested and mismatched tags.
    "<img src=x onerror=alert(1)//",
    "<a href=\"javascript:alert(1)",
    "<div title=\"x><img src=x onerror=alert(1)>",
    "<scr<script>ipt>alert(1)</script>",
    "<<script>alert(1)//<</script>",
    "<script/xss src=x></script>",
    "<script\u{c}>alert(1)</script>",
    "<SCRIPT>alert(1)</SCRIPT >",
    "<div <img src=x onerror=alert(1)>>",
    "<b x\"> <img src=x onerror=alert(1)> \"y>",
    "<div =onclick=alert(1)>x</div>",
    "<div \"onclick=alert(1)>x</div>",
    "<b><i>x</b></i></p></li></ul></blockquote>",
    "<div onclick\n=\nalert(1)>x</div>",
    "<a href=\"x\"onclick=alert(1)>x</a>",
    "<a href='x'onmouseover='alert(1)'>x</a>",
    // Raw HTML split across Markdown's events and blocks.
    "a <script>\nalert(1)\n</script> b",
    "<div>\n<script>\n\nalert(1)\n\n</script>\n</div>",
    "<a\nhref=\"javascript:alert(1)\">x</a>",
    "*<img src=x onerror=alert(1)>*",
    "[<img src=x onerror=alert(1)>](https://ok)",
    "| <img src=x onerror=alert(1)> | <a href=javascript:x>y</a> |\n|---|---|\n| <svg onload=alert(1)> | b |",
    "- <b>open\n- <script>alert(1)\n- after",
    "> <style>\n> body{}\n\nafter",
    "x[^n]\n\n[^n]: <img src=x onerror=alert(1)> <a href=\"javascript:alert(1)\">y</a>",
    "<span>never closed\n\n<div>also not",
];

#[test]
fn the_sanitizer_survives_the_classic_bypasses() {
    for md in BYPASSES {
        let h = sanitized(md);
        assert_clean(md, &h);
        // (Escaped text may still mention them; inside a tag they are gone.)
        for (_, _, attrs) in browser_tokens(&h).tags {
            assert!(attrs.iter().all(|(_, v)| !browser_url(v).contains("javascript:")), "{md:?} -> {h:?}");
        }
        // Fragments too (a selection of one block of it).
        let d = doc(md);
        let f = d.render_html_fragment(TextRange::new(0, 1), &RenderOptions { sanitize: true, ..Default::default() });
        assert_clean(md, &f);
    }
    // What is safe survives, normalised.
    assert!(sanitized("<p style=\"color: red\">kept</p>").contains("<p style=\"color: red\">kept</p>"));
    assert!(sanitized("<a href=\"https://ok\" href=\"javascript:alert(1)\">first wins</a>").contains("href=\"https://ok\""));
    assert!(sanitized("<img src=\"data:image/png;base64,AAAA\" alt=ok>").contains("<img src=\"data:image/png;base64,AAAA\" alt=\"ok\" />"));
    assert!(sanitized("<details open ontoggle=alert(1)>x</details>").contains("<details open=\"\">x</details>"));
    // Text never becomes a tag: a `<` the filter cannot read to its end is text.
    assert!(sanitized("<img src=x onerror=alert(1)//").contains("&lt;img"), "{}", sanitized("<img src=x onerror=alert(1)//"));
    // Inline HTML left open in a paragraph is closed with it; an HTML block's at the end.
    assert_eq!(sanitized("<span>never closed\n\nnext\n"), "<p><span>never closed</span></p>\n<p>next</p>\n");
    assert_eq!(sanitized("<div>\n\n*md*\n\n</div>\n"), "<div>\n<p><em>md</em></p>\n</div>\n");
    assert_eq!(sanitized("<div>\n\nnever closed\n"), "<div>\n<p>never closed</p>\n</div>");
    // A stray end tag cannot close the renderer's elements.
    assert_eq!(sanitized("- a </li></ul> b\n"), "<ul>\n<li>a  b</li>\n</ul>\n");
}

#[test]
fn sanitized_output_is_clean_on_random_soup() {
    let tokens = [
        "<script>", "</script>", "<style>", "<svg>", "</svg>", "<math>", "onclick=\"", "javascript:", "java&#x09;script:", "<a href=", "<img src=",
        ">", "\"", "'", "<", "[x](", ")", "![", "\n", "\n\n", " ", "<iframe", "<!--", "-->", "--!>", "<!-->", "<![CDATA[", "]]>", "<?", "</", "/",
        "=", "style=\"", "url(", "<div>", "</div>", "<b>", "</b>", "<textarea>", "<noscript>", "&#106;", "&colon;", "x", "- ", "> ", "| a |\n|---|\n",
        "<form action=", "<base href=", "data:text/html,", "srcset=", "xlink:href=", "\t", "\u{c}", "[^1]", "[^1]: ",
    ];
    let mut seed = 5u64;
    let n: usize = std::env::var("RENDER_FUZZ_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(3000);
    for _ in 0..n {
        let len = (lcg(&mut seed) % 40) as usize;
        let md: String = (0..len).map(|_| tokens[(lcg(&mut seed) as usize) % tokens.len()]).collect();
        let h = sanitized(&md);
        assert_clean(&md, &h);
    }
}

/// Element names in `html` balance: every end tag closes the innermost open element (void
/// elements and `<input>` aside). Returns the first problem.
fn balanced(html: &str) -> Result<(), String> {
    const VOID: &[&str] = &["br", "hr", "img", "input", "wbr", "col", "meta"];
    let mut stack: Vec<String> = Vec::new();
    for (end, name, _) in browser_tokens(html).tags {
        if VOID.contains(&name.as_str()) {
            continue;
        }
        if end {
            match stack.pop() {
                Some(open) if open == name => {}
                other => return Err(format!("</{name}> closes {other:?}")),
            }
        } else {
            stack.push(name);
        }
    }
    if stack.is_empty() { Ok(()) } else { Err(format!("left open: {stack:?}")) }
}

#[test]
fn fragments_and_sanitized_output_are_well_formed() {
    let text = "# Title\n\n- one *a*\n- two `b`\n  - nested **c**\n\n| h1 | h2 |\n|:--|--:|\n| cell **x** | y[^n] |\n\n> quote\n> - in a list\n\n1. first\n2. second\n\n```rust\nfn f() {}\n```\n\n[^n]: The *note*.\n\n    indented\n\nlast para\n";
    let d = doc(text);
    let o = RenderOptions { source_lines: true, ..Default::default() };
    let at = |s: &str| text.find(s).unwrap() as u32;
    for (from, to) in [
        (at("one") + 1, at("one") + 2),        // inside a list item
        (at("nested") + 2, at("nested") + 3), // a nested item
        (at("cell") + 1, at("cell") + 2),     // a table cell
        (at("The *note*") + 1, at("The *note*") + 3), // a footnote
        (at("quote"), at("in a list") + 2),   // across blocks in a quote
        (at("Title"), at("last")),            // across everything
        (at("fn f"), at("fn f") + 1),         // a code block
        (at("indented"), at("indented") + 3),
    ] {
        let h = d.render_html_fragment(TextRange::new(from, to), &o);
        balanced(&h).unwrap_or_else(|e| panic!("{from}..{to}: {e}\n{h}"));
        assert!(!h.is_empty());
    }
    // Every selection of the corpora, sanitized: well formed whatever raw HTML the text holds.
    let mut seed = 3u64;
    for (name, t) in snapshot_inputs() {
        let d = Document::new(&t, OffsetEncoding::Utf8);
        let b = boundaries(&t, OffsetEncoding::Utf8);
        for _ in 0..60 {
            let (x, y) = (b[lcg(&mut seed) as usize % b.len()], b[lcg(&mut seed) as usize % b.len()]);
            let h = d.render_html_fragment(TextRange::new(x.min(y), x.max(y)), &RenderOptions { sanitize: true, ..Default::default() });
            balanced(&h).unwrap_or_else(|e| panic!("{name} {x}..{y}: {e}\n{h}"));
        }
    }
    let tokens = ["<div>", "</div>", "<b>", "</b>", "<span>", "</i>", "<p>", "</p>", "- ", "> ", "\n", "\n\n", "x", "*", "| a |\n|---|\n", "<table>", "</td>", "[^1]", "[^1]: "];
    for _ in 0..2000 {
        let len = (lcg(&mut seed) % 30) as usize;
        let md: String = (0..len).map(|_| tokens[(lcg(&mut seed) as usize) % tokens.len()]).collect();
        let h = sanitized(&md);
        balanced(&h).unwrap_or_else(|e| panic!("{md:?}: {e}\n{h}"));
    }
}

#[test]
fn data_line_is_on_every_kind_of_block_in_every_container() {
    let text = "# H\n\n> ## Quoted heading\n>\n> para in quote\n>\n> - item in quote\n>\n> ```\n> code in quote\n> ```\n>\n> ---\n\n- item\n\n  para in item\n\n  > quote in item\n\n  ```\n  code in item\n  ```\n\n  1. ordered in item\n\n  | a |\n  |---|\n  | t |\n\n- [ ] task\n\n<div>\nhtml block\n</div>\n\nend[^n]\n\n[^n]: note\n\n    > not a quote\n";
    let html = doc(text).render_html(&lines());
    let got = data_lines(&html);
    let line_of = |s: &str| text[..text.find(s).unwrap()].matches('\n').count() as u32;
    for (tag, needle) in [
        ("h1", "# H"), ("blockquote", "> ## Quoted"), ("h2", "## Quoted"), ("p", "para in quote"), ("ul", "- item in quote"),
        ("li", "- item in quote"), ("pre", "```\n> code in quote"), ("hr", "> ---"), ("ul", "- item\n"), ("li", "- item\n"),
        ("p", "para in item"), ("blockquote", "> quote in item"), ("pre", "```\n  code in item"), ("ol", "1. ordered"),
        ("li", "1. ordered"), ("table", "| a |"), ("tr", "| a |"), ("tr", "| t |"), ("li", "- [ ] task"), ("p", "end[^n]"),
        // (Indented under a note, it is the note's quote.)
        ("li", "[^n]: note"), ("blockquote", "    > not"),
    ] {
        let want = (tag.to_owned(), line_of(needle));
        assert!(got.contains(&want), "{tag} at line {} ({needle:?}) missing from {got:?}", want.1);
    }
    // Lines never go backwards outside the notes section.
    let main_part = &html[..html.find("<section").unwrap()];
    let ls: Vec<u32> = data_lines(main_part).into_iter().map(|(_, n)| n).collect();
    assert!(ls.windows(2).all(|w| w[0] <= w[1]), "{ls:?}");
}

#[test]
fn footnotes_in_fragments_keep_the_documents_numbers_and_every_link_lands() {
    let text = "Intro[^a].\n\n# fn-b\n\nMiddle[^b] and[^a] again.\n\n## fnref-a\n\nEnd[^c].\n\n[^a]: Alpha, see[^c].\n[^b]: Beta.\n[^c]: Gamma.\n[^d]: Nobody refers to me.\n";
    let d = doc(text);
    let whole = d.render_html(&RenderOptions::default());
    // Ids are unique and every in-page link has a target.
    let ids: Vec<String> = whole.split(" id=\"").skip(1).map(|s| s[..s.find('"').unwrap()].to_owned()).collect();
    let unique: std::collections::HashSet<&String> = ids.iter().collect();
    assert_eq!(unique.len(), ids.len(), "duplicate ids: {ids:?}");
    for href in whole.split("href=\"#").skip(1).map(|s| &s[..s.find('"').unwrap()]) {
        assert!(ids.iter().any(|i| i == href), "#{href} has no target in {whole}");
    }
    // The headings named like notes did not take the notes' ids.
    assert!(whole.contains("<h1 id=\"fn-b-1\">") && whole.contains("<h2 id=\"fnref-a-1\">"), "{whole}");
    // Numbers by first reference: a 1, b 2, c 3 (first met in a's note? no: "End[^c]" comes first in the text), d 4.
    assert!(whole.contains("<a href=\"#fn-c\">3</a>"), "{whole}");
    // A note nobody refers to has no back-link.
    let d_item = &whole[whole.find("<li id=\"fn-d\"").unwrap()..];
    assert!(!d_item[..d_item.find("</li>").unwrap()].contains("footnote-backref"), "{d_item}");
    // A fragment: the second paragraph only. Its references keep their numbers and ids; its section
    // lists b and a (and c, which a's note refers to), numbered as in the document, with back-links
    // only to the references the fragment holds.
    let at = text.find("Middle").unwrap() as u32;
    let f = d.render_html_fragment(TextRange::new(at, at + 3), &RenderOptions::default());
    assert!(f.contains("<sup class=\"footnote-ref\" id=\"fnref-b\"><a href=\"#fn-b\">2</a></sup>"), "{f}");
    assert!(f.contains("<sup class=\"footnote-ref\" id=\"fnref-a-2\"><a href=\"#fn-a\">1</a></sup>"), "{f}");
    let pos = |s: &str| f.find(s).unwrap_or_else(|| panic!("{s} in {f}"));
    assert!(pos("<li id=\"fn-a\">") < pos("<li id=\"fn-b\">") && pos("<li id=\"fn-b\"") < pos("<li id=\"fn-c\">"), "{f}");
    assert!(f.contains("href=\"#fnref-a-2\"") && !f.contains("href=\"#fnref-a\"") && !f.contains("fn-d"), "{f}");
    // A fragment whose only note is the third: the list says 3, not 1.
    let at = text.find("End").unwrap() as u32;
    let f3 = d.render_html_fragment(TextRange::new(at, at + 2), &RenderOptions::default());
    assert!(f3.contains("<li id=\"fn-c\" value=\"3\">") && f3.contains("<a href=\"#fn-c\">3</a>"), "{f3}");
    let ids: Vec<&str> = f.split(" id=\"").skip(1).map(|s| &s[..s.find('"').unwrap()]).collect();
    for href in f.split("href=\"#").skip(1).map(|s| &s[..s.find('"').unwrap()]) {
        // Links to notes and back to references inside the fragment all land.
        if href.starts_with("fn") {
            assert!(ids.contains(&href) || href == "fnref-c", "#{href} has no target in {f}");
        }
    }
}

#[test]
fn highlighting_is_bounded_per_render_and_deterministic() {
    // Thousands of distinct blocks: the first ones are highlighted, the rest plain and marked.
    let mut text = String::new();
    for i in 0..3000 {
        text.push_str(&format!("```rust\nfn f{i}() {{ let x = {i}; }}\n```\n\n"));
    }
    highlight::clear_cache();
    let d = doc(&text);
    let count = |h: &str| (h.matches("<pre><code class=\"language-rust\"><span").count(), h.matches("<pre data-highlight=\"skipped\">").count());
    let cold = d.render_html(&RenderOptions::default());
    // The time cap may stop a cold render early (in a debug build it does); cached blocks cost no
    // time, so renders highlight further until only the byte budget stops them: then the output
    // is the same every time.
    let mut last = cold.clone();
    let mut stable = None;
    for _ in 0..50 {
        let next = d.render_html(&RenderOptions::default());
        if next == last {
            stable = Some(next);
            break;
        }
        assert!(count(&next).0 >= count(&last).0, "highlighting only grows");
        last = next;
    }
    let a = stable.expect("renders converge once the cache holds what the byte budget allows");
    let (highlighted, skipped) = count(&a);
    assert!(highlighted > 100 && skipped > 100 && highlighted + skipped == 3000, "{highlighted} highlighted, {skipped} skipped");
    assert!(count(&cold).0 <= highlighted && count(&cold).0 + count(&cold).1 == 3000);
    // In document order: everything highlighted comes before everything skipped.
    assert!(a.rfind("<span class=\"s-").unwrap() < a.find("data-highlight").unwrap());
    // A giant line or a giant block is shown plain, quickly, whatever the language.
    for code in ["x".repeat(50_000), format!("let a = \"{}\";", "\\\"".repeat(20_000)), "(".repeat(30_000)] {
        let t = std::time::Instant::now();
        let h = doc(&format!("```rust\n{code}\n```\n")).render_html(&RenderOptions::default());
        assert!(!h.contains("<span"), "plain");
        assert!(t.elapsed().as_millis() < 500, "{:?}", t.elapsed());
    }
    // The cache stays bounded however many distinct blocks pass through it.
    highlight::clear_cache();
    for round in 0..40 {
        let mut t = String::new();
        for i in 0..400 {
            t.push_str(&format!("```js\nvar v{round}_{i} = {i};\n```\n\n"));
        }
        doc(&t).render_html(&RenderOptions::default());
        assert!(highlight::cache_bytes() <= 8 << 20);
    }
}

#[test]
fn the_page_carries_a_content_security_policy_and_a_tidy_font_stack() {
    let p = doc("x\n").render_html(&RenderOptions { standalone: true, ..Default::default() });
    let head = &p[..p.find("</head>").unwrap()];
    let csp = head.find("Content-Security-Policy").expect("a policy");
    assert!(csp < head.find("<style>").unwrap(), "before anything else loads");
    for directive in ["default-src 'none'", "frame-src 'none'", "form-action 'none'", "base-uri 'none'", "font-src 'self'"] {
        assert!(head.contains(directive), "{directive}");
    }
    assert!(!head.contains("script-src"), "no script source at all (default-src 'none')");
    // A font name cannot end the stylesheet or the declaration.
    let typo = Typography { font_family: "\"Evil</style><script>x()</script>\"; } body { display:none }".into(), ..Typography::default() };
    let css = preview_css(&theme_by_id("light").unwrap(), &typo);
    assert!(!css.contains("</style>") && !css.contains("display:none }"), "{}", &css[..400]);
    assert!(braces_balance(&css));
}

// ----- fragments -------------------------------------------------------------------------------

#[test]
fn fragments_expand_to_whole_blocks() {
    let text = "# Title\n\nFirst paragraph.\n\nSecond paragraph with [^n].\n\n- a\n- b\n\n[^n]: A note.\n";
    let d = doc(text);
    let o = RenderOptions::default();
    let whole = d.render_html(&o);
    assert_eq!(d.render_html_fragment(TextRange::new(3, 3), &o), whole, "an empty range is the whole document");
    // A few words of the first paragraph: that paragraph, whole.
    let at = text.find("paragraph.").unwrap() as u32;
    assert_eq!(d.render_html_fragment(TextRange::new(at, at + 4), &o), "<p>First paragraph.</p>\n");
    // Across two blocks: both.
    let a = text.find("First").unwrap() as u32;
    let b = text.find("Second").unwrap() as u32 + 3;
    assert_eq!(d.render_html_fragment(TextRange::new(a, b), &o), "<p>First paragraph.</p>\n<p>Second paragraph with <sup class=\"footnote-ref\" id=\"fnref-n\"><a href=\"#fn-n\">1</a></sup>.</p>\n<section class=\"footnotes\">\n<ol>\n<li id=\"fn-n\">\n<p>A note. <a href=\"#fnref-n\" class=\"footnote-backref\" aria-label=\"Back to reference\">\u{21a9}</a></p>\n</li>\n</ol>\n</section>\n");
    // A word in a list item: the list.
    let li = text.find("- b").unwrap() as u32 + 2;
    assert_eq!(d.render_html_fragment(TextRange::new(li, li + 1), &o), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n");
    // The heading keeps the id it has in the whole document.
    assert_eq!(d.render_html_fragment(TextRange::new(2, 4), &o), "<h1 id=\"title\">Title</h1>\n");
    // A selection of only blank space touches no block.
    assert_eq!(d.render_html_fragment(TextRange::new(8, 9), &o), "");
    // Selecting a footnote definition renders it, referenced or not.
    let n = text.find("[^n]:").unwrap() as u32;
    let h = d.render_html_fragment(TextRange::new(n + 6, n + 8), &o);
    assert!(h.contains("<li id=\"fn-n\">") && h.contains("A note."), "{h}");
}

#[test]
fn fragments_use_the_documents_link_references_and_line_numbers() {
    let text = "para [ref] here\n\n[ref]: https://example.com \"T\"\n";
    let d = doc(text);
    let h = d.render_html_fragment(TextRange::new(1, 2), &lines());
    assert_eq!(h, "<p data-line=\"0\">para <a href=\"https://example.com\" title=\"T\">ref</a> here</p>\n");
}

#[test]
fn fragments_count_offsets_in_the_documents_encoding() {
    let text = "\u{1F389} one\n\ntwo \u{1F389}\n\nthree\n";
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let d = Document::new(text, enc);
        let units = |s: &str| -> u32 {
            s.chars().map(|c| match enc { OffsetEncoding::Utf8 => c.len_utf8(), OffsetEncoding::Utf16 => c.len_utf16(), OffsetEncoding::Utf32 => 1 }).sum::<usize>() as u32
        };
        let start = units("\u{1F389} one\n\ntwo ");
        let h = d.render_html_fragment(TextRange::new(start, start + units("\u{1F389}")), &RenderOptions::default());
        assert_eq!(h, "<p>two \u{1F389}</p>\n", "{enc:?}");
    }
}

// ----- highlighting ------------------------------------------------------------------------------

#[test]
fn known_languages_are_highlighted_and_unknown_are_not() {
    let h = body("```rust\nfn main() {\n    let x = \"hi\"; // c\n}\n```\n");
    assert!(h.starts_with("<pre><code class=\"language-rust\">"), "{h}");
    assert!(h.contains("<span class=\"s-storage s-type s-function\">fn</span>"), "{h}");
    assert!(h.contains("s-string") && h.contains("s-comment") && h.contains("s-entity s-name s-function"), "{h}");
    // Scopes with no colour of their own add no spans.
    assert!(!h.contains("s-meta") && !h.contains("s-source") && !h.contains("s-punctuation"), "{h}");
    for (lang, code) in [
        ("python", "def f():\n    return 'x'"),
        ("py", "import os # c"),
        ("js", "const a = 1;"),
        ("json", "{\"a\": 1}"),
        ("html", "<a href=\"x\">y</a>"),
        ("yaml", "a: \"b\""),
        ("sh", "echo \"x\" # c"),
        ("bash", "if true; then echo; fi"),
        ("c", "int main() { return 0; }"),
        ("cpp", "class A {};"),
        ("go", "func main() {}"),
        ("ts", "let a: number = 1;"),
        ("typescript", "interface A { x: string }"),
        ("tsx", "const a = <div className=\"x\">{y}</div>;"),
        ("toml", "[package]\nname = \"x\""),
        ("swift", "let greeting = \"hi\"\nfunc f() -> Int { return 1 }"),
        ("kotlin", "fun main() { val x = \"hi\" }"),
        ("dockerfile", "FROM rust:1\nRUN cargo build"),
        ("rust", "fn main() {}"),
    ] {
        assert!(body(&format!("```{lang}\n{code}\n```\n")).contains("class=\"s-"), "{lang}");
    }
    for unknown in ["klingon", "text", "txt", "plaintext", ""] {
        let h = body(&format!("```{unknown}\na < b\n```\n"));
        assert!(!h.contains("<span"), "{unknown:?}: {h}");
        assert!(h.contains("a &lt; b\n</code></pre>"), "{h}");
    }
    // The language is the first word of the info string; `highlight: false` switches it off.
    assert!(body("```rust,ignore title=x\nlet a = 1;\n```\n").contains("s-storage"));
    assert!(!doc("```rust\nlet a = 1;\n```\n").render_html(&plain()).contains("<span"));
    // Highlighting changes nothing about the text.
    let code = "def f(a, b):\n    return a < b and \"<tag>\" & 'x'\n";
    let h = body(&format!("```python\n{code}```\n"));
    let stripped = strip_tags(&h);
    assert!(stripped.contains(&markdown_core_escape(code)), "{stripped}");
}

fn markdown_core_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn strip_tags(html: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

#[test]
fn highlighting_survives_odd_code() {
    for code in ["", "\n", "no newline at end", "unterminated \"string\n", "/* open comment\n\n", "\r\n\r\n", "\u{0}\u{1}\u{2}", &"x".repeat(10_000)] {
        for lang in ["rust", "python", "html", "js", "yaml", "latex"] {
            let h = body(&format!("```{lang}\n{code}\n```\n"));
            assert!(h.starts_with("<pre><code"), "{lang} {code:?}");
        }
    }
    // Above the size limit the block is plain.
    let big = "let x = 1;\n".repeat(30_000);
    assert!(!body(&format!("```rust\n{big}```\n")).contains("<span"));
}

#[test]
fn highlight_languages_include_the_common_ones() {
    let names = highlight::language_names();
    for want in ["Rust", "Python", "JavaScript", "HTML", "JSON", "YAML", "C++", "Go", "SQL"] {
        assert!(names.iter().any(|n| n == want), "{want} in {names:?}");
    }
}

// ----- standalone ------------------------------------------------------------------------------

#[test]
fn standalone_documents_are_complete_pages() {
    let opts = RenderOptions { standalone: true, fallback_title: "Untitled & more".into(), ..Default::default() };
    let page = |t: &str| doc(t).render_html(&opts);
    let p = page("---\ntitle: \"From front <matter>\"\n---\n\n# Heading\n\ntext\n");
    assert!(p.starts_with("<!DOCTYPE html>\n<html lang=\"en\">"), "{p}");
    assert!(p.contains("<meta charset=\"utf-8\">") && p.contains("name=\"viewport\""), "{p}");
    assert!(p.contains("<title>From front &lt;matter&gt;</title>"), "{p}");
    assert!(p.contains("<style>") && p.contains("@media print") && p.contains("</style>"), "{p}");
    assert!(p.contains("<main class=\"md\" id=\"md\">\n<h1 id=\"heading\">Heading</h1>"), "{p}");
    assert!(p.ends_with("</main>\n</body>\n</html>\n"), "{p}");
    assert!(page("# Only a heading\n").contains("<title>Only a heading</title>"));
    assert!(page("plain text\n").contains("<title>Untitled &amp; more</title>"));
    assert!(page("").contains("<title>Untitled &amp; more</title>"));
    // The stylesheet is the theme's.
    let dark = theme_by_id("dark").unwrap();
    let styled = RenderOptions {
        standalone: true,
        style: Some(PreviewStyle { theme: dark.clone(), typography: Typography { measure_ch: 60.0, ..Typography::default() } }),
        ..Default::default()
    };
    let p = doc("x\n").render_html(&styled);
    assert!(p.contains(&format!("--bg: {};", dark.colors.background.to_hex())), "{p}");
    assert!(p.contains("max-width: 60ch"), "{p}");
    // A fragment can be a page too.
    assert!(doc("a\n\nb\n").render_html_fragment(TextRange::new(0, 1), &opts).contains("<main class=\"md\" id=\"md\">\n<p>a</p>\n</main>"));
}

// ----- the stylesheet -----------------------------------------------------------------------------

fn braces_balance(css: &str) -> bool {
    let mut depth = 0i32;
    for c in css.chars() {
        match c {
            '{' => depth += 1,
            '}' => depth -= 1,
            _ => {}
        }
        if depth < 0 {
            return false;
        }
    }
    depth == 0
}

#[test]
fn css_follows_the_theme_and_typography() {
    for t in builtin_themes() {
        let typo = Typography {
            font_family: "\"Quattro (bundled) S\", sans-serif".into(),
            mono_family: "\"Mono (bundled) S\", monospace".into(),
            font_size_px: 19.0,
            line_height: 1.6,
            measure_ch: 66.0,
        };
        let css = preview_css(&t, &typo);
        assert!(braces_balance(&css), "{}", t.id);
        for (role, color) in [
            ("--bg", t.colors.background),
            ("--text", t.colors.text),
            ("--heading", t.colors.heading),
            ("--link", t.colors.link),
            ("--code-text", t.colors.code_text),
            ("--code-bg", t.colors.code_background),
            ("--quote", t.colors.quote),
            ("--rule", t.colors.rule),
            ("--border", t.colors.table_border),
        ] {
            assert!(css.contains(&format!("{role}: {};", color.to_hex())), "{}: {role}", t.id);
        }
        assert!(css.contains("font-family: \"Quattro (bundled) S\", sans-serif; font-size: 19px; line-height: 1.6;"), "{css}");
        assert!(css.contains("max-width: 66ch"));
        assert!(css.contains(&format!("color-scheme: {};", if t.is_dark { "dark" } else { "light" })));
        // A proportional body: code a little smaller. A monospaced body (same stack): the same size.
        assert!(css.contains("font-size: 0.92em"));
        let mono = preview_css(&t, &Typography { font_family: typo.mono_family.clone(), ..typo.clone() });
        assert!(mono.contains("code, pre { font-family: \"Mono (bundled) S\", monospace; font-size: 1em; }"), "{mono}");
        assert!(css.contains("img { max-width: 100%;"));
    }
}

#[test]
fn print_styles_are_light_and_paginate() {
    let css = preview_css(&theme_by_id("dark").unwrap(), &Typography::default());
    let print = &css[css.find("@media print").unwrap()..];
    assert!(css.contains("@page {"), "page margins");
    for needle in [
        "--bg: #FFFFFF; --text: #000000;",
        "background: #FFFFFF !important",
        "max-width: none",
        "break-after: avoid",
        "break-inside: avoid",
        "orphans: 3; widows: 3",
        "a[href]::after { content: none !important; }",
        "color-scheme: light",
        "thead { display: table-header-group; }",
    ] {
        assert!(print.contains(needle), "{needle} missing from the print section");
    }
    assert!(!print.contains("max-width: 72ch"));
}

fn aa(name: &str, fg: Color, bg: Color) {
    let r = contrast_ratio(fg, bg);
    assert!(r >= 4.5, "{name} {} on {}: {r:.2}:1 is below 4.5:1", fg.to_hex(), bg.to_hex());
}

#[test]
fn syntax_palettes_meet_wcag_aa_on_every_code_background() {
    for t in builtin_themes() {
        let pal = syntax_palette(t.is_dark);
        for (name, color) in pal.all() {
            aa(&format!("{}: {name}", t.id), color, t.colors.code_background);
            aa(&format!("{}: {name} (page)", t.id), color, t.colors.background);
        }
        // The text of a code block, and a code block's text on the page.
        aa(&format!("{}: code text", t.id), t.colors.text, t.colors.code_background);
    }
    // Print: the light palette on the print code background, and on white.
    let print_bg = Color::from_hex("#F3F3F1").unwrap();
    for (name, color) in syntax_palette(false).all() {
        aa(&format!("print {name}"), color, print_bg);
        aa(&format!("print {name} on white"), color, Color::rgb(255, 255, 255));
    }
    // The palette is calm: each token colour is distinct.
    for dark in [false, true] {
        let all = syntax_palette(dark).all();
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert_ne!(a.1, b.1, "{} and {} share a colour", a.0, b.0);
            }
        }
    }
}

// ----- robustness ------------------------------------------------------------------------------------

fn every_option_set() -> Vec<RenderOptions> {
    vec![
        RenderOptions::default(),
        lines(),
        RenderOptions { sanitize: true, source_lines: true, ..Default::default() },
        RenderOptions { standalone: true, sanitize: true, highlight: false, ..Default::default() },
    ]
}

fn render_everything(text: &str, seed: &mut u64) {
    let enc = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32][(lcg(seed) % 3) as usize];
    let d = Document::new(text, enc);
    let b = boundaries(text, enc);
    for o in every_option_set() {
        let _ = d.render_html(&o);
        let (x, y) = (b[lcg(seed) as usize % b.len()], b[lcg(seed) as usize % b.len()]);
        let _ = d.render_html_fragment(TextRange::new(x.min(y), x.max(y)), &o);
    }
}

#[test]
fn rendering_never_panics_on_the_corpora() {
    let mut seed = 7u64;
    for (_, text) in snapshot_inputs() {
        render_everything(&text, &mut seed);
    }
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/commonmark-spec.json");
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    for e in json.as_array().unwrap() {
        render_everything(e["markdown"].as_str().unwrap(), &mut seed);
    }
    // The inputs that panic pulldown-cmark itself: shown as text.
    for text in [">1. [r]:u\n\t", "\n\n]**=== *word <b>text_~~~\\*[t][r]*===\n>1. [r]: /u\n\t"] {
        let h = body(text);
        assert!(!h.is_empty());
    }
    let n: usize = std::env::var("RENDER_FUZZ_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(600);
    for i in 0..n {
        let size = lcg(&mut seed) as usize;
        let text = match i % 3 {
            0 => token_doc(&mut seed, size % 400, TOKENS),
            1 => random_unicode(&mut seed, size % 80),
            _ => token_doc(&mut seed, size % 120, &["<script>", "</script>", "<style>", "onclick=\"", "javascript:", "<a href=", ">", "\"", "'", "<", "[x](", ")", "![", "\n", " ", "<iframe", "<!--", "-->"]),
        };
        render_everything(&text, &mut seed);
        // Sanitised output never carries what it is meant to remove, whatever went in.
        let d = doc(&text);
        let h = d.render_html(&RenderOptions { sanitize: true, ..Default::default() }).to_ascii_lowercase();
        for name in ["script", "iframe", "style", "object", "embed"] {
            assert!(!has_tag(&h, name), "{text:?} -> {h:?}");
        }
    }
}

#[test]
fn data_lines_hold_on_random_documents() {
    let mut seed = 21u64;
    for _ in 0..300 {
        let size = lcg(&mut seed) as usize;
        let text = token_doc(&mut seed, size % 300, TOKENS);
        // Raw HTML in the generated text can add `<p>`-like elements of its own; skip those.
        if text.contains('<') || text.contains("[^") {
            continue;
        }
        check_data_lines(&text).unwrap_or_else(|e| panic!("{text:?}: {e}"));
    }
}

#[test]
fn pictures_with_a_known_size_carry_it() {
    use markdown_core::ImageSize;
    let sizes = vec![
        ImageSize { destination: "shot.png".into(), width: 640, height: 400 },
        ImageSize { destination: "zero.png".into(), width: 0, height: 10 },
    ];
    let with = RenderOptions { image_sizes: sizes, ..Default::default() };
    let html = |text: &str, o: &RenderOptions| doc(text).render_html(o);
    assert_eq!(html("![A *shot*](shot.png)\n", &with), "<p><img src=\"shot.png\" alt=\"A shot\" width=\"640\" height=\"400\" /></p>\n");
    assert_eq!(
        html("![A](shot.png \"The \\\" title\")\n", &with),
        "<p><img src=\"shot.png\" alt=\"A\" width=\"640\" height=\"400\" title=\"The &quot; title\" /></p>\n"
    );
    // Not listed, listed with no size, or without sizes at all: as before, byte for byte.
    assert_eq!(html("![A](other.png)\n", &with), "<p><img src=\"other.png\" alt=\"A\" /></p>\n");
    assert_eq!(html("![A](zero.png)\n", &with), "<p><img src=\"zero.png\" alt=\"A\" /></p>\n");
    assert_eq!(html("![A](shot.png \"t\")\n", &plain()), "<p><img src=\"shot.png\" alt=\"A\" title=\"t\" /></p>\n");
}

// ----- highlighting: the two-face set (M7) ------------------------------------------------------

/// Inputs that make highlighters work hard: unclosed strings and comments, deep nesting, escapes at
/// the end of lines, heredocs, punctuation soup, long lines just under the plain-text limit.
fn pathological_code() -> Vec<String> {
    let soup: String = (0..900u32).map(|i| b"\"'`\\/*#<>{}[]()$@%;:=-+!?&|~^.,\n"[(i as usize * 7 + i as usize / 3) % 32] as char).collect();
    vec![
        format!("\"{}", "a".repeat(950)),
        format!("/* {}", "comment line\n".repeat(200)),
        "(".repeat(900) + &")".repeat(90),
        "{\n".repeat(400),
        "a\\".repeat(495),
        format!("<<EOF\n{}EOF", "${x} `y` $(z)\n".repeat(50)),
        format!("'''\n{}", "\"\"\" ' \\' \n".repeat(100)),
        soup,
        "<".repeat(999),
        "x = 1\n".repeat(3000),
        "\u{1F600}é\u{0301}\t\r\n\u{0}".repeat(60),
    ]
}

/// A language's token as a fence would name it: its first file extension, or its name's first word.
fn language_tokens() -> Vec<String> {
    let ss = two_face::syntax::extra_newlines();
    ss.syntaxes()
        .iter()
        .map(|s| s.file_extensions.first().cloned().unwrap_or_else(|| s.name.split_whitespace().next().unwrap_or("").to_lowercase()))
        .filter(|t| !t.is_empty())
        .collect()
}

#[test]
fn fifteen_languages_render_coloured_and_pathological_input_is_survived() {
    let langs = [
        "rust", "python", "js", "ts", "tsx", "swift", "kotlin", "go", "c", "cpp", "java", "ruby", "sh", "toml", "yaml",
        "json", "sql", "html", "css", "dockerfile",
    ];
    let samples = [
        "let x = \"s\"; // c\nfn f() {}", "def f(x):\n    return 'a'  # c", "const a = `t${b}`; // c", "let a: number = 1;",
        "const a = <div className=\"x\">{y}</div>;", "func f() -> Int { return 1 }", "fun f(): Int = 1 // c", "func f() { s := \"x\" }",
        "int main() { return 0; } /* c */", "template<class T> class A {};", "class A { String s = \"x\"; }", "def f; 'x'; end # c",
        "echo \"$HOME\" # c", "[a]\nb = \"c\"", "a: \"b\" # c", "{\"a\": [1, true, null]}", "SELECT a FROM b WHERE c = 'd';",
        "<p class=\"a\">b</p>", "a { color: red; } /* c */", "FROM rust:1\nRUN cargo build",
    ];
    for (lang, code) in langs.iter().zip(samples) {
        let h = body(&format!("```{lang}\n{code}\n```\n"));
        assert!(h.contains("<span class=\"s-"), "{lang}: {h}");
    }
    for unknown in ["klingon", "notalanguage", "x-y-z"] {
        assert!(!body(&format!("```{unknown}\n\"a\" < b\n```\n")).contains("<span"), "{unknown}");
    }
    // The same twenty with every pathological input: no panic, no hang, the text always there.
    for lang in langs {
        for code in pathological_code() {
            let html = body(&format!("````{lang}\n{code}\n````\n"));
            assert!(html.contains("</code></pre>"), "{lang}");
        }
    }
}

/// Every syntax two-face carries (213), with every pathological input and with random text: no
/// panic, and no block costs more than a bound. Run with --release; the debug build is slow to
/// compile 213 grammars.
#[test]
#[ignore]
fn every_bundled_syntax_survives_pathological_input() {
    use std::time::{Duration, Instant};
    let tokens = language_tokens();
    assert!(tokens.len() > 150, "{} syntaxes", tokens.len());
    let mut worst = (Duration::ZERO, String::new());
    let mut seed: u64 = 99;
    let mut random = || {
        let mut s = String::new();
        for _ in 0..400 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            s.push(b" \t\n\"'`\\/*#<>{}[]()$@%;:=abcXYZ019"[(seed >> 59) as usize % 32] as char);
        }
        s
    };
    for token in &tokens {
        let mut inputs = pathological_code();
        inputs.push(random());
        inputs.push(random());
        for code in inputs {
            let t = Instant::now();
            let result = std::panic::catch_unwind(|| highlight::highlight_until(token, &code, Some(Instant::now() + Duration::from_secs(5))));
            let took = t.elapsed();
            assert!(result.is_ok(), "{token}: panicked on {code:?}");
            if took > worst.0 {
                worst = (took, token.clone());
            }
        }
    }
    println!("{} syntaxes; slowest block: {:?} ({})", tokens.len(), worst.0, worst.1);
    assert!(worst.0 < Duration::from_secs(3), "{:?} for {}", worst.0, worst.1);
}
