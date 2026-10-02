//! Property tests for the editing commands: nothing panics, every edit applies cleanly with a
//! selection in bounds, toggles are involutions on plain words, Realign is idempotent, table
//! commands keep tables tables, and line commands stay on their lines.
mod common;
use common::*;
use markdown_core::*;
use proptest::prelude::*;

fn cases() -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(500)
}

fn md_tokens(max: usize) -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "# ", "## ", "> ", "> > ", "- ", "* ", "1. ", "2) ", "- [ ] ", "- [x] ", "  ", "    ", "\t", "```", "```rs\n", "~~~", "---\n",
        "\n", "\n", "\n\n", "\r\n", "*", "**", "_", "~~", "`", "``", "[", "](", ")", "![", "]", "| a | b |\n", "|---|---|\n",
        "|:-:|--:|\n", "| x ", "|", "\\|", "word", "word ", "text ", " ", "www.a.b/c", "http://a.b ", "<b>", "\\", "=== ", "===\n",
        "\u{1F389}", "\u{65E5}\u{672C}", "e\u{301}", "\u{e9}", "&amp;", "[^1]", "[r]: /u\n", "<http://a.b>",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat())
}

fn any_text() -> impl Strategy<Value = String> {
    prop_oneof![3 => md_tokens(30), 1 => any::<String>(), 1 => "[ -~\n\r\t\u{e9}\u{65E5}\u{1F389}]{0,80}"]
}

/// A selection as unit offsets: mostly on boundaries, sometimes anywhere (even inside a
/// surrogate pair) and sometimes inverted.
fn selection(text: &str, enc: OffsetEncoding, a: u32, b: u32, mode: u8) -> TextRange {
    let bounds = boundaries(text, enc);
    let len = *bounds.last().unwrap();
    match mode % 8 {
        0 => TextRange::new(a % (len + 2), b % (len + 2)), // anywhere, possibly past the end
        1 => {
            let p = bounds[a as usize % bounds.len()];
            TextRange::new(p, p)
        }
        2 => TextRange::new(bounds[a as usize % bounds.len()], bounds[b as usize % bounds.len()]), // maybe inverted
        _ => {
            let (mut i, mut j) = (a as usize % bounds.len(), b as usize % bounds.len());
            if i > j {
                std::mem::swap(&mut i, &mut j);
            }
            TextRange::new(bounds[i], bounds[j])
        }
    }
}

const ENCODINGS: [OffsetEncoding; 3] = ALL_ENCODINGS;

fn all_commands() -> Vec<FormatCommand> {
    let mut v = vec![
        FormatCommand::Strong,
        FormatCommand::Emphasis,
        FormatCommand::Strikethrough,
        FormatCommand::InlineCode,
        FormatCommand::Link,
        FormatCommand::Image { destination: "a b.png".into(), alt: String::new() },
        FormatCommand::Image { destination: String::new(), alt: "x".into() },
        FormatCommand::BlockQuote,
        FormatCommand::BulletList,
        FormatCommand::OrderedList,
        FormatCommand::TaskList,
        FormatCommand::CodeBlock,
    ];
    v.extend((0..=7).map(|level| FormatCommand::Heading { level }));
    v
}

fn all_table_commands() -> Vec<TableCommand> {
    vec![
        TableCommand::Insert { rows: 2, columns: 3 },
        TableCommand::Insert { rows: 0, columns: 0 },
        TableCommand::AddRowAbove,
        TableCommand::AddRowBelow,
        TableCommand::AddColumnLeft,
        TableCommand::AddColumnRight,
        TableCommand::DeleteRow,
        TableCommand::DeleteColumn,
        TableCommand::SetAlignment(ColumnAlignment::Center),
        TableCommand::SetAlignment(ColumnAlignment::Right),
        TableCommand::SetAlignment(ColumnAlignment::None),
        TableCommand::NextCell,
        TableCommand::PreviousCell,
        TableCommand::Realign,
    ]
}

/// The edit applies and its selection is valid; returns the new text.
fn check_edit_applies(text: &str, enc: OffsetEncoding, edit: &TextEdit) -> Result<String, TestCaseError> {
    match apply_edit(text, enc, edit) {
        Ok((new, _)) => Ok(new),
        Err(e) => Err(TestCaseError::fail(format!("{enc:?} {text:?}: {e}"))),
    }
}

fn strip_digits(s: &str) -> String {
    s.chars().filter(|c| !c.is_ascii_digit()).collect()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases()))]

    #[test]
    fn no_command_panics_and_every_edit_applies(
        text in any_text(), a in any::<u32>(), b in any::<u32>(), mode in any::<u8>(), enc_i in 0usize..3,
    ) {
        let enc = ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let sel = selection(&text, enc, a, b, mode);
        let mut edits: Vec<(String, Option<TextEdit>)> = Vec::new();
        for c in all_commands() {
            edits.push((format!("{c:?}"), doc.format(c.clone(), sel)));
        }
        edits.push(("newline".into(), doc.newline(sel)));
        edits.push(("indent".into(), doc.indent(sel, false)));
        edits.push(("outdent".into(), doc.indent(sel, true)));
        edits.push(("toggle_task".into(), doc.toggle_task(sel.start)));
        for c in all_table_commands() {
            edits.push((format!("{c:?}"), doc.table_command(c, sel)));
        }
        let _ = doc.format_state(sel);
        let _ = doc.table_at(sel.start);
        for (name, e) in edits {
            if let Some(e) = e {
                let new = check_edit_applies(&text, enc, &e).map_err(|err| TestCaseError::fail(format!("{name}: {err}")))?;
                // An edit that changes nothing is a selection change only, and says so.
                if new == text {
                    prop_assert!(e.range.is_empty() && e.replacement.is_empty(), "{name}: no-op edit with a range: {e:?}");
                }
            }
        }
    }

    #[test]
    fn inline_toggles_are_involutions_on_words(
        pre in "[a-zA-Z0-9\u{e9}\u{65E5}\u{1F389}][a-zA-Z0-9 \u{e9}\u{65E5}]{0,11}|", word in "[a-zA-Z0-9\u{e9}\u{65E5}]{1,10}", post in "[a-zA-Z0-9 \u{e9}]{0,12}",
        enc_i in 0usize..3, kind in 0usize..4, caret_only in any::<bool>(),
    ) {
        let enc = ENCODINGS[enc_i];
        let cmd = [FormatCommand::Strong, FormatCommand::Emphasis, FormatCommand::Strikethrough, FormatCommand::InlineCode][kind].clone();
        let text = format!("{pre} {word} {post}");
        let start = pre.len() + 1;
        // Four leading blanks make an indented code block, where nothing is formatted.
        let end = start + word.len();
        let (s, e) = if caret_only {
            let c = (start + word.len() / 2..=end).find(|&p| text.is_char_boundary(p)).unwrap();
            (c, c)
        } else {
            (start, end)
        };
        let sel = TextRange::new(byte_to_unit(&text, enc, s), byte_to_unit(&text, enc, e));
        let doc = Document::new(&text, enc);
        let wrapped = doc.format(cmd.clone(), sel).expect("wrapping a word is always possible");
        let new = check_edit_applies(&text, enc, &wrapped)?;
        prop_assert_ne!(&new, &text);
        let doc2 = Document::new(&new, enc);
        let state = doc2.format_state(wrapped.selection);
        prop_assert!(match kind { 0 => state.strong, 1 => state.emphasis, 2 => state.strikethrough, _ => state.inline_code }, "{new:?} not active at {:?}", wrapped.selection);
        let back = doc2.format(cmd, wrapped.selection).expect("toggling again is possible");
        let restored = check_edit_applies(&new, enc, &back)?;
        prop_assert_eq!(restored, text);
    }

    #[test]
    fn line_commands_stay_on_their_lines(
        text in md_tokens(30), a in any::<u32>(), b in any::<u32>(), mode in any::<u8>(), which in 0u8..3, enc_i in 0usize..3,
    ) {
        let enc = ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let sel = selection(&text, enc, a, b, mode);
        let edit = match which {
            0 => doc.newline(sel),
            1 => doc.indent(sel, false),
            _ => doc.indent(sel, true),
        };
        let Some(edit) = edit else { return Ok(()) };
        // Selected lines in bytes.
        let (s, e) = {
            let (x, y) = if sel.start <= sel.end { (sel.start, sel.end) } else { (sel.end, sel.start) };
            let ub = |u: u32| { let bounds = boundaries(&text, enc); let u = u.min(*bounds.last().unwrap()); let u = *bounds.iter().rev().find(|&&p| p <= u).unwrap(); unit_to_byte(&text, enc, u) };
            let (mut x, mut y) = (ub(x), ub(y));
            // A position between `\r` and `\n` belongs to the line before it.
            let mid = |p: usize| p > 0 && text[..p].ends_with('\r') && text[p..].starts_with('\n');
            if x == y && mid(x) {
                x -= 1;
                y = x;
            } else {
                if mid(x) { x -= 1; }
                if mid(y) { y += 1; }
            }
            (x, y)
        };
        let line_start = |p: usize| text[..p].rfind(['\n', '\r']).map_or(0, |i| i + 1);
        let line_end = |p: usize| text[p..].find(['\n', '\r']).map_or(text.len(), |i| p + i);
        let first = line_start(s);
        let last_end = line_end(e);
        let rs = unit_to_byte(&text, enc, edit.range.start);
        let re = unit_to_byte(&text, enc, edit.range.end);
        // Never starts before the first selected line (a CRLF split between its halves aside).
        prop_assert!(rs + 1 >= first, "edit starts before the selected lines: {edit:?} in {text:?}");
        if re > last_end + 1 {
            // Past the selected lines only ordered-list numbers change, and (Tab) the indentation
            // of the lines nested in a moved list item.
            let tail = &text[last_end.min(re)..re];
            let plain = |s: &str| s.chars().filter(|c| !c.is_ascii_digit() && !matches!(c, ' ' | '\t')).collect::<String>();
            let (a, b) = if which == 0 { (strip_digits(&edit.replacement), strip_digits(tail)) } else { (plain(&edit.replacement), plain(tail)) };
            prop_assert!(a.ends_with(&b), "text changed past the selection: {edit:?} in {text:?}");
        }
    }

    #[test]
    fn toggling_a_task_flips_one_character(text in md_tokens(20), at in any::<u32>(), enc_i in 0usize..3) {
        let enc = ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let len = doc.len();
        if let Some(e) = doc.toggle_task(at % (len + 1)) {
            prop_assert_eq!(e.range.len(), 1);
            prop_assert!(e.replacement == "x" || e.replacement == " ");
            check_edit_applies(&text, enc, &e)?;
        }
    }
}

// ----- tables ----------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Grid {
    prefix: String,
    eol: &'static str,
    aligns: Vec<u8>,
    header: Vec<String>,
    rows: Vec<Vec<String>>,
    leading_pipe: bool,
    trailing_newline: bool,
}

fn cell() -> impl Strategy<Value = String> {
    prop::sample::select(vec!["a", "bb", "", "x y", "\u{65E5}\u{672C}", "\u{1F600}", "x\\|y", "`c`", "**b**", "e\u{301}", "long cell text", "1"]).prop_map(String::from)
}

fn grid() -> impl Strategy<Value = Grid> {
    (1usize..=4).prop_flat_map(|cols| {
        (
            prop::sample::select(vec!["", "> ", "> > ", "  "]).prop_map(String::from),
            prop::sample::select(vec!["\n", "\r\n"]),
            prop::collection::vec(0u8..4, cols),
            prop::collection::vec(cell(), cols),
            prop::collection::vec(prop::collection::vec(cell(), 0..=cols + 1), 0..4),
            any::<bool>(),
            any::<bool>(),
        )
            .prop_map(|(prefix, eol, aligns, header, rows, leading_pipe, trailing_newline)| Grid {
                prefix,
                eol,
                aligns,
                header,
                rows,
                leading_pipe,
                trailing_newline,
            })
    })
}

impl Grid {
    fn render(&self) -> String {
        let row = |cells: &[String]| {
            let body = cells.iter().map(|c| format!(" {c} ")).collect::<Vec<_>>().join("|");
            if self.leading_pipe { format!("{}|{body}|", self.prefix) } else { format!("{}{body}", self.prefix) }
        };
        let delim: Vec<String> = self
            .aligns
            .iter()
            .map(|a| match a {
                0 => "---".into(),
                1 => ":--".into(),
                2 => ":-:".into(),
                _ => "--:".into(),
            })
            .collect();
        let mut lines = vec![row(&self.header), row(&delim)];
        lines.extend(self.rows.iter().map(|r| row(r)));
        let mut s = lines.join(self.eol);
        if self.trailing_newline {
            s.push_str(self.eol);
        }
        s
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases()))]

    #[test]
    fn realign_is_idempotent_and_keeps_the_table(g in grid(), pos in any::<u32>(), enc_i in 0usize..3) {
        let enc = ENCODINGS[enc_i];
        let text = g.render();
        let doc = Document::new(&text, enc);
        let len = doc.len();
        let at = pos % (len + 1);
        let Some(info) = doc.table_at(at) else { return Ok(()) };
        let sel = TextRange::new(at, at);
        let Some(edit) = doc.table_command(TableCommand::Realign, sel) else {
            // Already aligned: realigning again says the same, and nothing changes.
            return Ok(());
        };
        let new = check_edit_applies(&text, enc, &edit)?;
        let doc2 = Document::new(&new, enc);
        let info2 = doc2.table_at(edit.selection.start).expect("still a table at the caret");
        prop_assert_eq!((info2.rows, info2.columns), (info.rows, info.columns), "{:?} -> {:?}", text, new);
        prop_assert_eq!(&info2.alignments, &info.alignments);
        prop_assert!(doc2.table_command(TableCommand::Realign, edit.selection).is_none(), "not idempotent: {new:?}");
        // Same rows and cells textually (modulo padding): re-realigning each row's cells is stable.
        let lines_old = text.lines().count();
        let lines_new = new.lines().count();
        prop_assert_eq!(lines_old, lines_new);
        // Only whitespace, dashes, colons and the added empty cells changed: every non-blank
        // character of the old table is still there in order.
        let keep = |s: &str| s.chars().filter(|c| !c.is_whitespace() && !matches!(c, '-' | ':' | '|' | '>')).collect::<String>();
        prop_assert_eq!(keep(&text), keep(&new));
    }

    #[test]
    fn table_commands_keep_a_table_with_the_expected_shape(g in grid(), pos in any::<u32>(), cmd_i in 0usize..11, enc_i in 0usize..3) {
        let enc = ENCODINGS[enc_i];
        let text = g.render();
        let doc = Document::new(&text, enc);
        let len = doc.len();
        let at = pos % (len + 1);
        let Some(info) = doc.table_at(at) else { return Ok(()) };
        let cmd = [
            TableCommand::AddRowAbove, TableCommand::AddRowBelow, TableCommand::AddColumnLeft, TableCommand::AddColumnRight,
            TableCommand::DeleteRow, TableCommand::DeleteColumn, TableCommand::SetAlignment(ColumnAlignment::Center),
            TableCommand::SetAlignment(ColumnAlignment::Left), TableCommand::NextCell, TableCommand::PreviousCell,
            TableCommand::SetAlignment(ColumnAlignment::None),
        ][cmd_i];
        let Some(edit) = doc.table_command(cmd, TextRange::new(at, at)) else {
            // Refusals are only the documented ones.
            let on_delim = info.row.is_none();
            let header = info.row == Some(0);
            match cmd {
                TableCommand::AddRowAbove => prop_assert!(header || on_delim, "AddRowAbove refused on a body row: {:?} at {}", text, at),
                TableCommand::DeleteRow => prop_assert!(header || on_delim, "DeleteRow refused on a body row: {text:?} at {at}"),
                TableCommand::DeleteColumn => prop_assert_eq!(info.columns, 1),
                TableCommand::PreviousCell => prop_assert!(header, "PreviousCell refused outside the header: {text:?} at {at}"),
                _ => prop_assert!(false, "{cmd:?} refused inside a table: {text:?} at {at}"),
            }
            return Ok(());
        };
        let new = check_edit_applies(&text, enc, &edit)?;
        let doc2 = Document::new(&new, enc);
        let info2 = doc2.table_at(edit.selection.start).expect("still a table at the new selection");
        let (rows, cols) = (info.rows, info.columns);
        let (er, ec) = match cmd {
            TableCommand::AddRowAbove | TableCommand::AddRowBelow => (rows + 1, cols),
            TableCommand::AddColumnLeft | TableCommand::AddColumnRight => (rows, cols + 1),
            TableCommand::DeleteRow => (rows - 1, cols),
            TableCommand::DeleteColumn => (rows, cols - 1),
            _ => (rows, cols),
        };
        if cmd == TableCommand::NextCell {
            // From the last cell a row is appended; from anywhere else the shape stays.
            prop_assert_eq!(info2.columns, cols);
            let last_row = info.row == Some(rows - 1);
            let appended = info2.rows == rows + 1;
            match (info.row, info.column) {
                (Some(_), Some(c)) => prop_assert_eq!(appended, last_row && c + 1 == cols, "{:?} at {}: {:?}", cmd, at, text),
                (None, _) => prop_assert_eq!(appended, rows == 1, "{:?} at {}: {:?}", cmd, at, text),
                _ => prop_assert!(info2.rows == rows || appended),
            }
        } else {
            prop_assert_eq!((info2.rows, info2.columns), (er, ec), "{:?} at {}: {:?} -> {:?}", cmd, at, text, new);
        }
        // The result is aligned.
        prop_assert!(doc2.table_command(TableCommand::Realign, edit.selection).is_none(), "{cmd:?} left it misaligned: {new:?}");
    }

    #[test]
    fn inserted_tables_are_tables(text in md_tokens(20), pos in any::<u32>(), rows in 0u32..4, cols in 0u32..5, enc_i in 0usize..3) {
        let enc = ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let at = pos % (doc.len() + 1);
        let edit = doc.table_command(TableCommand::Insert { rows, columns: cols }, TextRange::new(at, at)).expect("insert always works");
        let new = check_edit_applies(&text, enc, &edit)?;
        let doc2 = Document::new(&new, enc);
        // Unless the surroundings swallow it (inside a code block, an HTML block, front matter...),
        // the caret is in a table of the requested shape.
        if let Some(t) = doc2.table_at(edit.selection.start) {
            prop_assert_eq!((t.rows, t.columns), (rows + 1, cols.clamp(1, 100)), "{:?} at {} -> {:?}", text, at, new);
            prop_assert_eq!((t.row, t.column), (Some(0), Some(0)));
        }
    }
}

// ----- exhaustive sweeps ------------------------------------------------------------------------------

/// Every command on every selection of some nasty documents: nothing panics and every edit
/// applies. (Includes the shape that once overflowed a subtraction in ordered-list renumbering.)
/// Samples every 7th selection by default; `SWEEP_STRIDE=1` tries them all (about a minute in debug).
#[test]
fn every_command_on_every_selection() {
    let docs = [
        "- [ ] ~~~# *| x > [r]: /u\n]| x | a | b |\n| a | b |\n- [ ] \n\n1. <b>\t\n\n---\n- | a | b |\n1. > 1. ",
        "1. a\n3. b\n   1. c\n   2. d\n9. e\n10. f\n",
        "> - a\n>   - b\n> - c\n>\n> ```\n> code\n> ```\n",
        "| a | b |\n|:-:|--:|\n| \u{65E5}\u{672C} | \u{1F600} |\r\n| x\\|y |\r\n",
        "# T\n\nsetext\n===\n\n- a\n\n  para\n- b\n\n```\n\u{1F389} `x`\n```\n\nwww.a.com **b** [c](d)\r\n",
        "***a** b* ~~c~~ `` ` `` [![i](p)](q) <http://x.y>",
    ];
    let stride: usize = std::env::var("SWEEP_STRIDE").ok().and_then(|s| s.parse().ok()).unwrap_or(7);
    for text in docs {
        for (enc_i, enc) in ENCODINGS.into_iter().enumerate() {
            let doc = Document::new(text, enc);
            let b = boundaries(text, enc);
            let mut n = enc_i;
            for &s in &b {
                for &e in b.iter().filter(|&&e| e >= s) {
                    n += 1;
                    if n % stride != 0 {
                        continue;
                    }
                    let sel = TextRange::new(s, e);
                    let mut edits: Vec<(String, Option<TextEdit>)> = Vec::new();
                    for c in all_commands() {
                        edits.push((format!("{c:?}"), doc.format(c.clone(), sel)));
                    }
                    edits.push(("newline".into(), doc.newline(sel)));
                    edits.push(("indent".into(), doc.indent(sel, false)));
                    edits.push(("outdent".into(), doc.indent(sel, true)));
                    for c in all_table_commands() {
                        edits.push((format!("{c:?}"), doc.table_command(c, sel)));
                    }
                    let _ = doc.format_state(sel);
                    for (name, edit) in edits {
                        if let Some(edit) = edit
                            && let Err(err) = apply_edit(text, enc, &edit)
                        {
                            panic!("{name} on {sel:?} of {text:?} ({enc:?}): {err}");
                        }
                    }
                }
            }
        }
    }
}
