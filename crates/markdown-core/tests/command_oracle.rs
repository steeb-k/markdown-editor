//! Oracle tests for the editing commands, judged by what the edited text *parses to* (with
//! pulldown-cmark directly), not by how the core describes it:
//!
//! * wrapping a selection in strong/emphasis/strikethrough leaves the rendered text content
//!   unchanged and `format_state` reports the format over the resulting selection;
//! * Return, Tab and Shift-Tab change structure only: the text content (everything but blanks,
//!   list and quote markers and renumbered digits) is unchanged;
//! * table helpers keep every cell's text (deletions only remove), and re-analysis finds the
//!   expected shape;
//! * nothing but the dedicated commands writes into code, HTML or front matter;
//! * no edit starts or ends inside a CRLF pair.
mod common;
use common::*;
use markdown_core::*;
use proptest::prelude::*;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

fn cases() -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(400)
}

fn options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
}

/// What a reader sees: text and code content, whitespace collapsed.
fn text_content(md: &str) -> String {
    let mut out = String::new();
    for ev in Parser::new_ext(md, options()) {
        match ev {
            Event::Text(t) | Event::Code(t) | Event::Html(t) | Event::InlineHtml(t) => out.push_str(&t),
            Event::SoftBreak | Event::HardBreak => out.push(' '),
            // Block boundaries separate words; inline ones do not.
            Event::Start(t) if !is_inline(&t) => out.push(' '),
            Event::End(t) if !is_inline_end(&t) => out.push(' '),
            Event::TaskListMarker(c) => out.push_str(if c { "[x]" } else { "[ ]" }),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A code span or link that crosses a line break inside a quote or list item: wrapping goes line
/// by line there and may cut through it. Known limit; left out.
fn multiline_atoms(md: &str) -> bool {
    Parser::new_ext(md, options()).into_offset_iter().any(|(ev, r)| {
        matches!(ev, Event::Code(_) | Event::Start(Tag::Link { .. } | Tag::Image { .. })) && md[r].contains(['\n', '\r'])
    })
}

fn is_inline(t: &Tag) -> bool {
    matches!(t, Tag::Emphasis | Tag::Strong | Tag::Strikethrough | Tag::Link { .. } | Tag::Image { .. })
}

fn is_inline_end(t: &TagEnd) -> bool {
    matches!(t, TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough | TagEnd::Link | TagEnd::Image)
}

/// The content of every code block, HTML block and front matter, in order.
fn opaque_contents(md: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur: Option<String> = None;
    for (ev, r) in Parser::new_ext(md, options()).into_offset_iter() {
        match ev {
            // pulldown-cmark 0.13 also reads `---` inside a list item as front matter; only the
            // real thing (at the very start) counts.
            Event::Start(Tag::MetadataBlock(_)) if r.start > 0 => {}
            Event::End(TagEnd::MetadataBlock(_)) if r.start > 0 => {}
            Event::Start(Tag::CodeBlock(_) | Tag::HtmlBlock | Tag::MetadataBlock(_)) => cur = Some(String::new()),
            Event::End(TagEnd::CodeBlock | TagEnd::HtmlBlock | TagEnd::MetadataBlock(_)) => out.extend(cur.take()),
            Event::Text(t) | Event::Html(t) if cur.is_some() => cur.as_mut().unwrap().push_str(&t),
            _ => {}
        }
    }
    out
}

/// Text content of every table cell, row by row.
fn table_cells(md: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row: Vec<String> = Vec::new();
    let mut cell: Option<String> = None;
    for ev in Parser::new_ext(md, options()) {
        match ev {
            Event::Start(Tag::TableHead | Tag::TableRow) => row.clear(),
            Event::End(TagEnd::TableHead | TagEnd::TableRow) => rows.push(std::mem::take(&mut row)),
            Event::Start(Tag::TableCell) => cell = Some(String::new()),
            Event::End(TagEnd::TableCell) => row.extend(cell.take().map(|c| c.trim().to_owned())),
            Event::Text(t) | Event::Code(t) if cell.is_some() => cell.as_mut().unwrap().push_str(&t),
            _ => {}
        }
    }
    rows
}

fn tokens(max: usize) -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "word", "word ", "text ", "x", " ", " ", "\n", "\n", "\n\n", "\r\n", "# ", "## ", "> ", "- ", "* ", "1. ", "3) ",
        "- [ ] ", "  ", "    ", "\t", "*", "**", "_", "~~", "`", "[", "](u)", "!", "|", "www.a.b ", "don't ", "\u{e9}",
        "e\u{301}", "\u{65E5}\u{672C}", "\u{1F389}", "```\n", "~~~\n", "<div>\n", "---\n", ",", ".", "(", ")", "\\",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat())
}

/// Like `tokens`, but every inline delimiter is part of a complete element. A stray `*` in the
/// paragraph pairs with a new delimiter (`*a «b»` -> `*a **b**`); that is Markdown, and a known
/// limit of the toggles.
fn balanced_tokens(max: usize) -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "word", "word ", "text ", "x", " ", " ", "\n", "\n", "\n\n", "\r\n", "# ", "## ", "> ", "- ", "1. ", "- [ ] ", "  ",
        "*em* ", "**st** ", "~~s~~ ", "`c` ", "_u_ ", "[l](u) ", "www.a.b ", "don't ", "\u{e9}", "e\u{301}", "\u{65E5}\u{672C}",
        "\u{1F389}", ",", ".", "(", ")", "```\n", "<div>\n",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat())
}

fn sel_on_boundaries(text: &str, enc: OffsetEncoding, a: u32, b: u32) -> TextRange {
    let bounds = boundaries(text, enc);
    let (mut i, mut j) = (a as usize % bounds.len(), b as usize % bounds.len());
    if i > j {
        std::mem::swap(&mut i, &mut j);
    }
    TextRange::new(bounds[i], bounds[j])
}

fn apply(text: &str, enc: OffsetEncoding, e: &TextEdit) -> Result<(String, (usize, usize)), TestCaseError> {
    let r = apply_edit(text, enc, e).map_err(TestCaseError::fail)?;
    // An edit never splits a CRLF pair.
    let (rs, re) = (unit_to_byte(text, enc, e.range.start), unit_to_byte(text, enc, e.range.end));
    let mid = |p: usize| p > 0 && p < text.len() && text.as_bytes()[p - 1] == b'\r' && text.as_bytes()[p] == b'\n';
    prop_assert!(!mid(rs) && !mid(re), "edit splits a CRLF: {e:?} in {text:?}");
    Ok(r)
}

fn is_inside_opaque(doc: &Document, sel: TextRange) -> bool {
    // Top-level blocks only: a quote toggle on a code block nested in a list item re-nests it.
    doc.blocks().iter().any(|b| {
        b.depth == 0
            && matches!(b.kind, BlockKind::CodeBlock | BlockKind::HtmlBlock | BlockKind::FrontMatter)
            && b.range.start <= sel.start
            && sel.end <= b.range.end
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases()))]

    #[test]
    fn wrapping_keeps_the_text_and_turns_the_format_on(text in balanced_tokens(24), a in any::<u32>(), b in any::<u32>(), kind in 0usize..3, enc_i in 0usize..3) {
        let enc = ALL_ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let sel = sel_on_boundaries(&text, enc, a, b);
        let cmd = [FormatCommand::Strong, FormatCommand::Emphasis, FormatCommand::Strikethrough][kind].clone();
        let on = |s: FormatState| [s.strong, s.emphasis, s.strikethrough][kind];
        let before = doc.format_state(sel);
        let Some(edit) = doc.format(cmd, sel) else { return Ok(()) };
        let (new, _) = apply(&text, enc, &edit)?;
        // With nothing to wrap, an empty pair is inserted for the caret to type into.
        let empty_pair = edit.range.is_empty() && edit.replacement.chars().all(|c| matches!(c, '*' | '~'));
        let picked = &text[unit_to_byte(&text, enc, sel.start)..unit_to_byte(&text, enc, sel.end)];
        // Wrapping bare punctuation (`*]`) is garbage in, garbage out.
        // A delimiter between punctuation (an emoji counts) and a letter cannot open or close
        // (CommonMark's flanking rules), so a selection that starts or ends with punctuation
        // next to a letter does not format. Known limit; such selections are left out.
        let t = picked.trim();
        let edges_ok = t.chars().next().is_some_and(char::is_alphanumeric) && t.chars().next_back().is_some_and(char::is_alphanumeric);
        let wordless = !picked.is_empty() && !edges_ok;
        // Several paragraphs: each part starts or ends where the paragraph does, and an existing
        // `**` element there merges with new `*` delimiters into one ambiguous run (`***a** b*`).
        // Known limit; covered by hand-written cases instead.
        let several = picked.replace("\r\n", "\n").contains("\n\n");
        // New delimiters right against an existing `*` element make one run of three or more
        // (`***a* b**`), which CommonMark pairs its own way. Known limit (underscores are used
        // where they can be); left out.
        let runs = |t: &str| t.matches("***").count() + t.matches("~~~").count();
        let merged_run = runs(&new) > runs(&text);
        let judged = !wordless && !multiline_atoms(&text) && !several && !merged_run;
        if !empty_pair && judged {
            prop_assert_eq!(text_content(&new), text_content(&text), "{:?} on {:?} of {:?} -> {:?}", kind, sel, text, new);
        }
        if !on(before) && !edit.selection.is_empty() && judged && !picked.is_empty() {
            let doc2 = Document::new(&new, enc);
            // At both ends of the new selection (over the whole of it, nesting that the parser
            // reads the other way round, `***a***`, can leave a delimiter of the outer element in).
            for p in [edit.selection.start, edit.selection.end] {
                prop_assert!(on(doc2.format_state(TextRange::new(p, p))), "{:?} not on at {} in {:?} (from {:?} at {:?})", kind, p, new, text, sel);
            }
        }
    }

    #[test]
    fn return_and_tab_change_structure_not_text(text in tokens(24), a in any::<u32>(), b in any::<u32>(), which in 0u8..3, enc_i in 0usize..3) {
        let enc = ALL_ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let sel = sel_on_boundaries(&text, enc, a, b);
        let edit = match which { 0 => doc.newline(sel), 1 => doc.indent(sel, false), _ => doc.indent(sel, true) };
        let Some(edit) = edit else { return Ok(()) };
        let (new, _) = apply(&text, enc, &edit)?;
        // Return replaces the selection; judge the text around it.
        let (s, e) = (unit_to_byte(&text, enc, sel.start), unit_to_byte(&text, enc, sel.end));
        let old_kept = if which == 0 { format!("{}{}", &text[..s], &text[e..]) } else { text.clone() };
        let strip = |t: &str| t.chars().filter(|c| !c.is_whitespace() && !c.is_ascii_digit() && !matches!(c, '-' | '*' | '+' | '>' | '.' | ')' | '[' | ']')).collect::<String>();
        prop_assert_eq!(strip(&new), strip(&old_kept), "{} on {:?} of {:?} -> {:?}", which, sel, text, new);
    }

    #[test]
    fn nothing_writes_into_code_html_or_front_matter(text in tokens(24), a in any::<u32>(), b in any::<u32>(), enc_i in 0usize..3) {
        let enc = ALL_ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let sel = sel_on_boundaries(&text, enc, a, b);
        if !is_inside_opaque(&doc, sel) {
            return Ok(());
        }
        // Commands on the list item that holds an indented code block may change the item.
        let line_start = text[..unit_to_byte(&text, enc, sel.start)].rfind(['\n', '\r']).map_or(0, |i| i + 1);
        if text[line_start..].trim_start_matches([' ', '\t', '>']).starts_with(['-', '*', '+', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9']) {
            return Ok(());
        }
        let mut cmds: Vec<FormatCommand> = vec![
            FormatCommand::Strong, FormatCommand::Emphasis, FormatCommand::Strikethrough, FormatCommand::InlineCode,
            FormatCommand::Link, FormatCommand::BlockQuote, FormatCommand::BulletList, FormatCommand::OrderedList, FormatCommand::TaskList,
        ];
        cmds.extend((0..=6).map(|level| FormatCommand::Heading { level }));
        let before = opaque_contents(&text);
        for c in cmds {
            // Known limit: a quote marker eats part of a leading tab, so a tab-indented line
            // cannot be quoted with its indentation intact.
            // Taking a quote off changes what the lines belong to (a list before it may take
            // them in); only putting one on is checked.
            // Nor next to an existing quote, which the new one joins.
            if c == FormatCommand::BlockQuote && (text.contains('\t') || text.contains('>')) {
                continue;
            }
            if let Some(edit) = doc.format(c.clone(), sel) {
                let (new, _) = apply(&text, enc, &edit)?;
                prop_assert_eq!(opaque_contents(&new), before.clone(), "{:?} on {:?} of {:?} -> {:?}", c, sel, text, new);
            }
        }
    }
}

// ----- tables ----------------------------------------------------------------------------------

fn cell_text() -> impl Strategy<Value = String> {
    prop::sample::select(vec!["a", "bb", "", "x y", "\u{65E5}\u{672C}", "\u{1F600}", "x\\|y", "`c`", "**b**", "e\u{301}", "1"])
        .prop_map(String::from)
}

fn table_text() -> impl Strategy<Value = String> {
    (1usize..=4).prop_flat_map(|cols| {
        (
            prop::sample::select(vec!["", "> ", "- ", "  "]),
            prop::sample::select(vec!["\n", "\r\n"]),
            prop::collection::vec(prop::collection::vec(cell_text(), cols), 1..5),
            prop::collection::vec(prop::sample::select(vec!["---", ":--", ":-:", "--:"]), cols),
        )
            .prop_map(|(prefix, eol, rows, delim)| {
                let line = |cells: &[String]| format!("| {} |", cells.join(" | "));
                let mut lines = vec![line(&rows[0]), format!("|{}|", delim.join("|"))];
                lines.extend(rows[1..].iter().map(|r| line(r)));
                let cont = if prefix == "- " { "  " } else { prefix };
                lines.iter().enumerate().map(|(i, l)| format!("{}{l}", if i == 0 { prefix } else { cont })).collect::<Vec<_>>().join(eol)
            })
    })
}

fn nonempty(rows: &[Vec<String>]) -> Vec<String> {
    rows.iter().flatten().filter(|c| !c.is_empty()).cloned().collect()
}

fn is_subsequence(small: &[String], big: &[String]) -> bool {
    let mut it = big.iter();
    small.iter().all(|s| it.any(|b| b == s))
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(cases()))]

    #[test]
    fn table_helpers_keep_every_cell(text in table_text(), pos in any::<u32>(), cmd_i in 0usize..12, enc_i in 0usize..3) {
        let enc = ALL_ENCODINGS[enc_i];
        let doc = Document::new(&text, enc);
        let at = pos % (doc.len() + 1);
        let Some(info) = doc.table_at(at) else { return Ok(()) };
        let cmd = [
            TableCommand::AddRowAbove, TableCommand::AddRowBelow, TableCommand::AddColumnLeft, TableCommand::AddColumnRight,
            TableCommand::DeleteRow, TableCommand::DeleteColumn, TableCommand::SetAlignment(ColumnAlignment::Center),
            TableCommand::SetAlignment(ColumnAlignment::Right), TableCommand::NextCell, TableCommand::PreviousCell,
            TableCommand::Realign, TableCommand::SetAlignment(ColumnAlignment::None),
        ][cmd_i];
        let Some(edit) = doc.table_command(cmd, TextRange::new(at, at)) else { return Ok(()) };
        let (new, _) = apply(&text, enc, &edit)?;
        let (old_cells, new_cells) = (table_cells(&text), table_cells(&new));
        prop_assert!(!new_cells.is_empty(), "{cmd:?}: no table left in {new:?}");
        match cmd {
            TableCommand::DeleteRow | TableCommand::DeleteColumn => {
                prop_assert!(is_subsequence(&nonempty(&new_cells), &nonempty(&old_cells)), "{cmd:?} at {at}: {text:?} -> {new:?}");
            }
            _ => prop_assert_eq!(nonempty(&new_cells), nonempty(&old_cells), "{:?} at {}: {:?} -> {:?}", cmd, at, text, new),
        }
        // The parser agrees with the core about the shape.
        let cols = new_cells[0].len() as u32;
        let rows = new_cells.len() as u32;
        let expect = match cmd {
            TableCommand::AddRowAbove | TableCommand::AddRowBelow => (info.rows + 1, info.columns),
            TableCommand::AddColumnLeft | TableCommand::AddColumnRight => (info.rows, info.columns + 1),
            TableCommand::DeleteRow => (info.rows - 1, info.columns),
            TableCommand::DeleteColumn => (info.rows, info.columns - 1),
            TableCommand::NextCell if rows == info.rows + 1 => (info.rows + 1, info.columns),
            _ => (info.rows, info.columns),
        };
        prop_assert_eq!((rows, cols), expect, "{:?} at {}: {:?} -> {:?}", cmd, at, text, new);
        // Every row of the parsed table has the header's column count (no ragged rows left).
        prop_assert!(new_cells.iter().all(|r| r.len() as u32 == cols));
    }
}
