//! Every CommonMark 0.31.2 spec example: no panic, contract holds, edits are sound.
mod common;
use common::*;
use markdown_core::*;

fn examples() -> Vec<(u64, String)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/commonmark-spec.json");
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).expect("fixtures/commonmark-spec.json")).unwrap();
    json.as_array()
        .unwrap()
        .iter()
        .map(|e| (e["example"].as_u64().unwrap(), e["markdown"].as_str().unwrap().to_owned()))
        .collect()
}

#[test]
fn spec_examples_hold_the_contract_in_every_encoding() {
    let ex = examples();
    assert!(ex.len() > 600, "expected the full spec, got {}", ex.len());
    for (n, md) in &ex {
        for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            let doc = Document::new(md, enc);
            check_everything(&doc).unwrap_or_else(|e| panic!("example {n} {enc:?} {md:?}: {e}"));
        }
    }
}

#[test]
fn spec_examples_survive_edits_with_sound_dirty_ranges() {
    for (n, md) in examples() {
        let enc = OffsetEncoding::Utf16;
        let b = boundaries(&md, enc);
        let last = *b.last().unwrap();
        let mid = b[b.len() / 2];
        let edits: Vec<(TextRange, &str)> = vec![
            (TextRange::new(0, 0), "# "),
            (TextRange::new(0, b.get(1).copied().unwrap_or(0)), ""),
            (TextRange::new(mid, mid), "*"),
            (TextRange::new(mid, mid), "\n\n"),
            (TextRange::new(mid, mid), "```\n"),
            (TextRange::new(last, last), "\n> x"),
            (TextRange::new(0, last), ""),
        ];
        for (r, with) in edits {
            check_edit(&md, enc, r, with).unwrap_or_else(|e| panic!("example {n} {md:?} edit {r:?} {with:?}: {e}"));
        }
    }
}
