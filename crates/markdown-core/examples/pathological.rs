use markdown_core::*;
use std::time::Instant;
fn main() {
    let cases: Vec<(&str, String)> = vec![
        ("20k nested quotes", ">".repeat(20000)),
        ("20k nested quotes with lines", "> ".repeat(2000) + &"\n> ".repeat(2000)),
        ("200k backslashes + text", "\\*".repeat(200_000)),
        ("100k brackets", "[".repeat(100_000)),
        ("100k links", "[a](b)".repeat(50_000)),
        ("deep lists", (0..2000).map(|i| format!("{}- x\n", "  ".repeat(i.min(500)))).collect()),
        ("100k emphasis", "*a ".repeat(100_000)),
        ("many tables", "| a | b |\n|---|---|\n| 1 | 2 |\n\n".repeat(20_000)),
        ("many defs", "[a]: /u\n".repeat(100_000)),
        ("one huge line", "word ".repeat(200_000)),
    ];
    for (name, text) in cases {
        let t = Instant::now();
        let d = Document::new(&text, OffsetEncoding::Utf16);
        let n = d.spans(None).len();
        println!("{name}: {:.1} ms, {n} spans", t.elapsed().as_secs_f64() * 1e3);
    }
}
