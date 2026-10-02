//! Dirty ranges: hand-written cases (property-based soundness lives in properties.rs).
mod common;
use common::*;
use markdown_core::*;

fn edit(text: &str, at: (u32, u32), with: &str) -> TextRange {
    check_edit(text, OffsetEncoding::Utf8, TextRange::new(at.0, at.1), with)
        .unwrap_or_else(|e| panic!("{e}"))
        .dirty
}

fn lines(text: &str, r: TextRange) -> &str {
    &text[r.start as usize..r.end as usize]
}

#[test]
fn typing_a_letter_in_a_paragraph_reports_that_line() {
    let t = "para one\n\npara two\n\npara three\n";
    let d = edit(t, (12, 12), "x");
    let new = "para one\n\npaxra two\n\npara three\n";
    assert_eq!(lines(new, d), "paxra two\n");
}

#[test]
fn typing_in_the_middle_of_emphasis_stays_local() {
    let t = "intro\n\nsome *emph here* and `code`\n\ntail *x*\n";
    let d = edit(t, (14, 14), "Z");
    let new = "intro\n\nsome *emZph here* and `code`\n\ntail *x*\n";
    assert_eq!(lines(new, d), "some *emZph here* and `code`\n");
}

#[test]
fn typing_a_closing_marker_reports_the_new_span() {
    let t = "a *b c\n\nz\n";
    let d = edit(t, (6, 6), "*");
    assert_eq!(lines("a *b c*\n\nz\n", d), "a *b c*\n");
}

#[test]
fn opening_a_code_fence_reports_everything_to_the_end() {
    let t = "intro\n\n\n\n# Heading\n\n*emph* and **strong**\n\n> quote\n";
    let d = edit(t, (7, 7), "```");
    let new = "intro\n\n```\n\n# Heading\n\n*emph* and **strong**\n\n> quote\n";
    assert_eq!(d.start, 7);
    assert_eq!(d.end as usize, new.len());
}

#[test]
fn closing_a_fence_reports_the_range_that_changes() {
    let t = "```\ncode *x*\n\n# H\n\ntext *y*\n";
    // Type a closing fence after the code line: the heading and text become markdown again.
    let d = edit(t, (13, 13), "```\n");
    let new = "```\ncode *x*\n```\n\n# H\n\ntext *y*\n";
    assert!(d.start <= 13);
    assert!(lines(new, d).contains("```"));
}

#[test]
fn deleting_a_closing_fence_reports_the_tail() {
    let t = "text\n\n```\ncode\n```\n\n*after* and more\n\nlast *one*\n";
    let d = edit(t, (15, 19), "");
    let new = "text\n\n```\ncode\n\n*after* and more\n\nlast *one*\n";
    assert_eq!(d.end as usize, new.len());
}

#[test]
fn typing_in_a_block_quote_does_not_dirty_the_rest_of_the_document() {
    let t = "> line one\n> line two\n> line three\n\nafter *x*\n";
    let d = edit(t, (14, 14), "Q");
    let new = "> line one\n> lQine two\n> line three\n\nafter *x*\n";
    assert_eq!(lines(new, d), "> lQine two\n");
}

#[test]
fn typing_in_a_list_item_is_local() {
    let t = "- one\n- two\n- three\n";
    let d = edit(t, (9, 9), "!");
    assert_eq!(lines("- one\n- tw!o\n- three\n", d), "- tw!o\n");
}

#[test]
fn inserting_a_newline_splits_a_heading() {
    let t = "# Title here\n\nbody\n";
    let d = edit(t, (7, 7), "\n");
    assert!(d.start == 0);
}

#[test]
fn deleting_a_character_reports_its_line() {
    let t = "aaa\nbbb\nccc\n";
    let d = edit(t, (5, 6), "");
    assert_eq!(lines("aaa\nbb\nccc\n", d), "bb\n");
}

#[test]
fn replacing_across_lines() {
    let t = "one *two*\nthree\nfour\n";
    let d = edit(t, (4, 17), "X");
    assert_eq!(lines("one Xour\n", d), "one Xour\n");
}

#[test]
fn no_op_edit_is_cheap_but_sound() {
    let t = "a *b*\n\nc\n";
    let u = check_edit(t, OffsetEncoding::Utf8, TextRange::new(2, 2), "").unwrap();
    assert!(u.dirty.end - u.dirty.start <= 6);
}

#[test]
fn edit_on_the_last_line_without_newline() {
    let t = "a\n\nlast *x*";
    let d = edit(t, (10, 10), "!");
    assert_eq!(lines("a\n\nlast *x*!", d), "last *x*!");
}

#[test]
fn empty_document_edits() {
    let u = check_edit("", OffsetEncoding::Utf16, TextRange::new(0, 0), "# hi").unwrap();
    assert_eq!(u.dirty, TextRange::new(0, 4));
    let u = check_edit("# hi", OffsetEncoding::Utf16, TextRange::new(0, 4), "").unwrap();
    assert_eq!(u.dirty, TextRange::new(0, 0));
}

#[test]
fn utf16_dirty_range_is_in_utf16_units() {
    let t = "\u{1F389}\u{1F389} intro\n\n*e* \u{1F389} text\n";
    let b = boundaries(t, OffsetEncoding::Utf16);
    let at = b[b.len() - 3];
    let u = check_edit(t, OffsetEncoding::Utf16, TextRange::new(at, at), "x").unwrap();
    // the edited line starts after 4 + 6 units of text and two newlines
    assert_eq!(u.dirty.start, 12);
}

#[test]
fn revision_increments_per_edit() {
    let mut d = Document::new("a", OffsetEncoding::Utf8);
    assert_eq!(d.revision(), 0);
    assert_eq!(d.replace(TextRange::new(1, 1), "b").unwrap().revision, 1);
    assert_eq!(d.replace(TextRange::new(2, 2), "c").unwrap().revision, 2);
    assert_eq!(d.set_text("z").revision, 3);
    assert!(d.replace(TextRange::new(5, 5), "c").is_err());
    assert_eq!(d.revision(), 3);
}

// ---------- edits that change structure far from the edit ----------

/// Filler paragraphs that keep the interesting lines apart.
fn filler(n: usize) -> String {
    (0..n).map(|i| format!("Paragraph {i} with *some* text.\n\n")).collect()
}

#[test]
fn adding_a_definition_turns_an_earlier_reference_into_a_link() {
    let t = format!("See [the docs][ref] first.\n\n{}", filler(50));
    let at = t.len() as u32;
    let d = edit(&t, (at, at), "[ref]: https://example.com\n");
    // The reference on line 0 changed kind although the edit is 50 paragraphs away.
    assert_eq!(d.start, 0);
}

#[test]
fn removing_a_definition_turns_a_link_back_into_text() {
    let t = format!("See [the docs][ref] first.\n\n{}[ref]: /u\n", filler(30));
    let def = t.find("[ref]: /u").unwrap() as u32;
    let d = edit(&t, (def, t.len() as u32), "");
    assert_eq!(d.start, 0);
}

#[test]
fn starting_front_matter_restyles_the_block_it_creates() {
    let t = format!("title: x\ntags: y\n---\n\n{}", filler(20));
    let d = edit(&t, (0, 0), "---\n");
    let new = format!("---\n{t}");
    // What was a setext heading is now front matter.
    assert!(lines(&new, d).starts_with("---\ntitle: x\ntags: y\n---"));
}

#[test]
fn setext_underline_restyles_the_paragraph_above() {
    let t = format!("{}first line\nsecond line\n\n{}", filler(5), filler(5));
    let at = (t.find("second line\n").unwrap() + "second line\n".len()) as u32;
    let d = edit(&t, (at, at), "===\n");
    let new = format!("{}===\n{}", &t[..at as usize], &t[at as usize..]);
    assert!(lines(&new, d).starts_with("first line\nsecond line\n==="), "{:?}", lines(&new, d));
}

#[test]
fn delimiter_row_turns_the_line_above_into_a_table_header() {
    let t = format!("{}| a | b |\n| 1 | 2 |\n\n{}", filler(5), filler(5));
    let at = (t.find("| 1 |").unwrap()) as u32;
    let d = edit(&t, (at, at), "|---|---|\n");
    let new = format!("{}|---|---|\n{}", &t[..at as usize], &t[at as usize..]);
    assert!(lines(&new, d).starts_with("| a | b |\n|---|---|\n| 1 | 2 |"), "{:?}", lines(&new, d));
}

#[test]
fn opening_a_fence_far_above_restyles_to_the_end() {
    let t = format!("intro\n\n{}", filler(40));
    let d = edit(&t, (7, 7), "~~~\n");
    let new = format!("intro\n\n~~~\n{}", &t[7..]);
    assert_eq!(d.start, 7);
    // Everything up to the trailing blank line, which has no spans.
    assert_eq!(&new[d.end as usize..], "\n");
}

#[test]
fn deleting_the_only_closing_fence_restyles_to_the_end() {
    let t = format!("```\ncode\n```\n\n{}", filler(20));
    let d = edit(&t, (9, 13), "");
    let new = format!("{}{}", &t[..9], &t[13..]);
    assert_eq!(&new[d.end as usize..], "\n");
}

#[test]
fn starting_a_block_quote_marks_lazy_lines() {
    let t = format!("{}line one\nline two\nline three\n\n{}", filler(3), filler(3));
    let at = t.find("line one").unwrap() as u32;
    let d = edit(&t, (at, at), "> ");
    let new = format!("{}> {}", &t[..at as usize], &t[at as usize..]);
    assert!(lines(&new, d).starts_with("> line one\nline two\nline three"));
}
