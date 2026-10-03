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
fn link_reference_definitions_are_lit_by_their_lines() {
    // The block model leaves them out; typing in one must not leave it dimmed.
    let doc = "Para.\n\n[ref]: http://x.y\n  \"Title\"\n[b]: /u\n\nAfter.";
    let at = doc.find("x.y").unwrap();
    let marked = format!("{}¦{}", &doc[..at], &doc[at..]);
    p(&marked, &["[ref]: http://x.y\n  \"Title\"\n[b]: /u"]);
    s(&marked, &["[ref]: http://x.y\n  \"Title\"\n[b]: /u"]);
    p("- item\n\n  [r]: /¦x", &["  [r]: /x"]);
    p("> [q]: /¦x\n> text", &["> [q]: /x"]);
    // Still nothing on blank lines and quote-marker-only lines.
    p("[r]: /x\n¦\nPara.", &[]);
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

/// A selection made before the view scrolls to it lies outside the query's window: it lights
/// itself only, never a unit at the window's edge that has nothing to do with it.
#[test]
fn a_selection_outside_the_window_lights_only_itself() {
    let text = "First one. Second one.\n\nThird one here. Fourth.\n\nFifth para. Sixth.\n";
    let doc = Document::new(text, OffsetEncoding::Utf8);
    let sel = TextRange::new(0, 5);
    let window = TextRange::new(text.find("Fifth").unwrap() as u32, text.len() as u32);
    for scope in [FocusScope::Sentence, FocusScope::Paragraph] {
        let st = doc.selection_state(sel, Some(window), false, Some(scope));
        assert_eq!(st.focus, Some(vec![sel]), "{scope:?}");
        // And one that meets the window gets its units there.
        let sel2 = TextRange::new(text.find("Fourth").unwrap() as u32, text.find("para").unwrap() as u32);
        let st = doc.selection_state(sel2, Some(window), false, Some(scope));
        let clip = |rs: Vec<TextRange>| -> Vec<(u32, u32)> {
            rs.iter().map(|r| (r.start.max(window.start), r.end.min(window.end))).filter(|r| r.0 < r.1).collect()
        };
        assert_eq!(clip(st.focus.unwrap()), clip(doc.focus_range(sel2, scope)), "{scope:?}");
    }
}

/// A selection of only the CR of a CRLF ends between the CR and the LF, which is the position
/// before the CR: it is a caret there, and a caret lights its unit whatever the window (the
/// proptest seed `ec984a98`).
#[test]
fn a_selection_of_only_a_cr_is_a_caret_before_it() {
    let text = "Word **\n\n**\r\n`c. d` ![****===\n****1. ";
    let cr = text.find('\r').unwrap() as u32;
    for enc in ENCODINGS {
        let doc = Document::new(text, enc);
        let sel = TextRange::new(cr, cr + 1);
        let caret = TextRange::new(cr, cr);
        for scope in [FocusScope::Sentence, FocusScope::Paragraph] {
            let want = doc.focus_range(caret, scope);
            // The paragraph that starts with the second `**` (offset 9), outside the window 0..0.
            assert_eq!(want.first().map(|r| r.start), Some(9), "{enc:?} {scope:?}");
            assert!(slice_units(text, enc, want[0]).starts_with("**\r\n"), "{enc:?} {scope:?}");
            assert_eq!(doc.focus_range(sel, scope), want, "{enc:?} {scope:?}");
            for window in [TextRange::new(0, 0), TextRange::new(20, 30)] {
                let st = doc.selection_state(sel, Some(window), false, Some(scope));
                assert_eq!(st.focus.as_ref(), Some(&want), "{enc:?} {scope:?} {window:?}");
            }
        }
    }
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

fn caret_line_is_blank(text: &str, p: usize) -> bool {
    let lines = line_ranges(text);
    let line = lines.iter().rposition(|&(s, _)| s <= p).unwrap();
    let (s, e) = lines[line];
    text[s..e.max(s)].chars().all(|c| matches!(c, ' ' | '\t' | '>'))
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
                // Nothing lit exactly when the caret is outside every block's lines and its
                // line is blank (or holds only quote markers).
                let inside = in_a_block(&text, &doc, byte, enc) || !caret_line_is_blank(&text, byte);
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
            // Short blocks: the pieces are the prose ranges themselves.
            prop_assert_eq!(&flat, &prose, "{:?} {:?}", enc, text);
            if let Err(e) = check_unit_tiling(&doc, &units) {
                return Err(TestCaseError::fail(format!("{enc:?} {text:?}: {e}")));
            }
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
fn prose_on_either_side_of_inline_code_is_two_words() {
    // `foo`x`bar` is a word, a piece of code and a word: the tagger must not be handed "foobar".
    let text = "foo`x`bar and **bo**`y`**ld** then `a`b and c`d` end.\n";
    let (_, u) = units(text);
    assert_eq!(u.len(), 1);
    let pieces: Vec<String> = u[0].prose.iter().map(|r| slice_units(text, OffsetEncoding::Utf16, *r)).collect();
    assert_eq!(pieces, ["foo", "bar and ", "bo", "ld", " then ", "b and c", " end."]);
    // Joined text: "foo bar and bo ld then b and c end." (the code is gone, the pieces that touched it are apart).
    let joined: String = joined_text(text, OffsetEncoding::Utf16, &u[0]);
    assert!(joined.starts_with("foo bar and "), "{joined:?}");
    assert!(joined.contains("bo ld then"), "{joined:?}");
    // Code beside a blank leaves the text as it was: no second blank.
    let (_, u) = units("Some `code` and more `code`.\n");
    assert_eq!(joined_text("Some `code` and more `code`.\n", OffsetEncoding::Utf16, &u[0]), "Some  and more .");
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

// ---------- an independent oracle: plain prose against UAX #29 itself ----------

/// Words and punctuation that Markdown leaves as plain prose wherever they fall in a line, as
/// long as a line never starts with one that is not a letter.
const PROSE_WORDS: &[&str] = &[
    "word", "Word", "another", "The", "lowercase", "Dr.", "e.g.", "U.S.A.", "end.", "End.", "why?", "No!", "wait...",
    "\"Quoted.\"", "(paren.)", "3.5", "x,", "y;", "z:", "na\u{EF}ve", "e\u{301}t\u{E9}", "\u{65E5}\u{672C}\u{8A9E}\u{3002}",
    "\u{4F60}\u{597D}\u{FF01}", "\u{1F389}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.", "\u{1F1E9}\u{1F1EA}", "\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947}\u{0964}",
    "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}.", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}.", "'tis", "it's",
];

/// A line of prose: words separated by single spaces, starting with a letter.
fn prose_line(words: &[usize]) -> String {
    let mut out = String::from("A");
    for &w in words {
        out.push(' ');
        out.push_str(PROSE_WORDS[w % PROSE_WORDS.len()]);
    }
    out
}

/// The sentence ranges (bytes) of plain-prose paragraphs, computed with UAX #29 directly: a
/// paragraph's soft breaks are spaces, a sentence runs from one boundary to the next, the
/// first from the paragraph's start, the last to its end.
fn oracle_sentences(text: &str) -> Vec<(usize, usize)> {
    use unicode_segmentation::UnicodeSegmentation;
    let mut out = Vec::new();
    let mut at = 0;
    for para in text.split("\n\n") {
        let flat = para.replace('\n', " ");
        let mut cuts: Vec<usize> = flat.split_sentence_bound_indices().map(|(i, _)| i).collect();
        cuts.push(flat.len());
        for w in cuts.windows(2) {
            out.push((at + w[0], at + w[1]));
        }
        at += para.len() + 2;
    }
    out
}

/// Checks the sentence at many carets of `text` against the oracle, in `enc`.
/// `stride` spaces the carets tried; `every` picks which sentences also have the carets at
/// and beside their edges tried (1: all of them).
fn check_against_oracle(text: &str, enc: OffsetEncoding, stride: usize, every: usize) -> Result<(), String> {
    let doc = Document::new(text, enc);
    let oracle = oracle_sentences(text);
    // Byte offset to unit offset, once.
    let mut units = vec![0u32; text.len() + 1];
    let mut u = 0u32;
    for (b, ch) in text.char_indices() {
        units[b] = u;
        u += match enc {
            OffsetEncoding::Utf8 => ch.len_utf8() as u32,
            OffsetEncoding::Utf16 => ch.len_utf16() as u32,
            OffsetEncoding::Utf32 => 1,
        };
    }
    units[text.len()] = u;
    let mut carets: Vec<usize> = (0..=text.len()).step_by(stride.max(1)).collect();
    // Every boundary and its neighbours too.
    for (i, &(s, e)) in oracle.iter().enumerate() {
        if i % every.max(1) == 0 || e - s > 1000 {
            carets.extend([s, s + 1, e.saturating_sub(1), e]);
        }
    }
    carets.sort_unstable();
    carets.dedup();
    for byte in carets {
        let mut byte = byte.min(text.len());
        while !text.is_char_boundary(byte) {
            byte -= 1;
        }
        // A caret on a cut belongs to the sentence that starts there; at a paragraph's end, to
        // its last sentence. Carets on the blank line between paragraphs light up nothing.
        let i = oracle.partition_point(|&(s, _)| s <= byte);
        let found = match i.checked_sub(1).map(|i| oracle[i]) {
            Some((s, e)) if byte < e => Some((s, e)),
            Some((s, e)) if byte == e && (e == text.len() || text[e..].starts_with('\n')) => Some((s, e)),
            _ => None,
        };
        let Some((s, e)) = found else {
            continue;
        };
        let c = units[byte];
        let got = doc.focus_range(TextRange::new(c, c), FocusScope::Sentence);
        let want = vec![TextRange::new(units[s], units[e])];
        if got != want {
            return Err(format!(
                "{enc:?} caret at byte {byte}: got {:?}, the whole text's sentence is {:?}",
                got.iter().map(|&r| slice_units(text, enc, r)).collect::<Vec<_>>(),
                &text[s..e]
            ));
        }
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(200)
    ))]

    #[test]
    fn plain_prose_sentences_are_uax29s(paras in prop::collection::vec(prop::collection::vec(prop::collection::vec(0usize..64, 0..14), 1..4), 1..4)) {
        let text = paras
            .iter()
            .map(|lines| lines.iter().map(|l| prose_line(l)).collect::<Vec<_>>().join("\n"))
            .collect::<Vec<_>>()
            .join("\n\n");
        for enc in ENCODINGS {
            if let Err(e) = check_against_oracle(&text, enc, 1, 1) {
                return Err(TestCaseError::fail(format!("{text:?}: {e}")));
            }
        }
    }
}

/// A paragraph of `bytes` or more, from a simple deterministic generator.
fn giant_paragraph(bytes: usize, seed: u64, line_words: usize) -> String {
    let mut x = seed;
    let mut next = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x as usize
    };
    let mut lines = Vec::new();
    let mut len = 0;
    while len < bytes {
        let words: Vec<usize> = (0..1 + next() % line_words).map(|_| next()).collect();
        let l = prose_line(&words);
        len += l.len() + 1;
        lines.push(l);
    }
    lines.join("\n")
}

#[test]
fn giant_paragraphs_give_the_whole_blocks_sentences() {
    // Many lines, one enormous line, and a 30 KB sentence with no terminator in the middle:
    // the window around the caret must never show.
    let unterminated = format!("A{}", " word and".repeat(30_000 / 9));
    let cases = [
        giant_paragraph(200_000, 7, 14),
        giant_paragraph(120_000, 11, 4000).replace('\n', " "),
        format!("{}\n{unterminated}\n{}", giant_paragraph(60_000, 3, 10), giant_paragraph(60_000, 5, 10)),
    ];
    for text in &cases {
        assert!(text.len() > 100_000);
        for enc in ENCODINGS {
            check_against_oracle(text, enc, 2003, 97).unwrap_or_else(|e| panic!("{e}"));
        }
    }
}

#[test]
fn giant_paragraph_selections_match_carets() {
    // A selection inside a giant paragraph is windowed too, and lights up the same sentences.
    let text = giant_paragraph(150_000, 13, 12);
    let doc = Document::new(&text, OffsetEncoding::Utf16);
    let oracle = oracle_sentences(&text);
    for &start in &[1_000usize, 70_001, 149_000] {
        let mut a = start.min(text.len() - 600);
        while !text.is_char_boundary(a) {
            a -= 1;
        }
        let mut b = a + 500;
        while !text.is_char_boundary(b) {
            b += 1;
        }
        let got = doc.focus_range(TextRange::new(unit_of(&text, a, OffsetEncoding::Utf16), unit_of(&text, b, OffsetEncoding::Utf16)), FocusScope::Sentence);
        let lo = oracle.iter().find(|&&(s, e)| s <= a && a < e).unwrap().0;
        let hi = oracle.iter().find(|&&(s, e)| s < b && b <= e).unwrap().1;
        assert_eq!(got, vec![TextRange::new(unit_of(&text, lo, OffsetEncoding::Utf16), unit_of(&text, hi, OffsetEncoding::Utf16))]);
    }
}

#[test]
fn a_sentence_too_long_to_find_changes_only_in_steps() {
    // 150 KB without a terminator: the lit range ends at window edges, which lie on a grid, so
    // it changes every few kilobytes of caret travel, not on every move, and holds the caret.
    let text = format!("A{}", " word and".repeat(150_000 / 9));
    let doc = Document::new(&text, OffsetEncoding::Utf8);
    let mut distinct = Vec::new();
    for c in (0..text.len() as u32).step_by(997) {
        let r = doc.focus_range(TextRange::new(c, c), FocusScope::Sentence);
        assert_eq!(r.len(), 1);
        assert!(r[0].start <= c && c <= r[0].end);
        if distinct.last() != Some(&r[0]) {
            distinct.push(r[0]);
        }
    }
    assert!(distinct.len() <= text.len() / 4096 + 2, "{} distinct ranges", distinct.len());
}

// ---------- constructs a writer meets ----------

#[test]
fn sentences_across_inline_elements() {
    s("**First one. Sec¦ond one.** Third.", &["Second one.** "]);
    s("**Fi¦rst one. Second one.** Third.", &["**First one. "]);
    s("See [the first. The se¦cond](http://x) here. Done.", &["The second](http://x) here. "]);
    s("See [the fi¦rst. The second](http://x) here. Done.", &["See [the first. "]);
    s("One ~~two. Th¦ree~~ four. Five.", &["Three~~ four. "]);
    s("**a. ¦b** c.", &["**a. b** c."]);
    s("Go to http://x.com/a.b?c=d. A¦nd now.", &["And now."]);
    s("Call `a.b()` no¦w. Next.", &["Call `a.b()` now. "]);
}

#[test]
fn ellipses_quotes_and_brackets_after_terminators() {
    s("Wait... wh¦at? Yes.", &["Wait... what? "]);
    s("He said \"Sto¦p.\" Then left.", &["He said \"Stop.\" "]);
    s("He said \"Stop.\" Th¦en left.", &["Then left."]);
    s("(Paren¦.) After.", &["(Paren.) "]);
    s("Done.) Ne¦xt.", &["Next."]);
}

#[test]
fn mixed_scripts_and_emoji() {
    s("English. \u{65E5}\u{672C}\u{8A9E}\u{3067}\u{3059}\u{3002}Mi¦xed text.", &["Mixed text."]);
    s("Emoji \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}. \u{1F389} Par¦ty! \u{1F1E9}\u{1F1EA} Flag.", &["\u{1F389} Party! "]);
    s("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}. \u{041C}\u{0438}¦\u{0440}.", &["\u{041C}\u{0438}\u{0440}."]);
}

#[test]
fn headings_with_closing_hashes_and_items_with_children() {
    s("## Heading one. Tw¦o ##", &["Two ##"]);
    s("- Item one. Item two.\n\n  Child pa¦ra. Second.\n- next", &["  Child para. "]);
    s("- Item one. Item two.\n\n  Child para. Sec¦ond.\n- next", &["Second."]);
    p("- Item one.\n\n  Child ¦para.\n- next", &["  Child para."]);
    s("1. one\n   two. Thr¦ee", &["Three"]);
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(120)
    ))]

    #[test]
    fn selection_state_equals_the_individual_queries(text in md_text(30), a in 0usize..400, b in 0usize..400, w0 in 0usize..400, w1 in 0usize..400) {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            let ok = boundaries(&text, enc);
            let pick = |i: usize| ok[i % ok.len()];
            let sel = TextRange::new(pick(a), pick(b));
            let window = TextRange::new(pick(w0).min(pick(w1)), pick(w0).max(pick(w1)));
            for within in [None, Some(window)] {
                for scope in [None, Some(FocusScope::Sentence), Some(FocusScope::Paragraph)] {
                    let st = doc.selection_state(sel, within, true, scope);
                    let lo = sel.start.min(sel.end);
                    prop_assert_eq!(&st.format_state, &doc.format_state(sel));
                    prop_assert_eq!(&st.table, &doc.table_at(lo));
                    prop_assert_eq!(&st.concealment, &Some(doc.concealment(sel, within)));
                    let whole = scope.map(|sc| doc.focus_range(sel, sc));
                    let (lo, hi) = (sel.start.min(sel.end), sel.start.max(sel.end));
                    // (A selection end between a CR and its LF is the position before the CR, for the
                    // window as well as for the units; either end.)
                    let split = |p: u32| p > 0 && slice_units(&text, enc, TextRange::new(p - 1, p)) == "\r" && slice_units(&text, enc, TextRange::new(p, p + 1)) == "\n";
                    let seen = |p: u32| if split(p) { p - 1 } else { p };
                    let (lo_seen, hi_seen) = (seen(lo), seen(hi));
                    if within.is_none() || lo_seen == hi_seen {
                        // A caret's unit is computed whatever the window. A selection of only the CR
                        // of a CRLF is a caret before the CR.
                        prop_assert_eq!(&st.focus, &whole);
                    } else if let (Some(got), Some(whole)) = (&st.focus, &whole) {
                        // A windowed selection: never more than the whole answer, and inside the
                        // window exactly it when the selection meets the window (otherwise only
                        // the selection itself is lit).
                        let lit = |rs: &[TextRange], u: u32| rs.iter().any(|r| r.start <= u && u < r.end);
                        let meets = lo_seen.max(window.start) < hi_seen.min(window.end);
                        for u in 0..doc.len() {
                            prop_assert!(!lit(got, u) || lit(whole, u), "{} lit beyond the whole answer", u);
                            if !meets {
                                // (A selection end between a CR and its LF counts from the CR.)
                                prop_assert!(!lit(got, u) || (lo.saturating_sub(1) <= u && u < hi), "{} with the selection outside the window", u);
                            } else if window.start <= u && u < window.end {
                                prop_assert_eq!(lit(got, u), lit(whole, u), "{} inside the window", u);
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn map_tags_gives_back_every_word_in_every_encoding(text in md_text(30)) {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            for u in doc.pos_units(None) {
                // The joined text, built from the pieces as the shell does.
                let mut joined: Vec<char> = Vec::new();
                for (i, pc) in u.prose.iter().enumerate() {
                    if u.separated[i] && i > 0 {
                        joined.push(' ');
                    }
                    joined.extend(slice_units(&text, enc, *pc).chars());
                }
                let width = |c: char| match enc {
                    OffsetEncoding::Utf8 => c.len_utf8() as u32,
                    OffsetEncoding::Utf16 => c.len_utf16() as u32,
                    OffsetEncoding::Utf32 => 1,
                };
                prop_assert_eq!(u.joined_len(), joined.iter().map(|&c| width(c)).sum::<u32>());
                // Every whitespace-separated word, as a tag in joined units.
                let mut words: Vec<(PosTag, String)> = Vec::new();
                let mut at = 0u32;
                let mut cur: Option<(u32, String)> = None;
                for &c in &joined {
                    if c.is_whitespace() {
                        if let Some((s, w)) = cur.take() {
                            words.push((PosTag { range: TextRange::new(s, at), class: PosClass::Noun }, w));
                        }
                    } else {
                        cur.get_or_insert((at, String::new())).1.push(c);
                    }
                    at += width(c);
                }
                if let Some((s, w)) = cur.take() {
                    words.push((PosTag { range: TextRange::new(s, at), class: PosClass::Noun }, w));
                }
                let tags: Vec<PosTag> = words.iter().map(|w| w.0).collect();
                let mapped = u.map_tags(&tags);
                // Mapped one word at a time, the pieces spell the word, inside the unit's prose.
                let mut all = Vec::new();
                for (tag, word) in &words {
                    let pieces = u.map_tags(std::slice::from_ref(tag));
                    let spelled: String = pieces.iter().map(|t| slice_units(&text, enc, t.range)).collect();
                    prop_assert_eq!(&spelled, word, "{:?} {:?}", enc, text);
                    for t in &pieces {
                        prop_assert!(u.prose.iter().any(|pc| pc.start <= t.range.start && t.range.end <= pc.end));
                    }
                    all.extend(pieces);
                }
                prop_assert_eq!(mapped, all);
            }
        }
    }
}

// ---------- long blocks come as several units ----------

/// The joined text of a unit, as the shell builds it.
fn joined_text(text: &str, enc: OffsetEncoding, u: &PosUnit) -> String {
    let mut out = String::new();
    for (i, pc) in u.prose.iter().enumerate() {
        if u.separated[i] && i > 0 {
            out.push(' ');
        }
        out.push_str(&slice_units(text, enc, *pc));
    }
    out
}

/// The units' pieces tile the prose ranges exactly (a long block's pieces may be cut where a
/// unit ends), units are ordered and disjoint, and each starts unseparated.
fn check_unit_tiling(doc: &Document, units: &[PosUnit]) -> Result<(), String> {
    let prose = doc.prose_ranges(None);
    let pieces: Vec<TextRange> = units.iter().flat_map(|u| u.prose.iter().copied()).collect();
    let mut k = 0;
    for p in &prose {
        let mut at = p.start;
        while at < p.end {
            let Some(q) = pieces.get(k) else { return Err(format!("prose {p:?} is not covered")) };
            if q.start != at || q.end > p.end || q.end <= q.start {
                return Err(format!("piece {q:?} does not tile prose {p:?} at {at}"));
            }
            at = q.end;
            k += 1;
        }
    }
    if k != pieces.len() {
        return Err(format!("{} pieces beyond the prose", pieces.len() - k));
    }
    let mut prev_end = 0;
    for u in units {
        if u.prose.is_empty() || u.separated.len() != u.prose.len() || u.separated[0] {
            return Err(format!("bad unit {u:?}"));
        }
        if u.range.start < prev_end || u.prose[0].start < u.range.start || u.prose.last().unwrap().end > u.range.end {
            return Err(format!("unit {:?} out of order or not around its prose", u.range));
        }
        prev_end = u.range.end;
    }
    Ok(())
}

/// Chinese-like text without spaces: sentences end in U+3002, U+FF01 or U+FF1F and nothing
/// else separates them.
fn cjk_paragraph(bytes: usize) -> String {
    let mut x: u64 = 0x2545_F491;
    let mut next = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x as usize
    };
    let mut out = String::new();
    while out.len() < bytes {
        for _ in 0..4 + next() % 20 {
            out.push(char::from_u32(0x4E00 + (next() % 2000) as u32).unwrap());
        }
        out.push(['\u{3002}', '\u{FF01}', '\u{FF1F}'][next() % 3]);
    }
    out
}

/// Words and no sentence terminator at all, on one line.
fn unterminated_paragraph(bytes: usize) -> String {
    let mut x: u64 = 0x9E37_79B9;
    let mut out = String::from("A");
    while out.len() < bytes {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push(' ');
        for i in 0..2 + x % 8 {
            out.push((b'a' + ((x >> (i * 5)) % 26) as u8) as char);
        }
    }
    out
}

fn long_documents() -> Vec<String> {
    vec![
        giant_paragraph(100_000, 17, 12),
        giant_paragraph(60_000, 19, 3000).replace('\n', " "),
        format!("# Title\n\n{}\n\n- item\n\n{}", giant_paragraph(40_000, 23, 8).replace(" word", " **word**").replace(" The", " [The](http://x.y/z)"), giant_paragraph(30_000, 29, 9)),
        cjk_paragraph(60_000),
        unterminated_paragraph(50_000),
    ]
}

#[test]
fn long_blocks_are_tagged_in_units_of_a_few_kilobytes() {
    for text in long_documents() {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            let units = doc.pos_units(None);
            check_unit_tiling(&doc, &units).unwrap_or_else(|e| panic!("{enc:?} {:?}: {e}", text.chars().take(20).collect::<String>()));
            let biggest = units.iter().map(|u| u.prose.iter().map(|p| p.end - p.start).sum::<u32>()).max().unwrap();
            assert!(units.len() > 3, "{enc:?} {:?}: {} units", text.chars().take(20).collect::<String>(), units.len());
            assert!(biggest < 40_000, "{enc:?} {:?}: a unit of {biggest}", text.chars().take(20).collect::<String>());
            // No word is cut between units: a unit starts at a word.
            for w in units.windows(2) {
                let first = slice_units(&text, enc, w[1].prose[0]);
                assert!(!first.starts_with(char::is_whitespace), "{first:?}");
            }
        }
    }
}

#[test]
fn an_edit_in_a_long_block_changes_only_the_units_around_it() {
    for text in long_documents() {
        let doc = Document::new(&text, OffsetEncoding::Utf8);
        let before: Vec<String> = doc.pos_units(None).iter().map(|u| joined_text(&text, OffsetEncoding::Utf8, u)).collect();
        for at in [text.len() / 7, text.len() - 300] {
            let mut at = at;
            while !text.is_char_boundary(at) {
                at += 1;
            }
            for insert in ["x", ". Then "] {
                let mut edited = text.clone();
                edited.insert_str(at, insert);
                let d = Document::new(&edited, OffsetEncoding::Utf8);
                let after: Vec<String> = d.pos_units(None).iter().map(|u| joined_text(&edited, OffsetEncoding::Utf8, u)).collect();
                let changed = after.iter().filter(|t| !before.contains(t)).count();
                assert!(changed <= 3, "{insert:?} at {at}: {changed} of {} units changed", after.len());
            }
        }
    }
}

#[test]
fn windowed_long_blocks_give_the_units_that_meet_the_window() {
    for text in long_documents() {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            let all = doc.pos_units(None);
            let len = doc.len();
            for (a, b) in [(len / 3, len / 3 + 2000), (len / 2, len / 2), (0, 100), (len - 50, len)] {
                let some = doc.pos_units(Some(TextRange::new(a, b)));
                assert!(!some.is_empty());
                for u in &some {
                    assert!(all.contains(u), "{enc:?}: {u:?} is not one of the units");
                }
                for u in &all {
                    let hit = u.prose.iter().any(|pc| if a == b { pc.start <= a && a < pc.end } else { pc.start < b && pc.end > a });
                    assert!(!hit || some.contains(u), "{enc:?} ({a}, {b}): missing {:?}", u.range);
                }
                // Far fewer than all of them.
                assert!(some.len() * 3 < all.len().max(3) || all.len() < 6, "{} of {}", some.len(), all.len());
            }
        }
    }
}

#[test]
fn map_tags_in_long_block_units() {
    for text in long_documents() {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            for u in doc.pos_units(None).iter().step_by(3) {
                let joined = joined_text(&text, enc, u);
                let width = |s: &str| match enc {
                    OffsetEncoding::Utf8 => s.len() as u32,
                    OffsetEncoding::Utf16 => s.encode_utf16().count() as u32,
                    OffsetEncoding::Utf32 => s.chars().count() as u32,
                };
                assert_eq!(u.joined_len(), width(&joined));
                // The last word of the unit comes back as itself.
                let word = joined.split_whitespace().last().unwrap();
                let start = width(&joined[..joined.rfind(word).unwrap()]);
                let tags = u.map_tags(&[PosTag { range: TextRange::new(start, start + width(word)), class: PosClass::Verb }]);
                let spelled: String = tags.iter().map(|t| slice_units(&text, enc, t.range)).collect();
                assert_eq!(spelled, word);
            }
        }
    }
}
