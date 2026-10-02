//! The notices for the syntax definitions two-face bundles (the ones whose licenses require
//! acknowledgement), as Markdown on stdout; scripts/gen-acknowledgements.py puts them in
//! Acknowledgements.md.
//!
//!   cargo run -q -p markdown-core --example syntax_licenses
use std::collections::BTreeMap;

fn main() {
    let ack = two_face::acknowledgement::listing();
    // Identical texts are printed once, with every definition they cover.
    let mut by_text: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
    for l in ack.for_syntaxes() {
        by_text.entry((format!("{:?}", l.ty), l.text.trim().to_owned())).or_default().push(
            l.rel_path.display().to_string().trim_start_matches("syntaxes/").trim_end_matches("/LICENSE").trim_end_matches("/LICENSE.txt").to_owned(),
        );
    }
    for ((ty, text), mut paths) in by_text {
        paths.sort();
        paths.dedup();
        println!("#### {} ({})\n\nCovers: {}\n\n````text\n{}\n````\n", ty, paths.len(), paths.join(", "), text);
    }
}
