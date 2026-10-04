//! Release-mode timing: `cargo test --release -p markdown-core --test perf -- --ignored --nocapture`
mod common;
use markdown_core::*;
use std::time::Instant;

fn realistic(target: usize) -> String {
    let unit = "# Section heading\n\nA paragraph with *emphasis*, **strong**, `inline code`, a [link](https://example.com/a?b=c \"title\") and some more words to make the line longer. Another sentence follows here, with caf\u{e9} and \u{65E5}\u{672C}\u{8A9E}.\nSecond line of the paragraph with ~~strike~~ and a footnote.[^1]\n\n- item one\n- [x] done item with **bold**\n- [ ] open item\n  - nested item\n\n> A block quote\n> over two lines.\n\n```rust\nfn main() {\n    println!(\"hello\");\n}\n```\n\n| Left | Right |\n|:-----|------:|\n| a    | b     |\n| `c`  | *d*   |\n\n![alt text](images/pic.png)\n\n1. first\n2. second\n\n---\n\n[^1]: The footnote body.\n\n";
    let mut s = String::new();
    while s.len() < target {
        s.push_str(unit);
    }
    s
}

fn med(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() / 2]
}

#[test]
#[ignore]
fn one_megabyte_document() {
    let text = realistic(1 << 20);
    println!("document: {} bytes", text.len());
    for enc in [OffsetEncoding::Utf16, OffsetEncoding::Utf8] {
        let t = Instant::now();
        let mut doc = Document::new(&text, enc);
        let t_new = t.elapsed().as_secs_f64() * 1e3;

        let mut times = vec![];
        let mut last_dirty = TextRange::default();
        let mid = doc.len() / 2;
        // a position on a char boundary: scan to the next ASCII letter boundary using spans' view
        let mut pos = mid;
        while doc.replace(TextRange::new(pos, pos), "x").is_err() {
            pos += 1;
        }
        // undo the probing insert
        doc.replace(TextRange::new(pos, pos + 1), "").unwrap();
        for i in 0..21 {
            let t = Instant::now();
            let u = doc.replace(TextRange::new(pos + i, pos + i), "x").unwrap();
            times.push(t.elapsed().as_secs_f64() * 1e3);
            last_dirty = u.dirty;
        }
        let t_replace = med(times);

        let mut times = vec![];
        let mut n = 0;
        for _ in 0..11 {
            let t = Instant::now();
            n = doc.spans(None).len();
            times.push(t.elapsed().as_secs_f64() * 1e3);
        }
        let t_spans = med(times);

        let t = Instant::now();
        let w = doc.spans(Some(TextRange::new(mid, mid + 2000))).len();
        let t_within = t.elapsed().as_secs_f64() * 1e3;
        let t = Instant::now();
        let nb = doc.blocks().len();
        let t_blocks = t.elapsed().as_secs_f64() * 1e3;
        let t = Instant::now();
        let np = doc.prose_ranges(None).len();
        let t_prose = t.elapsed().as_secs_f64() * 1e3;
        println!(
            "{enc:?}: new {t_new:.2} ms | replace(1 char) median {t_replace:.2} ms (dirty {} units) | spans(None) {t_spans:.2} ms ({n} spans) | spans(2000-unit window) {t_within:.3} ms ({w}) | blocks {t_blocks:.2} ms ({nb}) | prose {t_prose:.2} ms ({np})",
            last_dirty.end - last_dirty.start
        );
        assert!(t_replace < 30.0, "single-character replace took {t_replace:.2} ms");
    }
}

/// Editing commands on a 1 MB document, mid-text: each should be a few milliseconds at most.
#[test]
#[ignore]
fn commands_on_one_megabyte() {
    let text = realistic(1 << 20);
    let doc = Document::new(&text, OffsetEncoding::Utf8);
    let mid = text.len() / 2;
    let find = |pat: &str| {
        let i = mid + text[mid..].find(pat).unwrap();
        TextRange::new(i as u32, i as u32)
    };
    let word = {
        let r = find("emphasis");
        TextRange::new(r.start, r.start + 8)
    };
    let table = find("| `c`");
    let item = find("nested item");
    let task = find("done item");
    let mut rows: Vec<(&str, f64)> = Vec::new();
    let mut time = |name: &'static str, f: &dyn Fn()| {
        let mut v = Vec::new();
        for _ in 0..11 {
            let t = Instant::now();
            f();
            v.push(t.elapsed().as_secs_f64() * 1e3);
        }
        rows.push((name, med(v)));
    };
    time("format_state", &|| {
        std::hint::black_box(doc.format_state(word));
    });
    time("strong", &|| {
        std::hint::black_box(doc.format(FormatCommand::Strong, word));
    });
    time("heading", &|| {
        std::hint::black_box(doc.format(FormatCommand::Heading { level: 2 }, item));
    });
    time("newline", &|| {
        std::hint::black_box(doc.newline(task));
    });
    time("indent", &|| {
        std::hint::black_box(doc.indent(item, false));
    });
    time("toggle_task", &|| {
        std::hint::black_box(doc.toggle_task(task.start));
    });
    time("table next cell", &|| {
        std::hint::black_box(doc.table_command(TableCommand::NextCell, table));
    });
    time("table_at", &|| {
        std::hint::black_box(doc.table_at(table.start));
    });
    for (name, ms) in &rows {
        println!("{name}: {ms:.3} ms");
        assert!(*ms < 10.0, "{name} took {ms:.2} ms on a 1 MB document");
    }
}

#[test]
#[ignore]
fn focus_queries_on_one_megabyte() {
    let text = realistic(1 << 20);
    let doc = Document::new(&text, OffsetEncoding::Utf16);
    let len = doc.len();
    let mut carets = vec![];
    let mut p = 1;
    while p < len {
        carets.push(p);
        p += 9973;
    }
    for (name, scope) in [("sentence", FocusScope::Sentence), ("paragraph", FocusScope::Paragraph)] {
        let mut times = vec![];
        for &c in &carets {
            let t = Instant::now();
            let _ = doc.focus_range(TextRange::new(c, c), scope);
            times.push(t.elapsed().as_secs_f64() * 1e6);
        }
        let max = times.iter().cloned().fold(0.0, f64::max);
        println!("focus_range {name}: median {:.1} us, max {:.1} us over {} carets", med(times), max, carets.len());
    }
    let w = TextRange::new(len / 2, len / 2 + 30_000);
    let t = Instant::now();
    let st = doc.selection_state(TextRange::new(len / 2, len / 2), Some(w), true, Some(FocusScope::Sentence));
    println!("selection_state (conceal + format + table + focus, 30k window): {:.1} us ({} hidden)", t.elapsed().as_secs_f64() * 1e6, st.concealment.unwrap().hidden.len());
    let t = Instant::now();
    let r = doc.focus_range(TextRange::new(0, len), FocusScope::Sentence);
    println!("select all, sentence scope, whole document: {:.1} ms ({} ranges)", t.elapsed().as_secs_f64() * 1e3, r.len());
    let t = Instant::now();
    let _ = doc.format_state(TextRange::new(0, len));
    println!("(format_state of select all, for comparison: {:.1} ms)", t.elapsed().as_secs_f64() * 1e3);
    let t = Instant::now();
    let r = doc.selection_state(TextRange::new(0, len), Some(w), false, Some(FocusScope::Sentence)).focus.unwrap();
    println!("select all, windowed: {:.1} us ({} ranges)", t.elapsed().as_secs_f64() * 1e6, r.len());
    let t = Instant::now();
    let units = doc.pos_units(None);
    println!("pos_units whole document: {:.1} ms ({} units)", t.elapsed().as_secs_f64() * 1e3, units.len());
    let t = Instant::now();
    let units = doc.pos_units(Some(w));
    println!("pos_units 30k window: {:.1} us ({} units)", t.elapsed().as_secs_f64() * 1e6, units.len());
    // One paragraph of half a megabyte.
    let giant = "A sentence goes here. Another one follows it, and it keeps going.\n".repeat(8000);
    let g = Document::new(&giant, OffsetEncoding::Utf16);
    let t = Instant::now();
    let r = g.focus_range(TextRange::new(200_000, 200_000), FocusScope::Sentence);
    println!("one {} KB paragraph, sentence: {:.1} us {:?}", giant.len() / 1024, t.elapsed().as_secs_f64() * 1e6, r);
}

#[test]
#[ignore]
fn focus_and_pos_units_in_one_giant_paragraph() {
    // A megabyte in one paragraph: many lines, one line, and no sentence terminator at all.
    let mut x: u64 = 0x2545_F491;
    let mut words = |n: usize, stop: bool, newline_every: usize| {
        let mut out = String::from("A");
        let mut k: usize = 0;
        while out.len() < n {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            k += 1;
            out.push(if k.is_multiple_of(newline_every) { '\n' } else { ' ' });
            let capital = out.trim_end().ends_with('.');
            for i in 0..2 + x % 8 {
                let c = (b'a' + ((x >> (i * 5)) % 26) as u8) as char;
                out.push(if capital && i == 0 { c.to_ascii_uppercase() } else { c });
            }
            if stop && x.is_multiple_of(11) {
                out.push('.');
            }
        }
        out
    };
    let cases = [
        ("many lines", words(1 << 20, true, 12)),
        ("one line", words(1 << 20, true, usize::MAX)),
        ("no terminators", words(1 << 20, false, 12)),
    ];
    for (name, giant) in cases {
        let g = Document::new(&giant, OffsetEncoding::Utf16);
        let len = g.len();
        let t = Instant::now();
        let r = g.focus_range(TextRange::new(len / 2, len / 2), FocusScope::Sentence);
        let caret = t.elapsed().as_secs_f64() * 1e6;
        let t = Instant::now();
        let _ = g.focus_range(TextRange::new(len / 2, len / 2 + 3), FocusScope::Sentence);
        let sel = t.elapsed().as_secs_f64() * 1e6;
        let t = Instant::now();
        let all = g.pos_units(None);
        let units = t.elapsed().as_secs_f64() * 1e3;
        let t = Instant::now();
        let some = g.pos_units(Some(TextRange::new(len / 2, len / 2 + 30_000)));
        let window = t.elapsed().as_secs_f64() * 1e3;
        println!(
            "{name} ({} KB): sentence at caret {caret:.0} us ({} units long), small selection {sel:.0} us; pos_units {} units in {units:.1} ms, 30k window {} units in {window:.1} ms",
            giant.len() / 1024,
            r[0].end - r[0].start,
            all.len(),
            some.len()
        );
    }
}

/// Rendering a 1 MB document to HTML (target: under about 60 ms, first-use syntax loading excluded).
#[test]
#[ignore]
fn one_megabyte_render() {
    let text = realistic(1 << 20);
    let doc = Document::new(&text, OffsetEncoding::Utf16);
    // First use: the bundled syntaxes load once (a static).
    let t = Instant::now();
    markdown_core::highlight::warm_up();
    println!("syntax set load (first use): {:.1} ms", t.elapsed().as_secs_f64() * 1e3);
    let cases: [(&str, RenderOptions); 4] = [
        ("body, highlighted", RenderOptions::default()),
        ("body, no highlighting", RenderOptions { highlight: false, ..Default::default() }),
        ("with source lines", RenderOptions { source_lines: true, ..Default::default() }),
        ("standalone + sanitize", RenderOptions { standalone: true, sanitize: true, ..Default::default() }),
    ];
    for (name, options) in cases {
        let mut times = vec![];
        let mut cold = vec![];
        let mut len = 0;
        for _ in 0..7 {
            markdown_core::highlight::clear_cache();
            let t = Instant::now();
            len = doc.render_html(&options).len();
            cold.push(t.elapsed().as_secs_f64() * 1e3);
            // The second render finds the highlighted blocks in the cache, as the next keystroke's does.
            let t = Instant::now();
            doc.render_html(&options);
            times.push(t.elapsed().as_secs_f64() * 1e3);
        }
        println!("{name}: median {:.1} ms with the highlight cache warm, {:.1} ms cold (output {} KB)", med(times), med(cold), len / 1024);
    }
    let t = Instant::now();
    let fragment = doc.render_html_fragment(TextRange::new(500_000, 501_000), &RenderOptions::default());
    println!("a 1 KB fragment of the 1 MB document: {:.1} ms ({} bytes)", t.elapsed().as_secs_f64() * 1e3, fragment.len());
}

/// The same, with a different code block each time (the worst case for the highlight cache).
#[test]
#[ignore]
fn one_megabyte_render_with_distinct_code() {
    let mut text = String::new();
    let mut i = 0;
    while text.len() < 1 << 20 {
        text.push_str(&format!("# Section {i}\n\nA paragraph with *emphasis* and a [link](https://example.com/{i}). More words follow here.\n\n```rust\nfn main() {{\n    println!(\"hello {i}\");\n}}\n```\n\n- item {i}\n- [x] done\n\n"));
        i += 1;
    }
    let doc = Document::new(&text, OffsetEncoding::Utf16);
    markdown_core::highlight::warm_up();
    for (name, highlight) in [("highlighted", true), ("not highlighted", false)] {
        let options = RenderOptions { highlight, ..Default::default() };
        let mut times = vec![];
        for _ in 0..5 {
            markdown_core::highlight::clear_cache();
            let t = Instant::now();
            doc.render_html(&options);
            times.push(t.elapsed().as_secs_f64() * 1e3);
        }
        println!("{} blocks, distinct code, {name}: median {:.1} ms cold, {} KB of Markdown", i, med(times), text.len() / 1024);
    }
}

/// No render of a 1 MB document takes more than about 100 ms in release, whatever its code blocks
/// hold: highlighting stops at a per-render budget (`RENDER_BUDGET_MS` overrides the bound).
#[test]
#[ignore]
fn worst_case_renders_are_bounded() {
    markdown_core::highlight::warm_up();
    let bound: f64 = std::env::var("RENDER_BUDGET_MS").ok().and_then(|s| s.parse().ok()).unwrap_or(100.0);
    let fill = |unit: &dyn Fn(usize) -> String| {
        let mut s = String::new();
        let mut i = 0;
        while s.len() < 1 << 20 {
            s.push_str(&unit(i));
            i += 1;
        }
        s
    };
    let minified = "var a=function(b,c){return b&&c?b.map(function(d){return d*c+\"x\"}):[]};".repeat(25);
    let cases: Vec<(&str, String)> = vec![
        ("distinct small Rust blocks", fill(&|i| format!("```rust\nfn main() {{\n    println!(\"hello {i}\");\n}}\n```\n\n"))),
        ("one giant Python block", format!("```python\n{}```\n", fill(&|i| format!("def f{i}(a, b):\n    return a + b  # comment {i}\n")))),
        ("long minified JavaScript lines", fill(&|i| format!("```js\n{minified}{i}\n```\n\n"))),
        ("deeply nested HTML", fill(&|i| format!("```html\n{}x{i}{}\n```\n\n", "<div class=\"a\">".repeat(40), "</div>".repeat(40)))),
        ("LaTeX", fill(&|i| format!("```latex\n\\begin{{equation}}\\frac{{a_{i}}}{{b}} = \\sum_{{k=0}}^{{n}} x^k\\end{{equation}}\n```\n\n"))),
        ("unterminated strings and comments", fill(&|i| format!("```c\n/* open {i}\nchar *s = \"abc\\\n```\n\n"))),
        ("prose, no code", fill(&|i| format!("Paragraph {i} with *emphasis* and a [link](https://x.y/{i}).\n\n"))),
    ];
    let mut worst: f64 = 0.0;
    for (name, text) in &cases {
        let doc = Document::new(text, OffsetEncoding::Utf16);
        let opts = RenderOptions { source_lines: true, ..Default::default() };
        let mut times = vec![];
        for _ in 0..3 {
            markdown_core::highlight::clear_cache();
            let t = Instant::now();
            let html = doc.render_html(&opts);
            times.push(t.elapsed().as_secs_f64() * 1e3);
            assert!(!html.is_empty());
        }
        let skipped = doc.render_html(&opts).matches("data-highlight=\"skipped\"").count();
        let m = times.iter().cloned().fold(0.0, f64::max);
        worst = worst.max(m);
        println!("{name}: {:.1} ms worst of 3, cold cache ({} KB, {skipped} blocks left plain)", m, text.len() / 1024);
    }
    assert!(worst < bound, "a render took {worst:.1} ms (bound {bound} ms)");
}

/// Select All in a big document: the format state is answered from the first parts of the selection
/// that settle it, not by reading every span in it (it cost 13 to 44 ms at 1 MB before).
#[test]
#[ignore]
fn select_all_format_state_does_not_read_the_whole_document() {
    let text = realistic(1 << 20);
    let doc = Document::new(&text, OffsetEncoding::Utf16);
    let all = TextRange::new(0, doc.len());
    let mut times = vec![];
    for _ in 0..21 {
        let t = Instant::now();
        let _ = doc.format_state(all);
        times.push(t.elapsed().as_secs_f64() * 1e3);
    }
    let m = med(times);
    println!("format_state over Select All at 1 MB: median {m:.3} ms");
    assert!(m < 2.0, "{m} ms");
}

#[test]
#[ignore]
fn history_diff_one_megabyte() {
    use markdown_core::history::{diff_lines, DiffKind};
    let old = realistic(1 << 20);
    let mut new = old.clone();
    let mid = new.len() / 2;
    let at = new[mid..].find('\n').unwrap() + mid;
    new.insert_str(at, " (edited)");
    let mut times = vec![];
    let mut hunks = vec![];
    for _ in 0..11 {
        let t = Instant::now();
        hunks = diff_lines(&old, &new);
        times.push(t.elapsed().as_secs_f64() * 1e3);
    }
    let m = med(times);
    println!("history diff, {} bytes, one line changed: {:.2} ms median ({} hunks)", old.len(), m, hunks.len());
    assert!(m < 50.0, "the diff of a 1 MB document must stay under 50 ms");
    assert_eq!(hunks.iter().filter(|h| h.kind != DiffKind::Equal).count(), 2);
    // The worst case for the search: every line differs.
    let other: String = old.lines().map(|l| format!("{l} x\n")).collect();
    let t = Instant::now();
    let h = diff_lines(&old, &other);
    println!("history diff, every line changed: {:.2} ms ({} hunks)", t.elapsed().as_secs_f64() * 1e3, h.len());
}
