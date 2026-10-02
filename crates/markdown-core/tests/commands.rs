//! Table-driven expectations for the editing commands. `‸` is the caret, `«...»` a selection;
//! the expected text carries the selection the edit must leave behind.
mod common;
use common::*;
use markdown_core::*;

fn fmt(before: &str, cmd: FormatCommand) -> String {
    run_marked(before, |d, s| d.format(cmd.clone(), s))
}

fn newline(before: &str) -> String {
    run_marked(before, |d, s| d.newline(s))
}

fn indent(before: &str, outdent: bool) -> String {
    run_marked(before, |d, s| d.indent(s, outdent))
}

fn table(before: &str, cmd: TableCommand) -> String {
    run_marked(before, |d, s| d.table_command(cmd, s))
}

fn check(cases: &[(&str, &str)], f: impl Fn(&str) -> String) {
    let mut bad = Vec::new();
    for (before, after) in cases {
        let got = f(before);
        if got != *after {
            bad.push(format!("{before:?}\n   want {after:?}\n   got  {got:?}"));
        }
    }
    assert!(bad.is_empty(), "{} failing cases:\n{}", bad.len(), bad.join("\n"));
}

// ----- inline formatting --------------------------------------------------------------------

#[test]
fn strong() {
    check(
        &[
            ("«word»", "**«word»**"),
            ("a «word» b", "a **«word»** b"),
            ("**«word»**", "«word»"),
            ("**wo‸rd**", "wo‸rd"),
            ("**word**‸", "word‸"),
            ("«**word**»", "«word»"),
            ("**a «b» c**", "a «b» c"),
            ("wo‸rd", "**wo‸rd**"),
            ("word‸", "**word‸**"),
            ("a ‸ b", "a **‸** b"),
            ("‸", "**‸**"),
            ("« word »", " **«word»** "),
            ("«a **b** c»", "**«a b c»**"),
            ("«**a** **b**»", "«a b»"),
            ("«h\u{e9}llo \u{1F389}»", "**«h\u{e9}llo \u{1F389}»**"),
            ("a \u{65E5}\u{672C}‸\u{8A9E} b", "a **\u{65E5}\u{672C}‸\u{8A9E}** b"),
            ("«one»\r\ntwo", "**«one»**\r\ntwo"),
            ("«a»  ", "**«a»**  "),
            // An element that straddles the selection is taken in whole.
            ("**a«b**c»d", "**«abc»**d"),
            ("a«b **c»d**", "a**«b cd»**"),
        ],
        |b| fmt(b, FormatCommand::Strong),
    );
}

#[test]
fn emphasis_strike_and_code() {
    check(
        &[("«word»", "*«word»*"), ("*«word»*", "«word»"), ("_wo‸rd_", "wo‸rd"), ("***a‸***", "**a‸**")],
        |b| fmt(b, FormatCommand::Emphasis),
    );
    check(
        &[("«word»", "~~«word»~~"), ("~~«word»~~", "«word»"), ("~wo‸rd~", "wo‸rd"), ("a ‸", "a ~~‸~~")],
        |b| fmt(b, FormatCommand::Strikethrough),
    );
    check(
        &[
            ("«word»", "`«word»`"),
            ("`«word»`", "«word»"),
            ("`wo‸rd`", "wo‸rd"),
            ("«a`b»", "``«a`b»``"),
            ("«a``b`c»", "```«a``b`c»```"),
            ("a ‸", "a `‸`"),
            // A blank keeps a leading or trailing backtick apart from the fence, and goes again.
            ("«`a»", "`` «`a» ``"),
            ("`` `«a»` ``", "`«a»`"),
        ],
        |b| fmt(b, FormatCommand::InlineCode),
    );
}

#[test]
fn multi_paragraph_and_container_selections() {
    check(
        &[
            ("«one\n\ntwo»", "**«one**\n\n**two»**"),
            ("«one\ntwo»", "**«one\ntwo»**"),
            ("> «one\n> two»", "> **«one**\n> **two»**"),
            ("- «one\n- two»", "- **«one**\n- **two»**"),
            ("# «Title»", "# **«Title»**"),
            ("«# Title\n\ntext»", "# **«Title**\n\n**text»**"),
            ("**«one**\n\n**two»**", "«one\n\ntwo»"),
            ("```\n«code»\n```", "None"),
            ("    «code»", "None"),
            ("  ‸  code", "None"),
        ],
        |b| fmt(b, FormatCommand::Strong),
    );
}

#[test]
fn table_cells_are_wrapped_one_by_one() {
    check(
        &[("| «a | b» |\n|---|---|\n| 1 | 2 |", "| **«a** | **b»** |\n|---|---|\n| 1 | 2 |")],
        |b| fmt(b, FormatCommand::Strong),
    );
}

#[test]
fn links() {
    check(
        &[
            ("a «text» b", "a [text](‸) b"),
            ("[«text»](http://a.b)", "«text»"),
            ("[te‸xt](http://a.b)", "te‸xt"),
            ("[text][ref]‸\n\n[ref]: /u", "text‸\n\n[ref]: /u"),
            ("<http://a.b>‸", "http://a.b‸"),
            ("see «https://example.com/x» now", "see [‸](https://example.com/x) now"),
            ("see https://exam‸ple.com/x now", "see [‸](https://example.com/x) now"),
            ("see wo‸rd now", "see [word](‸) now"),
            ("see ‸ now", "see [‸]() now"),
            ("« text »", " [text](‸) "),
        ],
        |b| fmt(b, FormatCommand::Link),
    );
}

#[test]
fn images() {
    let img = |dest: &str, alt: &str, before: &str| {
        fmt(before, FormatCommand::Image { destination: dest.into(), alt: alt.into() })
    };
    assert_eq!(img("pic.png", "A pic", "a ‸ b"), "a ![A pic](pic.png)‸ b");
    assert_eq!(img("my pic (1).png", "", "«label»"), "![label](<my pic (1).png>)‸");
    assert_eq!(img("", "", "‸"), "![](‸)");
    assert_eq!(img("p.png", "a[b]", "‸"), "![a\\[b\\]](p.png)‸");
}

// ----- block formatting ---------------------------------------------------------------------

#[test]
fn headings() {
    let h = |level| move |b: &str| fmt(b, FormatCommand::Heading { level });
    check(
        &[
            ("te‸xt", "# te‸xt"),
            ("# te‸xt", "te‸xt"),
            ("## te‸xt", "# te‸xt"),
            ("«a\nb»", "# «a\n# b»"),
            ("# a\n«b\n# c»", "# a\n# «b\n# c»"),
            ("‸", "# ‸"),
            ("> te‸xt", "> # te‸xt"),
            ("- te‸xt", "- # te‸xt"),
            ("# te‸xt #", "te‸xt"),
            ("```\nco‸de\n```", "None"),
            ("a\r\nb‸", "a\r\n# b‸"),
            ("«a\n\nb»", "# «a\n\n# b»"),
            ("«a\nb»\n---", "«# a b»"),
        ],
        h(1),
    );
    check(&[("# te‸xt", "te‸xt"), ("te‸xt", "None"), ("###### a‸", "a‸"), ("Title‸\n---", "Title‸")], h(0));
    check(&[("te‸xt", "###### te‸xt"), ("# a‸", "###### a‸")], h(9));
    check(&[("Title‸\n=====", "## Title‸")], h(2));
    // The same level on a setext heading removes it.
    check(&[("Title‸\n-----", "Title‸"), ("Title‸\n=====", "Title‸")], |b| {
        if b.contains("---") { fmt(b, FormatCommand::Heading { level: 2 }) } else { fmt(b, FormatCommand::Heading { level: 1 }) }
    });
}

#[test]
fn block_quotes() {
    check(
        &[
            ("te‸xt", "> te‸xt"),
            ("> te‸xt", "te‸xt"),
            (">te‸xt", "te‸xt"),
            ("> > te‸xt", "> te‸xt"),
            ("«a\nb»", "> «a\n> b»"),
            ("> «a\n> b»", "«a\nb»"),
            ("«a\n> b»", "> «a\n> b»"),
            // Paragraphs quoted together stay one quote; the blank line gets a bare `>`.
            ("«a\n\nb»", "> «a\n>\n> b»"),
            ("> «a\n>\n> b»", "«a\n\nb»"),
            ("\n«\na\n\n»", "\n«\n> a\n\n»"),
            ("‸", "> ‸"),
            ("- te‸xt", "> - te‸xt"),
            ("a\r\n«b»", "a\r\n> «b»"),
            // A quote inside a list item is a quote: the toolbar lights up, and the toggle removes it.
            ("- > te‸xt", "- te‸xt"),
            ("1. > «a»", "1. «a»"),
            // A line of a fenced block quotes the whole block, code untouched (even a `>` in it).
            ("```\n> co‸de\n```", "> ```\n> > co‸de\n> ```"),
            ("> ```\n> > co‸de\n> ```", "```\n> co‸de\n```"),
            ("~~~\n‸\n~~~", "> ~~~\n> ‸\n> ~~~"),
            // An indented `~~~` does not close the fence; the block runs to the end.
            ("~~~\n‸\n    ~~~\n\nx", "> ~~~\n> ‸\n>     ~~~\n> \n> x"),
            ("---\nti‸tle: x\n---\n", "None"),
        ],
        |b| fmt(b, FormatCommand::BlockQuote),
    );
}

#[test]
fn bullet_lists() {
    check(
        &[
            ("te‸xt", "- te‸xt"),
            ("- te‸xt", "te‸xt"),
            ("«a\nb»", "- «a\n- b»"),
            ("«a\n\nb»", "- «a\n\n- b»"),
            ("‸", "- ‸"),
            ("1. te‸xt", "- te‸xt"),
            ("- [x] te‸xt", "- te‸xt"),
            ("«- a\nb»", "«- a\n- b»"),
            ("«* a\nb»", "«* a\n* b»"),
            ("  te‸xt", "  - te‸xt"),
            ("> te‸xt", "> - te‸xt"),
            ("«- a\n- b»", "«a\nb»"),
            ("```\n«a»\n```", "None"),
        ],
        |b| fmt(b, FormatCommand::BulletList),
    );
}

#[test]
fn ordered_and_task_lists() {
    check(
        &[
            ("te‸xt", "1. te‸xt"),
            ("1. te‸xt", "te‸xt"),
            ("«a\nb\nc»", "1. «a\n2. b\n3. c»"),
            ("«a\n\nb»", "1. «a\n\n2. b»"),
            ("- te‸xt", "1. te‸xt"),
            ("«- a\n- b»", "«1. a\n2. b»"),
            ("- [ ] te‸xt", "1. te‸xt"),
            ("«a\n  b\nc»", "1. «a\n  1. b\n2. c»"),
            ("«5. a\nb»", "«1. a\n2. b»"),
            ("«1) a\nb»", "«1) a\n2) b»"),
        ],
        |b| fmt(b, FormatCommand::OrderedList),
    );
    check(
        &[
            ("te‸xt", "- [ ] te‸xt"),
            ("- [ ] te‸xt", "te‸xt"),
            ("- [x] te‸xt", "te‸xt"),
            ("- te‸xt", "- [ ] te‸xt"),
            ("1. te‸xt", "- [ ] te‸xt"),
            ("«a\n- [x] b»", "- [ ] «a\n- [x] b»"),
            ("«a\nb»", "- [ ] «a\n- [ ] b»"),
        ],
        |b| fmt(b, FormatCommand::TaskList),
    );
}

#[test]
fn code_blocks() {
    check(
        &[
            ("«a\nb»", "```\n«a\nb»\n```"),
            ("te‸xt", "```\nte‸xt\n```"),
            ("```\n«a»\n```", "«a»"),
            ("```rs\na‸\nb\n```", "a‸\nb"),
            ("«a ``` b»", "````\n«a ``` b»\n````"),
            ("> «a»", "> ```\n> «a»\n> ```"),
            ("«a\r\nb»", "```\r\n«a\r\nb»\r\n```"),
            ("‸", "```\n‸\n```"),
            ("x\n```\n«a»\n```\ny", "x\n«a»\ny"),
        ],
        |b| fmt(b, FormatCommand::CodeBlock),
    );
}

// ----- Return, Tab, tasks -----------------------------------------------------------------------

#[test]
fn return_continues_lists_and_quotes() {
    check(
        &[
            ("- a‸", "- a\n- ‸"),
            ("- a‸b", "- a\n- ‸b"),
            ("* a‸", "* a\n* ‸"),
            ("+ a‸", "+ a\n+ ‸"),
            ("1. a‸", "1. a\n2. ‸"),
            ("1. a‸\n2. b", "1. a\n2. ‸\n3. b"),
            ("1. a‸\n2. b\n3. c", "1. a\n2. ‸\n3. b\n4. c"),
            ("1. a‸\n1. b", "1. a\n1. ‸\n1. b"),
            ("1) a‸", "1) a\n2) ‸"),
            ("9. a‸\n10. b", "9. a\n10. ‸\n11. b"),
            ("1. a‸\n2. b\n\nafter\n2. x", "1. a\n2. ‸\n3. b\n\nafter\n2. x"),
            ("- [ ] a‸", "- [ ] a\n- [ ] ‸"),
            ("- [x] a‸", "- [x] a\n- [ ] ‸"),
            ("  - a‸", "  - a\n  - ‸"),
            ("- a\n  - b‸", "- a\n  - b\n  - ‸"),
            ("1. a\n   - b‸\n2. c", "1. a\n   - b\n   - ‸\n2. c"),
            ("-   a‸", "-   a\n-   ‸"),
            ("- a‸\r\n- b", "- a\r\n- ‸\r\n- b"),
            ("- h\u{e9}llo \u{1F389}‸", "- h\u{e9}llo \u{1F389}\n- ‸"),
            ("> a‸", "> a\n> ‸"),
            ("> > a‸", "> > a\n> > ‸"),
            ("> - a‸", "> - a\n> - ‸"),
            ("> 1. a‸", "> 1. a\n> 2. ‸"),
            ("- ‸a", "- \n- ‸a"),
        ],
        newline,
    );
}

#[test]
fn return_on_empty_items_ends_or_outdents() {
    check(
        &[
            ("- ‸", "‸"),
            ("- a\n- ‸", "- a\n‸"),
            ("- [ ] ‸", "‸"),
            ("1. ‸", "‸"),
            ("- a\n  - ‸", "- a\n- ‸"),
            ("1. a\n   1. ‸", "1. a\n2. ‸"),
            ("> ‸", "‸"),
            ("> > ‸", "> ‸"),
            ("> - ‸", "> ‸"),
            ("- a\n  - b\n    - ‸", "- a\n  - b\n  - ‸"),
        ],
        newline,
    );
}

#[test]
fn return_elsewhere_is_left_to_the_shell() {
    check(
        &[
            ("plain‸", "None"),
            ("# head‸", "None"),
            ("‸- a", "None"),
            ("-‸ a", "None"),
            ("```\ncode‸\n```", "None"),
            ("```\ncode\n```‸", "None"),
            ("- a\n  more‸", "None"),
            ("---‸", "None"),
            ("* * *‸", "None"),
            ("    - not a list‸", "None"),
            ("foo\n2. bar‸", "None"),
        ],
        newline,
    );
}

#[test]
fn return_in_code_keeps_indentation() {
    check(
        &[
            ("```\n  code‸\n```", "```\n  code\n  ‸\n```"),
            ("```\n  co‸de\n```", "```\n  co\n  ‸de\n```"),
            ("```\n \u{20}‸code\n```", "```\n  \n  ‸code\n```"),
            ("> ```\n> code‸\n> ```", "> ```\n> code\n> ‸\n> ```"),
            ("- a\n  ```\n  x‸\n  ```", "- a\n  ```\n  x\n  ‸\n  ```"),
            ("```\n\tcode‸", "```\n\tcode\n\t‸"),
        ],
        newline,
    );
}

#[test]
fn tab_in_lists() {
    check(
        &[
            ("- a\n- b‸", "- a\n  - b‸"),
            ("- a‸", "None"),
            ("1. a\n2. b‸", "1. a\n   1. b‸"),
            ("1. a\n2. b‸\n3. c", "1. a\n   1. b‸\n2. c"),
            ("- a\n- «b\n- c»", "- a\n  - «b\n  - c»"),
            ("- a\n- b‸\n  - c", "- a\n  - b‸\n    - c"),
            ("- [ ] a\n- [ ] b‸", "- [ ] a\n  - [ ] b‸"),
            ("- a\n  - b\n- c‸", "- a\n  - b\n  - c‸"),
            ("> - a\n> - b‸", "> - a\n>   - b‸"),
            ("- a\n\n- b‸", "- a\n\n  - b‸"),
        ],
        |b| indent(b, false),
    );
}

#[test]
fn shift_tab_in_lists() {
    check(
        &[
            ("- a\n- b‸", "None"),
            ("- a\n  - b‸", "- a\n- b‸"),
            ("1. a\n   1. b\n   2. c‸", "1. a\n   1. b\n2. c‸"),
            ("- a\n  - «b\n  - c»", "- a\n- «b\n- c»"),
            ("- a\n  - b\n    - c‸", "- a\n  - b\n  - c‸"),
        ],
        |b| indent(b, true),
    );
}

#[test]
fn tab_outside_lists() {
    check(
        &[("text‸", "None"), ("«te»xt", "None"), ("«a\nb»", "    «a\n    b»"), ("«a\n\nb»", "    «a\n\n    b»"), ("> «a\n> b»", ">     «a\n>     b»")],
        |b| indent(b, false),
    );
    check(
        &[
            ("    a‸", "a‸"),
            ("\ta‸", "a‸"),
            ("  a‸", "a‸"),
            ("a‸", "None"),
            ("«      a\n  b»", "«  a\nb»"),
        ],
        |b| indent(b, true),
    );
}

#[test]
fn toggling_tasks() {
    let toggle = |before: &str, at: usize| {
        let (text, _) = parse_marked(before);
        for enc in ALL_ENCODINGS {
            let doc = Document::new(&text, enc);
            let at_u = byte_to_unit(&text, enc, at);
            let e = doc.toggle_task(at_u);
            if let Some(e) = &e {
                assert_eq!(e.selection, TextRange::new(at_u, at_u));
                let (new, _) = apply_edit(&text, enc, e).unwrap();
                assert_eq!(new.chars().count(), text.chars().count());
            }
        }
        let doc = Document::new(&text, OffsetEncoding::Utf8);
        doc.toggle_task(at as u32).map(|e| apply_edit(&text, OffsetEncoding::Utf8, &e).unwrap().0)
    };
    assert_eq!(toggle("- [ ] a‸", 0).as_deref(), Some("- [x] a"));
    assert_eq!(toggle("- [x] a‸", 4).as_deref(), Some("- [ ] a"));
    assert_eq!(toggle("- [X] a‸", 7).as_deref(), Some("- [ ] a"));
    assert_eq!(toggle("x\n- [ ] \u{e9} a‸", 2).as_deref(), Some("x\n- [x] \u{e9} a"));
    assert_eq!(toggle("- [ ] a\n- [ ] b‸", 10).as_deref(), Some("- [ ] a\n- [x] b"));
    assert_eq!(toggle("- a‸", 0), None);
    assert_eq!(toggle("text [ ] x‸", 3), None);
    assert_eq!(toggle("```\n- [ ] a\n```‸", 5), None);
}

// ----- tables -------------------------------------------------------------------------------------

#[test]
fn realign() {
    let r = |b: &str| table(b, TableCommand::Realign);
    check(
        &[
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "| ‸a   | b   |\n| --- | --- |\n| 1   | 2   |"),
            ("|‸a|b|\n|-|-|\n|1|2|", "| ‸a   | b   |\n| --- | --- |\n| 1   | 2   |"),
            ("a | b\n--|--\n‸1 | 2", "| a   | b   |\n| --- | --- |\n| ‸1   | 2   |"),
            ("| a   | b   |\n| --- | --- |\n| ‸1   | 2   |", "None"),
            // Display columns: CJK and emoji are two wide.
            (
                "| ‸\u{540D}\u{524D} | b |\n|---|---|\n| x | \u{65E5}\u{672C}\u{8A9E} |",
                "| ‸\u{540D}\u{524D} | b      |\n| ---- | ------ |\n| x    | \u{65E5}\u{672C}\u{8A9E} |",
            ),
            ("| ‸\u{1F600} | b |\n|---|---|\n| xxxx | y |", "| ‸\u{1F600}   | b   |\n| ---- | --- |\n| xxxx | y   |"),
            // Alignment decides the padding side.
            (
                "| a | b | c |\n|:--|:-:|--:|\n| ‸1 | 2 | 3 |",
                "| a   |  b  |   c |\n| :-- | :-: | --: |\n| ‸1   |  2  |   3 |",
            ),
            // Escaped pipes are cell content.
            ("| ‸a\\|b | c |\n|---|---|\n| 1 | 2 |", "| ‸a\\|b | c   |\n| ---- | --- |\n| 1    | 2   |"),
            // Missing cells are filled in, container prefixes kept.
            ("> | ‸a | b |\n> |---|---|\n> | 1 |", "> | ‸a   | b   |\n> | --- | --- |\n> | 1   |     |"),
            ("| ‸a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n", "| ‸a   | b   |\r\n| --- | --- |\r\n| 1   | 2   |\r\n"),
            ("text\n\n| ‸a |\n|---|\n| long text |\n\nmore", "text\n\n| ‸a         |\n| --------- |\n| long text |\n\nmore"),
            ("not a ta‸ble", "None"),
            // GFM splits cells at an unescaped pipe even inside a code span; the cell the parser
            // drops stays in the text (after the last aligned cell) instead of being deleted.
            ("| ‸a | b |\n|---|---|\n| `x|y` | z |", "| ‸a   | b   |\n| --- | --- |\n| `x  | y`  | z |"),
            ("| ‸a | b |\n|---|---|\n| `x\\|y` | z |", "| ‸a      | b   |\n| ------ | --- |\n| `x\\|y` | z   |"),
        ],
        r,
    );
}

#[test]
fn adding_and_deleting_rows_and_columns() {
    check(
        &[
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "| a   | b   |\n| --- | --- |\n| ‸    |     |\n| 1   | 2   |"),
            ("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | ‸4 |", "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| 3   | 4   |\n|     | ‸    |"),
            ("| a | b |\n|---|--‸-|\n| 1 | 2 |", "| a   | b   |\n| --- | --- |\n|     | ‸    |\n| 1   | 2   |"),
        ],
        |b| table(b, TableCommand::AddRowBelow),
    );
    check(
        &[
            ("| a | b |\n|---|---|\n| 1 | ‸2 |", "| a   | b   |\n| --- | --- |\n|     | ‸    |\n| 1   | 2   |"),
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "None"),
            ("| a | b |\n|--‸-|---|\n| 1 | 2 |", "None"),
        ],
        |b| table(b, TableCommand::AddRowAbove),
    );
    check(
        &[
            ("| a | b |\n|---|---|\n| ‸1 | 2 |\n| 3 | 4 |", "| a   | b   |\n| --- | --- |\n| ‸3   | 4   |"),
            ("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | ‸4 |", "| a   | b   |\n| --- | --- |\n| 1   | ‸2   |"),
            ("| a | b |\n|---|---|\n| ‸1 | 2 |", "| ‸a   | b   |\n| --- | --- |"),
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "None"),
            ("| a | b |\n|-‸--|---|\n| 1 | 2 |", "None"),
        ],
        |b| table(b, TableCommand::DeleteRow),
    );
    check(
        &[
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "| a   | ‸    | b   |\n| --- | --- | --- |\n| 1   |     | 2   |"),
            ("| a | b ‸|\n|---|---|\n| 1 | 2 |", "| a   | b   | ‸    |\n| --- | --- | --- |\n| 1   | 2   |     |"),
        ],
        |b| table(b, TableCommand::AddColumnRight),
    );
    check(
        &[("| a | ‸b |\n|---|---|\n| 1 | 2 |", "| a   | ‸    | b   |\n| --- | --- | --- |\n| 1   |     | 2   |")],
        |b| table(b, TableCommand::AddColumnLeft),
    );
    check(
        &[
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "| ‸b   |\n| --- |\n| 2   |"),
            ("| a | ‸b |\n|---|---|\n| 1 | 2 |", "| ‸a   |\n| --- |\n| 1   |"),
            ("| ‸a |\n|---|\n| 1 |", "None"),
        ],
        |b| table(b, TableCommand::DeleteColumn),
    );
}

#[test]
fn alignment() {
    check(
        &[
            ("| a | ‸b |\n|---|---|\n| 1 | 2 |", "| a   |  ‸b  |\n| --- | :-: |\n| 1   |  2  |"),
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "|  ‸a  | b   |\n| :-: | --- |\n|  1  | 2   |"),
        ],
        |b| table(b, TableCommand::SetAlignment(ColumnAlignment::Center)),
    );
    check(
        &[("| a | ‸b |\n|---|--:|\n| 1 | 2 |", "| a   | ‸b   |\n| --- | --- |\n| 1   | 2   |")],
        |b| table(b, TableCommand::SetAlignment(ColumnAlignment::None)),
    );
    check(
        &[("| ‸a | b |\n|---|---|\n| 1 | 2 |", "| ‸a   | b   |\n| :-- | --- |\n| 1   | 2   |")],
        |b| table(b, TableCommand::SetAlignment(ColumnAlignment::Left)),
    );
}

#[test]
fn moving_between_cells() {
    check(
        &[
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "| a   | «b»   |\n| --- | --- |\n| 1   | 2   |"),
            ("| a | ‸b |\n|---|---|\n| 1 | 2 |", "| a   | b   |\n| --- | --- |\n| «1»   | 2   |"),
            ("| a | b |\n|---|---|\n| 1 | ‸2 |", "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| ‸    |     |"),
            ("| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| «x»   | y   |", "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| x   | «y»   |"),
            ("| a | b |\n|-‸--|---|", "| a   | b   |\n| --- | --- |\n| ‸    |     |"),
        ],
        |b| table(b, TableCommand::NextCell),
    );
    check(
        &[
            ("| ‸a | b |\n|---|---|\n| 1 | 2 |", "None"),
            ("| a | ‸b |\n|---|---|\n| 1 | 2 |", "| «a»   | b   |\n| --- | --- |\n| 1   | 2   |"),
            ("| a | b |\n|---|---|\n| ‸1 | 2 |", "| a   | «b»   |\n| --- | --- |\n| 1   | 2   |"),
            ("| a | b |\n|-‸--|---|", "| a   | «b»   |\n| --- | --- |"),
        ],
        |b| table(b, TableCommand::PreviousCell),
    );
}

#[test]
fn inserting_tables() {
    let ins = |rows, columns| move |b: &str| table(b, TableCommand::Insert { rows, columns });
    check(
        &[
            ("‸", "| ‸    |     |\n| --- | --- |\n|     |     |\n|     |     |"),
            ("para‸", "para\n\n| ‸    |     |\n| --- | --- |\n|     |     |\n|     |     |"),
            ("‸para", "| ‸    |     |\n| --- | --- |\n|     |     |\n|     |     |\n\npara"),
            ("para\n‸\nnext", "para\n\n| ‸    |     |\n| --- | --- |\n|     |     |\n|     |     |\n\nnext"),
            ("> q\n> ‸", "> q\n>\n> | ‸    |     |\n> | --- | --- |\n> |     |     |\n> |     |     |"),
            ("a‸\r\nb", "a\r\n\r\n| ‸    |     |\r\n| --- | --- |\r\n|     |     |\r\n|     |     |\r\n\r\nb"),
        ],
        ins(2, 2),
    );
    check(&[("‸", "| ‸    |\n| --- |")], ins(0, 0));
    check(
        &[("| ‸a |\n|---|\n| 1 |\n\nafter", "| a |\n|---|\n| 1 |\n\n| ‸    |\n| --- |\n|     |\n\nafter")],
        |b| table(b, TableCommand::Insert { rows: 1, columns: 1 }),
    );
}

#[test]
fn table_info() {
    let doc = Document::new("intro\n\n| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |\n\nafter", OffsetEncoding::Utf16);
    assert_eq!(doc.table_at(2), None);
    assert_eq!(doc.table_at(60), None);
    let t = doc.table_at(8 + 2).unwrap();
    assert_eq!((t.rows, t.columns, t.row, t.column), (3, 2, Some(0), Some(0)));
    assert_eq!(t.alignments, vec![ColumnAlignment::None, ColumnAlignment::Center]);
    assert_eq!(t.range, TextRange::new(7, 7 + 9 + 1 + 9 + 1 + 9 + 1 + 9));
    let in_delim = doc.table_at(7 + 9 + 1 + 2).unwrap();
    assert_eq!((in_delim.row, in_delim.column), (None, None));
    let last = doc.table_at(7 + 9 + 1 + 9 + 1 + 9 + 1 + 6).unwrap();
    assert_eq!((last.row, last.column), (Some(2), Some(1)));
    // The end of the last line is still in the table.
    let end = doc.table_at(7 + 39).unwrap();
    assert_eq!(end.row, Some(2));
}

// ----- state ----------------------------------------------------------------------------------------

fn state(marked: &str) -> FormatState {
    let (text, sel) = parse_marked(marked);
    let mut all = Vec::new();
    for enc in ALL_ENCODINGS {
        let doc = Document::new(&text, enc);
        let r = TextRange::new(byte_to_unit(&text, enc, sel.0), byte_to_unit(&text, enc, sel.1));
        all.push(doc.format_state(r));
    }
    assert!(all.iter().all(|s| *s == all[0]));
    all[0]
}

#[test]
fn format_state_reports_what_is_active() {
    assert_eq!(state("plain ‸text"), FormatState::default());
    let s = state("**bo‸ld**");
    assert!(s.strong && !s.emphasis);
    let s = state("***a‸***");
    assert!(s.strong && s.emphasis);
    let s = state("~~a‸~~ `b`");
    assert!(s.strikethrough && !s.inline_code);
    assert!(state("`a‸b`").inline_code);
    assert!(state("[a‸b](http://x.y)").link);
    assert!(state("see https://a.b‸/c").link);
    assert_eq!(state("## he‸ad").heading_level, 2);
    assert_eq!(state("Head‸\n=====").heading_level, 1);
    assert!(state("> qu‸ote").in_quote);
    assert!(state("> - qu‸ote").in_quote);
    assert_eq!(state("- a‸").list, ListKind::Bullet);
    assert_eq!(state("1. a‸").list, ListKind::Ordered);
    assert_eq!(state("- [ ] a‸").list, ListKind::Task);
    assert_eq!(state("- a\n  more‸").list, ListKind::Bullet);
    assert_eq!(state("- a\nlazy‸").list, ListKind::Bullet);
    assert_eq!(state("para‸").list, ListKind::None);
    assert!(state("```\nco‸de\n```").in_code_block);
    assert!(!state("co‸de").in_code_block);
    assert!(state("| a |\n|---|\n| ‸1 |").in_table);
    assert!(!state("‸x\n\n| a |\n|---|").in_table);
    let s = state("«**a** **b**»");
    assert!(s.strong);
    assert!(!state("«**a** b»").strong);
}

// ----- regressions from the M2 test pass ------------------------------------------------------

#[test]
fn words_with_apostrophes_and_combining_marks_are_one_word() {
    check(
        &[
            ("do‸n't", "**do‸n't**"),
            ("l\u{2019}hom‸me", "**l\u{2019}hom‸me**"),
            ("'quo‸ted'", "'**quo‸ted**'"),
            ("cafe\u{301}‸", "**cafe\u{301}‸**"),
            ("cafe\u{301}‸s", "**cafe\u{301}‸s**"),
        ],
        |b| fmt(b, FormatCommand::Strong),
    );
}

#[test]
fn toggling_twice_with_a_caret_restores_the_text() {
    check(&[("a **‸** b", "a ‸ b"), ("**‸**", "‸"), ("wo‸rd**st**", "**«wordst»**")], |b| fmt(b, FormatCommand::Strong));
    // A caret inside a real delimiter (`*‸*st**`) is not an empty pair to take away.
    check(&[("a *‸* b", "a ‸ b"), ("**‸**", "***‸***"), ("*‸*st**", "**‸**st**")], |b| fmt(b, FormatCommand::Emphasis));
    check(&[("a `‸` b", "a ‸ b")], |b| fmt(b, FormatCommand::InlineCode));
    check(&[("a ~~‸~~ b", "a ‸ b")], |b| fmt(b, FormatCommand::Strikethrough));
}

#[test]
fn inline_formatting_never_cuts_into_code_spans_or_links() {
    check(
        &[
            ("`co‸de`", "**`co‸de`**"),
            ("a `x «y» z` b", "a **«`x y z`»** b"),
            ("«a `b» c` d", "**«a `b c`»** d"),
            ("[a «b](u) c»", "**«[a b](u) c»**"),
            ("see www.a.«com/x»", "see **«www.a.com/x»**"),
            ("e\u{301}*e‸m* x", "__«e\u{301}*em*»__ x"),
        ],
        |b| fmt(b, FormatCommand::Strong),
    );
}

#[test]
fn closing_heading_sequence_stays_outside_the_wrap() {
    check(&[("# «Title #»", "# **«Title»** #"), ("## «a b ##»  ", "## **«a b»** ##  ")], |b| fmt(b, FormatCommand::Strong));
}

#[test]
fn linking_a_bare_www_url_keeps_it_absolute() {
    check(
        &[("see www.a.‸com now", "see [‸](http://www.a.com) now"), ("«www.a.com»", "[‸](http://www.a.com)")],
        |b| fmt(b, FormatCommand::Link),
    );
}

#[test]
fn backslashes_in_image_destinations_survive() {
    let got = fmt("‸", FormatCommand::Image { destination: "a\\_b.png".into(), alt: "x".into() });
    assert_eq!(got, "![x](a\\\\_b.png)‸");
}

#[test]
fn code_block_toggle_keeps_container_prefixes() {
    check(
        &[
            ("- ```\n  a‸\n  ```", "- a‸"),
            ("- ```\n  a‸\n  b\n  ```\n- c", "- a‸\n  b\n- c"),
            ("> ```\n> a‸\n> ```", "> a‸"),
            ("  ```\n  a‸\n  ```", "  a‸"),
            ("- ```\n  ```‸", "- ‸"),
        ],
        |b| fmt(b, FormatCommand::CodeBlock),
    );
}

#[test]
fn return_on_an_empty_item_of_an_indented_top_level_list_ends_it() {
    check(&[("  - a\n  - ‸", "  - a\n  ‸"), ("- a\n  - ‸", "- a\n- ‸"), ("- a\n\n  b\n  - ‸", "- a\n\n  b\n- ‸")], newline);
}
