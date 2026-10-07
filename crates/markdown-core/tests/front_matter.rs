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
    assert_eq!(set("---\n---\nBody\n", Some("Letter")).as_deref(), Some("---\ntemplate: Letter\n---\nBody\n"));
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
    assert_eq!(set("---\n\ntemplate: A\n  \n---\nBody\n", None).as_deref(), Some("Body\n"));
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
        // A key given twice is invalid YAML: the edit handles the first, so removal would leave the second.
        prop_assume!(body.iter().filter(|l| **l == "template: X").count() <= 1);
        let set_text = set(&text, Some(&name)).unwrap_or_else(|| text.clone());
        prop_assert_eq!(read(&set_text), Some(name.clone()), "{:?} -> {:?}", text, set_text);
        if let Some(removed) = set(&set_text, None) {
            prop_assert_eq!(read(&removed), None);
        }
    }
}
