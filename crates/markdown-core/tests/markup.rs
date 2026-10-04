//! Hand-written expectations for the spans (and markup derivation) of each construct.
mod common;
use common::*;
use markdown_core::*;

/// Assert the complete span list of `text` as (kind, source text) pairs.
#[track_caller]
fn assert_spans(text: &str, expected: &[(&str, &str)]) {
    let got = spans_of(text);
    let want: Vec<(String, String)> = expected.iter().map(|(k, t)| (k.to_string(), t.to_string())).collect();
    assert_eq!(got, want, "spans of {text:?}");
}

// ---------- headings ----------

#[test]
fn atx_heading() {
    assert_spans("# Title", &[("Heading1", "# Title"), ("Markup", "# ")]);
    assert_spans("###### Six", &[("Heading6", "###### Six"), ("Markup", "###### ")]);
    assert_spans("  ## Indented", &[("Heading2", "## Indented"), ("Markup", "## ")]);
}

#[test]
fn atx_heading_closing_hashes() {
    assert_spans("## Title ##", &[("Heading2", "## Title ##"), ("Markup", "## "), ("Markup", "##")]);
    assert_spans("# Title #   ", &[("Heading1", "# Title #"), ("Markup", "# "), ("Markup", "#")]);
    // An escaped or attached trailing # is content, not a closing sequence.
    assert_spans("# C#", &[("Heading1", "# C#"), ("Markup", "# ")]);
    assert_spans("# a \\#", &[("Heading1", "# a \\#"), ("Markup", "# "), ("Markup", "\\")]);
}

#[test]
fn empty_atx_heading() {
    assert_spans("#", &[("Heading1", "#"), ("Markup", "#")]);
    assert_spans("## ##", &[("Heading2", "## ##"), ("Markup", "## "), ("Markup", "##")]);
}

#[test]
fn not_a_heading() {
    // Not a heading; it is a tag.
    assert_spans("#hashtag", &[("Tag", "#hashtag")]);
    assert_spans("#1 seven", &[]);
    assert_spans("####### seven", &[]);
}

#[test]
fn setext_heading() {
    assert_spans("Title\n=====", &[("Heading1", "Title\n====="), ("Markup", "=====")]);
    assert_spans("Sub\n---\n", &[("Heading2", "Sub\n---"), ("Markup", "---")]);
    assert_spans("two\nlines\n===", &[("Heading1", "two\nlines\n==="), ("Markup", "===")]);
}

#[test]
fn heading_with_inline_content() {
    assert_spans(
        "# a *b*",
        &[("Heading1", "# a *b*"), ("Markup", "# "), ("Emphasis", "*b*"), ("Markup", "*"), ("Markup", "*")],
    );
}

// ---------- emphasis, strong, strikethrough ----------

#[test]
fn emphasis_and_strong() {
    assert_spans("*a*", &[("Emphasis", "*a*"), ("Markup", "*"), ("Markup", "*")]);
    assert_spans("_a_", &[("Emphasis", "_a_"), ("Markup", "_"), ("Markup", "_")]);
    assert_spans("**a**", &[("Strong", "**a**"), ("Markup", "**"), ("Markup", "**")]);
    assert_spans("__a__", &[("Strong", "__a__"), ("Markup", "__"), ("Markup", "__")]);
}

#[test]
fn strong_and_emphasis_combined() {
    assert_spans(
        "***a***",
        &[
            ("Emphasis", "***a***"),
            ("Markup", "*"),
            ("Strong", "**a**"),
            ("Markup", "**"),
            ("Markup", "**"),
            ("Markup", "*"),
        ],
    );
}

#[test]
fn strikethrough() {
    assert_spans("~~a~~", &[("Strikethrough", "~~a~~"), ("Markup", "~~"), ("Markup", "~~")]);
    assert_spans("~a~", &[("Strikethrough", "~a~"), ("Markup", "~"), ("Markup", "~")]);
}

#[test]
fn emphasis_is_not_matched_inside_words_for_underscore() {
    assert_spans("snake_case_name", &[]);
}

#[test]
fn nested_strong_in_emphasis_in_link() {
    let t = "[*a **b** c*](u)";
    assert_spans(
        t,
        &[
            ("Link", t),
            ("Markup", "["),
            ("Emphasis", "*a **b** c*"),
            ("Markup", "*"),
            ("Strong", "**b**"),
            ("Markup", "**"),
            ("Markup", "**"),
            ("Markup", "*"),
            ("Markup", "]("),
            ("LinkDestination", "u"),
            ("Markup", ")"),
        ],
    );
}

// ---------- code ----------

#[test]
fn inline_code() {
    assert_spans("`a`", &[("InlineCode", "`a`"), ("Markup", "`"), ("Markup", "`")]);
    assert_spans("``a`b``", &[("InlineCode", "``a`b``"), ("Markup", "``"), ("Markup", "``")]);
    assert_spans("x ` a ` y", &[("InlineCode", "` a `"), ("Markup", "`"), ("Markup", "`")]);
}

#[test]
fn inline_code_hides_inner_markup() {
    assert_spans("`*a*`", &[("InlineCode", "`*a*`"), ("Markup", "`"), ("Markup", "`")]);
}

#[test]
fn fenced_code_block() {
    let t = "```rust\nlet x = 1;\n```";
    assert_spans(t, &[("CodeBlock", t), ("Markup", "```"), ("CodeInfo", "rust"), ("Markup", "```")]);
}

#[test]
fn fenced_code_block_without_info() {
    let t = "```\ncode\n```\n";
    assert_spans(t, &[("CodeBlock", "```\ncode\n```"), ("Markup", "```"), ("Markup", "```")]);
}

#[test]
fn tilde_fence_and_longer_closing_fence() {
    let t = "~~~ py  \ncode\n~~~~~";
    assert_spans(t, &[("CodeBlock", t), ("Markup", "~~~"), ("CodeInfo", "py"), ("Markup", "~~~~~")]);
}

#[test]
fn unclosed_fence_has_no_closing_markup() {
    let t = "```js\nlet x;\nmore";
    assert_spans(t, &[("CodeBlock", t), ("Markup", "```"), ("CodeInfo", "js")]);
}

#[test]
fn fence_content_is_not_markup() {
    let t = "```\n# not a heading\n*a*\n> not a quote\n```";
    assert_spans(t, &[("CodeBlock", t), ("Markup", "```"), ("Markup", "```")]);
}

#[test]
fn indented_code_block_has_no_markup() {
    assert_spans("    code\n    more\n", &[("CodeBlock", "code\n    more")]);
}

// ---------- links and images ----------

#[test]
fn inline_link_with_title() {
    let t = "[text](http://e.com \"title\")";
    assert_spans(
        t,
        &[
            ("Link", t),
            ("Markup", "["),
            ("Markup", "]("),
            ("LinkDestination", "http://e.com \"title\""),
            ("Markup", ")"),
        ],
    );
}

#[test]
fn inline_link_angle_destination_and_whitespace() {
    let t = "[a](  <b c>  )";
    assert_spans(
        t,
        &[("Link", t), ("Markup", "["), ("Markup", "](  "), ("LinkDestination", "<b c>"), ("Markup", "  )")],
    );
}

#[test]
fn inline_link_with_parens_in_destination() {
    let t = "[a](http://x.y/(z))";
    assert_spans(
        t,
        &[("Link", t), ("Markup", "["), ("Markup", "]("), ("LinkDestination", "http://x.y/(z)"), ("Markup", ")")],
    );
}

#[test]
fn empty_link_destination() {
    let t = "[a]()";
    assert_spans(t, &[("Link", t), ("Markup", "["), ("Markup", "]("), ("Markup", ")")]);
}

#[test]
fn reference_link() {
    let t = "[a][ref]\n\n[ref]: http://x \"T\"";
    assert_spans(
        t,
        &[
            ("Link", "[a][ref]"),
            ("Markup", "["),
            ("Markup", "]["),
            ("LinkDestination", "ref"),
            ("Markup", "]"),
            ("Markup", "["),
            ("Markup", "]:"),
            ("LinkDestination", "http://x \"T\""),
        ],
    );
}

#[test]
fn collapsed_and_shortcut_links() {
    let defs = "\n\n[a]: /u";
    assert_eq!(
        spans_of(&format!("[a][]{defs}"))[..3],
        [("Link".into(), "[a][]".into()), ("Markup".into(), "[".into()), ("Markup".into(), "][]".into())]
    );
    assert_eq!(
        spans_of(&format!("[a]{defs}"))[..3],
        [("Link".into(), "[a]".into()), ("Markup".into(), "[".into()), ("Markup".into(), "]".into())]
    );
}

#[test]
fn undefined_reference_is_plain_text() {
    assert_spans("[a][nope] and [b]", &[]);
}

#[test]
fn autolinks() {
    assert_spans(
        "<http://a.b/c>",
        &[("Link", "<http://a.b/c>"), ("Markup", "<"), ("LinkDestination", "http://a.b/c"), ("Markup", ">")],
    );
    assert_spans(
        "<me@x.org>",
        &[("Link", "<me@x.org>"), ("Markup", "<"), ("LinkDestination", "me@x.org"), ("Markup", ">")],
    );
}

#[test]
fn bare_urls_are_links_without_markup() {
    // pulldown-cmark 0.13 has no GFM bare-URL autolinks; the core finds them itself and
    // reports a bare `Link` span with no markup (see tests/autolink.rs).
    assert_spans("see https://example.com now", &[("Link", "https://example.com")]);
}

#[test]
fn image() {
    let t = "![alt text](img/p.png \"A title\")";
    assert_spans(
        t,
        &[
            ("Image", t),
            ("Markup", "!["),
            ("Markup", "]("),
            ("LinkDestination", "img/p.png \"A title\""),
            ("Markup", ")"),
        ],
    );
}

#[test]
fn empty_alt_image_and_reference_image() {
    assert_spans(
        "![](a.png)",
        &[("Image", "![](a.png)"), ("Markup", "!["), ("Markup", "]("), ("LinkDestination", "a.png"), ("Markup", ")")],
    );
    let t = "![a][r]\n\n[r]: x.png";
    let s = spans_of(t);
    assert_eq!(&s[..5], &[
        ("Image".into(), "![a][r]".into()),
        ("Markup".into(), "![".into()),
        ("Markup".into(), "][".into()),
        ("LinkDestination".into(), "r".into()),
        ("Markup".into(), "]".into()),
    ]);
}

#[test]
fn image_inside_link() {
    let t = "[![i](j)](k)";
    let s = spans_of(t);
    assert_eq!(s[0], ("Link".into(), t.into()));
    assert_eq!(s[2], ("Image".into(), "![i](j)".into()));
    assert_eq!(s.last().unwrap(), &("Markup".to_string(), ")".to_string()));
}

#[test]
fn escaped_brackets_in_link_text() {
    let t = "[a\\]](u)";
    let s = spans_of(t);
    assert!(s.contains(&("Markup".into(), "\\".into())));
    assert!(s.contains(&("Markup".into(), "](".into())));
    assert!(s.contains(&("LinkDestination".into(), "u".into())));
}

// ---------- block quotes ----------

#[test]
fn block_quote_every_line_with_marker() {
    let t = "> a\n> b\n>\n> c";
    assert_spans(t, &[("BlockQuote", t), ("Markup", "> "), ("Markup", "> "), ("Markup", ">"), ("Markup", "> ")]);
}

#[test]
fn block_quote_lazy_continuation_has_no_marker() {
    let t = "> a\nlazy\n> b";
    assert_spans(t, &[("BlockQuote", t), ("Markup", "> "), ("Markup", "> ")]);
}

#[test]
fn nested_block_quotes() {
    let t = "> > a\n> b\n> > c";
    let s = spans_of(t);
    assert_eq!(s[0], ("BlockQuote".to_string(), t.to_string()));
    // pulldown-cmark makes `> > c` a continuation of the inner quote's paragraph.
    assert_eq!(texts(t, "BlockQuote"), vec![t.to_string(), "> a\n> b\n> > c".to_string()]);
    // outer markers on lines 1-3, inner markers on lines 1 and 3, none for the lazy line 2.
    let doc = Document::new(t, OffsetEncoding::Utf8);
    let m = doc.markup_spans(None);
    assert_eq!(m.len(), 5);
    assert!(m.iter().all(|m| m.scope == MarkupScope::Line));
    let starts: Vec<u32> = m.iter().map(|m| m.range.start).collect();
    assert_eq!(starts, vec![0, 2, 6, 10, 12]);
}

#[test]
fn quote_containing_list_containing_code_fence() {
    let t = "> - item\n>   ```rs\n>   code\n>   ```\n> - two";
    assert_spans(
        t,
        &[
            ("BlockQuote", t),
            ("Markup", "> "),
            ("BulletMarker", "-"),
            ("Markup", "> "),
            ("CodeBlock", "```rs\n>   code\n>   ```"),
            ("Markup", "```"),
            ("CodeInfo", "rs"),
            ("Markup", "> "),
            ("Markup", "> "),
            ("Markup", "```"),
            ("Markup", "> "),
            ("BulletMarker", "-"),
        ],
    );
}

#[test]
fn quote_with_heading_and_emphasis() {
    let t = "> # H\n> *e*";
    assert_spans(
        t,
        &[
            ("BlockQuote", t),
            ("Markup", "> "),
            ("Heading1", "# H"),
            ("Markup", "# "),
            ("Markup", "> "),
            ("Emphasis", "*e*"),
            ("Markup", "*"),
            ("Markup", "*"),
        ],
    );
}

#[test]
fn greater_than_in_text_is_not_a_quote_marker() {
    assert_spans("a > b", &[]);
    let t = "> a > b";
    assert_spans(t, &[("BlockQuote", t), ("Markup", "> ")]);
}

// ---------- lists and tasks ----------

#[test]
fn list_markers() {
    assert_spans("- a\n- b", &[("BulletMarker", "-"), ("BulletMarker", "-")]);
    assert_spans("* a", &[("BulletMarker", "*")]);
    assert_spans("+ a", &[("BulletMarker", "+")]);
    assert_spans("1. a\n2. b", &[("OrderedMarker", "1."), ("OrderedMarker", "2.")]);
    assert_spans("10) a", &[("OrderedMarker", "10)")]);
}

#[test]
fn nested_and_indented_list_markers() {
    assert_spans("- a\n  - b\n    1. c", &[("BulletMarker", "-"), ("BulletMarker", "-"), ("OrderedMarker", "1.")]);
    assert_spans("  - a", &[("BulletMarker", "-")]);
}

#[test]
fn empty_list_item() {
    assert_spans("-\n- a", &[("BulletMarker", "-"), ("BulletMarker", "-")]);
}

#[test]
fn task_markers_are_not_markup() {
    assert_spans(
        "- [ ] open\n- [x] done\n- [X] done too",
        &[
            ("BulletMarker", "-"),
            ("TaskOpen", "[ ]"),
            ("BulletMarker", "-"),
            ("TaskChecked", "[x]"),
            ("BulletMarker", "-"),
            ("TaskChecked", "[X]"),
        ],
    );
}

#[test]
fn list_item_with_inline_markup() {
    assert_spans(
        "- a **b**",
        &[("BulletMarker", "-"), ("Strong", "**b**"), ("Markup", "**"), ("Markup", "**")],
    );
}

// ---------- thematic break, hard break, html ----------

#[test]
fn thematic_breaks() {
    assert_spans("---", &[("ThematicBreak", "---")]);
    assert_spans("a\n\n***\n\nb", &[("ThematicBreak", "***")]);
    assert_spans("_ _ _", &[("ThematicBreak", "_ _ _")]);
}

#[test]
fn hard_breaks() {
    assert_spans("a  \nb", &[("HardBreak", "  \n")]);
    assert_spans("a\\\nb", &[("HardBreak", "\\\n"), ("Markup", "\\")]);
}

#[test]
fn html_block_and_inline() {
    assert_spans("<div>\nx\n</div>\n", &[("Html", "<div>\nx\n</div>")]);
    assert_spans("a <b>c</b>", &[("Html", "<b>"), ("Html", "</b>")]);
    assert_spans("<!-- c -->\n", &[("Html", "<!-- c -->")]);
}

// ---------- escapes ----------

#[test]
fn backslash_escapes() {
    assert_spans("\\*a\\*", &[("Markup", "\\"), ("Markup", "\\")]);
    // An escaped backslash is one escape, and the following char is not escaped.
    assert_spans("\\\\*a*", &[("Markup", "\\"), ("Emphasis", "*a*"), ("Markup", "*"), ("Markup", "*")]);
    // A backslash before a letter is not an escape.
    assert_spans("a\\b", &[]);
}

#[test]
fn escape_markup_is_owned_by_the_two_characters() {
    let doc = Document::new("x \\# y", OffsetEncoding::Utf8);
    let m = doc.markup_spans(None);
    assert_eq!(m.len(), 1);
    assert_eq!(m[0].range, TextRange::new(2, 3));
    assert_eq!(m[0].owner, TextRange::new(2, 4));
    assert_eq!(m[0].scope, MarkupScope::Inline);
}

// ---------- front matter ----------

#[test]
fn front_matter() {
    let t = "---\ntitle: x\n---\n\n# H";
    assert_spans(
        t,
        &[
            ("FrontMatter", "---\ntitle: x\n---"),
            ("Markup", "---"),
            ("Markup", "---"),
            ("Heading1", "# H"),
            ("Markup", "# "),
        ],
    );
}

#[test]
fn front_matter_content_is_not_markdown() {
    let t = "---\n# not heading: *x*\n---\n";
    assert_spans(t, &[("FrontMatter", "---\n# not heading: *x*\n---"), ("Markup", "---"), ("Markup", "---")]);
}

#[test]
fn leading_rule_without_closing_is_not_front_matter() {
    assert_spans("---\ntext", &[("ThematicBreak", "---")]);
}

// ---------- tables ----------

#[test]
fn table_pipes_and_delimiter_row() {
    let t = "| a | b |\n|---|:-:|\n| 1 | 2 |";
    assert_spans(
        t,
        &[
            ("Table", t),
            ("Markup", "|"),
            ("Markup", "|"),
            ("Markup", "|"),
            ("TableDelimiterRow", "|---|:-:|"),
            ("Markup", "|"),
            ("Markup", "|"),
            ("Markup", "|"),
            ("Markup", "|"),
            ("Markup", "|"),
            ("Markup", "|"),
        ],
    );
}

#[test]
fn table_without_outer_pipes() {
    let t = "a | b\n--|--\n1 | 2";
    let s = spans_of(t);
    assert_eq!(s[0], ("Table".into(), t.into()));
    assert!(s.contains(&("TableDelimiterRow".into(), "--|--".into())));
    assert_eq!(markup_texts(t).len(), 3);
}

#[test]
fn table_inline_markup_and_escaped_pipe() {
    let t = "| `c` | **b** \\| x |\n|--|--|\n";
    let s = spans_of(t);
    assert!(s.contains(&("InlineCode".into(), "`c`".into())));
    assert!(s.contains(&("Strong".into(), "**b**".into())));
    // `\|` inside a cell is an escape, not a cell separator.
    assert!(s.contains(&("Markup".into(), "\\".into())));
}

#[test]
fn table_markup_is_flagged_in_table() {
    let t = "| *a* | b |\n|---|---|\n\nout *of* table";
    let doc = Document::new(t, OffsetEncoding::Utf8);
    let m = doc.markup_spans(None);
    let in_table: Vec<_> = m.iter().filter(|m| m.in_table).collect();
    let outside: Vec<_> = m.iter().filter(|m| !m.in_table).collect();
    // pipes (3 + 3) and the two `*` of the cell
    assert_eq!(in_table.len(), 8);
    assert_eq!(outside.len(), 2);
    assert!(outside.iter().all(|m| m.scope == MarkupScope::Inline));
    assert!(m.iter().filter(|m| m.in_table && t[m.range.start as usize..m.range.end as usize] == *"|").all(|m| m.scope == MarkupScope::Block));
}

#[test]
fn table_inside_block_quote() {
    let t = "> | a | b |\n> |---|---|\n> | 1 | 2 |";
    let s = spans_of(t);
    assert!(s.contains(&("Table".into(), "| a | b |\n> |---|---|\n> | 1 | 2 |".into())));
    assert!(s.contains(&("TableDelimiterRow".into(), "|---|---|".into())));
    assert_eq!(texts(t, "Markup").iter().filter(|m| m.as_str() == "> ").count(), 3);
}

// ---------- footnotes ----------

#[test]
fn footnote_reference_and_definition() {
    let t = "text[^1]\n\n[^1]: The *body*.";
    assert_spans(
        t,
        &[
            ("FootnoteReference", "[^1]"),
            ("Markup", "[^"),
            ("Markup", "]"),
            ("FootnoteDefinition", "[^1]: The *body*."),
            ("Markup", "[^"),
            ("Markup", "]:"),
            ("Emphasis", "*body*"),
            ("Markup", "*"),
            ("Markup", "*"),
        ],
    );
}

#[test]
fn footnote_with_named_label() {
    let t = "a[^note]\n\n[^note]: x";
    let s = spans_of(t);
    assert!(s.contains(&("FootnoteReference".into(), "[^note]".into())));
    assert!(s.contains(&("FootnoteDefinition".into(), "[^note]: x".into())));
}

// ---------- owners and scopes (Live mode groundwork) ----------

#[test]
fn inline_markup_is_owned_by_its_element() {
    let t = "x *a* y";
    let doc = Document::new(t, OffsetEncoding::Utf8);
    let m = doc.markup_spans(None);
    assert_eq!(m.len(), 2);
    for m in m {
        assert_eq!(m.owner, TextRange::new(2, 5));
        assert_eq!(m.scope, MarkupScope::Inline);
        assert!(!m.in_table);
    }
}

#[test]
fn block_markup_scopes() {
    let t = "# H\n\n> q\n\n```\nc\n```\n\nSetext\n===";
    let doc = Document::new(t, OffsetEncoding::Utf8);
    let m = doc.markup_spans(None);
    let by = |s: &str| -> MarkupSpan {
        *m.iter()
            .find(|m| &t[m.range.start as usize..m.range.end as usize] == s)
            .unwrap_or_else(|| panic!("no markup {s:?}"))
    };
    let h = by("# ");
    assert_eq!((h.scope, h.owner), (MarkupScope::Line, TextRange::new(0, 3)));
    let q = by("> ");
    assert_eq!((q.scope, q.owner), (MarkupScope::Line, TextRange::new(5, 8)));
    let f = by("```");
    assert_eq!(f.scope, MarkupScope::Line);
    let u = by("===");
    assert_eq!(u.scope, MarkupScope::Block);
    assert_eq!(&t[u.owner.start as usize..u.owner.end as usize], "Setext\n===");
}

// ---------- line endings ----------

#[test]
fn crlf_document() {
    let t = "# H\r\n\r\n> a\r\n> b\r\n\r\n```\r\nx\r\n```\r\n\r\n- [x] t\r\n";
    let s = spans_of(t);
    assert!(s.contains(&("Heading1".into(), "# H".into())));
    assert!(s.contains(&("BlockQuote".into(), "> a\r\n> b".into())));
    assert!(s.contains(&("CodeBlock".into(), "```\r\nx\r\n```".into())));
    assert_eq!(texts(t, "Markup").iter().filter(|m| m.as_str() == "> ").count(), 2);
    assert_eq!(texts(t, "Markup").iter().filter(|m| m.as_str() == "```").count(), 2);
    assert!(s.contains(&("TaskChecked".into(), "[x]".into())));
}

#[test]
fn lone_cr_line_endings() {
    let t = "# H\r> a\r> b";
    let s = spans_of(t);
    assert!(s.contains(&("Heading1".into(), "# H".into())));
    assert_eq!(texts(t, "Markup").iter().filter(|m| m.as_str() == "> ").count(), 2);
}

// ---------- blocks ----------

fn blocks_of(t: &str) -> Vec<(BlockKind, String, u32, Option<u8>, u8)> {
    let d = Document::new(t, OffsetEncoding::Utf8);
    d.blocks()
        .into_iter()
        .map(|b| (b.kind, t[b.range.start as usize..b.range.end as usize].to_owned(), b.line, b.heading_level, b.depth))
        .collect()
}

#[test]
fn blocks_basic() {
    let t = "# H\n\npara\ntwo\n\n```\nc\n```\n\n---\n\n<div>x</div>\n\n| a |\n|---|\n";
    assert_eq!(
        blocks_of(t),
        vec![
            (BlockKind::Heading, "# H".into(), 0, Some(1), 0),
            (BlockKind::Paragraph, "para\ntwo".into(), 2, None, 0),
            (BlockKind::CodeBlock, "```\nc\n```".into(), 5, None, 0),
            (BlockKind::ThematicBreak, "---".into(), 9, None, 0),
            (BlockKind::HtmlBlock, "<div>x</div>".into(), 11, None, 0),
            (BlockKind::Table, "| a |\n|---|".into(), 13, None, 0),
        ]
    );
}

#[test]
fn blocks_containers_set_depth() {
    let t = "> q\n>\n> - a\n>   - b\n\n- tight\n\n[^1]: note\n";
    assert_eq!(
        blocks_of(t),
        vec![
            (BlockKind::Paragraph, "q".into(), 0, None, 1),
            (BlockKind::Paragraph, "a".into(), 2, None, 2),
            (BlockKind::Paragraph, "b".into(), 3, None, 3),
            (BlockKind::Paragraph, "tight".into(), 5, None, 1),
            (BlockKind::Paragraph, "note".into(), 7, None, 1),
        ]
    );
}

#[test]
fn blocks_front_matter_and_setext() {
    let t = "---\na: 1\n---\nTitle\n===\n";
    assert_eq!(
        blocks_of(t),
        vec![
            (BlockKind::FrontMatter, "---\na: 1\n---".into(), 0, None, 0),
            (BlockKind::Heading, "Title\n===".into(), 3, Some(1), 0),
        ]
    );
}

#[test]
fn blocks_loose_and_tight_list_items() {
    let t = "- a\n- b\n\n- c\n\n  d\n";
    let b = blocks_of(t);
    let texts: Vec<_> = b.iter().map(|b| b.1.as_str()).collect();
    assert_eq!(texts, vec!["a", "b", "c", "d"]);
    assert!(b.iter().all(|b| b.4 == 1 && b.0 == BlockKind::Paragraph));
}

#[test]
fn blocks_are_empty_for_empty_document() {
    assert!(Document::new("", OffsetEncoding::Utf16).blocks().is_empty());
    assert!(Document::new("\n\n", OffsetEncoding::Utf16).spans(None).is_empty());
}

// ---------- prose ----------

fn prose_of(t: &str) -> Vec<String> {
    let d = Document::new(t, OffsetEncoding::Utf8);
    d.prose_ranges(None).into_iter().map(|r| t[r.start as usize..r.end as usize].to_owned()).collect()
}

#[test]
fn prose_excludes_markup_code_destinations_html_and_front_matter() {
    let t = "---\ntitle: x\n---\n\n# Head *em*\n\nSee [the docs](http://x.y) and `code` <b>bold</b> <http://auto.link>.\n\n```\ncode block\n```\n\n- [x] done item\n\n> quoted text\n\n| cell one | two |\n|---|---|\n\n[^1]: footnote body\n\n![alt text](p.png)\n\n<div>html block</div>\n";
    assert_eq!(
        prose_of(t),
        vec![
            "Head ", "em", "See ", "the docs", " and ", " ", "bold", " ", ".", "done item", "quoted text", "cell one", "two",
            "footnote body",
        ]
        .into_iter()
        .map(String::from)
        .collect::<Vec<_>>()
    );
}

#[test]
fn prose_merges_adjacent_pieces() {
    // Entities and plain text can be split into several text events; they merge back.
    assert_eq!(prose_of("a &amp; b &lt; c"), vec!["a &amp; b &lt; c"]);
    assert_eq!(prose_of("one\ntwo"), vec!["one", "two"]);
}

#[test]
fn prose_within_is_clipped() {
    let t = "aaa **bbb** ccc";
    let d = Document::new(t, OffsetEncoding::Utf8);
    assert_eq!(d.prose_ranges(Some(TextRange::new(2, 8))), vec![TextRange::new(2, 4), TextRange::new(6, 8)]);
    assert!(d.prose_ranges(Some(TextRange::new(4, 6))).is_empty());
}

// ---------- images ----------

#[test]
fn images_list() {
    let t = "![a *b*](x.png \"T\")\n\ntext ![c](<y z.png>) text\n\n[![d](e)](f)\n\n- ![g](h)\n\n![ref][r]\n\n[r]: i.png\n";
    let d = Document::new(t, OffsetEncoding::Utf8);
    let ims = d.images();
    let view: Vec<_> = ims
        .iter()
        .map(|i| {
            (
                t[i.range.start as usize..i.range.end as usize].to_owned(),
                i.destination.as_str(),
                i.alt.as_str(),
                i.title.as_deref(),
                i.standalone,
            )
        })
        .collect();
    assert_eq!(
        view,
        vec![
            ("![a *b*](x.png \"T\")".to_owned(), "x.png", "a b", Some("T"), true),
            ("![c](<y z.png>)".to_owned(), "y z.png", "c", None, false),
            ("![d](e)".to_owned(), "e", "d", None, false),
            ("![g](h)".to_owned(), "h", "g", None, true),
            ("![ref][r]".to_owned(), "i.png", "ref", None, true),
        ]
    );
}

#[test]
fn image_with_trailing_text_or_two_images_is_not_standalone() {
    let d = Document::new("![a](b) x\n\n![a](b)![c](d)\n\n![a](b)\n![c](d)", OffsetEncoding::Utf8);
    assert!(d.images().iter().all(|i| !i.standalone));
}

// ---------- span queries ----------

#[test]
fn spans_within_returns_intersecting() {
    let t = "aa *b* cc `d` ee";
    let d = Document::new(t, OffsetEncoding::Utf8);
    let all = d.spans(None);
    assert_eq!(all.len(), 6);
    // Window covering only the code span.
    let w = d.spans(Some(TextRange::new(10, 13)));
    assert_eq!(w.iter().map(|s| s.kind).collect::<Vec<_>>(), vec![SpanKind::InlineCode, SpanKind::Markup, SpanKind::Markup]);
    // Touching but not overlapping excludes.
    assert!(d.spans(Some(TextRange::new(0, 3))).is_empty());
    // A window inside Emphasis picks the element and no markup.
    let w = d.spans(Some(TextRange::new(4, 5)));
    assert_eq!(w.len(), 1);
    assert_eq!(w[0].kind, SpanKind::Emphasis);
    // Empty window selects the spans containing the position.
    let w = d.spans(Some(TextRange::new(4, 4)));
    assert_eq!(w.len(), 1);
    // Inverted or out-of-range windows are empty, never a panic.
    assert!(d.spans(Some(TextRange::new(9, 3))).is_empty());
    assert!(d.spans(Some(TextRange::new(100, 200))).is_empty());
}

// ---------- regressions found by the M1 test pass (oracle.rs found most of them) ----------

#[test]
fn hash_without_space_starts_a_setext_heading_not_an_atx_one() {
    assert_spans("#foo\n===", &[("Heading1", "#foo\n==="), ("Markup", "===")]);
}

#[test]
fn closing_hashes_follow_pulldown_cmark() {
    // After a tab the `#` is content in pulldown-cmark (and so in the preview).
    assert_spans("## a\t#", &[("Heading2", "## a\t#"), ("Markup", "## ")]);
    assert_spans("## a #", &[("Heading2", "## a #"), ("Markup", "## "), ("Markup", "#")]);
}

#[test]
fn inline_element_at_the_end_of_a_heading_with_a_trailing_tab() {
    // pulldown-cmark extends the emphasis over the tab; the span must stop at the `*`.
    assert_spans(
        "# *a*\t",
        &[("Heading1", "# *a*"), ("Markup", "# "), ("Emphasis", "*a*"), ("Markup", "*"), ("Markup", "*")],
    );
    assert_spans("# `a`\t", &[("Heading1", "# `a`"), ("Markup", "# "), ("InlineCode", "`a`"), ("Markup", "`"), ("Markup", "`")]);
}

#[test]
fn list_items_nested_with_a_tab_have_markers() {
    assert_spans("- a\n\t- b\n", &[("BulletMarker", "-"), ("BulletMarker", "-")]);
    assert_eq!(texts("- [x] a\n\t- [ ] b\n", "BulletMarker").len(), 2);
    assert_spans(">\t- x", &[("BlockQuote", ">\t- x"), ("Markup", ">"), ("BulletMarker", "-")]);
}

#[test]
fn multi_line_link_reference_definition() {
    let t = "   [foo]: \n      /url  \n           'the title'  \n\n[foo]";
    assert_eq!(
        spans_of(t)[..4],
        [
            ("Markup".into(), "[".into()),
            ("Markup".into(), "]:".into()),
            ("LinkDestination".into(), "/url".into()),
            ("LinkDestination".into(), "'the title'".into()),
        ]
    );
}

#[test]
fn link_reference_definition_in_a_block_quote_over_lines() {
    let t = "> [foo]:\n> /url\n> \"t\"\n\n[foo]";
    assert_eq!(
        spans_of(t)[..8],
        [
            ("BlockQuote".into(), "> [foo]:\n> /url\n> \"t\"".into()),
            ("Markup".into(), "> ".into()),
            ("Markup".into(), "[".into()),
            ("Markup".into(), "]:".into()),
            ("Markup".into(), "> ".into()),
            ("LinkDestination".into(), "/url".into()),
            ("Markup".into(), "> ".into()),
            ("LinkDestination".into(), "\"t\"".into()),
        ]
    );
}

#[test]
fn duplicate_link_reference_definitions_are_marked_too() {
    // pulldown-cmark keeps only the first; the second is still a definition, not text.
    assert_eq!(texts("[a]: /u\n[a]: /v \"t\"\n\n[a]", "LinkDestination"), ["/u", "/v \"t\""]);
    assert_eq!(texts("1. [r]: /u\n1. [r]: /v\n\n[r]", "LinkDestination"), ["/u", "/v"]);
    assert_eq!(texts("[a]: /u\n[a]: /v\n\"t\"\n\n[a]", "LinkDestination"), ["/u", "/v", "\"t\""]);
}

#[test]
fn greater_than_on_a_lazy_indented_line_is_text() {
    assert_spans("> a\n    > b", &[("BlockQuote", "> a\n    > b"), ("Markup", "> ")]);
}

#[test]
fn block_quote_inside_a_footnote_definition() {
    let t = "[^1]: > quoted\n\n[^1]";
    assert_eq!(
        spans_of(t)[..5],
        [
            ("FootnoteDefinition".into(), "[^1]: > quoted".into()),
            ("Markup".into(), "[^".into()),
            ("Markup".into(), "]:".into()),
            ("BlockQuote".into(), "> quoted".into()),
            ("Markup".into(), "> ".into()),
        ]
    );
}

#[test]
fn link_destination_across_quoted_lines() {
    let t = "> [a](\n> /url\n> )";
    assert_spans(
        t,
        &[
            ("BlockQuote", t),
            ("Markup", "> "),
            ("Link", "[a](\n> /url\n> )"),
            ("Markup", "["),
            ("Markup", "]("),
            ("Markup", "> "),
            ("LinkDestination", "/url"),
            ("Markup", "> "),
            ("Markup", ")"),
        ],
    );
}

#[test]
fn markup_never_contains_a_line_break() {
    // Concealing a line break in Live mode would join two lines.
    for t in ["[a](\n/url\n)", "![](x\n)", "[a](/url\n\"t\"\n)", "> [a](\n> /u\n> )"] {
        for (k, s) in spans_of(t) {
            assert!(k != "Markup" || !s.contains(['\n', '\r']), "{t:?}: markup {s:?}");
        }
    }
}

#[test]
fn collapsed_reference_inside_a_reference_image() {
    let t = "[r]: /u\n![[r][]][r]";
    let s = spans_of(t);
    assert!(s.contains(&("Link".into(), "[r][]".into())));
    assert!(s.contains(&("Markup".into(), "][]".into())));
    assert!(s.contains(&("Markup".into(), "][".into())), "{s:?}");
}

#[test]
fn reference_label_after_an_escaped_bracket() {
    // pulldown-cmark reads `[r]\[r]` as a reference link with label `r`.
    let t = "[r]: /u\n\n[r]\\[r]";
    let s = spans_of(t);
    assert!(s.contains(&("Link".into(), "[r]\\[r]".into())));
    assert!(s.contains(&("Markup".into(), "]\\[".into())), "{s:?}");
    assert!(s.contains(&("LinkDestination".into(), "r".into())));
}

#[test]
fn long_backslash_runs_keep_escape_parity() {
    // An odd run escapes the `*`; an earlier version only looked back 1024 backslashes.
    for n in [1usize, 2, 3, 2047, 2048, 2049] {
        let t = format!("{}*a*", "\\".repeat(n));
        let emphasis = !texts(&t, "Emphasis").is_empty();
        assert_eq!(emphasis, n % 2 == 0, "{n} backslashes");
        assert_eq!(markup_texts(&t).iter().filter(|m| *m == "\\").count(), n.div_ceil(2), "{n}");
    }
}

#[test]
fn metadata_block_without_a_closing_delimiter() {
    // pulldown-cmark ends this one at the end of the list item; there is no closing `---`.
    let t = "* ---\n\t* <http://a.b>\n---\nword";
    let s = spans_of(t);
    assert!(!s.iter().any(|(k, x)| k == "Markup" && x.contains("http")), "{s:?}");
}

#[test]
fn a_picture_is_standalone_only_as_a_paragraph_of_its_own() {
    let standalone = |t: &str| {
        let d = Document::new(t, OffsetEncoding::Utf8);
        d.images().iter().map(|i| i.standalone).collect::<Vec<_>>()
    };
    for t in ["![a](b)", "  ![a](b)  ", "![a](b)\n", "![a](b)  \n", "x\n\n![a](b)\n\ny", "![a](b)\r\n\r\ny", "- ![a](b)", "> ![a](b)"] {
        assert_eq!(standalone(t), vec![true], "{t:?}");
    }
    for t in [
        "A smaller one, and one inside a sentence ![tiny](img/small.png) like this.",
        "A smaller one, and one inside a sentence ![tiny](img/small.png) like this.\r\n",
        "![a](b) text", "text ![a](b)", "a\n![a](b)\nb", "- a ![a](b) b", "# H ![a](b)", "**![a](b)**", "![a](b) <b>x</b>",
    ] {
        assert_eq!(standalone(t), vec![false], "{t:?}");
    }
}
