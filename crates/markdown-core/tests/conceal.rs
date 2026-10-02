//! Live mode concealment: hand-written expectations per construct, then properties.
//!
//! Selections are written into the text: `¦` is a caret, `⟪…⟫` a selection. Both markers are
//! removed before the text reaches the core.
mod common;
use common::*;
use markdown_core::*;
use proptest::prelude::*;

fn parse(marked: &str) -> (String, TextRange) {
    let mut text = String::new();
    let (mut a, mut b) = (None, None);
    for ch in marked.chars() {
        match ch {
            '¦' => {
                a = Some(text.len() as u32);
                b = a;
            }
            '⟪' => a = Some(text.len() as u32),
            '⟫' => b = Some(text.len() as u32),
            c => text.push(c),
        }
    }
    let a = a.unwrap_or(text.len() as u32);
    (text, TextRange::new(a, b.unwrap_or(a)))
}

fn conceal(marked: &str) -> (String, Concealment) {
    let (text, sel) = parse(marked);
    let doc = Document::new(&text, OffsetEncoding::Utf8);
    (text.clone(), doc.concealment(sel, None))
}

fn src(text: &str, r: TextRange) -> String {
    text[r.start as usize..r.end as usize].to_owned()
}

/// The hidden source pieces, in order.
#[track_caller]
fn hidden(marked: &str) -> Vec<String> {
    let (t, c) = conceal(marked);
    c.hidden.iter().map(|&r| src(&t, r)).collect()
}

fn collapsed(marked: &str) -> Vec<String> {
    let (t, c) = conceal(marked);
    c.collapsed.iter().map(|&r| src(&t, r)).collect()
}

fn decos(marked: &str) -> Vec<(String, DecorationKind)> {
    let (t, c) = conceal(marked);
    c.decorations.iter().map(|d| (src(&t, d.range), d.kind)).collect()
}

fn v(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

// ---------- inline elements: caret outside, at each edge, inside ----------

#[test]
fn strong_is_revealed_by_a_caret_touching_it() {
    assert_eq!(hidden("¦a **b** c"), v(&["**", "**"]));
    assert_eq!(hidden("a ¦**b** c"), v::<>(&[]), "caret immediately before");
    assert_eq!(hidden("a **¦b** c"), v::<>(&[]), "caret inside, after the opening markup");
    assert_eq!(hidden("a **b¦** c"), v::<>(&[]));
    assert_eq!(hidden("a **b**¦ c"), v::<>(&[]), "caret immediately after");
    assert_eq!(hidden("a **b** ¦c"), v(&["**", "**"]));
    assert_eq!(hidden("a **b** c¦"), v(&["**", "**"]));
}

#[test]
fn emphasis_code_strike() {
    assert_eq!(hidden("¦x *a* _b_ `c` ~~d~~ ~e~"), v(&["*", "*", "_", "_", "`", "`", "~~", "~~", "~", "~"]));
    assert_eq!(hidden("*a* _b_ `c`¦ ~~d~~"), v(&["*", "*", "_", "_", "~~", "~~"]));
    assert_eq!(hidden("*a* _b_ `c` ~~¦d~~"), v(&["*", "*", "_", "_", "`", "`"]));
    // Longer backtick fences are all hidden.
    assert_eq!(hidden("¦x ``a`b`` y"), v(&["``", "``"]));
}

#[test]
fn adjacent_ranges_merge() {
    // `*` `*` of two touching elements become one hidden range.
    let (t, c) = conceal("¦x ***a***");
    // `***a***` is emphasis inside strong or the reverse; either way the markup is one run each side.
    assert_eq!(c.hidden.iter().map(|&r| src(&t, r)).collect::<Vec<_>>(), v(&["***", "***"]));
}

#[test]
fn links_hide_brackets_and_destination() {
    assert_eq!(hidden("¦see [text](http://x.y \"t\") ok"), v(&["[", "](http://x.y \"t\")"]));
    assert_eq!(hidden("see [te¦xt](http://x.y) ok"), v::<>(&[]));
    assert_eq!(hidden("see [text](http://x.y)¦ ok"), v::<>(&[]));
    assert_eq!(hidden("see ¦[text](http://x.y) ok"), v::<>(&[]));
    // A caret inside the destination reveals too.
    assert_eq!(hidden("see [text](http://¦x.y) ok"), v::<>(&[]));
}

#[test]
fn reference_link_pieces() {
    let (t, c) = conceal("¦x [a][b] and [c][]\n\n[b]: /u\n[c]: /v\n");
    let got: Vec<String> = c.hidden.iter().map(|&r| src(&t, r)).collect();
    // `[`, `][`+label+`]`, `[`, `][]`: the labelled form hides brackets and label.
    assert_eq!(got, v(&["[", "][b]", "[", "][]"]));
}

#[test]
fn nested_emphasis_in_link() {
    // A caret inside the emphasis is inside the link as well: both reveal.
    assert_eq!(hidden("[a *b¦* c](u)"), v::<>(&[]));
    // A caret in the link text but outside the emphasis reveals the link, not the emphasis.
    assert_eq!(hidden("[¦a *b* c](u)"), v(&["*", "*"]));
    assert_eq!(hidden("¦x [a *b* c](u)"), v(&["[", "*", "*", "](u)"]));
}

#[test]
fn images_inline_and_standalone() {
    // Inline image: markup hides, alt text stays.
    assert_eq!(hidden("¦a ![alt](p.png) b"), v(&["![", "](p.png)"]));
    assert!(decos("¦a ![alt](p.png) b").iter().all(|d| !matches!(d.1, DecorationKind::Image { .. })));
    // Standalone: the whole source is hidden and an Image decoration stands in.
    assert_eq!(hidden("a\n\n![alt](p.png)\n\n¦b"), v(&["![alt](p.png)"]));
    assert_eq!(decos("a\n\n![alt](p.png)\n\n¦b"), vec![("![alt](p.png)".to_string(), DecorationKind::Image { index: 0 })]);
    // The selection touching the paragraph shows the source.
    assert_eq!(hidden("a\n\n¦![alt](p.png)\n\nb"), v::<>(&[]));
    assert_eq!(hidden("a\n\n![al¦t](p.png)\n\nb"), v::<>(&[]));
    assert_eq!(hidden("a\n\n![alt](p.png)¦\n\nb"), v::<>(&[]));
    assert!(decos("a\n\n![alt](p.png)¦\n\nb").is_empty());
    // Two images in separate paragraphs get their own index.
    let d = decos("¦x\n\n![a](1.png)\n\n![b](2.png)\n");
    assert_eq!(d.len(), 2);
    assert_eq!(d[1].1, DecorationKind::Image { index: 1 });
}

#[test]
fn autolinks_hide_only_the_angle_brackets() {
    assert_eq!(hidden("¦a <http://x.y> b"), v(&["<", ">"]));
    assert_eq!(hidden("a <http://x.y>¦ b"), v::<>(&[]));
    // Bare URLs have no markup.
    assert_eq!(hidden("¦a http://x.y b"), v::<>(&[]));
}

#[test]
fn escapes_hide_the_backslash() {
    assert_eq!(hidden("¦a \\*b\\* c"), v(&["\\", "\\"]));
    assert_eq!(hidden("a \\¦*b"), v::<>(&[]));
    assert_eq!(hidden("a ¦\\*b"), v::<>(&[]));
    assert_eq!(hidden("a \\*¦b"), v::<>(&[]), "caret after the escaped character touches the escape");
    assert_eq!(hidden("¦a \\\\ b"), v(&["\\"]), "an escaped backslash is one escape");
}

#[test]
fn hard_break_backslash_hides() {
    assert_eq!(hidden("¦a\\\nb"), v(&["\\"]));
    assert_eq!(hidden("a\\¦\nb"), v::<>(&[]));
    assert_eq!(hidden("a\\\n¦b"), v(&["\\"]));
    // Trailing spaces need nothing.
    assert_eq!(hidden("¦a  \nb"), v::<>(&[]));
}

// ---------- block markup ----------

#[test]
fn atx_heading_prefix_belongs_to_the_line() {
    assert_eq!(hidden("# Title\n\n¦text"), v(&["# "]));
    assert_eq!(hidden("# Ti¦tle\n\ntext"), v::<>(&[]));
    assert_eq!(hidden("¦# Title\n\ntext"), v::<>(&[]));
    assert_eq!(hidden("# Title¦\n\ntext"), v::<>(&[]), "end of the heading line");
    assert_eq!(hidden("# Title\n¦\ntext"), v(&["# "]), "the blank line after is another line");
    assert_eq!(hidden("¦## Title ##\n"), v::<>(&[]));
    assert_eq!(hidden("## Title ##\n\n¦x"), v(&["## ", "##"]));
    // Inline markup inside a heading is separate from the prefix.
    assert_eq!(hidden("# a **b**\n\n¦x"), v(&["# ", "**", "**"]));
    assert!(hidden("# a **b**¦").is_empty());
    assert_eq!(hidden("# a ¦**b**\n\nx"), v::<>(&[]));
    assert_eq!(hidden("# ¦a **b**\n\nx"), v(&["**", "**"]));
}

#[test]
fn setext_heading_underline_collapses() {
    assert_eq!(hidden("Title\n=====\n\n¦x"), v(&["====="]));
    assert_eq!(collapsed("Title\n=====\n\n¦x"), v(&["=====\n"]));
    assert_eq!(hidden("Ti¦tle\n=====\n\nx"), v::<>(&[]));
    assert_eq!(hidden("Title\n¦=====\n\nx"), v::<>(&[]));
    assert!(collapsed("Title\n¦=====\n\nx").is_empty());
    assert_eq!(collapsed("Sub\n---\n¦x"), v(&["---\n"]));
    // The caret after the underline's trailing blanks is still on its line.
    assert_eq!(hidden("Title\n===  ¦\n\nx"), v::<>(&[]));
    // A list item whose empty sub-item marker becomes a setext underline while it is typed.
    assert_eq!(hidden("- A short item.\n  - ¦\n- b\n"), v::<>(&[]));
    assert_eq!(hidden("- A short item.\n  - \n- ¦b\n"), v(&["-"]));
}

#[test]
fn block_quotes() {
    assert_eq!(hidden("> a\n> b\n\n¦x"), v(&["> ", "> "]));
    assert_eq!(hidden("> a\n> ¦b\n\nx"), v(&["> "]));
    assert_eq!(hidden("> a¦\n> b\n\nx"), v(&["> "]), "only the caret's line reveals its marker");
    assert_eq!(hidden("> a\n> b¦"), v(&["> "]));
    // Lazy continuation: no marker on that line.
    assert_eq!(hidden("> a\nlazy\n\n¦x"), v(&["> "]));
    // Nested quotes: `> > ` on one line, hidden as one run.
    assert_eq!(hidden("> > a\n\n¦x"), v(&["> > "]));
    let d = decos("> > a\n\n¦x");
    assert_eq!(d, vec![("> > a".to_string(), DecorationKind::QuoteBar { depth: 0 }), ("> a".to_string(), DecorationKind::QuoteBar { depth: 1 })]);
    // A quote inside a list item.
    assert_eq!(hidden("- > a\n\n¦x"), v(&["> "]));
    let d = decos("- > a\n\n¦x");
    assert!(d.contains(&("> a".to_string(), DecorationKind::QuoteBar { depth: 0 })));
}

#[test]
fn lists_and_tasks() {
    let d = decos("¦x\n\n- a\n* b\n+ c\n1. d\n");
    assert_eq!(d.iter().filter(|d| d.1 == DecorationKind::Bullet).count(), 3);
    assert!(hidden("¦x\n\n- a\n1. d\n").is_empty(), "markers are drawn over, not hidden");
    // Tasks: a checkbox and the dash hidden.
    let d = decos("¦- [ ] a\n- [x] b\n");
    assert_eq!(
        d,
        vec![
            ("[ ]".to_string(), DecorationKind::Checkbox { checked: false }),
            ("[x]".to_string(), DecorationKind::Checkbox { checked: true }),
        ]
    );
    assert_eq!(hidden("¦- [ ] a\n- [x] b\n"), v(&["- [ ] ", "- [x] "]));
    assert_eq!(hidden("¦x\n\n  - [ ] nested\n"), v(&["- [ ] "]));
    // Adjacent hidden pieces are one range: the quote marker and the task prefix.
    assert_eq!(hidden("> - [ ] in a quote\n\n¦x"), v(&["> - [ ] "]));
    // A task marker is shown wherever the caret is.
    assert_eq!(decos("- [ ¦] a").len(), 1);
    // Nested bullets.
    assert_eq!(decos("¦- a\n  - b\n").iter().filter(|d| d.1 == DecorationKind::Bullet).count(), 2);
    // The prefix stays hidden with the caret on the item's line, at either end of it.
    assert_eq!(hidden("- [ ] a¦"), v(&["- [ ] "]));
    assert_eq!(hidden("¦- [ ] a"), v(&["- [ ] "]));
    assert_eq!(hidden("- [ ¦] a"), v(&["- [ ] "]));
    // An empty task item: the whole line is prefix.
    assert_eq!(hidden("¦z\n\n* [ ]\n"), v(&["* [ ]"]));
}

#[test]
fn ordered_task_items_keep_their_number_and_marker() {
    // Regression: a checkbox was emitted for `1. [x]` while `[x]` stayed visible (drawn twice,
    // or not at all, by the shell). The number stays, so does the marker; no checkbox.
    assert!(hidden("¦z\n\n1. [x] b\n2) [ ] c\n").is_empty());
    assert!(decos("¦z\n\n1. [x] b\n2) [ ] c\n").is_empty());
    // Unordered siblings are unaffected.
    assert_eq!(decos("¦z\n\n1. [x] b\n\n- [ ] c\n"), vec![("[ ]".to_string(), DecorationKind::Checkbox { checked: false })]);
}

#[test]
fn thematic_break() {
    assert_eq!(hidden("a\n\n***\n\n¦b"), v(&["***"]));
    assert_eq!(decos("a\n\n***\n\n¦b"), vec![("***".to_string(), DecorationKind::Rule)]);
    assert_eq!(hidden("a\n\n**¦*\n\nb"), v::<>(&[]));
    assert!(decos("a\n\n***¦\n\nb").is_empty());
    assert_eq!(hidden("¦_ _ _\n\n"), v::<>(&[]));
    assert_eq!(hidden("x\n\n_ _ _\n\n¦"), v(&["_ _ _"]));
}

#[test]
fn fenced_code_blocks() {
    let t = "a\n\n```rust\nlet x = 1;\n```\n\n¦b";
    assert_eq!(hidden(t), v(&["```rust", "```"]));
    assert_eq!(collapsed(t), v(&["```rust\n", "```\n"]));
    // Anywhere in the block reveals both fences, content line or fence line.
    for t in ["a\n\n```rust\nlet ¦x = 1;\n```\n", "a\n\n¦```rust\nlet x = 1;\n```\n", "a\n\n```rust\nlet x = 1;\n```¦\n", "a\n\n```ru¦st\nx\n```\n"] {
        assert!(hidden(t).is_empty(), "{t:?}");
        assert!(collapsed(t).is_empty(), "{t:?}");
    }
    // Just outside the block is outside.
    assert_eq!(hidden("```\nx\n```\n¦b"), v(&["```", "```"]));
    assert_eq!(hidden("¦a\n```\nx\n```"), v(&["```", "```"]));
    // Tilde fence, longer fence, indentation.
    assert_eq!(hidden("¦a\n\n~~~~ py \nx\n~~~~\n"), v(&["~~~~ py ", "~~~~"]));
    assert_eq!(hidden("¦a\n\n  ```\nx\n  ```\n"), v(&["```", "```"]));
    assert_eq!(collapsed("¦a\n\n  ```\nx\n  ```\n"), v(&["  ```\n", "  ```\n"]));
}

#[test]
fn unclosed_fence() {
    assert_eq!(hidden("¦a\n\n```rust\ncode\n"), v(&["```rust"]));
    assert_eq!(collapsed("¦a\n\n```rust\ncode\n"), v(&["```rust\n"]));
    assert!(hidden("a\n\n```rust\nco¦de\n").is_empty());
}

#[test]
fn fence_in_a_quote_keeps_the_quote_prefix_visible_or_hidden_by_the_line_rule() {
    // The caret outside: both the quote marker and the fence are hidden, so the line collapses.
    let t = "> ```\n> x\n> ```\n\n¦b";
    let (text, c) = conceal(t);
    let got: Vec<_> = c.hidden.iter().map(|&r| src(&text, r)).collect();
    assert_eq!(got, v(&["> ```", "> ", "> ```"]));
    assert_eq!(c.collapsed.iter().map(|&r| src(&text, r)).collect::<Vec<_>>(), v(&["> ```\n", "> ```\n"]));
}

#[test]
fn front_matter() {
    let t = "---\ntitle: x\n---\n\n¦# Head";
    assert_eq!(hidden(t), v(&["---", "---"]));
    assert_eq!(collapsed(t), v(&["---\n", "---\n"]));
    assert_eq!(hidden("---\ntit¦le: x\n---\n\n# Head"), v(&["# "]));
    assert_eq!(hidden("---¦\ntitle: x\n---\n\n# Head"), v(&["# "]));
    assert_eq!(hidden("---\ntitle: x\n---¦\n\n# Head"), v(&["# "]));
}

#[test]
fn tables_are_never_concealed() {
    let t = "¦x\n\n| **a** | [b](u) |\n|---|---|\n| `c` | \\* |\n";
    assert!(hidden(t).is_empty(), "{:?}", hidden(t));
    assert!(decos(t).is_empty());
}

#[test]
fn definitions_and_footnotes_stay_visible() {
    assert!(hidden("¦a\n\n[r]: http://x.y \"t\"\n").is_empty());
    assert!(hidden("¦a[^1]\n\n[^1]: note **b**\n").iter().all(|s| s == "**"), "{:?}", hidden("¦a[^1]\n\n[^1]: note **b**\n"));
    assert_eq!(hidden("¦a[^1]\n\n[^1]: note **b**\n"), v(&["**", "**"]));
    // Raw HTML and indented code have no concealable markup.
    assert!(hidden("¦a\n\n<div>*x*</div>\n\n    code `x`\n").is_empty());
}

#[test]
fn selections_reveal_every_owner_they_overlap() {
    let t = "x **a** y *b* z `c` w";
    assert_eq!(hidden(&t.replace("**a** y *b*", "⟪**a** y *b*⟫")), v(&["`", "`"]));
    // Each end of a selection touches like a caret: one that stops right before an element (or
    // starts right after it) reveals it, as a caret there would.
    assert!(hidden("⟪x ⟫**a** y").is_empty());
    assert!(hidden("x **a**⟪ y⟫").is_empty());
    assert_eq!(hidden("⟪x⟫ **a** y"), v(&["**", "**"]));
    assert_eq!(hidden("x **a** ⟪y⟫"), v(&["**", "**"]));
    assert_eq!(hidden("x⟪ y⟫ **a**"), v(&["**", "**"]));
    // A whole-line selection (with its terminator) does not reveal the next line's marker.
    assert_eq!(hidden("⟪text\n⟫# Next\n"), v(&["# "]));
    assert!(hidden("⟪text\n# Next\n⟫").is_empty());
    assert_eq!(hidden("⟪text\r\n⟫# Next\n"), v(&["# "]));
    assert_eq!(hidden("⟪text\r⟫# Next\n"), v(&["# "]));
    // Without the terminator the end is on the first line; the next line is not touched.
    assert_eq!(hidden("⟪text⟫\n# Next\n"), v(&["# "]));
    // Symmetrically, a selection starting at a line terminator does not reveal that line.
    assert_eq!(hidden("# Head⟪\nnext⟫\n"), v(&["# "]));
    assert_eq!(hidden("# Head⟪\r\nnext⟫\n"), v(&["# "]));
    assert!(hidden("# Hea⟪d\nnext⟫\n").is_empty());
    // A fence or quote line is not revealed by a selection that only reaches it with a break.
    assert_eq!(hidden("⟪a\n⟫> q\n"), v(&["> "]));
    assert_eq!(hidden("> q⟪\na⟫\n"), v(&["> "]));
    // Inverted selections are normalized.
    let doc = Document::new("a **b** c", OffsetEncoding::Utf8);
    assert_eq!(doc.concealment(TextRange::new(6, 3), None), doc.concealment(TextRange::new(3, 6), None));
}

#[test]
fn line_endings_never_get_hidden() {
    for nl in ["\n", "\r\n", "\r"] {
        let text = format!("# H{nl}{nl}> q{nl}> r{nl}{nl}```{nl}c{nl}```{nl}{nl}Title{nl}==={nl}{nl}a\\{nl}b {nl}x");
        let doc = Document::new(&text, OffsetEncoding::Utf8);
        let c = doc.concealment(TextRange::new(text.len() as u32, text.len() as u32), None);
        assert!(!c.hidden.is_empty());
        for r in &c.hidden {
            let s = &text[r.start as usize..r.end as usize];
            assert!(!s.contains('\n') && !s.contains('\r'), "{s:?}");
        }
        for r in &c.collapsed {
            let s = &text[r.start as usize..r.end as usize];
            assert!(s.ends_with(nl) || r.end as usize == text.len(), "{s:?}");
            assert!(r.start == 0 || text[..r.start as usize].ends_with(['\n', '\r']), "starts at a line start");
        }
        if nl != "\r" {
            // (pulldown-cmark does not recognise fences ending in lone CRs.)
            assert_eq!(c.collapsed.len(), 3, "{nl:?}: two fences and a setext underline");
        }
    }
}

#[test]
fn unicode_and_all_encodings_agree() {
    let text = "😀 **bold é** and [日本](http://x.y/ü) \\* `c\u{301}`\n\n# 😀 title\n";
    for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
        let doc = Document::new(text, enc);
        let end = doc.len();
        let c = doc.concealment(TextRange::new(end, end), None);
        let got: Vec<String> = c.hidden.iter().map(|&r| slice_units(text, enc, r)).collect();
        assert_eq!(got, v(&["**", "**", "[", "](http://x.y/ü)", "\\", "`", "`", "# "]), "{enc:?}");
    }
}

#[test]
fn within_clips_and_prefers_nothing_outside() {
    let text = "a **b** c\n\n# H\n\nd *e* f\n";
    let doc = Document::new(text, OffsetEncoding::Utf16);
    let sel = TextRange::new(text.len() as u32, text.len() as u32);
    let all = doc.concealment(sel, None);
    let part = doc.concealment(sel, Some(TextRange::new(10, 15)));
    assert_eq!(part.hidden.len(), 1);
    assert_eq!(slice_units(text, OffsetEncoding::Utf16, part.hidden[0]), "# ");
    assert!(all.hidden.len() > part.hidden.len());
    // An empty window sees nothing hidden.
    assert!(doc.concealment(sel, Some(TextRange::new(3, 3))).hidden.is_empty());
}

// ---------- links (Cmd-click) ----------

fn link_at(text: &str, needle: &str) -> Option<(String, String)> {
    let doc = Document::new(text, OffsetEncoding::Utf8);
    let at = text.find(needle).unwrap() as u32;
    doc.link_at(at).map(|l| (text[l.range.start as usize..l.range.end as usize].to_owned(), l.destination))
}

#[test]
fn link_at_resolves_every_link_form() {
    let t = "a [text](http://x.y \"title\") b";
    assert_eq!(link_at(t, "text"), Some(("[text](http://x.y \"title\")".into(), "http://x.y".into())));
    assert_eq!(link_at("[a](<my file.md>)", "a]").unwrap().1, "my file.md");
    assert_eq!(link_at("see <https://e.com/a> ok", "e.com").unwrap().1, "https://e.com/a");
    assert_eq!(link_at("mail <me@e.com>", "me@").unwrap().1, "mailto:me@e.com");
    assert_eq!(link_at("go to https://e.com/x_y now", "e.com").unwrap().1, "https://e.com/x_y");
    assert_eq!(link_at("go to www.e.com now", "www").unwrap().1, "www.e.com");
    assert_eq!(link_at("[a *b* c](u)", "b*").unwrap().1, "u");
    assert_eq!(link_at("[![i](x.png)](u)", "![").unwrap().1, "u");
    // Reference links resolve through the definition.
    let r = "x [a][Foo] [Foo][] [foo]\n\n[foo]: ./dest.md \"t\"\n";
    assert_eq!(link_at(r, "a]").unwrap().1, "./dest.md");
    assert_eq!(link_at(r, "Foo]").unwrap().1, "./dest.md");
    assert_eq!(link_at(r, "foo]").unwrap().1, "./dest.md");
    // Not a link, or an unresolved one.
    assert_eq!(link_at("plain text", "text"), None);
    assert_eq!(link_at("[a][nope]", "a]"), None);
}

#[test]
fn link_to_inserts_a_link_in_place_of_the_selection() {
    let doc = Document::new("see ", OffsetEncoding::Utf16);
    let e = doc.format(FormatCommand::LinkTo { destination: "a b/c (1).pdf".into(), text: "c".into() }, TextRange::new(4, 4)).unwrap();
    assert_eq!(e.replacement, "[c](<a b/c (1).pdf>)");
    assert_eq!(e.selection, TextRange::new(24, 24));
    let doc = Document::new("a word", OffsetEncoding::Utf16);
    let e = doc.format(FormatCommand::LinkTo { destination: "f.txt".into(), text: String::new() }, TextRange::new(2, 6)).unwrap();
    assert_eq!(e.replacement, "[word](f.txt)");
}

/// `cargo test --release -p markdown-core --test conceal -- --ignored --nocapture`
#[test]
#[ignore = "timing"]
fn concealment_of_a_window_in_a_one_megabyte_document_is_cheap() {
    let unit = "# Heading\n\nSome *emphasis*, **strong**, `code` and a [link](http://x.y/z) here.\n\n> quote\n> more\n\n- [ ] task\n- item\n\n```\ncode\n```\n\n";
    let text = unit.repeat(1_000_000 / unit.len() + 1);
    let doc = Document::new(&text, OffsetEncoding::Utf16);
    let mid = doc.len() / 2;
    let start = std::time::Instant::now();
    let n = 2000;
    let mut hidden = 0;
    for i in 0..n {
        let p = mid + (i % 50);
        let c = doc.concealment(TextRange::new(p, p), Some(TextRange::new(p - 6000, p + 6000)));
        hidden += c.hidden.len();
    }
    let per = start.elapsed() / n;
    println!("1 MB document ({} units): windowed concealment (12k units) {per:?} each, {} hidden ranges per query", doc.len(), hidden / n as usize);
    assert!(per < std::time::Duration::from_millis(5));
}

/// The shell queries the whole text up to 150k UTF-16 units, a window beyond: what each costs.
/// `cargo test --release -p markdown-core --test conceal -- --ignored --nocapture whole`
#[test]
#[ignore = "timing"]
fn whole_document_concealment_at_the_shell_threshold() {
    let unit = "# Heading\n\nSome *emphasis*, **strong**, `code` and a [link](http://x.y/z) here.\n\n> quote\n> more\n\n- [ ] task\n- item\n\n```\ncode\n```\n\n";
    let text = unit.repeat(150_000 / unit.len() + 1);
    for enc in [OffsetEncoding::Utf16, OffsetEncoding::Utf8] {
    let doc = Document::new(&text, enc);
    let n = 200;
    let start = std::time::Instant::now();
    for i in 0..n {
        let p = (i * 997) % doc.len();
        std::hint::black_box(doc.concealment(TextRange::new(p, p), None));
    }
    let whole = start.elapsed() / n;
    let start = std::time::Instant::now();
    for i in 0..n {
        let p = (i * 997) % doc.len();
        let w = TextRange::new(p.saturating_sub(6000), (p + 6000).min(doc.len()));
        std::hint::black_box(doc.concealment(TextRange::new(p, p), Some(w)));
    }
    let windowed = start.elapsed() / n;
    println!("{enc:?} {} units: whole document {whole:?}, 12k window {windowed:?}", doc.len());
    }
}

// ---------- properties ----------

const ENCODINGS: [OffsetEncoding; 3] = [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32];

fn md_tokens(max: usize) -> impl Strategy<Value = String> {
    const TOKENS: &[&str] = &[
        "# ", "## ", "> ", "- ", "* ", "1. ", "- [ ] ", "- [x] ", "```", "```rs\n", "~~~", "---\n", "***", "\n", "\n\n", "\r\n",
        "  \n", "*", "**", "_", "~~", "`", "[", "](", ")", "![", "]", "[^1]", "[^1]: ", "|", "| a | b |\n", "|---|---|\n",
        "<div>", "</div>", "<b>", "<http://a.b>", "www.a.b/c", "http://a.b/x_y ", "\\", "\\*", "word ", "text", " ", "    ",
        "=== ", "===\n", "[r]: /u\n", "[r]", "\u{1F389}", "\u{65E5}\u{672C}", "e\u{301}", "&amp;", "#", "![a](p.png)\n\n", "\\\n",
    ];
    prop::collection::vec(prop::sample::select(TOKENS), 0..max).prop_map(|v| v.concat())
}

fn check_concealment(doc: &Document, sel: TextRange, within: Option<TextRange>) -> Result<Concealment, String> {
    let text = doc.text();
    let enc = doc.encoding();
    let c = doc.concealment(sel, within);
    let len = doc.len();
    let ok = boundaries(text, enc);
    let prose = doc.prose_ranges(None);
    let mut prev_end = None;
    for r in &c.hidden {
        if r.start >= r.end || r.end > len {
            return Err(format!("bad hidden range {r:?}"));
        }
        if ok.binary_search(&r.start).is_err() || ok.binary_search(&r.end).is_err() {
            return Err(format!("hidden range splits a code point {r:?}"));
        }
        if prev_end.is_some_and(|p| r.start <= p) {
            return Err(format!("hidden ranges unsorted, overlapping or unmerged at {r:?}"));
        }
        prev_end = Some(r.end);
        if let Some(w) = within
            && (r.start < w.start || r.end > w.end)
        {
            return Err(format!("hidden {r:?} outside window {w:?}"));
        }
        let s = slice_units(text, enc, *r);
        if s.contains('\n') || s.contains('\r') {
            return Err(format!("hidden range {r:?} contains a line terminator: {s:?}"));
        }
        if prose.iter().any(|p| p.start < r.end && r.start < p.end) {
            return Err(format!("hidden range {r:?} ({s:?}) covers prose"));
        }
    }
    let full_hidden = doc.concealment(sel, None).hidden;
    for r in &c.collapsed {
        let first = r.start == 0 || slice_units(text, enc, TextRange::new(r.start - 1, r.start)).ends_with(['\n', '\r']);
        let last = r.end == len || slice_units(text, enc, TextRange::new(r.end - 1, r.end)).ends_with(['\n', '\r']);
        if !first || !last || r.start >= r.end {
            return Err(format!("collapsed {r:?} is not whole lines"));
        }
        // Nothing visible but blanks.
        let line = slice_units(text, enc, *r);
        let units: Vec<char> = line.chars().collect();
        let mut u = r.start;
        for ch in units {
            let w = match enc {
                OffsetEncoding::Utf8 => ch.len_utf8() as u32,
                OffsetEncoding::Utf16 => ch.len_utf16() as u32,
                OffsetEncoding::Utf32 => 1,
            };
            if !matches!(ch, ' ' | '\t' | '\n' | '\r') && !full_hidden.iter().any(|h| h.start <= u && u + w <= h.end) {
                return Err(format!("collapsed line {r:?} has visible {ch:?}"));
            }
            u += w;
        }
    }
    let images = doc.images();
    let mut last = None;
    for d in &c.decorations {
        if d.range.start >= d.range.end || d.range.end > len {
            return Err(format!("bad decoration {d:?}"));
        }
        if last.is_some_and(|l: TextRange| (l.start, std::cmp::Reverse(l.end)) > (d.range.start, std::cmp::Reverse(d.range.end))) {
            return Err(format!("decorations unsorted at {d:?}"));
        }
        last = Some(d.range);
        if let DecorationKind::Image { index } = d.kind {
            let im = images.get(index as usize).ok_or("image index out of range")?;
            if im.range != d.range || !im.standalone {
                return Err(format!("image decoration {d:?} does not match {im:?}"));
            }
        }
    }
    Ok(c)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|s| s.parse().ok()).unwrap_or(600)
    ))]

    #[test]
    fn concealment_contract(text in md_tokens(40), a in 0usize..200, b in 0usize..200, w0 in 0usize..200, w1 in 0usize..200) {
        for enc in ENCODINGS {
            let doc = Document::new(&text, enc);
            let bs = boundaries(&text, enc);
            let pick = |i: usize| bs[i % bs.len()];
            let sel = TextRange::new(pick(a), pick(b));
            if let Err(e) = check_concealment(&doc, sel, None) {
                return Err(TestCaseError::fail(format!("{enc:?} {text:?} {sel:?}: {e}")));
            }
            let (x, y) = (pick(w0), pick(w1));
            let win = TextRange::new(x.min(y), x.max(y));
            let full = doc.concealment(sel, None);
            let part = match check_concealment(&doc, sel, Some(win)) {
                Ok(p) => p,
                Err(e) => return Err(TestCaseError::fail(format!("{enc:?} {text:?} {sel:?} {win:?}: {e}"))),
            };
            // A window sees the same hidden pieces as the whole, clipped.
            let clipped: Vec<TextRange> = full.hidden.iter().filter_map(|h| {
                let (s, e) = (h.start.max(win.start), h.end.min(win.end));
                (s < e).then(|| TextRange::new(s, e))
            }).collect();
            prop_assert_eq!(&part.hidden, &clipped, "{:?} {:?} {:?}", text, sel, win);
        }
    }

    #[test]
    fn stable_for_carets_in_plain_prose(text in md_tokens(40), a in 0usize..200, b in 0usize..200) {
        let enc = OffsetEncoding::Utf8;
        let doc = Document::new(&text, enc);
        let bs = boundaries(&text, enc);
        let spans = doc.spans(None);
        let owners = doc.markup_spans(None);
        let bytes = text.as_bytes();
        // The paragraph of a standalone image is its owner (a hard break before the image does
        // not make it less alone: `\\` CR LF `![a](p.png)`).
        let image_paras: Vec<TextRange> = doc.images().iter().filter(|i| i.standalone).filter_map(|i| {
            doc.blocks().into_iter().find(|b| b.range.start <= i.range.start && i.range.end <= b.range.end).map(|b| b.range)
        }).collect();
        let plain: Vec<u32> = bs.iter().copied().filter(|&p| {
            let ls = text[..p as usize].rfind(['\n', '\r']).map_or(0, |i| i as u32 + 1);
            let le = text[p as usize..].find(['\n', '\r']).map_or(text.len() as u32, |i| p + i as u32);
            let _ = bytes;
            // Far from any owner: the caret's line has no block-level markup or decoration,
            // and the caret is not in or next to any inline owner, block or image.
            image_paras.iter().all(|r| !(r.start <= p && p <= r.end)) &&
            owners.iter().all(|m| !((m.owner.start <= p && p <= m.owner.end) || (m.range.start >= ls && m.range.end <= le)))
                && spans.iter().all(|s| {
                    let on_line = s.range.start <= le && s.range.end >= ls;
                    let touches = s.range.start <= p && p <= s.range.end;
                    let block_like = matches!(s.kind, SpanKind::CodeBlock | SpanKind::FrontMatter | SpanKind::Image | SpanKind::Link);
                    let line_like = matches!(s.kind, SpanKind::ThematicBreak | SpanKind::Heading { .. } | SpanKind::BlockQuote);
                    !((block_like && touches) || (line_like && on_line))
                })
        }).collect();
        if plain.len() >= 2 {
            let (p, q) = (plain[a % plain.len()], plain[b % plain.len()]);
            prop_assert_eq!(
                doc.concealment(TextRange::new(p, p), None),
                doc.concealment(TextRange::new(q, q), None),
                "{:?} carets {} and {}", text, p, q
            );
        }
    }

    #[test]
    fn matches_a_fresh_document_after_edits(text in md_tokens(30), ins in md_tokens(6), at in 0usize..100, n in 0usize..8) {
        let enc = OffsetEncoding::Utf16;
        let mut doc = Document::new(&text, enc);
        let bs = boundaries(&text, enc);
        let s = bs[at % bs.len()];
        let e = bs[(at + n) % bs.len()].max(s);
        doc.replace(TextRange::new(s, e), &ins).unwrap();
        let fresh = Document::new(doc.text(), enc);
        let end = doc.len();
        for p in [0, end / 2, end] {
            let sel = TextRange::new(p, p);
            prop_assert_eq!(doc.concealment(sel, None), fresh.concealment(sel, None));
        }
    }
}

// ---------- the test pass's list of suspects, pinned ----------

#[test]
fn nested_owners_are_independent() {
    // Caret in the outer strong, outside the inner emphasis: only the strong shows.
    assert_eq!(hidden("x **a¦ *b* c**"), v(&["*", "*"]));
    assert!(hidden("x **a *b¦* c**").is_empty());
    // `***a** b*`: emphasis around strong, the caret after the strong but inside the emphasis.
    assert_eq!(hidden("x ***a**¦ b*"), Vec::<String>::new());
    assert_eq!(hidden("x ***a** b¦*"), v(&["**", "**"]));
    // Caret in emphasis, outside the link it holds.
    assert_eq!(hidden("x *a [b](u) c¦*"), v(&["[", "](u)"]));
}

#[test]
fn links_holding_images() {
    // Away: both bracket pairs and both destinations hide; the alt text stays.
    assert_eq!(hidden("[![i](x.png)](u)\n\n¦z"), v(&["[![", "](x.png)](u)"]));
    // At the link's end: the link shows, the image inside it (not touched) does not.
    assert_eq!(hidden("[![i](x.png)](u)¦"), v(&["![", "](x.png)"]));
    // Not standalone (the link is the paragraph's content): no image decoration.
    assert!(decos("[![i](x.png)](u)\n\n¦z").is_empty());
}

#[test]
fn images_in_containers_are_standalone() {
    assert_eq!(decos("- ![i](x.png)\n\n¦z"), vec![("-".to_string(), DecorationKind::Bullet), ("![i](x.png)".to_string(), DecorationKind::Image { index: 0 })]);
    assert_eq!(hidden("> ![i](x.png)\n\n¦z"), v(&["> ![i](x.png)"]));
    assert!(hidden("> ![i](x.png)¦\n\nz").is_empty());
}

#[test]
fn headings_in_containers() {
    assert_eq!(hidden("- # H\n\n¦z"), v(&["# "]));
    assert!(hidden("- # H¦\n\nz").is_empty());
    assert_eq!(hidden("> # H\n\n¦z"), v(&["> # "]));
    assert_eq!(hidden("> ## H\n> b¦\n\nz"), v(&["> ## "]));
}

#[test]
fn lazy_continuation_lines_have_no_marker() {
    assert_eq!(hidden("> a\nlazy\n\n¦z"), v(&["> "]));
    // The bar covers the whole quote, lazy line included; the shell draws it only beside
    // lines whose `>` is hidden.
    assert_eq!(decos("> a\nlazy\n\n¦z"), vec![("> a\nlazy".to_string(), DecorationKind::QuoteBar { depth: 0 })]);
}

#[test]
fn setext_underlines_and_their_neighbours() {
    // `  - ` under a paragraph is an underline (up to three blanks of indentation).
    assert_eq!(hidden("a\n  - \n\n¦z"), v(&["-"]));
    assert_eq!(collapsed("a\n  - \n\n¦z"), v(&["  - \n"]));
    assert!(hidden("a\n  - ¦\n\nz").is_empty());
    assert!(hidden("a\n¦  - \n\nz").is_empty(), "the start of the underline's line is on it");
    // `*`, `+` and `1.` cannot be underlines: they stay list items.
    for m in ["*", "+", "1."] {
        let t = format!("- a\n  {m} \n\n¦z");
        assert!(hidden(&t).is_empty(), "{t:?}");
        assert!(collapsed(&t).is_empty(), "{t:?}");
    }
    // `==` is an underline too.
    assert_eq!(hidden("- a\n  ==\n\n¦z"), v(&["=="]));
    // A rule after a lazy line is a rule, not an underline.
    assert_eq!(decos("- a\nb\n---\n¦z"), vec![("-".to_string(), DecorationKind::Bullet), ("---".to_string(), DecorationKind::Rule)]);
    // Thematic breaks of each kind.
    assert_eq!(hidden("¦z\n\n***\n---\n___"), v(&["***", "---", "___"]));
}

#[test]
fn fences_in_containers() {
    // In a list item: the closing fence line collapses; the opening line keeps its bullet.
    let t = "¦z\n\n- ```\n  code\n  ```\n";
    assert_eq!(hidden(t), v(&["```", "```"]));
    assert_eq!(collapsed(t), v(&["  ```\n"]));
    // Unclosed in a list item.
    assert_eq!(hidden("¦z\n\n- ```\n  code\n"), v(&["```"]));
    // Unclosed in a quote.
    assert_eq!(hidden("¦z\n\n> ```\n> code\n"), v(&["> ```", "> "]));
    assert_eq!(collapsed("¦z\n\n> ```\n> code\n"), v(&["> ```\n"]));
}

#[test]
fn an_indented_closing_fence_is_content() {
    // Regression: `    ```` (four blanks) cannot close a fence; it was hidden and collapsed.
    assert_eq!(hidden("```\naaa\n    ```\n\n¦"), v(&["```"]));
    assert_eq!(collapsed("```\naaa\n    ```\n\n¦"), v(&["```\n"]));
    // Three blanks still close.
    assert_eq!(hidden("```\naaa\n   ```\n\n¦"), v(&["```", "```"]));
    // In a list item the indentation counts from the item's content.
    assert_eq!(hidden("¦z\n\n- ```\n  a\n      ```\n"), v(&["```"]));
}

#[test]
fn quote_markers_inside_multi_line_code_spans_and_list_items() {
    // Regression: the `>` starting a quote line inside a code span (or inline HTML) that runs
    // over two lines was taken for code content and left showing.
    assert_eq!(hidden("> a `b\n> c` d\n\n¦z"), v(&["> ", "`", "> ", "`"]));
    assert_eq!(hidden("> a <span\n> title=x> d\n\n¦z"), v(&["> ", "> "]));
    // Regression: a quoted fence in a list item, its `>` lines four columns in.
    assert_eq!(hidden("- > ```rs\n    >\n\n¦z"), v(&["> ```rs", ">"]));
}

#[test]
fn front_matter_lookalikes() {
    // Not closed: a rule and a paragraph.
    assert_eq!(decos("---\ntitle\n\n¦z"), vec![("---".to_string(), DecorationKind::Rule)]);
    assert_eq!(decos("---\n\n¦z"), vec![("---".to_string(), DecorationKind::Rule)]);
    // `...` closes YAML too.
    assert_eq!(hidden("---\na: b\n...\n¦z"), v(&["---", "..."]));
    // pulldown-cmark 0.13 accepts a metadata block after a blank line anywhere; the preview
    // omits it, so Live mode treats it as front matter too.
    assert_eq!(collapsed("x\n\n---\ntitle: x\n---\n¦z"), v(&["---\n", "---\n"]));
}

#[test]
fn escapes_next_to_emphasis_and_hard_breaks() {
    // An escaped backslash before strong: the escape and the strong are separate owners.
    assert_eq!(hidden("¦z \\\\**a**"), v(&["\\", "**", "**"]));
    assert_eq!(hidden("\\\\**a**¦ z"), v(&["\\"]));
    assert_eq!(hidden("¦z **a\\***"), v(&["**", "\\", "**"]));
    // A backslash at the end of a paragraph or a heading is text, not a hard break.
    assert!(hidden("¦z\n\na\\\n\nb").is_empty());
    assert_eq!(hidden("¦z\n\n# a\\\n\nb"), v(&["# "]));
    // A hard break in a quote: hidden like the markers around it.
    assert_eq!(hidden("¦z\n\n> a\\\n> b"), v(&["> ", "\\", "> "]));
}

#[test]
fn autolinks_and_remote_definitions() {
    assert_eq!(hidden("¦z <http://a.b> <me@x.y>"), v(&["<", ">", "<", ">"]));
    assert_eq!(hidden("¦<http://a.b> <me@x.y>"), v(&["<", ">"]), "the caret before the first touches it");
    // A reference whose definition is in a quote further down: the link hides its brackets,
    // the definition (never concealed) keeps its own; only the quote's `> ` goes.
    assert_eq!(hidden("[a][ref]\n\n> [ref]: /u\n\n¦z"), v(&["[", "][ref]", "> "]));
}

#[test]
fn empty_documents_and_crlf() {
    assert_eq!(conceal("¦").1, Concealment::default());
    assert_eq!(conceal("¦\n").1, Concealment::default());
    assert_eq!(conceal("¦\r\n").1, Concealment::default());
    let t = "¦z\r\n\r\n# H\r\n\r\n```\r\nc\r\n```\r\n";
    assert_eq!(hidden(t), v(&["# ", "```", "```"]));
    assert_eq!(collapsed(t), v(&["```\r\n", "```\r\n"]));
    // A caret between CR and LF is on neither line's text.
    assert_eq!(hidden("# H\r¦\nz"), v(&["# "]));
}

#[test]
fn a_standalone_image_over_two_lines_stays_source() {
    // Regression: the decoration stood for source whose line break could not be hidden.
    let t = "¦z\n\n![a](p.png\n)\n";
    assert!(decos(t).is_empty());
    assert_eq!(hidden(t), v(&["![", "](p.png", ")"]));
}
