//! Snapshots (insta) of spans, blocks, prose ranges and images for every fixture file.
mod common;
use common::*;
use markdown_core::*;

fn report(text: &str) -> String {
    let doc = Document::new(text, OffsetEncoding::Utf16);
    let mut out = String::new();
    out.push_str("# spans (utf16 range, kind, text)\n");
    for l in fmt_spans(&doc) {
        out.push_str(&l);
        out.push('\n');
    }
    out.push_str("\n# markup (range, owner, scope, in_table)\n");
    for m in doc.markup_spans(None) {
        out.push_str(&format!(
            "{}..{} owner {}..{} {:?}{}\n",
            m.range.start,
            m.range.end,
            m.owner.start,
            m.owner.end,
            m.scope,
            if m.in_table { " in_table" } else { "" }
        ));
    }
    out.push_str("\n# blocks\n");
    for b in doc.blocks() {
        out.push_str(&format!(
            "{:?} {}..{} line {} level {:?} depth {} {:?}\n",
            b.kind,
            b.range.start,
            b.range.end,
            b.line,
            b.heading_level,
            b.depth,
            slice_units(text, OffsetEncoding::Utf16, b.range)
        ));
    }
    out.push_str("\n# prose\n");
    for p in doc.prose_ranges(None) {
        out.push_str(&format!("{}..{} {:?}\n", p.start, p.end, slice_units(text, OffsetEncoding::Utf16, p)));
    }
    out.push_str("\n# images\n");
    for i in doc.images() {
        out.push_str(&format!("{i:?}\n"));
    }
    out
}

#[test]
fn fixture_snapshots() {
    let fixtures = fixtures();
    assert!(fixtures.len() >= 4);
    for (name, text) in fixtures {
        for enc in [OffsetEncoding::Utf8, OffsetEncoding::Utf16, OffsetEncoding::Utf32] {
            check_everything(&Document::new(&text, enc)).unwrap_or_else(|e| panic!("{name} {enc:?}: {e}"));
        }
        insta::assert_snapshot!(name.clone(), report(&text));
    }
}
