//! Does the core get slower as a long session of edits goes on? Repeated one-character edits
//! (and a selection query, as the editor makes after each) at scattered places of a 1 MB
//! document, timed in blocks.
//!
//!   cargo run --release -p markdown-core --example session_drift [edits]
use markdown_core::*;
use std::time::Instant;

fn main() {
    let edits: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(4000);
    let unit = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../scripts/macos/ui/fixtures/dense.md")).unwrap();
    let mut text = String::new();
    while text.len() < 1_000_000 {
        text.push_str(&unit);
    }
    let mut doc = Document::new(&text, OffsetEncoding::Utf16);
    let mut seed = 7u64;
    let mut block = 0.0;
    let alphabet: Vec<char> = "the quick brown fox jumps over the lazy dog ".chars().collect();
    for i in 0..edits {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        if i % 20 == 0 {
            // jump
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        }
        let pos = ((seed >> 33) % (doc.len() as u64 - 1)) as u32;
        let mut p = pos;
        let c = alphabet[i % alphabet.len()].to_string();
        let t = Instant::now();
        while doc.replace(TextRange::new(p, p), &c).is_err() {
            p += 1;
        }
        let sel = TextRange::new(p, p);
        let w = TextRange::new(p.saturating_sub(10_000), (p + 10_000).min(doc.len()));
        let _ = doc.selection_state(sel, Some(w), true, None);
        block += t.elapsed().as_secs_f64() * 1e3;
        if (i + 1) % 250 == 0 {
            println!("edits {:5}: {:.1} ms per edit", i + 1, block / 250.0);
            block = 0.0;
        }
    }
}
