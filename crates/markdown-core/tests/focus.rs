//! Focus mode: hand-written expectations per construct, then properties, then parts of speech.
//!
//! Selections are written into the text: `¦` is a caret, `⟪…⟫` a selection. Both markers are
//! removed before the text reaches the core. Every expectation runs in all three encodings and
//! must give the same text.
mod common;
use common::*;
use markdown_core::*;
use proptest::prelude::*;

const ENCODINGS: [OffsetEncoding; 3] = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32];

/// The text without markers, and the selection as byte offsets.
fn parse(marked: &str) -> (String, usize, usize) {
    let mut text = String::new();
    let (mut a, mut b) = (None, None);
    for ch in marked.chars() {
        match ch {
            '¦' => {
                a = Some(text.len());
                b = a;
            }
            '⟪' => a = Some(text.len()),
            '⟫' => b = Some(text.len()),
            c => text.push(c),
        }
    }
    let a = a.unwrap_or(text.len());
    (text, a, b.unwrap_or(a))
}

/// Byte offset to the unit offset of `enc`.
fn unit_of(text: &str, byte: usize, enc: OffsetEncoding) -> u32 {
    text[..byte]
        .chars()
        .map(|c| match enc {
            OffsetEncoding::Utf8 => c.len_utf8(),
            OffsetEncoding::Utf16 => c.len_utf16(),
            OffsetEncoding::Utf32 => 1,
        })
        .sum::<usize>() as u32
}

/// The focused source pieces for a marked selection, checked to agree across encodings.
#[track_caller]
fn focus(marked: &str, scope: FocusScope) -> Vec<String> {
    let (text, a, b) = parse(marked);
    let mut all: Vec<Vec<String>> = Vec::new();
    for enc in ENCODINGS {
        let doc = Document::new(&text, enc);
        let sel = TextRange::new(unit_of(&text, a, enc), unit_of(&text, b, enc));
        let ranges = doc.focus_range(sel, scope);
        all.push(ranges.iter().map(|&r| slice_units(&text, enc, r)).collect());
        check_ranges(&doc, &ranges).unwrap_or_else(|e| panic!("{marked:?} {enc:?}: {e}"));
    }
    assert_eq!(all[0], all[1], "UTF-8 and UTF-16 disagree for {marked:?}");
    assert_eq!(all[0], all[2], "UTF-8 and UTF-32 disagree for {marked:?}");
    all.remove(0)
}

fn check_ranges(doc: &Document, ranges: &[TextRange]) -> Result<(), String> {
    let ok = boundaries(doc.text(), doc.encoding());
    let mut prev_end: Option<u32> = None;
    for r in ranges {
        if r.start >= r.end || r.end > doc.len() {
            return Err(format!("bad range {r:?}"));
        }
        if ok.binary_search(&r.start).is_err() || ok.binary_search(&r.end).is_err() {
            return Err(format!("range {r:?} is not on code point boundaries"));
        }
        if prev_end.is_some_and(|p| r.start <= p) {
            return Err(format!("ranges overlap or touch: {ranges:?}"));
        }
        prev_end = Some(r.end);
    }
    Ok(())
}

#[track_caller]
fn s(marked: &str, expect: &[&str]) {
    assert_eq!(focus(marked, FocusScope::Sentence), expect, "sentence scope, {marked:?}");
}

#[track_caller]
fn p(marked: &str, expect: &[&str]) {
    assert_eq!(focus(marked, FocusScope::Paragraph), expect, "paragraph scope, {marked:?}");
}

// ---------- paragraphs ----------

#[test]
fn paragraph_is_the_block_at_the_caret() {
    p("One two.\nThree¦.\n\nOther.", &["One two.\nThree."]);
    p("One two.\nThree.\n\n¦Other.", &["Other."]);
    p("One¦", &["One"]);
    p("¦One", &["One"]);
}

#[test]
fn heading_is_its_own_unit() {
    p("# Title ¦here\n\nbody", &["# Title here"]);
    p("# Title here\n¦body", &["body"]);
    p("Setext ¦title\n=====\n\nbody", &["Setext title\n====="]);
    p("## Closed ##¦\n", &["## Closed ##"]);
}

#[test]
fn list_item_is_its_own_unit_not_the_list() {
    p("- one\n- t¦wo\n- three", &["- two"]);
    p("- one\n- two\n  continues ¦here\n- three", &["- two\n  continues here"]);
    p("1. one\n2. t¦wo", &["2. two"]);
    p("- [ ] ta¦sk\n- [x] done", &["- [ ] task"]);
}

#[test]
fn caret_in_the_marker_belongs_to_the_item() {
    p("- one\n¦- two", &["- two"]);
    p("- one\n-¦ two", &["- two"]);
    p("- one\n  ¦- nested", &["  - nested"]);
}

#[test]
fn nested_lists_focus_the_innermost_item() {
    p("- outer\n  - in¦ner\n    - deep\n- next", &["  - inner"]);
    p("- outer\n  - inner\n    - de¦ep\n- next", &["    - deep"]);
    p("- out¦er\n  - inner", &["- outer"]);
}

#[test]
fn quote_lines_keep_their_prefixes() {
    p("> one\n> tw¦o\n\nafter", &["> one\n> two"]);
    p("> a\n>\n> b¦", &["> b"]);
    p("> > nested ¦quote", &["> > nested quote"]);
    p("> - item ¦in quote\n> - next", &["> - item in quote"]);
}

#[test]
fn code_block_is_focused_whole() {
    p("para\n\n```rs\nlet a;\nle¦t b;\n```\n\nafter", &["```rs\nlet a;\nlet b;\n```"]);
    p("```\n¦\n```", &["```\n\n```"]);
    p("    indented\n    c¦ode\n\nafter", &["    indented\n    code"]);
    p("- item\n\n  ```\n  c¦ode\n  ```\n", &["  ```\n  code\n  ```"]);
    p("> ```\n> c¦ode\n> ```", &["> ```\n> code\n> ```"]);
}

#[test]
fn table_is_focused_whole() {
    p("| a | b |\n|---|---|\n| c¦ | d |\n\nafter", &["| a | b |\n|---|---|\n| c | d |"]);
    p("para\n\n| a | b |\n|---|---|\n¦| c | d |", &["| a | b |\n|---|---|\n| c | d |"]);
}

#[test]
fn front_matter_is_focused_whole() {
    p("---\ntitle: x\nta¦gs: y\n---\n\nbody", &["---\ntitle: x\ntags: y\n---"]);
}

#[test]
fn blank_lines_and_gaps_focus_nothing() {
    p("one\n¦\ntwo", &[]);
    p("one\n\n¦\n\ntwo", &[]);
    p("¦", &[]);
    p("¦\none", &[]);
    p("> a\n¦>\n> b", &[]);
    s("one.\n¦\ntwo.", &[]);
    p("one\n\n   ¦\ntwo", &[]);
}

#[test]
fn crlf_and_lone_cr() {
    p("One.\r\nTw¦o.\r\n\r\nNext.", &["One.\r\nTwo."]);
    s("One. Two\r\nthree. ¦Four.", &["Four."]);
    s("One. Two\r\nth¦ree. Four.", &["Two\r\nthree. "]);
    p("a\rb¦\r\rc", &["a\rb"]);
}

// ---------- sentences ----------

#[test]
fn sentences_of_a_paragraph() {
    s("First one. Sec¦ond one. Third one.", &["Second one. "]);
    s("¦First one. Second one.", &["First one. "]);
    s("First one. Second one.¦", &["Second one."]);
    s("Hello? Yes! Right¦.", &["Right."]);
    s("Is it? ¦Yes!", &["Yes!"]);
}

#[test]
fn trailing_whitespace_belongs_to_the_sentence_before() {
    s("One.¦ Two.", &["One. "]);
    s("One. ¦ Two.", &["One.  "]);
    s("One.  ¦Two.", &["Two."]);
    s("One. ¦Two.", &["Two."]);
}

#[test]
fn a_sentence_runs_over_soft_line_breaks() {
    s("This is one\nsentence that wraps\nacross ¦three lines. Next one.", &["This is one\nsentence that wraps\nacross three lines. "]);
    s("Ends here.\nNew¦ one starts.", &["New one starts."]);
}

#[test]
fn a_sentence_runs_over_the_prefixes_of_a_quote() {
    s("> This runs\n> across ¦lines. Next one.", &["> This runs\n> across lines. "]);
    s("> First.\n> Sec¦ond.", &["> Second."]);
    s("> First. Sec¦ond\n> goes on.\n> Third.", &["Second\n> goes on.\n"]);
}

#[test]
fn a_sentence_runs_over_the_indent_of_a_list_item() {
    s("- This runs\n  across ¦lines. Next one.", &["- This runs\n  across lines. "]);
    s("- One. Tw¦o\n  goes on.", &["Two\n  goes on."]);
}

#[test]
fn markup_at_the_edges_belongs_to_the_sentence() {
    s("**Bo¦ld.** Next", &["**Bold.** "]);
    s("**Bold.** Ne¦xt", &["Next"]);
    s("[Bold!](u)¦Next", &["Next"]);
    s("[Bo¦ld!](u)Next", &["[Bold!](u)"]);
    s("Done. **Ne¦xt** one.", &["**Next** one."]);
    s("Done. *Ne¦xt.* More.", &["*Next.* "]);
    s("One. [Lin¦k text.](http://x.y/z) Two.", &["[Link text.](http://x.y/z) "]);
    s("*Wrapped. Ins¦ide.* After.", &["Inside.* "]);
    s("*Wrapped. Inside.* Af¦ter.", &["After."]);
}

#[test]
fn code_urls_and_images_do_not_split_sentences() {
    s("Use `a. b` to ¦go. Then stop.", &["Use `a. b` to go. "]);
    s("See https://example.com/a.b. Next¦.", &["Next."]);
    s("Try `x`. ¦Then `y` now.", &["Then `y` now."]);
    s("A ![alt. text](p.png) b¦ c. D.", &["A ![alt. text](p.png) b c. "]);
}

#[test]
fn abbreviations_are_whatever_uax_29_says() {
    // A capital after the period splits (the standard has no abbreviation list).
    s("Dr. Smith ¦left. Then", &["Smith left. "]);
    s("Dr. S¦mith left.", &["Smith left."]);
    // A lowercase letter after the period does not.
    s("See e.g. ¦this one. Then.", &["See e.g. this one. "]);
    s("It costs 3.5 do¦llars. Next.", &["It costs 3.5 dollars. "]);
}

#[test]
fn a_heading_or_item_holds_its_own_sentences() {
    s("# One. T¦wo.\n\nBody.", &["Two."]);
    s("# On¦e. Two.\n\nBody.", &["# One. "]);
    s("- One. T¦wo.\n- Three.", &["Two."]);
    s("- One.\n- T¦wo.", &["- Two."]);
    s("Title ¦one. Two.\n=====", &["Title one. "]);
}

#[test]
fn code_tables_and_front_matter_focus_whole_in_sentence_scope_too() {
    s("```\na. b.\nc¦. d.\n```", &["```\na. b.\nc. d.\n```"]);
    s("| a. b | c |\n|---|---|\n| d¦ | e |", &["| a. b | c |\n|---|---|\n| d | e |"]);
    s("---\nk: a. b.\nl¦: c\n---", &["---\nk: a. b.\nl: c\n---"]);
}

#[test]
fn cjk_text_with_ideographic_full_stops() {
    s("你好。世¦界！再见。", &["世界！"]);
    s("你好。世界！再¦见。", &["再见。"]);
    s("¦你好。世界！", &["你好。"]);
    s("日本語の文章です。次の文¦です。", &["次の文です。"]);
}

#[test]
fn emoji_do_not_confuse_offsets() {
    s("Party \u{1F389}\u{1F389}! Next ¦one \u{1F468}\u{200D}\u{1F469}. Last.", &["Next one \u{1F468}\u{200D}\u{1F469}. "]);
    s("e\u{301}t\u{e9}. Fin¦.", &["Fin."]);
}

#[test]
fn a_selection_focuses_every_unit_it_overlaps() {
    s("One. ⟪Two. Three⟫. Four.", &["Two. Three. "]);
    s("One. T⟪wo. Th⟫ree. Four.", &["Two. Three. "]);
}

#[test]
fn selection_across_paragraphs_lights_up_all_and_the_gap() {
    p("one\n\ntw⟪o\n\nthr⟫ee\n\nfour", &["two\n\nthree"]);
    p("one\n\n⟪two\n\n⟫three", &["two\n\n"]);
    p("⟪one\n⟫\ntwo", &["one\n"]);
    s("A. B. ⟪C. D.⟫ E.", &["C. D. "]);
}

#[test]
fn a_selection_ending_at_the_start_of_a_block_does_not_take_it_in() {
    p("one\n\n⟪two\n\n⟫three", &["two\n\n"]);
    p("one\n\n⟪two\n⟫\nthree", &["two\n"]);
}

#[test]
fn selection_state_is_the_three_queries_in_one() {
    let text = "# T\n\nOne. **Two.** Three.\n\n- [ ] a\n- b\n";
    for enc in ENCODINGS {
        let doc = Document::new(text, enc);
        for byte in 0..=text.len() {
            if !text.is_char_boundary(byte) {
                continue;
            }
            let sel = TextRange::new(unit_of(text, byte, enc), unit_of(text, byte, enc));
            let w = TextRange::new(0, doc.len());
            for scope in [None, Some(FocusScope::Sentence), Some(FocusScope::Paragraph)] {
                for conceal in [false, true] {
                    let st = doc.selection_state(sel, Some(w), conceal, scope);
                    assert_eq!(st.format_state, doc.format_state(sel));
                    assert_eq!(st.table, doc.table_at(sel.start));
                    assert_eq!(st.concealment, conceal.then(|| doc.concealment(sel, Some(w))));
                    assert_eq!(st.focus, scope.map(|sc| doc.focus_range(sel, sc)));
                }
            }
        }
    }
}

// ---------- properties ----------

/// Sentence-like text with markup, so that sentence cuts and markup meet often.
fn md_text(max: usize) -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "Word ", "word ", "Dr. ", "e.g. ", "end. ", "Next. ", "why? ", "no! ", "**", "*", "_", "~~", "`", "`c. d` ", "[", "](http://a.b/c) ",
        "![", "](i.png) ", "\n", "\n\n", "\r\n", "> ", "- ", "1. ", "- [ ] ", "# ", "## ", "```\n", "---\n", "| a | b |\n", "|---|---|\n",
        "    ", "  ", " ", "\u{4F60}\u{597D}\u{3002}", "\u{1F389} ", "e\u{301}", "http://a.b/c. ", "<b>", "\\", "===\n", "[r]: /u\n", "[^1]", "[^1]: ",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat())
}

/// The lines (without terminators) of the text, as byte ranges, computed independently.
fn line_ranges(text: &str) -> Vec<(usize, usize)> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let (mut s, mut i) = (0, 0);
    while i < b.len() {
        match b[i] {
            b'\n' => {
                out.push((s, i));
                s = i + 1;
            }
            b'\r' => {
                out.push((s, i));
                if b.get(i + 1) == Some(&b'\n') {
                    i += 1;
                }
                s = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    out.push((s, b.len()));
    out
}

/// Is byte offset `p` on one of the lines of a leaf block?
fn in_a_block(text: &str, doc: &Document, p: usize, enc: OffsetEncoding) -> bool {
    let lines = line_ranges(text);
    // Units to bytes, independently.
    let to_byte = |u: u32| -> usize {
        let mut unit = 0u32;
        for (b, ch) in text.char_indices() {
            if unit == u {
                return b;
            }
            unit += match enc {
                OffsetEncoding::Utf8 => ch.len_utf8() as u32,
                OffsetEncoding::Utf16 => ch.len_utf16() as u32,
                OffsetEncoding::Utf32 => 1,
            };
        }
        text.len()
    };
    // A position between the CR and LF of a CRLF is on the line the pair ends.
    let line = lines.iter().rposition(|&(s, _)| s <= p).unwrap();
    let (ls, le) = lines[line];
    let le = le.max(ls);
    doc.blocks().iter().any(|bl| {
        let (bs, be) = (to_byte(bl.range.start), to_byte(bl.range.end));
        let first = lines.iter().rposition(|&(s, _)| s <= bs).unwrap();
        let last = lines.iter().rposition(|&(s, _)| s <= be.saturating_sub(1).max(bs)).unwrap();
        lines[first].0 <= ls && le <= lines[last].1
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(120)
    ))]

    #[test]
    fn caret_answers_hold_the_contract(text in md_text(30)) {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            let ok = boundaries(&text, enc);
            for byte in 0..=text.len() {
                if !text.is_char_boundary(byte) { continue; }
                // Not a caret position: between the CR and the LF of a line break.
                if byte > 0 && text.as_bytes()[byte - 1] == b'\r' && text.as_bytes().get(byte) == Some(&b'\n') { continue; }
                let c = unit_of(&text, byte, enc);
                let caret = TextRange::new(c, c);
                let para = doc.focus_range(caret, FocusScope::Paragraph);
                let sent = doc.focus_range(caret, FocusScope::Sentence);
                if let Err(e) = check_ranges(&doc, &para).and_then(|_| check_ranges(&doc, &sent)) {
                    return Err(TestCaseError::fail(format!("{enc:?} {text:?} caret {c}: {e}")));
                }
                // One range for a caret, containing it or next to it.
                prop_assert!(para.len() <= 1 && sent.len() <= 1);
                for r in para.iter().chain(&sent) {
                    prop_assert!(r.start <= c && c <= r.end, "{enc:?} {text:?} caret {c} outside {r:?}");
                }
                // Nothing lit exactly when the caret is outside every block's lines.
                let inside = in_a_block(&text, &doc, byte, enc);
                prop_assert_eq!(!para.is_empty(), inside, "{:?} {:?} caret {}", enc, text, c);
                prop_assert_eq!(!sent.is_empty(), inside);
                // Paragraph scope contains sentence scope.
                if let (Some(p), Some(s)) = (para.first(), sent.first()) {
                    prop_assert!(p.start <= s.start && s.end <= p.end, "{enc:?} {text:?} caret {c}: {s:?} not in {p:?}");
                    // Stability: every caret inside the sentence gives the same range.
                    for &q in ok.iter().filter(|&&q| s.start <= q && q < s.end) {
                        let again = doc.focus_range(TextRange::new(q, q), FocusScope::Sentence);
                        prop_assert_eq!(&again, &sent, "{:?} {:?} caret {} vs {} in {:?}", enc, text, c, q, s);
                    }
                    for &q in ok.iter().filter(|&&q| p.start <= q && q < p.end) {
                        let again = doc.focus_range(TextRange::new(q, q), FocusScope::Paragraph);
                        prop_assert_eq!(&again, &para, "{:?} {:?} caret {} vs {}", enc, text, c, q);
                    }
                }
            }
        }
    }

    #[test]
    fn selections_answer_in_order_and_cover_themselves(text in md_text(24), a in 0usize..200, b in 0usize..200) {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            // Positions that are carets: not between the CR and the LF of a line break.
            let mid: Vec<u32> = text
                .char_indices()
                .filter(|&(i, _)| i > 0 && text.as_bytes()[i - 1] == b'\r' && text.as_bytes()[i] == b'\n')
                .map(|(i, _)| unit_of(&text, i, enc))
                .collect();
            let ok: Vec<u32> = boundaries(&text, enc).into_iter().filter(|u| !mid.contains(u)).collect();
            let (x, y) = (ok[a % ok.len()], ok[b % ok.len()]);
            let sel = TextRange::new(x, y);
            for scope in [FocusScope::Sentence, FocusScope::Paragraph] {
                let r = doc.focus_range(sel, scope);
                if let Err(e) = check_ranges(&doc, &r) {
                    return Err(TestCaseError::fail(format!("{enc:?} {text:?} {sel:?}: {e}")));
                }
                // The selection (either way round) lies inside what is lit.
                let (lo, hi) = (x.min(y), x.max(y));
                if lo < hi {
                    prop_assert!(r.iter().any(|q| q.start <= lo && hi <= q.end), "{enc:?} {text:?} {sel:?}: {r:?}");
                } else if let Some(c) = r.first() {
                    prop_assert!(c.start <= lo && lo <= c.end);
                }
                // A window never adds anything: what it returns is a subset of the whole.
                let w = TextRange::new(ok[a % ok.len()].min(ok[b % ok.len()]), ok[a % ok.len()].max(ok[b % ok.len()]));
                let st = doc.selection_state(sel, Some(w), false, Some(scope));
                let windowed = st.focus.unwrap();
                for q in &windowed {
                    prop_assert!(r.iter().any(|f| f.start <= q.start && q.end <= f.end) || lo < hi, "{windowed:?} vs {r:?}");
                }
            }
        }
    }

    #[test]
    fn pos_units_cover_exactly_the_prose(text in md_text(30)) {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            let prose = doc.prose_ranges(None);
            let units = doc.pos_units(None);
            let flat: Vec<TextRange> = units.iter().flat_map(|u| u.prose.iter().copied()).collect();
            prop_assert_eq!(&flat, &prose, "{:?} {:?}", enc, text);
            let mut prev_end = 0;
            for u in &units {
                prop_assert_eq!(u.prose.len(), u.separated.len());
                prop_assert!(!u.prose.is_empty() && !u.separated[0]);
                prop_assert!(u.range.start >= prev_end || u.range.start == 0, "{:?} {:?}", enc, text);
                prev_end = u.range.end;
                for pc in &u.prose {
                    prop_assert!(u.range.start <= pc.start && pc.end <= u.range.end, "{enc:?} {text:?}: {pc:?} outside {:?}", u.range);
                }
            }
            // Windowed: whole units, in order, those that intersect the window.
            let len = doc.len();
            for (a, b) in [(0, len / 2), (len / 3, len / 3 * 2), (len, len)] {
                let w = TextRange::new(a, b);
                let some = doc.pos_units(Some(w));
                let mut it = units.iter();
                for u in &some {
                    prop_assert!(it.any(|x| x == u), "{enc:?} {text:?} {w:?}: {u:?} is not one of the units");
                }
                for u in &units {
                    let hit = u.prose.iter().any(|pc| if a == b { pc.start <= a && a < pc.end } else { pc.start < b && pc.end > a });
                    if hit {
                        prop_assert!(some.contains(u), "{enc:?} {text:?} {w:?}: missing {u:?}");
                    }
                }
            }
        }
    }
}

// ---------- parts of speech ----------

fn units(text: &str) -> (Document, Vec<PosUnit>) {
    let doc = Document::new(text, OffsetEncoding::Utf16);
    let u = doc.pos_units(None);
    (doc, u)
}

#[test]
fn pos_units_are_one_per_block_with_prose() {
    let text = "# Head *er*\n\nSome `code` and [a link](http://x.y) here\nsecond line.\n\n```\ncode\n```\n\n- item one\n- item two\n\n---\nk: v\n---\n";
    let (doc, u) = units(text);
    let strings: Vec<Vec<String>> =
        u.iter().map(|u| u.prose.iter().map(|r| slice_units(text, OffsetEncoding::Utf16, *r)).collect()).collect();
    assert_eq!(strings[0], ["Head ", "er"]);
    assert_eq!(strings[1], ["Some ", " and ", "a link", " here", "second line."]);
    assert_eq!(strings[2], ["item one"]);
    assert_eq!(strings[3], ["item two"]);
    assert_eq!(u.len(), 4);
    assert_eq!(u[1].separated, [false, false, false, false, true]);
    assert_eq!(u[1].joined_len() as usize, "Some  and a link here second line.".len());
    let _ = doc;
}

#[test]
fn table_cells_are_separated() {
    let text = "| ab | cd |\n|----|----|\n| ef | gh |\n";
    let (_, u) = units(text);
    assert_eq!(u.len(), 1);
    assert_eq!(u[0].prose.len(), 4);
    assert_eq!(u[0].separated, [false, true, true, true]);
}

#[test]
fn map_tags_gives_document_ranges() {
    let text = "Some **bold** words\ncontinue here.";
    let (_, u) = units(text);
    let u = &u[0];
    // Joined: "Some bold words continue here."
    let joined = "Some bold words continue here.";
    assert_eq!(u.joined_len() as usize, joined.len());
    let word = |w: &str| {
        let s = joined.find(w).unwrap() as u32;
        PosTag { range: TextRange::new(s, s + w.len() as u32), class: PosClass::Noun }
    };
    let mapped = u.map_tags(&[word("bold"), word("continue"), word("here")]);
    let src: Vec<&str> = mapped.iter().map(|t| &text[t.range.start as usize..t.range.end as usize]).collect();
    assert_eq!(src, ["bold", "continue", "here"]);
    // A word that spans pieces is cut at the markup; the separator maps to nothing.
    let across = u.map_tags(&[PosTag { range: TextRange::new(3, 8), class: PosClass::Verb }]);
    let src: Vec<&str> = across.iter().map(|t| &text[t.range.start as usize..t.range.end as usize]).collect();
    assert_eq!(src, ["e ", "bol"]);
    let sep = u.map_tags(&[PosTag { range: TextRange::new(15, 16), class: PosClass::Verb }]);
    assert!(sep.is_empty(), "{sep:?}");
    assert!(u.map_tags(&[PosTag { range: TextRange::new(100, 110), class: PosClass::Verb }]).is_empty());
}

#[test]
fn map_tags_in_utf16_with_emoji() {
    let text = "\u{1F389} party **time** now";
    let (_, u) = units(text);
    let joined = "\u{1F389} party time now";
    let utf16 = |s: &str| s.encode_utf16().count() as u32;
    let s = utf16("\u{1F389} party ");
    let t = u[0].map_tags(&[PosTag { range: TextRange::new(s, s + 4), class: PosClass::Noun }]);
    assert_eq!(t.len(), 1);
    assert_eq!(t[0].range, TextRange::new(utf16("\u{1F389} party **"), utf16("\u{1F389} party **time")));
    assert_eq!(u[0].joined_len(), utf16(joined));
}
