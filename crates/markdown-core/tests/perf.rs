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
