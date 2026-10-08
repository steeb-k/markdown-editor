//! `Document::front_matter_template` and `set_front_matter_template`: reading the `template:` key of the front matter
//! and the edit that adds, rewrites or removes it.
use markdown_core::*;
use proptest::prelude::*;

fn doc(text: &str) -> Document {
    Document::new(text, OffsetEncoding::Utf16)
}

fn read(text: &str) -> Option<String> {
    doc(text).front_matter_template()
}

/// The text after applying the edit `set_front_matter_template` returns (the text itself when there is none).
fn set(text: &str, name: Option<&str>) -> Option<String> {
    let mut d = doc(text);
    let edit = d.set_front_matter_template(name)?;
    d.replace(edit.range, &edit.replacement).unwrap();
    Some(d.text().to_owned())
}

#[test]
fn reads_quoted_and_bare_values() {
    assert_eq!(read("---\ntemplate: Academic\n---\nBody\n").as_deref(), Some("Academic"));
    assert_eq!(read("---\ntemplate:   Academic  \n---\n").as_deref(), Some("Academic"));
    assert_eq!(read("---\ntemplate: \"Two Words\"\n---\n").as_deref(), Some("Two Words"));
    assert_eq!(read("---\ntemplate: 'It''s'\n---\n").as_deref(), Some("It's"));
    assert_eq!(read("---\ntemplate: \"a \\\"b\\\"\"\n---\n").as_deref(), Some("a \"b\""));
    assert_eq!(read("---\ntemplate: Letter # my favourite\n---\n").as_deref(), Some("Letter"));
    assert_eq!(read("---\ntitle: T\ntemplate: Letter\ntags: [a]\n---\n").as_deref(), Some("Letter"));
    assert_eq!(read("---\ntemplate: Letter\n...\nBody").as_deref(), Some("Letter"));
}

#[test]
fn reads_through_crlf_and_a_byte_order_mark() {
    assert_eq!(read("---\r\ntemplate: Academic\r\n---\r\nBody\r\n").as_deref(), Some("Academic"));
    assert_eq!(read("\u{feff}---\ntemplate: Academic\n---\n").as_deref(), Some("Academic"));
    assert_eq!(read("\u{feff}---\r\ntemplate: \"A\"\r\n---\r\n").as_deref(), Some("A"));
}

#[test]
fn absent_empty_and_other_keys_read_as_none() {
    assert_eq!(read(""), None);
    assert_eq!(read("Body\n"), None);
    assert_eq!(read("---\ntitle: T\n---\n"), None);
    assert_eq!(read("---\ntemplate:\n---\n"), None);
    assert_eq!(read("---\ntemplate: \"\"\n---\n"), None);
    assert_eq!(read("---\nsubtemplate: X\n  template: X\n# template: X\n---\n"), None);
    // Not at the very start, not closed, or not a block: not front matter.
    assert_eq!(read("\n---\ntemplate: X\n---\n"), None);
    assert_eq!(read("Intro\n---\ntemplate: X\n---\n"), None);
    assert_eq!(read("---\ntemplate: X\n"), None);
    assert_eq!(read("--- x\ntemplate: X\n---\n"), None);
    // After the block, a `template:` line is only text.
    assert_eq!(read("---\ntitle: T\n---\ntemplate: X\n"), None);
}

#[test]
fn add_without_a_block_makes_one() {
    assert_eq!(set("# Title\n", Some("Academic")).as_deref(), Some("---\ntemplate: Academic\n---\n\n# Title\n"));
    // The text already starts with a blank line, or is empty: no second one.
    assert_eq!(set("\n# Title\n", Some("A")).as_deref(), Some("---\ntemplate: A\n---\n\n# Title\n"));
    assert_eq!(set("", Some("A")).as_deref(), Some("---\ntemplate: A\n---\n"));
    // A name that is not a plain YAML scalar is quoted, and reads back.
    let t = set("x", Some("Report: 2024 \"final\"")).unwrap();
    assert!(t.starts_with("---\ntemplate: \"Report: 2024 \\\"final\\\"\"\n---\n"), "{t}");
    assert_eq!(read(&t).as_deref(), Some("Report: 2024 \"final\""));
    // Other horizontal rules at the top are not front matter.
    assert_eq!(set("---\ntext\n", Some("A")).as_deref(), Some("---\ntemplate: A\n---\n\n---\ntext\n"));
}

#[test]
fn add_to_a_block_is_the_last_line() {
    assert_eq!(
        set("---\ntitle: T\ntags: [a]\n---\nBody\n", Some("Letter")).as_deref(),
        Some("---\ntitle: T\ntags: [a]\ntemplate: Letter\n---\nBody\n")
    );
    // An empty block is no block to the parser (two thematic breaks): a block is made in front of them.
    assert_eq!(set("---\n---\nBody\n", Some("Letter")).as_deref(), Some("---\ntemplate: Letter\n---\n\n---\n---\nBody\n"));
    assert_eq!(set("---\ntitle: T\n...\nBody", Some("L")).as_deref(), Some("---\ntitle: T\ntemplate: L\n...\nBody"));
}

#[test]
fn replace_rewrites_the_line_only() {
    assert_eq!(
        set("---\ntitle: T\ntemplate: Old # why\nx: 1\n---\nBody\n", Some("New")).as_deref(),
        Some("---\ntitle: T\ntemplate: New\nx: 1\n---\nBody\n")
    );
    assert_eq!(set("---\ntemplate: \"Old\"\n---\n", Some("New Name")).as_deref(), Some("---\ntemplate: New Name\n---\n"));
    // The range is just the line's text: the unit offsets of text after non-ASCII are right too.
    let mut d = doc("---\ntitle: \u{1F600}\u{e9}\ntemplate: Old\n---\n");
    let e = d.set_front_matter_template(Some("New")).unwrap();
    assert_eq!(e.replacement, "template: New");
    assert_eq!(d.text()[..].encode_utf16().count() as u32 - e.range.end, "\n---\n".len() as u32);
    d.replace(e.range, &e.replacement).unwrap();
    assert_eq!(d.front_matter_template().as_deref(), Some("New"));
}

#[test]
fn no_change_is_none() {
    assert_eq!(set("---\ntemplate: A\n---\n", Some("A")), None);
    assert_eq!(set("---\ntemplate: \"A\" # c\n---\n", Some("A")), None);
    assert_eq!(set("---\ntitle: T\n---\n", None), None);
    assert_eq!(set("Body\n", None), None);
    assert_eq!(set("", None), None);
    // A blank name is no name.
    assert_eq!(set("Body\n", Some("  ")), None);
    assert_eq!(set("---\ntemplate: A\n---\n", Some("  ")).as_deref(), Some(""));
}

#[test]
fn remove_the_line_and_keep_the_other_keys() {
    assert_eq!(
        set("---\ntitle: T\ntemplate: A\ntags: [a]\n---\nBody\n", None).as_deref(),
        Some("---\ntitle: T\ntags: [a]\n---\nBody\n")
    );
    // A comment is something to keep, so is the block.
    assert_eq!(set("---\n# notes\ntemplate: A\n---\nBody\n", None).as_deref(), Some("---\n# notes\n---\nBody\n"));
}

#[test]
fn remove_the_block_when_it_is_then_empty() {
    assert_eq!(set("---\ntemplate: A\n---\nBody\n", None).as_deref(), Some("Body\n"));
    // The blank line that adding made goes too: add then remove is the text we began with.
    assert_eq!(set("---\ntemplate: A\n---\n\n# Title\n", None).as_deref(), Some("# Title\n"));
    assert_eq!(set("---\ntemplate: A\n  \n\n---\nBody\n", None).as_deref(), Some("Body\n"));
    // A blank first line makes it no block to the parser: the `template:` line there is the document's text.
    assert_eq!(set("---\n\ntemplate: A\n  \n---\nBody\n", None), None);
    assert_eq!(set("---\ntemplate: A\n---\n", None).as_deref(), Some(""));
    assert_eq!(set("\u{feff}---\ntemplate: A\n---\nBody\n", None).as_deref(), Some("\u{feff}Body\n"));
}

#[test]
fn line_endings_are_kept() {
    assert_eq!(set("# T\r\nx\r\n", Some("A")).as_deref(), Some("---\r\ntemplate: A\r\n---\r\n\r\n# T\r\nx\r\n"));
    assert_eq!(set("---\r\ntitle: T\r\n---\r\nB\r\n", Some("A")).as_deref(), Some("---\r\ntitle: T\r\ntemplate: A\r\n---\r\nB\r\n"));
    assert_eq!(set("---\r\ntemplate: Old\r\n---\r\nB", Some("New")).as_deref(), Some("---\r\ntemplate: New\r\n---\r\nB"));
    assert_eq!(set("---\r\ntitle: T\r\ntemplate: Old\r\n---\r\nB", None).as_deref(), Some("---\r\ntitle: T\r\n---\r\nB"));
    assert_eq!(set("---\r\ntemplate: Old\r\n---\r\n\r\nB", None).as_deref(), Some("B"));
}

#[test]
fn byte_order_marks_stay_first() {
    assert_eq!(set("\u{feff}# T\n", Some("A")).as_deref(), Some("\u{feff}---\ntemplate: A\n---\n\n# T\n"));
    assert_eq!(set("\u{feff}---\ntitle: T\n---\n", Some("A")).as_deref(), Some("\u{feff}---\ntitle: T\ntemplate: A\n---\n"));
    assert_eq!(set("\u{feff}---\ntemplate: B\n---\n", Some("A")).as_deref(), Some("\u{feff}---\ntemplate: A\n---\n"));
}

#[test]
fn the_edit_is_in_the_documents_units() {
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let mut d = Document::new("---\ntitle: \u{1F600}\ntemplate: Old\n---\n", enc);
        let e = d.set_front_matter_template(Some("New")).unwrap();
        let (cut, end) = (e.range.start as usize, e.range.end as usize);
        assert_eq!(end - cut, "template: Old".chars().map(|c| match enc {
            OffsetEncoding::Utf8 => c.len_utf8(),
            OffsetEncoding::Utf16 => c.len_utf16(),
            OffsetEncoding::Utf32 => 1,
        }).sum::<usize>());
        assert_eq!(e.selection.start, e.selection.end);
        d.replace(e.range, &e.replacement).unwrap();
        assert_eq!(d.front_matter_template().as_deref(), Some("New"));
    }
}

#[test]
fn the_edit_leaves_the_rest_of_the_document_alone() {
    let mut d = doc("---\ntitle: T\n---\n# H\n\ntext [[link]] #tag\n");
    let before = d.outline();
    let e = d.set_front_matter_template(Some("Academic")).unwrap();
    d.replace(e.range, &e.replacement).unwrap();
    assert_eq!(d.front_matter_template().as_deref(), Some("Academic"));
    assert_eq!(d.outline().len(), before.len());
    assert!(d.text().ends_with("---\n# H\n\ntext [[link]] #tag\n"));
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Whatever the document, setting a name and reading it back gives the name, and removing it leaves no `template:`.
    #[test]
    fn set_then_read_gives_the_name(
        body in prop::collection::vec(prop_oneof![Just("---"), Just("..."), Just("title: T"), Just("template: X"), Just("# c"), Just(""), Just("text"), Just(" template: Y")], 0..8),
        crlf in any::<bool>(),
        bom in any::<bool>(),
        name in "[A-Za-z0-9 :#\"'\\\\\\[\\]-]{1,16}",
    ) {
        let eol = if crlf { "\r\n" } else { "\n" };
        let text = format!("{}{}", if bom { "\u{feff}" } else { "" }, body.join(eol));
        let name = name.trim().to_owned();
        prop_assume!(!name.is_empty());
        let set_text = set(&text, Some(&name)).unwrap_or_else(|| text.clone());
        prop_assert_eq!(read(&set_text), Some(name.clone()), "{:?} -> {:?}", text, set_text);
        if let Some(removed) = set(&set_text, None) {
            prop_assert_eq!(read(&removed), None);
        }
    }
}

// ----- found by the Opus pass, 7 October -----------------------------------------------------------------------------

/// The text outside the parser's front matter block, without the blank lines it starts with: what the reader sees.
fn visible(text: &str) -> String {
    let d = Document::new(text, OffsetEncoding::Utf8);
    let mut out = text.to_owned();
    // Only a block at the very start: pulldown-cmark also takes one right after a leading thematic break, which is no
    // front matter to anyone else.
    if let Some(s) = d.spans(None).into_iter().find(|s| s.kind == SpanKind::FrontMatter && s.range.start == 0) {
        out.replace_range(s.range.start as usize..s.range.end as usize, "");
    }
    let mut rest = out.as_str();
    while let Some(line) = rest.split_inclusive('\n').next().filter(|l| l.trim().is_empty() && l.ends_with('\n')) {
        rest = &rest[line.len()..];
    }
    if rest.trim().is_empty() { String::new() } else { rest.to_owned() }
}

/// Whether the parser (and so the preview, which hides it) sees a front matter block.
fn parser_sees_front_matter(text: &str) -> bool {
    doc(text).spans(None).iter().any(|s| s.kind == SpanKind::FrontMatter && s.range.start == 0)
}

#[test]
fn a_thematic_break_at_the_top_is_not_a_block_to_write_into() {
    // `---`, a blank line, a paragraph and a later `---`: two thematic breaks to the parser. The key was written before
    // the second, where it became a setext heading reading "template: Academic" in the document.
    let t = "---\n\nIntro.\n\n---\n\nBody\n";
    assert!(!parser_sees_front_matter(t));
    let made = set(t, Some("Academic")).unwrap();
    assert_eq!(made, "---\ntemplate: Academic\n---\n\n---\n\nIntro.\n\n---\n\nBody\n");
    assert!(parser_sees_front_matter(&made));
    assert_eq!(set(&made, None).as_deref(), Some(t));
    // A `template:` line in such a text is the text's, not a key.
    assert_eq!(read("---\n\ntemplate: X\n---\n"), None);
    assert_eq!(read("---\n  \ntemplate: X\n---\n"), None);
    // A closer followed by a tab is text to the parser, as is `----`.
    assert_eq!(read("---\ntemplate: X\n---\t\n"), None);
    assert_eq!(read("---\ntemplate: X\n----\n"), None);
    assert_eq!(read("---\ntemplate: X\n---  \n").as_deref(), Some("X"));
}

#[test]
fn removing_the_first_key_keeps_the_rest_a_block() {
    // Removing the first line left a blank first line, so the parser dropped the block and `title: T` showed as text.
    let t = "---\ntemplate: A\n\ntitle: T\n---\nx\n";
    assert!(parser_sees_front_matter(t));
    let removed = set(t, None).unwrap();
    assert_eq!(removed, "---\ntitle: T\n---\nx\n");
    assert!(parser_sees_front_matter(&removed));
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// The block the key is read from and written into is the parser's, before and after every edit (without a byte
    /// order mark: pulldown-cmark sees no block after one, but the shell removes it before the core sees the text, and
    /// 3.21 asks for the key to be read through one); setting a name
    /// twice changes nothing the second time; and for a text that had no block and does not start with a blank line
    /// (adding puts no second blank line after one, so removing cannot tell it was there), setting and removing gives
    /// back the text byte for byte.
    #[test]
    fn the_edit_agrees_with_the_parser(
        body in prop::collection::vec(prop_oneof![
            Just("---"), Just("..."), Just("--- "), Just("---\t"), Just("----"), Just("title: T"), Just("template: X"),
            Just("template: \"Y\""), Just("# c"), Just(""), Just("  "), Just("text"), Just(" template: Y"),
        ], 0..9),
        crlf in any::<bool>(),
        bom in any::<bool>(),
        name in "[A-Za-z0-9 :#\"'\\\\./é-]{1,12}",
    ) {
        let eol = if crlf { "\r\n" } else { "\n" };
        let text = format!("{}{}", if bom { "\u{feff}" } else { "" }, body.join(eol));
        let name = name.trim().to_owned();
        prop_assume!(!name.is_empty());
        prop_assume!(body.iter().filter(|l| l.starts_with("template:")).count() <= 1);
        let parser = |t: &str| bom || parser_sees_front_matter(t);
        if read(&text).is_some() {
            prop_assert!(parser(&text), "read a key outside the parser's block: {:?}", text);
        }
        let set_text = set(&text, Some(&name)).unwrap_or_else(|| text.clone());
        prop_assert!(parser(&set_text), "{:?} -> {:?}", text, set_text);
        prop_assert_eq!(read(&set_text), Some(name.clone()));
        prop_assert_eq!(set(&set_text, Some(&name)), None, "setting {:?} twice changed {:?}", name, set_text);
        let removed = set(&set_text, None).unwrap();
        prop_assert_eq!(read(&removed), None);
        let had_block = read(&text).is_some() || set(&text, Some(&name)).is_none_or(|t| !t.ends_with(&text[bom as usize * 3..]));
        // A body that is itself a block once the one before it goes (`---`, `---\t`, `---` after the front matter)
        // cannot be kept as text by any edit here; nobody writes that.
        if !bom && !parser_sees_front_matter(&visible(&text)) {
            // What the reader sees (the text outside the block) is the same before, with the key, and after removing it.
            prop_assert_eq!(visible(&set_text), visible(&text), "{:?} -> {:?}", text, set_text);
            prop_assert_eq!(visible(&removed), visible(&text), "{:?} -> {:?}", set_text, removed);
        }
        let starts_blank = text.trim_start_matches('\u{feff}').starts_with(['\n', '\r']);
        if !had_block && !starts_blank && !text.trim_start_matches('\u{feff}').is_empty() {
            prop_assert_eq!(&removed, &text);
        }
    }
}

// ----- line_width (M13) ----------------------------------------------------------------------------------------------

fn width(text: &str) -> Option<u32> {
    doc(text).front_matter_line_width()
}

/// The text after applying the edit `set_front_matter_line_width` returns (`None` when there is none).
fn set_width(text: &str, w: Option<u32>) -> Option<String> {
    let mut d = doc(text);
    let edit = d.set_front_matter_line_width(w)?;
    d.replace(edit.range, &edit.replacement).unwrap();
    Some(d.text().to_owned())
}

#[test]
fn line_width_reads_integers_in_range_only() {
    assert_eq!(width("---\nline_width: 56\n---\n"), Some(56));
    assert_eq!(width("---\nline_width: \"56\"\n---\n"), Some(56));
    assert_eq!(width("---\nline_width:   56  \n---\n"), Some(56));
    assert_eq!(width("---\nline_width: 30\n---\n"), Some(30));
    assert_eq!(width("---\nline_width: 160\n---\n"), Some(160));
    for bad in ["abc", "0", "999", "56px", "29", "161", "-56", "5.6", ""] {
        assert_eq!(width(&format!("---\nline_width: {bad}\n---\n")), None, "{bad}");
    }
    assert_eq!(width("line_width: 56\n"), None);
    assert_eq!(width("---\nline_width_x: 56\n---\n"), None);
}

/// A key written twice is invalid YAML, read by its first line: an edit replaces or removes every line of the key
/// at once, else a removal would leave the second line to take effect.
#[test]
fn line_width_first_duplicate_wins_and_an_edit_takes_every_line() {
    assert_eq!(width("---\nline_width: 56\nline_width: 96\n---\n"), Some(56));
    assert_eq!(set_width("---\nline_width: 56\nline_width: 96\n---\n", Some(72)).as_deref(), Some("---\nline_width: 72\n---\n"));
    assert_eq!(set_width("---\nline_width: 56\nline_width: 96\n---\n", Some(56)).as_deref(), Some("---\nline_width: 56\n---\n"));
    assert_eq!(set_width("---\nline_width: 56\nline_width: 96\n---\n\nBody\n", None).as_deref(), Some("Body\n"));
    // The lines of other keys between the two stay, in their order.
    assert_eq!(set_width("---\ntitle: T\nline_width: 56\ntags: [a]\nline_width: 96\ntemplate: X\n---\n", None).as_deref(),
               Some("---\ntitle: T\ntags: [a]\ntemplate: X\n---\n"));
    assert_eq!(set_width("---\ntitle: T\nline_width: 56\ntags: [a]\nline_width: 96\ntemplate: X\n---\n", Some(72)).as_deref(),
               Some("---\ntitle: T\nline_width: 72\ntags: [a]\ntemplate: X\n---\n"));
    // Removing the block's first line takes the blank lines after it too (a block opening blank is no block).
    assert_eq!(set_width("---\nline_width: 56\n\nline_width: 96\n\ntitle: T\n---\n", None).as_deref(), Some("---\ntitle: T\n---\n"));
    assert_eq!(set_width("---\r\nline_width: 56\r\nline_width: 96\r\n---\r\nBody\r\n", Some(72)).as_deref(), Some("---\r\nline_width: 72\r\n---\r\nBody\r\n"));
}

#[test]
fn line_width_is_made_replaced_and_removed() {
    assert_eq!(set_width("Body\n", Some(56)).as_deref(), Some("---\nline_width: 56\n---\n\nBody\n"));
    assert_eq!(set_width("---\nline_width: 56\n---\nBody\n", Some(96)).as_deref(), Some("---\nline_width: 96\n---\nBody\n"));
    assert_eq!(set_width("---\nline_width: 56\n---\nBody\n", Some(56)), None);
    assert_eq!(set_width("---\nline_width: \"56\"\n---\nBody\n", Some(56)), None);
    assert_eq!(set_width("---\nline_width: 56\n---\n\nBody\n", None).as_deref(), Some("Body\n"));
    assert_eq!(set_width("Body\n", None), None);
}

#[test]
fn line_width_among_other_keys_and_line_endings() {
    assert_eq!(set_width("---\ntitle: T\ntemplate: A\n---\nx\n", Some(72)).as_deref(), Some("---\ntitle: T\ntemplate: A\nline_width: 72\n---\nx\n"));
    assert_eq!(set_width("---\ntitle: T\nline_width: 72\ntemplate: A\n---\nx\n", None).as_deref(), Some("---\ntitle: T\ntemplate: A\n---\nx\n"));
    assert_eq!(set_width("---\nline_width: 72\ntitle: T\n---\nx\n", None).as_deref(), Some("---\ntitle: T\n---\nx\n"));
    assert_eq!(set_width("a\r\nb\r\n", Some(56)).as_deref(), Some("---\r\nline_width: 56\r\n---\r\n\r\na\r\nb\r\n"));
    assert_eq!(set_width("---\r\ntitle: T\r\n---\r\nx\r\n", Some(56)).as_deref(), Some("---\r\ntitle: T\r\nline_width: 56\r\n---\r\nx\r\n"));
    assert_eq!(width("\u{feff}---\r\nline_width: 96\r\n---\r\nx"), Some(96));
    assert_eq!(set_width("\u{feff}x\n", Some(56)).as_deref(), Some("\u{feff}---\nline_width: 56\n---\n\nx\n"));
}

#[test]
fn the_template_and_the_width_live_in_one_block() {
    let t = set(&set_width("Body\n", Some(56)).unwrap(), Some("Academic")).unwrap();
    assert_eq!(t, "---\nline_width: 56\ntemplate: Academic\n---\n\nBody\n");
    assert_eq!(read(&t).as_deref(), Some("Academic"));
    assert_eq!(width(&t), Some(56));
    assert_eq!(set_width(&t, None).as_deref(), Some("---\ntemplate: Academic\n---\n\nBody\n"));
}
