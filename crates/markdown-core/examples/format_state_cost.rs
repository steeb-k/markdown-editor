//! What `format_state` costs over a selection of the whole of a 1 MB document (Select All), and
//! over a few places for comparison.
//!
//!   cargo run --release -p markdown-core --example format_state_cost
use markdown_core::*;
use std::time::Instant;

fn main() {
    let unit = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../scripts/macos/ui/fixtures/dense.md")).unwrap();
    let mut text = String::new();
    while text.len() < 1_000_000 {
        text.push_str(&unit);
    }
    let doc = Document::new(&text, OffsetEncoding::Utf16);
    let n = doc.len();
    for (name, sel) in [("caret", TextRange::new(n / 2, n / 2)), ("a paragraph", TextRange::new(n / 2, n / 2 + 300)), ("select all", TextRange::new(0, n))] {
        let mut times = vec![];
        let mut last = None;
        for _ in 0..9 {
            let t = Instant::now();
            last = Some(doc.format_state(sel));
            times.push(t.elapsed().as_secs_f64() * 1e3);
        }
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!("{name:12} median {:.2} ms  {:?}", times[times.len() / 2], last.unwrap());
    }
}
