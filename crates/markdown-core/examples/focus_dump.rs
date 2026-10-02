use markdown_core::*;
fn main() {
    let t = std::env::args().nth(1).unwrap().replace("\\n", "\n");
    let scope = if std::env::args().nth(2).as_deref() == Some("p") { FocusScope::Paragraph } else { FocusScope::Sentence };
    let d = Document::new(&t, OffsetEncoding::Utf8);
    for b in d.blocks() { println!("block {:?} {:?}", b.kind, &t[b.range.start as usize..b.range.end as usize]); }
    for p in 0..=t.len() as u32 {
        if !t.is_char_boundary(p as usize) { continue; }
        let r = d.focus_range(TextRange::new(p, p), scope);
        println!("{p:3} {:?}", r.iter().map(|r| &t[r.start as usize..r.end as usize]).collect::<Vec<_>>());
    }
}
