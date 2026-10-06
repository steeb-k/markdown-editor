//! The outline: a document's headings, from the block index.
mod common;
use common::*;
use markdown_core::*;

fn outline(text: &str) -> Vec<(u8, String, String, u32)> {
    let d = Document::new(text, OffsetEncoding::Utf8);
    d.outline().into_iter().map(|e| (e.level, e.text, slice_units(text, OffsetEncoding::Utf8, e.range), e.line)).collect()
}

fn texts(text: &str) -> Vec<String> {
    outline(text).into_iter().map(|e| e.1).collect()
}

#[test]
fn atx_and_setext_headings_with_their_levels_ranges_and_lines() {
    let t = "# One\n\ntext\n\n## Two ##\n\nThree\n=====\n\nFour\n----\n\n###### Six\n";
    assert_eq!(
        outline(t),
        vec![
            (1, "One".into(), "# One".into(), 0),
            (2, "Two".into(), "## Two ##".into(), 4),
            (1, "Three".into(), "Three\n=====".into(), 6),
            (2, "Four".into(), "Four\n----".into(), 9),
            (6, "Six".into(), "###### Six".into(), 12),
        ]
    );
}

#[test]
fn inline_markup_is_stripped_like_the_renderers_plain_text() {
    assert_eq!(texts("# A **bold** and *em* and `code` and ~~gone~~\n"), vec!["A bold and em and code and gone"]);
    assert_eq!(texts("# A [link](http://x.y \"t\") and ![alt text](p.png) and <b>html</b>\n"), vec!["A link and alt text and html"]);
    assert_eq!(texts("# R&amp;D \\*not em\\* &copy;\n"), vec!["R&D *not em* \u{a9}"]);
    assert_eq!(texts("Two\nlines\n===\n"), vec!["Two lines"]);
    assert_eq!(texts("#\n\n#   \n\n# \\#\n"), vec!["", "", "#"]);
    assert_eq!(texts("#    spaced   out   \n"), vec!["spaced   out"]);
}

#[test]
fn the_text_agrees_with_the_ids_the_renderer_makes() {
    for t in ["# Title\n\n## A `b` **c**\n\n### ![x](y) z\n\n#### [l](u) *m*\n", "Setext *one*\n===\n\nAnother & more\n---\n"] {
        let d = Document::new(t, OffsetEncoding::Utf8);
        let html = d.render_html(&RenderOptions::default());
        for e in d.outline() {
            assert!(html.contains(&format!("id=\"{}\"", slug(&e.text))), "{:?} in {html}", e.text);
        }
    }
}

#[test]
fn a_wikilink_in_a_heading_gets_the_same_id_in_the_preview_as_the_outline() {
    let t = "# See [[Other|the other]]\n\n# [[Other]]\n\n# [[Other#Sec|]]\n\n# [[Other#Sec]]\n\n# In [a [[Other|link]]](u) and `[[Other|code]]`\n\n# Bare http://a.b/[[x|y]] url\n";
    let d = Document::new(t, OffsetEncoding::Utf8);
    let html = d.render_html(&RenderOptions::default());
    let entries = d.outline();
    assert_eq!(entries.len(), 6);
    assert_eq!(entries[0].text, "See the other");
    assert_eq!(entries[1].text, "Other");
    for e in &entries {
        assert!(
            html.contains(&format!("id=\"{}\"", slug(&e.text)))
                || html.contains(&format!("id=\"{}-", slug(&e.text))),
            "{:?} in {html}",
            e.text
        );
    }
    // The ids themselves, not just that something matches.
    assert!(html.contains("id=\"see-the-other\""), "{html}");
    assert!(html.contains("<h1 id=\"other\">"), "{html}");
    // Inside a link or a code span the brackets stay literal.
    assert!(
        entries[4].text.contains("[[Other|code]]") && !entries[4].text.contains('`'),
        "{:?}",
        entries[4].text
    );
    assert!(
        html.contains(&format!("id=\"{}\"", slug(&entries[4].text))),
        "{html}"
    );
}

#[test]
fn a_setext_heading_continuing_after_a_reference_definition_reads_as_the_renderer_does() {
    let t = "[r]: /u\n\t# Title\n===\n";
    assert_eq!(texts(t), vec!["# Title"]);
    let html = Document::new(t, OffsetEncoding::Utf8).render_html(&RenderOptions::default());
    assert!(
        html.contains("<h1 id=\"-title\">") && html.contains("># Title</h1>"),
        "{html}"
    );
    // Without the definition it is an indented code block and a paragraph: no heading.
    assert!(texts("\t# Title\n===\n").is_empty());
    // A plain `# Title` over `===` is an ATX heading and a paragraph.
    assert_eq!(texts("# Title\n===\n"), vec!["Title"]);
    // Other block markers the continuation hides in the same way.
    assert_eq!(texts("[r]: /u\n\t- item\n---\n"), vec!["- item"]);
    assert_eq!(texts("[r]: /u\n\t> q\n---\n"), vec!["> q"]);
}

#[test]
fn headings_in_lists_and_quotes_are_headings() {
    let t = "- # In a list\n\n  text\n\n> ## In a quote\n\n> Setext\n> in a quote\n> ---\n\n1. 1. ### Nested\n";
    assert_eq!(
        outline(t).iter().map(|e| (e.0, e.1.as_str())).collect::<Vec<_>>(),
        vec![(1, "In a list"), (2, "In a quote"), (2, "Setext in a quote"), (3, "Nested")]
    );
}

#[test]
fn what_only_looks_like_a_heading_is_not_one() {
    let t = "```\n# in a fence\n```\n\n    # indented code\n\n<div>\n# in html\n</div>\n\n---\ntitle: x\n# a yaml comment\n---\n\n\\# escaped\n\n#nospace\n\n    ## also code\n\n~~~md\n## tilde\n~~~\n\n- item\n\n  ```\n  # fenced in a list\n  ```\n";
    // (The `---` pair after text is a thematic break and a setext underline; only real headings count.)
    let got = texts(t);
    for bad in ["in a fence", "indented code", "in html", "a yaml comment", "escaped", "nospace", "also code", "tilde", "fenced in a list"] {
        assert!(!got.iter().any(|g| g.contains(bad)), "{bad:?} listed in {got:?}");
    }
    let doc = Document::new("---\ntitle: x\n# a comment\n---\n\n# Real\n", OffsetEncoding::Utf8);
    assert_eq!(doc.outline().iter().map(|e| e.text.as_str()).collect::<Vec<_>>(), vec!["Real"]);
}

#[test]
fn crlf_cr_and_utf16_offsets() {
    let t = "# One\r\n\r\ntext 😀\r\n\r\nTwo\r\n===\r\n\r\n## 😀 Three\r\n";
    let d = Document::new(t, OffsetEncoding::Utf16);
    let got: Vec<_> = d.outline().into_iter().map(|e| (e.text, slice_units(t, OffsetEncoding::Utf16, e.range), e.line)).collect();
    assert_eq!(
        got,
        vec![
            ("One".to_string(), "# One".to_string(), 0),
            ("Two".to_string(), "Two\r\n===".to_string(), 4),
            ("😀 Three".to_string(), "## 😀 Three".to_string(), 7),
        ]
    );
    let lone = Document::new("# a\r# b\rtext\r# c", OffsetEncoding::Utf8);
    assert_eq!(lone.outline().iter().map(|e| (e.text.as_str(), e.line)).collect::<Vec<_>>(), vec![("a", 0), ("b", 1), ("c", 3)]);
}

#[test]
fn an_edit_updates_the_outline_and_an_empty_document_has_none() {
    assert!(Document::new("", OffsetEncoding::Utf8).outline().is_empty());
    assert!(Document::new("just text\n\nmore\n", OffsetEncoding::Utf8).outline().is_empty());
    let mut d = Document::new("# A\n\ntext\n", OffsetEncoding::Utf8);
    d.replace(TextRange::new(10, 10), "\n## New\n").unwrap();
    assert_eq!(d.outline().iter().map(|e| (e.level, e.text.as_str(), e.line)).collect::<Vec<_>>(), vec![(1, "A", 0), (2, "New", 4)]);
    d.replace(TextRange::new(0, 1), "").unwrap();
    assert_eq!(d.outline().iter().map(|e| e.text.as_str()).collect::<Vec<_>>(), vec!["New"]);
}

#[test]
fn a_thousand_headings() {
    let mut t = String::new();
    for i in 0..1000 {
        t.push_str(&format!("{} Heading *{i}* of `many`\n\nA paragraph of text, {i}.\n\n", "#".repeat(1 + i % 6)));
    }
    let d = Document::new(&t, OffsetEncoding::Utf8);
    let t0 = std::time::Instant::now();
    let o = d.outline();
    let took = t0.elapsed();
    assert_eq!(o.len(), 1000);
    assert_eq!(o[0].text, "Heading 0 of many");
    assert_eq!(o[999].text, "Heading 999 of many");
    assert_eq!(o[999].level, 4);
    assert_eq!(o[999].line, 999 * 4);
    assert!(o.windows(2).all(|w| w[0].range.end <= w[1].range.start));
    eprintln!("outline of 1000 headings: {took:?}");
    assert!(took.as_millis() < if cfg!(debug_assertions) { 600 } else { 60 }, "{took:?}");
}

#[test]
fn what_only_the_whole_document_decides_reference_links_footnotes_and_wikilinks() {
    // Found in the test pass: the heading's source parsed alone showed reference links with their brackets and a
    // footnote reference as `[^1]`, and wikilinks as written; the preview and Live mode show the label.
    let t = "# See [foo] and [bar][] and ![img][foo] and [none]\n\n## Note[^1]\n\n### [[Note]], [[Note|Label]], [[#Head]], [[N#H|L]] and `[[code]]`\n\n#### [a [[wiki]] in a link](u)\n\n> Setext with\n> [foo] on its second line[^1]\n> ===\n\n[foo]: http://x\n[bar]: http://y\n[^1]: note\n";
    assert_eq!(
        texts(t),
        vec![
            "See foo and bar and img and [none]",
            "Note",
            "Note, Label, Head, L and [[code]]",
            "a [[wiki]] in a link",
            "Setext with foo on its second line",
        ]
    );
    // The ids are still made from what the renderer's events say (a wikilink's brackets included): the outline's text
    // agrees with them wherever no wikilink is involved.
    let d = Document::new(t, OffsetEncoding::Utf8);
    let html = d.render_html(&RenderOptions::default());
    for e in d.outline().iter().filter(|e| !e.text.contains("Label") && !e.text.contains("wiki")) {
        assert!(html.contains(&format!("id=\"{}\"", slug(&e.text))), "{:?} in {html}", e.text);
    }
}
