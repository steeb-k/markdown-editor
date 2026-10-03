//! Wikilinks and inline tags in the analysis, Live mode and the HTML renderer.
//!
//! The existing invariants these have to keep: spans are in bounds, on code point boundaries,
//! sorted, properly nested (a wikilink holds only its own `Markup`); every `Markup` span lies in
//! its owner (a wikilink's markup is owned by the whole link, inline scope); prose ranges never
//! overlap markup; the dirty range of an edit is sound; the rendering oracle (tests/oracle.rs,
//! tests/conceal_oracle.rs) skips what pulldown-cmark has no notion of: wikilinks.
mod common;
use common::*;
use markdown_core::*;
use proptest::prelude::*;

#[track_caller]
fn assert_spans(text: &str, expected: &[(&str, &str)]) {
    let got: Vec<(String, String)> = spans_of(text).into_iter().filter(|(k, _)| k == "Wikilink" || k == "Tag" || k == "Markup").collect();
    let want: Vec<(String, String)> = expected.iter().map(|(k, t)| (k.to_string(), t.to_string())).collect();
    assert_eq!(got, want, "spans of {text:?}");
}

fn tags(text: &str) -> Vec<String> {
    texts(text, "Tag")
}

fn wikilinks(text: &str) -> Vec<String> {
    texts(text, "Wikilink")
}

// ----- spans --------------------------------------------------------------------------------------

#[test]
fn a_wikilink_is_a_span_with_markup_for_brackets_separator_and_heading() {
    assert_spans("[[Title]]", &[("Wikilink", "[[Title]]"), ("Markup", "[["), ("Markup", "]]")]);
    assert_spans("[[Title|label]]", &[("Wikilink", "[[Title|label]]"), ("Markup", "[["), ("Markup", "Title|"), ("Markup", "]]")]);
    // Without a label the heading is syntax, the target shows.
    assert_spans("[[Title#Head]]", &[("Wikilink", "[[Title#Head]]"), ("Markup", "[["), ("Markup", "#Head"), ("Markup", "]]")]);
    // With a label, target and heading both go with the separator.
    assert_spans("[[T#H|lab]]", &[("Wikilink", "[[T#H|lab]]"), ("Markup", "[["), ("Markup", "T#H|"), ("Markup", "]]")]);
    assert_spans("[[#Head]]", &[("Wikilink", "[[#Head]]"), ("Markup", "[["), ("Markup", "#"), ("Markup", "]]")]);
    assert_spans("a [[ x ]] b", &[("Wikilink", "[[ x ]]"), ("Markup", "[["), ("Markup", "]]")]);
}

#[test]
fn what_is_not_a_wikilink() {
    for t in ["[[]]", "[[ ]]", "[[a|]]", "[[a| ]]", "[[a", "[a]]", "[[a]", "[[a\nb]]", "[[a[b]]", "[[a]b]]", "\\[[a]]", "[[#]]", "[ [a]]"] {
        assert!(wikilinks(t).is_empty(), "{t:?} -> {:?}", wikilinks(t));
    }
    // An even run of backslashes does not escape.
    assert_eq!(wikilinks("\\\\[[a]]"), ["[[a]]"]);
    // In the middle of text, in emphasis, in a list, in a table cell, in a heading and a quote.
    for t in ["x[[a]]y", "*[[a]]*", "- [[a]]", "> [[a]]", "# [[a]]", "| [[a]] |\n|---|\n| b |", "**a [[a]] b**"] {
        assert_eq!(wikilinks(t), ["[[a]]"], "{t:?}");
    }
    assert_eq!(wikilinks("[[a]] [[b|c]] [[d#e]]"), ["[[a]]", "[[b|c]]", "[[d#e]]"]);
}

#[test]
fn never_inside_code_links_images_html_or_front_matter() {
    for t in [
        "`[[a]] #t`",
        "``[[a]]``",
        "```\n[[a]]\n#t\n```",
        "~~~md\n[[a]] #t\n~~~",
        "    [[a]] #t",
        "[x [[a]] #t y](http://u)",
        "[[[a]]](u)",
        "![alt [[a]] #t](p.png)",
        "<span title=\"[[a]] #t\">",
        "<div>\n[[a]] #t\n</div>",
        "---\ntags: [[a]] #t\n---\n",
        "<http://x.y/#frag>",
        "[ref]: http://x.y/[[a]]",
        "https://x.y/#frag",
        "www.x.y/#frag and http://x.y/a[[b]]c",
    ] {
        let doc = Document::new(t, OffsetEncoding::Utf8);
        check_everything(&doc).unwrap();
        let found: Vec<_> = doc.spans(None).into_iter().filter(|s| matches!(s.kind, SpanKind::Wikilink | SpanKind::Tag)).collect();
        assert!(found.is_empty(), "{t:?} -> {found:?}");
    }
    // But next to them.
    assert_eq!(wikilinks("`code` [[a]]"), ["[[a]]"]);
    assert_eq!(tags("`code` #t"), ["#t"]);
    assert_eq!(tags("---\na: b\n---\n\n#t"), ["#t"]);
    assert_eq!(tags("[l](http://u) #t"), ["#t"]);
    assert_eq!(tags("<b>x</b> #t"), ["#t"]);
}

#[test]
fn tag_rules() {
    assert_eq!(tags("#tag"), ["#tag"]);
    assert_eq!(tags("a #tag b"), ["#tag"]);
    assert_eq!(tags("#a/b #a/b/c #a_b #a-b #é #日本 #a1"), ["#a/b", "#a/b/c", "#a_b", "#a-b", "#é", "#日本", "#a1"]);
    // The tag ends at anything else; a trailing `-` or `/` is not part of it.
    assert_eq!(tags("(#tag) #tag. #tag, #tag- #tag/ #tag!"), ["#tag", "#tag", "#tag", "#tag", "#tag", "#tag"]);
    assert_eq!(texts("#tag- x", "Tag"), ["#tag"]);
    // A letter must follow.
    for t in ["#", "# ", "#1", "#_a", "#-a", "#/a", "# a"] {
        assert!(tags(t).is_empty(), "{t:?}");
    }
    // Not after a letter, a digit, `#` or `&`, nor escaped.
    for t in ["a#b", "1#b", "é#b", "##b", "&#x41;", "\\#b", "C#"] {
        assert!(tags(t).is_empty(), "{t:?}");
    }
    assert_eq!(tags("\\\\#b"), ["#b"]);
    assert_eq!(tags("a/#b"), ["#b"]);
    assert_eq!(tags("*#b*"), ["#b"]);
    // Not in a heading line: ATX, setext; but in the paragraph around.
    assert!(tags("# a #tag").is_empty());
    assert!(tags("## a #tag ##").is_empty());
    assert!(tags("Setext #tag\n===").is_empty());
    assert!(tags("# *x #tag*").is_empty());
    assert_eq!(tags("# head\n\n#tag"), ["#tag"]);
    assert_eq!(tags("#tag\n\n# head"), ["#tag"]);
    // A tag line that is no heading (no space after the `#`).
    assert_eq!(tags("#tag more"), ["#tag"]);
    // Not inside a wikilink.
    assert_eq!(tags("[[a#b]] #c"), ["#c"]);
}

#[test]
fn spans_nest_and_markup_is_owned_by_the_wikilink() {
    for t in [
        "[[a]]",
        "*x [[a|b]] #t*",
        "> [[a#b]] #t\n> more",
        "- [[a]]\n- #t [[b]]",
        "| [[a]] | #t |\n|---|---|\n| b | c |",
        "# [[a]] #no",
        "**[[a]]**",
        "[[a]][[b]]#t#u",
        "[[a]]\n[[b]]",
    ] {
        let doc = Document::new(t, OffsetEncoding::Utf8);
        check_everything(&doc).unwrap_or_else(|e| panic!("{t:?}: {e}"));
        let spans = doc.spans(None);
        let marks = doc.markup_spans(None);
        for w in spans.iter().filter(|s| s.kind == SpanKind::Wikilink) {
            // The markup inside the wikilink is owned by it, inline scope; nothing else is inside.
            let inside: Vec<&Span> = spans.iter().filter(|s| *s != w && s.range.start >= w.range.start && s.range.end <= w.range.end).collect();
            assert!(inside.iter().all(|s| s.kind == SpanKind::Markup), "{t:?}: {inside:?}");
            assert!(inside.len() >= 2, "{t:?}");
            for m in marks.iter().filter(|m| m.range.start >= w.range.start && m.range.end <= w.range.end) {
                assert_eq!((m.owner, m.scope), (w.range, MarkupScope::Inline), "{t:?}");
            }
        }
    }
}

#[test]
fn wikilink_in_every_encoding() {
    let text = "\u{1F389} [[T\u{e9}st|\u{65E5}\u{672C}]] #t\u{e9}g";
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let doc = Document::new(text, enc);
        check_everything(&doc).unwrap();
        let got: Vec<(SpanKind, String)> = doc
            .spans(None)
            .into_iter()
            .filter(|s| matches!(s.kind, SpanKind::Wikilink | SpanKind::Tag))
            .map(|s| (s.kind, slice_units(text, enc, s.range)))
            .collect();
        assert_eq!(got, [(SpanKind::Wikilink, "[[T\u{e9}st|\u{65E5}\u{672C}]]".to_owned()), (SpanKind::Tag, "#t\u{e9}g".to_owned())], "{enc:?}");
    }
}

#[test]
fn prose_keeps_the_label_and_the_tag_not_the_brackets() {
    let doc = Document::new("see [[Title|the label]] and #tag", OffsetEncoding::Utf8);
    let prose: Vec<String> = doc.prose_ranges(None).iter().map(|r| slice_units(doc.text(), OffsetEncoding::Utf8, *r)).collect();
    assert_eq!(prose, ["see ", "the label", " and #tag"]);
}

#[test]
fn wikilink_at_finds_the_link_under_the_offset() {
    let text = "ab [[Title#Head|label]] cd [[#Own]] [x](u)";
    let doc = Document::new(text, OffsetEncoding::Utf16);
    assert_eq!(doc.wikilink_at(0), None);
    assert_eq!(doc.wikilink_at(2), None);
    let w = doc.wikilink_at(3).unwrap();
    assert_eq!(w.range, TextRange::new(3, 23));
    assert_eq!((w.target.as_str(), w.heading.as_deref(), w.label.as_deref()), ("Title", Some("Head"), Some("label")));
    assert_eq!(doc.wikilink_at(22).unwrap(), w);
    assert_eq!(doc.wikilink_at(23), None);
    let own = doc.wikilink_at(30).unwrap();
    assert_eq!((own.target.as_str(), own.heading.as_deref(), own.label), ("", Some("Own"), None));
    assert_eq!(doc.wikilink_at(100), None);
    // The ordinary link affordance does not see wikilinks and the other way round.
    assert_eq!(doc.link_at(5), None);
    assert_eq!(doc.wikilink_at(40), None);
}

// ----- Live mode -----------------------------------------------------------------------------------

fn hidden_for(text: &str, caret: u32) -> Vec<String> {
    let doc = Document::new(text, OffsetEncoding::Utf8);
    let c = doc.concealment(TextRange::new(caret, caret), None);
    c.hidden.iter().map(|r| text[r.start as usize..r.end as usize].to_owned()).collect()
}

fn visible(text: &str, caret: u32) -> String {
    let doc = Document::new(text, OffsetEncoding::Utf8);
    let c = doc.concealment(TextRange::new(caret, caret), None);
    let mut out = String::new();
    let mut at = 0usize;
    for r in &c.hidden {
        out.push_str(&text[at..r.start as usize]);
        at = r.end as usize;
    }
    out.push_str(&text[at..]);
    out
}

#[test]
fn live_mode_shows_only_the_label() {
    let end = |t: &str| t.len() as u32;
    let t = "see [[Title|the label]] now\n\nx";
    assert_eq!(hidden_for(t, end(t)), ["[[Title|", "]]"]);
    assert_eq!(visible(t, end(t)), "see the label now\n\nx");
    // Without a label: the target; the heading goes.
    let t = "see [[Title]] now\n\nx";
    assert_eq!(visible(t, end(t)), "see Title now\n\nx");
    let t = "see [[Title#Head]] now\n\nx";
    assert_eq!(visible(t, end(t)), "see Title now\n\nx");
    let t = "see [[T#H|label]] now\n\nx";
    assert_eq!(visible(t, end(t)), "see label now\n\nx");
    let t = "see [[#Head]] now\n\nx";
    assert_eq!(visible(t, end(t)), "see Head now\n\nx");
    // Tags are never concealed.
    let t = "a #tag b\n\nx";
    assert!(hidden_for(t, end(t)).is_empty());
}

#[test]
fn a_caret_in_or_next_to_the_wikilink_shows_its_source() {
    let t = "see [[Title|label]] now\n\nx";
    for caret in [4, 6, 12, 18, 19] {
        assert!(hidden_for(t, caret).is_empty(), "caret {caret}");
    }
    assert!(!hidden_for(t, 3).is_empty());
    assert!(!hidden_for(t, 20).is_empty());
    // A selection that overlaps it.
    let doc = Document::new(t, OffsetEncoding::Utf8);
    assert!(doc.concealment(TextRange::new(0, 8), None).hidden.is_empty());
    assert!(doc.concealment(TextRange::new(0, 3), None).hidden.len() == 2);
}

#[test]
fn wikilinks_in_tables_stay_visible() {
    let t = "| [[a]] | c |\n|---|---|\n| d | e |\n\nx";
    assert!(hidden_for(t, t.len() as u32).is_empty());
}

#[test]
fn live_mode_invariants_hold_with_wikilinks_everywhere() {
    for t in ["[[a]]\n[[b|c]]", "> [[a#b]] #t\n> x", "- [[a]]\n  - [[b|c]]", "# [[a]] h", "*[[a]]*", "[[a]](u) [[b]]"] {
        let doc = Document::new(t, OffsetEncoding::Utf8);
        for caret in 0..=t.len() as u32 {
            if !t.is_char_boundary(caret as usize) {
                continue;
            }
            let c = doc.concealment(TextRange::new(caret, caret), None);
            for h in &c.hidden {
                assert!(h.start < h.end && h.end as usize <= t.len());
                assert!(!t[h.start as usize..h.end as usize].contains(['\n', '\r']), "{t:?}");
            }
            assert!(c.hidden.windows(2).all(|w| w[0].end < w[1].start), "sorted, disjoint, merged");
        }
    }
}

// ----- the renderer --------------------------------------------------------------------------------

fn html(text: &str) -> String {
    Document::new(text, OffsetEncoding::Utf8).render_html(&RenderOptions { highlight: false, ..Default::default() })
}

fn html_sanitized(text: &str) -> String {
    Document::new(text, OffsetEncoding::Utf8).render_html(&RenderOptions { sanitize: true, highlight: false, ..Default::default() })
}

#[test]
fn wikilinks_render_as_links_to_the_sibling_note() {
    assert_eq!(html("[[Title]]"), "<p><a href=\"Title.md\">Title</a></p>\n");
    assert_eq!(html("[[Title|label]]"), "<p><a href=\"Title.md\">label</a></p>\n");
    assert_eq!(html("[[Title#Some Heading]]"), "<p><a href=\"Title.md#some-heading\">Title</a></p>\n");
    assert_eq!(html("[[Title#H|label]]"), "<p><a href=\"Title.md#h\">label</a></p>\n");
    assert_eq!(html("[[#Some Heading]]"), "<p><a href=\"#some-heading\">Some Heading</a></p>\n");
    assert_eq!(html("a [[B]] c"), "<p>a <a href=\"B.md\">B</a> c</p>\n");
    // Spaces and unicode are escaped in the href, shown as written.
    assert_eq!(html("[[My Note]]"), "<p><a href=\"My%20Note.md\">My Note</a></p>\n");
    assert_eq!(html("[[Caf\u{e9}]]"), "<p><a href=\"Caf%C3%A9.md\">Caf\u{e9}</a></p>\n");
    // An extension is not doubled; a folder path stays.
    assert_eq!(html("[[Note.md]]"), "<p><a href=\"Note.md\">Note.md</a></p>\n");
    assert_eq!(html("[[dir/Note]]"), "<p><a href=\"dir/Note.md\">dir/Note</a></p>\n");
    // Text is escaped.
    assert_eq!(html("[[a&b|x&y]]"), "<p><a href=\"a&amp;b.md\">x&amp;y</a></p>\n");
    // Inside emphasis, lists, quotes, tables, headings.
    assert_eq!(html("*[[a]]*"), "<p><em><a href=\"a.md\">a</a></em></p>\n");
    assert!(html("- [[a]]").contains("<li><a href=\"a.md\">a</a></li>"));
    assert!(html("> [[a]]").contains("<a href=\"a.md\">a</a>"));
    assert!(html("| [[a]] |\n|---|\n| b |").contains("<td><a href=\"a.md\">a</a></td>") || html("| [[a]] |\n|---|\n| b |").contains("<th><a href=\"a.md\">a</a></th>"));
    assert_eq!(html("# [[a]]"), "<h1 id=\"a\"><a href=\"a.md\">a</a></h1>\n");
    // Not in code or in links.
    assert_eq!(html("`[[a]]`"), "<p><code>[[a]]</code></p>\n");
    assert_eq!(html("[x [[a]] y](u)"), "<p><a href=\"u\">x [[a]] y</a></p>\n");
    assert_eq!(html("```\n[[a]]\n```"), "<pre><code>[[a]]\n</code></pre>\n");
}

#[test]
fn a_target_that_looks_like_a_url_scheme_stays_a_relative_link() {
    assert_eq!(html("[[Note: Title]]"), "<p><a href=\"./Note:%20Title.md\">Note: Title</a></p>\n");
    let s = html_sanitized("[[javascript:alert(1)]]");
    assert!(s.contains("href=\"./javascript:alert(1).md\""), "{s}");
    assert!(!s.contains("href=\"javascript"));
}

#[test]
fn tags_render_as_muted_spans() {
    assert_eq!(html("a #tag b"), "<p>a <span class=\"tag\">#tag</span> b</p>\n");
    assert_eq!(html("#a/b."), "<p><span class=\"tag\">#a/b</span>.</p>\n");
    assert_eq!(html("`#tag`"), "<p><code>#tag</code></p>\n");
    assert_eq!(html("# head #tag"), "<h1 id=\"head-tag\">head #tag</h1>\n");
    assert_eq!(html("a#b \\#c"), "<p>a#b #c</p>\n");
    assert_eq!(html("https://x.y/#frag"), "<p><a href=\"https://x.y/#frag\">https://x.y/#frag</a></p>\n");
    assert!(html("#tag").contains("class=\"tag\""));
}

#[test]
fn both_survive_the_sanitizer() {
    let t = "[[Title|label]] and #tag and <span class=\"tag\">raw</span>";
    let s = html_sanitized(t);
    assert!(s.contains("<a href=\"Title.md\">label</a>"), "{s}");
    assert!(s.contains("<span class=\"tag\">#tag</span>"), "{s}");
    assert!(s.contains("<span class=\"tag\">raw</span>"), "{s}");
    assert_eq!(s, html(t), "nothing of ours is filtered");
}

#[test]
fn fragments_render_the_same_links() {
    let t = "first\n\nsee [[Title]] #tag\n\nlast";
    let doc = Document::new(t, OffsetEncoding::Utf8);
    let f = doc.render_html_fragment(TextRange::new(7, 24), &RenderOptions { highlight: false, ..Default::default() });
    assert!(f.contains("<a href=\"Title.md\">Title</a>") && f.contains("<span class=\"tag\">#tag</span>"), "{f}");
}

#[test]
fn the_preview_stylesheet_styles_tags() {
    let css = preview_css(&builtin_themes()[0], &Typography::default());
    assert!(css.contains(".tag"));
}

// ----- properties ----------------------------------------------------------------------------------

fn soup(max: usize) -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "[[", "]]", "[[a]]", "[[a|b]]", "[[a#h]]", "[[#h]]", "|", "#", "#tag", "#a/b", " ", "\n", "\n\n", "# ", "## ", "> ", "- ", "`", "```\n", "*", "**",
        "[", "](", ")", "![", "<b>", "</b>", "http://a.b/#c ", "\\", "&#x41;", "word", "\u{e9}", "\u{1F389}", "---\n", "| a | b |\n|---|---|\n", "[r]: /u\n",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(600)
    ))]

    #[test]
    fn the_contract_holds_with_wikilinks_and_tags_in_the_soup(text in soup(40)) {
        for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            let doc = Document::new(&text, enc);
            if let Err(e) = check_everything(&doc) {
                return Err(TestCaseError::fail(format!("{enc:?} {text:?}: {e}")));
            }
            // Concealment is a pure function of text and selection: never hides a line break.
            let c = doc.concealment(TextRange::new(0, 0), None);
            let b = boundaries(&text, enc);
            for h in &c.hidden {
                prop_assert!(!slice_units(&text, enc, *h).contains(['\n', '\r']));
                prop_assert!(b.binary_search(&h.start).is_ok() && b.binary_search(&h.end).is_ok());
            }
        }
    }

    #[test]
    fn dirty_ranges_stay_sound_with_wikilinks_and_tags(
        text in soup(30), with in soup(4), a in 0usize..200, b in 0usize..200,
    ) {
        let bounds = boundaries(&text, OffsetEncoding::Utf16);
        let (mut i, mut j) = (a % bounds.len(), b % bounds.len());
        if i > j { std::mem::swap(&mut i, &mut j); }
        let range = TextRange::new(bounds[i], bounds[j]);
        if let Err(e) = check_edit(&text, OffsetEncoding::Utf16, range, &with) {
            return Err(TestCaseError::fail(format!("edit {range:?} -> {with:?} in {text:?}: {e}")));
        }
    }

    #[test]
    fn rendering_never_panics_and_closes_its_links(text in soup(40)) {
        let doc = Document::new(&text, OffsetEncoding::Utf16);
        for sanitize in [false, true] {
            let h = doc.render_html(&RenderOptions { sanitize, highlight: false, ..Default::default() });
            prop_assert!(h.matches("<a ").count() >= h.matches("</a>").count());
        }
    }
}

#[test]
fn every_fixture_note_keeps_the_contract() {
    let base = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/library");
    let mut n = 0;
    let mut stack = vec![base];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else {
                let text = std::fs::read_to_string(&p).unwrap();
                for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
                    check_everything(&Document::new(&text, enc)).unwrap_or_else(|e| panic!("{p:?} {enc:?}: {e}"));
                }
                n += 1;
            }
        }
    }
    assert!(n >= 30);
}
